//! The `PendingReviewStore` seam: a ptr+vtable interface (same type-erasure
//! idiom as `std.mem.Allocator` / `HttpClient`) that persists Drafts so a
//! PendingReview survives a crash / quit / PR switch (ADR-0002, ADR-0003).
//!
//! The store is a per-Draft repository keyed by
//! `(workspace, repository, pr_id, local_id)`: `put`
//! inserts-or-replaces one Draft, `remove` deletes one, and `load` returns every
//! Draft for a PR. Per-Draft writes mean a crash mid-edit loses at most the
//! Draft being composed. The real implementation is `SqliteStore`; tests and the
//! offline demo use `InMemoryStore`.
//!
//! Ownership: `load` dupes every string into the caller's allocator (the
//! PR-scoped arena), so the returned Drafts outlive the store call. `put` copies
//! what it needs into the store's own storage — the caller keeps its originals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draft_mod = @import("draft.zig");
const Draft = draft_mod.Draft;
const TempId = draft_mod.TempId;
const PendingReview = draft_mod.PendingReview;
const Anchor = @import("comment.zig").Anchor;

/// Durable identity of a Pending Review. Bitbucket PullRequestIds are unique
/// only within a Repository, so every store operation carries the full scope.
pub const ReviewKey = struct {
    workspace: []const u8,
    repository: []const u8,
    pull_request_id: u64,

    pub fn eql(a: ReviewKey, b: ReviewKey) bool {
        return a.pull_request_id == b.pull_request_id and
            std.mem.eql(u8, a.workspace, b.workspace) and
            std.mem.eql(u8, a.repository, b.repository);
    }
};

pub const PendingReviewStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Insert or replace a Draft under `pr_id` (keyed by `draft.local_id`).
        put: *const fn (ptr: *anyopaque, key: ReviewKey, draft: Draft) anyerror!void,
        /// Delete the Draft `(pr_id, local_id)`. Idempotent — a missing id is ok.
        remove: *const fn (ptr: *anyopaque, key: ReviewKey, local_id: TempId) anyerror!void,
        /// Every Draft for `pr_id`, each with its strings duped into `allocator`.
        load: *const fn (ptr: *anyopaque, allocator: Allocator, key: ReviewKey) anyerror![]Draft,
    };

    pub fn put(self: PendingReviewStore, key: ReviewKey, draft: Draft) !void {
        return self.vtable.put(self.ptr, key, draft);
    }

    pub fn remove(self: PendingReviewStore, key: ReviewKey, local_id: TempId) !void {
        return self.vtable.remove(self.ptr, key, local_id);
    }

    pub fn load(self: PendingReviewStore, allocator: Allocator, key: ReviewKey) ![]Draft {
        return self.vtable.load(self.ptr, allocator, key);
    }

    /// Resume: load a PR's Drafts and rebuild the PendingReview graph. Strings
    /// (and the review's backing list) live in `allocator`.
    pub fn loadReview(self: PendingReviewStore, allocator: Allocator, key: ReviewKey) !PendingReview {
        const drafts = try self.load(allocator, key);
        var review = PendingReview.init(key.pull_request_id);
        for (drafts) |d| try review.addExisting(allocator, d);
        return review;
    }
};

/// Deep-copy a Draft's borrowed strings into `alloc`, so the copy is independent
/// of the caller's storage. Shared by every store implementation.
pub fn dupeDraft(alloc: Allocator, d: Draft) !Draft {
    var copy = d;
    copy.body = try alloc.dupe(u8, d.body);
    if (d.anchor) |anchor| copy.anchor = try dupeAnchor(alloc, anchor);
    return copy;
}

fn dupeAnchor(alloc: Allocator, a: Anchor) !Anchor {
    var copy = a;
    copy.path = try alloc.dupe(u8, a.path);
    if (a.commit) |c| copy.commit = try alloc.dupe(u8, c);
    return copy;
}

// ---------------------------------------------------------------------------
// InMemoryStore — the fake. Keeps duped Drafts in its own arena; `load` re-dupes
// into the caller's allocator so results are independent of the store's lifetime.
// ---------------------------------------------------------------------------
pub const InMemoryStore = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),

    const Entry = struct { key: ReviewKey, draft: Draft };

    pub fn init(gpa: Allocator) InMemoryStore {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .entries = .empty };
    }

    pub fn deinit(self: *InMemoryStore) void {
        const gpa = self.arena.child_allocator;
        self.entries.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn store(self: *InMemoryStore) PendingReviewStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: PendingReviewStore.VTable = .{
        .put = putImpl,
        .remove = removeImpl,
        .load = loadImpl,
    };

    fn putImpl(ptr: *anyopaque, key: ReviewKey, d: Draft) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        const owned = try dupeDraft(self.arena.allocator(), d);
        // Replace an existing row with the same key; else append.
        for (self.entries.items) |*e| {
            if (ReviewKey.eql(e.key, key) and e.draft.local_id == d.local_id) {
                e.draft = owned;
                return;
            }
        }
        const owned_key: ReviewKey = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        try self.entries.append(self.arena.child_allocator, .{ .key = owned_key, .draft = owned });
    }

    fn removeImpl(ptr: *anyopaque, key: ReviewKey, local_id: TempId) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (ReviewKey.eql(e.key, key) and e.draft.local_id == local_id) {
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    fn loadImpl(ptr: *anyopaque, allocator: Allocator, key: ReviewKey) anyerror![]Draft {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(Draft) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items) |e| {
            if (ReviewKey.eql(e.key, key)) try out.append(allocator, try dupeDraft(allocator, e.draft));
        }
        return out.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn testReviewKey(pull_request_id: u64) ReviewKey {
    return .{ .workspace = "workspace", .repository = "repo", .pull_request_id = pull_request_id };
}

test "round-trips a draft's fields, anchor, and state through the fake" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();

    try s.put(testReviewKey(7), .{
        .local_id = 1,
        .kind = .inline_comment,
        .anchor = .{ .path = "src/f.zig", .to = 12, .commit = "deadbeef" },
        .body = "needs a test",
        .state = .{ .posted = 555 },
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), testReviewKey(7));

    try testing.expectEqual(@as(usize, 1), drafts.len);
    const d = drafts[0];
    try testing.expectEqual(@as(TempId, 1), d.local_id);
    try testing.expect(d.kind == .inline_comment);
    try testing.expectEqualStrings("needs a test", d.body);
    try testing.expectEqualStrings("src/f.zig", d.anchor.?.path);
    try testing.expectEqual(@as(?u32, 12), d.anchor.?.to);
    try testing.expectEqualStrings("deadbeef", d.anchor.?.commit.?);
    try testing.expectEqual(@as(u64, 555), d.state.posted);
}

test "put replaces the same key; load scopes to the PR" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();

    try s.put(testReviewKey(1), .{ .local_id = 1, .kind = .top_level, .body = "first" });
    try s.put(testReviewKey(1), .{ .local_id = 1, .kind = .top_level, .body = "edited" }); // replace
    try s.put(testReviewKey(1), .{ .local_id = 2, .kind = .top_level, .body = "second" });
    try s.put(testReviewKey(2), .{ .local_id = 1, .kind = .top_level, .body = "other pr" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), testReviewKey(1));
    try testing.expectEqual(@as(usize, 2), drafts.len);
    // The replaced row kept its key and took the new body.
    try testing.expectEqualStrings("edited", drafts[0].body);
    try testing.expectEqualStrings("second", drafts[1].body);
}

test "Pending Reviews with the same PullRequestId are scoped by Repository" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const alpha: ReviewKey = .{ .workspace = "ws", .repository = "alpha", .pull_request_id = 1 };
    const beta: ReviewKey = .{ .workspace = "ws", .repository = "beta", .pull_request_id = 1 };

    try s.put(alpha, .{ .local_id = 1, .kind = .top_level, .body = "alpha draft" });
    try s.put(beta, .{ .local_id = 1, .kind = .top_level, .body = "beta draft" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alpha_drafts = try s.load(arena.allocator(), alpha);
    const beta_drafts = try s.load(arena.allocator(), beta);
    try testing.expectEqualStrings("alpha draft", alpha_drafts[0].body);
    try testing.expectEqualStrings("beta draft", beta_drafts[0].body);
}

test "remove is scoped and idempotent" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    try s.put(testReviewKey(1), .{ .local_id = 1, .kind = .top_level, .body = "a" });
    try s.put(testReviewKey(1), .{ .local_id = 2, .kind = .top_level, .body = "b" });

    try s.remove(testReviewKey(1), 1);
    try s.remove(testReviewKey(1), 1); // idempotent — no error
    try s.remove(testReviewKey(1), 999); // unknown — no error

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), testReviewKey(1));
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(@as(TempId, 2), drafts[0].local_id);
}

test "loadReview rebuilds the graph and next_id for resume" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    try s.put(testReviewKey(1), .{ .local_id = 3, .kind = .top_level, .body = "root" });
    try s.put(testReviewKey(1), .{ .local_id = 8, .kind = .reply, .body = "re", .parent = .{ .draft = 3 } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var review = try s.loadReview(arena.allocator(), testReviewKey(1));

    try testing.expectEqual(@as(usize, 2), review.drafts.items.len);
    try testing.expect(review.get(8).?.isReply());
    // A fresh draft is assigned an id past every loaded one.
    const fresh = try review.add(arena.allocator(), .{ .kind = .top_level, .body = "new" });
    try testing.expectEqual(@as(TempId, 9), fresh);
}
