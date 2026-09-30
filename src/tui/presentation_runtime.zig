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
            .load_session => |value| .{ .session_loaded = .{ .command_id = value.command_id, .intent = value.intent, .outcome = .{ .failed = error.Scripted } } },
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
