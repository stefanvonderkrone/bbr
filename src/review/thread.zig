//! Thread building — folds a flat comment list (each carrying a `parent_id`)
//! into the nested `Thread`s the UI displays and collapses.
//!
//! A Thread is a root Comment plus its ordered Replies and a `resolved` flag.
//! Bitbucket returns comments flat; replies point at their parent, which may
//! itself be a reply, so we resolve each comment to its ultimate root and bucket
//! it there. Input order (creation order) is preserved among replies.
//!
//! Zero-copy: `Thread` borrows `*const Comment` into the `comments` slice, which
//! must outlive the threads. Only the backing arrays are allocated — pass an
//! arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const comment = @import("comment.zig");
const Comment = comment.Comment;
const CommentId = comment.CommentId;
const Anchor = comment.Anchor;
const CommentScope = comment.CommentScope;

/// A root Comment together with its ordered Replies. The unit the UI collapses.
/// Resolved Threads hide behind a toggle that reveals the *whole* Thread.
pub const Thread = struct {
    root: *const Comment,
    replies: []const *const Comment,
    resolved: bool,

    /// The diff anchor this thread hangs off (the root's), or null for PR-level.
    pub fn anchor(self: Thread) ?Anchor {
        return switch (self.scope()) {
            .@"inline" => |anc| anc,
            else => null,
        };
    }

    pub fn scope(self: Thread) CommentScope {
        return self.root.effectiveScope();
    }

    pub fn isInline(self: Thread) bool {
        return self.scope() == .@"inline";
    }
};

/// Build the Threads for a flat comment list. Roots keep their input order; each
/// non-root attaches to the root at the top of its `parent_id` chain. A reply
/// whose parent is missing from the set is promoted to a root (defensive — the
/// tree stays a forest, nothing is dropped).
pub fn build(allocator: Allocator, comments: []const Comment) ![]Thread {
    // id → comment, for parent-chain resolution.
    var by_id: std.AutoHashMapUnmanaged(CommentId, *const Comment) = .empty;
    defer by_id.deinit(allocator);
    try by_id.ensureTotalCapacity(allocator, @intCast(comments.len));
    for (comments) |*c| by_id.putAssumeCapacity(c.id, c);

    // root id → index into `threads` (built lazily, preserving first-seen order).
    var thread_of: std.AutoHashMapUnmanaged(CommentId, usize) = .empty;
    defer thread_of.deinit(allocator);

    var threads: std.ArrayList(Thread) = .empty;
    var reply_lists: std.ArrayList(std.ArrayList(*const Comment)) = .empty;
    defer reply_lists.deinit(allocator);

    for (comments) |*c| {
        const root = rootOf(c, by_id);
        if (root == c) {
            // A root comment: open its thread slot — unless a reply seen earlier
            // already created it lazily (out-of-order input), in which case it's
            // already correct (the lazy slot used this same root pointer).
            if (thread_of.contains(c.id)) continue;
            try thread_of.put(allocator, c.id, threads.items.len);
            try threads.append(allocator, .{ .root = c, .replies = &.{}, .resolved = c.resolved });
            try reply_lists.append(allocator, .empty);
        } else {
            // A reply: file it under its root's thread (creating the root's slot
            // first if we haven't seen the root as its own list entry yet — it
            // always appears in `comments`, so this stays a lookup).
            const slot = thread_of.get(root.id) orelse blk: {
                const idx = threads.items.len;
                try thread_of.put(allocator, root.id, idx);
                try threads.append(allocator, .{ .root = root, .replies = &.{}, .resolved = root.resolved });
                try reply_lists.append(allocator, .empty);
                break :blk idx;
            };
            try reply_lists.items[slot].append(allocator, c);
        }
    }

    // Freeze each reply list onto its thread.
    for (threads.items, 0..) |*t, i| {
        t.replies = try reply_lists.items[i].toOwnedSlice(allocator);
    }
    return threads.toOwnedSlice(allocator);
}

/// Walk `parent_id` links to the ultimate root. Stops at a comment with no
/// parent, or whose parent is absent from the set (orphaned reply → its own root).
fn rootOf(c: *const Comment, by_id: std.AutoHashMapUnmanaged(CommentId, *const Comment)) *const Comment {
    var cur = c;
    // Bounded by the comment count — a cycle would be malformed input; the
    // hashmap chain is finite because we never revisit via a strict parent walk.
    while (cur.parent_id) |pid| {
        const parent = by_id.get(pid) orelse return cur;
        cur = parent;
    }
    return cur;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "flat roots become one thread each, in order" {
    const comments = [_]Comment{
        .{ .id = 1, .author = "a", .body = "first" },
        .{ .id = 2, .author = "b", .body = "second" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expectEqual(@as(usize, 2), threads.len);
    try testing.expectEqual(@as(CommentId, 1), threads[0].root.id);
    try testing.expectEqual(@as(usize, 0), threads[0].replies.len);
    try testing.expectEqual(@as(CommentId, 2), threads[1].root.id);
}

test "replies nest under their root in creation order" {
    const comments = [_]Comment{
        .{ .id = 1, .author = "a", .body = "root" },
        .{ .id = 2, .parent_id = 1, .author = "b", .body = "reply 1" },
        .{ .id = 3, .parent_id = 1, .author = "c", .body = "reply 2" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expectEqual(@as(usize, 1), threads.len);
    try testing.expectEqual(@as(usize, 2), threads[0].replies.len);
    try testing.expectEqual(@as(CommentId, 2), threads[0].replies[0].id);
    try testing.expectEqual(@as(CommentId, 3), threads[0].replies[1].id);
}

test "a reply to a reply flattens onto the ultimate root" {
    const comments = [_]Comment{
        .{ .id = 1, .author = "a", .body = "root" },
        .{ .id = 2, .parent_id = 1, .author = "b", .body = "reply" },
        .{ .id = 3, .parent_id = 2, .author = "c", .body = "reply to reply" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expectEqual(@as(usize, 1), threads.len);
    try testing.expectEqual(@as(usize, 2), threads[0].replies.len);
    try testing.expectEqual(@as(CommentId, 3), threads[0].replies[1].id);
}

test "resolved flag comes from the root" {
    const comments = [_]Comment{
        .{ .id = 1, .author = "a", .body = "root", .resolved = true },
        .{ .id = 2, .parent_id = 1, .author = "b", .body = "reply" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expect(threads[0].resolved);
}

test "a reply whose parent is absent is promoted to a root" {
    const comments = [_]Comment{
        .{ .id = 2, .parent_id = 99, .author = "b", .body = "orphan" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expectEqual(@as(usize, 1), threads.len);
    try testing.expectEqual(@as(CommentId, 2), threads[0].root.id);
}

test "a reply seen before its root still nests correctly" {
    // Bitbucket usually returns creation order, but don't rely on it.
    const comments = [_]Comment{
        .{ .id = 2, .parent_id = 1, .author = "b", .body = "reply" },
        .{ .id = 1, .author = "a", .body = "root" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expectEqual(@as(usize, 1), threads.len);
    try testing.expectEqual(@as(CommentId, 1), threads[0].root.id);
    try testing.expectEqual(@as(usize, 1), threads[0].replies.len);
    try testing.expectEqual(@as(CommentId, 2), threads[0].replies[0].id);
}

test "anchor and inline predicate come from the root" {
    const comments = [_]Comment{
        .{ .id = 1, .author = "a", .body = "root", .anchor = .{ .path = "f.zig", .to = 42 } },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const threads = try build(arena.allocator(), &comments);
    try testing.expect(threads[0].isInline());
    try testing.expectEqual(@as(?u32, 42), threads[0].anchor().?.line());
}

test "empty input yields no threads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const threads = try build(arena.allocator(), &.{});
    try testing.expectEqual(@as(usize, 0), threads.len);
}
