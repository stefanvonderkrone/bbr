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
pub const RemoteReviewIdentity = struct {
    workspace: []const u8,
    repository: []const u8,
    pull_request_id: u64,

    pub fn eql(a: RemoteReviewIdentity, b: RemoteReviewIdentity) bool {
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
    remote: RemoteReviewIdentity,
    local: struct {
        repository_id: ReviewRepositoryId,
        base_ref: []const u8,
        source_ref: []const u8,
    },

    pub fn eql(a: ReviewIdentity, b: ReviewIdentity) bool {
        return switch (a) {
            .remote => |remote| switch (b) {
                .remote => |other| RemoteReviewIdentity.eql(remote, other),
                .local => false,
            },
            .local => |local| switch (b) {
                .remote => false,
                .local => |other| local.repository_id == other.repository_id and
                    std.mem.eql(u8, local.base_ref, other.base_ref) and
                    std.mem.eql(u8, local.source_ref, other.source_ref),
            },
        };
    }
};

pub const ActiveSubmissionRun = struct {
    operation_id: OperationId,
    key: RemoteReviewIdentity,
    source_commit: []const u8,
    current_temp_id: ?TempId,
    items: []SubmissionRunItem,
    retry: ?SubmissionRetryCheckpoint = null,
};

pub const SubmissionRetryPhase = enum { post, publication_check };

pub const SubmissionRetryReason = enum {
    rate_limited,
    server_error,
    ambiguous_post,
    publication_check_rate_limited,
    publication_check_server_error,
    publication_check_transport,
};

pub const SubmissionRetryCheckpoint = struct {
    phase: SubmissionRetryPhase,
    attempt: u8,
    reason: SubmissionRetryReason,
    local_delay_ms: u64,
    server_delay_ms: ?u64,
    effective_delay_ms: u64,
    pending_wait: bool,
};

pub const SubmissionRunItem = struct {
    temp_id: TempId,
    parent: ?draft_mod.Parent,
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

/// A body-only replacement of one existing Draft, applied as one transaction.
/// The expectations are rechecked inside that transaction so an edit staged
/// against a stale in-memory graph is refused instead of overwriting a Draft
/// whose kind or parentage changed underneath it. TempId, kind, parent,
/// CommentScope, Anchor, and AnchorSnapshot all survive the edit; only the
/// body — and a `failed` state, which resets to `draft` — changes.
pub const DraftBodyEdit = struct {
    temp_id: TempId,
    expected_kind: draft_mod.DraftKind,
    expected_parent: ?draft_mod.Parent,
    body: []const u8,
};

/// An Anchor-only replacement of one existing inline root Draft, applied as one
/// transaction. TempId, kind, body, parentage, and every Reply descendant
/// survive; only the Anchor — plus a LocalReview's AnchorSnapshot and a `failed`
/// state, which resets to `draft` — changes. `snapshot` is the replacement
/// captured from the newly selected source: a RemoteReview passes null because
/// it invents no local snapshot.
pub const DraftReanchor = struct {
    temp_id: TempId,
    expected_kind: draft_mod.DraftKind,
    anchor: Anchor,
    snapshot: ?comment.AnchorSnapshot = null,
};

/// The complete deletion of one Draft and every Draft that reaches it through
/// Draft parentage, applied as one transaction. `cascade` is the closure the
/// reviewer was shown and confirmed, root first; the store recomputes it inside
/// the same write and refuses a mismatch, so a cascade staged against a stale
/// graph can neither strand a Reply nor remove evidence nobody confirmed.
pub const DraftSubtreeDelete = struct {
    root_temp_id: TempId,
    expected_parent: ?draft_mod.Parent,
    cascade: []const TempId,
};

pub const DraftEditError = error{
    /// No Draft with that TempId under this ReviewIdentity.
    DraftNotFound,
    /// An active or recovered SubmissionRun owns it, or its publication
    /// outcome is unresolved.
    DraftLocked,
    /// `submitting` or transient `posted`: Bitbucket, not the reviewer, owns
    /// the next transition.
    DraftNotEditable,
    /// The persisted kind or parent relationship is not the one edited.
    DraftEditConflict,
    /// The persisted Draft is not an inline root, so it has no Anchor of its
    /// own to replace: a Reply inherits its root's, and Review- and File-level
    /// scopes are not converted.
    DraftNotAnchorable,
    /// The proposed Anchor is not structurally valid (see `Anchor.validateShape`).
    InvalidAnchor,
    /// The Draft-parentage closure recomputed inside the transaction is not the
    /// one the reviewer confirmed.
    DraftCascadeConflict,
};

pub const PendingReviewStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Insert or replace a Draft under `pr_id` (keyed by `draft.local_id`).
        put: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, draft: Draft) anyerror!void,
        /// Delete the Draft `(pr_id, local_id)`. Idempotent — a missing id is ok.
        remove: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, local_id: TempId) anyerror!void,
        /// Atomically replace one existing Draft's body after rechecking its
        /// identity, expected shape, editable state, and run participation.
        edit_draft_body: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, edit: DraftBodyEdit) anyerror!void,
        /// Atomically replace one inline root Draft's Anchor (and AnchorSnapshot)
        /// after rechecking its identity, root inline shape, editable state, and
        /// run participation.
        reanchor_draft: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, reanchor: DraftReanchor) anyerror!void,
        /// Atomically delete one Draft and its complete Reply-descendant
        /// closure after rechecking identity, expected parentage, that closure,
        /// and every member's eligibility.
        delete_draft_subtree: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, deletion: DraftSubtreeDelete) anyerror!void,
        /// Every Draft for `pr_id`, each with its strings duped into `allocator`.
        load: *const fn (ptr: *anyopaque, allocator: Allocator, key: RemoteReviewIdentity) anyerror![]Draft,
        begin_submission: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, source_commit: []const u8, items: []const SubmissionRunItem) anyerror!OperationId,
        checkpoint_submission: *const fn (ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) anyerror!void,
        checkpoint_submission_retry: *const fn (ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, temp_id: TempId, checkpoint: SubmissionRetryCheckpoint) anyerror!void,
        complete_submission: *const fn (ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, completion: SubmissionCompletion) anyerror!void,
        abandon_submission: *const fn (ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity) anyerror!void,
        active_submission: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!?ActiveSubmissionRun,
        resolve_unknown: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity, temp_id: TempId, resolution: UnknownResolution) anyerror!void,
        resolve_repository: *const fn (ptr: *anyopaque, aliases: []const []const u8) anyerror!ReviewRepositoryId,
        reserve_temp_id: *const fn (ptr: *anyopaque, key: RemoteReviewIdentity) anyerror!TempId,
    };

    pub fn put(self: PendingReviewStore, key: RemoteReviewIdentity, draft: Draft) !void {
        return self.vtable.put(self.ptr, key, draft);
    }

    pub fn remove(self: PendingReviewStore, key: RemoteReviewIdentity, local_id: TempId) !void {
        return self.vtable.remove(self.ptr, key, local_id);
    }

    /// Replace `edit.temp_id`'s body. A `failed` Draft returns to `draft`,
    /// because a changed body is a new attempt rather than the failed one.
    pub fn editDraftBody(self: PendingReviewStore, key: RemoteReviewIdentity, edit: DraftBodyEdit) !void {
        return self.vtable.edit_draft_body(self.ptr, key, edit);
    }

    /// Replace `reanchor.temp_id`'s Anchor. Like a body edit, a real change is
    /// a new attempt, so a `failed` Draft returns to `draft`; the Reply subtree
    /// is untouched because parentage, not a copied scope, places it.
    pub fn reanchorDraft(self: PendingReviewStore, key: RemoteReviewIdentity, reanchor: DraftReanchor) !void {
        return self.vtable.reanchor_draft(self.ptr, key, reanchor);
    }

    /// Delete `deletion.root_temp_id` together with every Draft that reaches it
    /// through Draft parentage. Unlike `remove`, which takes one row on trust,
    /// this refuses unless the whole confirmed subtree is present and every
    /// member is eligible — a partial cascade would strand a Reply.
    pub fn deleteDraftSubtree(self: PendingReviewStore, key: RemoteReviewIdentity, deletion: DraftSubtreeDelete) !void {
        return self.vtable.delete_draft_subtree(self.ptr, key, deletion);
    }

    pub fn load(self: PendingReviewStore, allocator: Allocator, key: RemoteReviewIdentity) ![]Draft {
        return self.vtable.load(self.ptr, allocator, key);
    }

    pub fn beginSubmission(self: PendingReviewStore, key: RemoteReviewIdentity, source_commit: []const u8, items: []const SubmissionRunItem) !OperationId {
        return self.vtable.begin_submission(self.ptr, key, source_commit, items);
    }

    pub fn activeSubmission(self: PendingReviewStore, allocator: Allocator) !?ActiveSubmissionRun {
        return self.vtable.active_submission(self.ptr, allocator);
    }

    pub fn resolveUnknown(self: PendingReviewStore, key: RemoteReviewIdentity, temp_id: TempId, resolution: UnknownResolution) !void {
        return self.vtable.resolve_unknown(self.ptr, key, temp_id, resolution);
    }

    pub fn resolveRepository(self: PendingReviewStore, aliases: []const []const u8) !ReviewRepositoryId {
        return self.vtable.resolve_repository(self.ptr, aliases);
    }

    pub fn reserveTempId(self: PendingReviewStore, key: RemoteReviewIdentity) !TempId {
        return self.vtable.reserve_temp_id(self.ptr, key);
    }

    /// Persist one post's outcome and the next post intent as one transaction.
    /// No network operation belongs inside this call.
    pub fn checkpointSubmission(self: PendingReviewStore, operation_id: OperationId, key: RemoteReviewIdentity, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) !void {
        return self.vtable.checkpoint_submission(self.ptr, operation_id, key, completed_temp_id, outcome, next_temp_id);
    }

    pub fn checkpointSubmissionRetry(self: PendingReviewStore, operation_id: OperationId, key: RemoteReviewIdentity, temp_id: TempId, checkpoint: SubmissionRetryCheckpoint) !void {
        return self.vtable.checkpoint_submission_retry(self.ptr, operation_id, key, temp_id, checkpoint);
    }

    pub fn completeSubmission(self: PendingReviewStore, operation_id: OperationId, key: RemoteReviewIdentity, completion: SubmissionCompletion) !void {
        return self.vtable.complete_submission(self.ptr, operation_id, key, completion);
    }

    /// Terminalize recovered ambiguous work without asserting non-publication.
    pub fn abandonSubmission(self: PendingReviewStore, operation_id: OperationId, key: RemoteReviewIdentity) !void {
        return self.vtable.abandon_submission(self.ptr, operation_id, key);
    }

    /// Resume: load a PR's Drafts and rebuild the PendingReview graph. Strings
    /// (and the review's backing list) live in `allocator`.
    pub fn loadReview(self: PendingReviewStore, allocator: Allocator, key: RemoteReviewIdentity) !PendingReview {
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
    if (d.scope) |scope| copy.scope = switch (scope) {
        .review => .review,
        .file => |file| .{ .file = .{
            .path = try alloc.dupe(u8, file.path),
            .source_commit = try alloc.dupe(u8, file.source_commit),
        } },
        .@"inline" => |anchor| .{ .@"inline" = try dupeAnchor(alloc, anchor) },
    };
    if (d.anchor) |anchor| copy.anchor = try dupeAnchor(alloc, anchor);
    if (d.snapshot) |snapshot| {
        copy.snapshot = snapshot;
        copy.snapshot.?.text = try alloc.dupe(u8, snapshot.text);
    }
    return copy;
}

test "ReviewIdentity equality distinguishes remote and local Reviews by canonical identity" {
    const remote: ReviewIdentity = .{ .remote = .{
        .workspace = "workspace",
        .repository = "repo",
        .pull_request_id = 7,
    } };
    const same_remote: ReviewIdentity = .{ .remote = .{
        .workspace = "workspace",
        .repository = "repo",
        .pull_request_id = 7,
    } };
    const other_repository: ReviewIdentity = .{ .remote = .{
        .workspace = "workspace",
        .repository = "other",
        .pull_request_id = 7,
    } };
    const local: ReviewIdentity = .{ .local = .{
        .repository_id = 3,
        .base_ref = "refs/heads/main",
        .source_ref = "refs/heads/feature",
    } };
    const same_local: ReviewIdentity = .{ .local = .{
        .repository_id = 3,
        .base_ref = "refs/heads/main",
        .source_ref = "refs/heads/feature",
    } };

    try std.testing.expect(ReviewIdentity.eql(remote, same_remote));
    try std.testing.expect(!ReviewIdentity.eql(remote, other_repository));
    try std.testing.expect(!ReviewIdentity.eql(remote, local));
    try std.testing.expect(ReviewIdentity.eql(local, same_local));
}

test "retry checkpoints round-trip and terminal guidance carries into a fresh budget" {
    var memory = InMemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    const store = memory.store();
    const key = testReviewKey(99);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "retry" });
    const operation_id = try store.beginSubmission(key, "source", &.{.{ .temp_id = 1, .parent = null }});
    const terminal: SubmissionRetryCheckpoint = .{
        .phase = .post,
        .attempt = 3,
        .reason = .rate_limited,
        .local_delay_ms = 0,
        .server_delay_ms = 4_000,
        .effective_delay_ms = 4_000,
        .pending_wait = false,
    };
    try store.checkpointSubmissionRetry(operation_id, key, 1, terminal);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualDeep(terminal, (try store.activeSubmission(arena.allocator())).?.retry.?);
    try store.checkpointSubmission(operation_id, key, 1, .{ .failed = error.RateLimited }, null);
    try store.completeSubmission(operation_id, key, .partial);

    const fresh_id = try store.beginSubmission(key, "source", &.{.{ .temp_id = 1, .parent = null }});
    const fresh = (try store.activeSubmission(arena.allocator())).?;
    try std.testing.expectEqual(fresh_id, fresh.operation_id);
    try std.testing.expectEqual(@as(u8, 0), fresh.retry.?.attempt);
    try std.testing.expectEqual(@as(?u64, 4_000), fresh.retry.?.server_delay_ms);
    try std.testing.expect(fresh.retry.?.pending_wait);
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
    retry_carryovers: std.ArrayList(RetryCarryover) = .empty,
    next_operation_id: OperationId = 1,
    next_repository_id: ReviewRepositoryId = 1,
    repository_aliases: std.ArrayList(RepositoryAlias) = .empty,
    temp_counters: std.ArrayList(TempCounter) = .empty,
    /// Deterministic adapter fault injection for Presentation edit tests.
    fail_next_edit: bool = false,
    /// Deterministic adapter fault injection for Presentation re-anchor tests.
    fail_next_reanchor: bool = false,
    /// Deterministic adapter fault injection for Presentation delete tests.
    fail_next_delete: bool = false,
    /// Deterministic adapter fault injection for Presentation checkpoint tests.
    fail_next_checkpoint: bool = false,
    /// Deterministic adapter fault injection after a terminal checkpoint.
    fail_next_completion: bool = false,

    const Entry = struct { key: RemoteReviewIdentity, draft: Draft };
    const RepositoryAlias = struct { alias: []const u8, repository_id: ReviewRepositoryId };
    const TempCounter = struct { key: RemoteReviewIdentity, next_id: TempId };
    const RetryCarryover = struct { key: RemoteReviewIdentity, temp_id: TempId, checkpoint: SubmissionRetryCheckpoint };

    pub fn init(gpa: Allocator) InMemoryStore {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .entries = .empty };
    }

    pub fn deinit(self: *InMemoryStore) void {
        const gpa = self.arena.child_allocator;
        self.entries.deinit(gpa);
        self.repository_aliases.deinit(gpa);
        self.temp_counters.deinit(gpa);
        self.retry_carryovers.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn store(self: *InMemoryStore) PendingReviewStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: PendingReviewStore.VTable = .{
        .put = putImpl,
        .remove = removeImpl,
        .edit_draft_body = editDraftBodyImpl,
        .reanchor_draft = reanchorDraftImpl,
        .delete_draft_subtree = deleteDraftSubtreeImpl,
        .load = loadImpl,
        .begin_submission = beginSubmissionImpl,
        .checkpoint_submission = checkpointSubmissionImpl,
        .checkpoint_submission_retry = checkpointSubmissionRetryImpl,
        .complete_submission = completeSubmissionImpl,
        .abandon_submission = abandonSubmissionImpl,
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

    fn reserveTempIdImpl(ptr: *anyopaque, key: RemoteReviewIdentity) anyerror!TempId {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        for (self.temp_counters.items) |*counter| if (RemoteReviewIdentity.eql(counter.key, key)) {
            const id = counter.next_id;
            counter.next_id += 1;
            return id;
        };
        var next_id: TempId = 1;
        for (self.entries.items) |entry| {
            if (RemoteReviewIdentity.eql(entry.key, key)) next_id = @max(next_id, entry.draft.local_id + 1);
        }
        const owned_key: RemoteReviewIdentity = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        try self.temp_counters.append(self.arena.child_allocator, .{ .key = owned_key, .next_id = next_id + 1 });
        return next_id;
    }

    fn putImpl(ptr: *anyopaque, key: RemoteReviewIdentity, d: Draft) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        for (self.entries.items) |entry| {
            if (RemoteReviewIdentity.eql(entry.key, key) and entry.draft.local_id == d.local_id and entry.draft.state == .outcome_unknown)
                return error.DraftLocked;
        }
        if (self.active_submission) |run| {
            if (RemoteReviewIdentity.eql(run.key, key)) {
                if (submissionItemIndex(run.items, d.local_id) != null) return error.DraftLocked;
            }
        }
        const owned = try dupeDraft(self.arena.allocator(), d);
        // Replace an existing row with the same key; else append.
        for (self.entries.items) |*e| {
            if (RemoteReviewIdentity.eql(e.key, key) and e.draft.local_id == d.local_id) {
                e.draft = owned;
                return;
            }
        }
        const owned_key: RemoteReviewIdentity = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        try self.entries.append(self.arena.child_allocator, .{ .key = owned_key, .draft = owned });
    }

    fn removeImpl(ptr: *anyopaque, key: RemoteReviewIdentity, local_id: TempId) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        for (self.entries.items) |entry| {
            if (RemoteReviewIdentity.eql(entry.key, key) and entry.draft.local_id == local_id and entry.draft.state == .outcome_unknown)
                return error.DraftLocked;
        }
        if (self.active_submission) |run| {
            if (RemoteReviewIdentity.eql(run.key, key)) {
                if (submissionItemIndex(run.items, local_id) != null) return error.DraftLocked;
            }
        }
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (RemoteReviewIdentity.eql(e.key, key) and e.draft.local_id == local_id) {
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    fn editDraftBodyImpl(ptr: *anyopaque, key: RemoteReviewIdentity, edit: DraftBodyEdit) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_edit) {
            self.fail_next_edit = false;
            return error.InjectedEditFailure;
        }
        // Everything below is one check-and-replace step: nothing between the
        // rechecks can observe a partially edited Draft.
        if (self.active_submission) |run| {
            if (RemoteReviewIdentity.eql(run.key, key) and submissionItemIndex(run.items, edit.temp_id) != null)
                return error.DraftLocked;
        }
        for (self.entries.items) |*entry| {
            if (!RemoteReviewIdentity.eql(entry.key, key) or entry.draft.local_id != edit.temp_id) continue;
            if (entry.draft.state == .outcome_unknown) return error.DraftLocked;
            switch (entry.draft.state) {
                .draft, .failed => {},
                .submitting, .posted => return error.DraftNotEditable,
                .outcome_unknown => unreachable,
            }
            if (entry.draft.kind != edit.expected_kind) return error.DraftEditConflict;
            if (!parentEql(entry.draft.parent, edit.expected_parent)) return error.DraftEditConflict;
            const owned_body = try self.arena.allocator().dupe(u8, edit.body);
            entry.draft.body = owned_body;
            if (entry.draft.state == .failed) entry.draft.state = .draft;
            return;
        }
        return error.DraftNotFound;
    }

    fn reanchorDraftImpl(ptr: *anyopaque, key: RemoteReviewIdentity, reanchor: DraftReanchor) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_reanchor) {
            self.fail_next_reanchor = false;
            return error.InjectedReanchorFailure;
        }
        reanchor.anchor.validateShape() catch return error.InvalidAnchor;
        // One check-and-replace step, like a body edit: no partially re-anchored
        // Draft is observable between the rechecks and the replacement.
        if (self.active_submission) |run| {
            if (RemoteReviewIdentity.eql(run.key, key) and submissionItemIndex(run.items, reanchor.temp_id) != null)
                return error.DraftLocked;
        }
        for (self.entries.items) |*entry| {
            if (!RemoteReviewIdentity.eql(entry.key, key) or entry.draft.local_id != reanchor.temp_id) continue;
            switch (entry.draft.state) {
                .draft, .failed => {},
                .submitting, .posted => return error.DraftNotEditable,
                .outcome_unknown => return error.DraftLocked,
            }
            if (entry.draft.kind != reanchor.expected_kind) return error.DraftEditConflict;
            if (entry.draft.parent != null or entry.draft.effectiveScope() != .@"inline") return error.DraftNotAnchorable;
            // Bitbucket refuses to apply a Suggestion over removed lines.
            if (entry.draft.kind == .suggestion and reanchor.anchor.to == null) return error.InvalidAnchor;

            const arena = self.arena.allocator();
            var owned = reanchor.anchor;
            owned.path = try arena.dupe(u8, reanchor.anchor.path);
            if (reanchor.anchor.commit) |commit| owned.commit = try arena.dupe(u8, commit);
            const owned_snapshot: ?comment.AnchorSnapshot = if (reanchor.snapshot) |snapshot| .{
                .text = try arena.dupe(u8, snapshot.text),
                .selection_start = snapshot.selection_start,
                .selection_len = snapshot.selection_len,
            } else null;
            entry.draft.scope = .{ .@"inline" = owned };
            entry.draft.anchor = owned;
            entry.draft.snapshot = owned_snapshot;
            if (entry.draft.state == .failed) entry.draft.state = .draft;
            return;
        }
        return error.DraftNotFound;
    }

    fn deleteDraftSubtreeImpl(ptr: *anyopaque, key: RemoteReviewIdentity, deletion: DraftSubtreeDelete) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_delete) {
            self.fail_next_delete = false;
            return error.InjectedDeleteFailure;
        }
        try validateCascadeShape(deletion);
        // One check-and-delete step: the closure, the expectations, and every
        // eligibility rule are rechecked here, against this store's own rows.
        const root = self.draftEntry(key, deletion.root_temp_id) orelse return error.DraftNotFound;
        if (!parentEql(root.parent, deletion.expected_parent)) return error.DraftEditConflict;

        var members: usize = 0;
        for (self.entries.items) |candidate| {
            if (!RemoteReviewIdentity.eql(candidate.key, key)) continue;
            if (!self.descendsFrom(key, deletion.root_temp_id, candidate.draft.local_id)) continue;
            members += 1;
        }
        if (members != deletion.cascade.len) return error.DraftCascadeConflict;
        for (deletion.cascade) |temp_id| {
            if (self.draftEntry(key, temp_id) == null) return error.DraftCascadeConflict;
            if (!self.descendsFrom(key, deletion.root_temp_id, temp_id)) return error.DraftCascadeConflict;
        }

        // Ambiguous or run-owned evidence refuses the whole cascade; nothing
        // below this point can remove part of it.
        if (self.active_submission) |run| {
            if (RemoteReviewIdentity.eql(run.key, key))
                for (deletion.cascade) |temp_id| if (submissionItemIndex(run.items, temp_id) != null) return error.DraftLocked;
        }
        for (deletion.cascade) |temp_id| {
            const member = self.draftEntry(key, temp_id).?;
            switch (member.state) {
                .draft, .failed => {},
                .outcome_unknown => return error.DraftLocked,
                .submitting, .posted => return error.DraftNotEditable,
            }
        }

        // A TempId is never reused. Without this, a review whose ids were only
        // ever derived from MAX(local_id) — every resumed review — hands the
        // deleted root's id straight back to the next authored Draft.
        try self.retainTempIdFloor(key);
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const candidate = self.entries.items[index];
            if (RemoteReviewIdentity.eql(candidate.key, key) and containsTempId(deletion.cascade, candidate.draft.local_id)) {
                _ = self.entries.orderedRemove(index);
            } else index += 1;
        }
    }

    /// Pin the reservation counter at or above every id currently in use, so a
    /// later delete cannot lower the floor it derives from.
    fn retainTempIdFloor(self: *InMemoryStore, key: RemoteReviewIdentity) !void {
        var floor: TempId = 1;
        for (self.entries.items) |candidate| {
            if (RemoteReviewIdentity.eql(candidate.key, key)) floor = @max(floor, candidate.draft.local_id + 1);
        }
        for (self.temp_counters.items) |*counter| if (RemoteReviewIdentity.eql(counter.key, key)) {
            counter.next_id = @max(counter.next_id, floor);
            return;
        };
        const owned_key: RemoteReviewIdentity = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        try self.temp_counters.append(self.arena.child_allocator, .{ .key = owned_key, .next_id = floor });
    }

    fn draftEntry(self: *InMemoryStore, key: RemoteReviewIdentity, temp_id: TempId) ?*Draft {
        for (self.entries.items) |*candidate| {
            if (RemoteReviewIdentity.eql(candidate.key, key) and candidate.draft.local_id == temp_id) return &candidate.draft;
        }
        return null;
    }

    /// `draft_mod.descendsFrom` over this store's rows: walking up the parent
    /// chain needs no allocation, and a malformed cycle terminates.
    fn descendsFrom(self: *InMemoryStore, key: RemoteReviewIdentity, root: TempId, temp_id: TempId) bool {
        var current = temp_id;
        var hops: usize = 0;
        while (hops <= self.entries.items.len) : (hops += 1) {
            if (current == root) return true;
            const found = self.draftEntry(key, current) orelse return false;
            current = switch (found.parent orelse return false) {
                .draft => |parent_id| parent_id,
                .comment => return false,
            };
        }
        return false;
    }

    fn loadImpl(ptr: *anyopaque, allocator: Allocator, key: RemoteReviewIdentity) anyerror![]Draft {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(Draft) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items) |e| {
            if (RemoteReviewIdentity.eql(e.key, key)) try out.append(allocator, try dupeDraft(allocator, e.draft));
        }
        return out.toOwnedSlice(allocator);
    }

    fn beginSubmissionImpl(ptr: *anyopaque, key: RemoteReviewIdentity, source_commit: []const u8, items: []const SubmissionRunItem) anyerror!OperationId {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.active_submission != null) return error.SubmissionAlreadyActive;
        if (items.len == 0) return error.EmptySubmission;
        const first_temp_id = items[0].temp_id;
        for (items, 0..) |item, index| {
            var found = false;
            for (self.entries.items) |entry| {
                if (!RemoteReviewIdentity.eql(entry.key, key) or entry.draft.local_id != item.temp_id) continue;
                if (entry.draft.target != .bitbucket) return error.DraftNotSubmittable;
                if (!parentEql(entry.draft.parent, item.parent)) return error.InvalidSubmissionGraph;
                found = true;
                break;
            }
            if (!found) return error.DraftNotFound;
            for (items[0..index]) |prior| if (prior.temp_id == item.temp_id) return error.InvalidSubmissionGraph;
        }
        var draft: ?*Draft = null;
        for (self.entries.items) |*entry| {
            if (RemoteReviewIdentity.eql(entry.key, key) and entry.draft.local_id == first_temp_id) {
                draft = &entry.draft;
                break;
            }
        }
        const first = draft orelse return error.DraftNotFound;
        if (first.target != .bitbucket or (first.state != .draft and first.state != .failed))
            return error.DraftNotSubmittable;
        const owned_key: RemoteReviewIdentity = .{
            .workspace = try self.arena.allocator().dupe(u8, key.workspace),
            .repository = try self.arena.allocator().dupe(u8, key.repository),
            .pull_request_id = key.pull_request_id,
        };
        const owned_commit = try self.arena.allocator().dupe(u8, source_commit);
        const owned_items = try self.arena.allocator().dupe(SubmissionRunItem, items);
        const operation_id = self.next_operation_id;
        self.active_submission = .{
            .operation_id = operation_id,
            .key = owned_key,
            .source_commit = owned_commit,
            .current_temp_id = first_temp_id,
            .items = owned_items,
        };
        for (self.retry_carryovers.items, 0..) |carry, index| if (RemoteReviewIdentity.eql(carry.key, key) and carry.temp_id == first_temp_id and carry.checkpoint.server_delay_ms != null) {
            const delay = carry.checkpoint.server_delay_ms.?;
            self.active_submission.?.retry = .{
                .phase = .post,
                .attempt = 0,
                .reason = carry.checkpoint.reason,
                .local_delay_ms = 0,
                .server_delay_ms = delay,
                .effective_delay_ms = delay,
                .pending_wait = true,
            };
            _ = self.retry_carryovers.orderedRemove(index);
            break;
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
            .items = try allocator.dupe(SubmissionRunItem, run.items),
            .retry = run.retry,
        };
    }

    fn checkpointSubmissionRetryImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, temp_id: TempId, checkpoint: SubmissionRetryCheckpoint) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_checkpoint) {
            self.fail_next_checkpoint = false;
            return error.InjectedCheckpointFailure;
        }
        const run = if (self.active_submission) |*active| active else return error.SubmissionNotActive;
        if (run.operation_id != operation_id or !RemoteReviewIdentity.eql(run.key, key) or run.current_temp_id != temp_id)
            return error.InvalidSubmissionCheckpoint;
        if (checkpoint.effective_delay_ms != @max(checkpoint.local_delay_ms, checkpoint.server_delay_ms orelse 0))
            return error.InvalidSubmissionCheckpoint;
        run.retry = checkpoint;
    }

    fn resolveUnknownImpl(ptr: *anyopaque, key: RemoteReviewIdentity, temp_id: TempId, resolution: UnknownResolution) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.active_submission) |run| if (RemoteReviewIdentity.eql(run.key, key) and submissionItemIndex(run.items, temp_id) != null) return error.DraftLocked;
        for (self.entries.items) |*entry| {
            if (!RemoteReviewIdentity.eql(entry.key, key) or entry.draft.local_id != temp_id) continue;
            if (entry.draft.state != .outcome_unknown) return error.InvalidUnknownResolution;
            entry.draft.state = switch (resolution) {
                .posted => |id| .{ .posted = id },
                .unpublished => .draft,
            };
            return;
        }
        return error.DraftNotFound;
    }

    fn checkpointSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_checkpoint) {
            self.fail_next_checkpoint = false;
            return error.InjectedCheckpointFailure;
        }
        const run = if (self.active_submission) |*active| active else return error.SubmissionNotActive;
        if (run.operation_id != operation_id or !RemoteReviewIdentity.eql(run.key, key) or
            run.current_temp_id != completed_temp_id)
            return error.InvalidSubmissionCheckpoint;
        if (next_temp_id == completed_temp_id) return error.InvalidSubmissionCheckpoint;
        if (next_temp_id) |next_id| {
            const completed_index = submissionItemIndex(run.items, completed_temp_id) orelse return error.InvalidSubmissionCheckpoint;
            const next_index = submissionItemIndex(run.items, next_id) orelse return error.InvalidSubmissionCheckpoint;
            if (next_index <= completed_index) return error.InvalidSubmissionCheckpoint;
        }

        var completed: ?*Draft = null;
        var next: ?*Draft = null;
        for (self.entries.items) |*entry| {
            if (!RemoteReviewIdentity.eql(entry.key, key)) continue;
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
        if (outcome == .failed and run.retry != null and !run.retry.?.pending_wait and run.retry.?.server_delay_ms != null) {
            var retained = false;
            for (self.retry_carryovers.items) |*carry| if (RemoteReviewIdentity.eql(carry.key, run.key) and carry.temp_id == completed_temp_id) {
                carry.checkpoint = run.retry.?;
                retained = true;
                break;
            };
            if (!retained) try self.retry_carryovers.append(self.arena.child_allocator, .{
                .key = run.key,
                .temp_id = completed_temp_id,
                .checkpoint = run.retry.?,
            });
        }
        run.current_temp_id = next_temp_id;
        run.retry = null;
    }

    fn completeSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, completion: SubmissionCompletion) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        if (self.fail_next_completion) {
            self.fail_next_completion = false;
            return error.InjectedCompletionFailure;
        }
        const run = self.active_submission orelse return error.SubmissionNotActive;
        if (run.operation_id != operation_id or !RemoteReviewIdentity.eql(run.key, key))
            return error.InvalidSubmissionCompletion;

        switch (completion) {
            .clean => {
                if (run.current_temp_id != null) return error.InvalidSubmissionCompletion;
                for (run.items) |item| {
                    for (self.entries.items) |entry| if (RemoteReviewIdentity.eql(entry.key, key) and entry.draft.local_id == item.temp_id and entry.draft.state != .posted)
                        return error.SubmissionNotClean;
                }
                var i: usize = 0;
                while (i < self.entries.items.len) {
                    const entry = self.entries.items[i];
                    if (RemoteReviewIdentity.eql(entry.key, key) and submissionItemIndex(run.items, entry.draft.local_id) != null and entry.draft.state == .posted) {
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
                    if (RemoteReviewIdentity.eql(entry.key, key) and entry.draft.local_id == current_id) current = &entry.draft;
                }
                const draft = current orelse return error.DraftNotFound;
                if (draft.state != .submitting) return error.InvalidSubmissionCompletion;
                draft.state = restore.draftState();
            },
        }
        self.active_submission = null;
    }

    fn abandonSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity) anyerror!void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ptr));
        const run = self.active_submission orelse return error.SubmissionNotActive;
        if (run.operation_id != operation_id or !RemoteReviewIdentity.eql(run.key, key)) return error.InvalidSubmissionCompletion;
        const current_id = run.current_temp_id orelse return error.InvalidSubmissionCompletion;
        for (self.entries.items) |*entry| {
            if (!RemoteReviewIdentity.eql(entry.key, key) or entry.draft.local_id != current_id) continue;
            if (entry.draft.state != .submitting) return error.InvalidSubmissionCompletion;
            entry.draft.state = .outcome_unknown;
            self.active_submission = null;
            return;
        }
        return error.DraftNotFound;
    }
};

/// Structural parent equality, shared by every store adapter so a persisted
/// Draft's parentage is compared identically wherever it is rechecked.
pub fn parentEql(a: ?draft_mod.Parent, b: ?draft_mod.Parent) bool {
    if (a == null or b == null) return a == null and b == null;
    return switch (a.?) {
        .draft => |id| b.? == .draft and b.?.draft == id,
        .comment => |id| b.? == .comment and b.?.comment == id,
    };
}

/// The caller-side shape every adapter demands of a confirmed cascade before it
/// touches a row: non-empty, rooted at the Draft being deleted, and free of
/// duplicates. Shared so a malformed cascade is rejected identically everywhere.
pub fn validateCascadeShape(deletion: DraftSubtreeDelete) error{DraftCascadeConflict}!void {
    if (deletion.cascade.len == 0) return error.DraftCascadeConflict;
    if (deletion.cascade[0] != deletion.root_temp_id) return error.DraftCascadeConflict;
    for (deletion.cascade, 0..) |temp_id, index| {
        if (containsTempId(deletion.cascade[0..index], temp_id)) return error.DraftCascadeConflict;
    }
}

pub fn containsTempId(ids: []const TempId, temp_id: TempId) bool {
    for (ids) |candidate| if (candidate == temp_id) return true;
    return false;
}

fn submissionItemIndex(items: []const SubmissionRunItem, temp_id: TempId) ?usize {
    for (items, 0..) |item, index| if (item.temp_id == temp_id) return index;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn testReviewKey(pull_request_id: u64) RemoteReviewIdentity {
    return .{ .workspace = "workspace", .repository = "repo", .pull_request_id = pull_request_id };
}

test "round-trips a draft's fields, anchor, and state through the fake" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();

    try s.put(testReviewKey(7), .{
        .local_id = 1,
        .kind = .comment,
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
    try testing.expect(d.kind == .comment);
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

    try s.put(testReviewKey(1), .{ .local_id = 1, .kind = .comment, .body = "first" });
    try s.put(testReviewKey(1), .{ .local_id = 1, .kind = .comment, .body = "edited" }); // replace
    try s.put(testReviewKey(1), .{ .local_id = 2, .kind = .comment, .body = "second" });
    try s.put(testReviewKey(2), .{ .local_id = 1, .kind = .comment, .body = "other pr" });

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
    const alpha: RemoteReviewIdentity = .{ .workspace = "ws", .repository = "alpha", .pull_request_id = 1 };
    const beta: RemoteReviewIdentity = .{ .workspace = "ws", .repository = "beta", .pull_request_id = 1 };

    try s.put(alpha, .{ .local_id = 1, .kind = .comment, .body = "alpha draft" });
    try s.put(beta, .{ .local_id = 1, .kind = .comment, .body = "beta draft" });

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
    try s.put(testReviewKey(1), .{ .local_id = 1, .kind = .comment, .body = "a" });
    try s.put(testReviewKey(1), .{ .local_id = 2, .kind = .comment, .body = "b" });

    try s.remove(testReviewKey(1), 1);
    try s.remove(testReviewKey(1), 1); // idempotent — no error
    try s.remove(testReviewKey(1), 999); // unknown — no error

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), testReviewKey(1));
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(@as(TempId, 2), drafts[0].local_id);
}

test "editing a Draft body preserves its identity, shape, and scope" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{
        .local_id = 9,
        .kind = .suggestion,
        .scope = .{ .@"inline" = .{ .path = "src/f.zig", .to = 12, .commit = "abc" } },
        .snapshot = .{ .text = "const x = 0;", .selection_start = 0, .selection_len = 12 },
        .body = "```suggestion\nold\n```",
    });

    try s.editDraftBody(key, .{
        .temp_id = 9,
        .expected_kind = .suggestion,
        .expected_parent = null,
        .body = "```suggestion\nnew\n```",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 1), drafts.len);
    const edited = drafts[0];
    try testing.expectEqual(@as(TempId, 9), edited.local_id);
    try testing.expect(edited.kind == .suggestion);
    try testing.expect(edited.parent == null);
    try testing.expectEqualStrings("```suggestion\nnew\n```", edited.body);
    try testing.expectEqualStrings("src/f.zig", edited.effectiveScope().@"inline".path);
    try testing.expectEqual(@as(?u32, 12), edited.effectiveScope().@"inline".to);
    try testing.expectEqualStrings("const x = 0;", edited.snapshot.?.text);
}

test "editing a Reply keeps its parent and refuses a changed expectation" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "root" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });

    try testing.expectError(error.DraftEditConflict, s.editDraftBody(key, .{
        .temp_id = 2,
        .expected_kind = .comment,
        .expected_parent = .{ .comment = 1 },
        .body = "wrong parentage",
    }));
    try testing.expectError(error.DraftEditConflict, s.editDraftBody(key, .{
        .temp_id = 2,
        .expected_kind = .suggestion,
        .expected_parent = .{ .draft = 1 },
        .body = "wrong kind",
    }));
    try s.editDraftBody(key, .{
        .temp_id = 2,
        .expected_kind = .comment,
        .expected_parent = .{ .draft = 1 },
        .body = "edited reply",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqualStrings("root", drafts[0].body);
    try testing.expectEqualStrings("edited reply", drafts[1].body);
    try testing.expect(drafts[1].parent.? == .draft and drafts[1].parent.?.draft == 1);
}

test "editing a failed Draft resets it to draft" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "rejected", .state = .{ .failed = error.ServerError } });

    try s.editDraftBody(key, .{ .temp_id = 1, .expected_kind = .comment, .expected_parent = null, .body = "reworded" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expect(drafts[0].state == .draft);
    try testing.expectEqualStrings("reworded", drafts[0].body);
}

test "editing refuses unknown, run-owned, in-flight, and unresolved Drafts" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    const other = RemoteReviewIdentity{ .workspace = "workspace", .repository = "other", .pull_request_id = 4 };
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "participant" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .body = "bystander" });
    try s.put(key, .{ .local_id = 3, .kind = .comment, .body = "posted", .state = .{ .posted = 77 } });

    const edit: DraftBodyEdit = .{ .temp_id = 1, .expected_kind = .comment, .expected_parent = null, .body = "changed" };
    try testing.expectError(error.DraftNotFound, s.editDraftBody(key, .{
        .temp_id = 99,
        .expected_kind = .comment,
        .expected_parent = null,
        .body = "changed",
    }));
    try testing.expectError(error.DraftNotFound, s.editDraftBody(other, edit));

    _ = try s.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try testing.expectError(error.DraftLocked, s.editDraftBody(key, edit));
    try testing.expectError(error.DraftNotEditable, s.editDraftBody(key, .{
        .temp_id = 3,
        .expected_kind = .comment,
        .expected_parent = null,
        .body = "changed",
    }));
    // A Draft outside the frozen participant graph stays editable.
    try s.editDraftBody(key, .{ .temp_id = 2, .expected_kind = .comment, .expected_parent = null, .body = "still mine" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqualStrings("participant", drafts[0].body);
    try testing.expectEqualStrings("still mine", drafts[1].body);
}

test "an unresolved outcome refuses editing until it is resolved" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "ambiguous" });
    const operation_id = try s.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try s.checkpointSubmission(operation_id, key, 1, .outcome_unknown, null);
    try s.completeSubmission(operation_id, key, .partial);

    const edit: DraftBodyEdit = .{ .temp_id = 1, .expected_kind = .comment, .expected_parent = null, .body = "changed" };
    try testing.expectError(error.DraftLocked, s.editDraftBody(key, edit));
    try s.resolveUnknown(key, 1, .unpublished);
    try s.editDraftBody(key, edit);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("changed", (try s.load(arena.allocator(), key))[0].body);
}

test "re-anchoring an inline root replaces its Anchor and snapshot, keeping everything else" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "src/f.zig", .to = 4, .commit = "source" } },
        .snapshot = .{ .text = "authored", .selection_start = 0, .selection_len = 1 },
        .body = "still the same words",
        .state = .{ .failed = error.ServerError },
    });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });

    try s.reanchorDraft(key, .{
        .temp_id = 1,
        .expected_kind = .comment,
        .anchor = .{ .path = "src/g.zig", .start_to = 9, .to = 11, .commit = "source" },
        .snapshot = .{ .text = "repaired", .selection_start = 1, .selection_len = 3 },
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    const root = drafts[0];
    try testing.expectEqual(@as(TempId, 1), root.local_id);
    try testing.expect(root.kind == .comment);
    try testing.expectEqualStrings("still the same words", root.body);
    try testing.expectEqualStrings("src/g.zig", root.effectiveScope().@"inline".path);
    try testing.expectEqual(@as(?u32, 9), root.effectiveScope().@"inline".start_to);
    try testing.expectEqual(@as(?u32, 11), root.effectiveScope().@"inline".to);
    try testing.expectEqualStrings("repaired", root.snapshot.?.text);
    // A real Anchor change is a new attempt.
    try testing.expect(root.state == .draft);
    // The Reply subtree is untouched: parentage, not a copied scope, places it.
    try testing.expectEqual(@as(usize, 2), drafts.len);
    try testing.expect(drafts[1].parent.? == .draft and drafts[1].parent.?.draft == 1);
}

test "re-anchoring accepts an old-side Comment range but refuses an old-side Suggestion" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "f.zig", .to = 1, .commit = "source" } },
        .body = "prose",
    });
    try s.put(key, .{
        .local_id = 2,
        .kind = .suggestion,
        .scope = .{ .@"inline" = .{ .path = "f.zig", .to = 1, .commit = "source" } },
        .body = "```suggestion\nnew\n```",
    });

    try s.reanchorDraft(key, .{
        .temp_id = 1,
        .expected_kind = .comment,
        .anchor = .{ .path = "f.zig", .start_from = 2, .from = 5, .commit = "base" },
    });
    try testing.expectError(error.InvalidAnchor, s.reanchorDraft(key, .{
        .temp_id = 2,
        .expected_kind = .suggestion,
        .anchor = .{ .path = "f.zig", .from = 5, .commit = "base" },
    }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqual(@as(?u32, 5), drafts[0].effectiveScope().@"inline".from);
    try testing.expectEqualStrings("base", drafts[0].effectiveScope().@"inline".commit.?);
    try testing.expectEqual(@as(?u32, 1), drafts[1].effectiveScope().@"inline".to);
}

test "re-anchoring refuses ambiguous shapes, non-inline roots, Replies, and locked Drafts" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    const inline_scope: Anchor = .{ .path = "f.zig", .to = 1, .commit = "source" };
    try s.put(key, .{ .local_id = 1, .kind = .comment, .scope = .{ .@"inline" = inline_scope }, .body = "root" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
    try s.put(key, .{ .local_id = 3, .kind = .comment, .scope = .review, .body = "review level" });
    try s.put(key, .{ .local_id = 4, .kind = .comment, .scope = .{ .file = .{ .path = "f.zig", .source_commit = "source" } }, .body = "file level" });

    const valid: Anchor = .{ .path = "f.zig", .to = 3, .commit = "source" };
    try testing.expectError(error.DraftNotFound, s.reanchorDraft(key, .{ .temp_id = 99, .expected_kind = .comment, .anchor = valid }));
    try testing.expectError(error.DraftNotAnchorable, s.reanchorDraft(key, .{ .temp_id = 2, .expected_kind = .comment, .anchor = valid }));
    try testing.expectError(error.DraftNotAnchorable, s.reanchorDraft(key, .{ .temp_id = 3, .expected_kind = .comment, .anchor = valid }));
    try testing.expectError(error.DraftNotAnchorable, s.reanchorDraft(key, .{ .temp_id = 4, .expected_kind = .comment, .anchor = valid }));
    try testing.expectError(error.DraftEditConflict, s.reanchorDraft(key, .{ .temp_id = 1, .expected_kind = .suggestion, .anchor = valid }));
    try testing.expectError(error.InvalidAnchor, s.reanchorDraft(key, .{
        .temp_id = 1,
        .expected_kind = .comment,
        .anchor = .{ .path = "f.zig", .from = 2, .to = 3, .commit = "source" },
    }));
    try testing.expectError(error.InvalidAnchor, s.reanchorDraft(key, .{
        .temp_id = 1,
        .expected_kind = .comment,
        .anchor = .{ .path = "f.zig", .start_to = 1, .to = 31, .commit = "source" },
    }));

    _ = try s.beginSubmission(key, "source", &.{.{ .temp_id = 1, .parent = null }});
    try testing.expectError(error.DraftLocked, s.reanchorDraft(key, .{ .temp_id = 1, .expected_kind = .comment, .anchor = valid }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqual(@as(?u32, 1), drafts[0].effectiveScope().@"inline".to);
}

test "deleting a Draft subtree removes the root and every transitive descendant" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "f.zig", .to = 1, .commit = "source" } },
        .body = "root",
    });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
    try s.put(key, .{ .local_id = 3, .kind = .comment, .parent = .{ .draft = 2 }, .body = "deep reply" });
    try s.put(key, .{ .local_id = 4, .kind = .comment, .body = "bystander" });
    try s.put(key, .{ .local_id = 5, .kind = .comment, .parent = .{ .comment = 900 }, .body = "reply to Bitbucket" });

    try s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{ 1, 2, 3 },
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 2), drafts.len);
    try testing.expectEqual(@as(TempId, 4), drafts[0].local_id);
    try testing.expectEqual(@as(TempId, 5), drafts[1].local_id);
}

test "deleting a leaf Reply leaves its root and siblings untouched" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "root" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "doomed" });
    try s.put(key, .{ .local_id = 3, .kind = .comment, .parent = .{ .draft = 1 }, .body = "sibling" });

    try s.deleteDraftSubtree(key, .{
        .root_temp_id = 2,
        .expected_parent = .{ .draft = 1 },
        .cascade = &.{2},
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 2), drafts.len);
    try testing.expectEqualStrings("root", drafts[0].body);
    try testing.expectEqualStrings("sibling", drafts[1].body);
}

test "a deletion refuses an incomplete, overreaching, or malformed cascade" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    const other = RemoteReviewIdentity{ .workspace = "workspace", .repository = "other", .pull_request_id = 4 };
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "root" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
    try s.put(key, .{ .local_id = 3, .kind = .comment, .body = "bystander" });

    // The confirmed cascade omitted the Reply, so committing would strand it.
    try testing.expectError(error.DraftCascadeConflict, s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{1},
    }));
    // A bystander is not in the closure, whatever the reviewer confirmed.
    try testing.expectError(error.DraftCascadeConflict, s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{ 1, 3 },
    }));
    try testing.expectError(error.DraftCascadeConflict, s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{ 2, 1 },
    }));
    try testing.expectError(error.DraftCascadeConflict, s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{ 1, 2, 2 },
    }));
    try testing.expectError(error.DraftCascadeConflict, s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{},
    }));
    // Wrong parentage means the graph moved underneath the confirmation.
    try testing.expectError(error.DraftEditConflict, s.deleteDraftSubtree(key, .{
        .root_temp_id = 2,
        .expected_parent = .{ .comment = 1 },
        .cascade = &.{2},
    }));
    try testing.expectError(error.DraftNotFound, s.deleteDraftSubtree(key, .{
        .root_temp_id = 99,
        .expected_parent = null,
        .cascade = &.{99},
    }));
    try testing.expectError(error.DraftNotFound, s.deleteDraftSubtree(other, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{ 1, 2 },
    }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 3), (try s.load(arena.allocator(), key)).len);
}

test "a deletion refuses a run-owned or immutable member and removes nothing" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "root" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "published reply", .state = .{ .posted = 77 } });
    try s.put(key, .{ .local_id = 3, .kind = .comment, .body = "participant" });
    try s.put(key, .{ .local_id = 4, .kind = .comment, .parent = .{ .draft = 3 }, .body = "participant reply" });

    // The root itself is mutable; a transient `posted` descendant is not.
    try testing.expectError(error.DraftNotEditable, s.deleteDraftSubtree(key, .{
        .root_temp_id = 1,
        .expected_parent = null,
        .cascade = &.{ 1, 2 },
    }));

    _ = try s.beginSubmission(key, "source-commit", &.{.{ .temp_id = 3, .parent = null }});
    try testing.expectError(error.DraftLocked, s.deleteDraftSubtree(key, .{
        .root_temp_id = 3,
        .expected_parent = null,
        .cascade = &.{ 3, 4 },
    }));
    // The descendant alone is outside the frozen participant graph.
    try s.deleteDraftSubtree(key, .{
        .root_temp_id = 4,
        .expected_parent = .{ .draft = 3 },
        .cascade = &.{4},
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try s.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 3), drafts.len);
    try testing.expectEqualSlices(TempId, &.{ 1, 2, 3 }, &.{ drafts[0].local_id, drafts[1].local_id, drafts[2].local_id });
}

test "an unresolved outcome refuses deleting the subtree that contains it" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "ambiguous" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
    const operation_id = try s.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try s.checkpointSubmission(operation_id, key, 1, .outcome_unknown, null);
    try s.completeSubmission(operation_id, key, .partial);

    const deletion: DraftSubtreeDelete = .{ .root_temp_id = 1, .expected_parent = null, .cascade = &.{ 1, 2 } };
    try testing.expectError(error.DraftLocked, s.deleteDraftSubtree(key, deletion));
    try s.resolveUnknown(key, 1, .unpublished);
    try s.deleteDraftSubtree(key, deletion);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try s.load(arena.allocator(), key)).len);
}

test "deleting the highest Draft never hands its TempId back" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    // Rows persisted without ever reserving — exactly what a resumed review
    // looks like, and the case where the counter is derived from MAX(local_id).
    try s.put(key, .{ .local_id = 1, .kind = .comment, .body = "root" });
    try s.put(key, .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });

    try s.deleteDraftSubtree(key, .{ .root_temp_id = 1, .expected_parent = null, .cascade = &.{ 1, 2 } });

    try testing.expectEqual(@as(TempId, 3), try s.reserveTempId(key));
    try testing.expectEqual(@as(TempId, 4), try s.reserveTempId(key));
}

test "loadReview rebuilds the graph and next_id for resume" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    try s.put(testReviewKey(1), .{ .local_id = 3, .kind = .comment, .body = "root" });
    try s.put(testReviewKey(1), .{ .local_id = 8, .kind = .comment, .body = "re", .parent = .{ .draft = 3 } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var review = try s.loadReview(arena.allocator(), testReviewKey(1));

    try testing.expectEqual(@as(usize, 2), review.drafts.items.len);
    try testing.expect(review.get(8).?.isReply());
    // A fresh draft is assigned an id past every loaded one.
    const fresh = try review.add(arena.allocator(), .{ .kind = .comment, .body = "new" });
    try testing.expectEqual(@as(TempId, 9), fresh);
}

test "beginning a Submission atomically records its run and first submitting Draft" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "first" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .body = "second" });

    const participants = [_]SubmissionRunItem{
        .{ .temp_id = 2, .parent = null },
        .{ .temp_id = 1, .parent = null },
    };
    const operation_id = try store.beginSubmission(key, "source-commit", &participants);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = (try store.activeSubmission(arena.allocator())).?;
    try testing.expectEqual(operation_id, run.operation_id);
    try testing.expect(RemoteReviewIdentity.eql(key, run.key));
    try testing.expectEqualStrings("source-commit", run.source_commit);
    try testing.expectEqual(@as(?TempId, 2), run.current_temp_id);
    try testing.expectEqualSlices(TempId, &.{ 2, 1 }, &.{ run.items[0].temp_id, run.items[1].temp_id });

    const drafts = try store.load(arena.allocator(), key);
    try testing.expect(drafts[0].state == .draft);
    try testing.expect(drafts[1].state == .submitting);
}

test "Submission checkpoint persists the outcome and next intent together" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "first" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .body = "second", .state = .{ .failed = error.ServerError } });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{ .{ .temp_id = 1, .parent = null }, .{ .temp_id = 2, .parent = null } });

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
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "first" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});

    try testing.expectError(error.InvalidSubmissionCheckpoint, store.checkpointSubmission(operation_id, key, 1, .{ .posted = 900 }, 99));

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
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "posted" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .target = .local, .body = "keep local", .state = .{ .posted = 901 } });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
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
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "failed" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
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
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "unknown" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try store.checkpointSubmission(operation_id, key, 1, .outcome_unknown, null);
    try store.completeSubmission(operation_id, key, .partial);

    try testing.expectError(error.DraftLocked, store.put(key, .{ .local_id = 1, .kind = .comment, .body = "changed" }));
    try testing.expectError(error.DraftLocked, store.remove(key, 1));
    try store.resolveUnknown(key, 1, .unpublished);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "changed" });
}

test "active Submission locks Bitbucket Draft mutation but not local Drafts" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "remote" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .target = .local, .body = "local" });
    _ = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});

    try testing.expectError(error.DraftLocked, store.put(key, .{ .local_id = 1, .kind = .comment, .body = "changed" }));
    try testing.expectError(error.DraftLocked, store.remove(key, 1));
    try store.put(key, .{ .local_id = 3, .kind = .comment, .body = "new remote" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .target = .local, .body = "changed local" });
    try store.remove(key, 2);
}

test "clean completion rejects a Submission with failed Bitbucket Drafts" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "failed" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
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
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "retry", .state = .{ .failed = error.ServerError } });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});

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
    try store.put(key, .{ .local_id = 2, .kind = .comment, .body = "second" });
    try testing.expectEqual(@as(TempId, 3), try store.reserveTempId(key));
}

test "abandoning recovery preserves ambiguity and releases participant ownership" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "ambiguous" });
    const operation_id = try store.beginSubmission(key, "source", &.{.{ .temp_id = 1, .parent = null }});

    try store.abandonSubmission(operation_id, key);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    try testing.expect((try store.load(arena.allocator(), key))[0].state == .outcome_unknown);
}

// The fake recomputes subtree membership over its own rows rather than
// borrowing `draft_mod.descendsFrom`, because its entries are not one
// contiguous slice. That duplication is only safe while the two agree
// exactly — including on cycles, orphans, and Replies to published Comments.
test "the fake's subtree membership matches the shared rule exactly" {
    var mem = InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const s = mem.store();
    const key = testReviewKey(4);
    var review = PendingReview.init(4);
    defer review.deinit(testing.allocator);

    const rows = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "root" },
        .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" },
        .{ .local_id = 3, .kind = .comment, .parent = .{ .draft = 2 }, .body = "deep" },
        .{ .local_id = 4, .kind = .comment, .parent = .{ .comment = 900 }, .body = "remote reply" },
        .{ .local_id = 5, .kind = .comment, .parent = .{ .draft = 99 }, .body = "orphan" },
        .{ .local_id = 6, .kind = .comment, .parent = .{ .draft = 7 }, .body = "cycle a" },
        .{ .local_id = 7, .kind = .comment, .parent = .{ .draft = 6 }, .body = "cycle b" },
    };
    for (rows) |row| {
        try s.put(key, row);
        try review.addExisting(testing.allocator, row);
    }

    for (0..10) |root| for (0..10) |id| {
        const pure = draft_mod.descendsFrom(review.drafts.items, @intCast(root), @intCast(id));
        const stored = mem.descendsFrom(key, @intCast(root), @intCast(id));
        try testing.expectEqual(pure, stored);
    };
}
