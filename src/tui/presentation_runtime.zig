//! Thread-to-terminal handoff for typed Presentation completions.
//!
//! A worker owns its command. It executes through the production adapter, then
//! transfers exactly one `OwnedInput` to a sink. If the terminal queue has
//! closed, the worker disposes the completion locally.

const bbr = @import("bbr");
const presentation = @import("presentation.zig");
const adapter = @import("presentation_adapter.zig");
const search = @import("search.zig");

pub const CompletionSink = struct {
    ptr: *anyopaque,
    post_fn: *const fn (*anyopaque, presentation.OwnedInput) anyerror!void,

    /// On success ownership transfers to the sink. On error the caller still
    /// owns `input` and must dispose it.
    pub fn post(self: CompletionSink, input: presentation.OwnedInput) !void {
        return self.post_fn(self.ptr, input);
    }
};

/// Terminal-adapter execution seam. Production executors and deterministic
/// scripts consume the same closed `OwnedCommand` union and return completions
/// through `CompletionSink`.
pub const CommandExecutor = struct {
    ptr: *anyopaque,
    execute_fn: *const fn (*anyopaque, CompletionSink, *presentation.OwnedCommand) anyerror!void,

    /// On success the executor consumed `command`. On error ownership remains
    /// with the caller so it can admit a typed launch failure or dispose it.
    pub fn execute(self: CommandExecutor, sink: CompletionSink, command: *presentation.OwnedCommand) !void {
        return self.execute_fn(self.ptr, sink, command);
    }
};

/// Drain a scripted command batch through the same executor/sink ownership
/// contract used by terminal workers. This deliberately knows no network,
/// timer, terminal, PTY, or Presentation policy.
pub fn drain(executor: CommandExecutor, sink: CompletionSink, commands: []presentation.OwnedCommand) !void {
    for (commands) |*command| {
        try executor.execute(sink, command);
        command.* = undefined;
    }
}

pub fn deliver(sink: CompletionSink, input_value: presentation.OwnedInput) void {
    var input = input_value;
    sink.post(input) catch input.deinit();
}

pub fn executePost(
    sink: CompletionSink,
    command: *presentation.PostDraft,
    poster: bbr.review.CommentPoster,
) void {
    deliver(sink, adapter.executePost(command, poster));
}

pub fn rejectPostLaunch(sink: CompletionSink, command: *presentation.PostDraft) void {
    deliver(sink, adapter.postLaunchFailed(command));
}

pub fn executeCommentEdit(sink: CompletionSink, command: *presentation.UpdateComment, client: bbr.bitbucket.Client) void {
    deliver(sink, adapter.executeCommentEdit(command, client));
}

pub fn rejectCommentEditLaunch(sink: CompletionSink, command: *presentation.UpdateComment) void {
    deliver(sink, adapter.commentEditLaunchFailed(command));
}

pub fn executeCommentDelete(sink: CompletionSink, command: *presentation.DeleteComment, client: bbr.bitbucket.Client) void {
    deliver(sink, adapter.executeCommentDelete(command, client));
}

pub fn rejectCommentDeleteLaunch(sink: CompletionSink, command: *presentation.DeleteComment) void {
    deliver(sink, adapter.commentDeleteLaunchFailed(command));
}

const std = @import("std");
const testing = std.testing;

test "M23 highlighting closed completion sink releases owned result storage" {
    const highlighting = @import("code_highlighting.zig");
    const result = owned: {
        const value = try testing.allocator.create(highlighting.Result);
        errdefer testing.allocator.destroy(value);
        value.* = .{ .allocator = testing.allocator, .spans = try testing.allocator.alloc(highlighting.SourceSpan, 1) };
        break :owned value;
    };
    var sink: CapturingSink = .{ .reject = true };
    deliver(sink.sink(), .{ .code_highlight_completed = .{
        .command_id = 1,
        .identity = .{ .session_epoch = 1, .owner = .{ .draft = 1 }, .block = 0, .body_hash = 1, .context_hash = 1 },
        .result = result,
    } });
    try testing.expect(sink.input == null);
}

const CapturingSink = struct {
    input: ?presentation.OwnedInput = null,
    reject: bool = false,

    fn sink(self: *CapturingSink) CompletionSink {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, input: presentation.OwnedInput) anyerror!void {
        const self: *CapturingSink = @ptrCast(@alignCast(ptr));
        if (self.reject) return error.QueueClosed;
        self.input = input;
    }
};

const ScriptedSink = struct {
    inputs: [13]?presentation.OwnedInput = .{null} ** 13,
    count: usize = 0,

    fn sink(self: *ScriptedSink) CompletionSink {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, input: presentation.OwnedInput) anyerror!void {
        const self: *ScriptedSink = @ptrCast(@alignCast(ptr));
        if (self.count == self.inputs.len) return error.QueueFull;
        self.inputs[self.count] = input;
        self.count += 1;
    }

    fn deinit(self: *ScriptedSink) void {
        for (self.inputs[0..self.count]) |*maybe_input| if (maybe_input.*) |input_value| {
            var input = input_value;
            input.deinit();
            maybe_input.* = null;
        };
    }
};

const ScriptedExecutor = struct {
    tags: [13]std.meta.Tag(presentation.OwnedCommand) = undefined,
    count: usize = 0,

    fn executor(self: *ScriptedExecutor) CommandExecutor {
        return .{ .ptr = self, .execute_fn = execute };
    }

    fn execute(ptr: *anyopaque, sink: CompletionSink, command: *presentation.OwnedCommand) !void {
        const self: *ScriptedExecutor = @ptrCast(@alignCast(ptr));
        self.tags[self.count] = std.meta.activeTag(command.*);
        self.count += 1;
        const input: presentation.OwnedInput = switch (command.*) {
            .highlight_code => |job| .{ .code_highlight_completed = job.launchFailed() },
            .load_session => |value| .{ .session_loaded = .{ .command_id = value.command_id, .intent = value.intent, .outcome = .{ .failed = error.Scripted } } },
            .prepare_session => |value| value.launchFailed(),
            .enrich_file => |value| .{ .file_enrichment_completed = .{
                .command_id = value.command_id,
                .work_id = value.work_id,
                .session_epoch = value.session_epoch,
                .file_index = value.file_index,
                .outcome = .{ .failed = .launch_failed },
            } },
            .post_draft => |value| adapter.postLaunchFailed(value),
            .update_comment => |value| adapter.commentEditLaunchFailed(value),
            .delete_comment => |value| adapter.commentDeleteLaunchFailed(value),
            .change_reviewer_verdict => |value| adapter.reviewerVerdictLaunchFailed(value),
            .wait_submission => |value| .{ .submission_wait_completed = value },
            .check_recovery => |value| .{ .recovery_checked = .{
                .command_id = value.command_id,
                .operation_id = value.operation_id,
                .identity = value.identity,
                .outcome = .failed,
            } },
            .find_duplicate => |value| blk: {
                const input: presentation.OwnedInput = .{ .duplicate_checked = .{
                    .command_id = value.command_id,
                    .operation_id = value.operation_id,
                    .identity = value.identity,
                    .temp_id = value.draft.local_id,
                    .outcome = .failed,
                } };
                value.destroy();
                break :blk input;
            },
            .list_pull_requests => |value| .{ .pull_requests_loaded = .{ .command_id = value.command_id, .work_id = value.work_id, .outcome = .failed } },
            .copy_clipboard => |value| blk: {
                const command_id = value.command_id;
                value.destroy();
                break :blk .{ .clipboard_completed = .{ .command_id = command_id, .success = true } };
            },
            .external_edit => |value| blk: {
                const completed = try presentation.ExternalEditCompleted.create(value.allocator, value.command_id, value.session_epoch);
                completed.outcome = .unchanged;
                value.destroy();
                break :blk .{ .external_edit_completed = completed };
            },
            .scan_buffer_search => |*value| .{ .buffer_search_scanned = value.launchFailed() },
            .build_buffer_disclosure => |value| blk: {
                value.failed = true;
                break :blk .{ .buffer_disclosure_built = value };
            },
            .scan_review_source => |*value| blk: {
                const completed: presentation.ReviewSourceScanned = .{
                    .allocator = std.heap.page_allocator,
                    .command_id = value.command_id,
                    .session_epoch = value.session_epoch,
                    .request_id = value.request_id,
                    .file_index = value.file_index,
                    .outcome = .failed,
                };
                value.deinit();
                break :blk .{ .review_source_scanned = completed };
            },
        };
        deliver(sink, input);
    }
};

test "deliver transfers a correlated completion to the terminal sink" {
    var capture = CapturingSink{};
    deliver(capture.sink(), .{ .post_draft_launch_failed = .{ .operation_id = 7, .temp_id = 11 } });

    const input = capture.input.?.post_draft_launch_failed;
    try testing.expectEqual(@as(bbr.review.OperationId, 7), input.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 11), input.temp_id);
}

test "deliver owns and disposes a completion rejected during shutdown" {
    var capture = CapturingSink{ .reject = true };
    const summaries = try presentation.PullRequestSummaries.create(testing.allocator);
    summaries.prs = try summaries.arena.allocator().dupe(bbr.bitbucket.PullRequestSummary, &.{.{
        .id = 7,
        .title = "owned result",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
    }});
    var input: presentation.OwnedInput = .{ .pull_requests_loaded = .{
        .work_id = 9,
        .outcome = .{ .loaded = summaries },
    } };
    deliver(capture.sink(), input);
    input = undefined;

    try testing.expect(capture.input == null);
}

fn scriptedPost(command_id: presentation.CommandId, operation_id: bbr.review.OperationId) !*presentation.PostDraft {
    const command = try testing.allocator.create(presentation.PostDraft);
    command.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .operation_id = operation_id,
        .command_id = command_id,
        .identity = .{ .value = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1) },
        .draft = .{ .local_id = 41, .kind = .comment, .body = "body" },
        .parent = null,
        .dedupe = false,
    };
    return command;
}

fn scriptedUpdate(command_id: presentation.CommandId) !*presentation.UpdateComment {
    const command = try testing.allocator.create(presentation.UpdateComment);
    command.* = .{
        .allocator = testing.allocator,
        .command_id = command_id,
        .identity = .{ .value = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1) },
        .comment_id = 42,
        .body = try testing.allocator.dupe(u8, "updated"),
    };
    return command;
}

fn scriptedDelete(command_id: presentation.CommandId) !*presentation.DeleteComment {
    const command = try testing.allocator.create(presentation.DeleteComment);
    command.* = .{
        .allocator = testing.allocator,
        .command_id = command_id,
        .identity = .{ .value = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1) },
        .comment_id = 43,
    };
    return command;
}

fn scriptedClipboard(command_id: presentation.CommandId) !*presentation.ClipboardCopy {
    const command = try testing.allocator.create(presentation.ClipboardCopy);
    command.* = .{
        .allocator = testing.allocator,
        .command_id = command_id,
        .text = try testing.allocator.dupe(u8, "copy"),
    };
    return command;
}

fn scriptedExternalEdit(command_id: presentation.CommandId) !*presentation.ExternalEdit {
    const command = try testing.allocator.create(presentation.ExternalEdit);
    command.* = .{
        .allocator = testing.allocator,
        .command_id = command_id,
        .session_epoch = 7,
        .max_bytes = 64,
        .body = try testing.allocator.dupe(u8, "edit"),
    };
    return command;
}

fn scriptedBufferSearch(command_id: presentation.CommandId) !presentation.ScanBufferSearch {
    const corpus = try std.heap.page_allocator.create(presentation.BufferSearchCorpus);
    corpus.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .candidates = &.{},
    };
    errdefer {
        corpus.arena.deinit();
        std.heap.page_allocator.destroy(corpus);
    }
    return .{
        .command_id = command_id,
        .request_id = 1,
        .session_epoch = 7,
        .corpus = corpus,
        .query = try search.Query.init(std.heap.page_allocator, "query"),
    };
}

test "Buffer Search launch failure keeps correlation and releases its command" {
    for ([_]search.Mode{ .literal, .fuzzy }) |mode| {
        var command = try scriptedBufferSearch(41);
        command.mode = mode;
        command.corpus.references.store(2, .release);
        const corpus = command.corpus;
        defer {
            corpus.arena.deinit();
            std.heap.page_allocator.destroy(corpus);
        }
        var completed = command.launchFailed();
        defer completed.deinit();
        try testing.expectEqual(@as(presentation.CommandId, 41), completed.command_id);
        try testing.expectEqual(@as(u64, 1), completed.request_id);
        try testing.expectEqual(@as(presentation.SessionEpoch, 7), completed.session_epoch);
        try testing.expectEqual(mode, completed.mode);
        try testing.expect(completed.outcome == .failed);
        try testing.expectEqual(@as(usize, 1), corpus.references.load(.acquire));
    }
}

test "closed terminal sink releases a Buffer Search Batch" {
    var command = try scriptedBufferSearch(41);
    defer command.deinit();
    command.corpus.candidates = &.{.{
        .text = "query",
        .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 0 } },
        .session_epoch = 7,
    }};
    var capture: CapturingSink = .{ .reject = true };
    const completed = presentation.executeBufferSearchScan(testing.allocator, &command);
    try testing.expect(completed.outcome == .scanned);
    try testing.expectEqual(@as(usize, 1), completed.outcome.scanned.occurrences.len);
    deliver(capture.sink(), .{ .buffer_search_scanned = completed });
    try testing.expect(capture.input == null);
}

test "closed terminal sink releases a staged Buffer Frame and its Session" {
    const session = try @import("session.zig").create(testing.allocator);
    session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Local" };
    session.source = .{ .local = .{ .common_dir = "." } };
    session.diff = try bbr.diff.parse(session.arena.allocator(), "");
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try presentation.OwnedReviewIdentity.initLocal(1, "main", "feature");
    try store.store().put(.{ .workspace = key.workspace(), .repository = key.repository(), .pull_request_id = 1 }, .{ .local_id = 1, .target = .local, .kind = .comment, .scope = .review, .body = "one\n\ntwo\n\nhidden" });
    var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store(), .comments_collapsed_rows = 2 }, .{
        .initial = .{ .key = key, .session = session },
    });
    defer state.deinit();
    try state.dispatch(.{ .action = .open_buffer_search });
    try state.dispatch(.{ .key = .{ .codepoint = 'h', .text = "hidden" } });
    var scan = state.takeCommand().?;
    defer scan.deinit();
    try state.dispatch(.{ .buffer_search_scanned = presentation.executeBufferSearchScan(testing.allocator, &scan.scan_buffer_search) });
    const job = state.takeCommand().?.build_buffer_disclosure;
    job.failed = true;
    var capture: CapturingSink = .{ .reject = true };
    deliver(capture.sink(), .{ .buffer_disclosure_built = job });
    try testing.expect(capture.input == null);
}

fn candidateSessionFixture() !*@import("session.zig").Session {
    const session = try @import("session.zig").create(testing.allocator);
    errdefer session.destroy();
    session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Local" };
    session.source = .{ .local = .{ .common_dir = "." } };
    session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1 @@\n-old\n+new\n");
    try session.initializeEnrichment();
    return session;
}

test "M21 kernel Candidate Session launch failure and closed sink release private Frames" {
    for ([_]enum { launch_failed, closed_before_build, closed_after_build }{ .launch_failed, .closed_before_build, .closed_after_build }) |outcome| {
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        const key = try presentation.OwnedReviewIdentity.initLocal(1, "main", "feature");
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{ .initial = .{ .key = key, .session = try candidateSessionFixture() } });
        defer state.deinit();
        const previous = state.projection().review.?;
        try state.dispatch(.{ .action = .refresh });
        const load = state.takeCommand().?.load_session;
        const candidate = try candidateSessionFixture();
        defer candidate.destroy();
        candidate.retain();
        try state.dispatch(.{ .session_loaded = .{ .command_id = load.command_id, .intent = load.intent, .outcome = .{ .loaded = candidate } } });
        var command = state.takeCommand().?;
        var capture: CapturingSink = .{ .reject = outcome != .launch_failed };
        if (outcome == .closed_after_build) {
            command.prepare_session.build();
            try testing.expect(command.prepare_session.ready);
            deliver(capture.sink(), .{ .session_prepared = command.prepare_session });
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
        }
        if (outcome == .launch_failed) {
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ReplacementError.buffer_build_failed, state.projection().replacement_error.?);
            try testing.expect(!state.projection().replacing);
        } else try testing.expect(capture.input == null);
        try testing.expectEqual(@as(usize, 1), candidate.references.load(.acquire));
        try testing.expectEqual(previous.session_epoch, state.projection().review.?.session_epoch);
        try testing.expectEqual(previous.frame.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
    }
}

test "M21 kernel view Frame launch failure and closed sink preserve the complete Frame" {
    for ([_]enum { layout, scope, resolved, version, isolate, movement, width }{ .layout, .scope, .resolved, .version, .isolate, .movement, .width }) |change| for ([_]bool{ false, true }) |closed| {
        const session = try @import("session.zig").create(testing.allocator);
        session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Local" };
        session.source = .{ .local = .{ .common_dir = "." } };
        const a = session.arena.allocator();
        session.diff = try bbr.diff.parse(a, "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b.zig b/b.zig\n--- a/b.zig\n+++ b/b.zig\n@@ -1 +1 @@\n-old\n+new\n");
        session.threads = try bbr.review.buildThreads(a, &.{.{ .id = 1, .author = "Reviewer", .body = "resolved", .resolved = true, .anchor = .{ .path = "a.zig", .to = 1 } }});
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = try presentation.OwnedReviewIdentity.initLocal(1, "main", "feature"), .session = session },
            .geometry = .{ .cols = 100, .rows = 12 },
        });
        defer state.deinit();
        if (change == .movement) {
            try state.dispatch(.{ .action = .isolate });
            const initial = state.takeCommand().?.build_buffer_disclosure;
            initial.build();
            try state.dispatch(.{ .buffer_disclosure_built = initial });
        } else if (change == .resolved) {
            const initial = state.projection().review.?;
            for (initial.frame.visual_rows, 0..) |visual, index| if (initial.buffer.rows[visual.buffer_index] == .disclosure) {
                for (0..index) |_| try state.dispatch(.{ .action = .down });
                break;
            };
        }
        const before = state.projection().review.?;
        const references = session.references.load(.acquire);
        switch (change) {
            .layout => try state.dispatch(.{ .action = .toggle_layout }),
            .scope => try state.dispatch(.{ .action = .cycle_scope }),
            .resolved => try state.dispatch(.{ .action = .toggle_disclosure }),
            .version => try state.dispatch(.{ .action = .select_old_version }),
            .isolate => try state.dispatch(.{ .action = .isolate }),
            .movement => try state.dispatch(.{ .action = .next_file }),
            .width => try state.dispatch(.{ .resize = .{ .cols = 72, .rows = 12 } }),
        }
        var command = state.takeCommand().?;
        var capture: CapturingSink = .{ .reject = closed };
        if (closed) {
            command.build_buffer_disclosure.build();
            try testing.expect(!command.build_buffer_disclosure.failed);
            deliver(capture.sink(), .{ .buffer_disclosure_built = command.build_buffer_disclosure });
            try testing.expect(capture.input == null);
            try testing.expectEqual(references, session.references.load(.acquire));
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ActionError.buffer_build_failed, state.projection().action_error.?);
        }
        const after = state.projection().review.?;
        try testing.expectEqual(before.frame.visual_rows.ptr, after.frame.visual_rows.ptr);
        try testing.expectEqual(before.preferences, after.preferences);
        try testing.expectEqual(before.frame.geometry, after.frame.geometry);
        try testing.expectEqual(before.isolated_file, after.isolated_file);
    };
}

test "M21 kernel cache Frame launch failure and closed sink preserve content and focus" {
    for ([_]bool{ false, true }) |release_holds| for ([_]bool{ false, true }) |closed| {
        const session = try @import("session.zig").create(testing.allocator);
        session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Local" };
        session.source = .{ .local = .{ .common_dir = "." } };
        session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b.zig b/b.zig\n--- a/b.zig\n+++ b/b.zig\n@@ -1 +1 @@\n-old\n+new\n");
        try session.initializeEnrichment();
        session.enrichment.focus(0);
        const enrichment = @import("file_enrichment.zig");
        var fake: bbr.http.FakeHttpClient = .{ .status = 200, .body = "cached needle\n" };
        const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
        var plain: bbr.highlight.PlainHighlighter = .{};
        for (0..if (release_holds) @as(usize, 2) else 1) |index| {
            if (index == 1) session.enrichment.hold(index);
            var result = try enrichment.enrich(testing.allocator, client, plain.highlighter(), .{
                .repo = "repo",
                .status = .modified,
                .source_commit = "source",
                .destination_commit = "base",
                .old_path = session.diff.files[index].old_path,
                .new_path = session.diff.files[index].new_path,
                .max_file_bytes = 0,
            });
            defer result.deinit();
            try session.enrichment.admit(index, &result);
        }
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store(), .file_cache_enabled = false }, .{
            .initial = .{ .key = try presentation.OwnedReviewIdentity.initLocal(1, "main", "feature"), .session = session },
        });
        defer state.deinit();
        if (release_holds) {
            session.enrichment.finishLeaseDeferred(1);
            try state.dispatch(.{ .action = .open_review_search });
            try state.dispatch(.{ .key = .{ .codepoint = @import("keymap.zig").special.escape } });
        } else {
            try state.dispatch(.{ .action = .next_file });
            try state.dispatch(.ensure_focused_enrichment);
        }
        const before = state.projection().review.?.frame;
        var command = state.takeCommand().?;
        const references = session.references.load(.acquire) - 1;
        var capture: CapturingSink = .{ .reject = closed };
        if (closed) {
            command.build_buffer_disclosure.build();
            try testing.expect(!command.build_buffer_disclosure.failed);
            deliver(capture.sink(), .{ .buffer_disclosure_built = command.build_buffer_disclosure });
            try testing.expect(capture.input == null);
            try testing.expectEqual(references, session.references.load(.acquire));
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ActionError.buffer_build_failed, state.projection().action_error.?);
            try state.dispatch(.ensure_focused_enrichment);
            const retry = state.takeCommand().?.build_buffer_disclosure;
            retry.build();
            try testing.expect(!retry.failed);
            try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
            try state.dispatch(.{ .buffer_disclosure_built = retry });
        }
        if (closed) {
            try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
            try testing.expectEqual(@as(?usize, 0), session.enrichment.focused_file);
            try testing.expect(session.enrichment.file(if (release_holds) 1 else 0).new == .content);
        } else try testing.expect(session.enrichment.file(if (release_holds) 1 else 0).new == .pending);
    };
}

test "M21 authored destination launch failure and closed sink preserve the Overlay and Frame" {
    for ([_]bool{ false, true }) |closed| {
        const session = try @import("session.zig").create(testing.allocator);
        session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Local" };
        session.source = .{ .local = .{ .common_dir = "." } };
        const a = session.arena.allocator();
        session.diff = try bbr.diff.parse(a, "");
        session.threads = try bbr.review.buildThreads(a, &.{.{ .id = 1, .author = "Reviewer", .body = "needle" }});
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = try presentation.OwnedReviewIdentity.initLocal(1, "main", "feature"), .session = session },
        });
        defer state.deinit();
        try state.dispatch(.{ .action = .open_review_search });
        try state.dispatch(.{ .key = .{ .codepoint = 'n', .text = "needle" } });
        var scan = state.takeCommand().?;
        defer scan.deinit();
        try state.dispatch(.{ .buffer_search_scanned = presentation.executeBufferSearchScan(testing.allocator, &scan.scan_buffer_search) });
        const before = state.projection().review.?.frame;
        const references = session.references.load(.acquire);
        try state.dispatch(.{ .action = .open_search_occurrence });
        var command = state.takeCommand().?;
        var capture: CapturingSink = .{ .reject = closed };
        if (closed) {
            command.build_buffer_disclosure.build();
            try testing.expect(!command.build_buffer_disclosure.failed);
            deliver(capture.sink(), .{ .buffer_disclosure_built = command.build_buffer_disclosure });
            try testing.expect(capture.input == null);
            try testing.expectEqual(references, session.references.load(.acquire));
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ActionError.buffer_build_failed, state.projection().action_error.?);
            try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
            try testing.expectEqualStrings("needle", state.projection().review_search.?.query);
            try state.dispatch(.{ .action = .open_search_occurrence });
            const retry = state.takeCommand().?.build_buffer_disclosure;
            retry.build();
            try state.dispatch(.{ .buffer_disclosure_built = retry });
            try testing.expect(state.projection().review_search == null);
            continue;
        }
        try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
        try testing.expectEqualStrings("needle", state.projection().review_search.?.query);
    }
}

test "M21 authored Buffer Search restoration launch failure and closed sink preserve the Frame" {
    for ([_]bool{ false, true }) |closed| {
        const session = try @import("session.zig").create(testing.allocator);
        session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Bitbucket" };
        session.source = .{ .remote = .{ .id = 1, .title = "Review", .state = "OPEN", .author_display_name = "Reviewer", .source_branch = "feature", .destination_branch = "main", .source_commit = "source", .destination_commit = "base" } };
        session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,12 +1,12 @@\n-a\n+A\n c1\n c2\n c3\n c4\n c5\n c6\n c7\n c8\n c9\n c10\n-b\n+B\n");
        try session.initializeEnrichment();
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1), .session = session },
        });
        defer state.deinit();
        try state.dispatch(.ensure_focused_enrichment);
        var enrichment = state.takeCommand().?;
        const blob = "a\nc1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\nc9\nc10\nb\n";
        const responses = [_]bbr.http.Canned{ .{ .status = 200, .body = blob }, .{ .status = 200, .body = blob } };
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
        var plain: bbr.highlight.PlainHighlighter = .{};
        const result = try @import("file_enrichment.zig").enrich(testing.allocator, client, plain.highlighter(), enrichment.enrich_file.request());
        try state.dispatch(.{ .file_enrichment_completed = .{
            .command_id = enrichment.enrich_file.command_id,
            .work_id = enrichment.enrich_file.work_id,
            .session_epoch = enrichment.enrich_file.session_epoch,
            .file_index = 0,
            .outcome = .{ .completed = result },
        } });
        enrichment.deinit();
        const enriched = state.takeCommand().?.build_buffer_disclosure;
        enriched.build();
        try state.dispatch(.{ .buffer_disclosure_built = enriched });
        try state.dispatch(.{ .action = .open_review_search });
        try state.dispatch(.{ .key = .{ .codepoint = 'c', .text = "c5" } });
        var authored = state.takeCommand().?;
        try state.dispatch(.{ .buffer_search_scanned = presentation.executeBufferSearchScan(testing.allocator, &authored.scan_buffer_search) });
        authored.deinit();
        var source = state.takeCommand().?;
        try state.dispatch(.{ .review_source_scanned = presentation.executeReviewSourceScan(testing.allocator, &source.scan_review_source) });
        source.deinit();
        try state.dispatch(.{ .action = .open_search_occurrence });
        const destination = state.takeCommand().?.build_buffer_disclosure;
        destination.build();
        try state.dispatch(.{ .buffer_disclosure_built = destination });
        const before = state.projection().review.?.frame;
        const references = session.references.load(.acquire);
        try state.dispatch(.{ .action = .open_buffer_search });
        var command = state.takeCommand().?;
        var capture: CapturingSink = .{ .reject = closed };
        if (closed) {
            command.build_buffer_disclosure.build();
            try testing.expect(!command.build_buffer_disclosure.failed);
            deliver(capture.sink(), .{ .buffer_disclosure_built = command.build_buffer_disclosure });
            try testing.expect(capture.input == null);
            try testing.expectEqual(references, session.references.load(.acquire));
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ActionError.buffer_build_failed, state.projection().action_error.?);
            try testing.expect(!state.projection().buffer_search.?.pending);
            try state.dispatch(.{ .key = .{ .codepoint = 'c', .text = "c5" } });
            const retry = state.takeCommand().?.build_buffer_disclosure;
            retry.build();
            try state.dispatch(.{ .buffer_disclosure_built = retry });
            try testing.expect(before.visual_rows.ptr != state.projection().review.?.frame.visual_rows.ptr);
            continue;
        }
        try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
    }
}

test "M21 kernel Draft Frame launch failure and closed sink keep the Draft unsaved" {
    for ([_]bool{ false, true }) |closed| {
        const session = try @import("session.zig").create(testing.allocator);
        session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Local" };
        session.source = .{ .local = .{ .common_dir = "." } };
        session.diff = try bbr.diff.parse(session.arena.allocator(), "");
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        const key = try presentation.OwnedReviewIdentity.initLocal(1, "main", "feature");
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = key, .session = session },
        });
        defer state.deinit();
        try state.dispatch(.{ .action = .review_comment });
        try state.dispatch(.{ .composer = .{ .insert = try presentation.TextChunk.init("keep me") } });
        const before = state.projection().review.?.frame;
        try state.dispatch(.{ .composer = .save });
        var command = state.takeCommand().?;
        var capture: CapturingSink = .{ .reject = closed };
        if (closed) {
            command.build_buffer_disclosure.build();
            try testing.expect(!command.build_buffer_disclosure.failed);
            deliver(capture.sink(), .{ .buffer_disclosure_built = command.build_buffer_disclosure });
            try testing.expect(capture.input == null);
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ActionError.buffer_build_failed, state.projection().action_error.?);
        }
        try testing.expectEqualStrings("keep me", state.projection().composer.?.body);
        try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
        try testing.expectEqual(@as(usize, 0), state.projection().review.?.drafts.len);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const stored = try store.store().loadReview(arena.allocator(), .{ .workspace = key.workspace(), .repository = key.repository(), .pull_request_id = 1 });
        try testing.expectEqual(@as(usize, 0), stored.drafts.items.len);
        if (!closed) {
            try state.dispatch(.{ .composer = .save });
            const retry = state.takeCommand().?.build_buffer_disclosure;
            retry.build();
            try state.dispatch(.{ .buffer_disclosure_built = retry });
            try testing.expect(state.projection().composer == null);
            try testing.expectEqual(@as(usize, 1), state.projection().review.?.drafts.len);
        }
    }
}

test "M21 kernel Draft mutation launch failure and closed sink preserve persistence and Frame" {
    for ([_]enum { body, reanchor, delete, unpublished }{ .body, .reanchor, .delete, .unpublished }) |mutation| for ([_]bool{ false, true }) |closed| {
        const session = try @import("session.zig").create(testing.allocator);
        session.header = .{ .title = "Review", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Bitbucket", .pull_request_id = 1 };
        session.source = .{ .remote = .{ .id = 1, .title = "Review", .state = "OPEN", .author_display_name = "Reviewer", .source_branch = "feature", .destination_branch = "main", .source_commit = "source", .destination_commit = "base" } };
        session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1,2 @@\n-old\n+new\n+later\n");
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        const key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);
        const store_key: bbr.review.RemoteReviewIdentity = .{ .workspace = key.workspace(), .repository = key.repository(), .pull_request_id = 1 };
        try store.store().put(store_key, .{
            .local_id = 1,
            .kind = .comment,
            .target = .bitbucket,
            .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
            .body = "original",
            .state = if (mutation == .unpublished) .outcome_unknown else .draft,
        });
        var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = key, .session = session },
        });
        defer state.deinit();
        var card_row: ?usize = null;
        var source_row: ?usize = null;
        const initial = state.projection().review.?;
        for (initial.frame.visual_rows, 0..) |visual, index| {
            const row = initial.buffer.rows[visual.buffer_index];
            if (row == .draft and card_row == null) card_row = index;
            if (row == .line and row.line.newNo() == 2) source_row = index;
        }
        for (0..card_row.?) |_| try state.dispatch(.{ .action = .down });
        switch (mutation) {
            .body => {
                try state.dispatch(.{ .action = .edit_review_item });
                try state.dispatch(.{ .composer = .{ .insert = try presentation.TextChunk.init(" changed") } });
                try state.dispatch(.{ .composer = .save });
            },
            .reanchor => {
                try state.dispatch(.{ .action = .reanchor_review_item });
                try state.dispatch(.{ .action = .to_top });
                for (0..source_row.?) |_| try state.dispatch(.{ .action = .down });
                try state.dispatch(.{ .reanchor = .accept });
            },
            .delete => {
                try state.dispatch(.{ .action = .delete_review_item });
                try state.dispatch(.{ .delete_confirmation = .confirm });
            },
            .unpublished => try state.dispatch(.{ .action = .resolve_unpublished }),
        }
        const before = state.projection().review.?.frame;
        try testing.expectEqual(@as(?presentation.ActionError, null), state.projection().action_error);
        var command = state.takeCommand().?;
        var capture: CapturingSink = .{ .reject = closed };
        if (closed) {
            command.build_buffer_disclosure.build();
            try testing.expect(!command.build_buffer_disclosure.failed);
            deliver(capture.sink(), .{ .buffer_disclosure_built = command.build_buffer_disclosure });
            try testing.expect(capture.input == null);
        } else {
            var executor: ScriptedExecutor = .{};
            try executor.executor().execute(capture.sink(), &command);
            try state.dispatch(capture.input.?);
            capture.input = null;
            try testing.expectEqual(presentation.ActionError.buffer_build_failed, state.projection().action_error.?);
        }
        try testing.expectEqual(before.visual_rows.ptr, state.projection().review.?.frame.visual_rows.ptr);
        try testing.expectEqualStrings("original", state.projection().review.?.drafts[0].body);
        try testing.expectEqual(@as(?u32, 1), state.projection().review.?.drafts[0].effectiveScope().@"inline".to);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const stored = try store.store().loadReview(arena.allocator(), store_key);
        try testing.expectEqual(@as(usize, 1), stored.drafts.items.len);
        try testing.expectEqualStrings("original", stored.getConst(1).?.body);
        if (mutation == .unpublished) try testing.expect(stored.getConst(1).?.state == .outcome_unknown) else try testing.expect(stored.getConst(1).?.state == .draft);
        if (!closed) {
            switch (mutation) {
                .body => try state.dispatch(.{ .composer = .save }),
                .reanchor => try state.dispatch(.{ .reanchor = .accept }),
                .delete => try state.dispatch(.{ .delete_confirmation = .confirm }),
                .unpublished => try state.dispatch(.{ .action = .resolve_unpublished }),
            }
            const retry = state.takeCommand().?.build_buffer_disclosure;
            retry.build();
            try state.dispatch(.{ .buffer_disclosure_built = retry });
            try testing.expect(state.projection().action_error == null);
            switch (mutation) {
                .body => try testing.expectEqualStrings("original changed", state.projection().review.?.drafts[0].body),
                .reanchor => try testing.expectEqual(@as(?u32, 2), state.projection().review.?.drafts[0].effectiveScope().@"inline".to),
                .delete => try testing.expectEqual(@as(usize, 0), state.projection().review.?.drafts.len),
                .unpublished => try testing.expect(state.projection().review.?.drafts[0].state == .draft),
            }
        }
    };
}

test "scripted terminal adapter drains every command family through the production sink" {
    const identity = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);
    const remote_identity: presentation.OwnedRemoteReviewIdentity = .{ .value = identity };
    var commands = [_]presentation.OwnedCommand{
        .{ .load_session = .{ .command_id = 1, .intent = 21, .key = identity } },
        .{ .enrich_file = .{ .command_id = 2, .work_id = 12, .session_epoch = 7, .file_index = 3, .source = undefined, .source_commit = undefined, .destination_commit = undefined, .old_path = undefined, .new_path = undefined, .status = .modified, .max_file_bytes = 0 } },
        .{ .post_draft = try scriptedPost(3, 30) },
        .{ .update_comment = try scriptedUpdate(4) },
        .{ .delete_comment = try scriptedDelete(5) },
        .{ .change_reviewer_verdict = .{ .command_id = 6, .identity = remote_identity, .expected_source_commit = undefined, .authenticated_account_uuid = undefined, .target = .approved } },
        .{ .wait_submission = .{ .command_id = 7, .operation_id = 30, .identity = remote_identity, .temp_id = 41, .ms = 1000 } },
        .{ .check_recovery = .{ .command_id = 8, .operation_id = 30, .identity = remote_identity, .source_commit = undefined } },
        .{ .find_duplicate = try scriptedPost(9, 30) },
        .{ .list_pull_requests = .{ .command_id = 10, .work_id = 19, .repository = undefined } },
        .{ .copy_clipboard = try scriptedClipboard(11) },
        .{ .external_edit = try scriptedExternalEdit(12) },
        .{ .scan_buffer_search = try scriptedBufferSearch(13) },
    };
    var drained = false;
    defer if (!drained) for (&commands) |*command| command.deinit();
    var executor: ScriptedExecutor = .{};
    var sink: ScriptedSink = .{};
    defer sink.deinit();

    try drain(executor.executor(), sink.sink(), &commands);
    drained = true;

    try testing.expectEqual(commands.len, executor.count);
    try testing.expectEqual(commands.len, sink.count);
    try testing.expectEqual(@as(presentation.CommandId, 1), sink.inputs[0].?.session_loaded.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 2), sink.inputs[1].?.file_enrichment_completed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 3), sink.inputs[2].?.post_draft_launch_failed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 4), sink.inputs[3].?.comment_edit_launch_failed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 5), sink.inputs[4].?.comment_delete_launch_failed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 6), sink.inputs[5].?.reviewer_verdict_changed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 7), sink.inputs[6].?.submission_wait_completed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 8), sink.inputs[7].?.recovery_checked.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 9), sink.inputs[8].?.duplicate_checked.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 10), sink.inputs[9].?.pull_requests_loaded.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 11), sink.inputs[10].?.clipboard_completed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 12), sink.inputs[11].?.external_edit_completed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 13), sink.inputs[12].?.buffer_search_scanned.command_id);
}
