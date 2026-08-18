//! Thread-to-terminal handoff for typed Presentation completions.
//!
//! A worker owns its command. It executes through the production adapter, then
//! transfers exactly one `OwnedInput` to a sink. If the terminal queue has
//! closed, the worker disposes the completion locally.

const bbr = @import("bbr");
const presentation = @import("presentation.zig");
const adapter = @import("presentation_adapter.zig");

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

pub fn executeCommentDelete(sink: CompletionSink, command: *presentation.DeleteComment, client: bbr.bitbucket.Client) void {
    deliver(sink, adapter.executeCommentDelete(command, client));
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
    inputs: [11]?presentation.OwnedInput = .{null} ** 11,
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
    tags: [11]std.meta.Tag(presentation.OwnedCommand) = undefined,
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

test "scripted terminal adapter drains every command family through the production sink" {
    const identity = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);
    const remote_identity: presentation.OwnedRemoteReviewIdentity = .{ .value = identity };
    var commands = [_]presentation.OwnedCommand{
        .{ .load_session = .{ .command_id = 1, .intent = 21, .key = identity } },
        .{ .enrich_file = .{ .command_id = 2, .work_id = 12, .session_epoch = 7, .file_index = 3, .source = undefined, .source_commit = undefined, .destination_commit = undefined, .old_path = undefined, .new_path = undefined, .status = .modified, .max_file_bytes = 0 } },
        .{ .post_draft = try scriptedPost(3, 30) },
        .{ .update_comment = try scriptedUpdate(4) },
        .{ .delete_comment = try scriptedDelete(5) },
        .{ .wait_submission = .{ .command_id = 6, .operation_id = 30, .identity = remote_identity, .temp_id = 41, .ms = 1000 } },
        .{ .check_recovery = .{ .command_id = 7, .operation_id = 30, .identity = remote_identity, .source_commit = undefined } },
        .{ .find_duplicate = try scriptedPost(8, 30) },
        .{ .list_pull_requests = .{ .command_id = 9, .work_id = 19, .repository = undefined } },
        .{ .copy_clipboard = try scriptedClipboard(10) },
        .{ .external_edit = try scriptedExternalEdit(11) },
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
    try testing.expectEqual(@as(presentation.CommandId, 6), sink.inputs[5].?.submission_wait_completed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 7), sink.inputs[6].?.recovery_checked.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 8), sink.inputs[7].?.duplicate_checked.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 9), sink.inputs[8].?.pull_requests_loaded.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 10), sink.inputs[9].?.clipboard_completed.command_id);
    try testing.expectEqual(@as(presentation.CommandId, 11), sink.inputs[10].?.external_edit_completed.command_id);
}
