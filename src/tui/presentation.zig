//! Presentation — the deterministic state-transition seam between terminal
//! mechanics and the coherent review state the renderer projects (ADR-0012).

const std = @import("std");
const builtin = @import("builtin");
const bbr = @import("bbr");
const session_mod = @import("session.zig");
const ArenaRing = @import("arena_ring.zig").ArenaRing;
const Nav = @import("nav.zig").Nav;
const composer_mod = @import("composer.zig");
const Composer = composer_mod.Composer;
const file_enrichment = @import("file_enrichment.zig");
const keymap_mod = @import("keymap.zig");
const Picker = @import("picker.zig").Picker;
const FileFinder = @import("picker.zig").FileFinder;
const frame_mod = @import("frame.zig");
const file_tree = frame_mod.file_tree;
const buffer_mod = @import("buffer.zig");
pub const FrameGeometry = frame_mod.Geometry;
pub const Layout = buffer_mod.Layout;

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

pub const SessionEpoch = u64;
pub const LoadIntent = u64;
pub const WorkId = u64;
pub const CommandId = u64;
pub const ReviewKind = enum { remote, local };

/// Copy-safe, fixed-buffer transport representation of `ReviewIdentity`.
/// This owns bytes for queued commands; it is not a second domain identity.
pub const OwnedReviewIdentity = struct {
    kind: ReviewKind = .remote,
    workspace_buf: [128]u8 = undefined,
    workspace_len: u8,
    repository_buf: [768]u8 = undefined,
    repository_len: u16,
    pull_request_id: u64,
    base_ref_buf: [256]u8 = undefined,
    base_ref_len: u16 = 0,
    source_ref_buf: [256]u8 = undefined,
    source_ref_len: u16 = 0,

    pub fn init(workspace_name: []const u8, repository_name: []const u8, pull_request_id: u64) error{NameTooLong}!OwnedReviewIdentity {
        if (workspace_name.len > 128 or repository_name.len > 256) return error.NameTooLong;
        var key: OwnedReviewIdentity = .{
            .workspace_len = @intCast(workspace_name.len),
            .repository_len = @intCast(repository_name.len),
            .pull_request_id = pull_request_id,
        };
        @memcpy(key.workspace_buf[0..workspace_name.len], workspace_name);
        @memcpy(key.repository_buf[0..repository_name.len], repository_name);
        return key;
    }

    pub fn initLocal(repository_id: u64, base_ref: []const u8, source_ref: []const u8) error{NameTooLong}!OwnedReviewIdentity {
        if (base_ref.len > 256 or source_ref.len > 256 or base_ref.len + source_ref.len + 1 > 768)
            return error.NameTooLong;
        var key: OwnedReviewIdentity = .{
            .kind = .local,
            .workspace_len = 6,
            .repository_len = @intCast(base_ref.len + source_ref.len + 1),
            .pull_request_id = repository_id,
            .base_ref_len = @intCast(base_ref.len),
            .source_ref_len = @intCast(source_ref.len),
        };
        @memcpy(key.workspace_buf[0..6], "\x1flocal");
        @memcpy(key.repository_buf[0..base_ref.len], base_ref);
        key.repository_buf[base_ref.len] = 0x1f;
        @memcpy(key.repository_buf[base_ref.len + 1 .. key.repository_len], source_ref);
        @memcpy(key.base_ref_buf[0..base_ref.len], base_ref);
        @memcpy(key.source_ref_buf[0..source_ref.len], source_ref);
        return key;
    }

    pub fn workspace(self: *const OwnedReviewIdentity) []const u8 {
        return self.workspace_buf[0..self.workspace_len];
    }

    pub fn repository(self: *const OwnedReviewIdentity) []const u8 {
        return self.repository_buf[0..self.repository_len];
    }

    pub fn baseRef(self: *const OwnedReviewIdentity) []const u8 {
        return self.base_ref_buf[0..self.base_ref_len];
    }

    pub fn sourceRef(self: *const OwnedReviewIdentity) []const u8 {
        return self.source_ref_buf[0..self.source_ref_len];
    }

    pub fn isRemote(self: OwnedReviewIdentity) bool {
        return self.kind == .remote;
    }

    pub fn identity(self: *const OwnedReviewIdentity) bbr.review.ReviewIdentity {
        return switch (self.kind) {
            .remote => .{ .remote = .{
                .workspace = self.workspace(),
                .repository = self.repository(),
                .pull_request_id = self.pull_request_id,
            } },
            .local => .{ .local = .{
                .repository_id = self.pull_request_id,
                .base_ref = self.baseRef(),
                .source_ref = self.sourceRef(),
            } },
        };
    }

    pub fn eql(a: OwnedReviewIdentity, b: OwnedReviewIdentity) bool {
        return bbr.review.ReviewIdentity.eql(a.identity(), b.identity());
    }

    fn remote(self: *const OwnedReviewIdentity) bbr.review.RemoteReviewIdentity {
        return switch (self.identity()) {
            .remote => |remote_identity| remote_identity,
            .local => unreachable,
        };
    }

    fn storeKey(self: *const OwnedReviewIdentity) bbr.review.RemoteReviewIdentity {
        return .{
            .workspace = self.workspace(),
            .repository = self.repository(),
            .pull_request_id = self.pull_request_id,
        };
    }
};

/// Copy-safe transport for boundaries that can only operate on Remote Reviews.
pub const OwnedRemoteReviewIdentity = struct {
    value: OwnedReviewIdentity,

    fn init(value: OwnedReviewIdentity) OwnedRemoteReviewIdentity {
        std.debug.assert(value.isRemote());
        return .{ .value = value };
    }

    pub fn workspace(self: *const OwnedRemoteReviewIdentity) []const u8 {
        return self.value.workspace();
    }

    pub fn repository(self: *const OwnedRemoteReviewIdentity) []const u8 {
        return self.value.repository();
    }

    pub fn pullRequestId(self: OwnedRemoteReviewIdentity) u64 {
        return self.value.pull_request_id;
    }

    pub fn identity(self: *const OwnedRemoteReviewIdentity) bbr.review.RemoteReviewIdentity {
        return self.value.remote();
    }

    pub fn eql(a: OwnedRemoteReviewIdentity, b: OwnedRemoteReviewIdentity) bool {
        return bbr.review.RemoteReviewIdentity.eql(a.identity(), b.identity());
    }
};

pub const Dependencies = struct {
    reviews: bbr.review.PendingReviewStore,
    anchor_resolver: ?bbr.review.AnchorResolver = null,
    scope_resolver: ?bbr.review.ScopeResolver = null,
    submission_locks: ?bbr.review.SubmissionLocks = null,
    highlight_max_file_bytes: usize = 0,
    file_cache_enabled: bool = true,
    inactive_file_cache_max_bytes: usize = 256 * 1024 * 1024,
    comments_collapsed_rows: usize = 6,
    mouse_enabled: bool = true,
    mouse_vertical_scroll_rows: usize = 3,
    require_source_check: bool = false,
    keymap: keymap_mod.Keymap = .default,
    remote_enabled: bool = true,
    cell_metrics: frame_mod.CellMetrics = .bytes,
};

pub const InitialReview = struct {
    key: OwnedReviewIdentity,
    session: *Session,
};

pub const Boot = struct {
    initial: ?InitialReview = null,
    viewport_rows: usize = 1,
    geometry: ?frame_mod.Geometry = null,
};

pub const SessionLoadOutcome = union(enum) {
    loaded: *Session,
    failed: anyerror,
};

pub const SessionLoaded = struct {
    command_id: CommandId = 0,
    intent: LoadIntent,
    outcome: SessionLoadOutcome,
};

pub const OwnedInput = union(enum) {
    choose_pull_request: OwnedReviewIdentity,
    key: keymap_mod.KeyStroke,
    mouse: MouseInput,
    session_loaded: SessionLoaded,
    push_count_digit: u8,
    resize_viewport: usize,
    resize: frame_mod.Geometry,
    action: Action,
    composer: ComposerInput,
    unknown_resolution: UnknownResolutionInput,
    ensure_focused_enrichment,
    file_enrichment_completed: FileEnrichmentCompleted,
    post_draft_completed: PostDraftCompleted,
    post_draft_launch_failed: PostDraftLaunchFailed,
    submission_wait_completed: WaitSubmission,
    submission_wait_launch_failed: WaitSubmission,
    recovery_checked: RecoveryChecked,
    duplicate_checked: DuplicateChecked,
    pull_requests_loaded: PullRequestsLoaded,
    picker_tick: WorkId,
    clipboard_completed: ClipboardCompleted,
    dismiss_submission_result,
    request_shutdown,

    /// Dispose an input that could not be handed to `dispatch` (for example,
    /// because the terminal event queue is already shutting down).
    pub fn deinit(self: *OwnedInput) void {
        switch (self.*) {
            .session_loaded => |loaded| if (loaded.outcome == .loaded) loaded.outcome.loaded.destroy(),
            .file_enrichment_completed => |completed| if (completed.outcome == .completed) {
                var result = completed.outcome.completed;
                result.deinit();
            },
            .pull_requests_loaded => |loaded| if (loaded.outcome == .loaded) loaded.outcome.loaded.destroy(),
            else => {},
        }
        self.* = undefined;
    }
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
    unsupported,
};

pub const MouseType = enum { press, release, motion, drag };

pub const MouseInput = struct {
    col: u16,
    row: u16,
    button: MouseButton,
    type: MouseType,
    modified: bool = false,
};

pub const PostDraftCompleted = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: ?OwnedRemoteReviewIdentity = null,
    temp_id: bbr.review.TempId,
    outcome: bbr.review.PostOutcome,
    retry_after_ms: ?u64 = null,
};

pub const PostDraftLaunchFailed = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: ?OwnedRemoteReviewIdentity = null,
    temp_id: bbr.review.TempId,
};

pub const WaitSubmission = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: ?OwnedRemoteReviewIdentity = null,
    temp_id: bbr.review.TempId,
    ms: u64,
};

pub const RecoveryOwnership = enum { running_elsewhere, recoverable };

pub const RecoveryNotice = struct {
    operation_id: bbr.review.OperationId,
    key: OwnedReviewIdentity,
    source_commit: BoundedText(64),
    current_temp_id: ?bbr.review.TempId,
    ownership: RecoveryOwnership,
};

pub const CheckRecovery = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: OwnedRemoteReviewIdentity,
    source_commit: BoundedText(64),

    pub fn sourceCommit(self: *const CheckRecovery) []const u8 {
        return self.source_commit.slice();
    }
};

pub const RecoveryCheckOutcome = union(enum) {
    current_source: BoundedText(64),
    failed,
};

pub const RecoveryChecked = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: ?OwnedRemoteReviewIdentity = null,
    outcome: RecoveryCheckOutcome,
};

pub const DuplicateCheckOutcome = union(enum) {
    found: bbr.review.CommentId,
    missing,
    failed,
};

pub const DuplicateChecked = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: ?OwnedRemoteReviewIdentity = null,
    temp_id: bbr.review.TempId,
    outcome: DuplicateCheckOutcome,
};

pub const PullRequestSummaries = struct {
    arena: std.heap.ArenaAllocator,
    prs: []const bbr.bitbucket.PullRequestSummary,

    pub fn create(backing: Allocator) !*PullRequestSummaries {
        const summaries = try backing.create(PullRequestSummaries);
        summaries.arena = std.heap.ArenaAllocator.init(backing);
        summaries.prs = &.{};
        return summaries;
    }

    pub fn destroy(self: *PullRequestSummaries) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
};

pub const PullRequestsLoadOutcome = union(enum) { loaded: *PullRequestSummaries, failed };
pub const PullRequestsLoaded = struct { command_id: CommandId = 0, work_id: WorkId, outcome: PullRequestsLoadOutcome };
pub const ListPullRequests = struct {
    command_id: CommandId = 0,
    work_id: WorkId,
    repository: BoundedText(256),

    pub fn repositoryName(self: *const ListPullRequests) []const u8 {
        return self.repository.slice();
    }
};

pub fn recoveryCheckSucceeded(command_id: CommandId, operation_id: bbr.review.OperationId, identity: ?OwnedRemoteReviewIdentity, source_commit: []const u8) OwnedInput {
    const source = BoundedText(64).init(source_commit) catch return .{ .recovery_checked = .{
        .command_id = command_id,
        .operation_id = operation_id,
        .identity = identity,
        .outcome = .failed,
    } };
    return .{ .recovery_checked = .{
        .command_id = command_id,
        .operation_id = operation_id,
        .identity = identity,
        .outcome = .{ .current_source = source },
    } };
}

fn durableIdentityMatches(expected: OwnedReviewIdentity, actual: ?OwnedRemoteReviewIdentity) bool {
    if (actual == null) return builtin.is_test;
    return expected.isRemote() and OwnedRemoteReviewIdentity.eql(.init(expected), actual.?);
}

pub const FileEnrichmentOutcome = union(enum) {
    completed: file_enrichment.Result,
    failed: FileEnrichmentFailure,
};

pub const FileEnrichmentFailure = enum {
    launch_failed,
    out_of_memory,
};

pub const FileEnrichmentCompleted = struct {
    command_id: CommandId = 0,
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

pub const UnknownResolutionInput = union(enum) {
    digit: u8,
    backspace,
    confirm,
    cancel,
};

/// Session-relative actions whose complete state is Navigation. They are
/// suspended while a replacement is pending, along with every other Action
/// that depends on the currently published review.
pub const Action = @import("action.zig").Action;

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
    layout: Layout = .unified,
    scope: Scope = .changes,
};

pub const LoadSession = struct {
    command_id: CommandId = 0,
    intent: LoadIntent,
    key: OwnedReviewIdentity,
    cause: SessionLoadCause = .picker,
};

pub const SessionLoadCause = enum { picker, refresh, reconciliation };

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
    command_id: CommandId = 0,
    work_id: WorkId,
    session_epoch: SessionEpoch,
    file_index: usize,
    source: EnrichmentSource,
    source_commit: BoundedText(64),
    destination_commit: BoundedText(64),
    old_path: BoundedText(512),
    new_path: BoundedText(512),
    status: bbr.diff.FileStatus,
    max_file_bytes: usize,

    pub fn repository(self: *const EnrichFile) []const u8 {
        return switch (self.source) {
            .remote => |*repo| repo.slice(),
            .local => "",
        };
    }

    pub fn newPath(self: *const EnrichFile) []const u8 {
        return self.new_path.slice();
    }

    pub fn request(self: *const EnrichFile) file_enrichment.Request {
        return .{
            .repo = self.repository(),
            .status = self.status,
            .source_commit = self.source_commit.slice(),
            .destination_commit = self.destination_commit.slice(),
            .old_path = self.old_path.slice(),
            .new_path = self.new_path.slice(),
            .max_file_bytes = self.max_file_bytes,
        };
    }
};

pub const EnrichmentSource = union(enum) {
    remote: BoundedText(256),
    local,
};

/// Self-owned network payload. It remains valid if the originating Session is
/// replaced while the durable Submission continues.
pub const PostDraft = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    operation_id: bbr.review.OperationId,
    command_id: CommandId = 0,
    identity: OwnedRemoteReviewIdentity,
    draft: bbr.review.Draft,
    parent: ?bbr.review.CommentId,
    dedupe: bool,

    fn create(allocator: Allocator, key: OwnedReviewIdentity, draft: bbr.review.Draft, step: bbr.review.submission.PostStep) !*PostDraft {
        const command = try allocator.create(PostDraft);
        errdefer allocator.destroy(command);
        command.allocator = allocator;
        command.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer command.arena.deinit();
        command.operation_id = 0;
        command.identity = .init(key);
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
    check_recovery: CheckRecovery,
    find_duplicate: *PostDraft,
    list_pull_requests: ListPullRequests,
    copy_clipboard: *ClipboardCopy,

    pub fn deinit(self: *OwnedCommand) void {
        switch (self.*) {
            .post_draft, .find_duplicate => |command| command.destroy(),
            .copy_clipboard => |command| command.destroy(),
            .load_session, .enrich_file, .wait_submission, .check_recovery, .list_pull_requests => {},
        }
        self.* = undefined;
    }
};

const CommandTarget = std.meta.Tag(OwnedCommand);

const IssuedCommand = struct {
    id: CommandId,
    target: CommandTarget,
};

fn commandTarget(command: OwnedCommand) CommandTarget {
    return std.meta.activeTag(command);
}

fn setCommandId(command: *OwnedCommand, command_id: CommandId) void {
    switch (command.*) {
        .load_session => |*value| value.command_id = command_id,
        .enrich_file => |*value| value.command_id = command_id,
        .post_draft, .find_duplicate => |value| value.command_id = command_id,
        .wait_submission => |*value| value.command_id = command_id,
        .check_recovery => |*value| value.command_id = command_id,
        .list_pull_requests => |*value| value.command_id = command_id,
        .copy_clipboard => |value| value.command_id = command_id,
    }
}

pub const ClipboardCopy = struct {
    allocator: Allocator,
    command_id: CommandId = 0,
    text: []u8,

    pub fn destroy(self: *ClipboardCopy) void {
        const allocator = self.allocator;
        allocator.free(self.text);
        allocator.destroy(self);
    }
};

pub const ClipboardCompleted = struct {
    command_id: CommandId,
    success: bool,
};

pub const ReviewProjection = struct {
    key: OwnedReviewIdentity,
    identity: bbr.review.ReviewIdentity,
    session_epoch: SessionEpoch,
    header: session_mod.ReviewHeader,
    pull_request: ?*const bbr.bitbucket.PullRequest,
    diff: *const bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    buffer: buffer_mod.Buffer,
    /// A value snapshot. Mutating this copy cannot affect Presentation.
    navigation: Nav,
    preferences: Preferences,
    isolated_file: ?usize,
    frame: frame_mod.Projection,
};

pub const Projection = struct {
    review: ?ReviewProjection,
    submission: ?SubmissionProjection,
    submission_result: ?SubmissionResultProjection,
    recovery: ?RecoveryNotice,
    unknown_resolution: ?UnknownResolutionProjection,
    picker: ?*const Picker,
    picker_tick_scope: ?WorkId,
    file_finder: ?*const FileFinder,
    help_visible: bool,
    action_availability: ActionAvailability,
    loading_pull_request_id: ?u64,
    composer: ?ComposerProjection,
    replacing: bool,
    replacement_error: ?ReplacementError,
    action_error: ?ActionError,
    clipboard_status: ?ClipboardStatus,
    fatal_error: ?FatalError,
    shutting_down: bool,
};

pub const ClipboardStatus = enum { copied, failed };

pub const ActionAvailability = struct {
    remote: bool,
    has_review: bool = true,
    context: keymap_mod.InteractionContext = .diff,
    source: bool = true,

    pub fn available(self: ActionAvailability, action: Action) bool {
        if (!self.has_review) return switch (action) {
            .quit, .help, .open_pull_request_picker => self.remote,
            else => false,
        };
        if (!self.remote) switch (action) {
            .open_pull_request_picker, .submit, .recover_submission, .resolve_unpublished, .link_existing_comment => return false,
            else => {},
        };
        return switch (action) {
            .inline_comment, .suggest, .yank => self.source,
            else => true,
        };
    }
};

pub const SubmissionProjection = struct {
    operation_id: bbr.review.OperationId,
    key: OwnedReviewIdentity,
    current_temp_id: ?bbr.review.TempId,
    persistence_paused: bool,
    completed: usize,
    total: usize,
};

pub const SubmissionResultProjection = struct {
    key: OwnedReviewIdentity,
    completion: bbr.review.SubmissionCompletion,
    posted: usize,
    failed: usize,
    skipped: usize,
    outcome_unknown: usize,
};

pub const FatalError = enum {
    file_enrichment_out_of_memory,
    out_of_memory,
};

pub const ComposerProjection = struct {
    label: []const u8,
    body: []const u8,
};

pub const UnknownResolutionProjection = struct {
    temp_id: bbr.review.TempId,
    comment_id: []const u8,
};

pub const ActionError = enum {
    action_refused,
    buffer_build_failed,
    file_enrichment_launch_failed,
    invalid_selection,
    out_of_memory,
    persistence_failed,
    submission_already_active,
    submission_launch_failed,
    submission_owned_elsewhere,
    submission_start_failed,
    recovery_check_failed,
    recovery_claim_failed,
    recovery_source_changed,
    duplicate_check_failed,
    picker_load_failed,
    local_review_no_picker,
    local_review_no_submission,
    local_review_remote_action_unavailable,
    source_action_unavailable,
    target_action_unavailable,
};

const BufferTransactionError = error{ BufferBuildFailed, OutOfMemory };
const SaveDraftError = BufferTransactionError || error{PersistenceFailed};

pub const ReplacementError = enum {
    session_load_failed,
    pending_review_load_failed,
    buffer_build_failed,
    out_of_memory,
};

const Published = struct {
    const StagedBuffer = struct {
        published: *Published,
        buffer: buffer_mod.Buffer,
        targets: []const frame_mod.SemanticTarget,
        tree: file_tree.Projection,
        geometry: frame_mod.Geometry,
        active: bool = true,

        fn deinit(self: *StagedBuffer) void {
            if (self.active) self.published.buffers.abort();
            self.* = undefined;
        }

        fn publish(self: *StagedBuffer) void {
            std.debug.assert(self.active);
            const previous = self.published.frameProjection();
            self.published.buffers.commit();
            self.published.buffer = self.buffer;
            self.published.targets = self.targets;
            self.published.tree = self.tree;
            self.published.geometry = self.geometry;
            self.published.navigation = frame_mod.restoreNavigation(previous, self.targets, self.geometry);
            self.published.frame_revision += 1;
            self.active = false;
        }
    };

    allocator: Allocator,
    key: OwnedReviewIdentity,
    epoch: SessionEpoch,
    session: *Session,
    review_arena: std.heap.ArenaAllocator,
    review: bbr.review.PendingReview,
    scope_projection: std.ArrayList(bbr.review.ScopeProjectionEntry),
    buffers: ArenaRing(2),
    buffer: buffer_mod.Buffer,
    targets: []const frame_mod.SemanticTarget,
    tree: file_tree.Projection,
    geometry: frame_mod.Geometry,
    frame_revision: frame_mod.Revision,
    cell_metrics: frame_mod.CellMetrics,
    comments_collapsed_rows: usize,
    navigation: Nav,
    expanded_disclosures: std.ArrayList(buffer_mod.DisclosureKey),
    collapsed_directories: std.ArrayList([]const u8),
    focus: frame_mod.PaneFocus,
    isolated_file: ?usize,
    composer_arena: std.heap.ArenaAllocator,
    composer: ?Composer,

    fn create(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        anchor_resolver: ?bbr.review.AnchorResolver,
        scope_resolver: ?bbr.review.ScopeResolver,
        key: OwnedReviewIdentity,
        epoch: SessionEpoch,
        session: *Session,
        geometry: frame_mod.Geometry,
        preferences: Preferences,
        cache_policy: file_enrichment.CachePolicy,
        cell_metrics: frame_mod.CellMetrics,
        comments_collapsed_rows: usize,
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
        const expected_target: bbr.review.CommentTarget = if (key.isRemote()) .bitbucket else .local;
        for (published.review.drafts.items) |draft| {
            if (draft.target != expected_target) return error.PendingReviewLoadFailed;
        }
        published.scope_projection = .empty;
        for (published.review.drafts.items) |draft| {
            if (draft.parent != null) continue;
            const authored = draft.effectiveScope();
            const current_commit = switch (authored) {
                .@"inline" => |anchor| if (anchor.to != null) session.header.source_commit else session.header.base_commit,
                else => session.header.source_commit,
            };
            const resolution: bbr.review.ScopeResolution = if (key.isRemote())
                .{ .resolved = .{ .state = .current, .scope = authored } }
            else if (scope_resolver) |resolver|
                resolver.resolve(published.review_arena.allocator(), authored, current_commit) catch .unavailable
            else if (authored == .@"inline" and anchor_resolver != null) blk: {
                const legacy = anchor_resolver.?.resolve(published.review_arena.allocator(), authored.@"inline", current_commit) catch .unavailable;
                break :blk switch (legacy) {
                    .unavailable => .unavailable,
                    .resolved => |value| .{ .resolved = .{ .state = value.state, .scope = .{ .@"inline" = value.anchor } } },
                };
            } else if (authored == .review)
                .{ .resolved = .{ .state = .current, .scope = .review } }
            else
                .unavailable;
            try published.scope_projection.append(published.review_arena.allocator(), .{ .temp_id = draft.local_id, .resolution = resolution });
        }
        published.buffers = ArenaRing(2).init(allocator);
        errdefer published.buffers.deinit();
        published.expanded_disclosures = .empty;
        errdefer published.expanded_disclosures.deinit(allocator);
        published.collapsed_directories = .empty;
        errdefer published.collapsed_directories.deinit(allocator);
        published.focus = .diff;
        published.isolated_file = null;
        published.composer_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer published.composer_arena.deinit();
        published.composer = null;
        published.geometry = geometry;
        published.frame_revision = 1;
        published.cell_metrics = cell_metrics;
        published.comments_collapsed_rows = comments_collapsed_rows;
        session.enrichment.configureCache(cache_policy);
        if (session.enrichment.len() > 0) session.enrichment.focus(0);

        const buffer_allocator = published.buffers.begin();
        errdefer published.buffers.abort();
        const enrichment = session.enrichment.projection();
        published.buffer = buffer_mod.buildWithComments(
            buffer_allocator,
            session.diff,
            preferences.layout,
            session.threads,
            .{
                .drafts = published.review.drafts.items,
                .scope_projections = published.scope_projection.items,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
                .fold_context = preferences.scope == .changes,
                .whole_file = preferences.scope == .whole,
                .card_width = frame_mod.paneRects(geometry).diff.width,
                .cell_metrics = cell_metrics,
                .collapsed_rows = published.comments_collapsed_rows,
            },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BufferBuildFailed;
        };
        published.targets = try frame_mod.buildTargets(buffer_allocator, published.buffer.rows, cell_metrics);
        const panes = frame_mod.paneRects(geometry);
        published.tree = try file_tree.build(
            buffer_allocator,
            session.diff,
            session.threads,
            published.review.drafts.items,
            published.collapsed_directories.items,
            if (session.diff.files.len == 0) null else 0,
            panes.sidebar_content.width,
            panes.sidebar_content.height,
            if (session.diff.files.len == 0) null else .{ .file = 0 },
            0,
            cell_metrics,
        );
        published.buffers.commit();
        published.navigation = Nav.init(published.buffer.rows.len, panes.diff_content.height);
        return published;
    }

    fn destroy(self: *Published) void {
        const allocator = self.allocator;
        if (self.composer) |*composer| composer.deinit();
        self.composer_arena.deinit();
        self.expanded_disclosures.deinit(allocator);
        for (self.collapsed_directories.items) |path| allocator.free(path);
        self.collapsed_directories.deinit(allocator);
        self.buffers.deinit();
        self.review_arena.deinit();
        self.session.destroy();
        allocator.destroy(self);
    }

    fn projection(self: *const Published, preferences: Preferences) ReviewProjection {
        return .{
            .key = self.key,
            .identity = self.key.identity(),
            .session_epoch = self.epoch,
            .header = self.session.header,
            .pull_request = self.session.remotePullRequestConst(),
            .diff = &self.session.diff,
            .threads = self.session.threads,
            .drafts = self.review.drafts.items,
            .buffer = self.buffer,
            .navigation = self.navigation,
            .preferences = preferences,
            .isolated_file = self.isolated_file,
            .frame = self.frameProjection(),
        };
    }

    fn frameProjection(self: *const Published) frame_mod.Projection {
        return .{
            .revision = self.frame_revision,
            .targets_revision = self.frame_revision,
            .geometry = self.geometry,
            .panes = frame_mod.paneRects(self.geometry),
            .targets = self.targets,
            .buffer = self.buffer,
            .navigation = self.navigation,
            .file_tree = self.tree,
            .focus = self.focus,
        };
    }

    fn rebuild(
        self: *Published,
        preferences: Preferences,
        expanded_disclosures: []const buffer_mod.DisclosureKey,
        isolated_file: ?usize,
    ) BufferTransactionError!void {
        var staged = try self.prepareBuffer(preferences, expanded_disclosures, isolated_file, self.geometry);
        defer staged.deinit();
        staged.publish();
    }

    fn focusEnrichment(self: *Published, preferences: Preferences, file_index: usize) BufferTransactionError!void {
        if (!self.session.enrichment.stageFocus(file_index)) return;
        self.rebuild(preferences, self.expanded_disclosures.items, self.isolated_file) catch |err| {
            self.session.enrichment.rollbackCacheUpdate();
            return err;
        };
        self.session.enrichment.commitCacheUpdate();
    }

    fn saveDraft(
        self: *Published,
        store: bbr.review.PendingReviewStore,
        preferences: Preferences,
        new_draft: bbr.review.NewDraft,
    ) SaveDraftError!void {
        const review_allocator = self.review_arena.allocator();
        const reserved_id = store.reserveTempId(self.key.storeKey()) catch return error.PersistenceFailed;
        try self.review.drafts.ensureUnusedCapacity(review_allocator, 1);

        var draft: bbr.review.Draft = .{
            .local_id = reserved_id,
            .kind = new_draft.kind,
            .target = new_draft.target,
            .parent = new_draft.parent,
            .scope = if (new_draft.parent == null) new_draft.scope else null,
            .snapshot = if (new_draft.snapshot) |snapshot| .{
                .text = try review_allocator.dupe(u8, snapshot.text),
                .selection_start = snapshot.selection_start,
                .selection_len = snapshot.selection_len,
            } else null,
            .body = if (new_draft.kind == .suggestion)
                try std.fmt.allocPrint(review_allocator, "```suggestion\n{s}\n```", .{new_draft.body})
            else
                try review_allocator.dupe(u8, new_draft.body),
        };
        if (draft.scope) |scope| switch (scope) {
            .review => {},
            .file => |file| draft.scope = .{ .file = .{
                .path = try review_allocator.dupe(u8, file.path),
                .source_commit = try review_allocator.dupe(u8, file.source_commit),
            } },
            .@"inline" => |anchor| {
                var owned = anchor;
                owned.path = try review_allocator.dupe(u8, anchor.path);
                if (anchor.commit) |commit| owned.commit = try review_allocator.dupe(u8, commit);
                draft.scope = .{ .@"inline" = owned };
            },
        };
        if (new_draft.anchor) |anchor| {
            draft.anchor = anchor;
            draft.anchor.?.path = try review_allocator.dupe(u8, anchor.path);
            if (anchor.commit) |commit| draft.anchor.?.commit = try review_allocator.dupe(u8, commit);
        }

        const previous_len = self.review.drafts.items.len;
        const previous_projection_len = self.scope_projection.items.len;
        const previous_next_id = self.review.next_id;
        self.review.drafts.appendAssumeCapacity(draft);
        self.review.next_id = @max(self.review.next_id, reserved_id + 1);
        errdefer {
            self.review.drafts.shrinkRetainingCapacity(previous_len);
            self.scope_projection.shrinkRetainingCapacity(previous_projection_len);
            self.review.next_id = previous_next_id;
        }
        if (draft.parent == null) {
            self.scope_projection.append(review_allocator, .{
                .temp_id = draft.local_id,
                .resolution = .{ .resolved = .{ .state = .current, .scope = draft.effectiveScope() } },
            }) catch return error.OutOfMemory;
        }

        var staged = try self.prepareBuffer(preferences, self.expanded_disclosures.items, self.isolated_file, self.geometry);
        defer staged.deinit();
        store.put(self.key.storeKey(), draft) catch return error.PersistenceFailed;
        staged.publish();
    }

    fn prepareBuffer(
        self: *Published,
        preferences: Preferences,
        expanded_disclosures: []const buffer_mod.DisclosureKey,
        isolated_file: ?usize,
        geometry: frame_mod.Geometry,
    ) BufferTransactionError!StagedBuffer {
        const allocator = self.buffers.begin();
        errdefer self.buffers.abort();
        const enrichment = self.session.enrichment.projection();
        const candidate = buffer_mod.buildWithComments(
            allocator,
            self.session.diff,
            preferences.layout,
            self.session.threads,
            .{
                .fold_context = preferences.scope == .changes,
                .whole_file = preferences.scope == .whole,
                .expanded_disclosures = expanded_disclosures,
                .drafts = self.review.drafts.items,
                .scope_projections = self.scope_projection.items,
                .only_file = isolated_file,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
                .card_width = frame_mod.paneRects(geometry).diff.width,
                .cell_metrics = self.cell_metrics,
                .collapsed_rows = self.commentsCollapsedRows(),
            },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BufferBuildFailed;
        };
        const targets = try frame_mod.buildTargets(allocator, candidate.rows, self.cell_metrics);
        const panes = frame_mod.paneRects(geometry);
        const wanted_cursor = if (self.tree.entries.len == 0) null else self.tree.entries[self.tree.cursor].identity;
        const active_file = if (self.session.diff.files.len == 0) null else isolated_file orelse fileIndexForRow(self.buffer, self.navigation.cursor);
        const tree = try file_tree.build(
            allocator,
            self.session.diff,
            self.session.threads,
            self.review.drafts.items,
            self.collapsed_directories.items,
            active_file,
            panes.sidebar_content.width,
            panes.sidebar_content.height,
            wanted_cursor,
            self.tree.scroll,
            self.cell_metrics,
        );
        return .{ .published = self, .buffer = candidate, .targets = targets, .tree = tree, .geometry = geometry };
    }

    fn commentsCollapsedRows(self: *const Published) usize {
        // Published projection policy is supplied by its owning Presentation;
        // keep the value alongside the other process preferences in a field.
        return self.comments_collapsed_rows;
    }

    fn activeFile(self: *const Published) ?usize {
        if (self.session.diff.files.len == 0) return null;
        return self.isolated_file orelse fileIndexForRow(self.buffer, self.navigation.cursor);
    }

    fn sidebarEntry(self: *const Published) ?file_tree.Entry {
        if (self.tree.cursor >= self.tree.entries.len) return null;
        return self.tree.entries[self.tree.cursor];
    }

    fn sidebarVertical(self: *Published, direction: i2) void {
        self.navigation.count = 0;
        if (self.tree.entries.len == 0) return;
        if (direction > 0) self.tree.cursor = @min(self.tree.cursor + 1, self.tree.entries.len - 1) else self.tree.cursor -|= 1;
        if (self.tree.cursor < self.tree.scroll) self.tree.scroll = self.tree.cursor;
        if (self.tree.viewport > 0 and self.tree.cursor >= self.tree.scroll + self.tree.viewport) self.tree.scroll = self.tree.cursor + 1 - self.tree.viewport;
        self.frame_revision += 1;
    }

    fn sidebarScrollRows(self: *Published, delta: isize) void {
        self.navigation.count = 0;
        const max_scroll = self.tree.entries.len -| self.tree.viewport;
        if (delta < 0)
            self.tree.scroll -|= @intCast(-delta)
        else
            self.tree.scroll = @min(self.tree.scroll +| @as(usize, @intCast(delta)), max_scroll);
        if (self.tree.cursor < self.tree.scroll) self.tree.cursor = self.tree.scroll;
        if (self.tree.viewport > 0 and self.tree.cursor >= self.tree.scroll + self.tree.viewport)
            self.tree.cursor = self.tree.scroll + self.tree.viewport - 1;
        self.frame_revision += 1;
    }

    fn cursorToIdentity(self: *Published, identity: file_tree.Identity) void {
        for (self.tree.entries, 0..) |entry, index| if (entry.identity.eql(identity)) {
            self.tree.cursor = index;
            if (index < self.tree.scroll) self.tree.scroll = index;
            if (self.tree.viewport > 0 and index >= self.tree.scroll + self.tree.viewport) self.tree.scroll = index + 1 - self.tree.viewport;
            self.frame_revision += 1;
            return;
        };
    }

    fn cursorToActiveFile(self: *Published) void {
        const active = self.activeFile() orelse return;
        for (self.tree.entries, 0..) |entry, index| {
            const selected = (entry.identity == .file and entry.identity.file == active) or
                (entry.identity == .directory and !entry.expanded and entry.active_descendant);
            if (selected) {
                self.tree.cursor = index;
                if (index < self.tree.scroll) self.tree.scroll = index;
                if (self.tree.viewport > 0 and index >= self.tree.scroll + self.tree.viewport) self.tree.scroll = index + 1 - self.tree.viewport;
                return;
            }
        }
    }

    fn centerActiveFile(self: *Published) void {
        const active = self.activeFile() orelse return;
        for (self.tree.entries, 0..) |entry, index| if (entry.identity == .file and entry.identity.file == active) {
            const half = self.tree.viewport / 2;
            self.tree.scroll = @min(index -| half, self.tree.entries.len -| self.tree.viewport);
            return;
        };
    }

    fn collapseDirectory(self: *Published, path: []const u8) !void {
        for (self.collapsed_directories.items) |candidate| if (std.mem.eql(u8, candidate, path)) return;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.collapsed_directories.append(self.allocator, owned);
    }

    fn takeCollapsedDirectory(self: *Published, path: []const u8) ?[]const u8 {
        for (self.collapsed_directories.items, 0..) |candidate, index| if (std.mem.eql(u8, candidate, path)) {
            _ = self.collapsed_directories.orderedRemove(index);
            return candidate;
        };
        return null;
    }
};

const UnknownResolutionEditor = struct {
    key: OwnedReviewIdentity,
    temp_id: bbr.review.TempId,
    digits: [20]u8 = undefined,
    len: usize = 0,

    fn text(self: *const UnknownResolutionEditor) []const u8 {
        return self.digits[0..self.len];
    }
};

const Replacement = struct {
    intent: LoadIntent,
    key: OwnedReviewIdentity,
};

const IssuedEnrichment = struct {
    work_id: WorkId,
    session_epoch: SessionEpoch,
    file_index: usize,
};

const DurableSubmission = struct {
    allocator: Allocator,
    key: OwnedReviewIdentity,
    operation_id: bbr.review.OperationId = 0,
    current_temp_id: ?bbr.review.TempId = null,
    lock: bbr.review.SubmissionLockGuard,
    arena: std.heap.ArenaAllocator,
    review: bbr.review.PendingReview,
    machine: bbr.review.Submission,
    phase: enum { post_queued, awaiting_post, post_retry_paused, wait_queued, awaiting_wait, wait_retry_paused, admission_paused, persistence_paused, recovery_check_queued, awaiting_recovery_check, recovery_check_paused, recovery_source_changed, duplicate_queued, awaiting_duplicate, duplicate_check_paused, duplicate_persistence_paused } = .post_queued,
    pending_admission: ?PendingAdmission = null,
    pending_persistence: ?PendingPersistence = null,
    pending_wait_retry: ?WaitSubmission = null,
    posted_any: bool = false,
    recovery_source_commit: ?BoundedText(64) = null,
    recovered: bool = false,
    pending_duplicate: ?struct { outcome: DuplicateCheckOutcome, checkpoint_done: bool = false } = null,

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
        finished: struct { result: SubmissionResultProjection, transition: PersistedTransition },
    };

    fn create(allocator: Allocator, store: bbr.review.PendingReviewStore, key: OwnedReviewIdentity, lock: bbr.review.SubmissionLockGuard) !*DurableSubmission {
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
        durable.pending_wait_retry = null;
        durable.posted_any = false;
        durable.recovery_source_commit = null;
        durable.recovered = false;
        durable.pending_duplicate = null;
        return durable;
    }

    /// Takes ownership of `lock`. A null result means the persisted review has
    /// no remote Draft to post. Every failure rolls back all in-memory work and
    /// releases ownership; the store publishes only inside `beginSubmission`.
    fn begin(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        key: OwnedReviewIdentity,
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

    fn recover(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        notice: RecoveryNotice,
        lock: bbr.review.SubmissionLockGuard,
    ) !*DurableSubmission {
        const durable = try create(allocator, store, notice.key, lock);
        errdefer durable.destroy();
        const post = switch (durable.machine.advance()) {
            .post => |value| value,
            else => return error.InvalidRecoveryState,
        };
        if (post.temp_id != notice.current_temp_id.?) return error.InvalidRecoveryState;
        durable.operation_id = notice.operation_id;
        durable.current_temp_id = notice.current_temp_id;
        durable.recovery_source_commit = notice.source_commit;
        durable.recovered = true;
        durable.phase = .recovery_check_queued;
        return durable;
    }

    fn acceptPost(
        self: *DurableSubmission,
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        completed: PostDraftCompleted,
    ) !AfterPost {
        self.machine.report(completed.outcome, completed.retry_after_ms);
        if (completed.outcome == .posted) self.posted_any = true;
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
                    .identity = .init(self.key),
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
            const result = self.resultProjection(completion);
            self.pending_persistence = null;
            return .{ .finished = .{ .result = result, .transition = transition } };
        }
        const command = next_command orelse return error.MissingNextSubmissionCommand;
        self.pending_persistence = null;
        self.phase = .post_queued;
        return .{ .next = .{ .command = command, .transition = transition } };
    }

    fn completeWait(self: *DurableSubmission, allocator: Allocator, wait: WaitSubmission) !*PostDraft {
        if (self.operation_id != wait.operation_id or self.current_temp_id != wait.temp_id or self.phase != .awaiting_wait)
            return error.StaleSubmissionWait;
        return self.materializeCurrentPost(allocator);
    }

    fn materializeCurrentPost(self: *DurableSubmission, allocator: Allocator) !*PostDraft {
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

    fn retryPost(self: *DurableSubmission, allocator: Allocator) !*PostDraft {
        if (self.phase != .post_retry_paused) return error.InvalidSubmissionState;
        return self.materializeCurrentPost(allocator);
    }

    fn materializeDuplicateCheck(self: *DurableSubmission, allocator: Allocator) !*PostDraft {
        const post = switch (self.machine.advance()) {
            .post => |value| value,
            else => return error.InvalidRecoveryState,
        };
        if (self.current_temp_id != post.temp_id) return error.InvalidRecoveryState;
        const draft = self.review.getConst(post.temp_id) orelse return error.DraftNotFound;
        const command = try PostDraft.create(allocator, self.key, draft.*, post);
        command.operation_id = self.operation_id;
        command.dedupe = true;
        self.phase = .duplicate_queued;
        return command;
    }

    fn recordCheckpoint(self: *DurableSubmission, completed_temp_id: bbr.review.TempId, outcome: bbr.review.SubmissionOutcome, next_temp_id: ?bbr.review.TempId) void {
        self.review.setState(completed_temp_id, outcome.draftState());
        if (next_temp_id) |next| self.review.setState(next, .submitting);
        self.current_temp_id = next_temp_id;
    }

    fn progress(self: *const DurableSubmission) struct { completed: usize, total: usize } {
        var completed: usize = 0;
        var total: usize = 0;
        for (self.machine.order, self.machine.results) |temp_id, result| {
            const draft = self.review.getConst(temp_id) orelse continue;
            if (draft.target != .bitbucket) continue;
            total += 1;
            if (result != null) completed += 1;
        }
        return .{ .completed = completed, .total = total };
    }

    fn resultProjection(self: *const DurableSubmission, completion: bbr.review.SubmissionCompletion) SubmissionResultProjection {
        var result: SubmissionResultProjection = .{
            .key = self.key,
            .completion = completion,
            .posted = 0,
            .failed = 0,
            .skipped = 0,
            .outcome_unknown = 0,
        };
        for (self.machine.results) |maybe| if (maybe) |item| switch (item.status) {
            .posted => result.posted += 1,
            .failed => result.failed += 1,
            .skipped => result.skipped += 1,
            .outcome_unknown => result.outcome_unknown += 1,
        };
        return result;
    }

    fn persistedResultProjection(self: *const DurableSubmission, completion: bbr.review.SubmissionCompletion) SubmissionResultProjection {
        var result: SubmissionResultProjection = .{
            .key = self.key,
            .completion = completion,
            .posted = 0,
            .failed = 0,
            .skipped = 0,
            .outcome_unknown = 0,
        };
        for (self.review.drafts.items) |draft| {
            if (draft.target != .bitbucket) continue;
            switch (draft.state) {
                .posted => result.posted += 1,
                .failed => result.failed += 1,
                .outcome_unknown, .submitting => result.outcome_unknown += 1,
                .draft => result.skipped += 1,
            }
        }
        return result;
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
    geometry: frame_mod.Geometry,
    preferences: Preferences = .{},
    published: ?*Published = null,
    replacement: ?Replacement = null,
    next_intent: LoadIntent = 0,
    next_session_epoch: SessionEpoch = 0,
    next_work_id: WorkId = 0,
    next_command_id: CommandId = 0,
    commands: std.ArrayList(OwnedCommand) = .empty,
    issued_commands: std.ArrayList(IssuedCommand) = .empty,
    outstanding_loads: usize = 0,
    outstanding_picker_loads: usize = 0,
    issued_enrichments: std.ArrayList(IssuedEnrichment) = .empty,
    resolver: keymap_mod.Resolver = .{},
    picker: ?Picker = null,
    file_finder: ?FileFinder = null,
    picker_summaries: ?*PullRequestSummaries = null,
    picker_work_id: ?WorkId = null,
    help_visible: bool = false,
    durable_submission: ?*DurableSubmission = null,
    submission_result: ?SubmissionResultProjection = null,
    recovery: ?RecoveryNotice = null,
    unknown_resolution: ?UnknownResolutionEditor = null,
    shutdown_requested: bool = false,
    replacement_error: ?ReplacementError = null,
    action_error: ?ActionError = null,
    fatal_error: ?FatalError = null,
    clipboard_status: ?ClipboardStatus = null,
    interaction_revision: frame_mod.Revision = 1,
    mouse_press: ?MousePress = null,

    const MousePress = struct {
        revision: frame_mod.Revision,
        target: frame_mod.HitTarget,
    };

    pub fn init(allocator: Allocator, dependencies: Dependencies, boot: Boot) !Presentation {
        const geometry: frame_mod.Geometry = boot.geometry orelse .{
            .cols = 80,
            .rows = @as(u16, @intCast(@min(boot.viewport_rows, std.math.maxInt(u16)))),
        };
        var self: Presentation = .{
            .allocator = allocator,
            .dependencies = dependencies,
            .geometry = geometry,
        };
        errdefer self.deinit();
        if (boot.initial) |initial| {
            self.next_session_epoch = 1;
            self.published = try Published.create(
                allocator,
                dependencies.reviews,
                dependencies.anchor_resolver,
                dependencies.scope_resolver,
                initial.key,
                self.next_session_epoch,
                initial.session,
                geometry,
                self.preferences,
                .{
                    .enabled = dependencies.file_cache_enabled,
                    .max_retained_bytes = dependencies.inactive_file_cache_max_bytes,
                },
                dependencies.cell_metrics,
                dependencies.comments_collapsed_rows,
            );
        }
        self.discoverRecovery();
        return self;
    }

    pub fn deinit(self: *Presentation) void {
        for (self.commands.items) |*command| command.deinit();
        if (self.durable_submission) |durable| durable.destroy();
        if (self.picker) |*picker| picker.deinit();
        if (self.file_finder) |*finder| finder.deinit();
        if (self.picker_summaries) |summaries| summaries.destroy();
        if (self.published) |published| published.destroy();
        self.commands.deinit(self.allocator);
        self.issued_commands.deinit(self.allocator);
        self.issued_enrichments.deinit(self.allocator);
        self.* = undefined;
    }

    /// The sole mutation entry point. Candidate construction consumes a loaded
    /// Session whether it commits, fails, or proves stale.
    pub fn dispatch(self: *Presentation, input: OwnedInput) !void {
        // A candidate completion is not itself an interaction or a Frame
        // change. Keep a press across rollback; a committed replacement
        // invalidates it below when the new Session becomes published.
        if (input != .mouse and input != .session_loaded) {
            self.mouse_press = null;
            self.interaction_revision +%= 1;
        }
        switch (input) {
            .choose_pull_request => |key| if (!self.shutdown_requested) try self.choosePullRequest(key),
            .key => |key| try self.applyKey(key),
            .mouse => |mouse| self.applyMouse(mouse),
            .session_loaded => |completed| self.acceptLoadedSession(completed),
            .push_count_digit => |digit| self.pushCountDigit(digit),
            .resize_viewport => |rows| self.resizeViewport(rows),
            .resize => |geometry| self.resize(geometry),
            .action => |action| self.applyAction(action),
            .composer => |composer_input| self.applyComposerInput(composer_input),
            .unknown_resolution => |resolution_input| self.applyUnknownResolutionInput(resolution_input),
            .ensure_focused_enrichment => try self.ensureFocusedEnrichment(),
            .file_enrichment_completed => |completed| self.acceptFileEnrichment(completed),
            .post_draft_completed => |completed| self.acceptPostDraft(completed),
            .post_draft_launch_failed => |failed| self.acceptPostDraftLaunchFailure(failed),
            .submission_wait_completed => |completed| self.acceptSubmissionWait(completed),
            .submission_wait_launch_failed => |failed| self.acceptSubmissionWaitLaunchFailure(failed),
            .recovery_checked => |checked| self.acceptRecoveryCheck(checked),
            .duplicate_checked => |checked| self.acceptDuplicateCheck(checked),
            .pull_requests_loaded => |loaded| self.acceptPullRequests(loaded),
            .picker_tick => |scope| if (!self.shutdown_requested and self.picker_work_id == scope) {
                if (self.picker) |*active_picker| active_picker.tick();
            },
            .clipboard_completed => |completed| {
                if (!self.consumeCommand(completed.command_id, .copy_clipboard)) return;
                self.clipboard_status = if (completed.success) .copied else .failed;
                self.action_error = null;
            },
            .dismiss_submission_result => self.submission_result = null,
            .request_shutdown => self.requestShutdown(),
        }
    }

    pub fn takeCommand(self: *Presentation) ?OwnedCommand {
        if (self.commands.items.len == 0) return null;
        var command = self.commands.orderedRemove(0);
        self.next_command_id +%= 1;
        if (self.next_command_id == 0) self.next_command_id = 1;
        const command_id = self.next_command_id;
        setCommandId(&command, command_id);
        self.issued_commands.append(self.allocator, .{ .id = command_id, .target = commandTarget(command) }) catch {
            command.deinit();
            self.fatal_error = .out_of_memory;
            self.requestShutdown();
            return null;
        };
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
            .check_recovery => |check| if (self.durable_submission) |durable| {
                if (durable.operation_id == check.operation_id and durable.phase == .recovery_check_queued)
                    durable.phase = .awaiting_recovery_check;
            },
            .find_duplicate => |check| if (self.durable_submission) |durable| {
                if (durable.operation_id == check.operation_id and durable.current_temp_id == check.draft.local_id and durable.phase == .duplicate_queued)
                    durable.phase = .awaiting_duplicate;
            },
            .list_pull_requests => self.outstanding_picker_loads += 1,
            .copy_clipboard => {},
        }
        return command;
    }

    fn consumeCommand(self: *Presentation, command_id: CommandId, target: CommandTarget) bool {
        // Pre-M16 fixtures omit correlation. Production commands never use 0;
        // new protocol tests exercise the strict nonzero path below.
        if (builtin.is_test and command_id == 0) return true;
        for (self.issued_commands.items, 0..) |issued, index| {
            if (issued.id != command_id) continue;
            _ = self.issued_commands.orderedRemove(index);
            return issued.target == target;
        }
        return false;
    }

    pub fn projection(self: *const Presentation) Projection {
        return .{
            .review = if (self.published) |published| self.reviewProjection(published) else null,
            .submission = if (self.durable_submission) |durable| blk: {
                const progress = durable.progress();
                break :blk .{
                    .operation_id = durable.operation_id,
                    .key = durable.key,
                    .current_temp_id = durable.current_temp_id,
                    .persistence_paused = durable.pending_persistence != null,
                    .completed = progress.completed,
                    .total = progress.total,
                };
            } else null,
            .submission_result = self.submission_result,
            .recovery = self.recovery,
            .unknown_resolution = if (self.unknown_resolution) |*editor| .{
                .temp_id = editor.temp_id,
                .comment_id = editor.text(),
            } else null,
            .picker = if (self.picker) |*picker| picker else null,
            .picker_tick_scope = if (!self.shutdown_requested) if (self.picker) |*picker|
                if (picker.loading) self.picker_work_id else null
            else
                null else null,
            .file_finder = if (self.file_finder) |*finder| finder else null,
            .help_visible = self.help_visible,
            .action_availability = self.actionAvailability(),
            .loading_pull_request_id = if (self.replacement) |replacement|
                if (replacement.key.isRemote()) replacement.key.pull_request_id else null
            else
                null,
            .composer = if (self.published) |published| if (published.composer) |*composer| .{
                .label = composer.request.label,
                .body = composer.body(),
            } else null else null,
            .replacing = self.replacement != null,
            .replacement_error = self.replacement_error,
            .action_error = self.action_error,
            .clipboard_status = self.clipboard_status,
            .fatal_error = self.fatal_error,
            .shutting_down = self.shutdown_requested,
        };
    }

    pub fn readyToExit(self: *const Presentation) bool {
        if (builtin.is_test) return self.shutdown_requested and self.durable_submission == null and self.commands.items.len == 0 and self.outstanding_loads == 0 and self.outstanding_picker_loads == 0 and self.issued_enrichments.items.len == 0;
        return self.shutdown_requested and self.durable_submission == null and self.commands.items.len == 0 and self.issued_commands.items.len == 0;
    }

    fn reviewProjection(self: *const Presentation, published: *const Published) ReviewProjection {
        var review = published.projection(self.preferences);
        review.frame = self.frameProjection();
        return review;
    }

    /// The one current immutable Frame used by projection, rendering, and all
    /// semantic mouse targeting.
    fn frameProjection(self: *const Presentation) frame_mod.Projection {
        var frame: frame_mod.Projection = if (self.published) |published|
            published.frameProjection()
        else
            .{
                .revision = self.interaction_revision,
                .targets_revision = self.interaction_revision,
                .geometry = self.geometry,
                .panes = frame_mod.paneRects(self.geometry),
                .targets = &.{},
                .buffer = .{ .rows = &.{}, .layout = .unified },
                .navigation = Nav.init(0, frame_mod.paneRects(self.geometry).diff_content.height),
            };
        frame.revision = self.interaction_revision;
        frame.overlay = self.overlayTarget();
        return frame;
    }

    fn overlayTarget(self: *const Presentation) ?frame_mod.OverlayTarget {
        if (self.help_visible or self.unknown_resolution != null or self.visibleSubmissionOverlay())
            return otherOverlay(self.geometry);
        if (self.file_finder) |finder| {
            const rect = frame_mod.overlayRect(self.geometry, 60, 16) orelse return null;
            return .{ .kind = .picker, .rect = rect, .row_count = finder.matches().len, .scroll = pickerTop(finder.selected, rect.height -| 1) };
        }
        if (self.picker) |picker| {
            const rect = frame_mod.overlayRect(self.geometry, 60, 16) orelse return null;
            return .{ .kind = .picker, .rect = rect, .row_count = picker.matches().len, .scroll = pickerTop(picker.selected, rect.height -| 1) };
        }
        if (self.published) |published| if (published.composer != null) return otherOverlay(self.geometry);
        return null;
    }

    fn visibleSubmissionOverlay(self: *const Presentation) bool {
        const published = self.published orelse return false;
        if (self.durable_submission) |submission| if (OwnedReviewIdentity.eql(submission.key, published.key)) return true;
        if (self.submission_result) |result| if (OwnedReviewIdentity.eql(result.key, published.key)) return true;
        return false;
    }

    fn applyMouse(self: *Presentation, mouse: MouseInput) void {
        if (!self.dependencies.mouse_enabled) {
            self.mouse_press = null;
            return;
        }
        if (mouse.modified or mouse.type == .motion or mouse.type == .drag) {
            self.mouse_press = null;
            return;
        }
        switch (mouse.button) {
            .wheel_up, .wheel_down => {
                self.mouse_press = null;
                if (mouse.type == .press) self.applyMouseWheel(mouse, mouse.button == .wheel_down);
            },
            .left => switch (mouse.type) {
                .press => {
                    const frame = self.frameProjection();
                    const target = frame_mod.hitTest(frame, mouse.col, mouse.row) orelse {
                        self.mouse_press = null;
                        return;
                    };
                    self.mouse_press = .{ .revision = frame.revision, .target = target };
                },
                .release => {
                    const pressed = self.mouse_press orelse return;
                    self.mouse_press = null;
                    const frame = self.frameProjection();
                    if (pressed.revision != frame.revision) return;
                    const target = frame_mod.hitTest(frame, mouse.col, mouse.row) orelse return;
                    if (!std.meta.eql(pressed.target, target)) return;
                    self.activateMouseTarget(target);
                },
                .motion, .drag => unreachable,
            },
            .middle, .right, .wheel_left, .wheel_right, .unsupported => self.mouse_press = null,
        }
    }

    fn activateMouseTarget(self: *Presentation, target: frame_mod.HitTarget) void {
        switch (target) {
            .picker_entry => |index| {
                if (self.file_finder) |*finder| finder.select(index) else if (self.picker) |*picker| picker.select(index) else return;
            },
            .sidebar => {
                const published = self.published orelse return;
                self.focusPane(published, .sidebar);
            },
            .diff => {
                const published = self.published orelse return;
                self.focusPane(published, .diff);
            },
            .sidebar_entry => |index| {
                const published = self.published orelse return;
                if (index >= published.tree.entries.len) return;
                self.focusPane(published, .sidebar);
                published.tree.cursor = index;
                self.applyAction(switch (published.tree.entries[index].identity) {
                    .directory => .toggle_directory,
                    .file => .focus_file,
                });
            },
            .diff_row => |index| {
                const published = self.published orelse return;
                if (index >= published.buffer.rows.len) return;
                self.focusPane(published, .diff);
                published.navigation.jumpTo(index);
                if (buffer_mod.disclosureKey(published.buffer.rows[index]) != null)
                    self.applyAction(.toggle_disclosure);
            },
        }
        self.interaction_revision +%= 1;
    }

    fn applyMouseWheel(self: *Presentation, mouse: MouseInput, down: bool) void {
        const target = frame_mod.hitTest(self.frameProjection(), mouse.col, mouse.row) orelse return;
        const rows = self.dependencies.mouse_vertical_scroll_rows;
        if (rows == 0) return;
        switch (target) {
            .picker_entry => {
                var remaining = rows;
                while (remaining > 0) : (remaining -= 1) {
                    if (self.file_finder) |*finder| {
                        if (down) finder.moveDown() else finder.moveUp();
                    } else if (self.picker) |*picker| {
                        if (down) picker.moveDown() else picker.moveUp();
                    } else return;
                }
            },
            .sidebar_entry => {
                const published = self.published orelse return;
                self.scrollPane(published, .sidebar, if (down) @as(isize, @intCast(rows)) else -@as(isize, @intCast(rows)));
            },
            .diff_row => {
                const published = self.published orelse return;
                self.scrollPane(published, .diff, if (down) @as(isize, @intCast(rows)) else -@as(isize, @intCast(rows)));
            },
            .sidebar, .diff => return,
        }
        self.interaction_revision +%= 1;
    }

    fn discoverRecovery(self: *Presentation) void {
        const locks = self.dependencies.submission_locks orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const run = self.dependencies.reviews.activeSubmission(arena.allocator()) catch {
            self.action_error = .recovery_claim_failed;
            return;
        } orelse return;
        const key = OwnedReviewIdentity.init(run.key.workspace, run.key.repository, run.key.pull_request_id) catch {
            self.action_error = .recovery_claim_failed;
            return;
        };
        const source_commit = BoundedText(64).init(run.source_commit) catch {
            self.action_error = .recovery_claim_failed;
            return;
        };
        var probe = locks.tryAcquire(run.key) catch {
            self.action_error = .recovery_claim_failed;
            return;
        };
        const ownership: RecoveryOwnership = if (probe != null) .recoverable else .running_elsewhere;
        if (probe) |*guard| guard.release();
        self.recovery = .{
            .operation_id = run.operation_id,
            .key = key,
            .source_commit = source_commit,
            .current_temp_id = run.current_temp_id,
            .ownership = ownership,
        };
    }

    fn recoverSubmission(self: *Presentation) void {
        if (self.durable_submission) |durable| {
            if (durable.phase == .recovery_check_paused) self.queueRecoveryCheck(durable) else if (durable.phase == .duplicate_check_paused) self.queueDuplicateCheck(durable) else if (durable.phase == .duplicate_persistence_paused) self.persistDuplicateResolution(durable);
            return;
        }
        const notice = self.recovery orelse {
            self.action_error = .action_refused;
            return;
        };
        if (notice.ownership == .running_elsewhere) {
            self.action_error = .submission_owned_elsewhere;
            return;
        }
        const locks = self.dependencies.submission_locks orelse {
            self.action_error = .recovery_claim_failed;
            return;
        };
        if (notice.current_temp_id != null) self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        var lock = (locks.tryAcquire(notice.key.storeKey()) catch {
            self.action_error = .recovery_claim_failed;
            return;
        }) orelse {
            self.recovery.?.ownership = .running_elsewhere;
            self.action_error = .submission_owned_elsewhere;
            return;
        };
        var validation_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer validation_arena.deinit();
        const active = self.dependencies.reviews.activeSubmission(validation_arena.allocator()) catch {
            lock.release();
            self.action_error = .recovery_claim_failed;
            return;
        } orelse {
            lock.release();
            self.recovery = null;
            self.action_error = .action_refused;
            return;
        };
        if (!recoveryMatches(notice, active)) {
            lock.release();
            self.discoverRecovery();
            self.action_error = .recovery_claim_failed;
            return;
        }
        if (notice.current_temp_id == null) {
            self.completeRecoveredTerminal(notice, &lock);
            return;
        }
        const durable = DurableSubmission.recover(self.allocator, self.dependencies.reviews, notice, lock) catch {
            lock.ptr = null;
            self.action_error = .recovery_claim_failed;
            return;
        };
        lock.ptr = null;
        self.durable_submission = durable;
        self.recovery = null;
        self.commands.appendAssumeCapacity(.{ .check_recovery = .{
            .operation_id = notice.operation_id,
            .identity = .init(notice.key),
            .source_commit = notice.source_commit,
        } });
        self.action_error = null;
    }

    fn completeRecoveredTerminal(self: *Presentation, notice: RecoveryNotice, lock: *bbr.review.SubmissionLockGuard) void {
        defer lock.release();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const review = self.dependencies.reviews.loadReview(arena.allocator(), notice.key.storeKey()) catch {
            self.action_error = .recovery_claim_failed;
            return;
        };
        var result: SubmissionResultProjection = .{
            .key = notice.key,
            .completion = .clean,
            .posted = 0,
            .failed = 0,
            .skipped = 0,
            .outcome_unknown = 0,
        };
        var clean = true;
        for (review.drafts.items) |draft| {
            if (draft.target != .bitbucket) continue;
            switch (draft.state) {
                .posted => result.posted += 1,
                .failed => {
                    result.failed += 1;
                    clean = false;
                },
                .outcome_unknown, .submitting => {
                    result.outcome_unknown += 1;
                    clean = false;
                },
                .draft => {
                    result.skipped += 1;
                    clean = false;
                },
            }
        }
        result.completion = if (clean) .clean else .partial;
        self.dependencies.reviews.completeSubmission(notice.operation_id, notice.key.storeKey(), result.completion) catch {
            self.action_error = .recovery_claim_failed;
            return;
        };
        self.recovery = null;
        self.submission_result = result;
        self.action_error = null;
    }

    fn queueRecoveryCheck(self: *Presentation, durable: *DurableSubmission) void {
        const source_commit = durable.recovery_source_commit orelse return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        durable.phase = .recovery_check_queued;
        self.commands.appendAssumeCapacity(.{ .check_recovery = .{
            .operation_id = durable.operation_id,
            .identity = .init(durable.key),
            .source_commit = source_commit,
        } });
        self.action_error = null;
    }

    fn queueDuplicateCheck(self: *Presentation, durable: *DurableSubmission) void {
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.phase = .duplicate_check_paused;
            self.action_error = .out_of_memory;
            return;
        };
        const command = durable.materializeDuplicateCheck(self.allocator) catch {
            durable.phase = .duplicate_check_paused;
            self.action_error = .out_of_memory;
            return;
        };
        self.commands.appendAssumeCapacity(.{ .find_duplicate = command });
        self.action_error = .recovery_source_changed;
    }

    fn requestShutdown(self: *Presentation) void {
        self.shutdown_requested = true;
        self.closePicker();
        self.closeFileFinder();
        self.help_visible = false;
        self.unknown_resolution = null;
        var write: usize = 0;
        for (self.commands.items) |command_value| {
            var command = command_value;
            if (command == .post_draft or command == .wait_submission or command == .check_recovery or command == .find_duplicate) {
                self.commands.items[write] = command;
                write += 1;
            } else {
                command.deinit();
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

    fn interactionContext(self: *const Presentation) keymap_mod.InteractionContext {
        if (self.help_visible) return .help;
        if (self.unknown_resolution != null) return .unknown_resolution;
        if (self.file_finder != null) return .file_finder;
        if (self.picker != null) return .pull_request_picker;
        return self.paneContext();
    }

    fn paneContext(self: *const Presentation) keymap_mod.InteractionContext {
        const published = self.published orelse return .diff;
        if (published.composer != null) return .composer;
        if (published.focus == .sidebar) {
            const entry = published.sidebarEntry() orelse return .sidebar;
            return if (entry.identity == .directory) .sidebar_directory else .sidebar_file;
        }
        if (published.navigation.cursor >= published.buffer.rows.len) return .diff;
        return switch (published.buffer.rows[published.navigation.cursor]) {
            .line, .line_pair => .diff_source,
            .disclosure => .diff_disclosure,
            .comment, .draft => |card| if (card.part == .disclosure_footer) .diff_review_card else .diff_review_card,
            else => .diff,
        };
    }

    fn actionAvailability(self: *const Presentation) ActionAvailability {
        const context = if (self.help_visible) self.paneContext() else self.interactionContext();
        const published = self.published orelse return .{
            .remote = self.dependencies.remote_enabled,
            .has_review = false,
            .context = context,
        };
        const source = context == .diff_source or published.navigation.count > 0 or blk: {
            const selection = published.navigation.selection() orelse break :blk false;
            var index = selection[0];
            while (index <= selection[1] and index < published.buffer.rows.len) : (index += 1)
                if (lineAtRow(published.buffer.rows[index]) != null) break :blk true;
            break :blk false;
        };
        return .{ .remote = published.key.isRemote(), .context = context, .source = source };
    }

    fn applyKey(self: *Presentation, key: keymap_mod.KeyStroke) !void {
        if (self.submission_result != null) {
            self.submission_result = null;
            return;
        }
        if (self.help_visible) {
            self.help_visible = false;
            return;
        }
        if (self.unknown_resolution != null) {
            if (key.matches(keymap_mod.special.escape, .{}) or key.matches('c', .{ .ctrl = true })) return self.applyUnknownResolutionInput(.cancel);
            if (key.matches(keymap_mod.special.enter, .{})) return self.applyUnknownResolutionInput(.confirm);
            if (key.matches(keymap_mod.special.backspace, .{})) return self.applyUnknownResolutionInput(.backspace);
            if (key.text) |text| for (text) |byte| if (byte >= '0' and byte <= '9') self.applyUnknownResolutionInput(.{ .digit = byte - '0' });
            return;
        }
        if (self.published) |published| if (published.composer != null) {
            if (key.matches(keymap_mod.special.escape, .{}) or key.matches('c', .{ .ctrl = true })) return self.applyComposerInput(.cancel);
            if (key.matches('d', .{ .ctrl = true }) or key.matches('s', .{ .ctrl = true })) return self.applyComposerInput(.save);
            if (key.matches(keymap_mod.special.enter, .{})) return self.applyComposerInput(.newline);
            if (key.matches('w', .{ .ctrl = true })) return self.applyComposerInput(.delete_word);
            if (key.matches('u', .{ .ctrl = true })) return self.applyComposerInput(.delete_to_line_start);
            if (key.matches(keymap_mod.special.backspace, .{})) return self.applyComposerInput(.backspace);
            if (key.text) |text| if (TextChunk.init(text)) |chunk| return self.applyComposerInput(.{ .insert = chunk }) else |_| {};
            return;
        };
        if (self.file_finder) |*finder| {
            if (key.matches(keymap_mod.special.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                self.closeFileFinder();
            } else if (key.matches(keymap_mod.special.enter, .{})) {
                const selected = finder.selection() orelse return;
                self.closeFileFinder();
                if (self.published) |published| {
                    self.focusFile(published, selected);
                    published.focus = .diff;
                }
            } else if (key.matches(keymap_mod.special.up, .{}) or key.matches('p', .{ .ctrl = true })) {
                finder.moveUp();
            } else if (key.matches(keymap_mod.special.down, .{}) or key.matches('n', .{ .ctrl = true })) {
                finder.moveDown();
            } else if (key.matches(keymap_mod.special.backspace, .{})) {
                finder.backspace();
            } else if (key.text) |text| finder.insert(text);
            return;
        }
        if (self.picker) |*picker| {
            if (key.matches(keymap_mod.special.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                self.closePicker();
            } else if (key.matches(keymap_mod.special.enter, .{})) {
                const selected = picker.selection() orelse return;
                self.closePicker();
                try self.choosePullRequest(try OwnedReviewIdentity.init(
                    if (self.published) |published| published.key.workspace() else self.replacement.?.key.workspace(),
                    if (self.published) |published| published.key.repository() else self.replacement.?.key.repository(),
                    selected.id,
                ));
            } else if (key.matches(keymap_mod.special.up, .{}) or key.matches('p', .{ .ctrl = true })) {
                picker.moveUp();
            } else if (key.matches(keymap_mod.special.down, .{}) or key.matches('n', .{ .ctrl = true })) {
                picker.moveDown();
            } else if (key.matches(keymap_mod.special.backspace, .{})) {
                picker.backspace();
            } else if (key.text) |text| picker.insert(text);
            return;
        }
        switch (self.resolver.feed(self.dependencies.keymap, self.interactionContext(), key)) {
            .none => {},
            .digit => |digit| self.pushCountDigit(digit),
            .action => |action| self.applyAction(action),
        }
    }

    fn resizeViewport(self: *Presentation, rows: usize) void {
        self.resize(.{
            .cols = self.geometry.cols,
            .rows = @as(u16, @intCast(@min(rows, std.math.maxInt(u16)))),
        });
    }

    fn resize(self: *Presentation, geometry: frame_mod.Geometry) void {
        if (std.meta.eql(self.geometry, geometry)) return;
        const published = self.published orelse {
            self.geometry = geometry;
            return;
        };
        var staged = published.prepareBuffer(
            self.preferences,
            published.expanded_disclosures.items,
            published.isolated_file,
            geometry,
        ) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        defer staged.deinit();
        staged.publish();
        published.centerActiveFile();
        self.geometry = geometry;
        self.action_error = null;
    }

    fn applyAction(self: *Presentation, action: Action) void {
        self.clipboard_status = null;
        if (action == .quit) {
            self.requestShutdown();
            return;
        }
        const visible_key = if (self.published) |published|
            published.key
        else if (self.replacement) |replacement|
            replacement.key
        else
            null;
        if (visible_key != null and !self.actionAvailability().available(action)) {
            self.action_error = switch (action) {
                .open_pull_request_picker => .local_review_no_picker,
                .submit => .local_review_no_submission,
                .inline_comment, .suggest, .yank => .source_action_unavailable,
                else => .local_review_remote_action_unavailable,
            };
            return;
        }
        if (self.shutdown_requested) {
            if (action == .submit) self.resumeDurableSubmission();
            return;
        }
        if (action == .recover_submission) {
            self.recoverSubmission();
            return;
        }
        if (action == .help) {
            self.help_visible = true;
            return;
        }
        if (action == .open_pull_request_picker) {
            self.openPicker();
            return;
        }
        if (action == .open_file_finder) {
            self.openFileFinder();
            return;
        }
        if (self.replacement != null) return;
        const published = self.published orelse return;
        self.action_error = null;
        const active_before = published.activeFile();
        switch (action) {
            .down => if (published.focus == .sidebar) published.sidebarVertical(1) else published.navigation.down(),
            .up => if (published.focus == .sidebar) published.sidebarVertical(-1) else published.navigation.up(),
            .left => if (published.focus == .sidebar) self.sidebarLeft(published),
            .right => if (published.focus == .sidebar) self.sidebarRight(published),
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
            .scroll_row_up => self.scrollPane(published, published.focus, -1),
            .scroll_row_down => self.scrollPane(published, published.focus, 1),
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
            .refresh => self.queueRefresh(published.key),
            .toggle_layout => {
                var candidate = self.preferences;
                candidate.layout = if (candidate.layout == .unified) .side_by_side else .unified;
                self.publishPreferences(published, candidate);
            },
            .cycle_scope => {
                var candidate = self.preferences;
                candidate.scope = candidate.scope.next();
                published.rebuild(candidate, published.expanded_disclosures.items, published.isolated_file) catch |err| {
                    self.action_error = normalizeActionError(err);
                    return;
                };
                self.preferences = candidate;
                self.action_error = null;
            },
            .isolate => self.toggleIsolation(published),
            .next_file => if (published.focus == .diff) self.moveFile(published, 1),
            .prev_file => if (published.focus == .diff) self.moveFile(published, -1),
            .toggle_disclosure => if (published.focus == .sidebar) self.activateSidebarEntry(published) else self.toggleDisclosure(published),
            .toggle_review_card => self.toggleDisclosure(published),
            .toggle_directory, .focus_file => self.activateSidebarEntry(published),
            .focus_next_pane => self.togglePaneFocus(published),
            .review_comment => self.openComposer(published, .{ .kind = .comment, .label = "New comment", .scope = .review }),
            .file_comment => self.openFileComposer(published),
            .reply => self.openReplyComposer(published),
            .inline_comment => self.openInlineComposer(published, .comment),
            .suggest => self.openInlineComposer(published, .suggestion),
            .submit => self.startSubmission(published),
            .recover_submission => unreachable,
            .resolve_unpublished => self.resolveSelectedUnknownAsUnpublished(published),
            .link_existing_comment => self.openUnknownResolutionEditor(published),
            .yank => self.yank(published),
            .open_file_finder, .open_pull_request_picker, .confirm_picker, .help => unreachable,
            .quit => unreachable,
        }
        if (published.focus == .diff and active_before != published.activeFile()) self.revealActiveFile(published);
    }

    fn togglePaneFocus(self: *Presentation, published: *Published) void {
        self.focusPane(published, if (published.focus == .diff) .sidebar else .diff);
    }

    fn focusPane(self: *Presentation, published: *Published, focus: frame_mod.PaneFocus) void {
        _ = self;
        if (published.focus == focus) return;
        published.focus = focus;
        if (focus == .sidebar) published.cursorToActiveFile();
        published.frame_revision += 1;
    }

    fn scrollPane(self: *Presentation, published: *Published, pane: frame_mod.PaneFocus, delta: isize) void {
        _ = self;
        switch (pane) {
            .sidebar => published.sidebarScrollRows(delta),
            .diff => published.navigation.scrollRows(delta),
        }
    }

    fn sidebarLeft(self: *Presentation, published: *Published) void {
        published.navigation.count = 0;
        const entry = published.sidebarEntry() orelse return;
        if (entry.identity == .directory and entry.expanded) {
            published.collapseDirectory(entry.identity.directory) catch {
                self.action_error = .out_of_memory;
                return;
            };
            published.rebuild(self.preferences, published.expanded_disclosures.items, published.isolated_file) catch |err| {
                const path = published.collapsed_directories.pop().?;
                published.allocator.free(path);
                self.action_error = normalizeActionError(err);
            };
            return;
        }
        if (entry.parent) |parent| published.cursorToIdentity(parent);
    }

    fn sidebarRight(self: *Presentation, published: *Published) void {
        published.navigation.count = 0;
        const entry = published.sidebarEntry() orelse return;
        if (entry.identity != .directory) return;
        if (!entry.expanded) {
            const removed = published.takeCollapsedDirectory(entry.identity.directory) orelse return;
            published.rebuild(self.preferences, published.expanded_disclosures.items, published.isolated_file) catch |err| {
                published.collapsed_directories.appendAssumeCapacity(removed);
                self.action_error = normalizeActionError(err);
                return;
            };
            published.allocator.free(removed);
            return;
        }
        const next = published.tree.cursor + 1;
        if (next < published.tree.entries.len and published.tree.entries[next].parent != null and published.tree.entries[next].parent.?.eql(entry.identity)) {
            published.tree.cursor = next;
            published.frame_revision += 1;
        }
    }

    fn activateSidebarEntry(self: *Presentation, published: *Published) void {
        const entry = published.sidebarEntry() orelse return;
        switch (entry.identity) {
            .directory => if (entry.expanded) self.sidebarLeft(published) else self.sidebarRight(published),
            .file => |file_index| {
                self.focusFile(published, file_index);
            },
        }
    }

    fn focusFile(self: *Presentation, published: *Published, file_index: usize) void {
        if (file_index >= published.session.diff.files.len) return;
        if (published.isolated_file != null) {
            published.rebuild(self.preferences, published.expanded_disclosures.items, file_index) catch |err| {
                self.action_error = normalizeActionError(err);
                return;
            };
            published.isolated_file = file_index;
            published.navigation = Nav.init(published.buffer.rows.len, frame_mod.paneRects(published.geometry).diff_content.height);
        } else if (fileHeaderRow(published.buffer, file_index)) |row| published.navigation.jumpTo(row);
        self.revealActiveFile(published);
    }

    fn revealActiveFile(self: *Presentation, published: *Published) void {
        const active = published.activeFile() orelse return;
        const path = published.session.diff.files[active].displayPath();
        var removed: std.ArrayList([]const u8) = .empty;
        defer removed.deinit(published.allocator);
        removed.ensureTotalCapacity(published.allocator, published.collapsed_directories.items.len) catch {
            self.action_error = .out_of_memory;
            return;
        };
        var collapsed_index = published.collapsed_directories.items.len;
        while (collapsed_index > 0) {
            collapsed_index -= 1;
            const candidate = published.collapsed_directories.items[collapsed_index];
            if (path.len > candidate.len and std.mem.startsWith(u8, path, candidate) and path[candidate.len] == '/')
                removed.appendAssumeCapacity(published.collapsed_directories.orderedRemove(collapsed_index));
        }
        published.rebuild(self.preferences, published.expanded_disclosures.items, published.isolated_file) catch |err| {
            published.collapsed_directories.appendSliceAssumeCapacity(removed.items);
            self.action_error = normalizeActionError(err);
            return;
        };
        for (removed.items) |candidate| published.allocator.free(candidate);
        published.centerActiveFile();
    }

    fn selectedUnknownDraft(published: *Published) ?*bbr.review.Draft {
        if (published.navigation.cursor >= published.buffer.rows.len) return null;
        const row = switch (published.buffer.rows[published.navigation.cursor]) {
            .draft => |draft_row| draft_row,
            else => return null,
        };
        if (row.draftItem().state != .outcome_unknown) return null;
        return published.review.get(row.draftItem().local_id);
    }

    fn resolveSelectedUnknownAsUnpublished(self: *Presentation, published: *Published) void {
        const draft = selectedUnknownDraft(published) orelse {
            self.action_error = .action_refused;
            return;
        };
        self.dependencies.reviews.resolveUnknown(published.key.storeKey(), draft.local_id, .unpublished) catch {
            self.action_error = .persistence_failed;
            return;
        };
        draft.state = .draft;
        self.action_error = null;
    }

    fn openUnknownResolutionEditor(self: *Presentation, published: *Published) void {
        const draft = selectedUnknownDraft(published) orelse {
            self.action_error = .action_refused;
            return;
        };
        self.unknown_resolution = .{ .key = published.key, .temp_id = draft.local_id };
        self.action_error = null;
    }

    fn applyUnknownResolutionInput(self: *Presentation, input: UnknownResolutionInput) void {
        const editor = if (self.unknown_resolution) |*value| value else return;
        switch (input) {
            .digit => |digit| if (digit <= 9 and editor.len < editor.digits.len) {
                editor.digits[editor.len] = '0' + digit;
                editor.len += 1;
            },
            .backspace => if (editor.len > 0) {
                editor.len -= 1;
            },
            .cancel => self.unknown_resolution = null,
            .confirm => {
                if (editor.len == 0) return;
                const comment_id = std.fmt.parseInt(bbr.review.CommentId, editor.text(), 10) catch {
                    self.action_error = .action_refused;
                    return;
                };
                if (comment_id == 0) {
                    self.action_error = .action_refused;
                    return;
                }
                self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                self.dependencies.reviews.resolveUnknown(editor.key.storeKey(), editor.temp_id, .{ .posted = comment_id }) catch {
                    self.action_error = .persistence_failed;
                    return;
                };
                if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, editor.key))
                    published.review.setState(editor.temp_id, .{ .posted = comment_id });
                const key = editor.key;
                self.unknown_resolution = null;
                if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, key)) self.queueReconciliation(key);
                self.action_error = null;
            },
        }
    }

    fn startSubmission(self: *Presentation, published: *Published) void {
        if (!published.key.isRemote()) {
            self.action_error = .local_review_no_submission;
            return;
        }
        if (self.durable_submission) |durable| {
            if (durable.phase == .post_retry_paused) {
                self.resumePostDraftLaunch(durable);
                return;
            }
            if (durable.phase == .wait_retry_paused) {
                self.resumeSubmissionWaitLaunch(durable);
                return;
            }
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
        const lock = locks.tryAcquire(published.key.remote()) catch {
            self.action_error = .submission_start_failed;
            return;
        } orelse {
            self.action_error = .submission_owned_elsewhere;
            return;
        };
        const source_check = if (self.dependencies.require_source_check)
            BoundedText(64).init(published.session.header.source_commit) catch {
                self.action_error = .submission_start_failed;
                return;
            }
        else
            null;
        const started = DurableSubmission.begin(
            self.allocator,
            self.dependencies.reviews,
            published.key,
            published.session.header.source_commit,
            lock,
        ) catch |err| {
            self.action_error = if (err == error.SubmissionAlreadyActive) .submission_already_active else .submission_start_failed;
            return;
        } orelse {
            self.action_error = .action_refused;
            return;
        };
        if (self.dependencies.require_source_check) {
            started.command.destroy();
            started.durable.recovery_source_commit = source_check.?;
            started.durable.phase = .recovery_check_queued;
            self.commands.appendAssumeCapacity(.{ .check_recovery = .{
                .operation_id = started.durable.operation_id,
                .identity = .init(started.durable.key),
                .source_commit = started.durable.recovery_source_commit.?,
            } });
        } else {
            self.commands.appendAssumeCapacity(.{ .post_draft = started.command });
        }
        self.durable_submission = started.durable;
        published.review.setState(started.durable.current_temp_id.?, .submitting);
        self.action_error = null;
    }

    fn resumeDurableSubmission(self: *Presentation) void {
        const durable = self.durable_submission orelse return;
        if (durable.phase == .post_retry_paused) {
            self.resumePostDraftLaunch(durable);
        } else if (durable.phase == .wait_retry_paused) {
            self.resumeSubmissionWaitLaunch(durable);
        } else if (durable.phase == .recovery_check_paused) {
            self.queueRecoveryCheck(durable);
        } else if (durable.phase == .duplicate_check_paused) {
            self.queueDuplicateCheck(durable);
        } else if (durable.phase == .duplicate_persistence_paused) {
            self.persistDuplicateResolution(durable);
        } else if (durable.pending_admission != null) {
            self.resumeSubmissionAdmission(durable);
        } else if (durable.pending_persistence != null) {
            self.resumeSubmissionPersistence(durable);
        }
    }

    fn acceptPostDraft(self: *Presentation, completed: PostDraftCompleted) void {
        if (!self.consumeCommand(completed.command_id, .post_draft)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != completed.operation_id or !durableIdentityMatches(durable.key, completed.identity) or durable.current_temp_id != completed.temp_id or durable.phase != .awaiting_post) return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.pending_admission = .{ .post = completed };
            durable.phase = .admission_paused;
            self.action_error = .out_of_memory;
            return;
        };
        self.processPostDraft(durable, completed);
    }

    fn acceptPostDraftLaunchFailure(self: *Presentation, failed: PostDraftLaunchFailed) void {
        if (!self.consumeCommand(failed.command_id, .post_draft)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != failed.operation_id or !durableIdentityMatches(durable.key, failed.identity) or durable.current_temp_id != failed.temp_id or durable.phase != .awaiting_post) return;
        durable.phase = .post_retry_paused;
        self.action_error = .submission_launch_failed;
    }

    fn resumePostDraftLaunch(self: *Presentation, durable: *DurableSubmission) void {
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        const command = durable.retryPost(self.allocator) catch {
            self.action_error = .out_of_memory;
            return;
        };
        self.commands.appendAssumeCapacity(.{ .post_draft = command });
        self.action_error = null;
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
                if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, durable.key))
                    published.review.setState(durable.current_temp_id.?, .submitting);
                self.commands.appendAssumeCapacity(.{ .post_draft = next.command });
            },
            .wait => |wait| self.commands.appendAssumeCapacity(.{ .wait_submission = wait }),
            .finished => |finished| {
                self.recordVisibleTransition(durable, finished.transition);
                const reconcile = durable.posted_any and !self.shutdown_requested and self.replacement == null and
                    (if (self.published) |published| OwnedReviewIdentity.eql(published.key, durable.key) else false);
                const key = durable.key;
                self.submission_result = finished.result;
                self.durable_submission = null;
                durable.destroy();
                if (reconcile) self.queueReconciliation(key);
            },
        }
    }

    fn acceptRecoveryCheck(self: *Presentation, checked: RecoveryChecked) void {
        if (!self.consumeCommand(checked.command_id, .check_recovery)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != checked.operation_id or !durableIdentityMatches(durable.key, checked.identity) or durable.phase != .awaiting_recovery_check) return;
        const current_source = switch (checked.outcome) {
            .failed => {
                durable.phase = .recovery_check_paused;
                self.action_error = .recovery_check_failed;
                return;
            },
            .current_source => |source| source,
        };
        const recovered_source = durable.recovery_source_commit orelse return;
        if (bbr.review.headChanged(recovered_source.slice(), current_source.slice())) {
            if (durable.recovered) {
                durable.phase = .recovery_source_changed;
                self.queueDuplicateCheck(durable);
            } else {
                self.abortChangedSubmission(durable);
            }
            return;
        }
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.phase = .recovery_check_paused;
            self.action_error = .out_of_memory;
            return;
        };
        const command = durable.materializeCurrentPost(self.allocator) catch {
            durable.phase = .recovery_check_paused;
            self.action_error = .out_of_memory;
            return;
        };
        command.dedupe = durable.recovered;
        self.commands.appendAssumeCapacity(.{ .post_draft = command });
        self.action_error = null;
    }

    fn abortChangedSubmission(self: *Presentation, durable: *DurableSubmission) void {
        const completion: bbr.review.SubmissionCompletion = .{ .aborted = .draft };
        self.dependencies.reviews.completeSubmission(durable.operation_id, durable.key.storeKey(), completion) catch {
            durable.phase = .recovery_check_paused;
            self.action_error = .persistence_failed;
            return;
        };
        if (durable.current_temp_id) |temp_id| durable.review.setState(temp_id, .draft);
        const result = durable.persistedResultProjection(completion);
        if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, durable.key) and durable.current_temp_id != null)
            published.review.setState(durable.current_temp_id.?, .draft);
        self.durable_submission = null;
        durable.destroy();
        self.submission_result = result;
        self.action_error = .recovery_source_changed;
    }

    fn acceptDuplicateCheck(self: *Presentation, checked: DuplicateChecked) void {
        if (!self.consumeCommand(checked.command_id, .find_duplicate)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != checked.operation_id or !durableIdentityMatches(durable.key, checked.identity) or durable.current_temp_id != checked.temp_id or durable.phase != .awaiting_duplicate) return;
        if (checked.outcome == .failed) {
            durable.phase = .duplicate_check_paused;
            self.action_error = .duplicate_check_failed;
            return;
        }
        durable.pending_duplicate = .{ .outcome = checked.outcome };
        durable.phase = .duplicate_persistence_paused;
        self.persistDuplicateResolution(durable);
    }

    fn persistDuplicateResolution(self: *Presentation, durable: *DurableSubmission) void {
        const pending = if (durable.pending_duplicate) |*value| value else return;
        const temp_id = durable.current_temp_id orelse return;
        const outcome: bbr.review.SubmissionOutcome = switch (pending.outcome) {
            .found => |id| .{ .posted = id },
            .missing => .outcome_unknown,
            .failed => unreachable,
        };
        if (!pending.checkpoint_done) {
            self.dependencies.reviews.checkpointSubmission(durable.operation_id, durable.key.storeKey(), temp_id, outcome, null) catch {
                durable.phase = .duplicate_persistence_paused;
                self.action_error = .persistence_failed;
                return;
            };
            durable.recordCheckpoint(temp_id, outcome, null);
            pending.checkpoint_done = true;
        }
        var clean = true;
        for (durable.review.drafts.items) |draft| if (draft.target == .bitbucket and draft.state != .posted) {
            clean = false;
            break;
        };
        const completion: bbr.review.SubmissionCompletion = if (clean) .clean else .partial;
        self.dependencies.reviews.completeSubmission(durable.operation_id, durable.key.storeKey(), completion) catch {
            durable.phase = .duplicate_persistence_paused;
            self.action_error = .persistence_failed;
            return;
        };
        const result = durable.persistedResultProjection(completion);
        self.durable_submission = null;
        durable.destroy();
        self.submission_result = result;
        self.action_error = null;
    }

    fn acceptSubmissionWait(self: *Presentation, completed: WaitSubmission) void {
        if (!self.consumeCommand(completed.command_id, .wait_submission)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != completed.operation_id or !durableIdentityMatches(durable.key, completed.identity) or durable.current_temp_id != completed.temp_id or durable.phase != .awaiting_wait) return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.pending_admission = .{ .wait = completed };
            durable.phase = .admission_paused;
            self.action_error = .out_of_memory;
            return;
        };
        self.processSubmissionWait(durable, completed);
    }

    fn acceptSubmissionWaitLaunchFailure(self: *Presentation, failed: WaitSubmission) void {
        if (!self.consumeCommand(failed.command_id, .wait_submission)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != failed.operation_id or !durableIdentityMatches(durable.key, failed.identity) or durable.current_temp_id != failed.temp_id or durable.phase != .awaiting_wait) return;
        durable.pending_wait_retry = failed;
        durable.phase = .wait_retry_paused;
        self.action_error = .submission_launch_failed;
    }

    fn resumeSubmissionWaitLaunch(self: *Presentation, durable: *DurableSubmission) void {
        const wait = durable.pending_wait_retry orelse return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        durable.pending_wait_retry = null;
        durable.phase = .wait_queued;
        self.commands.appendAssumeCapacity(.{ .wait_submission = wait });
        self.action_error = null;
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
        if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, durable.key))
            published.review.setState(transition.temp_id, transition.state);
    }

    fn publishDurableCheckpoint(self: *Presentation, durable: *const DurableSubmission) void {
        const pending = durable.pending_persistence orelse return;
        if (pending.checkpoint_done) self.recordVisibleTransition(durable, pending.transition);
    }

    fn openComposer(self: *Presentation, published: *Published, request: composer_mod.Request) void {
        if (published.composer != null) return;
        _ = published.composer_arena.reset(.retain_capacity);
        var targeted = request;
        targeted.target = if (published.key.isRemote()) .bitbucket else .local;
        published.composer = Composer.init(published.composer_arena.allocator(), targeted);
        self.action_error = null;
    }

    fn openFileComposer(self: *Presentation, published: *Published) void {
        const file_index = published.activeFile() orelse {
            self.action_error = .action_refused;
            return;
        };
        const file = published.session.diff.files[file_index];
        const path = if (file.new_path.len > 0) file.new_path else file.old_path;
        self.openComposer(published, .{
            .kind = .comment,
            .scope = .{ .file = .{ .path = path, .source_commit = published.session.header.source_commit } },
            .label = "New File comment",
        });
    }

    fn openReplyComposer(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) {
            self.action_error = .action_refused;
            return;
        }
        const parent: bbr.review.draft.Parent = switch (published.buffer.rows[published.navigation.cursor]) {
            .comment => |row| .{ .comment = row.commentItem().id },
            .draft => |row| .{ .draft = row.draftItem().local_id },
            else => {
                self.action_error = .action_refused;
                return;
            },
        };
        self.openComposer(published, .{ .kind = .comment, .parent = parent, .label = "Reply" });
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
        const file = published.session.diff.files[file_index];
        const old_side = span.to == null;
        const path = if (old_side) file.old_path else file.new_path;
        const authored_commit = if (old_side) published.session.header.base_commit else published.session.header.source_commit;
        const anchor: bbr.review.Anchor = .{
            .path = allocator.dupe(u8, path) catch {
                self.action_error = .out_of_memory;
                return;
            },
            .from = span.from,
            .to = span.to,
            .start_from = span.start_from,
            .start_to = span.start_to,
            .commit = allocator.dupe(u8, authored_commit) catch {
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
        const snapshot = if (!published.key.isRemote()) captureAnchorSnapshot(allocator, file, lines.items) catch {
            self.action_error = .out_of_memory;
            return;
        } else null;
        published.composer = Composer.init(allocator, .{
            .kind = kind,
            .target = if (published.key.isRemote()) .bitbucket else .local,
            .anchor = anchor,
            .snapshot = snapshot,
            .label = label,
        });
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
        published.focusEnrichment(self.preferences, file_index) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        if (!published.session.enrichment.needsEnrichment(file_index)) return;

        const file = published.session.diff.files[file_index];
        const work_id = self.next_work_id + 1;
        const command: EnrichFile = .{
            .work_id = work_id,
            .session_epoch = published.epoch,
            .file_index = file_index,
            .source = switch (published.key.kind) {
                .remote => .{ .remote = BoundedText(256).init(published.key.repository()) catch {
                    self.action_error = .action_refused;
                    return;
                } },
                .local => .local,
            },
            .source_commit = BoundedText(64).init(published.session.header.source_commit) catch {
                self.action_error = .action_refused;
                return;
            },
            .destination_commit = BoundedText(64).init(published.session.header.base_commit) catch {
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
        if (!self.consumeCommand(completed.command_id, .enrich_file)) {
            if (completed.outcome == .completed) {
                var result = completed.outcome.completed;
                result.deinit();
            }
            return;
        }
        var issued_index: ?usize = null;
        for (self.issued_enrichments.items, 0..) |issued, index| {
            if (issued.work_id == completed.work_id) {
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
                _ = current.session.enrichment.stageAdmission(completed.file_index, &result) catch {
                    self.action_error = .action_refused;
                    return;
                };
                current.rebuild(self.preferences, current.expanded_disclosures.items, current.isolated_file) catch |err| {
                    current.session.enrichment.rollbackCacheUpdate();
                    self.action_error = normalizeActionError(err);
                    return;
                };
                current.session.enrichment.commitCacheUpdate();
                self.action_error = null;
            },
        }
    }

    fn saveComposer(self: *Presentation, published: *Published) void {
        const composer = if (published.composer) |*value| value else return;
        if (composer.isBlank()) return;
        published.saveDraft(self.dependencies.reviews, self.preferences, composer.toNewDraft()) catch |err| {
            self.action_error = switch (err) {
                error.PersistenceFailed => .persistence_failed,
                error.BufferBuildFailed => .buffer_build_failed,
                error.OutOfMemory => .out_of_memory,
            };
            return;
        };
        composer.deinit();
        published.composer = null;
        self.action_error = null;
    }

    fn publishPreferences(self: *Presentation, published: *Published, candidate: Preferences) void {
        published.rebuild(candidate, published.expanded_disclosures.items, published.isolated_file) catch |err| {
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
        published.rebuild(self.preferences, published.expanded_disclosures.items, candidate) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        published.isolated_file = candidate;
        if (previous) |file_index| {
            if (fileHeaderRow(published.buffer, file_index)) |row| published.navigation.jumpTo(row);
        } else {
            published.navigation = Nav.init(published.buffer.rows.len, frame_mod.paneRects(self.geometry).diff_content.height);
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
            published.rebuild(self.preferences, published.expanded_disclosures.items, candidate) catch |err| {
                self.action_error = normalizeActionError(err);
                return;
            };
            published.isolated_file = candidate;
            published.navigation = Nav.init(published.buffer.rows.len, frame_mod.paneRects(self.geometry).diff_content.height);
            self.action_error = null;
            return;
        }
        const row = if (direction > 0)
            nextFileHeaderRow(published.buffer, published.navigation.cursor)
        else
            previousFileHeaderRow(published.buffer, published.navigation.cursor);
        if (row) |target| published.navigation.jumpTo(target);
    }

    fn toggleDisclosure(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) return;
        const key = buffer_mod.disclosureKey(published.buffer.rows[published.navigation.cursor]) orelse return;
        const old_len = published.expanded_disclosures.items.len;
        var removed_index: ?usize = null;
        for (published.expanded_disclosures.items, 0..) |candidate, index| if (std.meta.eql(candidate, key)) {
            removed_index = index;
            _ = published.expanded_disclosures.orderedRemove(index);
            break;
        };
        if (removed_index == null) published.expanded_disclosures.append(self.allocator, key) catch {
            self.action_error = .out_of_memory;
            return;
        };
        published.rebuild(self.preferences, published.expanded_disclosures.items, published.isolated_file) catch |err| {
            if (removed_index) |index| {
                published.expanded_disclosures.insert(self.allocator, index, key) catch unreachable;
            } else published.expanded_disclosures.shrinkRetainingCapacity(old_len);
            self.action_error = normalizeActionError(err);
            return;
        };
        self.action_error = null;
    }

    fn openPicker(self: *Presentation) void {
        const key = if (self.published) |published| published.key else if (self.replacement) |replacement| replacement.key else {
            self.action_error = .action_refused;
            return;
        };
        if (!key.isRemote()) {
            self.action_error = .local_review_no_picker;
            return;
        }
        if (!self.dependencies.remote_enabled) {
            self.action_error = .action_refused;
            return;
        }
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        const repository = BoundedText(256).init(key.repository()) catch {
            self.action_error = .action_refused;
            return;
        };
        self.closePicker();
        self.next_work_id += 1;
        self.picker = Picker.initLoading(self.allocator);
        self.picker_work_id = self.next_work_id;
        self.commands.appendAssumeCapacity(.{ .list_pull_requests = .{
            .work_id = self.next_work_id,
            .repository = repository,
        } });
        self.action_error = null;
    }

    fn openFileFinder(self: *Presentation) void {
        const published = self.published orelse {
            self.action_error = .action_refused;
            return;
        };
        self.closeFileFinder();
        self.file_finder = FileFinder.init(self.allocator, published.session.diff.files) catch {
            self.action_error = .out_of_memory;
            return;
        };
        self.action_error = null;
    }

    fn yank(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) {
            self.action_error = .invalid_selection;
            return;
        }
        const start_file = fileIndexForRow(published.buffer, published.navigation.cursor);
        const selection = published.navigation.selection();
        const wanted = if (selection == null) @max(published.navigation.count, 1) else std.math.maxInt(usize);
        published.navigation.count = 0;
        const first = if (selection) |range| range[0] else published.navigation.cursor;
        const last = if (selection) |range| range[1] else published.buffer.rows.len - 1;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        var copied: usize = 0;
        var row_index = first;
        while (row_index <= last and row_index < published.buffer.rows.len and copied < wanted) : (row_index += 1) {
            if (fileIndexForRow(published.buffer, row_index) != start_file) break;
            const source: ?[]const u8 = switch (published.buffer.rows[row_index]) {
                .line => |line| line.line.text,
                .line_pair => |pair| if (pair.right) |right| right.line.text else if (pair.left) |left| left.line.text else null,
                else => null,
            };
            if (source) |text_value| {
                if (copied > 0) bytes.append(self.allocator, '\n') catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                bytes.appendSlice(self.allocator, text_value) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                copied += 1;
            }
        }
        if (copied == 0) {
            self.action_error = .invalid_selection;
            return;
        }
        const command = self.allocator.create(ClipboardCopy) catch {
            self.action_error = .out_of_memory;
            return;
        };
        const owned = bytes.toOwnedSlice(self.allocator) catch {
            self.allocator.destroy(command);
            self.action_error = .out_of_memory;
            return;
        };
        command.* = .{ .allocator = self.allocator, .text = owned };
        self.commands.append(self.allocator, .{ .copy_clipboard = command }) catch {
            command.destroy();
            self.action_error = .out_of_memory;
            return;
        };
        published.navigation.clearMark();
        self.action_error = null;
    }

    fn closeFileFinder(self: *Presentation) void {
        if (self.file_finder) |*finder| finder.deinit();
        self.file_finder = null;
    }

    fn closePicker(self: *Presentation) void {
        if (self.picker) |*picker| picker.deinit();
        self.picker = null;
        if (self.picker_summaries) |summaries| summaries.destroy();
        self.picker_summaries = null;
        self.picker_work_id = null;
    }

    fn acceptPullRequests(self: *Presentation, loaded: PullRequestsLoaded) void {
        if (!self.consumeCommand(loaded.command_id, .list_pull_requests)) {
            if (loaded.outcome == .loaded) loaded.outcome.loaded.destroy();
            return;
        }
        if (self.outstanding_picker_loads > 0) self.outstanding_picker_loads -= 1;
        if (self.picker_work_id != loaded.work_id or self.picker == null) {
            if (loaded.outcome == .loaded) loaded.outcome.loaded.destroy();
            return;
        }
        switch (loaded.outcome) {
            .failed => {
                self.closePicker();
                self.action_error = .picker_load_failed;
            },
            .loaded => |summaries| {
                self.picker.?.populate(summaries.prs) catch {
                    summaries.destroy();
                    self.closePicker();
                    self.action_error = .out_of_memory;
                    return;
                };
                self.picker_summaries = summaries;
                self.action_error = null;
            },
        }
    }

    fn choosePullRequest(self: *Presentation, key: OwnedReviewIdentity) !void {
        self.unknown_resolution = null;
        self.help_visible = false;
        if (self.published) |published| {
            if (OwnedReviewIdentity.eql(published.key, key)) {
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
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key, .cause = .picker } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key };
        self.replacement_error = null;
    }

    fn queueReconciliation(self: *Presentation, key: OwnedReviewIdentity) void {
        const intent = self.next_intent + 1;
        self.removeQueuedSessionLoads();
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key, .cause = .reconciliation } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key };
        self.replacement_error = null;
    }

    fn queueRefresh(self: *Presentation, key: OwnedReviewIdentity) void {
        const intent = self.next_intent + 1;
        self.commands.ensureTotalCapacity(self.allocator, self.commands.items.len + 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        self.removeQueuedSessionLoads();
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key, .cause = .refresh } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key };
        self.replacement_error = null;
        self.action_error = null;
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
        if (!self.consumeCommand(completed.command_id, .load_session)) {
            if (completed.outcome == .loaded) completed.outcome.loaded.destroy();
            return;
        }
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
                    self.dependencies.anchor_resolver,
                    self.dependencies.scope_resolver,
                    replacement.key,
                    epoch,
                    session,
                    self.geometry,
                    self.preferences,
                    .{
                        .enabled = self.dependencies.file_cache_enabled,
                        .max_retained_bytes = self.dependencies.inactive_file_cache_max_bytes,
                    },
                    self.dependencies.cell_metrics,
                    self.dependencies.comments_collapsed_rows,
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
                self.resolver = .{};
                self.mouse_press = null;
                self.interaction_revision +%= 1;
                self.replacement = null;
                self.replacement_error = null;
                self.action_error = null;
                if (previous) |published| published.destroy();
            },
        }
    }
};

fn recoveryMatches(notice: RecoveryNotice, active: bbr.review.ActiveSubmissionRun) bool {
    return notice.operation_id == active.operation_id and
        OwnedReviewIdentity.eql(notice.key, OwnedReviewIdentity.init(active.key.workspace, active.key.repository, active.key.pull_request_id) catch return false) and
        notice.current_temp_id == active.current_temp_id and
        std.mem.eql(u8, notice.source_commit.slice(), active.source_commit);
}

fn captureAnchorSnapshot(allocator: Allocator, file: bbr.diff.File, selected: []const *const bbr.diff.Line) !?bbr.review.AnchorSnapshot {
    if (selected.len == 0) return null;
    for (file.hunks) |hunk| {
        var first: ?usize = null;
        var last: ?usize = null;
        for (hunk.lines, 0..) |*line, index| {
            for (selected) |candidate| if (candidate == line) {
                if (first == null) first = index;
                last = index;
            };
        }
        if (first == null or last == null) continue;
        const start = first.? -| 3;
        const end = @min(hunk.lines.len, last.? + 4);
        var text: std.ArrayList(u8) = .empty;
        for (hunk.lines[start..end], 0..) |line, index| {
            if (index > 0) try text.append(allocator, '\n');
            try text.appendSlice(allocator, line.text);
        }
        return .{
            .text = try text.toOwnedSlice(allocator),
            .selection_start = @intCast(first.? - start),
            .selection_len = @intCast(last.? - first.? + 1),
        };
    }
    return null;
}

fn normalizeActionError(err: BufferTransactionError) ActionError {
    return switch (err) {
        error.BufferBuildFailed => .buffer_build_failed,
        error.OutOfMemory => .out_of_memory,
    };
}

fn lineAtRow(row: buffer_mod.Row) ?*const bbr.diff.Line {
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
    buffer: buffer_mod.Buffer,
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

fn otherOverlay(geometry: frame_mod.Geometry) ?frame_mod.OverlayTarget {
    const rect = frame_mod.overlayRect(geometry, geometry.cols, geometry.rows) orelse return null;
    return .{ .kind = .other, .rect = rect };
}

fn pickerTop(selected: usize, visible_rows: usize) usize {
    if (visible_rows == 0 or selected < visible_rows) return 0;
    return selected - visible_rows + 1;
}

fn fileIndexForRow(buffer: buffer_mod.Buffer, cursor: usize) usize {
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

fn nextFileHeaderRow(buffer: buffer_mod.Buffer, cursor: usize) ?usize {
    var row = cursor +| 1;
    while (row < buffer.rows.len) : (row += 1) {
        if (buffer.rows[row] == .file_header) return row;
    }
    return null;
}

fn previousFileHeaderRow(buffer: buffer_mod.Buffer, cursor: usize) ?usize {
    if (cursor == 0) return null;
    var row = cursor;
    while (row > 0) {
        row -= 1;
        if (buffer.rows[row] == .file_header) return row;
    }
    return null;
}

fn fileHeaderRow(buffer: buffer_mod.Buffer, file_index: usize) ?usize {
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
    const pr: bbr.bitbucket.PullRequest = .{
        .id = id,
        .title = try std.fmt.allocPrint(a, "PR {d}", .{id}),
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.source = .{ .remote = pr };
    s.header = .{
        .title = pr.title,
        .source_ref = pr.source_branch,
        .base_ref = pr.destination_branch,
        .source_commit = pr.source_commit,
        .base_commit = pr.destination_commit,
        .author = pr.author_display_name,
        .locator = "repo",
        .source_label = "Bitbucket",
        .pull_request_id = pr.id,
    };
    s.diff = try bbr.diff.parse(a, raw);
    try s.initializeEnrichment();
    return s;
}

fn testLocalSession(backing: std.mem.Allocator) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    s.source = .{ .local = .{ .common_dir = "/repo/.git" } };
    s.header = .{
        .title = "Local review",
        .source_ref = "refs/heads/feature",
        .base_ref = "refs/remotes/origin/main",
        .source_commit = "source",
        .base_commit = "base",
        .locator = "/repo",
        .source_label = "Git",
    };
    s.diff = try bbr.diff.parse(a,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
    );
    try s.initializeEnrichment();
    return s;
}

test "local review gates remote actions and refreshes the same identity" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.initLocal(42, "refs/remotes/origin/main", "refs/heads/feature");
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testLocalSession(testing.allocator) },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    const initial = presentation.projection();
    try testing.expect(initial.review.?.pull_request == null);
    try testing.expectEqual(@as(bbr.review.ReviewRepositoryId, 42), initial.review.?.identity.local.repository_id);
    try testing.expectEqualStrings("refs/remotes/origin/main", initial.review.?.identity.local.base_ref);
    try testing.expectEqualStrings("refs/heads/feature", initial.review.?.identity.local.source_ref);
    try testing.expect(!initial.action_availability.available(.open_pull_request_picker));
    try testing.expect(!initial.action_availability.available(.submit));

    try presentation.dispatch(.{ .action = .open_pull_request_picker });
    try testing.expectEqual(ActionError.local_review_no_picker, presentation.projection().action_error.?);
    try testing.expect(presentation.takeCommand() == null);
    try presentation.dispatch(.{ .action = .submit });
    try testing.expectEqual(ActionError.local_review_no_submission, presentation.projection().action_error.?);
    try presentation.dispatch(.{ .action = .recover_submission });
    try testing.expectEqual(ActionError.local_review_remote_action_unavailable, presentation.projection().action_error.?);

    try presentation.dispatch(.{ .action = .refresh });
    const refresh = presentation.takeCommand().?.load_session;
    try testing.expectEqual(SessionLoadCause.refresh, refresh.cause);
    try testing.expect(OwnedReviewIdentity.eql(key, refresh.key));
}

test "local inline authoring persists a local target and authored context" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.initLocal(42, "refs/remotes/origin/main", "refs/heads/feature");
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testLocalSession(testing.allocator) },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .inline_comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("remember this") } });
    try presentation.dispatch(.{ .composer = .save });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(bbr.review.CommentTarget.local, drafts[0].target);
    try testing.expectEqualStrings("source", drafts[0].anchor.?.commit.?);
    try testing.expectEqualStrings("old\nnew", drafts[0].snapshot.?.text);
    try testing.expectEqual(@as(u32, 1), drafts[0].snapshot.?.selection_start);
    try testing.expectEqual(@as(u32, 1), drafts[0].snapshot.?.selection_len);
}

test "resize publishes one complete Presentation Frame revision" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .geometry = .{ .cols = 80, .rows = 8 },
    });
    defer presentation.deinit();

    const before = presentation.projection().review.?.frame;
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .toggle_select });
    const navigated = presentation.projection().review.?.frame;
    try testing.expect(navigated.revision > before.revision);
    const owner = navigated.targets[navigated.navigation.cursor].owner;
    try presentation.dispatch(.{ .resize = .{ .cols = 40, .rows = 4 } });
    const after = presentation.projection().review.?.frame;

    try testing.expectEqual(navigated.revision + 1, after.revision);
    try testing.expectEqual(@as(u16, 40), after.geometry.cols);
    try testing.expectEqual(@as(u16, 4), after.geometry.rows);
    try testing.expect(after.targets_revision <= after.revision);
    try testing.expect(owner.eql(after.targets[after.navigation.cursor].owner));
    try testing.expectEqual(navigated.navigation.mark, after.navigation.mark);
    try testing.expectEqual(@as(usize, after.panes.sidebar_content.height), after.file_tree.viewport);
    try testing.expect(after.file_tree.entries[after.file_tree.cursor].active);
}

fn testTwoFileSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    const pr: bbr.bitbucket.PullRequest = .{
        .id = id,
        .title = "Two files",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.source = .{ .remote = pr };
    s.header = .{
        .title = pr.title,
        .source_ref = pr.source_branch,
        .base_ref = pr.destination_branch,
        .source_commit = pr.source_commit,
        .base_commit = pr.destination_commit,
        .author = pr.author_display_name,
        .locator = "repo",
        .source_label = "Bitbucket",
        .pull_request_id = pr.id,
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

fn testUnicodeSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try testSession(backing, id, 'u');
    errdefer s.destroy();
    s.diff = try bbr.diff.parse(s.arena.allocator(),
        \\diff --git a/unicode.zig b/unicode.zig
        \\--- a/unicode.zig
        \\+++ b/unicode.zig
        \\@@ -1 +1 @@
        \\-plain
        \\+é界👩‍💻
    );
    const comments = try s.arena.allocator().alloc(bbr.review.Comment, 1);
    comments[0] = .{
        .id = 1,
        .author = "Metrics",
        .body = "é界👩‍💻",
        .anchor = .{ .path = "unicode.zig", .to = 1 },
    };
    s.threads = try bbr.review.buildThreads(s.arena.allocator(), comments);
    return s;
}

const matrix_graphemes = [_]struct { text: []const u8, cell_width: usize }{
    .{ .text = "é", .cell_width = 1 },
    .{ .text = "界", .cell_width = 2 },
    .{ .text = "👩‍💻", .cell_width = 2 },
};

const MatrixGraphemeMetrics = struct {
    fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
        for (matrix_graphemes) |grapheme| if (std.mem.startsWith(u8, text, grapheme.text))
            return .{ .byte_len = grapheme.text.len, .cell_width = grapheme.cell_width };
        const byte_len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        return .{ .byte_len = @min(@as(usize, byte_len), text.len), .cell_width = 1 };
    }

    const context: u8 = 0;
    const vtable: frame_mod.CellMetrics.VTable = .{ .next = next };
    const value: frame_mod.CellMetrics = .{ .ptr = &context, .vtable = &vtable };
};

fn expectCompleteMatrixGraphemes(text: []const u8) !void {
    var remaining = text;
    while (remaining.len > 0) {
        var matched = false;
        for (matrix_graphemes) |grapheme| {
            if (!std.mem.startsWith(u8, remaining, grapheme.text)) continue;
            remaining = remaining[grapheme.text.len..];
            matched = true;
            break;
        }
        if (!matched) return error.SplitGrapheme;
    }
}

test "M15 Layout Scope and geometry matrix restores a Unicode source row" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .cell_metrics = MatrixGraphemeMetrics.value,
    }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testUnicodeSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();

    var source_row: usize = 0;
    for (presentation.projection().review.?.buffer.rows, 0..) |row, index| {
        if (row == .line and row.line.line.kind == .added) {
            source_row = index;
            break;
        }
    }
    try moveToRow(&presentation, source_row);
    const owner = presentation.projection().review.?.frame.targets[source_row].owner;
    const geometries = [_]frame_mod.Geometry{
        .{ .cols = 0, .rows = 0 },
        .{ .cols = 8, .rows = 2 },
        .{ .cols = 80, .rows = 24 },
        .{ .cols = 240, .rows = 80 },
    };
    try testing.expectEqual(@as(usize, 5), MatrixGraphemeMetrics.value.width("é界👩‍💻"));

    for (0..2) |layout_index| {
        if (layout_index > 0) try presentation.dispatch(.{ .action = .toggle_layout });
        for (0..3) |scope_index| {
            if (scope_index > 0) try presentation.dispatch(.{ .action = .cycle_scope });
            for (geometries) |geometry| {
                try presentation.dispatch(.{ .resize = geometry });
                const review = presentation.projection().review.?;
                try testing.expectEqual(geometry, review.frame.geometry);
                try testing.expect(review.frame.targets_revision <= review.frame.revision);
                try testing.expect(review.navigation.cursor < review.frame.targets.len);
                try testing.expect(owner.eql(review.frame.targets[review.navigation.cursor].owner));
                try testing.expectEqualStrings("é界👩‍💻", lineAtRow(review.buffer.rows[review.navigation.cursor]).?.text);
                var saw_projected_body = false;
                for (review.buffer.rows) |row| if (row == .comment and row.comment.part == .body) {
                    saw_projected_body = true;
                    for (row.comment.segments) |segment| try expectCompleteMatrixGraphemes(segment.text);
                };
                try testing.expect(saw_projected_body);
            }
        }
        try presentation.dispatch(.{ .action = .cycle_scope });
    }
}

fn testDirectorySession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try testTwoFileSession(backing, id);
    errdefer s.destroy();
    s.diff = try bbr.diff.parse(s.arena.allocator(),
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1 +1 @@
        \\-old a
        \\+new a
        \\diff --git a/src/b.zig b/src/b.zig
        \\--- a/src/b.zig
        \\+++ b/src/b.zig
        \\@@ -1 +1 @@
        \\-old b
        \\+new b
    );
    return s;
}

test "Pane focus gives the Sidebar an independent cursor while DiffPane File motions remain complete" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();

    var frame = presentation.projection().review.?.frame;
    try testing.expectEqual(frame_mod.PaneFocus.diff, frame.focus);
    try testing.expect(frame.file_tree.entries[frame.file_tree.cursor].identity.eql(.{ .file = 0 }));

    try presentation.dispatch(.{ .action = .focus_next_pane });
    try presentation.dispatch(.{ .action = .down });
    frame = presentation.projection().review.?.frame;
    try testing.expectEqual(frame_mod.PaneFocus.sidebar, frame.focus);
    try testing.expect(frame.file_tree.entries[frame.file_tree.cursor].identity.eql(.{ .file = 1 }));
    try presentation.dispatch(.{ .action = .toggle_directory });
    frame = presentation.projection().review.?.frame;
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(frame.buffer, frame.navigation.cursor));

    // File Actions are scoped to the DiffPane and do not consume Sidebar state.
    try presentation.dispatch(.{ .action = .prev_file });
    frame = presentation.projection().review.?.frame;
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(frame.buffer, frame.navigation.cursor));
    try presentation.dispatch(.{ .action = .focus_next_pane });
    try presentation.dispatch(.{ .action = .prev_file });
    frame = presentation.projection().review.?.frame;
    try testing.expectEqual(@as(usize, 0), fileIndexForRow(frame.buffer, frame.navigation.cursor));
    try testing.expect(frame.file_tree.entries[frame.file_tree.cursor].identity.eql(.{ .file = 1 }));
}

test "File finder filters synchronously and confirms within the same Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();
    const epoch = presentation.projection().review.?.session_epoch;

    try presentation.dispatch(.{ .key = .{ .codepoint = 'F', .text = "F" } });
    try testing.expect(presentation.projection().file_finder != null);
    try presentation.dispatch(.{ .key = .{ .codepoint = 'x', .text = "xyz" } });
    try testing.expectEqual(@as(usize, 0), presentation.projection().file_finder.?.matches().len);
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.enter } });
    try testing.expect(presentation.projection().file_finder != null);
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.escape } });
    try presentation.dispatch(.{ .action = .open_file_finder });
    try presentation.dispatch(.{ .key = .{ .codepoint = 'b', .text = "b" } });
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.enter } });

    const projection = presentation.projection();
    try testing.expect(projection.file_finder == null);
    try testing.expectEqual(epoch, projection.review.?.session_epoch);
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(projection.review.?.buffer, projection.review.?.navigation.cursor));
    try testing.expectEqual(frame_mod.PaneFocus.diff, projection.review.?.frame.focus);
}

test "File finder Escape dismisses and reopening resets its query" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .open_file_finder });
    try presentation.dispatch(.{ .key = .{ .codepoint = 'b', .text = "b" } });
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.escape } });
    try testing.expect(presentation.projection().file_finder == null);
    try presentation.dispatch(.{ .action = .open_file_finder });
    try testing.expectEqualStrings("", presentation.projection().file_finder.?.query());
}

test "Comment Action ladder carries inline File and Review scopes" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
    });
    defer presentation.deinit();
    const published = presentation.published.?;

    try presentation.dispatch(.{ .action = .review_comment });
    try testing.expect(published.composer.?.request.scope.? == .review);
    try presentation.dispatch(.{ .composer = .cancel });

    try presentation.dispatch(.{ .action = .file_comment });
    try testing.expect(published.composer.?.request.scope.? == .file);
    try testing.expectEqualStrings("a.zig", published.composer.?.request.scope.?.file.path);
    try presentation.dispatch(.{ .composer = .cancel });

    for (published.buffer.rows, 0..) |row, index| if (lineAtRow(row) != null) {
        published.navigation.jumpTo(index);
        break;
    };
    try presentation.dispatch(.{ .action = .inline_comment });
    try testing.expect(published.composer.?.request.anchor != null);
    try testing.expect(published.composer.?.request.scope == null);
}

test "source-only Action reports availability instead of silently doing nothing" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
    });
    defer presentation.deinit();
    presentation.published.?.navigation.jumpTo(0);
    try testing.expect(!presentation.projection().action_availability.available(.yank));
    try presentation.dispatch(.{ .action = .yank });
    try testing.expectEqual(ActionError.source_action_unavailable, presentation.projection().action_error.?);
}

test "yank Count skips Presentation rows and stops at the File boundary" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
    });
    defer presentation.deinit();
    const published = presentation.published.?;
    published.navigation.jumpTo(0); // File header; Count starts here and skips it.
    published.navigation.pushDigit(9);
    try presentation.dispatch(.{ .action = .yank });
    var command = presentation.takeCommand().?;
    defer command.deinit();
    try testing.expect(command == .copy_clipboard);
    try testing.expectEqualStrings("old a\nnew a", command.copy_clipboard.text);
    try testing.expectEqual(@as(usize, 0), published.navigation.count);
}

test "side-by-side yank applies provisional new-side-first source selection" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .toggle_layout });
    const published = presentation.published.?;
    for (published.buffer.rows, 0..) |row, index| if (row == .line_pair) {
        published.navigation.jumpTo(index);
        break;
    };
    try presentation.dispatch(.{ .action = .yank });
    var command = presentation.takeCommand().?;
    defer command.deinit();
    try testing.expectEqualStrings("new a", command.copy_clipboard.text);
    try presentation.dispatch(.{ .clipboard_completed = .{ .command_id = command.copy_clipboard.command_id, .success = true } });
    try testing.expectEqual(ClipboardStatus.copied, presentation.projection().clipboard_status.?);
}

test "Selection overrides Count for yank and clipboard failure is visible" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testDisclosureSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();

    var first_context: ?usize = null;
    for (presentation.projection().review.?.buffer.rows, 0..) |row, index| {
        const line = lineAtRow(row) orelse continue;
        if (std.mem.eql(u8, line.text, "c1")) {
            first_context = index;
            break;
        }
    }
    try testing.expect(first_context != null);
    try moveToRow(&presentation, first_context.?);
    try presentation.dispatch(.{ .action = .toggle_select });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .push_count_digit = 9 });
    try presentation.dispatch(.{ .action = .yank });

    var command = presentation.takeCommand().?;
    defer command.deinit();
    try testing.expectEqualStrings("c1\nc2", command.copy_clipboard.text);
    try testing.expectEqual(@as(usize, 0), presentation.projection().review.?.navigation.count);
    try testing.expect(presentation.projection().review.?.navigation.mark == null);
    try presentation.dispatch(.{ .clipboard_completed = .{ .command_id = command.copy_clipboard.command_id, .success = false } });
    try testing.expectEqual(ClipboardStatus.failed, presentation.projection().clipboard_status.?);
}

test "successful Session replacement resets Pane and Sidebar defaults" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .focus_next_pane });
    try presentation.dispatch(.{ .action = .down });

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{ .intent = command.intent, .outcome = .{ .loaded = try testTwoFileSession(testing.allocator, 2) } } });
    const frame = presentation.projection().review.?.frame;
    try testing.expectEqual(frame_mod.PaneFocus.diff, frame.focus);
    try testing.expectEqual(@as(usize, 0), frame.navigation.cursor);
    try testing.expect(frame.file_tree.entries[frame.file_tree.cursor].identity.eql(.{ .file = 0 }));
    for (frame.file_tree.entries) |entry| if (entry.identity == .directory) try testing.expect(entry.expanded);
}

fn testDisclosureSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    const pr: bbr.bitbucket.PullRequest = .{
        .id = id,
        .title = "Disclosure review",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.source = .{ .remote = pr };
    s.header = .{
        .title = pr.title,
        .source_ref = pr.source_branch,
        .base_ref = pr.destination_branch,
        .source_commit = pr.source_commit,
        .base_commit = pr.destination_commit,
        .author = pr.author_display_name,
        .locator = "repo",
        .source_label = "Bitbucket",
        .pull_request_id = pr.id,
    };
    s.diff = try bbr.diff.parse(a,
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,12 +1,12 @@
        \\-a
        \\+A
        \\ c1
        \\ c2
        \\ c3
        \\ c4
        \\ c5
        \\ c6
        \\ c7
        \\ c8
        \\ c9
        \\ c10
        \\-b
        \\+B
    );
    const comments = try a.alloc(bbr.review.Comment, 3);
    comments[0] = .{ .id = 1, .author = "Ada", .body = "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n\neight", .resolved = true, .anchor = .{ .path = "a.txt", .to = 12 } };
    comments[1] = .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "fixed" };
    comments[2] = .{ .id = 3, .author = "Cy", .body = "history", .state = .outdated, .anchor = .{ .path = "a.txt", .from = 99 } };
    s.threads = try bbr.review.buildThreads(a, comments);
    try s.initializeEnrichment();
    return s;
}

fn findDisclosureRow(rows: []const buffer_mod.Row, key: buffer_mod.DisclosureKey) ?usize {
    for (rows, 0..) |row, index| {
        const candidate = buffer_mod.disclosureKey(row) orelse continue;
        if (std.meta.eql(candidate, key)) return index;
    }
    return null;
}

fn moveToRow(presentation: *Presentation, row: usize) !void {
    try presentation.dispatch(.{ .action = .to_top });
    var index: usize = 0;
    while (index < row) : (index += 1) try presentation.dispatch(.{ .action = .down });
}

test "Session disclosures toggle independently persist through rebuilds and reset atomically" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store(), .comments_collapsed_rows = 2 }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testDisclosureSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 12 },
    });
    defer presentation.deinit();

    const thread_key: buffer_mod.DisclosureKey = .{ .resolved_thread = 1 };
    const initial = presentation.projection().review.?;
    const thread_row = findDisclosureRow(initial.buffer.rows, thread_key).?;
    try testing.expect(!initial.buffer.rows[thread_row].disclosure.expanded);
    try testing.expect(findDisclosureRow(initial.buffer.rows, .{ .outdated_file = &initial.diff.files[0] }) != null);

    try moveToRow(&presentation, thread_row);
    try presentation.dispatch(.{ .action = .toggle_disclosure });
    const opened = presentation.projection().review.?;
    try testing.expect(opened.buffer.rows[opened.navigation.cursor] == .disclosure);
    try testing.expect(std.meta.eql(thread_key, opened.buffer.rows[opened.navigation.cursor].disclosure.key));

    const card_key: buffer_mod.DisclosureKey = .{ .review_card = .{ .comment = 1 } };
    const card_row = findDisclosureRow(opened.buffer.rows, card_key).?;
    try moveToRow(&presentation, card_row);
    try presentation.dispatch(.{ .action = .toggle_disclosure });
    const nested = presentation.projection().review.?;
    try testing.expect(findDisclosureRow(nested.buffer.rows, thread_key) != null);
    try testing.expect(nested.buffer.rows[findDisclosureRow(nested.buffer.rows, card_key).?].comment.hidden_rows == 0);

    // A Fold is another independent key. Cycling Scope temporarily omits it;
    // returning to Changes restores the explicit choice.
    var fold_key: ?buffer_mod.DisclosureKey = null;
    var fold_row: usize = 0;
    for (nested.buffer.rows, 0..) |row, index| if (row == .disclosure and row.disclosure.kind == .fold) {
        fold_key = row.disclosure.key;
        fold_row = index;
        break;
    };
    try moveToRow(&presentation, fold_row);
    try presentation.dispatch(.{ .action = .toggle_disclosure });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try testing.expect(findDisclosureRow(presentation.projection().review.?.buffer.rows, fold_key.?) == null);
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .cycle_scope });
    const folds_restored = presentation.projection().review.?;
    try testing.expect(folds_restored.buffer.rows[findDisclosureRow(folds_restored.buffer.rows, fold_key.?).?].disclosure.expanded);

    // Saving a Draft also rebuilds the Frame without discarding choices.
    try presentation.dispatch(.{ .action = .review_comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("new review note") } });
    try presentation.dispatch(.{ .composer = .save });
    try testing.expect(presentation.projection().review.?.buffer.rows[findDisclosureRow(presentation.projection().review.?.buffer.rows, thread_key).?].disclosure.expanded);

    // Width and isolation rebuild the Frame but preserve both explicit choices.
    try presentation.dispatch(.{ .resize = .{ .cols = 72, .rows = 8 } });
    try testing.expect(presentation.projection().review.?.buffer.rows[findDisclosureRow(presentation.projection().review.?.buffer.rows, thread_key).?].disclosure.expanded);
    try presentation.dispatch(.{ .action = .isolate });
    try testing.expect(presentation.projection().review.?.buffer.rows[findDisclosureRow(presentation.projection().review.?.buffer.rows, thread_key).?].disclosure.expanded);

    // Selecting disclosed content and then collapsing its semantic owner drops
    // the Selection because that content no longer exists in the new Frame.
    const content_row = findDisclosureRow(presentation.projection().review.?.buffer.rows, thread_key).? + 1;
    try moveToRow(&presentation, content_row);
    try presentation.dispatch(.{ .action = .toggle_select });
    try moveToRow(&presentation, findDisclosureRow(presentation.projection().review.?.buffer.rows, thread_key).?);
    try presentation.dispatch(.{ .action = .toggle_disclosure });
    try testing.expect(presentation.projection().review.?.navigation.mark == null);

    // Reopen, then prove failed replacement preserves it and successful
    // replacement starts from the canonical all-collapsed defaults.
    try presentation.dispatch(.{ .action = .toggle_disclosure });
    const before_failed = presentation.projection().review.?;
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const failed_command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{ .intent = failed_command.intent, .outcome = .{ .failed = error.NetworkFailure } } });
    try testing.expectEqual(before_failed.buffer.rows.ptr, presentation.projection().review.?.buffer.rows.ptr);
    try testing.expect(presentation.projection().review.?.buffer.rows[findDisclosureRow(presentation.projection().review.?.buffer.rows, thread_key).?].disclosure.expanded);

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const replacement = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{ .intent = replacement.intent, .outcome = .{ .loaded = try testDisclosureSession(testing.allocator, 2) } } });
    const replaced = presentation.projection().review.?;
    try testing.expect(!replaced.buffer.rows[findDisclosureRow(replaced.buffer.rows, thread_key).?].disclosure.expanded);
}

test "failed replacement Buffer construction preserves the published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const a = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(failing.allocator(), .{
        .reviews = store.store(),
    }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = a },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;

    const candidate = try testSession(testing.allocator, 2, 'b');
    failing.fail_index = failing.alloc_index + 1; // Published allocation succeeds; Buffer allocation fails.
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = candidate },
    } });

    try testing.expect(failing.has_induced_failure);
    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 1), after.review.?.pull_request.?.id);
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
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 3) });

    const command = presentation.takeCommand().?.load_session;
    try testing.expectEqual(@as(u64, 3), command.key.pull_request_id);
    try testing.expect(presentation.takeCommand() == null);
}

test "a complete candidate publishes atomically and advances the Session Epoch" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 2), after.review.?.pull_request.?.id);
    try testing.expectEqual(before.session_epoch + 1, after.review.?.session_epoch);
    try testing.expect(after.review.?.buffer.rows.ptr != before.buffer.rows.ptr);
    try testing.expect(!after.replacing);
    try testing.expect(after.replacement_error == null);
}

test "replacement rollback preserves input grammar and commit resets it" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .key = .{ .codepoint = 'g', .text = "g" } });
    try testing.expectEqual(@as(u4, 1), presentation.resolver.pending_len);
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const failed = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = failed.intent,
        .outcome = .{ .failed = error.NotFound },
    } });
    try testing.expectEqual(@as(u4, 1), presentation.resolver.pending_len);

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const loaded = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = loaded.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try testing.expectEqual(@as(u4, 0), presentation.resolver.pending_len);
}

test "a stale candidate is disposed and the latest failure restores the exact published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const b = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 3) });
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
    try testing.expectEqual(@as(u64, 1), after.review.?.pull_request.?.id);
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
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 1) });
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .down });
    const before = presentation.projection().review.?.navigation;
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testTwoFileSession(testing.allocator, 1),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .toggle_layout });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .isolate });
    const isolated = presentation.projection().review.?;
    try testing.expectEqual(@as(?usize, 0), isolated.isolated_file);
    try testing.expectEqual(Layout.side_by_side, isolated.preferences.layout);
    try testing.expectEqual(Scope.fetched, isolated.preferences.scope);

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'c') },
    } });

    const replaced = presentation.projection().review.?;
    try testing.expectEqual(Layout.side_by_side, replaced.preferences.layout);
    try testing.expectEqual(Scope.fetched, replaced.preferences.scope);
    try testing.expectEqual(@as(?usize, null), replaced.isolated_file);
    try testing.expectEqual(@as(usize, 0), replaced.navigation.cursor);
}

test "saving a Composer Draft persists it for a later Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);

    {
        var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
            .viewport_rows = 8,
        });
        defer presentation.deinit();

        try presentation.dispatch(.{ .action = .review_comment });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 7,
        .kind = .comment,
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .review_comment });
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

test "Composer save allocation failure preserves Composer and the exact published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .review_comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("keep me") } });
    const before = presentation.projection().review.?;

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .composer = .save });

    const failed = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(ActionError.out_of_memory, failed.action_error.?);
    try testing.expectEqualStrings("keep me", failed.composer.?.body);
    try testing.expectEqual(@as(usize, 0), failed.review.?.drafts.len);
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, failed.review.?.navigation));
}

test "inline Composer allocation failure publishes no invalid Overlay" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .review_comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("survive rollback") } });

    const key_two = try OwnedReviewIdentity.init("workspace", "repo", 2);
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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

test "external commands receive unique nonzero CommandIds" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.ensure_focused_enrichment);
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const enrich = presentation.takeCommand().?.enrich_file;
    const load = presentation.takeCommand().?.load_session;

    try testing.expect(enrich.command_id != 0);
    try testing.expect(load.command_id != 0);
    try testing.expect(enrich.command_id != load.command_id);
}

test "wrong-target completion consumes CommandId and later owned completion is disposed" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const load = presentation.takeCommand().?.load_session;

    try presentation.dispatch(.{ .clipboard_completed = .{ .command_id = load.command_id, .success = true } });
    try testing.expect(presentation.projection().clipboard_status == null);
    try presentation.dispatch(.{ .session_loaded = .{
        .command_id = load.command_id,
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    try testing.expectEqual(@as(u64, 1), presentation.projection().review.?.pull_request.?.id);
    try testing.expect(presentation.projection().replacing);
}

test "duplicate completion is discarded after first admission" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    const copy = try testing.allocator.create(ClipboardCopy);
    copy.* = .{ .allocator = testing.allocator, .text = try testing.allocator.dupe(u8, "copy") };
    try presentation.commands.append(testing.allocator, .{ .copy_clipboard = copy });
    var command = presentation.takeCommand().?;
    const command_id = command.copy_clipboard.command_id;
    command.deinit();

    try presentation.dispatch(.{ .clipboard_completed = .{ .command_id = command_id, .success = true } });
    try presentation.dispatch(.{ .clipboard_completed = .{ .command_id = command_id, .success = false } });

    try testing.expectEqual(ClipboardStatus.copied, presentation.projection().clipboard_status.?);
}

test "stale-Epoch File Enrichment completion is consumed without changing Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.ensure_focused_enrichment);
    const enrich = presentation.takeCommand().?.enrich_file;

    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .command_id = enrich.command_id,
        .work_id = enrich.work_id,
        .session_epoch = enrich.session_epoch + 1,
        .file_index = enrich.file_index,
        .outcome = .{ .failed = .launch_failed },
    } });

    try testing.expect(presentation.projection().action_error == null);
    try presentation.dispatch(.request_shutdown);
    try testing.expect(presentation.readyToExit());
}

test "disabled File cache discards an inactive completion and revisiting refetches it" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .file_cache_enabled = false,
    }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testTwoFileSession(testing.allocator, 1),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.ensure_focused_enrichment);
    const first = presentation.takeCommand().?.enrich_file;
    try testing.expectEqual(@as(usize, 0), first.file_index);
    try presentation.dispatch(.{ .action = .next_file });
    try presentation.dispatch(.ensure_focused_enrichment);
    _ = presentation.takeCommand().?.enrich_file;

    const responses = [_]bbr.http.Canned{
        .{ .status = 200, .body = "old a\n" },
        .{ .status = 200, .body = "new a\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
    var highlighter = TestNoopHighlighter{};
    const result = try file_enrichment.enrich(testing.allocator, client, highlighter.highlighter(), first.request());
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .work_id = first.work_id,
        .session_epoch = first.session_epoch,
        .file_index = first.file_index,
        .outcome = .{ .completed = result },
    } });

    try presentation.dispatch(.{ .action = .prev_file });
    try presentation.dispatch(.ensure_focused_enrichment);
    try testing.expectEqual(@as(usize, 0), presentation.takeCommand().?.enrich_file.file_index);
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
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
    try testing.expectEqual(@as(u64, 1), presentation.projection().review.?.pull_request.?.id);
    try testing.expect(presentation.projection().review.?.buffer.rows.len > before_rows);
}

test "replacement preserves queued File Enrichment for the published rollback Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.ensure_focused_enrichment);
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });

    try testing.expect(presentation.takeCommand().? == .enrich_file);
    try testing.expect(presentation.takeCommand().? == .load_session);
    try testing.expect(presentation.takeCommand() == null);
}

test "stale File Enrichment is disposed without mutating the replacement Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.ensure_focused_enrichment);
    const enrich = presentation.takeCommand().?.enrich_file;
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
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
    try testing.expectEqual(@as(u64, 2), after.review.?.pull_request.?.id);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expect(after.action_error == null);
}

test "admitted File Enrichment survives failed Buffer reprojection" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
    try presentation.dispatch(.{ .action = .toggle_layout });
    try testing.expect(presentation.projection().review.?.buffer.rows.ptr != before.buffer.rows.ptr);
    try testing.expect(presentation.projection().action_error == null);
}

test "File Enrichment launch failure restores retryable pending state" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
            .key = try OwnedReviewIdentity.init("workspace", "repo", 1),
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "publish me" });
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

test "durable completion with wrong Review target is consumed and discarded" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "publish me" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') } });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var command = presentation.takeCommand().?;
    const post = command.post_draft;
    const command_id = post.command_id;
    const operation_id = post.operation_id;
    const temp_id = post.draft.local_id;
    post.destroy();
    command = undefined;

    try presentation.dispatch(.{ .post_draft_completed = .{
        .command_id = command_id,
        .operation_id = operation_id,
        .identity = .init(try OwnedReviewIdentity.init("workspace", "other", 1)),
        .temp_id = temp_id,
        .outcome = .{ .posted = 900 },
    } });
    try presentation.dispatch(.{ .post_draft_completed = .{
        .command_id = command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = temp_id,
        .outcome = .{ .posted = 900 },
    } });

    try testing.expect(presentation.projection().submission != null);
    try testing.expectEqual(@as(?bbr.review.TempId, 1), presentation.projection().submission.?.current_temp_id);
}

test "Submission lock contention emits no command or durable intent" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "publish me" });
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

test "fresh Submission checks the source commit before its first POST" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "stale anchor" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
        .require_source_check = true,
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    const check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(check.command_id, check.operation_id, null, "different-head"));

    try testing.expect(presentation.takeCommand() == null);
    try testing.expect(presentation.projection().submission == null);
    try testing.expect(presentation.projection().submission_result.?.completion == .aborted);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.store().load(arena.allocator(), key.storeKey()))[0].state == .draft);
    try testing.expect((try store.store().activeSubmission(arena.allocator())) == null);
}

test "startup discovers and explicitly claims an interrupted Submission" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "recover me" });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", 1);

    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .viewport_rows = 8 });
    defer presentation.deinit();

    const notice = presentation.projection().recovery.?;
    try testing.expectEqual(operation_id, notice.operation_id);
    try testing.expectEqual(RecoveryOwnership.recoverable, notice.ownership);
    try presentation.dispatch(.{ .action = .recover_submission });
    const check = presentation.takeCommand().?.check_recovery;
    try testing.expectEqual(operation_id, check.operation_id);
    try testing.expect(presentation.projection().recovery == null);
    try testing.expect(presentation.projection().submission != null);

    try presentation.dispatch(recoveryCheckSucceeded(check.command_id, operation_id, null, "old-head"));
    var post = presentation.takeCommand().?;
    defer post.deinit();
    try testing.expect(post.post_draft.dedupe);
    try testing.expectEqual(@as(bbr.review.TempId, 1), post.post_draft.draft.local_id);
}

test "startup reports a live owner without stealing its Submission" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "owned" });
    _ = try store.store().beginSubmission(key.storeKey(), "head", 1);
    var owner = (try locks.locks().tryAcquire(key.storeKey())).?;
    defer owner.release();

    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .viewport_rows = 8 });
    defer presentation.deinit();
    try testing.expectEqual(RecoveryOwnership.running_elsewhere, presentation.projection().recovery.?.ownership);
    try presentation.dispatch(.{ .action = .recover_submission });
    try testing.expectEqual(ActionError.submission_owned_elsewhere, presentation.projection().action_error.?);
    try testing.expect(presentation.takeCommand() == null);
}

test "changed-source recovery only runs the Duplicate guard and leaves a miss unresolved" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "stale" });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", 1);
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .viewport_rows = 8 });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .recover_submission });
    const check = presentation.takeCommand().?.check_recovery;

    try presentation.dispatch(recoveryCheckSucceeded(check.command_id, operation_id, null, "new-head"));
    try testing.expectEqual(ActionError.recovery_source_changed, presentation.projection().action_error.?);
    var duplicate = presentation.takeCommand().?;
    const temp_id = duplicate.find_duplicate.draft.local_id;
    duplicate.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 1), temp_id);
    try presentation.dispatch(.{ .duplicate_checked = .{
        .operation_id = operation_id,
        .temp_id = temp_id,
        .outcome = .missing,
    } });
    try testing.expect(presentation.projection().submission == null);
    try testing.expectEqual(@as(usize, 1), presentation.projection().submission_result.?.outcome_unknown);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.store().load(arena.allocator(), key.storeKey()))[0].state == .outcome_unknown);
    try testing.expect((try store.store().activeSubmission(arena.allocator())) == null);
}

test "changed-source Duplicate guard records an existing Comment without posting" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "already posted" });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", 1);
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .viewport_rows = 8 });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .recover_submission });
    const check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(check.command_id, operation_id, null, "new-head"));
    var duplicate = presentation.takeCommand().?;
    duplicate.deinit();
    try presentation.dispatch(.{ .duplicate_checked = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .found = 900 },
    } });

    try testing.expect(presentation.takeCommand() == null);
    try testing.expectEqual(@as(usize, 1), presentation.projection().submission_result.?.posted);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try store.store().load(arena.allocator(), key.storeKey())).len);
}

test "reviewer can mark a selected unresolved Draft as unpublished" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "unknown", .state = .outcome_unknown });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    for (presentation.published.?.buffer.rows, 0..) |row, index| if (row == .draft and row.draft.draftItem().local_id == 1) {
        presentation.published.?.navigation.jumpTo(index);
        break;
    };

    try presentation.dispatch(.{ .action = .resolve_unpublished });
    try testing.expect(presentation.published.?.review.getConst(1).?.state == .draft);
}

test "reviewer can link a selected unresolved Draft to an existing Comment" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "unknown", .state = .outcome_unknown });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    for (presentation.published.?.buffer.rows, 0..) |row, index| if (row == .draft and row.draft.draftItem().local_id == 1) {
        presentation.published.?.navigation.jumpTo(index);
        break;
    };
    try presentation.dispatch(.{ .action = .link_existing_comment });
    try presentation.dispatch(.{ .unknown_resolution = .{ .digit = 8 } });
    try presentation.dispatch(.{ .unknown_resolution = .{ .digit = 1 } });
    try presentation.dispatch(.{ .unknown_resolution = .{ .digit = 2 } });
    try presentation.dispatch(.{ .unknown_resolution = .confirm });

    try testing.expect(presentation.projection().unknown_resolution == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(bbr.review.CommentId, 812), (try store.store().load(arena.allocator(), key.storeKey()))[0].state.posted);
    try testing.expect(presentation.takeCommand().? == .load_session);
}

test "portable key input owns help overlay capture" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .key = .{ .codepoint = '?', .text = "?" } });
    try testing.expect(presentation.projection().help_visible);
    try presentation.dispatch(.{ .key = .{ .codepoint = 'j', .text = "j" } });
    try testing.expect(!presentation.projection().help_visible);
}

test "portable Picker input loads summaries and selects a replacement" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .key = .{ .codepoint = 'p', .text = "p" } });
    const list = presentation.takeCommand().?.list_pull_requests;
    var summaries = try PullRequestSummaries.create(testing.allocator);
    summaries.prs = try summaries.arena.allocator().dupe(bbr.bitbucket.PullRequestSummary, &.{.{
        .id = 2,
        .title = "second",
        .state = "OPEN",
        .author_display_name = "reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
    }});
    try presentation.dispatch(.{ .pull_requests_loaded = .{
        .work_id = list.work_id,
        .outcome = .{ .loaded = summaries },
    } });
    try testing.expect(presentation.projection().picker != null);
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.enter } });
    try testing.expect(presentation.projection().picker == null);
    try testing.expectEqual(@as(u64, 2), presentation.takeCommand().?.load_session.key.pull_request_id);
}

test "Picker tick advances only its visible loading scope" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .key = .{ .codepoint = 'p', .text = "p" } });
    const list = presentation.takeCommand().?.list_pull_requests;
    const initial = presentation.projection().picker.?.spinnerGlyph();
    try testing.expectEqual(list.work_id, presentation.projection().picker_tick_scope.?);

    try presentation.dispatch(.{ .picker_tick = list.work_id + 1 });
    try testing.expectEqualStrings(initial, presentation.projection().picker.?.spinnerGlyph());
    try presentation.dispatch(.{ .picker_tick = list.work_id });
    try testing.expect(!std.mem.eql(u8, initial, presentation.projection().picker.?.spinnerGlyph()));

    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.escape } });
    try testing.expect(presentation.projection().picker == null);
    try testing.expect(presentation.projection().picker_tick_scope == null);
    try presentation.dispatch(.{ .picker_tick = list.work_id });
    try testing.expect(presentation.projection().picker == null);
}

test "shutdown closes Picker and disposes its late completion" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .key = .{ .codepoint = 'p', .text = "p" } });
    const list = presentation.takeCommand().?.list_pull_requests;
    try presentation.dispatch(.request_shutdown);
    try testing.expect(presentation.projection().picker == null);
    try testing.expect(!presentation.readyToExit());

    const summaries = try PullRequestSummaries.create(testing.allocator);
    try presentation.dispatch(.{ .pull_requests_loaded = .{
        .work_id = list.work_id,
        .outcome = .{ .loaded = summaries },
    } });
    try testing.expect(presentation.projection().picker == null);
    try testing.expect(presentation.readyToExit());
}

test "Submission payload and identity survive originating Session replacement" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const first_key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(first_key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "survive replacement" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = first_key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const post = presentation.takeCommand().?.post_draft;
    defer post.destroy();
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    try testing.expectEqual(@as(u64, 2), presentation.projection().review.?.key.pull_request_id);
    try testing.expectEqual(@as(u64, 1), presentation.projection().submission.?.key.pull_request_id);
    try testing.expectEqual(@as(usize, 0), presentation.projection().submission.?.completed);
    try testing.expectEqual(@as(usize, 1), presentation.projection().submission.?.total);
    try testing.expectEqualStrings("survive replacement", post.draft.body);
}

test "Submission completion does not reconcile over a different visible PR" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const first_key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    const second_key = try OwnedReviewIdentity.init("workspace", "repo", 2);
    try store.store().put(first_key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "post elsewhere" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = first_key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    const operation_id = post.post_draft.operation_id;
    post.deinit();
    try presentation.dispatch(.{ .choose_pull_request = second_key });
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    try presentation.dispatch(.{ .post_draft_completed = .{
        .operation_id = operation_id,
        .temp_id = 1,
        .outcome = .{ .posted = 900 },
    } });

    try testing.expectEqual(@as(u64, 2), presentation.projection().review.?.key.pull_request_id);
    try testing.expect(presentation.projection().submission == null);
    const result = presentation.projection().submission_result.?;
    try testing.expectEqual(@as(u64, 1), result.key.pull_request_id);
    try testing.expect(result.completion == .clean);
    try testing.expectEqual(@as(usize, 1), result.posted);
    try testing.expectEqual(@as(usize, 0), result.failed);
    try testing.expect(presentation.takeCommand() == null);
    try presentation.dispatch(.dismiss_submission_result);
    try testing.expect(presentation.projection().submission_result == null);
}

test "shutdown retains an authorized Submission command and waits for terminal durability" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "finish me" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "publish me" });
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
    presentation.published.?.session.header.source_commit = &long_commit;
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "publish me" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "parent" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "first" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "second" });
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

test "final successful POST completes clean, releases ownership, and reconciles the visible PR" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "only" });
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

    const reconciliation = presentation.takeCommand().?.load_session;
    try testing.expect(reconciliation.cause == .reconciliation);
    try testing.expect(OwnedReviewIdentity.eql(reconciliation.key, key));
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "retry" });
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

test "wait launch failure pauses and submit retries the exact delay" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "retry wait" });
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
    try presentation.dispatch(.{ .submission_wait_launch_failed = wait });

    try testing.expectEqual(ActionError.submission_launch_failed, presentation.projection().action_error.?);
    try testing.expect(presentation.takeCommand() == null);
    try presentation.dispatch(.{ .action = .submit });
    const retry = presentation.takeCommand().?.wait_submission;
    try testing.expectEqual(wait.operation_id, retry.operation_id);
    try testing.expectEqual(wait.temp_id, retry.temp_id);
    try testing.expectEqual(wait.ms, retry.ms);
}

test "exhausted ambiguous POST persists an immutable unresolved Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "uncertain" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "keep pending" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "retain me" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "first" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "second" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "only" });
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
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "only" });
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

test "POST launch failure pauses without reporting a remote outcome and submit retries" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "retry launch" });
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

    try presentation.dispatch(.{ .post_draft_launch_failed = .{
        .operation_id = operation_id,
        .temp_id = 1,
    } });

    try testing.expectEqual(ActionError.submission_launch_failed, presentation.projection().action_error.?);
    try testing.expect(presentation.takeCommand() == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.store().load(arena.allocator(), key.storeKey()))[0].state == .submitting);

    try presentation.dispatch(.{ .action = .submit });
    var retry = presentation.takeCommand().?;
    defer retry.deinit();
    try testing.expectEqual(operation_id, retry.post_draft.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 1), retry.post_draft.draft.local_id);
    try testing.expect(!retry.post_draft.dedupe);
}

test "shutdown retries a paused terminal persistence step" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "only" });
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

test "mouse click uses the published Frame target and a Motion cancels a pending press" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();
    const content = presentation.projection().review.?.frame.panes.diff_content;

    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 2, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 2, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 2), presentation.projection().review.?.navigation.cursor);

    try presentation.dispatch(.{ .action = .to_top });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 2, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 2, .button = .left, .type = .motion } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 2, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 0), presentation.projection().review.?.navigation.cursor);

    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 2, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 3, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 0), presentation.projection().review.?.navigation.cursor);

    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 3, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 3, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 1), presentation.projection().review.?.navigation.cursor);
}

test "mouse wheel uses configured rows without focus changes and ignored gestures are inert" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .mouse_vertical_scroll_rows = 2,
    }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 4 },
    });
    defer presentation.deinit();
    const diff = presentation.projection().review.?.frame.panes.diff_content;
    try presentation.dispatch(.{ .action = .toggle_select });
    try presentation.dispatch(.{ .mouse = .{ .col = diff.x, .row = diff.y, .button = .wheel_down, .type = .press } });
    var frame = presentation.projection().review.?.frame;
    try testing.expectEqual(@as(usize, 2), frame.navigation.scroll);
    try testing.expectEqual(@as(usize, 2), frame.navigation.cursor);
    try testing.expectEqual(@as(?usize, 0), frame.navigation.mark);
    try testing.expectEqual(frame_mod.PaneFocus.diff, frame.focus);

    const before = frame.navigation;
    for ([_]MouseInput{
        .{ .col = diff.x, .row = diff.y, .button = .wheel_left, .type = .press },
        .{ .col = diff.x, .row = diff.y, .button = .right, .type = .press },
        .{ .col = diff.x, .row = diff.y, .button = .left, .type = .drag },
        .{ .col = diff.x, .row = diff.y, .button = .left, .type = .press, .modified = true },
    }) |mouse| try presentation.dispatch(.{ .mouse = mouse });
    frame = presentation.projection().review.?.frame;
    try testing.expectEqual(before.cursor, frame.navigation.cursor);
    try testing.expectEqual(before.scroll, frame.navigation.scroll);

    var disabled = try Presentation.init(testing.allocator, .{ .reviews = store.store(), .mouse_enabled = false }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 2), .session = try testTwoFileSession(testing.allocator, 2) },
        .geometry = .{ .cols = 80, .rows = 4 },
    });
    defer disabled.deinit();
    const disabled_diff = disabled.projection().review.?.frame.panes.diff_content;
    try disabled.dispatch(.{ .mouse = .{ .col = disabled_diff.x, .row = disabled_diff.y, .button = .wheel_down, .type = .press } });
    try testing.expectEqual(@as(usize, 0), disabled.projection().review.?.navigation.scroll);
    try disabled.dispatch(.{ .action = .down });
    try testing.expectEqual(@as(usize, 1), disabled.projection().review.?.navigation.cursor);
}

test "Picker mouse click selects only and non-Picker Overlay captures Pane clicks" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .open_file_finder });
    const overlay = presentation.projection().review.?.frame.overlay.?;
    try presentation.dispatch(.{ .mouse = .{ .col = overlay.rect.x, .row = overlay.rect.y + 2, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = overlay.rect.x, .row = overlay.rect.y + 2, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 1), presentation.projection().file_finder.?.selected);
    try testing.expect(presentation.projection().file_finder != null); // click never confirms

    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.escape } });
    try presentation.dispatch(.{ .action = .review_comment });
    const before = presentation.projection().review.?.navigation.cursor;
    const diff = presentation.projection().review.?.frame.panes.diff_content;
    try presentation.dispatch(.{ .mouse = .{ .col = diff.x, .row = diff.y + 2, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = diff.x, .row = diff.y + 2, .button = .left, .type = .release } });
    try testing.expectEqual(before, presentation.projection().review.?.navigation.cursor);
    try testing.expect(presentation.projection().composer != null);
}

test "PullRequest Picker wheel and click move selection while Enter alone confirms" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testSession(testing.allocator, 1, 'a') },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .open_pull_request_picker });
    const list = presentation.takeCommand().?.list_pull_requests;
    var summaries = try PullRequestSummaries.create(testing.allocator);
    summaries.prs = try summaries.arena.allocator().dupe(bbr.bitbucket.PullRequestSummary, &.{
        .{ .id = 1, .title = "one", .state = "OPEN", .author_display_name = "a", .source_branch = "one", .destination_branch = "main" },
        .{ .id = 2, .title = "two", .state = "OPEN", .author_display_name = "b", .source_branch = "two", .destination_branch = "main" },
        .{ .id = 3, .title = "three", .state = "OPEN", .author_display_name = "c", .source_branch = "three", .destination_branch = "main" },
        .{ .id = 4, .title = "four", .state = "OPEN", .author_display_name = "d", .source_branch = "four", .destination_branch = "main" },
    });
    try presentation.dispatch(.{ .pull_requests_loaded = .{ .work_id = list.work_id, .outcome = .{ .loaded = summaries } } });
    const overlay = presentation.projection().review.?.frame.overlay.?;
    try presentation.dispatch(.{ .mouse = .{ .col = overlay.rect.x, .row = overlay.rect.y + 1, .button = .wheel_down, .type = .press } });
    try testing.expectEqual(@as(usize, 3), presentation.projection().picker.?.selected);

    const current_overlay = presentation.projection().review.?.frame.overlay.?;
    try presentation.dispatch(.{ .mouse = .{ .col = current_overlay.rect.x, .row = current_overlay.rect.y + 2, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = current_overlay.rect.x, .row = current_overlay.rect.y + 2, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 1), presentation.projection().picker.?.selected);
    try testing.expect(presentation.takeCommand() == null);

    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.enter } });
    try testing.expectEqual(@as(u64, 2), presentation.takeCommand().?.load_session.key.pull_request_id);
}

test "mouse activates Sidebar Files and disclosures and replacement cancels a press" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store(), .comments_collapsed_rows = 2 }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testDisclosureSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 8 },
    });
    defer presentation.deinit();
    const disclosure_key: buffer_mod.DisclosureKey = .{ .resolved_thread = 1 };
    const row = findDisclosureRow(presentation.projection().review.?.buffer.rows, disclosure_key).?;
    presentation.published.?.navigation.jumpTo(row);
    const frame = presentation.projection().review.?.frame;
    const screen_row: u16 = frame.panes.diff_content.y + @as(u16, @intCast(row - frame.navigation.scroll));
    try presentation.dispatch(.{ .mouse = .{ .col = frame.panes.diff_content.x, .row = screen_row, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = frame.panes.diff_content.x, .row = screen_row, .button = .left, .type = .release } });
    const opened = presentation.projection().review.?;
    try testing.expect(opened.buffer.rows[findDisclosureRow(opened.buffer.rows, disclosure_key).?].disclosure.expanded);

    const sidebar = opened.frame.panes.sidebar_content;
    try presentation.dispatch(.{ .mouse = .{ .col = sidebar.x, .row = sidebar.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = sidebar.x, .row = sidebar.y, .button = .left, .type = .release } });
    try testing.expectEqual(frame_mod.PaneFocus.sidebar, presentation.projection().review.?.frame.focus);

    const current = presentation.projection().review.?.frame;
    try presentation.dispatch(.{ .mouse = .{ .col = current.panes.diff_content.x, .row = current.panes.diff_content.y + 1, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{ .intent = load.intent, .outcome = .{ .loaded = try testDisclosureSession(testing.allocator, 2) } } });
    const replacement = presentation.projection().review.?.frame;
    try presentation.dispatch(.{ .mouse = .{ .col = replacement.panes.diff_content.x, .row = replacement.panes.diff_content.y + 1, .button = .left, .type = .release } });
    try testing.expectEqual(@as(usize, 0), presentation.projection().review.?.navigation.cursor);
}

test "failed Session replacement preserves a pending mouse press" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testTwoFileSession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .choose_pull_request = try OwnedReviewIdentity.init("workspace", "repo", 2) });
    const load = presentation.takeCommand().?.load_session;
    const frame = presentation.projection().review.?.frame;
    const target_row = frame.panes.diff_content.y + 2;
    try presentation.dispatch(.{ .mouse = .{
        .col = frame.panes.diff_content.x,
        .row = target_row,
        .button = .left,
        .type = .press,
    } });

    try presentation.dispatch(.{ .session_loaded = .{
        .intent = load.intent,
        .outcome = .{ .failed = error.NetworkFailure },
    } });
    try presentation.dispatch(.{ .mouse = .{
        .col = frame.panes.diff_content.x,
        .row = target_row,
        .button = .left,
        .type = .release,
    } });

    try testing.expectEqual(@as(usize, 2), presentation.projection().review.?.navigation.cursor);
    try testing.expectEqual(ReplacementError.session_load_failed, presentation.projection().replacement_error.?);
}

test "Sidebar mouse click toggles a Directory and focuses a child File" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try OwnedReviewIdentity.init("workspace", "repo", 1), .session = try testDirectorySession(testing.allocator, 1) },
        .geometry = .{ .cols = 80, .rows = 8 },
    });
    defer presentation.deinit();

    var frame = presentation.projection().review.?.frame;
    const content = frame.panes.sidebar_content;
    try testing.expect(frame.file_tree.entries[0].identity == .directory);
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y, .button = .left, .type = .release } });
    frame = presentation.projection().review.?.frame;
    try testing.expect(!frame.file_tree.entries[0].expanded);
    try testing.expectEqual(@as(usize, 1), frame.file_tree.entries.len);

    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y, .button = .left, .type = .release } });
    frame = presentation.projection().review.?.frame;
    try testing.expect(frame.file_tree.entries[0].expanded);
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 1, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 1, .button = .left, .type = .release } });
    frame = presentation.projection().review.?.frame;
    try testing.expectEqual(frame_mod.PaneFocus.sidebar, frame.focus);
    try testing.expect(frame.file_tree.entries[frame.file_tree.cursor].identity.eql(.{ .file = 0 }));
    try testing.expectEqual(@as(usize, 0), frame.navigation.cursor);
}
