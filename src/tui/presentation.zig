//! Presentation — the deterministic state-transition seam between terminal
//! mechanics and the coherent review state the renderer projects (ADR-0012).

const std = @import("std");
const bbr = @import("bbr");
const session_mod = @import("session.zig");
const ArenaRing = @import("arena_ring.zig").ArenaRing;
const Nav = @import("nav.zig").Nav;
const composer_mod = @import("composer.zig");
const Composer = composer_mod.Composer;
const file_enrichment = @import("file_enrichment.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

pub const SessionEpoch = u64;
pub const LoadIntent = u64;
pub const WorkId = u64;

/// Repository-qualified identity copied by value into commands and state. The
/// fixed storage keeps the first command protocol self-owned without exposing
/// another allocator lifetime to the terminal adapter.
pub const ReviewKey = struct {
    workspace_buf: [128]u8 = undefined,
    workspace_len: u8,
    repository_buf: [256]u8 = undefined,
    repository_len: u16,
    pull_request_id: u64,

    pub fn init(workspace_name: []const u8, repository_name: []const u8, pull_request_id: u64) error{NameTooLong}!ReviewKey {
        if (workspace_name.len > 128 or repository_name.len > 256) return error.NameTooLong;
        var key: ReviewKey = .{
            .workspace_len = @intCast(workspace_name.len),
            .repository_len = @intCast(repository_name.len),
            .pull_request_id = pull_request_id,
        };
        @memcpy(key.workspace_buf[0..workspace_name.len], workspace_name);
        @memcpy(key.repository_buf[0..repository_name.len], repository_name);
        return key;
    }

    pub fn workspace(self: *const ReviewKey) []const u8 {
        return self.workspace_buf[0..self.workspace_len];
    }

    pub fn repository(self: *const ReviewKey) []const u8 {
        return self.repository_buf[0..self.repository_len];
    }

    pub fn eql(a: ReviewKey, b: ReviewKey) bool {
        return a.pull_request_id == b.pull_request_id and
            std.mem.eql(u8, a.workspace(), b.workspace()) and
            std.mem.eql(u8, a.repository(), b.repository());
    }

    fn storeKey(self: *const ReviewKey) bbr.review.ReviewKey {
        return .{
            .workspace = self.workspace(),
            .repository = self.repository(),
            .pull_request_id = self.pull_request_id,
        };
    }
};

pub const Dependencies = struct {
    reviews: bbr.review.PendingReviewStore,
    submission_locks: ?bbr.review.SubmissionLocks = null,
    highlight_max_file_bytes: usize = 0,
};

pub const InitialReview = struct {
    key: ReviewKey,
    session: *Session,
};

pub const Boot = struct {
    initial: ?InitialReview = null,
    viewport_rows: usize,
};

pub const SessionLoadOutcome = union(enum) {
    loaded: *Session,
    failed: anyerror,
};

pub const SessionLoaded = struct {
    intent: LoadIntent,
    outcome: SessionLoadOutcome,
};

pub const OwnedInput = union(enum) {
    choose_pull_request: ReviewKey,
    session_loaded: SessionLoaded,
    push_count_digit: u8,
    resize_viewport: usize,
    action: Action,
    composer: ComposerInput,
    ensure_focused_enrichment,
    file_enrichment_completed: FileEnrichmentCompleted,
    post_draft_completed: PostDraftCompleted,
    submission_wait_completed: WaitSubmission,
    request_shutdown,
};

pub const PostDraftCompleted = struct {
    operation_id: bbr.review.OperationId,
    temp_id: bbr.review.TempId,
    outcome: bbr.review.PostOutcome,
    retry_after_ms: ?u64 = null,
};

pub const WaitSubmission = struct {
    operation_id: bbr.review.OperationId,
    temp_id: bbr.review.TempId,
    ms: u64,
};

pub const FileEnrichmentOutcome = union(enum) {
    completed: file_enrichment.Result,
    failed: FileEnrichmentFailure,
};

pub const FileEnrichmentFailure = enum {
    launch_failed,
    out_of_memory,
};

pub const FileEnrichmentCompleted = struct {
    work_id: WorkId,
    session_epoch: SessionEpoch,
    file_index: usize,
    outcome: FileEnrichmentOutcome,
};

pub const TextChunk = struct {
    bytes: [64]u8 = undefined,
    len: u8,

    pub fn init(text: []const u8) error{TextTooLong}!TextChunk {
        if (text.len > 64) return error.TextTooLong;
        var chunk: TextChunk = .{ .len = @intCast(text.len) };
        @memcpy(chunk.bytes[0..text.len], text);
        return chunk;
    }

    pub fn slice(self: *const TextChunk) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ComposerInput = union(enum) {
    insert: TextChunk,
    newline,
    backspace,
    delete_word,
    delete_to_line_start,
    cancel,
    save,
};

/// Session-relative actions whose complete state is Navigation. They are
/// suspended while a replacement is pending, along with every other Action
/// that depends on the currently published review.
pub const Action = enum {
    down,
    up,
    half_page_down,
    half_page_up,
    page_down,
    page_up,
    to_top,
    to_bottom,
    center,
    scroll_cursor_top,
    scroll_cursor_bottom,
    cursor_view_top,
    cursor_view_middle,
    cursor_view_bottom,
    select_down,
    select_up,
    quit,
    open_picker,
    comment,
    inline_comment,
    suggest,
    reply,
    submit,
    help,
    toggle_select,
    clear_selection,
    toggle_resolved,
    toggle_layout,
    cycle_scope,
    isolate,
    next_file,
    prev_file,
    expand_fold,
};

pub const Scope = enum {
    changes,
    fetched,
    whole,

    fn next(self: Scope) Scope {
        return switch (self) {
            .changes => .fetched,
            .fetched => .whole,
            .whole => .changes,
        };
    }
};

pub const Preferences = struct {
    layout: bbr.diff.Layout = .unified,
    scope: Scope = .changes,
    show_resolved: bool = false,
};

pub const LoadSession = struct {
    intent: LoadIntent,
    key: ReviewKey,
};

fn BoundedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize,

        fn init(value: []const u8) error{ValueTooLong}!@This() {
            if (value.len > capacity) return error.ValueTooLong;
            var text: @This() = .{ .len = value.len };
            @memcpy(text.bytes[0..value.len], value);
            return text;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const EnrichFile = struct {
    work_id: WorkId,
    session_epoch: SessionEpoch,
    file_index: usize,
    repo: BoundedText(256),
    source_commit: BoundedText(64),
    destination_commit: BoundedText(64),
    old_path: BoundedText(512),
    new_path: BoundedText(512),
    status: bbr.diff.FileStatus,
    max_file_bytes: usize,

    pub fn repository(self: *const EnrichFile) []const u8 {
        return self.repo.slice();
    }

    pub fn newPath(self: *const EnrichFile) []const u8 {
        return self.new_path.slice();
    }

    pub fn request(self: *const EnrichFile) file_enrichment.Request {
        return .{
            .repo = self.repo.slice(),
            .status = self.status,
            .source_commit = self.source_commit.slice(),
            .destination_commit = self.destination_commit.slice(),
            .old_path = self.old_path.slice(),
            .new_path = self.new_path.slice(),
            .max_file_bytes = self.max_file_bytes,
        };
    }
};

/// Self-owned network payload. It remains valid if the originating Session is
/// replaced while the durable Submission continues.
pub const PostDraft = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    operation_id: bbr.review.OperationId,
    key: ReviewKey,
    draft: bbr.review.Draft,
    parent: ?bbr.review.CommentId,
    dedupe: bool,

    fn create(allocator: Allocator, key: ReviewKey, draft: bbr.review.Draft, step: bbr.review.submission.PostStep) !*PostDraft {
        const command = try allocator.create(PostDraft);
        errdefer allocator.destroy(command);
        command.allocator = allocator;
        command.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer command.arena.deinit();
        command.operation_id = 0;
        command.key = key;
        command.draft = try bbr.review.store.dupeDraft(command.arena.allocator(), draft);
        command.parent = step.parent;
        command.dedupe = step.dedupe;
        return command;
    }

    pub fn destroy(self: *PostDraft) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const OwnedCommand = union(enum) {
    load_session: LoadSession,
    enrich_file: EnrichFile,
    post_draft: *PostDraft,
    wait_submission: WaitSubmission,

    pub fn deinit(self: *OwnedCommand) void {
        switch (self.*) {
            .post_draft => |command| command.destroy(),
            .load_session, .enrich_file, .wait_submission => {},
        }
        self.* = undefined;
    }
};

pub const ReviewProjection = struct {
    key: ReviewKey,
    session_epoch: SessionEpoch,
    pull_request: *const bbr.bitbucket.PullRequest,
    diff: *const bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    buffer: bbr.diff.Buffer,
    /// A value snapshot. Mutating this copy cannot affect Presentation.
    navigation: Nav,
    preferences: Preferences,
    isolated_file: ?usize,
};

pub const Projection = struct {
    review: ?ReviewProjection,
    submission: ?SubmissionProjection,
    composer: ?ComposerProjection,
    replacing: bool,
    replacement_error: ?ReplacementError,
    action_error: ?ActionError,
    fatal_error: ?FatalError,
    shutting_down: bool,
};

pub const SubmissionProjection = struct {
    operation_id: bbr.review.OperationId,
    key: ReviewKey,
    current_temp_id: ?bbr.review.TempId,
    persistence_paused: bool,
};

pub const FatalError = enum {
    file_enrichment_out_of_memory,
};

pub const ComposerProjection = struct {
    label: []const u8,
    body: []const u8,
};

pub const ActionError = enum {
    action_refused,
    buffer_build_failed,
    file_enrichment_launch_failed,
    invalid_selection,
    out_of_memory,
    persistence_failed,
    submission_already_active,
    submission_owned_elsewhere,
    submission_start_failed,
};

const BufferTransactionError = error{ BufferBuildFailed, OutOfMemory };

pub const ReplacementError = enum {
    session_load_failed,
    pending_review_load_failed,
    buffer_build_failed,
    out_of_memory,
};

const Published = struct {
    allocator: Allocator,
    key: ReviewKey,
    epoch: SessionEpoch,
    session: *Session,
    review_arena: std.heap.ArenaAllocator,
    review: bbr.review.PendingReview,
    buffers: ArenaRing(2),
    buffer: bbr.diff.Buffer,
    navigation: Nav,
    expanded_folds: std.ArrayList(*const bbr.diff.Line),
    isolated_file: ?usize,
    composer_arena: std.heap.ArenaAllocator,
    composer: ?Composer,

    fn create(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        key: ReviewKey,
        epoch: SessionEpoch,
        session: *Session,
        viewport_rows: usize,
        preferences: Preferences,
    ) !*Published {
        const published = try allocator.create(Published);
        errdefer allocator.destroy(published);
        errdefer session.destroy();

        published.allocator = allocator;
        published.key = key;
        published.epoch = epoch;
        published.session = session;
        published.review_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer published.review_arena.deinit();
        published.review = store.loadReview(published.review_arena.allocator(), key.storeKey()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.PendingReviewLoadFailed;
        };
        published.buffers = ArenaRing(2).init(allocator);
        errdefer published.buffers.deinit();
        published.expanded_folds = .empty;
        errdefer published.expanded_folds.deinit(allocator);
        published.isolated_file = null;
        published.composer_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer published.composer_arena.deinit();
        published.composer = null;

        const buffer_allocator = published.buffers.begin();
        errdefer published.buffers.abort();
        const enrichment = session.enrichment.projection();
        published.buffer = bbr.diff.buffer.buildWithComments(
            buffer_allocator,
            session.diff,
            preferences.layout,
            session.threads,
            .{
                .drafts = published.review.drafts.items,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
                .show_resolved = preferences.show_resolved,
                .fold_context = preferences.scope == .changes,
                .whole_file = preferences.scope == .whole,
            },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BufferBuildFailed;
        };
        published.buffers.commit();
        published.navigation = Nav.init(published.buffer.rows.len, viewport_rows);
        return published;
    }

    fn destroy(self: *Published) void {
        const allocator = self.allocator;
        if (self.composer) |*composer| composer.deinit();
        self.composer_arena.deinit();
        self.expanded_folds.deinit(allocator);
        self.buffers.deinit();
        self.review_arena.deinit();
        self.session.destroy();
        allocator.destroy(self);
    }

    fn projection(self: *const Published, preferences: Preferences) ReviewProjection {
        return .{
            .key = self.key,
            .session_epoch = self.epoch,
            .pull_request = &self.session.pr,
            .diff = &self.session.diff,
            .threads = self.session.threads,
            .drafts = self.review.drafts.items,
            .buffer = self.buffer,
            .navigation = self.navigation,
            .preferences = preferences,
            .isolated_file = self.isolated_file,
        };
    }

    fn rebuild(
        self: *Published,
        preferences: Preferences,
        expanded_folds: []const *const bbr.diff.Line,
        isolated_file: ?usize,
    ) BufferTransactionError!void {
        const candidate = try self.stageBuffer(preferences, expanded_folds, isolated_file);
        self.buffers.commit();
        self.buffer = candidate;
        self.navigation.setRowCount(candidate.rows.len);
    }

    /// Begin and populate the inactive Buffer generation. The caller must
    /// commit it or abort it after any additional fallible work.
    fn stageBuffer(
        self: *Published,
        preferences: Preferences,
        expanded_folds: []const *const bbr.diff.Line,
        isolated_file: ?usize,
    ) BufferTransactionError!bbr.diff.Buffer {
        const allocator = self.buffers.begin();
        errdefer self.buffers.abort();
        const enrichment = self.session.enrichment.projection();
        const candidate = bbr.diff.buffer.buildWithComments(
            allocator,
            self.session.diff,
            preferences.layout,
            self.session.threads,
            .{
                .show_resolved = preferences.show_resolved,
                .fold_context = preferences.scope == .changes,
                .whole_file = preferences.scope == .whole,
                .expanded = expanded_folds,
                .drafts = self.review.drafts.items,
                .only_file = isolated_file,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
            },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BufferBuildFailed;
        };
        return candidate;
    }
};

const Replacement = struct {
    intent: LoadIntent,
    key: ReviewKey,
};

const IssuedEnrichment = struct {
    work_id: WorkId,
    session_epoch: SessionEpoch,
    file_index: usize,
};

const DurableSubmission = struct {
    allocator: Allocator,
    key: ReviewKey,
    operation_id: bbr.review.OperationId = 0,
    current_temp_id: ?bbr.review.TempId = null,
    lock: bbr.review.SubmissionLockGuard,
    arena: std.heap.ArenaAllocator,
    review: bbr.review.PendingReview,
    machine: bbr.review.Submission,
    phase: enum { post_queued, awaiting_post, wait_queued, awaiting_wait, admission_paused, persistence_paused } = .post_queued,
    pending_admission: ?PendingAdmission = null,
    pending_persistence: ?PendingPersistence = null,

    const Started = struct {
        durable: *DurableSubmission,
        command: *PostDraft,
    };

    const PersistedTransition = struct {
        temp_id: bbr.review.TempId,
        state: bbr.review.DraftState,
    };

    const PendingPersistence = struct {
        transition: PersistedTransition,
        outcome: ?bbr.review.SubmissionOutcome,
        next: ?bbr.review.submission.PostStep = null,
        completion: ?bbr.review.SubmissionCompletion = null,
        checkpoint_done: bool = false,
    };

    const PendingAdmission = union(enum) {
        post: PostDraftCompleted,
        wait: WaitSubmission,
    };

    const AfterPost = union(enum) {
        next: struct { command: *PostDraft, transition: PersistedTransition },
        wait: WaitSubmission,
        finished: struct { completion: bbr.review.SubmissionCompletion, transition: PersistedTransition },
    };

    fn create(allocator: Allocator, store: bbr.review.PendingReviewStore, key: ReviewKey, lock: bbr.review.SubmissionLockGuard) !*DurableSubmission {
        var owned_lock = lock;
        errdefer owned_lock.release();
        const durable = try allocator.create(DurableSubmission);
        errdefer allocator.destroy(durable);
        durable.allocator = allocator;
        durable.key = key;
        durable.lock = owned_lock;
        owned_lock.ptr = null;
        errdefer durable.lock.release();
        durable.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer durable.arena.deinit();
        durable.review = try store.loadReview(durable.arena.allocator(), key.storeKey());
        durable.machine = try bbr.review.Submission.init(durable.arena.allocator(), &durable.review);
        durable.phase = .post_queued;
        durable.pending_admission = null;
        durable.pending_persistence = null;
        return durable;
    }

    /// Takes ownership of `lock`. A null result means the persisted review has
    /// no remote Draft to post. Every failure rolls back all in-memory work and
    /// releases ownership; the store publishes only inside `beginSubmission`.
    fn begin(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        key: ReviewKey,
        source_commit: []const u8,
        lock: bbr.review.SubmissionLockGuard,
    ) !?Started {
        const durable = try create(allocator, store, key, lock);
        errdefer durable.destroy();
        const post = switch (durable.machine.advance()) {
            .post => |value| value,
            .done => {
                durable.destroy();
                return null;
            },
            .wait, .aborted => unreachable,
        };
        const draft = durable.review.getConst(post.temp_id) orelse return error.DraftNotFound;
        const command = try PostDraft.create(allocator, durable.key, draft.*, post);
        errdefer command.destroy();
        const operation_id = try store.beginSubmission(durable.key.storeKey(), source_commit, post.temp_id);
        durable.operation_id = operation_id;
        durable.current_temp_id = post.temp_id;
        command.operation_id = operation_id;
        return .{ .durable = durable, .command = command };
    }

    fn acceptPost(
        self: *DurableSubmission,
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        completed: PostDraftCompleted,
    ) !AfterPost {
        self.machine.report(completed.outcome, completed.retry_after_ms);
        const outcome: bbr.review.SubmissionOutcome = switch (completed.outcome) {
            .posted => |id| .{ .posted = id },
            .rejected => |err| .{ .failed = err },
            .ambiguous => .outcome_unknown,
        };
        switch (self.machine.advance()) {
            .post => |next| {
                self.pending_persistence = .{
                    .transition = .{ .temp_id = completed.temp_id, .state = outcome.draftState() },
                    .outcome = outcome,
                    .next = next,
                };
            },
            .done => {
                const completion: bbr.review.SubmissionCompletion = if (self.machine.isClean()) .clean else .partial;
                self.pending_persistence = .{
                    .transition = .{ .temp_id = completed.temp_id, .state = outcome.draftState() },
                    .outcome = outcome,
                    .completion = completion,
                };
            },
            .aborted => {
                const draft = self.review.getConst(completed.temp_id) orelse return error.DraftNotFound;
                const restore: bbr.review.SubmissionPendingState = switch (draft.state) {
                    .draft => .draft,
                    .failed => |err| .{ .failed = err },
                    .outcome_unknown => .outcome_unknown,
                    else => return error.InvalidSubmissionState,
                };
                const completion: bbr.review.SubmissionCompletion = .{ .aborted = restore };
                self.pending_persistence = .{
                    .transition = .{ .temp_id = completed.temp_id, .state = restore.draftState() },
                    .outcome = null,
                    .completion = completion,
                };
            },
            .wait => |wait| {
                self.phase = .wait_queued;
                return .{ .wait = .{
                    .operation_id = self.operation_id,
                    .temp_id = wait.temp_id,
                    .ms = wait.ms,
                } };
            },
        }
        self.phase = .persistence_paused;
        return self.retryPersistence(allocator, store);
    }

    fn retryPersistence(self: *DurableSubmission, allocator: Allocator, store: bbr.review.PendingReviewStore) !AfterPost {
        const pending = if (self.pending_persistence) |*value| value else return error.NoPendingPersistence;
        var next_command: ?*PostDraft = null;
        if (pending.next) |next| {
            const draft = self.review.getConst(next.temp_id) orelse return error.DraftNotFound;
            next_command = try PostDraft.create(allocator, self.key, draft.*, next);
            next_command.?.operation_id = self.operation_id;
        }
        errdefer if (next_command) |command| command.destroy();

        if (!pending.checkpoint_done) if (pending.outcome) |outcome| {
            try store.checkpointSubmission(
                self.operation_id,
                self.key.storeKey(),
                pending.transition.temp_id,
                outcome,
                if (pending.next) |next| next.temp_id else null,
            );
            self.recordCheckpoint(pending.transition.temp_id, outcome, if (pending.next) |next| next.temp_id else null);
            pending.checkpoint_done = true;
        };

        const transition = pending.transition;
        if (pending.completion) |completion| {
            try store.completeSubmission(self.operation_id, self.key.storeKey(), completion);
            self.pending_persistence = null;
            return .{ .finished = .{ .completion = completion, .transition = transition } };
        }
        const command = next_command orelse return error.MissingNextSubmissionCommand;
        self.pending_persistence = null;
        self.phase = .post_queued;
        return .{ .next = .{ .command = command, .transition = transition } };
    }

    fn completeWait(self: *DurableSubmission, allocator: Allocator, wait: WaitSubmission) !*PostDraft {
        if (self.operation_id != wait.operation_id or self.current_temp_id != wait.temp_id or self.phase != .awaiting_wait)
            return error.StaleSubmissionWait;
        const post = switch (self.machine.advance()) {
            .post => |value| value,
            else => return error.InvalidSubmissionState,
        };
        const draft = self.review.getConst(post.temp_id) orelse return error.DraftNotFound;
        const command = try PostDraft.create(allocator, self.key, draft.*, post);
        command.operation_id = self.operation_id;
        self.phase = .post_queued;
        return command;
    }

    fn recordCheckpoint(self: *DurableSubmission, completed_temp_id: bbr.review.TempId, outcome: bbr.review.SubmissionOutcome, next_temp_id: ?bbr.review.TempId) void {
        self.review.setState(completed_temp_id, outcome.draftState());
        if (next_temp_id) |next| self.review.setState(next, .submitting);
        self.current_temp_id = next_temp_id;
    }

    fn destroy(self: *DurableSubmission) void {
        const allocator = self.allocator;
        self.machine.deinit();
        self.arena.deinit();
        self.lock.release();
        allocator.destroy(self);
    }
};

pub const Presentation = struct {
    allocator: Allocator,
    dependencies: Dependencies,
    viewport_rows: usize,
    preferences: Preferences = .{},
    published: ?*Published = null,
    replacement: ?Replacement = null,
    next_intent: LoadIntent = 0,
    next_session_epoch: SessionEpoch = 0,
    next_work_id: WorkId = 0,
    commands: std.ArrayList(OwnedCommand) = .empty,
    outstanding_loads: usize = 0,
    issued_enrichments: std.ArrayList(IssuedEnrichment) = .empty,
    durable_submission: ?*DurableSubmission = null,
    shutdown_requested: bool = false,
    replacement_error: ?ReplacementError = null,
    action_error: ?ActionError = null,
    fatal_error: ?FatalError = null,

    pub fn init(allocator: Allocator, dependencies: Dependencies, boot: Boot) !Presentation {
        var self: Presentation = .{
            .allocator = allocator,
            .dependencies = dependencies,
            .viewport_rows = boot.viewport_rows,
        };
        errdefer self.deinit();
        if (boot.initial) |initial| {
            self.next_session_epoch = 1;
            self.published = try Published.create(
                allocator,
                dependencies.reviews,
                initial.key,
                self.next_session_epoch,
                initial.session,
                boot.viewport_rows,
                self.preferences,
            );
        }
        return self;
    }

    pub fn deinit(self: *Presentation) void {
        for (self.commands.items) |*command| command.deinit();
        if (self.durable_submission) |durable| durable.destroy();
        if (self.published) |published| published.destroy();
        self.commands.deinit(self.allocator);
        self.issued_enrichments.deinit(self.allocator);
        self.* = undefined;
    }

    /// The sole mutation entry point. Candidate construction consumes a loaded
    /// Session whether it commits, fails, or proves stale.
    pub fn dispatch(self: *Presentation, input: OwnedInput) !void {
        switch (input) {
            .choose_pull_request => |key| if (!self.shutdown_requested) try self.choosePullRequest(key),
            .session_loaded => |completed| self.acceptLoadedSession(completed),
            .push_count_digit => |digit| self.pushCountDigit(digit),
            .resize_viewport => |rows| self.resizeViewport(rows),
            .action => |action| self.applyAction(action),
            .composer => |composer_input| self.applyComposerInput(composer_input),
            .ensure_focused_enrichment => try self.ensureFocusedEnrichment(),
            .file_enrichment_completed => |completed| self.acceptFileEnrichment(completed),
            .post_draft_completed => |completed| self.acceptPostDraft(completed),
            .submission_wait_completed => |completed| self.acceptSubmissionWait(completed),
            .request_shutdown => self.requestShutdown(),
        }
    }

    pub fn takeCommand(self: *Presentation) ?OwnedCommand {
        if (self.commands.items.len == 0) return null;
        const command = self.commands.orderedRemove(0);
        switch (command) {
            .load_session => self.outstanding_loads += 1,
            .enrich_file => |enrich| self.issued_enrichments.appendAssumeCapacity(.{
                .work_id = enrich.work_id,
                .session_epoch = enrich.session_epoch,
                .file_index = enrich.file_index,
            }),
            .post_draft => |post| if (self.durable_submission) |durable| {
                if (durable.operation_id == post.operation_id and durable.current_temp_id == post.draft.local_id and durable.phase == .post_queued)
                    durable.phase = .awaiting_post;
            },
            .wait_submission => |wait| if (self.durable_submission) |durable| {
                if (durable.operation_id == wait.operation_id and durable.current_temp_id == wait.temp_id and durable.phase == .wait_queued)
                    durable.phase = .awaiting_wait;
            },
        }
        return command;
    }

    pub fn projection(self: *const Presentation) Projection {
        return .{
            .review = if (self.published) |published| published.projection(self.preferences) else null,
            .submission = if (self.durable_submission) |durable| .{
                .operation_id = durable.operation_id,
                .key = durable.key,
                .current_temp_id = durable.current_temp_id,
                .persistence_paused = durable.pending_persistence != null,
            } else null,
            .composer = if (self.published) |published| if (published.composer) |*composer| .{
                .label = composer.request.label,
                .body = composer.body(),
            } else null else null,
            .replacing = self.replacement != null,
            .replacement_error = self.replacement_error,
            .action_error = self.action_error,
            .fatal_error = self.fatal_error,
            .shutting_down = self.shutdown_requested,
        };
    }

    pub fn readyToExit(self: *const Presentation) bool {
        return self.shutdown_requested and self.durable_submission == null and self.commands.items.len == 0 and self.outstanding_loads == 0 and self.issued_enrichments.items.len == 0;
    }

    fn requestShutdown(self: *Presentation) void {
        self.shutdown_requested = true;
        var write: usize = 0;
        for (self.commands.items) |command| {
            if (command == .post_draft or command == .wait_submission) {
                self.commands.items[write] = command;
                write += 1;
            }
        }
        self.commands.shrinkRetainingCapacity(write);
        self.replacement = null;
        self.resumeDurableSubmission();
    }

    fn pushCountDigit(self: *Presentation, digit: u8) void {
        if (self.shutdown_requested or self.replacement != null) return;
        if (self.published) |published| published.navigation.pushDigit(digit);
    }

    fn resizeViewport(self: *Presentation, rows: usize) void {
        self.viewport_rows = rows;
        if (self.published) |published| published.navigation.setViewport(rows);
    }

    fn applyAction(self: *Presentation, action: Action) void {
        if (action == .quit) {
            self.requestShutdown();
            return;
        }
        if (self.shutdown_requested) {
            if (action == .submit) self.resumeDurableSubmission();
            return;
        }
        if (self.replacement != null) return;
        const published = self.published orelse return;
        self.action_error = null;
        switch (action) {
            .down => published.navigation.down(),
            .up => published.navigation.up(),
            .half_page_down => published.navigation.halfPageDown(),
            .half_page_up => published.navigation.halfPageUp(),
            .page_down => published.navigation.pageDown(),
            .page_up => published.navigation.pageUp(),
            .to_top => published.navigation.toTop(),
            .to_bottom => published.navigation.toBottom(),
            .center => published.navigation.center(),
            .scroll_cursor_top => published.navigation.scrollCursorTop(),
            .scroll_cursor_bottom => published.navigation.scrollCursorBottom(),
            .cursor_view_top => published.navigation.cursorToViewTop(),
            .cursor_view_middle => published.navigation.cursorToViewMiddle(),
            .cursor_view_bottom => published.navigation.cursorToViewBottom(),
            .select_down => {
                published.navigation.ensureMark();
                published.navigation.down();
            },
            .select_up => {
                published.navigation.ensureMark();
                published.navigation.up();
            },
            .toggle_select => published.navigation.toggleMark(),
            .clear_selection => published.navigation.clearMark(),
            .toggle_resolved => {
                var candidate = self.preferences;
                candidate.show_resolved = !candidate.show_resolved;
                self.publishPreferences(published, candidate);
            },
            .toggle_layout => {
                var candidate = self.preferences;
                candidate.layout = if (candidate.layout == .unified) .side_by_side else .unified;
                self.publishPreferences(published, candidate);
            },
            .cycle_scope => {
                var candidate = self.preferences;
                candidate.scope = candidate.scope.next();
                published.rebuild(candidate, &.{}, published.isolated_file) catch |err| {
                    self.action_error = normalizeActionError(err);
                    return;
                };
                self.preferences = candidate;
                published.expanded_folds.clearRetainingCapacity();
                self.action_error = null;
            },
            .isolate => self.toggleIsolation(published),
            .next_file => self.moveFile(published, 1),
            .prev_file => self.moveFile(published, -1),
            .expand_fold => self.expandFold(published),
            .comment => self.openComposer(published, .{ .kind = .top_level, .label = "New comment" }),
            .reply => self.openReplyComposer(published),
            .inline_comment => self.openInlineComposer(published, .inline_comment),
            .suggest => self.openInlineComposer(published, .suggestion),
            .submit => self.startSubmission(published),
            .open_picker, .help => {},
            .quit => unreachable,
        }
    }

    fn startSubmission(self: *Presentation, published: *Published) void {
        if (self.durable_submission) |durable| {
            if (durable.pending_admission != null) {
                self.resumeSubmissionAdmission(durable);
                return;
            }
            if (durable.pending_persistence != null) {
                self.resumeSubmissionPersistence(durable);
                return;
            }
            self.action_error = .submission_already_active;
            return;
        }
        const locks = self.dependencies.submission_locks orelse {
            self.action_error = .action_refused;
            return;
        };
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .submission_start_failed;
            return;
        };
        const lock = locks.tryAcquire(published.key.storeKey()) catch {
            self.action_error = .submission_start_failed;
            return;
        } orelse {
            self.action_error = .submission_owned_elsewhere;
            return;
        };
        const started = DurableSubmission.begin(
            self.allocator,
            self.dependencies.reviews,
            published.key,
            published.session.pr.source_commit,
            lock,
        ) catch |err| {
            self.action_error = if (err == error.SubmissionAlreadyActive) .submission_already_active else .submission_start_failed;
            return;
        } orelse {
            self.action_error = .action_refused;
            return;
        };
        self.commands.appendAssumeCapacity(.{ .post_draft = started.command });
        self.durable_submission = started.durable;
        published.review.setState(started.durable.current_temp_id.?, .submitting);
        self.action_error = null;
    }

    fn resumeDurableSubmission(self: *Presentation) void {
        const durable = self.durable_submission orelse return;
        if (durable.pending_admission != null) {
            self.resumeSubmissionAdmission(durable);
        } else if (durable.pending_persistence != null) {
            self.resumeSubmissionPersistence(durable);
        }
    }

    fn acceptPostDraft(self: *Presentation, completed: PostDraftCompleted) void {
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != completed.operation_id or durable.current_temp_id != completed.temp_id or durable.phase != .awaiting_post) return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.pending_admission = .{ .post = completed };
            durable.phase = .admission_paused;
            self.action_error = .out_of_memory;
            return;
        };
        self.processPostDraft(durable, completed);
    }

    fn processPostDraft(self: *Presentation, durable: *DurableSubmission, completed: PostDraftCompleted) void {
        const progress = durable.acceptPost(self.allocator, self.dependencies.reviews, completed) catch {
            self.publishDurableCheckpoint(durable);
            self.action_error = .persistence_failed;
            return;
        };
        self.publishSubmissionProgress(durable, progress);
        self.action_error = null;
    }

    fn resumeSubmissionAdmission(self: *Presentation, durable: *DurableSubmission) void {
        const pending = durable.pending_admission orelse return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        switch (pending) {
            .post => |completed| {
                durable.pending_admission = null;
                durable.phase = .awaiting_post;
                self.processPostDraft(durable, completed);
            },
            .wait => |completed| {
                durable.pending_admission = null;
                durable.phase = .awaiting_wait;
                self.processSubmissionWait(durable, completed);
            },
        }
    }

    fn resumeSubmissionPersistence(self: *Presentation, durable: *DurableSubmission) void {
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        const progress = durable.retryPersistence(self.allocator, self.dependencies.reviews) catch {
            self.publishDurableCheckpoint(durable);
            self.action_error = .persistence_failed;
            return;
        };
        self.publishSubmissionProgress(durable, progress);
        self.action_error = null;
    }

    fn publishSubmissionProgress(self: *Presentation, durable: *DurableSubmission, progress: DurableSubmission.AfterPost) void {
        switch (progress) {
            .next => |next| {
                self.recordVisibleTransition(durable, next.transition);
                if (self.published) |published| if (ReviewKey.eql(published.key, durable.key))
                    published.review.setState(durable.current_temp_id.?, .submitting);
                self.commands.appendAssumeCapacity(.{ .post_draft = next.command });
            },
            .wait => |wait| self.commands.appendAssumeCapacity(.{ .wait_submission = wait }),
            .finished => |finished| {
                self.recordVisibleTransition(durable, finished.transition);
                self.durable_submission = null;
                durable.destroy();
            },
        }
    }

    fn acceptSubmissionWait(self: *Presentation, completed: WaitSubmission) void {
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != completed.operation_id or durable.current_temp_id != completed.temp_id or durable.phase != .awaiting_wait) return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.pending_admission = .{ .wait = completed };
            durable.phase = .admission_paused;
            self.action_error = .out_of_memory;
            return;
        };
        self.processSubmissionWait(durable, completed);
    }

    fn processSubmissionWait(self: *Presentation, durable: *DurableSubmission, completed: WaitSubmission) void {
        const command = durable.completeWait(self.allocator, completed) catch {
            durable.pending_admission = .{ .wait = completed };
            durable.phase = .admission_paused;
            self.action_error = .out_of_memory;
            return;
        };
        self.commands.appendAssumeCapacity(.{ .post_draft = command });
        self.action_error = null;
    }

    fn recordVisibleTransition(self: *Presentation, durable: *const DurableSubmission, transition: DurableSubmission.PersistedTransition) void {
        if (self.published) |published| if (ReviewKey.eql(published.key, durable.key))
            published.review.setState(transition.temp_id, transition.state);
    }

    fn publishDurableCheckpoint(self: *Presentation, durable: *const DurableSubmission) void {
        const pending = durable.pending_persistence orelse return;
        if (pending.checkpoint_done) self.recordVisibleTransition(durable, pending.transition);
    }

    fn openComposer(self: *Presentation, published: *Published, request: composer_mod.Request) void {
        if (published.composer != null) return;
        _ = published.composer_arena.reset(.retain_capacity);
        published.composer = Composer.init(published.composer_arena.allocator(), request);
        self.action_error = null;
    }

    fn openReplyComposer(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) {
            self.action_error = .action_refused;
            return;
        }
        const parent: bbr.review.draft.Parent = switch (published.buffer.rows[published.navigation.cursor]) {
            .comment => |row| .{ .comment = row.comment.id },
            .draft => |row| .{ .draft = row.draft.local_id },
            else => {
                self.action_error = .action_refused;
                return;
            },
        };
        self.openComposer(published, .{ .kind = .reply, .parent = parent, .label = "Reply" });
    }

    fn openInlineComposer(self: *Presentation, published: *Published, kind: bbr.review.DraftKind) void {
        if (published.composer != null) return;
        if (published.navigation.cursor >= published.buffer.rows.len) {
            self.action_error = .action_refused;
            return;
        }
        const file_index = published.isolated_file orelse fileIndexForRow(published.buffer, published.navigation.cursor);
        if (file_index >= published.session.diff.files.len) {
            self.action_error = .action_refused;
            return;
        }

        _ = published.composer_arena.reset(.retain_capacity);
        const allocator = published.composer_arena.allocator();
        var lines: std.ArrayList(*const bbr.diff.Line) = .empty;
        if (published.navigation.selection()) |selection| {
            collectSelectedLines(published.buffer, selection[0], selection[1], &lines, allocator) catch {
                self.action_error = .invalid_selection;
                return;
            };
        } else if (lineAtRow(published.buffer.rows[published.navigation.cursor])) |line| {
            lines.append(allocator, line) catch {
                self.action_error = .out_of_memory;
                return;
            };
        }
        const span = spanFromLines(lines.items, kind == .suggestion) catch {
            self.action_error = .invalid_selection;
            return;
        };
        const path = published.session.diff.files[file_index].new_path;
        const anchor: bbr.review.Anchor = .{
            .path = allocator.dupe(u8, path) catch {
                self.action_error = .out_of_memory;
                return;
            },
            .from = span.from,
            .to = span.to,
            .start_from = span.start_from,
            .start_to = span.start_to,
            .commit = allocator.dupe(u8, published.session.pr.source_commit) catch {
                self.action_error = .out_of_memory;
                return;
            },
        };
        const noun = if (kind == .suggestion) "Suggest on" else "Comment on";
        const bottom = span.to orelse span.from orelse 0;
        const top = span.start_to orelse span.start_from;
        const label = (if (top) |first|
            std.fmt.allocPrint(allocator, "{s} {s}:{d}-{d}", .{ noun, path, first, bottom })
        else
            std.fmt.allocPrint(allocator, "{s} {s}:{d}", .{ noun, path, bottom })) catch {
            self.action_error = .out_of_memory;
            return;
        };
        published.composer = Composer.init(allocator, .{ .kind = kind, .anchor = anchor, .label = label });
        if (kind == .suggestion) {
            var seed: std.ArrayList(u8) = .empty;
            for (lines.items, 0..) |line, index| {
                if (index > 0) seed.append(allocator, '\n') catch {
                    published.composer = null;
                    self.action_error = .out_of_memory;
                    return;
                };
                seed.appendSlice(allocator, line.text) catch {
                    published.composer = null;
                    self.action_error = .out_of_memory;
                    return;
                };
            }
            published.composer.?.seed(seed.items) catch {
                published.composer = null;
                self.action_error = .out_of_memory;
                return;
            };
        }
        published.navigation.clearMark();
        self.action_error = null;
    }

    fn applyComposerInput(self: *Presentation, composer_input: ComposerInput) void {
        if (self.shutdown_requested or self.replacement != null) return;
        const published = self.published orelse return;
        const composer = if (published.composer) |*value| value else return;
        switch (composer_input) {
            .insert => |chunk| {
                composer.insert(chunk.slice()) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                self.action_error = null;
            },
            .newline => {
                composer.newline() catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                self.action_error = null;
            },
            .backspace => {
                composer.backspace();
                self.action_error = null;
            },
            .delete_word => {
                composer.deleteWord();
                self.action_error = null;
            },
            .delete_to_line_start => {
                composer.deleteToLineStart();
                self.action_error = null;
            },
            .cancel => {
                composer.deinit();
                published.composer = null;
                self.action_error = null;
            },
            .save => self.saveComposer(published),
        }
    }

    fn ensureFocusedEnrichment(self: *Presentation) !void {
        if (self.shutdown_requested) return;
        const published = self.published orelse return;
        const file_index = published.isolated_file orelse fileIndexForRow(published.buffer, published.navigation.cursor);
        if (file_index >= published.session.diff.files.len or file_index >= published.session.enrichment.len()) return;
        if (!published.session.enrichment.needsEnrichment(file_index)) return;

        const file = published.session.diff.files[file_index];
        const work_id = self.next_work_id + 1;
        const command: EnrichFile = .{
            .work_id = work_id,
            .session_epoch = published.epoch,
            .file_index = file_index,
            .repo = BoundedText(256).init(published.key.repository()) catch {
                self.action_error = .action_refused;
                return;
            },
            .source_commit = BoundedText(64).init(published.session.pr.source_commit) catch {
                self.action_error = .action_refused;
                return;
            },
            .destination_commit = BoundedText(64).init(published.session.pr.destination_commit) catch {
                self.action_error = .action_refused;
                return;
            },
            .old_path = BoundedText(512).init(file.old_path) catch {
                self.action_error = .action_refused;
                return;
            },
            .new_path = BoundedText(512).init(file.new_path) catch {
                self.action_error = .action_refused;
                return;
            },
            .status = file.status,
            .max_file_bytes = self.dependencies.highlight_max_file_bytes,
        };
        var queued_enrichments: usize = 0;
        for (self.commands.items) |queued| if (queued == .enrich_file) {
            queued_enrichments += 1;
        };
        try self.issued_enrichments.ensureTotalCapacity(
            self.allocator,
            self.issued_enrichments.items.len + queued_enrichments + 1,
        );
        try self.commands.append(self.allocator, .{ .enrich_file = command });
        self.next_work_id = work_id;
        published.session.enrichment.markLoading(file_index);
        self.action_error = null;
    }

    fn acceptFileEnrichment(self: *Presentation, completed: FileEnrichmentCompleted) void {
        var issued_index: ?usize = null;
        for (self.issued_enrichments.items, 0..) |issued, index| {
            if (issued.work_id == completed.work_id and
                issued.session_epoch == completed.session_epoch and
                issued.file_index == completed.file_index)
            {
                issued_index = index;
                break;
            }
        }
        if (issued_index == null) {
            if (completed.outcome == .completed) {
                var result = completed.outcome.completed;
                result.deinit();
            }
            return;
        }
        _ = self.issued_enrichments.orderedRemove(issued_index.?);
        const published = self.published;
        const applies = if (published) |current|
            current.epoch == completed.session_epoch and completed.file_index < current.session.enrichment.len()
        else
            false;

        switch (completed.outcome) {
            .failed => |failure| if (applies) {
                const current = published.?;
                current.session.enrichment.resetLoading(completed.file_index);
                switch (failure) {
                    .launch_failed => self.action_error = .file_enrichment_launch_failed,
                    .out_of_memory => {
                        self.requestShutdown();
                        self.fatal_error = .file_enrichment_out_of_memory;
                    },
                }
            },
            .completed => |result_value| {
                var result = result_value;
                defer result.deinit();
                if (!applies) return;
                const current = published.?;
                current.session.enrichment.admit(completed.file_index, &result) catch {
                    self.action_error = .action_refused;
                    return;
                };
                current.rebuild(self.preferences, current.expanded_folds.items, current.isolated_file) catch |err| {
                    self.action_error = normalizeActionError(err);
                    return;
                };
                self.action_error = null;
            },
        }
    }

    fn saveComposer(self: *Presentation, published: *Published) void {
        const composer = if (published.composer) |*value| value else return;
        if (composer.isBlank()) return;
        const review_allocator = published.review_arena.allocator();
        published.review.drafts.ensureUnusedCapacity(review_allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };

        const new_draft = composer.toNewDraft();
        var draft: bbr.review.Draft = .{
            .local_id = published.review.next_id,
            .kind = new_draft.kind,
            .target = new_draft.target,
            .parent = new_draft.parent,
            .body = (if (new_draft.kind == .suggestion)
                std.fmt.allocPrint(review_allocator, "```suggestion\n{s}\n```", .{new_draft.body})
            else
                review_allocator.dupe(u8, new_draft.body)) catch {
                self.action_error = .out_of_memory;
                return;
            },
        };
        if (new_draft.anchor) |anchor| {
            draft.anchor = anchor;
            draft.anchor.?.path = review_allocator.dupe(u8, anchor.path) catch {
                self.action_error = .out_of_memory;
                return;
            };
            if (anchor.commit) |commit| {
                draft.anchor.?.commit = review_allocator.dupe(u8, commit) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
            }
        }

        published.review.drafts.appendAssumeCapacity(draft);
        published.review.next_id += 1;
        const previous_len = published.review.drafts.items.len - 1;
        const candidate = published.stageBuffer(self.preferences, published.expanded_folds.items, published.isolated_file) catch |err| {
            published.review.drafts.shrinkRetainingCapacity(previous_len);
            published.review.next_id -= 1;
            self.action_error = normalizeActionError(err);
            return;
        };

        self.dependencies.reviews.put(published.key.storeKey(), draft) catch {
            published.buffers.abort();
            published.review.drafts.shrinkRetainingCapacity(previous_len);
            published.review.next_id -= 1;
            self.action_error = .persistence_failed;
            return;
        };
        published.buffers.commit();
        published.buffer = candidate;
        published.navigation.setRowCount(candidate.rows.len);
        composer.deinit();
        published.composer = null;
        self.action_error = null;
    }

    fn publishPreferences(self: *Presentation, published: *Published, candidate: Preferences) void {
        published.rebuild(candidate, published.expanded_folds.items, published.isolated_file) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        self.preferences = candidate;
        self.action_error = null;
    }

    fn toggleIsolation(self: *Presentation, published: *Published) void {
        if (published.session.diff.files.len == 0) return;
        const previous = published.isolated_file;
        const candidate = if (previous) |_| null else fileIndexForRow(published.buffer, published.navigation.cursor);
        published.rebuild(self.preferences, published.expanded_folds.items, candidate) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        published.isolated_file = candidate;
        if (previous) |file_index| {
            if (fileHeaderRow(published.buffer, file_index)) |row| published.navigation.jumpTo(row);
        } else {
            published.navigation = Nav.init(published.buffer.rows.len, self.viewport_rows);
        }
        self.action_error = null;
    }

    fn moveFile(self: *Presentation, published: *Published, direction: i2) void {
        if (published.isolated_file) |current| {
            const candidate = if (direction > 0)
                if (current + 1 < published.session.diff.files.len) current + 1 else return
            else if (current > 0)
                current - 1
            else
                return;
            published.rebuild(self.preferences, published.expanded_folds.items, candidate) catch |err| {
                self.action_error = normalizeActionError(err);
                return;
            };
            published.isolated_file = candidate;
            published.navigation = Nav.init(published.buffer.rows.len, self.viewport_rows);
            self.action_error = null;
            return;
        }
        const row = if (direction > 0)
            nextFileHeaderRow(published.buffer, published.navigation.cursor)
        else
            previousFileHeaderRow(published.buffer, published.navigation.cursor);
        if (row) |target| published.navigation.jumpTo(target);
    }

    fn expandFold(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) return;
        if (published.buffer.rows[published.navigation.cursor] != .fold) return;
        const old_len = published.expanded_folds.items.len;
        published.expanded_folds.append(self.allocator, published.buffer.rows[published.navigation.cursor].fold.id) catch {
            self.action_error = .out_of_memory;
            return;
        };
        published.rebuild(self.preferences, published.expanded_folds.items, published.isolated_file) catch |err| {
            published.expanded_folds.shrinkRetainingCapacity(old_len);
            self.action_error = normalizeActionError(err);
            return;
        };
        self.action_error = null;
    }

    fn choosePullRequest(self: *Presentation, key: ReviewKey) !void {
        if (self.published) |published| {
            if (ReviewKey.eql(published.key, key)) {
                self.next_intent += 1; // invalidate a candidate already in flight
                self.replacement = null;
                self.replacement_error = null;
                self.removeQueuedSessionLoads();
                return;
            }
        }

        const intent = self.next_intent + 1;
        // Reserve before changing either the queued command or replacement
        // intent. Once one slot exists, superseding a not-yet-started load is
        // allocation-free and cannot strand Presentation in `.replacing`.
        try self.commands.ensureTotalCapacity(self.allocator, self.commands.items.len + 1);
        // Commands not yet transferred to the terminal adapter are still ours
        // to supersede. Already-taken commands complete normally and are
        // rejected later by their LoadIntent.
        self.removeQueuedSessionLoads();
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key };
        self.replacement_error = null;
    }

    fn removeQueuedSessionLoads(self: *Presentation) void {
        var write: usize = 0;
        for (self.commands.items) |command| {
            if (command == .load_session) continue;
            self.commands.items[write] = command;
            write += 1;
        }
        self.commands.shrinkRetainingCapacity(write);
    }

    fn acceptLoadedSession(self: *Presentation, completed: SessionLoaded) void {
        if (self.outstanding_loads > 0) self.outstanding_loads -= 1;
        const replacement = self.replacement orelse {
            if (completed.outcome == .loaded) completed.outcome.loaded.destroy();
            return;
        };
        if (replacement.intent != completed.intent) {
            if (completed.outcome == .loaded) completed.outcome.loaded.destroy();
            return;
        }

        switch (completed.outcome) {
            .failed => |err| {
                self.replacement = null;
                self.replacement_error = if (err == error.OutOfMemory) .out_of_memory else .session_load_failed;
            },
            .loaded => |session| {
                const epoch = self.next_session_epoch + 1;
                const candidate = Published.create(
                    self.allocator,
                    self.dependencies.reviews,
                    replacement.key,
                    epoch,
                    session,
                    self.viewport_rows,
                    self.preferences,
                ) catch |err| {
                    self.replacement = null;
                    self.replacement_error = switch (err) {
                        error.OutOfMemory => .out_of_memory,
                        error.PendingReviewLoadFailed => .pending_review_load_failed,
                        error.BufferBuildFailed => .buffer_build_failed,
                    };
                    return;
                };

                const previous = self.published;
                self.published = candidate;
                self.next_session_epoch = epoch;
                self.replacement = null;
                self.replacement_error = null;
                self.action_error = null;
                if (previous) |published| published.destroy();
            },
        }
    }
};

fn normalizeActionError(err: BufferTransactionError) ActionError {
    return switch (err) {
        error.BufferBuildFailed => .buffer_build_failed,
        error.OutOfMemory => .out_of_memory,
    };
}

fn lineAtRow(row: bbr.diff.buffer.Row) ?*const bbr.diff.Line {
    return switch (row) {
        .line => |line| line.line,
        .line_pair => |pair| if (pair.right) |right| right.line else if (pair.left) |left| left.line else null,
        else => null,
    };
}

const AnchorSpan = struct {
    from: ?u32 = null,
    to: ?u32 = null,
    start_from: ?u32 = null,
    start_to: ?u32 = null,
};

fn spanFromLines(lines: []const *const bbr.diff.Line, suggestion: bool) !AnchorSpan {
    if (lines.len == 0) return error.NotOnALine;
    var all_new = true;
    var all_old = true;
    for (lines) |line| {
        if (line.new_no == null) all_new = false;
        if (line.old_no == null) all_old = false;
    }
    if (!all_new and !all_old) return error.MixedSides;
    if (all_new) {
        for (lines[1..], 1..) |line, index| {
            if (line.new_no.? != lines[index - 1].new_no.? + 1) return error.NonContiguous;
        }
        const last = lines[lines.len - 1].new_no.?;
        return if (lines.len == 1) .{ .to = last } else .{ .to = last, .start_to = lines[0].new_no.? };
    }
    if (suggestion) return error.SuggestionOnRemoved;
    for (lines[1..], 1..) |line, index| {
        if (line.old_no.? != lines[index - 1].old_no.? + 1) return error.NonContiguous;
    }
    const last = lines[lines.len - 1].old_no.?;
    return if (lines.len == 1) .{ .from = last } else .{ .from = last, .start_from = lines[0].old_no.? };
}

fn collectSelectedLines(
    buffer: bbr.diff.Buffer,
    low: usize,
    high: usize,
    lines: *std.ArrayList(*const bbr.diff.Line),
    allocator: Allocator,
) !void {
    var index = low;
    while (index <= high and index < buffer.rows.len) : (index += 1) {
        if (buffer.rows[index] == .file_header) return error.NonContiguous;
        if (lineAtRow(buffer.rows[index])) |line| try lines.append(allocator, line);
    }
}

fn fileIndexForRow(buffer: bbr.diff.Buffer, cursor: usize) usize {
    var file_index: usize = 0;
    var seen_file = false;
    var row: usize = 0;
    while (row <= cursor and row < buffer.rows.len) : (row += 1) {
        if (buffer.rows[row] == .file_header) {
            if (seen_file) file_index += 1 else seen_file = true;
        }
    }
    return file_index;
}

fn nextFileHeaderRow(buffer: bbr.diff.Buffer, cursor: usize) ?usize {
    var row = cursor +| 1;
    while (row < buffer.rows.len) : (row += 1) {
        if (buffer.rows[row] == .file_header) return row;
    }
    return null;
}

fn previousFileHeaderRow(buffer: bbr.diff.Buffer, cursor: usize) ?usize {
    if (cursor == 0) return null;
    var row = cursor;
    while (row > 0) {
        row -= 1;
        if (buffer.rows[row] == .file_header) return row;
    }
    return null;
}

fn fileHeaderRow(buffer: bbr.diff.Buffer, file_index: usize) ?usize {
    var seen: usize = 0;
    for (buffer.rows, 0..) |row, index| {
        if (row == .file_header) {
            if (seen == file_index) return index;
            seen += 1;
        }
    }
    return null;
}

const testing = std.testing;

fn testSession(backing: std.mem.Allocator, id: u64, marker: u8) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    const raw = try std.fmt.allocPrint(
        a,
        "diff --git a/{c}.zig b/{c}.zig\n--- a/{c}.zig\n+++ b/{c}.zig\n@@ -1 +1 @@\n-old\n+new\n",
        .{ marker, marker, marker, marker },
    );
    s.pr = .{
        .id = id,
        .title = try std.fmt.allocPrint(a, "PR {d}", .{id}),
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.diff = try bbr.diff.parse(a, raw);
    try s.initializeEnrichment();
    return s;
}

fn testTwoFileSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    s.pr = .{
        .id = id,
        .title = "Two files",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.diff = try bbr.diff.parse(a,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old a
        \\+new a
        \\diff --git a/b.zig b/b.zig
        \\--- a/b.zig
        \\+++ b/b.zig
        \\@@ -1 +1 @@
        \\-old b
        \\+new b
    );
    try s.initializeEnrichment();
    return s;
}

test "failed replacement Buffer construction preserves the published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const a = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(failing.allocator(), .{
        .reviews = store.store(),
    }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = a },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;

    const candidate = try testSession(testing.allocator, 2, 'b');
    failing.fail_index = failing.alloc_index + 1; // Published allocation succeeds; Buffer allocation fails.
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = candidate },
    } });

    try testing.expect(failing.has_induced_failure);
    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 1), after.review.?.pull_request.id);
    try testing.expectEqual(before.session_epoch, after.review.?.session_epoch);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, after.review.?.navigation));
    try testing.expectEqual(ReplacementError.out_of_memory, after.replacement_error.?);
}

test "only the latest queued replacement command is exposed" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
    }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 3) });

    const command = presentation.takeCommand().?.load_session;
    try testing.expectEqual(@as(u64, 3), command.key.pull_request_id);
    try testing.expect(presentation.takeCommand() == null);
}

test "a complete candidate publishes atomically and advances the Session Epoch" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 2), after.review.?.pull_request.id);
    try testing.expectEqual(before.session_epoch + 1, after.review.?.session_epoch);
    try testing.expect(after.review.?.buffer.rows.ptr != before.buffer.rows.ptr);
    try testing.expect(!after.replacing);
    try testing.expect(after.replacement_error == null);
}

test "a stale candidate is disposed and the latest failure restores the exact published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const b = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 3) });
    const c = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = b.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = c.intent,
        .outcome = .{ .failed = error.NotFound },
    } });

    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 1), after.review.?.pull_request.id);
    try testing.expectEqual(before.session_epoch, after.review.?.session_epoch);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, after.review.?.navigation));
    try testing.expectEqual(ReplacementError.session_load_failed, after.replacement_error.?);
}

test "shutdown drains issued loads and disposes their late completions" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 1) });
    const command = presentation.takeCommand().?.load_session;

    try presentation.dispatch(.request_shutdown);
    try testing.expect(!presentation.readyToExit());
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 1, 'a') },
    } });

    try testing.expect(presentation.readyToExit());
    try testing.expect(presentation.projection().review == null);
}

test "Navigation and Count mutate only through dispatch" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .push_count_digit = 2 });
    try presentation.dispatch(.{ .action = .down });
    try testing.expectEqual(@as(usize, 2), presentation.projection().review.?.navigation.cursor);
    try presentation.dispatch(.{ .action = .toggle_select });
    try presentation.dispatch(.{ .action = .up });
    const navigation = presentation.projection().review.?.navigation;
    try testing.expectEqual(@as(usize, 1), navigation.cursor);
    try testing.expectEqual(@as(?usize, 2), navigation.mark);
}

test "Session-relative Navigation is suspended during replacement" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .down });
    const before = presentation.projection().review.?.navigation;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .push_count_digit = 9 });
    try testing.expect(std.meta.eql(before, presentation.projection().review.?.navigation));
}

test "failed Buffer transaction preserves Buffer preferences and Navigation" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .down });
    const before = presentation.projection().review.?;

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .action = .toggle_layout });

    const after = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expectEqual(before.buffer.layout, after.review.?.buffer.layout);
    try testing.expect(std.meta.eql(before.preferences, after.review.?.preferences));
    try testing.expect(std.meta.eql(before.navigation, after.review.?.navigation));
    try testing.expectEqual(ActionError.out_of_memory, after.action_error.?);
}

test "preferences survive replacement while file isolation resets" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testTwoFileSession(testing.allocator, 1),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .toggle_layout });
    try presentation.dispatch(.{ .action = .toggle_resolved });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .isolate });
    const isolated = presentation.projection().review.?;
    try testing.expectEqual(@as(?usize, 0), isolated.isolated_file);
    try testing.expectEqual(bbr.diff.Layout.side_by_side, isolated.preferences.layout);
    try testing.expect(isolated.preferences.show_resolved);
    try testing.expectEqual(Scope.fetched, isolated.preferences.scope);

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'c') },
    } });

    const replaced = presentation.projection().review.?;
    try testing.expectEqual(bbr.diff.Layout.side_by_side, replaced.preferences.layout);
    try testing.expect(replaced.preferences.show_resolved);
    try testing.expectEqual(Scope.fetched, replaced.preferences.scope);
    try testing.expectEqual(@as(?usize, null), replaced.isolated_file);
    try testing.expectEqual(@as(usize, 0), replaced.navigation.cursor);
}

test "saving a Composer Draft persists it for a later Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);

    {
        var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
            .viewport_rows = 8,
        });
        defer presentation.deinit();

        try presentation.dispatch(.{ .action = .comment });
        try testing.expectEqualStrings("New comment", presentation.projection().composer.?.label);
        try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("ship it") } });
        try presentation.dispatch(.{ .composer = .save });

        const projection = presentation.projection();
        try testing.expect(projection.composer == null);
        try testing.expectEqual(@as(usize, 1), projection.review.?.drafts.len);
        try testing.expectEqualStrings("ship it", projection.review.?.drafts[0].body);
    }

    var resumed = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer resumed.deinit();
    try testing.expectEqualStrings("ship it", resumed.projection().review.?.drafts[0].body);
}

test "Reply on a Draft row saves a child linked to that Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 7,
        .kind = .top_level,
        .body = "parent",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    const review = presentation.projection().review.?;
    var draft_row: usize = 0;
    for (review.buffer.rows, 0..) |row, index| {
        if (row == .draft) {
            draft_row = index;
            break;
        }
    }
    for (0..draft_row) |_| try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .reply });
    try testing.expectEqualStrings("Reply", presentation.projection().composer.?.label);
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("child") } });
    try presentation.dispatch(.{ .composer = .save });

    const drafts = presentation.projection().review.?.drafts;
    try testing.expectEqual(@as(usize, 2), drafts.len);
    try testing.expectEqualStrings("child", drafts[1].body);
    try testing.expect(drafts[1].parent.? == .draft);
    try testing.expectEqual(@as(bbr.review.TempId, 7), drafts[1].parent.?.draft);
    try testing.expect(drafts[1].anchor == null);
}

test "Suggest derives an Anchor and persists a fenced seeded Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    const review = presentation.projection().review.?;
    var added_row: usize = 0;
    for (review.buffer.rows, 0..) |row, index| switch (row) {
        .line => |line| if (line.line.new_no != null) {
            added_row = index;
            break;
        },
        else => {},
    };
    for (0..added_row) |_| try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .suggest });
    try testing.expectEqualStrings("new", presentation.projection().composer.?.body);
    try presentation.dispatch(.{ .composer = .save });

    const draft = presentation.projection().review.?.drafts[0];
    try testing.expectEqualStrings("```suggestion\nnew\n```", draft.body);
    try testing.expectEqualStrings("a.zig", draft.anchor.?.path);
    try testing.expectEqual(@as(?u32, 1), draft.anchor.?.to);
    try testing.expectEqualStrings("source", draft.anchor.?.commit.?);
}

test "persistence failure preserves Composer and the exact published review" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = bbr.review.InMemoryStore.init(failing.allocator());
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("keep me") } });
    const before = presentation.projection().review.?;

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .composer = .save });

    const failed = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(ActionError.persistence_failed, failed.action_error.?);
    try testing.expectEqualStrings("keep me", failed.composer.?.body);
    try testing.expectEqual(@as(usize, 0), failed.review.?.drafts.len);
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, failed.review.?.navigation));

    failing.fail_index = std.math.maxInt(usize);
    try presentation.dispatch(.{ .composer = .save });
    try testing.expect(presentation.projection().composer == null);
    try testing.expectEqualStrings("keep me", presentation.projection().review.?.drafts[0].body);
}

test "inline Composer allocation failure publishes no invalid Overlay" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    const rows = presentation.projection().review.?.buffer.rows;
    var added_row: usize = 0;
    for (rows, 0..) |row, index| switch (row) {
        .line => |line| if (line.line.new_no != null) {
            added_row = index;
            break;
        },
        else => {},
    };
    for (0..added_row) |_| try presentation.dispatch(.{ .action = .down });

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .action = .suggest });

    const projection = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expect(projection.composer == null);
    try testing.expectEqual(ActionError.out_of_memory, projection.action_error.?);
}

test "failed replacement preserves Composer and successful replacement resets it" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("survive rollback") } });

    const key_two = try ReviewKey.init("workspace", "repo", 2);
    try presentation.dispatch(.{ .choose_pull_request = key_two });
    const failed_command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = failed_command.intent,
        .outcome = .{ .failed = error.NotFound },
    } });
    try testing.expectEqualStrings("survive rollback", presentation.projection().composer.?.body);

    try presentation.dispatch(.{ .choose_pull_request = key_two });
    const successful_command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = successful_command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try testing.expect(presentation.projection().composer == null);
}

test "focused File Enrichment emits one Session Epoch command while in flight" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.ensure_focused_enrichment);
    const command = presentation.takeCommand().?.enrich_file;
    try testing.expectEqual(presentation.projection().review.?.session_epoch, command.session_epoch);
    try testing.expectEqual(@as(usize, 0), command.file_index);
    try testing.expectEqualStrings("repo", command.repository());
    try testing.expectEqualStrings("a.zig", command.newPath());

    try presentation.dispatch(.ensure_focused_enrichment);
    try testing.expect(presentation.takeCommand() == null);
}

const TestNoopHighlighter = struct {
    fn highlighter(self: *TestNoopHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlight };

    fn highlight(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!bbr.highlight.HighlightResult {
        return .{ .spans = &.{} };
    }
};

test "matching File Enrichment is admitted and reprojects whole-file Buffer" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .cycle_scope });
    const before_rows = presentation.projection().review.?.buffer.rows.len;
    try presentation.dispatch(.ensure_focused_enrichment);
    const command = presentation.takeCommand().?.enrich_file;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const replacement = presentation.takeCommand().?.load_session;

    const responses = [_]bbr.http.Canned{
        .{ .status = 200, .body = "prefix\nold\nsuffix\n" },
        .{ .status = 200, .body = "prefix\nnew\nsuffix\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
    var highlighter = TestNoopHighlighter{};
    var result = try @import("file_enrichment.zig").enrich(testing.allocator, client, highlighter.highlighter(), command.request());

    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = .{ .completed = result },
    } });
    result = undefined; // ownership moved into dispatch

    try testing.expect(presentation.projection().review.?.buffer.rows.len > before_rows);
    try testing.expect(presentation.projection().replacing);
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = replacement.intent,
        .outcome = .{ .failed = error.NotFound },
    } });
    try testing.expectEqual(@as(u64, 1), presentation.projection().review.?.pull_request.id);
    try testing.expect(presentation.projection().review.?.buffer.rows.len > before_rows);
}

test "replacement preserves queued File Enrichment for the published rollback Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.ensure_focused_enrichment);
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });

    try testing.expect(presentation.takeCommand().? == .enrich_file);
    try testing.expect(presentation.takeCommand().? == .load_session);
    try testing.expect(presentation.takeCommand() == null);
}

test "stale File Enrichment is disposed without mutating the replacement Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.ensure_focused_enrichment);
    const enrich = presentation.takeCommand().?.enrich_file;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    const before = presentation.projection().review.?;

    const responses = [_]bbr.http.Canned{
        .{ .status = 200, .body = "old\n" },
        .{ .status = 200, .body = "new\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
    var highlighter = TestNoopHighlighter{};
    const result = try file_enrichment.enrich(testing.allocator, client, highlighter.highlighter(), enrich.request());
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = enrich.work_id,
        .session_epoch = enrich.session_epoch,
        .file_index = enrich.file_index,
        .outcome = .{ .completed = result },
    } });

    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 2), after.review.?.pull_request.id);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expect(after.action_error == null);
}

test "admitted File Enrichment survives failed Buffer reprojection" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.ensure_focused_enrichment);
    const command = presentation.takeCommand().?.enrich_file;
    const before = presentation.projection().review.?;

    const responses = [_]bbr.http.Canned{
        .{ .status = 200, .body = "prefix\nold\nsuffix\n" },
        .{ .status = 200, .body = "prefix\nnew\nsuffix\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
    var highlighter = TestNoopHighlighter{};
    const result = try file_enrichment.enrich(testing.allocator, client, highlighter.highlighter(), command.request());

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = .{ .completed = result },
    } });
    const failed = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expectEqual(ActionError.out_of_memory, failed.action_error.?);

    failing.fail_index = std.math.maxInt(usize);
    try presentation.dispatch(.{ .action = .toggle_resolved });
    try testing.expect(presentation.projection().review.?.buffer.rows.len > before.buffer.rows.len);
}

test "File Enrichment launch failure restores retryable pending state" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.ensure_focused_enrichment);
    const first = presentation.takeCommand().?.enrich_file;
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = first.work_id,
        .session_epoch = first.session_epoch,
        .file_index = first.file_index,
        .outcome = .{ .failed = .launch_failed },
    } });
    try testing.expectEqual(ActionError.file_enrichment_launch_failed, presentation.projection().action_error.?);

    try presentation.dispatch(.ensure_focused_enrichment);
    const retry = presentation.takeCommand().?.enrich_file;
    try testing.expect(retry.work_id != first.work_id);
}

test "duplicate File Enrichment completion cannot drain a newer WorkId" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.ensure_focused_enrichment);
    const first = presentation.takeCommand().?.enrich_file;
    const first_failure: FileEnrichmentCompleted = .{
        .work_id = first.work_id,
        .session_epoch = first.session_epoch,
        .file_index = first.file_index,
        .outcome = .{ .failed = .launch_failed },
    };
    try presentation.dispatch(.{ .file_enrichment_completed = first_failure });
    try presentation.dispatch(.ensure_focused_enrichment);
    const retry = presentation.takeCommand().?.enrich_file;

    try presentation.dispatch(.{ .file_enrichment_completed = first_failure });
    try presentation.dispatch(.request_shutdown);
    try testing.expect(!presentation.readyToExit());
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = retry.work_id,
        .session_epoch = retry.session_epoch,
        .file_index = retry.file_index,
        .outcome = .{ .failed = .launch_failed },
    } });
    try testing.expect(presentation.readyToExit());
}

test "File Enrichment out of memory projects a distinct fatal shutdown" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.ensure_focused_enrichment);
    const command = presentation.takeCommand().?.enrich_file;
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = .{ .failed = .out_of_memory },
    } });

    try testing.expectEqual(FatalError.file_enrichment_out_of_memory, presentation.projection().fatal_error.?);
    try testing.expect(presentation.projection().shutting_down);
    try testing.expect(presentation.readyToExit());
}

test "Submission start acquires ownership persists intent and emits one durable POST" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "publish me" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });

    const command = presentation.takeCommand().?.post_draft;
    defer command.destroy();
    try testing.expectEqual(@as(bbr.review.TempId, 1), command.draft.local_id);
    try testing.expectEqualStrings("publish me", command.draft.body);
    const run = (try store.store().activeSubmission(testing.allocator)).?;
    defer {
        testing.allocator.free(run.key.workspace);
        testing.allocator.free(run.key.repository);
        testing.allocator.free(run.source_commit);
    }
    try testing.expectEqual(run.operation_id, command.operation_id);
    try testing.expectEqual(@as(?bbr.review.TempId, 1), run.current_temp_id);
    try testing.expect((try locks.locks().tryAcquire(key.storeKey())) == null);
    try testing.expectEqual(run.operation_id, presentation.projection().submission.?.operation_id);
}

test "Submission lock contention emits no command or durable intent" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "publish me" });
    var other_owner = (try locks.locks().tryAcquire(key.storeKey())).?;
    defer other_owner.release();
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });

    try testing.expect(presentation.takeCommand() == null);
    try testing.expect((try store.store().activeSubmission(testing.allocator)) == null);
    try testing.expectEqual(ActionError.submission_owned_elsewhere, presentation.projection().action_error.?);
}

test "Submission payload and identity survive originating Session replacement" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const first_key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(first_key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "survive replacement" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = first_key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const post = presentation.takeCommand().?.post_draft;
    defer post.destroy();
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    try testing.expectEqual(@as(u64, 2), presentation.projection().review.?.key.pull_request_id);
    try testing.expectEqual(@as(u64, 1), presentation.projection().submission.?.key.pull_request_id);
    try testing.expectEqualStrings("survive replacement", post.draft.body);
}

test "shutdown retains an authorized Submission command and waits for terminal durability" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "finish me" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    try presentation.dispatch(.request_shutdown);

    try testing.expect(!presentation.readyToExit());
    var command = presentation.takeCommand().?;
    defer command.deinit();
    try testing.expect(command == .post_draft);
}

test "Submission persistence failure publishes no command and releases ownership" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = bbr.review.InMemoryStore.init(failing.allocator());
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "publish me" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    var long_commit: [4096]u8 = undefined;
    @memset(&long_commit, 'a');
    presentation.published.?.session.pr.source_commit = &long_commit;
    failing.fail_index = failing.alloc_index;

    try presentation.dispatch(.{ .action = .submit });

    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(ActionError.submission_start_failed, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().submission == null);
    try testing.expect(presentation.takeCommand() == null);
    try testing.expect((try store.store().activeSubmission(testing.allocator)) == null);
    var reacquired = (try locks.locks().tryAcquire(key.storeKey())).?;
    reacquired.release();
}

test "Submission state allocation failure releases ownership before transfer" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "publish me" });
    var presentation = try Presentation.init(failing.allocator(), .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.commands.ensureUnusedCapacity(failing.allocator(), 1);
    failing.fail_index = failing.alloc_index;

    try presentation.dispatch(.{ .action = .submit });

    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(ActionError.submission_start_failed, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().submission == null);
    try testing.expect((try store.store().activeSubmission(testing.allocator)) == null);
    var reacquired = (try locks.locks().tryAcquire(key.storeKey())).?;
    reacquired.release();
}

test "durable POST completion checkpoints outcome and next intent before next command" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "parent" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .reply, .parent = .{ .draft = 1 }, .body = "reply" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var first = presentation.takeCommand().?;
    const operation_id = first.post_draft.operation_id;
    first.deinit();

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expectEqual(@as(bbr.review.CommentId, 900), drafts[0].state.posted);
    try testing.expect(drafts[1].state == .submitting);
    const run = (try store.store().activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(?bbr.review.TempId, 2), run.current_temp_id);
    var second = presentation.takeCommand().?;
    defer second.deinit();
    try testing.expectEqual(operation_id, second.post_draft.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 2), second.post_draft.draft.local_id);
    try testing.expectEqual(@as(?bbr.review.CommentId, 900), second.post_draft.parent);
}

test "stale POST completion cannot mutate the next in-flight Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "first" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .top_level, .body = "second" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var first = presentation.takeCommand().?;
    const operation_id = first.post_draft.operation_id;
    first.deinit();
    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });
    var second = presentation.takeCommand().?;
    defer second.deinit();

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 901 },
    } });

    try testing.expectEqual(@as(?bbr.review.TempId, 2), presentation.projection().submission.?.current_temp_id);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expectEqual(@as(bbr.review.CommentId, 900), drafts[0].state.posted);
    try testing.expect(drafts[1].state == .submitting);
}

test "final successful POST completes clean and releases Submission ownership" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "only" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    const operation_id = post.post_draft.operation_id;
    post.deinit();

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });

    try testing.expect(presentation.takeCommand() == null);
    try testing.expect(presentation.projection().submission == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.store().activeSubmission(arena.allocator())) == null);
    try testing.expectEqual(@as(usize, 0), (try store.store().load(arena.allocator(), key.storeKey())).len);
    var reacquired = (try locks.locks().tryAcquire(key.storeKey())).?;
    reacquired.release();
}

test "retryable POST rejection waits and reissues without checkpointing an outcome" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "retry" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var first = presentation.takeCommand().?;
    const operation_id = first.post_draft.operation_id;
    first.deinit();

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .rejected = error.RateLimited },
        .retry_after_ms = 17,
    } });

    const wait = presentation.takeCommand().?.wait_submission;
    try testing.expectEqual(@as(u64, 17), wait.ms);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const before_retry = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expect(before_retry[0].state == .submitting);
    try presentation.dispatch(.{ .submission_wait_completed = wait });
    var retry = presentation.takeCommand().?;
    defer retry.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 1), retry.post_draft.draft.local_id);
    try testing.expect(!retry.post_draft.dedupe);
}

test "exhausted ambiguous POST persists an immutable unresolved Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "uncertain" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });

    var attempt: u8 = 0;
    while (attempt < bbr.review.submission.max_attempts) : (attempt += 1) {
        var post = presentation.takeCommand().?;
        const operation_id = post.post_draft.operation_id;
        post.deinit();
        try presentation.dispatch(.{ .post_draft_completed = .{
            .operation_id = operation_id,
            .temp_id = 1,
            .outcome = .ambiguous,
        } });
        if (attempt + 1 < bbr.review.submission.max_attempts) {
            const wait = presentation.takeCommand().?.wait_submission;
            try presentation.dispatch(.{ .submission_wait_completed = wait });
        }
    }

    try testing.expect(presentation.projection().submission == null);
    try testing.expect(presentation.projection().review.?.drafts[0].state == .outcome_unknown);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.store().load(arena.allocator(), key.storeKey()))[0].state == .outcome_unknown);
    try presentation.dispatch(.{ .action = .submit });
    try testing.expect(presentation.takeCommand() == null);
}

test "auth rejection aborts Submission and restores the pending Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "keep pending" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var command = presentation.takeCommand().?;
    const operation_id = command.post_draft.operation_id;
    command.deinit();

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .rejected = error.Forbidden },
    } });

    try testing.expect(presentation.projection().submission == null);
    try testing.expect(presentation.projection().review.?.drafts[0].state == .draft);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expect(drafts[0].state == .draft);
    try testing.expect((try store.store().activeSubmission(arena.allocator())) == null);
}

test "non-retryable POST rejection completes partially and retains the failed Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "retain me" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var command = presentation.takeCommand().?;
    const operation_id = command.post_draft.operation_id;
    command.deinit();

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .rejected = error.NotFound },
    } });

    try testing.expect(presentation.projection().submission == null);
    try testing.expectEqual(error.NotFound, presentation.projection().review.?.drafts[0].state.failed);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expectEqual(error.NotFound, drafts[0].state.failed);
    try testing.expect((try store.store().activeSubmission(arena.allocator())) == null);
}

test "checkpoint failure pauses Submission and retry persists before next POST" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "first" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .top_level, .body = "second" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var first = presentation.takeCommand().?;
    const operation_id = first.post_draft.operation_id;
    first.deinit();
    store.fail_next_checkpoint = true;

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });

    try testing.expect(presentation.takeCommand() == null);
    try testing.expect(presentation.projection().submission.?.persistence_paused);
    var before_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer before_arena.deinit();
    const before = try store.store().load(before_arena.allocator(), key.storeKey());
    try testing.expect(before[0].state == .submitting);
    try testing.expect(before[1].state == .draft);

    try presentation.dispatch(.{ .action = .submit });

    var second = presentation.takeCommand().?;
    defer second.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 2), second.post_draft.draft.local_id);
    var after_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer after_arena.deinit();
    const after = try store.store().load(after_arena.allocator(), key.storeKey());
    try testing.expectEqual(@as(bbr.review.CommentId, 900), after[0].state.posted);
    try testing.expect(after[1].state == .submitting);
}

test "terminal persistence retry does not repeat an already-durable checkpoint" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "only" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    const operation_id = post.post_draft.operation_id;
    post.deinit();
    store.fail_next_completion = true;

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });

    try testing.expect(presentation.projection().submission.?.persistence_paused);
    var before_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer before_arena.deinit();
    const run = (try store.store().activeSubmission(before_arena.allocator())).?;
    try testing.expect(run.current_temp_id == null);
    const before = try store.store().load(before_arena.allocator(), key.storeKey());
    try testing.expectEqual(@as(bbr.review.CommentId, 900), before[0].state.posted);
    try testing.expectEqual(@as(?bbr.review.TempId, null), presentation.projection().submission.?.current_temp_id);
    try testing.expectEqual(@as(bbr.review.CommentId, 900), presentation.projection().review.?.drafts[0].state.posted);

    try presentation.dispatch(.{ .action = .submit });

    try testing.expect(presentation.projection().submission == null);
    var after_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer after_arena.deinit();
    try testing.expect((try store.store().activeSubmission(after_arena.allocator())) == null);
    try testing.expectEqual(@as(usize, 0), (try store.store().load(after_arena.allocator(), key.storeKey())).len);
}

test "queue allocation failure retains a POST completion for admission retry" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "only" });
    var presentation = try Presentation.init(failing.allocator(), .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    const operation_id = post.post_draft.operation_id;
    post.deinit();
    while (presentation.commands.items.len < presentation.commands.capacity)
        presentation.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = 99, .key = key } });
    failing.fail_index = failing.alloc_index;

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });

    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(ActionError.out_of_memory, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().submission != null);
    presentation.commands.clearRetainingCapacity();
    failing.fail_index = std.math.maxInt(usize);
    try presentation.dispatch(.{ .action = .submit });
    try testing.expect(presentation.projection().submission == null);
}

test "shutdown retries a paused terminal persistence step" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .top_level, .body = "only" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    const operation_id = post.post_draft.operation_id;
    post.deinit();
    store.fail_next_completion = true;
    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });
    try testing.expect(presentation.projection().submission.?.persistence_paused);

    try presentation.dispatch(.request_shutdown);

    try testing.expect(presentation.readyToExit());
    try testing.expect(presentation.projection().submission == null);
}
