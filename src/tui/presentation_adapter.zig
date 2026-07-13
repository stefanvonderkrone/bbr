//! Production execution policy for Presentation commands.
//!
//! Presentation decides which remote action is valid; this adapter performs
//! that action without owning Session or Submission state. Every caller turns
//! the result back into a typed `OwnedInput` for serialized admission.

const bbr = @import("bbr");
const presentation = @import("presentation.zig");

pub fn postOutcome(
    poster: bbr.review.CommentPoster,
    draft: bbr.review.Draft,
    parent: ?bbr.review.CommentId,
    dedupe: bool,
) !bbr.review.PostOutcome {
    if (dedupe) {
        if (try poster.findExisting(draft)) |existing| return .{ .posted = existing };
    }
    return poster.post(draft, parent);
}

/// Consumes `command` whether execution succeeds or fails.
pub fn executePost(command: *presentation.PostDraft, poster: bbr.review.CommentPoster) presentation.OwnedInput {
    defer command.destroy();
    const outcome = postOutcome(poster, command.draft, command.parent, command.dedupe) catch .ambiguous;
    return .{ .post_draft_completed = .{
        .operation_id = command.operation_id,
        .temp_id = command.draft.local_id,
        .outcome = outcome,
    } };
}

const std = @import("std");
const testing = std.testing;

const FakePoster = struct {
    existing: ?bbr.review.CommentId = null,
    posted: bbr.review.PostOutcome = .{ .posted = 900 },
    find_calls: usize = 0,
    post_calls: usize = 0,
    fail_post: bool = false,

    fn poster(self: *FakePoster) bbr.review.CommentPoster {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.review.CommentPoster.VTable = .{
        .post = post,
        .findExisting = findExisting,
    };

    fn post(ptr: *anyopaque, _: bbr.review.Draft, _: ?bbr.review.CommentId) anyerror!bbr.review.PostOutcome {
        const self: *FakePoster = @ptrCast(@alignCast(ptr));
        self.post_calls += 1;
        if (self.fail_post) return error.TransportFailure;
        return self.posted;
    }

    fn findExisting(ptr: *anyopaque, _: bbr.review.Draft) anyerror!?bbr.review.CommentId {
        const self: *FakePoster = @ptrCast(@alignCast(ptr));
        self.find_calls += 1;
        return self.existing;
    }
};

fn testCommand(operation_id: bbr.review.OperationId, dedupe: bool) !*presentation.PostDraft {
    const command = try testing.allocator.create(presentation.PostDraft);
    command.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .operation_id = operation_id,
        .key = try presentation.ReviewKey.init("workspace", "repo", 1),
        .draft = .{ .local_id = 41, .kind = .top_level, .body = "body" },
        .parent = null,
        .dedupe = dedupe,
    };
    return command;
}

test "dedupe hit completes from the existing Comment without another POST" {
    var fake = FakePoster{ .existing = 777 };
    const outcome = try postOutcome(fake.poster(), .{
        .local_id = 1,
        .kind = .top_level,
        .body = "already posted",
    }, null, true);

    try testing.expectEqual(@as(bbr.review.CommentId, 777), outcome.posted);
    try testing.expectEqual(@as(usize, 1), fake.find_calls);
    try testing.expectEqual(@as(usize, 0), fake.post_calls);
}

test "dedupe miss performs the POST" {
    var fake = FakePoster{};
    const outcome = try postOutcome(fake.poster(), .{
        .local_id = 1,
        .kind = .top_level,
        .body = "new comment",
    }, null, true);

    try testing.expectEqual(@as(bbr.review.CommentId, 900), outcome.posted);
    try testing.expectEqual(@as(usize, 1), fake.find_calls);
    try testing.expectEqual(@as(usize, 1), fake.post_calls);
}

test "executePost consumes the command and returns correlated success" {
    var fake = FakePoster{};
    const input = executePost(try testCommand(17, false), fake.poster());

    try testing.expectEqual(@as(bbr.review.OperationId, 17), input.post_draft_completed.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 41), input.post_draft_completed.temp_id);
    try testing.expectEqual(@as(bbr.review.CommentId, 900), input.post_draft_completed.outcome.posted);
}

test "executePost returns correlated ambiguity when execution errors" {
    var fake = FakePoster{ .fail_post = true };
    const input = executePost(try testCommand(23, false), fake.poster());

    try testing.expectEqual(@as(bbr.review.OperationId, 23), input.post_draft_completed.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 41), input.post_draft_completed.temp_id);
    try testing.expect(input.post_draft_completed.outcome == .ambiguous);
}
