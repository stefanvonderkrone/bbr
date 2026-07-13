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

/// Total tries per retryable item (the first attempt plus retries). After this
/// many failures the item is marked failed and its reply-descendants skipped.
pub const max_attempts: u8 = 3;
const backoff_base_ms: u64 = 200;
const backoff_cap_ms: u64 = 5_000;

/// Backoff before the `n`-th retry (n = the failure count so far, 1-based):
/// exponential from `backoff_base_ms`, doubling, capped at `backoff_cap_ms`.
/// Deterministic — jitter is deferred (a caller can add it to the returned ms).
pub fn backoffMs(attempt: u8) u64 {
    if (attempt == 0) return 0;
    const shift: u6 = @intCast(@min(attempt - 1, 5));
    return @min(backoff_base_ms << shift, backoff_cap_ms);
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

/// The concrete action `advance()` asks the caller to take.
pub const Step = union(enum) {
    /// POST this draft. `parent` is the resolved server `CommentId` for a reply
    /// (null for a root). `dedupe` is set when this is a retry after an
    /// `ambiguous` failure: the caller must GET-and-match first (via
    /// `CommentPoster.findExisting`) and, on a match, report `.posted{that id}`
    /// instead of re-POSTing.
    post: PostStep,
    /// Sleep `ms`, then call `advance()` again (it re-issues the same post).
    wait: struct { ms: u64, temp_id: TempId },
    /// Terminal: the batch finished. Some items may have failed or been skipped
    /// (see `summary`); the caller applies state and, on a clean batch, deletes
    /// the posted drafts (ADR-0007).
    done,
    /// Terminal: an auth failure aborted the whole batch. Everything unposted
    /// stays pending; the caller surfaces the token/scope error.
    aborted: ApiError,
};

pub const PostStep = struct { temp_id: TempId, parent: ?CommentId, dedupe: bool };

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
        error.NotFound, error.UnexpectedStatus, error.MalformedResponse => .fail,
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
    /// Whether the last failure at a position was `ambiguous` (→ dedupe on retry).
    ambiguous_last: []bool,
    /// The decided outcome per `order` position, filled as the batch runs.
    results: []?ItemResult,
    /// A retry is scheduled for the current item: `advance()` emits one `.wait`.
    must_wait: bool = false,
    wait_ms: u64 = 0,
    aborted_reason: ?ApiError = null,
    alloc: Allocator,

    pub fn init(alloc: Allocator, review: *const PendingReview) !Submission {
        const order = try review.topologicalOrder(alloc);
        errdefer alloc.free(order);
        const n = order.len;
        const attempts = try alloc.alloc(u8, n);
        errdefer alloc.free(attempts);
        @memset(attempts, 0);
        const amb = try alloc.alloc(bool, n);
        errdefer alloc.free(amb);
        @memset(amb, false);
        const results = try alloc.alloc(?ItemResult, n);
        @memset(results, null);
        for (order, 0..) |temp_id, i| {
            const draft = review.getConst(temp_id) orelse continue;
            if (draft.state == .outcome_unknown)
                results[i] = .{ .temp_id = temp_id, .status = .outcome_unknown };
        }
        return .{
            .review = review,
            .order = order,
            .attempts = attempts,
            .ambiguous_last = amb,
            .results = results,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Submission) void {
        self.alloc.free(self.order);
        self.alloc.free(self.attempts);
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
                        self.must_wait = false;
                        return .{ .wait = .{ .ms = self.wait_ms, .temp_id = tid } };
                    }
                    return .{ .post = .{ .temp_id = tid, .parent = parent, .dedupe = self.ambiguous_last[i] } };
                },
            }
        }
        return .done;
    }

    /// Feed back the outcome of the `.post` step `advance()` last returned.
    /// `retry_after_ms` overrides the computed backoff (a 429's `Retry-After`).
    pub fn report(self: *Submission, outcome: PostOutcome, retry_after_ms: ?u64) void {
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
                .retry => self.scheduleRetryOrFail(i, err, false, retry_after_ms),
                .fail => self.failItem(i, tid, err),
            },
            .ambiguous => self.scheduleRetryOrFail(i, null, true, retry_after_ms),
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
        return .{ .ok = null }; // parent not in this review → treat as a root
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
        return null;
    }

    fn scheduleRetryOrFail(self: *Submission, i: usize, err: ?ApiError, ambiguous: bool, retry_after_ms: ?u64) void {
        self.attempts[i] += 1;
        if (self.attempts[i] >= max_attempts) {
            if (err) |api_error| {
                self.failItem(i, self.order[i], api_error);
            } else {
                self.results[i] = .{ .temp_id = self.order[i], .status = .outcome_unknown };
                self.idx += 1;
            }
            return;
        }
        self.ambiguous_last[i] = ambiguous;
        self.wait_ms = retry_after_ms orelse backoffMs(self.attempts[i]);
        self.must_wait = true;
    }

    fn failItem(self: *Submission, i: usize, tid: TempId, err: ApiError) void {
        self.results[i] = .{ .temp_id = tid, .status = .failed, .reason = err };
        self.idx += 1;
    }
};

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
        post: *const fn (ptr: *anyopaque, draft: Draft, parent: ?CommentId) anyerror!PostOutcome,
        /// Dedupe lookup for an ambiguous retry: the id of an already-posted
        /// comment matching this draft (path/line/body), or null if none.
        findExisting: *const fn (ptr: *anyopaque, draft: Draft) anyerror!?CommentId,
    };

    pub fn post(self: CommentPoster, draft: Draft, parent: ?CommentId) !PostOutcome {
        return self.vtable.post(self.ptr, draft, parent);
    }

    pub fn findExisting(self: CommentPoster, draft: Draft) !?CommentId {
        return self.vtable.findExisting(self.ptr, draft);
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
    const root = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "root" });
    const reply = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .draft = root } });

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
    const r = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .comment = 99 } });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();
    const s = sub.advance();
    try testing.expectEqual(r, s.post.temp_id);
    try testing.expectEqual(@as(?CommentId, 99), s.post.parent);
}

test "auth failure aborts the whole batch, leaving items pending" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "a" });
    _ = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "b" });

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
    const root = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "root" });
    const child = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .draft = root } });
    const grandchild = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re2", .parent = .{ .draft = child } });
    const other = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "independent" });

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
    _ = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "a" });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    _ = sub.advance(); // .post
    sub.report(.{ .rejected = error.ServerError }, null);
    const w1 = sub.advance();
    try testing.expectEqual(backoffMs(1), w1.wait.ms);
    try testing.expect(sub.advance() == .post); // re-issued after the wait

    sub.report(.{ .rejected = error.ServerError }, null);
    const w2 = sub.advance();
    try testing.expectEqual(backoffMs(2), w2.wait.ms);
    try testing.expect(w2.wait.ms > w1.wait.ms);
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
    _ = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    _ = sub.advance();
    sub.report(.{ .rejected = error.RateLimited }, 12_345);
    try testing.expectEqual(@as(u64, 12_345), sub.advance().wait.ms);
}

test "ambiguous failure sets the dedupe flag on retry" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    const first = sub.advance();
    try testing.expect(!first.post.dedupe);
    sub.report(.ambiguous, null);
    _ = sub.advance(); // .wait
    const retry = sub.advance();
    try testing.expect(retry.post.dedupe); // caller must GET-and-match now
}

test "exhausted ambiguity remains unresolved across selective retry" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const temp_id = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (sub.advance() == .wait) _ = sub.advance();
        sub.report(.ambiguous, null);
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

test "retries exhaust into an item failure" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const a = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "a" });
    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const step = sub.advance();
        if (step == .wait) {
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
    try pr.addExisting(testing.allocator, .{ .local_id = 1, .kind = .top_level, .body = "root", .state = .{ .posted = 42 } });
    const reply = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .draft = 1 } });

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

test "local-only Drafts are never emitted as Submission posts" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    _ = try pr.add(testing.allocator, .{ .kind = .top_level, .target = .local, .body = "private" });
    const remote = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "publish" });

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();
    const step = sub.advance();
    try testing.expectEqual(remote, step.post.temp_id);
}

test "backoffMs is exponential, capped" {
    try testing.expectEqual(@as(u64, 0), backoffMs(0));
    try testing.expectEqual(backoff_base_ms, backoffMs(1));
    try testing.expectEqual(backoff_base_ms * 2, backoffMs(2));
    try testing.expectEqual(backoff_base_ms * 4, backoffMs(3));
    try testing.expectEqual(backoff_cap_ms, backoffMs(10)); // capped
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
    fn postImpl(ptr: *anyopaque, _: Draft, _: ?CommentId) anyerror!PostOutcome {
        const self: *FakeCommentPoster = @ptrCast(@alignCast(ptr));
        defer self.calls += 1;
        return self.outcomes[self.calls];
    }
    fn findImpl(ptr: *anyopaque, _: Draft) anyerror!?CommentId {
        const self: *FakeCommentPoster = @ptrCast(@alignCast(ptr));
        self.find_calls += 1;
        return self.existing;
    }
};

test "driver runs the engine through the CommentPoster seam" {
    var pr = PendingReview.init(1);
    defer pr.deinit(testing.allocator);
    const root = try pr.add(testing.allocator, .{ .kind = .top_level, .body = "root" });
    _ = try pr.add(testing.allocator, .{ .kind = .reply, .body = "re", .parent = .{ .draft = root } });

    var fake = FakeCommentPoster{ .outcomes = &.{ .{ .posted = 10 }, .{ .posted = 11 } } };
    const poster = fake.poster();

    var sub = try Submission.init(testing.allocator, &pr);
    defer sub.deinit();

    while (true) {
        switch (sub.advance()) {
            .post => |ps| {
                const d = pr.getConst(ps.temp_id).?;
                const outcome = try poster.post(d.*, ps.parent);
                sub.report(outcome, null);
            },
            .wait => {}, // a real worker sleeps here
            .done => break,
            .aborted => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, 2), fake.calls);
    const sum = try sub.summary(testing.allocator);
    defer testing.allocator.free(sum.items);
    try testing.expectEqual(@as(usize, 2), sum.posted);
}
