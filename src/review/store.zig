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
const DraftState = draft_mod.DraftState;
const TempId = draft_mod.TempId;
const PendingReview = draft_mod.PendingReview;
const comment = @import("comment.zig");
const Anchor = comment.Anchor;
const CommentId = comment.CommentId;
const ApiError = @import("../bitbucket/types.zig").ApiError;

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

pub const OperationId = u64;
pub const ReviewRepositoryId = u64;

/// Source-neutral domain identity. Commit hashes deliberately do not appear:
/// advancing either Ref replaces the Session snapshot, not the Review.
pub const ReviewIdentity = union(enum) {
    remote: struct {
        workspace: []const u8,
        repository: []const u8,
        pull_request_id: u64,
    },
    local: struct {
        repository_id: ReviewRepositoryId,
        base_ref: []const u8,
        source_ref: []const u8,
    },
};

pub const ActiveSubmissionRun = struct {
    operation_id: OperationId,
    key: ReviewKey,
    source_commit: []const u8,
    current_temp_id: ?TempId,
};

/// The durable result of one network post. Keeping this narrower than
/// `DraftState` prevents an invalid checkpoint from moving a completed item
/// back to `.draft` or `.submitting`.
pub const SubmissionOutcome = union(enum) {
    posted: CommentId,
    failed: ApiError,
    outcome_unknown,

    pub fn draftState(self: SubmissionOutcome) DraftState {
        return switch (self) {
            .posted => |id| .{ .posted = id },
            .failed => |err| .{ .failed = err },
            .outcome_unknown => .outcome_unknown,
        };
    }
};

pub const SubmissionPendingState = union(enum) {
    draft,
    failed: ApiError,
    outcome_unknown,

    pub fn draftState(self: SubmissionPendingState) DraftState {
        return switch (self) {
            .draft => .draft,
            .failed => |err| .{ .failed = err },
            .outcome_unknown => .outcome_unknown,
        };
    }
};

pub const SubmissionCompletion = union(enum) {
    /// Every remote Draft posted; transient `.posted` rows can be removed.
    clean,
    /// At least one outcome needs repair; retain every Draft as evidence.
    partial,
    /// An abort produced no item outcome. Restore the in-flight Draft to the
    /// pending state it had before intent was persisted, then close partial.
    aborted: SubmissionPendingState,
};

pub const UnknownResolution = union(enum) {
    posted: CommentId,
    unpublished,
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
        begin_submission: *const fn (ptr: *anyopaque, key: ReviewKey, source_commit: []const u8, first_temp_id: TempId) anyerror!OperationId,
        checkpoint_submission: *const fn (ptr: *anyopaque, operation_id: OperationId, key: ReviewKey, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) anyerror!void,
        complete_submission: *const fn (ptr: *anyopaque, operation_id: OperationId, key: ReviewKey, completion: SubmissionCompletion) anyerror!void,
        active_submission: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!?ActiveSubmissionRun,
        resolve_unknown: *const fn (ptr: *anyopaque, key: ReviewKey, temp_id: TempId, resolution: UnknownResolution) anyerror!void,
        resolve_repository: *const fn (ptr: *anyopaque, aliases: []const []const u8) anyerror!ReviewRepositoryId,
        reserve_temp_id: *const fn (ptr: *anyopaque, key: ReviewKey) anyerror!TempId,
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

    pub fn beginSubmission(self: PendingReviewStore, key: ReviewKey, source_commit: []const u8, first_temp_id: TempId) !OperationId {
        return self.vtable.begin_submission(self.ptr, key, source_commit, first_temp_id);
    }

    pub fn activeSubmission(self: PendingReviewStore, allocator: Allocator) !?ActiveSubmissionRun {
        return self.vtable.active_submission(self.ptr, allocator);
    }

    pub fn resolveUnknown(self: PendingReviewStore, key: ReviewKey, temp_id: TempId, resolution: UnknownResolution) !void {
        return self.vtable.resolve_unknown(self.ptr, key, temp_id, resolution);
    }

    pub fn resolveRepository(self: PendingReviewStore, aliases: []const []const u8) !ReviewRepositoryId {
        return self.vtable.resolve_repository(self.ptr, aliases);
    }

    pub fn reserveTempId(self: PendingReviewStore, key: ReviewKey) !TempId {
        return self.vtable.reserve_temp_id(self.ptr, key);
    }

    /// Persist one post's outcome and the next post intent as one transaction.
    /// No network operation belongs inside this call.
    pub fn checkpointSubmission(self: PendingReviewStore, operation_id: OperationId, key: ReviewKey, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) !void {
        return self.vtable.checkpoint_submission(self.ptr, operation_id, key, completed_temp_id, outcome, next_temp_id);
    }

    pub fn completeSubmission(self: PendingReviewStore, operation_id: OperationId, key: ReviewKey, completion: SubmissionCompletion) !void {
        return self.vtable.complete_submission(self.ptr, operation_id, key, completion);
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
    if (d.snapshot) |snapshot| {
        copy.snapshot = snapshot;
        copy.snapshot.?.text = try alloc.dupe(u8, snapshot.text);
    }
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
    active_submission: ?ActiveSubmissionRun = null,
    next_operation_id: OperationId = 1,
    next_repository_id: ReviewRepositoryId = 1,
    repository_aliases: std.ArrayList(RepositoryAlias) = .empty,
    temp_counters: std.ArrayList(TempCounter) = .empty,
    /// Deterministic adapter fault injection for Presentation checkpoint tests.
    fail_next_checkpoint: bool = false,
    /// Deterministic adapter fault injection after a terminal checkpoint.
    fail_next_completion: bool = false,

    const Entry = struct { key: ReviewKey, draft: Draft };
    const RepositoryAlias = struct { alias: []const u8, repository_id: ReviewRepositoryId };
    const TempCounter = struct { key: ReviewKey, next_id: TempId };

    pub fn init(gpa: Allocator) InMemoryStore {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .entries = .empty };
    }

    pub fn deinit(self: *InMemoryStore) void {
        const gpa = self.arena.child_allocator;
        self.entries.deinit(gpa);
        self.repository_aliases.deinit(gpa);
        self.temp_counters.deinit(gpa);
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
        .begin_submission = beginSubmissionImpl,
        .checkpoint_submission = checkpointSubmissionImpl,
        .complete_submission = completeSubmissionImpl,
        .active_submission = activeSubmissionImpl,
        .resolve_unknown = resolveUnknownImpl,
        .resolve_repository = resolveRepositoryImpl,
        .reserve_temp_id = reserveTempIdImpl,
    };

    fn resolveRepositoryImpl(ptr: *anyopaque, aliases: []const []const u8) anyerror!ReviewRepositoryId {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (aliases.len == 0) return error.NoRepositoryAlias;
        var resolved: ?ReviewRepositoryId = null;
        for (aliases) |alias| for (self.repository_aliases.items) |entry| {
            if (!std.mem.eql(u8, alias, entry.alias)) continue;
            if (resolved != null and resolved.? != entry.repository_id) return error.RepositoryIdentityConflict;
            resolved = entry.repository_id;
        };
        const id = resolved orelse blk: {
            const fresh = self.next_repository_id;
            self.next_repository_id += 1;
            break :blk fresh;
        };
        for (aliases) |alias| {
            var exists = false;
            for (self.repository_aliases.items) |entry| if (std.mem.eql(u8, alias, entry.alias)) {
                exists = true;
                break;
            };
            if (!exists) try self.repository_aliases.append(self.arena.child_allocator, .{
                .alias = try self.arena.allocator().dupe(u8, alias),
                .repository_id = id,
            });
        }
        return id;
    }

    fn reserveTempIdImpl(ptr: *anyopaque, key: ReviewKey) anyerror!TempId {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        for (self.temp_counters.items) |*counter| if (ReviewKey.eql(counter.key, key)) {
            const id = counter.next_id;
            counter.next_id += 1;
            return id;
        };
        var next_id: TempId = 1;
        for (self.entries.items) |entry| {
            if (ReviewKey.eql(entry.key, key)) next_id = @max(next_id, entry.draft.local_id + 1);
        }
        const owned_key: ReviewKey = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        try self.temp_counters.append(self.arena.child_allocator, .{ .key = owned_key, .next_id = next_id + 1 });
        return next_id;
    }

    fn putImpl(ptr: *anyopaque, key: ReviewKey, d: Draft) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        for (self.entries.items) |entry| {
            if (ReviewKey.eql(entry.key, key) and entry.draft.local_id == d.local_id and entry.draft.state == .outcome_unknown)
                return error.DraftLocked;
        }
        if (self.active_submission) |run| {
            if (ReviewKey.eql(run.key, key)) {
                if (d.target == .bitbucket) return error.DraftLocked;
                for (self.entries.items) |entry| {
                    if (ReviewKey.eql(entry.key, key) and entry.draft.local_id == d.local_id and entry.draft.target == .bitbucket)
                        return error.DraftLocked;
                }
            }
        }
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
        for (self.entries.items) |entry| {
            if (ReviewKey.eql(entry.key, key) and entry.draft.local_id == local_id and entry.draft.state == .outcome_unknown)
                return error.DraftLocked;
        }
        if (self.active_submission) |run| {
            if (ReviewKey.eql(run.key, key)) {
                for (self.entries.items) |entry| {
                    if (ReviewKey.eql(entry.key, key) and entry.draft.local_id == local_id and entry.draft.target == .bitbucket)
                        return error.DraftLocked;
                }
            }
        }
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

    fn beginSubmissionImpl(ptr: *anyopaque, key: ReviewKey, source_commit: []const u8, first_temp_id: TempId) anyerror!OperationId {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.active_submission != null) return error.SubmissionAlreadyActive;
        var draft: ?*Draft = null;
        for (self.entries.items) |*entry| {
            if (ReviewKey.eql(entry.key, key) and entry.draft.local_id == first_temp_id) {
                draft = &entry.draft;
                break;
            }
        }
        const first = draft orelse return error.DraftNotFound;
        if (first.target != .bitbucket or (first.state != .draft and first.state != .failed))
            return error.DraftNotSubmittable;
        const owned_key: ReviewKey = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        const owned_commit = try self.arena.allocator().dupe(u8, source_commit);
        const operation_id = self.next_operation_id;
        self.active_submission = .{
            .operation_id = operation_id,
            .key = owned_key,
            .source_commit = owned_commit,
            .current_temp_id = first_temp_id,
        };
        self.next_operation_id += 1;
        first.state = .submitting;
        return operation_id;
    }

    fn activeSubmissionImpl(ptr: *anyopaque, allocator: Allocator) anyerror!?ActiveSubmissionRun {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        const run = self.active_submission orelse return null;
        return .{
            .operation_id = run.operation_id,
            .key = .{
                .workspace = try allocator.dupe(u8, run.key.workspace),
                .repository = try allocator.dupe(u8, run.key.repository),
                .pull_request_id = run.key.pull_request_id,
            },
            .source_commit = try allocator.dupe(u8, run.source_commit),
            .current_temp_id = run.current_temp_id,
        };
    }

    fn resolveUnknownImpl(ptr: *anyopaque, key: ReviewKey, temp_id: TempId, resolution: UnknownResolution) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.active_submission) |run| if (ReviewKey.eql(run.key, key)) return error.DraftLocked;
        for (self.entries.items) |*entry| {
            if (!ReviewKey.eql(entry.key, key) or entry.draft.local_id != temp_id) continue;
            if (entry.draft.state != .outcome_unknown) return error.InvalidUnknownResolution;
            entry.draft.state = switch (resolution) {
                .posted => |id| .{ .posted = id },
                .unpublished => .draft,
            };
            return;
        }
        return error.DraftNotFound;
    }

    fn checkpointSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: ReviewKey, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_checkpoint) {
            self.fail_next_checkpoint = false;
            return error.InjectedCheckpointFailure;
        }
        const run = if (self.active_submission) |*active| active else return error.SubmissionNotActive;
        if (run.operation_id != operation_id or !ReviewKey.eql(run.key, key) or
            run.current_temp_id != completed_temp_id)
            return error.InvalidSubmissionCheckpoint;
        if (next_temp_id == completed_temp_id) return error.InvalidSubmissionCheckpoint;

        var completed: ?*Draft = null;
        var next: ?*Draft = null;
        for (self.entries.items) |*entry| {
            if (!ReviewKey.eql(entry.key, key)) continue;
            if (entry.draft.local_id == completed_temp_id) completed = &entry.draft;
            if (next_temp_id != null and entry.draft.local_id == next_temp_id.?) next = &entry.draft;
        }
        const completed_draft = completed orelse return error.DraftNotFound;
        if (completed_draft.state != .submitting) return error.InvalidSubmissionCheckpoint;
        const next_draft = if (next_temp_id != null) next orelse return error.DraftNotFound else null;
        if (next_draft) |draft| {
            if (draft.target != .bitbucket or (draft.state != .draft and draft.state != .failed))
                return error.InvalidSubmissionCheckpoint;
        }

        completed_draft.state = outcome.draftState();
        if (next_draft) |draft| draft.state = .submitting;
        run.current_temp_id = next_temp_id;
    }

    fn completeSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: ReviewKey, completion: SubmissionCompletion) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_completion) {
            self.fail_next_completion = false;
            return error.InjectedCompletionFailure;
        }
        const run = self.active_submission orelse return error.SubmissionNotActive;
        if (run.operation_id != operation_id or !ReviewKey.eql(run.key, key))
            return error.InvalidSubmissionCompletion;

        switch (completion) {
            .clean => {
                if (run.current_temp_id != null) return error.InvalidSubmissionCompletion;
                for (self.entries.items) |entry| {
                    if (ReviewKey.eql(entry.key, key) and entry.draft.target == .bitbucket and entry.draft.state != .posted)
                        return error.SubmissionNotClean;
                }
                var i: usize = 0;
                while (i < self.entries.items.len) {
                    const entry = self.entries.items[i];
                    if (ReviewKey.eql(entry.key, key) and entry.draft.target == .bitbucket and entry.draft.state == .posted) {
                        _ = self.entries.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },
            .partial => if (run.current_temp_id != null) return error.InvalidSubmissionCompletion,
            .aborted => |restore| {
                const current_id = run.current_temp_id orelse return error.InvalidSubmissionCompletion;
                var current: ?*Draft = null;
                for (self.entries.items) |*entry| {
                    if (ReviewKey.eql(entry.key, key) and entry.draft.local_id == current_id) current = &entry.draft;
                }
                const draft = current orelse return error.DraftNotFound;
                if (draft.state != .submitting) return error.InvalidSubmissionCompletion;
                draft.state = restore.draftState();
            },
        }
        self.active_submission = null;
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

test "beginning a Submission atomically records its run and first submitting Draft" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "first" });
    try store.put(key, .{ .local_id = 2, .kind = .top_level, .body = "second" });

    const operation_id = try store.beginSubmission(key, "source-commit", 1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = (try store.activeSubmission(arena.allocator())).?;
    try testing.expectEqual(operation_id, run.operation_id);
    try testing.expect(ReviewKey.eql(key, run.key));
    try testing.expectEqualStrings("source-commit", run.source_commit);
    try testing.expectEqual(@as(?TempId, 1), run.current_temp_id);

    const drafts = try store.load(arena.allocator(), key);
    try testing.expect(drafts[0].state == .submitting);
    try testing.expect(drafts[1].state == .draft);
}

test "Submission checkpoint persists the outcome and next intent together" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "first" });
    try store.put(key, .{ .local_id = 2, .kind = .top_level, .body = "second", .state = .{ .failed = error.ServerError } });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);

    try store.checkpointSubmission(operation_id, key, 1, .{ .posted = 900 }, 2);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = (try store.activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(?TempId, 2), run.current_temp_id);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqual(@as(u64, 900), drafts[0].state.posted);
    try testing.expect(drafts[1].state == .submitting);
}

test "a rejected Submission checkpoint leaves the run and Draft unchanged" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "first" });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);

    try testing.expectError(error.DraftNotFound, store.checkpointSubmission(operation_id, key, 1, .{ .posted = 900 }, 99));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = (try store.activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(?TempId, 1), run.current_temp_id);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expect(drafts[0].state == .submitting);
}

test "clean Submission completion removes posted Drafts and closes the run" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "posted" });
    try store.put(key, .{ .local_id = 2, .kind = .top_level, .target = .local, .body = "keep local", .state = .{ .posted = 901 } });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);
    try store.checkpointSubmission(operation_id, key, 1, .{ .posted = 900 }, null);

    try store.completeSubmission(operation_id, key, .clean);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(@as(TempId, 2), drafts[0].local_id);
}

test "partial Submission completion keeps outcomes for repair" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "failed" });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);
    try store.checkpointSubmission(operation_id, key, 1, .{ .failed = error.Forbidden }, null);

    try store.completeSubmission(operation_id, key, .partial);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(ApiError.Forbidden, drafts[0].state.failed);
}

test "unresolved outcome remains immutable after partial completion" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "unknown" });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);
    try store.checkpointSubmission(operation_id, key, 1, .outcome_unknown, null);
    try store.completeSubmission(operation_id, key, .partial);

    try testing.expectError(error.DraftLocked, store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "changed" }));
    try testing.expectError(error.DraftLocked, store.remove(key, 1));
    try store.resolveUnknown(key, 1, .unpublished);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "changed" });
}

test "active Submission locks Bitbucket Draft mutation but not local Drafts" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "remote" });
    try store.put(key, .{ .local_id = 2, .kind = .top_level, .target = .local, .body = "local" });
    _ = try store.beginSubmission(key, "source-commit", 1);

    try testing.expectError(error.DraftLocked, store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "changed" }));
    try testing.expectError(error.DraftLocked, store.remove(key, 1));
    try testing.expectError(error.DraftLocked, store.put(key, .{ .local_id = 3, .kind = .top_level, .body = "new remote" }));
    try store.put(key, .{ .local_id = 2, .kind = .top_level, .target = .local, .body = "changed local" });
    try store.remove(key, 2);
}

test "clean completion rejects a Submission with failed Bitbucket Drafts" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "failed" });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);
    try store.checkpointSubmission(operation_id, key, 1, .{ .failed = error.Forbidden }, null);

    try testing.expectError(error.SubmissionNotClean, store.completeSubmission(operation_id, key, .clean));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) != null);
}

test "aborted Submission restores the current Draft and closes partial" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .top_level, .body = "retry", .state = .{ .failed = error.ServerError } });
    const operation_id = try store.beginSubmission(key, "source-commit", 1);

    try store.completeSubmission(operation_id, key, .{ .aborted = .{ .failed = error.ServerError } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqual(ApiError.ServerError, drafts[0].state.failed);
}

test "repository aliases converge on one stable identity and conflicts refuse merging" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const remote = "remote:example.test/team/repo";
    const common = "common:/work/repo/.git";
    const id = try store.resolveRepository(&.{remote});
    try testing.expectEqual(id, try store.resolveRepository(&.{ remote, common }));
    try testing.expectEqual(id, try store.resolveRepository(&.{common}));

    const other = try store.resolveRepository(&.{"remote:example.test/other/repo"});
    try testing.expect(id != other);
    try testing.expectError(error.RepositoryIdentityConflict, store.resolveRepository(&.{ remote, "remote:example.test/other/repo" }));
}

test "TempId reservation is monotonic and gaps remain valid" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(77);
    try testing.expectEqual(@as(TempId, 1), try store.reserveTempId(key));
    try testing.expectEqual(@as(TempId, 2), try store.reserveTempId(key));
    try store.put(key, .{ .local_id = 2, .kind = .top_level, .body = "second" });
    try testing.expectEqual(@as(TempId, 3), try store.reserveTempId(key));
}
