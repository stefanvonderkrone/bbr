//! The write-side review model: `Draft`s and the `PendingReview` graph. A Draft
//! is an authored-but-unpublished Comment/Reply/Suggestion held locally; the
//! whole graph of Drafts for one PullRequest is a PendingReview, persisted via
//! the `PendingReviewStore` so it survives a crash / quit / PR switch.
//!
//! Bitbucket Cloud has no native draft concept (ADR-0002), so this batching is
//! entirely ours: Drafts accumulate here and publish together at Submission (M10).
//! A Reply's parent may be *another Draft* that has no server id yet — this is
//! what forces the topological ordering that submission relies on (design §9).
//!
//! Pure: no network, no disk. `PendingReview` owns a growable list of Drafts in
//! a caller-supplied allocator (the PR-scoped arena in production); Draft bodies
//! and anchor strings are borrowed and must outlive the review. The SQLite store
//! dupes them into its own storage.

const std = @import("std");
const Allocator = std.mem.Allocator;
const comment = @import("comment.zig");
const CommentId = comment.CommentId;
const Anchor = comment.Anchor;
const ApiError = @import("../bitbucket/types.zig").ApiError;

/// A Draft's client-side identifier, assigned by the PendingReview on creation
/// and stable across persistence. Distinct from a server `CommentId`: a reply
/// can point at a TempId (a sibling Draft) before any id has been assigned.
pub const TempId = u64;

/// What role a Draft plays. Mirrors design §6.
pub const DraftKind = enum { top_level, inline_comment, reply, suggestion };

/// Where a Draft lives: `bitbucket` submits on Submission; `local` persists only
/// in SQLite and is never submitted (the offline review mode, M14).
pub const CommentTarget = enum { bitbucket, local };

/// A Draft's lifecycle. `posted` carries the server-assigned id (so a resumed
/// review knows it is already published); `failed` carries the ApiError reason.
/// All four states persist, so a crash mid-submit resumes exactly (design §6).
pub const DraftState = union(enum) {
    draft,
    submitting,
    posted: CommentId,
    failed: ApiError,
};

/// What a Reply attaches to: another pending `Draft` (identified by its TempId,
/// no server id yet) or an already-`posted` Comment (a remote reply).
pub const Parent = union(enum) {
    draft: TempId,
    comment: CommentId,
};

/// An authored-but-unpublished Comment/Reply/Suggestion. `body` and any anchor
/// strings are borrowed (see the file header).
pub const Draft = struct {
    local_id: TempId,
    kind: DraftKind,
    target: CommentTarget = .bitbucket,
    /// The diff location, or null for a PR-level (top-level) Draft.
    anchor: ?Anchor = null,
    /// The comment/draft this replies to, or null for a root Draft.
    parent: ?Parent = null,
    /// Raw markdown body, as authored.
    body: []const u8,
    state: DraftState = .draft,

    pub fn isReply(self: Draft) bool {
        return self.parent != null;
    }

    pub fn isInline(self: Draft) bool {
        return self.anchor != null;
    }

    /// True once the Draft carries a server id (submission succeeded).
    pub fn isPosted(self: Draft) bool {
        return self.state == .posted;
    }
};

/// Fields for a new Draft: everything but the `local_id`, which the review
/// assigns, and `state`, which starts at `.draft`.
pub const NewDraft = struct {
    kind: DraftKind,
    target: CommentTarget = .bitbucket,
    anchor: ?Anchor = null,
    parent: ?Parent = null,
    body: []const u8,
};

/// The whole graph of Drafts for one PullRequest. Owns the Drafts; `add` assigns
/// a monotonic TempId. Reset on PR switch by dropping the backing arena.
pub const PendingReview = struct {
    pr_id: u64,
    drafts: std.ArrayList(Draft) = .empty,
    /// Next TempId to hand out. Kept above every existing id so resumed reviews
    /// (which insert with explicit ids) never collide with fresh Drafts.
    next_id: TempId = 1,

    pub fn init(pr_id: u64) PendingReview {
        return .{ .pr_id = pr_id };
    }

    pub fn deinit(self: *PendingReview, alloc: Allocator) void {
        self.drafts.deinit(alloc);
        self.* = undefined;
    }

    /// Create a Draft, assigning the next TempId, and return that id.
    pub fn add(self: *PendingReview, alloc: Allocator, d: NewDraft) !TempId {
        const id = self.next_id;
        self.next_id += 1;
        try self.drafts.append(alloc, .{
            .local_id = id,
            .kind = d.kind,
            .target = d.target,
            .anchor = d.anchor,
            .parent = d.parent,
            .body = d.body,
        });
        return id;
    }

    /// Append a fully-formed Draft (e.g. one loaded from the store on resume),
    /// keeping `next_id` past its `local_id`.
    pub fn addExisting(self: *PendingReview, alloc: Allocator, d: Draft) !void {
        try self.drafts.append(alloc, d);
        if (d.local_id >= self.next_id) self.next_id = d.local_id + 1;
    }

    /// The Draft with `id`, or null. Mutable so callers can drive state.
    pub fn get(self: *PendingReview, id: TempId) ?*Draft {
        for (self.drafts.items) |*d| {
            if (d.local_id == id) return d;
        }
        return null;
    }

    /// Advance a Draft's lifecycle state. No-op if the id is unknown.
    pub fn setState(self: *PendingReview, id: TempId, state: DraftState) void {
        if (self.get(id)) |d| d.state = state;
    }

    /// Remove a Draft (and, transitively, every Draft that replies to it) so the
    /// graph never dangles. `scratch` backs a short-lived work list. Returns the
    /// number removed (0 on OOM — nothing is partially removed).
    pub fn remove(self: *PendingReview, scratch: Allocator, id: TempId) usize {
        // Collect the id and all its draft-descendants, then filter in place.
        var doomed: std.ArrayList(TempId) = .empty;
        defer doomed.deinit(scratch);
        doomed.append(scratch, id) catch return 0;

        var grew = true;
        while (grew) {
            grew = false;
            for (self.drafts.items) |d| {
                const pid = switch (d.parent orelse continue) {
                    .draft => |p| p,
                    .comment => continue,
                };
                if (contains(doomed.items, pid) and !contains(doomed.items, d.local_id)) {
                    doomed.append(scratch, d.local_id) catch return 0;
                    grew = true;
                }
            }
        }

        var w: usize = 0;
        for (self.drafts.items) |d| {
            if (contains(doomed.items, d.local_id)) continue;
            self.drafts.items[w] = d;
            w += 1;
        }
        const removed = self.drafts.items.len - w;
        self.drafts.shrinkRetainingCapacity(w);
        return removed;
    }

    /// The Drafts in submission order: a Draft that replies to another Draft
    /// always appears *after* its parent (design §9). Roots (top-level, or
    /// replies to an already-posted Comment) keep their insertion order among
    /// themselves. A Draft whose parent-draft is missing, or that sits in a
    /// cycle (malformed), is emitted last rather than dropped — the caller sees
    /// every Draft. Returns TempIds; the slice is owned by `alloc`.
    pub fn topologicalOrder(self: *const PendingReview, alloc: Allocator) ![]TempId {
        const n = self.drafts.items.len;
        var order = try std.ArrayList(TempId).initCapacity(alloc, n);
        errdefer order.deinit(alloc);

        var emitted = try alloc.alloc(bool, n);
        defer alloc.free(emitted);
        @memset(emitted, false);

        // Repeatedly emit any not-yet-emitted Draft whose draft-parent (if any)
        // is already emitted or absent from the set. Each pass emits ≥1 unless
        // only cyclic Drafts remain, so this terminates.
        var progress = true;
        while (progress) {
            progress = false;
            for (self.drafts.items, 0..) |d, i| {
                if (emitted[i]) continue;
                if (self.parentReady(d, emitted)) {
                    order.appendAssumeCapacity(d.local_id);
                    emitted[i] = true;
                    progress = true;
                }
            }
        }
        // Anything left is part of a cycle: emit in insertion order.
        for (self.drafts.items, 0..) |d, i| {
            if (!emitted[i]) order.appendAssumeCapacity(d.local_id);
        }
        return order.toOwnedSlice(alloc);
    }

    /// A Draft is ready to emit when it has no draft-parent, its draft-parent is
    /// not in this review (a stale reference — treat as a root), or that parent
    /// has already been emitted.
    fn parentReady(self: *const PendingReview, d: Draft, emitted: []const bool) bool {
        const pid = switch (d.parent orelse return true) {
            .draft => |p| p,
            .comment => return true,
        };
        for (self.drafts.items, 0..) |other, i| {
            if (other.local_id == pid) return emitted[i];
        }
        return true; // parent not in the set → root-like
    }
};

fn contains(ids: []const TempId, id: TempId) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "add assigns monotonic ids and stores fields" {
    var pr = PendingReview.init(7);
    defer pr.deinit(testing.allocator);

    const a = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "first" });
    const b = try pr.add(testing.allocator, .{ .kind = .inline_comment, .body = "second", .anchor = .{ .path = "f.zig", .to = 10, .commit = "abc" } });
    try testing.expectEqual(@as(TempId, 1), a);
    try testing.expectEqual(@as(TempId, 2), b);
    try testing.expectEqual(@as(usize, 2), pr.drafts.items.len);

    const d = pr.get(b).?;
    try testing.expect(d.isInline());
    try testing.expectEqualStrings("f.zig", d.anchor.?.path);
    try testing.expectEqualStrings("abc", d.anchor.?.commit.?);
    try testing.expect(d.state == .draft);
}

test "setState advances the lifecycle" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const id = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "x" });

    pr.setState(id, .submitting);
    try testing.expect(pr.get(id).?.state == .submitting);
    pr.setState(id, .{ .posted = 4242 });
    try testing.expect(pr.get(id).?.isPosted());
    try testing.expectEqual(@as(CommentId, 4242), pr.get(id).?.state.posted);
    pr.setState(id, .{ .failed = error.RateLimited });
    try testing.expectEqual(ApiError.RateLimited, pr.get(id).?.state.failed);
}

test "addExisting keeps next_id past loaded ids (resume)" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    try pr.addExisting(testing.allocator, .{ .local_id = 5, .kind = .top_level, .body = "loaded" });
    try pr.addExisting(testing.allocator, .{ .local_id = 3, .kind = .top_level, .body = "loaded2" });
    // A fresh draft gets an id above every loaded one.
    const fresh = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "new" });
    try testing.expectEqual(@as(TempId, 6), fresh);
}

test "topological order places a reply after its draft parent" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const root = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "root" });
    const reply = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .draft = root } });
    // Reply to the reply (parent has no server id yet either).
    const reply2 = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re2", .parent = .{ .draft = reply } });

    const order = try pr.topologicalOrder(testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 3), order.len);
    try testing.expect(indexOf(order, root) < indexOf(order, reply));
    try testing.expect(indexOf(order, reply) < indexOf(order, reply2));
}

test "replies to already-posted comments are roots (no reordering needed)" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const a = try pr.add(testing.allocator, .{ .kind = .reply, .body = "to server comment", .parent = .{ .comment = 99 } });
    const b = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "top" });
    const order = try pr.topologicalOrder(testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(a, order[0]);
    try testing.expectEqual(b, order[1]);
}

test "remove takes a draft's reply-descendants with it" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const root = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "root" });
    _ = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .draft = root } });
    const keep = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "unrelated" });

    const removed = pr.remove(testing.allocator, root);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 1), pr.drafts.items.len);
    try testing.expect(pr.get(keep) != null);
    try testing.expect(pr.get(root) == null);
}

fn indexOf(ids: []const TempId, id: TempId) usize {
    for (ids, 0..) |x, i| {
        if (x == id) return i;
    }
    return std.math.maxInt(usize);
}
