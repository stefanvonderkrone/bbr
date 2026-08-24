//! Submission: the pure orchestrator that publishes a `PendingReview` to
//! Bitbucket (design §9, M10). It is a clock-free, network-free state machine —
//! it never posts anything itself. `advance()` returns the next `Step` as data
//! (post this draft / wait N ms / done / aborted); the caller performs the one
//! I/O action a step names and feeds the result back via `report()`. This keeps
//! the whole failure model — topological ordering, temp-id → CommentId remap,
//! retry-with-backoff, abort-on-auth, mark-and-continue, skip-descendants — unit
//! testable with no HTTP and no threads.
//!
//! The network side is the `CommentPoster` seam (a ptr+vtable like `HttpClient`
//! and `PendingReviewStore`): the Bitbucket adapter implements it for real, and
//! `FakeCommentPoster` scripts outcomes in tests. The engine does not call the
//! poster — the driving worker (app.zig) does, on the thread that owns `Io`.
//!
//! Ordering & remap ride on the model that already exists: `topologicalOrder`
//! places a reply after its parent, and each posted item records its server
//! `CommentId` so a following reply can resolve `Parent.draft` → a real id. A
//! draft already `posted` (a prior interrupted batch, ADR-0007) is treated as
//! done, so re-running a Submission over the same review is selective retry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draft_mod = @import("draft.zig");
const PendingReview = draft_mod.PendingReview;
const Draft = draft_mod.Draft;
const TempId = draft_mod.TempId;
const comment = @import("comment.zig");
const CommentId = comment.CommentId;
const ApiError = @import("../bitbucket/types.zig").ApiError;
const SubmissionRunItem = @import("store.zig").SubmissionRunItem;
const SubmissionRetryCheckpoint = @import("store.zig").SubmissionRetryCheckpoint;
const SubmissionRetryPhase = @import("store.zig").SubmissionRetryPhase;
const SubmissionRetryReason = @import("store.zig").SubmissionRetryReason;

/// Total tries per retryable item (the first attempt plus retries). After this
/// many failures the item is marked failed and its reply-descendants skipped.
pub const max_attempts: u8 = 3;
const backoff_base_ms: u64 = 1_000;

/// Backoff before the `n`-th retry (n = the failure count so far, 1-based):
/// one second, then two seconds. A third failure is terminal.
pub fn backoffMs(attempt: u8) u64 {
    if (attempt == 0) return 0;
    return if (attempt == 1) backoff_base_ms else backoff_base_ms * 2;
}

/// Stale-anchor guard (§9): true if the PR's source head moved since we loaded
/// it, so anchors may no longer resolve (→ the batch should warn/reload before
/// posting). Tolerant of hash abbreviation; unknown (empty) sides never warn.
pub fn headChanged(loaded: []const u8, current: []const u8) bool {
    if (loaded.len == 0 or current.len == 0) return false;
    const shorter = if (loaded.len <= current.len) loaded else current;
    const longer = if (loaded.len <= current.len) current else loaded;
    return !std.mem.startsWith(u8, longer, shorter);
}

/// What a single POST attempt yielded. `rejected` means the server responded
/// with a non-2xx we classified (no comment was created); `ambiguous` means the
/// request failed in transit (transport error / lost response) so a comment may
/// or may not exist — the retry must dedupe (design §9, "Duplicates").
pub const PostOutcome = union(enum) {
    posted: CommentId,
    rejected: ApiError,
    ambiguous,
};

pub const PostResult = struct {
    outcome: PostOutcome,
    retry_after_ms: ?u64 = null,
};

pub const CheckOutcome = union(enum) {
    found: CommentId,
    missing,
    rejected: ApiError,
    ambiguous,
};

pub const CheckResult = struct {
    outcome: CheckOutcome,
    retry_after_ms: ?u64 = null,
};

/// The concrete action `advance()` asks the caller to take.
pub const Step = union(enum) {
    /// POST this draft. `parent` is the resolved server `CommentId` for a reply
    /// (null for a root). `dedupe` is set when this is a retry after an
    /// `ambiguous` failure: the caller must GET-and-match first (via
    /// `CommentPoster.findExisting`) and, on a match, report `.posted{that id}`
    /// instead of re-POSTing.
    post: PostStep,
    /// Read comments and establish whether an ambiguous POST published. This
    /// effect never performs a POST itself.
    check: PostStep,
    /// Sleep `ms`, then call `advance()` again (it re-issues the same post).
    wait: WaitStep,
    /// Terminal: the batch finished. Some items may have failed or been skipped
    /// (see `summary`); the caller applies state and, on a clean batch, deletes
    /// the posted drafts (ADR-0007).
    done,
    /// Terminal: an auth failure aborted the whole batch. Everything unposted
    /// stays pending; the caller surfaces the token/scope error.
    aborted: ApiError,
};

pub const PostStep = struct { temp_id: TempId, parent: ?CommentId, dedupe: bool };

pub const WaitStep = struct {
    ms: u64,
    temp_id: TempId,
    checkpoint: SubmissionRetryCheckpoint,
};

/// The fate of one draft in a finished (or aborted) batch.
pub const ItemStatus = enum { posted, failed, skipped, outcome_unknown };

pub const ItemResult = struct {
    temp_id: TempId,
    status: ItemStatus,
    /// The server id, set only when `status == .posted`.
    id: ?CommentId = null,
    /// The classified reason, set for `failed` (its own error) and `skipped`
    /// (the ancestor error that blocked it), null otherwise.
    reason: ?ApiError = null,
};

/// A finished batch's per-item outcome plus roll-up counts. `items` holds only
/// the decided drafts (an aborted batch leaves the rest pending, absent here).
pub const Summary = struct {
    items: []const ItemResult,
    posted: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    outcome_unknown: usize = 0,
    aborted: ?ApiError = null,
};

/// How a rejected `ApiError` maps to policy (design §9 failure table).
const Policy = enum { abort, retry, fail };
fn classifyPolicy(err: ApiError) Policy {
    return switch (err) {
        error.Unauthorized, error.Forbidden => .abort,
        error.RateLimited, error.ServerError => .retry,
        error.BadRequest, error.NotFound, error.Conflict, error.UnexpectedStatus, error.MalformedResponse => .fail,
    };
}

/// The submission state machine over one PendingReview. Owns per-item bookkeeping
/// in a caller-supplied allocator; `deinit` frees it. The review is read only for
/// draft fields and prior `posted` state — the engine never mutates it, so the
/// caller stays the single writer of review/store state.
pub const Submission = struct {
    review: *const PendingReview,
    /// Drafts in topological submission order (a reply after its parent).
    order: []TempId,
    /// Index into `order` of the item currently in flight.
    idx: usize = 0,
    /// Failure count per `order` position (drives backoff and exhaustion).
    attempts: []u8,
    /// Failed publication checks; independent from the POST attempt budget.
    check_attempts: []u8,
    /// Whether the last failure at a position was `ambiguous` (→ dedupe on retry).
    ambiguous_last: []bool,
    /// The decided outcome per `order` position, filled as the batch runs.
    results: []?ItemResult,
    /// A retry is scheduled for the current item: `advance()` emits one `.wait`.
    must_wait: bool = false,
    retry_checkpoint: SubmissionRetryCheckpoint = undefined,
    /// Guidance attached to the final definite retryable rejection. A fresh
    /// selective retry carries this delay to its first POST.
    terminal_server_delay_ms: ?u64 = null,
    aborted_reason: ?ApiError = null,
    alloc: Allocator,

    pub fn init(alloc: Allocator, review: *const PendingReview) !Submission {
        const order = try review.topologicalOrder(alloc);
        return initOrder(alloc, review, order, false);
    }

    /// Start a fresh Submission for exactly one selected Draft subtree. Posted
    /// participants are omitted: a pending Reply below one can still resolve
    /// that parent's durable CommentId from the PendingReview.
    pub fn initSubtree(alloc: Allocator, review: *const PendingReview, root: TempId) !Submission {
        const selected = review.getConst(root) orelse return error.DraftNotFound;
        if (selected.target != .bitbucket or (selected.state != .failed and selected.state != .draft))
            return error.DraftNotRetryable;

        const all = try review.topologicalOrder(alloc);
        defer alloc.free(all);
        var order: std.ArrayList(TempId) = .empty;
        errdefer order.deinit(alloc);
        for (all) |temp_id| {
            if (!draft_mod.descendsFrom(review.drafts.items, root, temp_id)) continue;
            const draft = review.getConst(temp_id) orelse continue;
            if (draft.target != .bitbucket) return error.DraftNotRetryable;
            switch (draft.state) {
                .posted => continue,
                .draft, .failed => {},
                .submitting, .outcome_unknown => return error.DraftNotRetryable,
            }
            try order.append(alloc, temp_id);
        }
        if (order.items.len == 0) return error.DraftNotRetryable;
        return initOrder(alloc, review, try order.toOwnedSlice(alloc), false);
    }

    /// Rebuild an interrupted Submission from its durable participant graph.
    /// Current PendingReview membership and ordering are deliberately ignored.
    pub fn initFrozen(alloc: Allocator, review: *const PendingReview, items: []const SubmissionRunItem) !Submission {
        const order = try alloc.alloc(TempId, items.len);
        errdefer alloc.free(order);
        for (items, order) |item, *temp_id| {
            const draft = review.getConst(item.temp_id) orelse return error.DraftNotFound;
            if (!parentEql(draft.parent, item.parent)) return error.InvalidSubmissionGraph;
            temp_id.* = item.temp_id;
        }
        return initOrder(alloc, review, order, true);
    }

    fn initOrder(alloc: Allocator, review: *const PendingReview, order: []TempId, settle_failures: bool) !Submission {
        errdefer alloc.free(order);
        const n = order.len;
        const attempts = try alloc.alloc(u8, n);
        errdefer alloc.free(attempts);
        @memset(attempts, 0);
        const amb = try alloc.alloc(bool, n);
        errdefer alloc.free(amb);
        @memset(amb, false);
        const check_attempts = try alloc.alloc(u8, n);
        errdefer alloc.free(check_attempts);
        @memset(check_attempts, 0);
        const results = try alloc.alloc(?ItemResult, n);
        @memset(results, null);
        for (order, 0..) |temp_id, i| {
            const draft = review.getConst(temp_id) orelse continue;
            results[i] = switch (draft.state) {
                .posted => |id| .{ .temp_id = temp_id, .status = .posted, .id = id },
                .failed => |reason| if (settle_failures) .{ .temp_id = temp_id, .status = .failed, .reason = reason } else null,
                .outcome_unknown => .{ .temp_id = temp_id, .status = .outcome_unknown },
                .draft, .submitting => null,
            };
        }
        return .{
            .review = review,
            .order = order,
            .attempts = attempts,
            .check_attempts = check_attempts,
            .ambiguous_last = amb,
            .results = results,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Submission) void {
        self.alloc.free(self.order);
        self.alloc.free(self.attempts);
        self.alloc.free(self.check_attempts);
        self.alloc.free(self.ambiguous_last);
        self.alloc.free(self.results);
        self.* = undefined;
    }

    /// The next action to take. Idempotent between `report()` calls: calling it
    /// twice without an intervening `report` returns the same non-terminal step
    /// (except that a pending `.wait` is consumed once, then `.post` follows).
    pub fn advance(self: *Submission) Step {
        if (self.aborted_reason) |e| return .{ .aborted = e };

        while (self.idx < self.order.len) {
            const i = self.idx;
            if (self.results[i] != null) {
                self.idx += 1;
                continue;
            }
            const tid = self.order[i];
            const d = self.review.getConst(tid) orelse {
                self.idx += 1;
                continue;
            };
            if (d.target == .local) {
                self.idx += 1;
                continue;
            }

            // A draft posted by a prior (interrupted) batch: already done.
            if (d.state == .posted) {
                self.results[i] = .{ .temp_id = tid, .status = .posted, .id = d.state.posted };
                self.idx += 1;
                continue;
            }

            switch (self.resolveParent(d.*)) {
                .blocked => {
                    self.results[i] = .{
                        .temp_id = tid,
                        .status = .skipped,
                        .reason = self.parentReason(d.*),
                    };
                    self.idx += 1;
                    continue;
                },
                .ok => |parent| {
                    if (self.must_wait) {
                        return .{ .wait = .{
                            .ms = self.retry_checkpoint.effective_delay_ms,
                            .temp_id = tid,
                            .checkpoint = self.retry_checkpoint,
                        } };
                    }
                    const effect: PostStep = .{ .temp_id = tid, .parent = parent, .dedupe = self.ambiguous_last[i] };
                    return if (self.ambiguous_last[i]) .{ .check = effect } else .{ .post = effect };
                },
            }
        }
        return .done;
    }

    pub fn completeWait(self: *Submission) void {
        std.debug.assert(self.must_wait);
        self.must_wait = false;
    }

    /// Feed back the outcome of the `.post` step `advance()` last returned.
    /// `retry_after_ms` overrides the computed backoff (a 429's `Retry-After`).
    pub fn report(self: *Submission, outcome: PostOutcome, retry_after_ms: ?u64) void {
        self.terminal_server_delay_ms = null;
        const i = self.idx;
        const tid = self.order[i];
        switch (outcome) {
            .posted => |cid| {
                self.results[i] = .{ .temp_id = tid, .status = .posted, .id = cid };
                self.ambiguous_last[i] = false;
                self.idx += 1;
            },
            .rejected => |err| switch (classifyPolicy(err)) {
                .abort => self.aborted_reason = err, // leave the item pending
                .retry => self.scheduleRetryOrFail(i, err, retry_after_ms),
                .fail => self.failItem(i, tid, err),
            },
            .ambiguous => {
                self.attempts[i] += 1;
                self.ambiguous_last[i] = true;
                self.check_attempts[i] = 0;
            },
        }
    }

    /// Feed back one Duplicate-guard read. A failed read spends only the
    /// publication-check budget; another POST is allowed only after a definite
    /// `.missing` result.
    pub fn reportCheck(self: *Submission, result: CheckResult) void {
        const i = self.idx;
        const tid = self.order[i];
        switch (result.outcome) {
            .found => |id| {
                self.results[i] = .{ .temp_id = tid, .status = .posted, .id = id };
                self.ambiguous_last[i] = false;
                self.idx += 1;
            },
            .missing => {
                self.ambiguous_last[i] = false;
                self.check_attempts[i] = 0;
                if (self.attempts[i] >= max_attempts) {
                    self.results[i] = .{ .temp_id = tid, .status = .outcome_unknown };
                    self.idx += 1;
                } else {
                    self.setWait(.post, self.attempts[i], .ambiguous_post, result.retry_after_ms);
                    self.must_wait = true;
                }
            },
            .rejected => |err| switch (classifyPolicy(err)) {
                .retry => self.scheduleCheckRetryOrUnknown(i, checkReason(err), result.retry_after_ms),
                .abort, .fail => {
                    self.results[i] = .{ .temp_id = tid, .status = .outcome_unknown };
                    self.idx += 1;
                },
            },
            .ambiguous => self.scheduleCheckRetryOrUnknown(i, .publication_check_transport, result.retry_after_ms),
        }
    }

    /// Roll up the decided items into a `Summary`; `items` is owned by `alloc`.
    /// Call once `advance()` has returned `.done` or `.aborted`.
    pub fn summary(self: *const Submission, alloc: Allocator) !Summary {
        var items: std.ArrayList(ItemResult) = .empty;
        errdefer items.deinit(alloc);
        var s = Summary{ .items = &.{}, .aborted = self.aborted_reason };
        for (self.results) |maybe| {
            const r = maybe orelse continue;
            try items.append(alloc, r);
            switch (r.status) {
                .posted => s.posted += 1,
                .failed => s.failed += 1,
                .skipped => s.skipped += 1,
                .outcome_unknown => s.outcome_unknown += 1,
            }
        }
        s.items = try items.toOwnedSlice(alloc);
        return s;
    }

    /// Valid after `.done`: true when every decided remote Draft posted and no
    /// Draft was failed or skipped. Local-only Drafts are intentionally absent.
    pub fn isClean(self: *const Submission) bool {
        if (self.aborted_reason != null) return false;
        for (self.results) |maybe| if (maybe) |result| {
            if (result.status != .posted) return false;
        };
        return true;
    }

    const ParentResolution = union(enum) { ok: ?CommentId, blocked };

    /// Resolve a draft's parent to the server id a reply must POST against.
    /// A `Parent.comment` is already a server id; a `Parent.draft` reads the
    /// parent's recorded result (topological order guarantees it precedes this
    /// item). A parent that failed or was skipped → `.blocked`; a parent absent
    /// from the review (stale reference) → root-like (`.ok = null`).
    fn resolveParent(self: *Submission, d: Draft) ParentResolution {
        const p = d.parent orelse return .{ .ok = null };
        const pid = switch (p) {
            .comment => |cid| return .{ .ok = cid },
            .draft => |x| x,
        };
        for (self.order, 0..) |tid, i| {
            if (tid != pid) continue;
            const r = self.results[i] orelse return .blocked;
            return if (r.status == .posted) .{ .ok = r.id } else .blocked;
        }
        const parent = self.review.getConst(pid) orelse return .blocked;
        return if (parent.state == .posted) .{ .ok = parent.state.posted } else .blocked;
    }

    fn parentReason(self: *Submission, d: Draft) ?ApiError {
        const p = d.parent orelse return null;
        const pid = switch (p) {
            .draft => |x| x,
            .comment => return null,
        };
        for (self.order, 0..) |tid, i| {
            if (tid == pid) return if (self.results[i]) |r| r.reason else null;
        }
        const parent = self.review.getConst(pid) orelse return null;
        return if (parent.state == .failed) parent.state.failed else null;
    }

    fn scheduleRetryOrFail(self: *Submission, i: usize, err: ApiError, retry_after_ms: ?u64) void {
        self.attempts[i] += 1;
        if (self.attempts[i] >= max_attempts) {
            self.terminal_server_delay_ms = retry_after_ms;
            self.failItem(i, self.order[i], err);
            return;
        }
        self.ambiguous_last[i] = false;
        self.setWait(.post, self.attempts[i], postReason(err), retry_after_ms);
        self.must_wait = true;
    }

    fn scheduleCheckRetryOrUnknown(self: *Submission, i: usize, reason: SubmissionRetryReason, retry_after_ms: ?u64) void {
        self.check_attempts[i] += 1;
        if (self.check_attempts[i] >= max_attempts) {
            self.results[i] = .{ .temp_id = self.order[i], .status = .outcome_unknown };
            self.idx += 1;
            return;
        }
        self.setCheckWait(i, reason, retry_after_ms);
        self.must_wait = true;
    }

    fn setWait(self: *Submission, phase: SubmissionRetryPhase, attempt: u8, reason: SubmissionRetryReason, server_delay_ms: ?u64) void {
        const local = backoffMs(attempt);
        self.retry_checkpoint = .{
            .phase = phase,
            .attempt = attempt,
            .reason = reason,
            .local_delay_ms = local,
            .server_delay_ms = server_delay_ms,
            .effective_delay_ms = @max(local, server_delay_ms orelse 0),
            .pending_wait = true,
        };
    }

    fn setCheckWait(self: *Submission, i: usize, reason: SubmissionRetryReason, server_delay_ms: ?u64) void {
        const local = backoffMs(self.check_attempts[i]);
        self.retry_checkpoint = .{
            .phase = .publication_check,
            // Preserve the independent POST budget. The exact 1s/2s local
            // delay identifies the failed publication-check attempt on resume.
            .attempt = self.attempts[i],
            .reason = reason,
            .local_delay_ms = local,
            .server_delay_ms = server_delay_ms,
            .effective_delay_ms = @max(local, server_delay_ms orelse 0),
            .pending_wait = true,
        };
    }

    /// Restore a durable retry point. A pending timer is intentionally replayed
    /// in full; a cleared post-phase checkpoint becomes a publication check
    /// because a crash cannot establish whether the POST launched.
    pub fn restoreRetry(self: *Submission, checkpoint: SubmissionRetryCheckpoint) void {
        const i = self.idx;
        self.retry_checkpoint = checkpoint;
        self.attempts[i] = checkpoint.attempt;
        self.check_attempts[i] = if (checkpoint.phase == .publication_check)
            (if (checkpoint.local_delay_ms == backoffMs(1)) 1 else 2)
        else
            0;
        self.ambiguous_last[i] = checkpoint.phase == .publication_check or !checkpoint.pending_wait;
        self.must_wait = checkpoint.pending_wait;
    }

    fn failItem(self: *Submission, i: usize, tid: TempId, err: ApiError) void {
        self.results[i] = .{ .temp_id = tid, .status = .failed, .reason = err };
        self.idx += 1;
    }
};

fn postReason(err: ApiError) SubmissionRetryReason {
    return switch (err) {
        error.RateLimited => .rate_limited,
        error.ServerError => .server_error,
        else => unreachable,
    };
}

fn checkReason(err: ApiError) SubmissionRetryReason {
    return switch (err) {
        error.RateLimited => .publication_check_rate_limited,
        error.ServerError => .publication_check_server_error,
        else => unreachable,
    };
}

fn parentEql(a: ?draft_mod.Parent, b: ?draft_mod.Parent) bool {
    if (a == null or b == null) return a == null and b == null;
    return switch (a.?) {
        .draft => |id| b.? == .draft and b.?.draft == id,
        .comment => |id| b.? == .comment and b.?.comment == id,
    };
}

/// The network seam Submission's driver posts through. Same ptr+vtable idiom as
/// `HttpClient` / `PendingReviewStore`. The Bitbucket adapter implements it;
/// `FakeCommentPoster` scripts outcomes in tests.
pub const CommentPoster = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// POST one draft. `parent` is the resolved server id for a reply, null
        /// for a root. Returns the classified `PostOutcome` (transport failures
        /// map to `.ambiguous`, not an error); errors are reserved for local
        /// faults (e.g. OOM building the request).
        post: *const fn (ptr: *anyopaque, draft: Draft, parent: ?CommentId) anyerror!PostResult,
        /// Dedupe lookup for an ambiguous retry: the id of an already-posted
        /// comment matching this draft (path/line/body), or null if none.
        findExisting: *const fn (ptr: *anyopaque, draft: Draft, parent: ?CommentId) anyerror!CheckResult,
    };

    pub fn post(self: CommentPoster, draft: Draft, parent: ?CommentId) !PostResult {
        return self.vtable.post(self.ptr, draft, parent);
    }

    pub fn findExisting(self: CommentPoster, draft: Draft, parent: ?CommentId) !CheckResult {
        return self.vtable.findExisting(self.ptr, draft, parent);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn find(items: []const ItemResult, tid: TempId) ?ItemResult {
    for (items) |r| {
        if (r.temp_id == tid) return r;
    }
    return null;
}

test "topological post order and temp-id → CommentId remap" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const root = try pr.add(testing.allocator, .{ .kind = .comment, .body = "root" });
    const reply = try pr.add(testing.allocator, .{ .kind = .comment, .body = "re", .parent = .{ .draft = root } });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    // Root first, no parent.
    const s1 = sub.advance();
    try testing.expectEqual(root, s1.post.temp_id);
    try testing.expect(s1.post.parent == null);
    sub.report(.{ .posted = 500 }, null);

    // Reply second, remapped onto the root's new server id.
    const s2 = sub.advance();
    try testing.expectEqual(reply, s2.post.temp_id);
    try testing.expectEqual(@as(?CommentId, 500), s2.post.parent);
    try testing.expect(!s2.post.dedupe);
    sub.report(.{ .posted = 501 }, null);

    try testing.expect(sub.advance() == .done);

    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 2), sum.posted);
    try testing.expect(sum.aborted == null);
}

test "reply to an already-posted server comment posts against that id" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const r = try pr.add(testing.allocator, .{ .kind = .comment, .body = "re", .parent = .{ .comment = 99 } });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();
    const s = sub.advance();
    try testing.expectEqual(r, s.post.temp_id);
    try testing.expectEqual(@as(?CommentId, 99), s.post.parent);
}

test "auth failure aborts the whole batch, leaving items pending" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "b" });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();
    _ = sub.advance();
    sub.report(.{ .rejected = error.Unauthorized }, null);

    const step = sub.advance();
    try testing.expectEqual(ApiError.Unauthorized, step.aborted);

    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 0), sum.posted);
    try testing.expectEqual(ApiError.Unauthorized, sum.aborted.?);
}

test "validation failure fails the item and skips its reply-descendants" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const root = try pr.add(testing.allocator, .{ .kind = .comment, .body = "root" });
    const child = try pr.add(testing.allocator, .{ .kind = .comment, .body = "re", .parent = .{ .draft = root } });
    const grandchild = try pr.add(testing.allocator, .{ .kind = .comment, .body = "re2", .parent = .{ .draft = child } });
    const other = try pr.add(testing.allocator, .{ .kind = .comment, .body = "independent" });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    // root → 404 (bad_request-class), item fails.
    try testing.expectEqual(root, sub.advance().post.temp_id);
    sub.report(.{ .rejected = error.NotFound }, null);

    // The independent draft still posts (mark-and-continue).
    const s = sub.advance();
    try testing.expectEqual(other, s.post.temp_id);
    sub.report(.{ .posted = 700 }, null);

    try testing.expect(sub.advance() == .done);

    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 1), sum.posted);
    try testing.expectEqual(@as(usize, 1), sum.failed);
    try testing.expectEqual(@as(usize, 2), sum.skipped);
    try testing.expectEqual(ItemStatus.failed, find(sum.items, root).?.status);
    // Descendants inherit the ancestor's reason.
    try testing.expectEqual(ItemStatus.skipped, find(sum.items, child).?.status);
    try testing.expectEqual(ApiError.NotFound, find(sum.items, grandchild).?.reason.?);
}

test "retryable failure schedules backoff waits then succeeds" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    _ = sub.advance(); // .post
    sub.report(.{ .rejected = error.ServerError }, null);
    const w1 = sub.advance();
    try testing.expectEqual(backoffMs(1), w1.wait.ms);
    sub.completeWait();
    try testing.expect(sub.advance() == .post); // re-issued after the wait

    sub.report(.{ .rejected = error.ServerError }, null);
    const w2 = sub.advance();
    try testing.expectEqual(backoffMs(2), w2.wait.ms);
    try testing.expect(w2.wait.ms > w1.wait.ms);
    sub.completeWait();
    _ = sub.advance(); // .post again
    sub.report(.{ .posted = 900 }, null);

    try testing.expect(sub.advance() == .done);
    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 1), sum.posted);
}

test "429 Retry-After overrides the computed backoff" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    _ = sub.advance();
    sub.report(.{ .rejected = error.RateLimited }, 12_345);
    try testing.expectEqual(@as(u64, 12_345), sub.advance().wait.ms);
}

test "server guidance cannot shorten local fallback and wait exposes checkpoint evidence" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    _ = sub.advance();
    sub.report(.{ .rejected = error.RateLimited }, 17);
    const wait = sub.advance().wait;
    try testing.expectEqual(@as(u64, 1_000), wait.ms);
    try testing.expectEqual(@as(u64, 1_000), wait.checkpoint.local_delay_ms);
    try testing.expectEqual(@as(?u64, 17), wait.checkpoint.server_delay_ms);
    try testing.expect(wait.checkpoint.pending_wait);
}

test "ambiguous POST requires a publication check before another POST" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    const first = sub.advance();
    try testing.expect(!first.post.dedupe);
    sub.report(.ambiguous, null);
    const check = sub.advance();
    try testing.expect(check == .check);
    try testing.expect(check.check.dedupe);
}

test "exhausted ambiguity remains unresolved across selective retry" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const temp_id = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        sub.report(.ambiguous, null);
        try testing.expect(sub.advance() == .check);
        sub.reportCheck(.{ .outcome = .missing });
        if (attempt + 1 < max_attempts) {
            try testing.expect(sub.advance() == .wait);
            sub.completeWait();
            try testing.expect(sub.advance() == .post);
        }
    }
    try testing.expect(sub.advance() == .done);
    const sum = try sub.summary(testing.allocator);
    try testing.expectEqual(ItemStatus.outcome_unknown, find(sum.items, temp_id).?.status);
    try testing.expectEqual(@as(usize, 1), sum.outcome_unknown);
    testing.allocator.free(sum.items);
    sub.deinit();

    pr.setState(temp_id, .outcome_unknown);
    var retry = try Submission.init(testing.allocator, &pr);
    defer retry.deinit();
    try testing.expect(retry.advance() == .done);
}

test "publication checks have an independent three-attempt budget" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    _ = sub.advance();
    sub.report(.ambiguous, null);
    var check_attempt: u8 = 0;
    while (check_attempt < max_attempts) : (check_attempt += 1) {
        try testing.expect(sub.advance() == .check);
        sub.reportCheck(.{ .outcome = .ambiguous });
        if (check_attempt + 1 < max_attempts) {
            try testing.expect(sub.advance() == .wait);
            sub.completeWait();
        }
    }
    try testing.expect(sub.advance() == .done);
    try testing.expectEqual(@as(u8, 1), sub.attempts[0]);
}

test "publication-check recovery preserves both independent budgets" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var first = try Submission.init(testing.allocator, &pr);
    _ = first.advance();
    first.report(.ambiguous, null);
    _ = first.advance();
    first.reportCheck(.{ .outcome = .ambiguous });
    const checkpoint = first.advance().wait.checkpoint;
    first.deinit();

    var recovered = try Submission.init(testing.allocator, &pr);
    defer recovered.deinit();
    recovered.restoreRetry(checkpoint);
    try testing.expectEqual(@as(u8, 1), recovered.attempts[0]);
    try testing.expectEqual(@as(u8, 1), recovered.check_attempts[0]);
    recovered.completeWait();
    try testing.expect(recovered.advance() == .check);
}

test "retries exhaust into an item failure" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const a = try pr.add(testing.allocator, .{ .kind = .comment, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const step = sub.advance();
        if (step == .wait) {
            sub.completeWait();
            _ = sub.advance(); // consume the re-issued .post
        }
        sub.report(.{ .rejected = error.ServerError }, null);
    }
    try testing.expect(sub.advance() == .done);
    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 1), sum.failed);
    try testing.expectEqual(ApiError.ServerError, find(sum.items, a).?.reason.?);
}

test "a prior-posted draft is skipped (selective retry) and remaps its replies" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    // Simulate a resumed batch: the root already posted as comment 42.
    try pr.addExisting(testing.allocator, .{ .local_id = 1, .kind = .comment, .body = "root", .state = .{ .posted = 42 } });
    const reply = try pr.add(testing.allocator, .{ .kind = .comment, .body = "re", .parent = .{ .draft = 1 } });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    // The only POST is the reply, remapped onto the root's already-known id.
    const s = sub.advance();
    try testing.expectEqual(reply, s.post.temp_id);
    try testing.expectEqual(@as(?CommentId, 42), s.post.parent);
    sub.report(.{ .posted = 43 }, null);

    try testing.expect(sub.advance() == .done);
    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 2), sum.posted); // the seeded root counts as posted
}

test "frozen recovery excludes new Drafts and remaps Replies through checkpoint evidence" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    try pr.addExisting(testing.allocator, .{ .local_id = 1, .kind = .comment, .body = "root", .state = .{ .posted = 42 } });
    try pr.addExisting(testing.allocator, .{ .local_id = 2, .kind = .comment, .body = "reply", .parent = .{ .draft = 1 }, .state = .submitting });
    try pr.addExisting(testing.allocator, .{ .local_id = 3, .kind = .comment, .body = "added after begin" });
    const frozen = [_]SubmissionRunItem{
        .{ .temp_id = 1, .parent = null },
        .{ .temp_id = 2, .parent = .{ .draft = 1 } },
    };

    var recovered = try Submission.initFrozen(testing.allocator, &pr, &frozen);
    defer recovered.deinit();

    const post = recovered.advance().post;
    try testing.expectEqual(@as(TempId, 2), post.temp_id);
    try testing.expectEqual(@as(?CommentId, 42), post.parent);
    recovered.report(.{ .posted = 43 }, null);
    try testing.expect(recovered.advance() == .done);
}

test "fresh Submission retries failed Drafts while frozen recovery preserves their evidence" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    try pr.addExisting(testing.allocator, .{ .local_id = 1, .kind = .comment, .body = "retry", .state = .{ .failed = error.ServerError } });

    var fresh = try Submission.init(testing.allocator, &pr);
    defer fresh.deinit();
    try testing.expectEqual(@as(TempId, 1), fresh.advance().post.temp_id);

    var recovered = try Submission.initFrozen(testing.allocator, &pr, &.{.{ .temp_id = 1, .parent = null }});
    defer recovered.deinit();
    try testing.expect(recovered.advance() == .done);
}

test "selected subtree excludes ancestors siblings unrelated roots and posted descendants" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    try pr.addExisting(testing.allocator, .{ .local_id = 1, .kind = .comment, .body = "ancestor", .state = .{ .posted = 40 } });
    try pr.addExisting(testing.allocator, .{ .local_id = 2, .kind = .comment, .body = "failed", .parent = .{ .draft = 1 }, .state = .{ .failed = error.ServerError } });
    try pr.addExisting(testing.allocator, .{ .local_id = 3, .kind = .comment, .body = "child", .parent = .{ .draft = 2 } });
    try pr.addExisting(testing.allocator, .{ .local_id = 4, .kind = .comment, .body = "published child", .parent = .{ .draft = 2 }, .state = .{ .posted = 41 } });
    try pr.addExisting(testing.allocator, .{ .local_id = 5, .kind = .comment, .body = "below published", .parent = .{ .draft = 4 } });
    try pr.addExisting(testing.allocator, .{ .local_id = 6, .kind = .comment, .body = "sibling", .parent = .{ .draft = 1 } });
    try pr.addExisting(testing.allocator, .{ .local_id = 7, .kind = .comment, .body = "other root" });

    var sub = try Submission.initSubtree(testing.allocator, &pr, 2);
    defer sub.deinit();
    try testing.expectEqualSlices(TempId, &.{ 2, 3, 5 }, sub.order);

    try testing.expectEqual(@as(TempId, 2), sub.advance().post.temp_id);
    sub.report(.{ .posted = 42 }, null);
    try testing.expectEqual(@as(TempId, 3), sub.advance().post.temp_id);
    sub.report(.{ .posted = 43 }, null);
    const below_published = sub.advance().post;
    try testing.expectEqual(@as(TempId, 5), below_published.temp_id);
    try testing.expectEqual(@as(?CommentId, 41), below_published.parent);
}

test "selected subtree refuses unresolved descendants instead of silently excluding them" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    try pr.addExisting(testing.allocator, .{ .local_id = 1, .kind = .comment, .body = "failed", .state = .{ .failed = error.ServerError } });
    try pr.addExisting(testing.allocator, .{ .local_id = 2, .kind = .comment, .body = "unknown", .parent = .{ .draft = 1 }, .state = .outcome_unknown });

    try testing.expectError(error.DraftNotRetryable, Submission.initSubtree(testing.allocator, &pr, 1));
}

test "local-only Drafts are never emitted as Submission posts" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .target = .local, .body = "private" });
    const remote = try pr.add(testing.allocator, .{ .kind = .comment, .body = "publish" });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();
    const step = sub.advance();
    try testing.expectEqual(remote, step.post.temp_id);
}

test "backoffMs has exact one-second and two-second fallback waits" {
    try testing.expectEqual(@as(u64, 0), backoffMs(0));
    try testing.expectEqual(backoff_base_ms, backoffMs(1));
    try testing.expectEqual(backoff_base_ms * 2, backoffMs(2));
    try testing.expectEqual(backoff_base_ms * 2, backoffMs(3));
    try testing.expectEqual(backoff_base_ms * 2, backoffMs(10));
}

test "headChanged detects a moved source head, tolerant of abbreviation" {
    try testing.expect(!headChanged("f6180208c871", "f6180208c871abcd"));
    try testing.expect(!headChanged("f6180208c871abcd", "f6180208c871"));
    try testing.expect(headChanged("f6180208c871", "c034a30e082c"));
    try testing.expect(!headChanged("", "abc")); // unknown → don't warn
}

// A scripted CommentPoster, exercised through a tiny driver that mimics the
// worker loop (posting through the seam, ignoring waits). Proves the seam type
// composes with the engine end to end.
const FakeCommentPoster = struct {
    outcomes: []const PostOutcome,
    existing: ?CommentId = null,
    calls: usize = 0,
    find_calls: usize = 0,

    fn poster(self: *FakeCommentPoster) CommentPoster {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: CommentPoster.VTable = .{ .post = postImpl, .findExisting = findImpl };
    fn postImpl(ptr: *anyopaque, _: Draft, _: ?CommentId) anyerror!PostResult {
        const self: *FakeCommentPoster = @ptrCast(@alignCast(ptr));
        defer self.calls += 1;
        return .{ .outcome = self.outcomes[self.calls] };
    }
    fn findImpl(ptr: *anyopaque, _: Draft, _: ?CommentId) anyerror!CheckResult {
        const self: *FakeCommentPoster = @ptrCast(@alignCast(ptr));
        self.find_calls += 1;
        return if (self.existing) |id| .{ .outcome = .{ .found = id } } else .{ .outcome = .missing };
    }
};

test "driver runs the engine through the CommentPoster seam" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const root = try pr.add(testing.allocator, .{ .kind = .comment, .body = "root" });
    _ = try pr.add(testing.allocator, .{ .kind = .comment, .body = "re", .parent = .{ .draft = root } });

    var fake = FakeCommentPoster{ .outcomes = &.{ .{ .posted = 10 }, .{ .posted = 11 } } };
    const poster = fake.poster();

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    while (true) {
        switch (sub.advance()) {
            .post => |ps| {
                const d = pr.getConst(ps.temp_id).?;
                const result = try poster.post(d.*, ps.parent);
                sub.report(result.outcome, result.retry_after_ms);
            },
            .wait => sub.completeWait(),
            .check => |check| {
                const d = pr.getConst(check.temp_id).?;
                sub.reportCheck(try poster.findExisting(d.*, check.parent));
            },
            .done => break,
            .aborted => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, 2), fake.calls);
    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 2), sum.posted);
}
