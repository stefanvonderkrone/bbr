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

test "deliver transfers a correlated completion to the terminal sink" {
    var capture = CapturingSink{};
    deliver(capture.sink(), .{ .post_draft_launch_failed = .{ .operation_id = 7, .temp_id = 11 } });

    const input = capture.input.?.post_draft_launch_failed;
    try testing.expectEqual(@as(bbr.review.OperationId, 7), input.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 11), input.temp_id);
}

test "deliver owns and disposes a completion rejected during shutdown" {
    var capture = CapturingSink{ .reject = true };
    var input: presentation.OwnedInput = .{ .post_draft_launch_failed = .{ .operation_id = 7, .temp_id = 11 } };
    deliver(capture.sink(), input);
    input = undefined;

    try testing.expect(capture.input == null);
}
