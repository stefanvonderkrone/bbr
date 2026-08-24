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
    external_edit_max_bytes: usize = 1024 * 1024,
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
    reanchor: ReanchorInput,
    delete_confirmation: DeleteConfirmationInput,
    ensure_focused_enrichment,
    file_enrichment_completed: FileEnrichmentCompleted,
    post_draft_completed: PostDraftCompleted,
    post_draft_launch_failed: PostDraftLaunchFailed,
    comment_edit_completed: CommentEditCompleted,
    comment_edit_launch_failed: CommentEditLaunchFailed,
    comment_delete_completed: CommentDeleteCompleted,
    comment_delete_launch_failed: CommentDeleteLaunchFailed,
    submission_wait_completed: WaitSubmission,
    submission_wait_launch_failed: WaitSubmission,
    recovery_checked: RecoveryChecked,
    duplicate_checked: DuplicateChecked,
    pull_requests_loaded: PullRequestsLoaded,
    picker_tick: WorkId,
    clipboard_completed: ClipboardCompleted,
    external_edit_completed: *ExternalEditCompleted,
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
            .external_edit_completed => |completed| completed.destroy(),
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
    checkpoint: ?bbr.review.SubmissionRetryCheckpoint = null,
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
    rejected: bbr.bitbucket.ApiError,
    failed,
};

pub const DuplicateChecked = struct {
    command_id: CommandId = 0,
    operation_id: bbr.review.OperationId,
    identity: ?OwnedRemoteReviewIdentity = null,
    temp_id: bbr.review.TempId,
    outcome: DuplicateCheckOutcome,
    retry_after_ms: ?u64 = null,
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
    external_edit,
};

pub const UnknownResolutionInput = union(enum) {
    digit: u8,
    backspace,
    confirm,
    cancel,
};

/// Stage two of re-anchor: accept the candidate the source cursor names, or
/// cancel and leave the Draft exactly as it was.
pub const ReanchorInput = enum { accept, cancel };

pub const DeleteConfirmationInput = enum { confirm, cancel };

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

pub const CommentEditOutcome = union(enum) {
    updated,
    definitive_failure: bbr.bitbucket.ApiError,
    outcome_unknown,
};

pub const CommentEditCompleted = struct {
    command_id: CommandId,
    identity: OwnedRemoteReviewIdentity,
    comment_id: bbr.review.CommentId,
    outcome: CommentEditOutcome,
};

pub const CommentEditLaunchFailed = struct {
    command_id: CommandId,
    identity: OwnedRemoteReviewIdentity,
    comment_id: bbr.review.CommentId,
};

pub const CommentDeleteOutcome = union(enum) {
    deleted,
    not_found,
    definitive_failure: bbr.bitbucket.ApiError,
    outcome_unknown,
};

pub const CommentDeleteCompleted = struct {
    command_id: CommandId,
    identity: OwnedRemoteReviewIdentity,
    comment_id: bbr.review.CommentId,
    outcome: CommentDeleteOutcome,
};

pub const CommentDeleteLaunchFailed = struct {
    command_id: CommandId,
    identity: OwnedRemoteReviewIdentity,
    comment_id: bbr.review.CommentId,
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

pub const UpdateComment = struct {
    allocator: Allocator,
    command_id: CommandId = 0,
    identity: OwnedRemoteReviewIdentity,
    comment_id: bbr.review.CommentId,
    body: []u8,

    fn create(allocator: Allocator, key: OwnedReviewIdentity, comment_id: bbr.review.CommentId, body: []const u8) !*UpdateComment {
        const command = try allocator.create(UpdateComment);
        errdefer allocator.destroy(command);
        command.* = .{
            .allocator = allocator,
            .identity = .init(key),
            .comment_id = comment_id,
            .body = try allocator.dupe(u8, body),
        };
        return command;
    }

    pub fn destroy(self: *UpdateComment) void {
        const allocator = self.allocator;
        allocator.free(self.body);
        allocator.destroy(self);
    }
};

pub const DeleteComment = struct {
    allocator: Allocator,
    command_id: CommandId = 0,
    identity: OwnedRemoteReviewIdentity,
    comment_id: bbr.review.CommentId,

    fn create(allocator: Allocator, key: OwnedReviewIdentity, comment_id: bbr.review.CommentId) !*DeleteComment {
        const command = try allocator.create(DeleteComment);
        command.* = .{ .allocator = allocator, .identity = .init(key), .comment_id = comment_id };
        return command;
    }

    pub fn destroy(self: *DeleteComment) void {
        self.allocator.destroy(self);
    }
};

pub const OwnedCommand = union(enum) {
    load_session: LoadSession,
    enrich_file: EnrichFile,
    post_draft: *PostDraft,
    update_comment: *UpdateComment,
    delete_comment: *DeleteComment,
    wait_submission: WaitSubmission,
    check_recovery: CheckRecovery,
    find_duplicate: *PostDraft,
    list_pull_requests: ListPullRequests,
    copy_clipboard: *ClipboardCopy,
    external_edit: *ExternalEdit,

    pub fn deinit(self: *OwnedCommand) void {
        switch (self.*) {
            .post_draft, .find_duplicate => |command| command.destroy(),
            .update_comment => |command| command.destroy(),
            .delete_comment => |command| command.destroy(),
            .copy_clipboard => |command| command.destroy(),
            .external_edit => |command| command.destroy(),
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
        .update_comment => |value| value.command_id = command_id,
        .delete_comment => |value| value.command_id = command_id,
        .wait_submission => |*value| value.command_id = command_id,
        .check_recovery => |*value| value.command_id = command_id,
        .list_pull_requests => |*value| value.command_id = command_id,
        .copy_clipboard => |value| value.command_id = command_id,
        .external_edit => |value| value.command_id = command_id,
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

pub const ExternalEdit = struct {
    allocator: Allocator,
    command_id: CommandId = 0,
    session_epoch: SessionEpoch,
    max_bytes: usize,
    body: []u8,

    fn create(allocator: Allocator, session_epoch: SessionEpoch, max_bytes: usize, body: []const u8) !*ExternalEdit {
        const command = try allocator.create(ExternalEdit);
        errdefer allocator.destroy(command);
        command.* = .{
            .allocator = allocator,
            .session_epoch = session_epoch,
            .max_bytes = max_bytes,
            .body = try allocator.dupe(u8, body),
        };
        return command;
    }

    pub fn destroy(self: *ExternalEdit) void {
        const allocator = self.allocator;
        allocator.free(self.body);
        allocator.destroy(self);
    }
};

pub const ExternalEditOutcome = union(enum) {
    changed: []const u8,
    unchanged,
    cancelled,
    missing_editor,
    invalid_editor,
    too_large,
    invalid_utf8,
    contains_nul,
    failed,
    cleanup_failed: struct { body: []const u8, path: []const u8 },
    restoration_failed: []const u8,
};

pub const ExternalEditCompleted = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    command_id: CommandId,
    session_epoch: SessionEpoch,
    outcome: ExternalEditOutcome,

    pub fn create(allocator: Allocator, command_id: CommandId, session_epoch: SessionEpoch) !*ExternalEditCompleted {
        const completed = try allocator.create(ExternalEditCompleted);
        completed.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .command_id = command_id,
            .session_epoch = session_epoch,
            .outcome = .failed,
        };
        return completed;
    }

    pub fn destroy(self: *ExternalEditCompleted) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
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
    submission_tree: ?SubmissionTreeProjection,
    comment_edit_result: ?CommentEditResultProjection,
    comment_delete_result: ?CommentDeleteResultProjection,
    recovery: ?RecoveryNotice,
    unknown_resolution: ?UnknownResolutionProjection,
    reanchor: ?ReanchorProjection,
    delete_confirmation: ?DeleteConfirmationProjection,
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

pub const CommentEditResultProjection = struct {
    key: OwnedReviewIdentity,
    comment_id: bbr.review.CommentId,
    outcome: enum { updated, failed, outcome_unknown, reload_required },
};

pub const CommentDeleteResultProjection = struct {
    key: OwnedReviewIdentity,
    comment_id: bbr.review.CommentId,
    outcome: enum { deleted, failed, outcome_unknown, reload_required },
};

pub const ClipboardStatus = enum { copied, failed };

/// What a Composer save mutates instead of creating. Presentation carries the
/// typed identity end to end and never flattens both into one numeric id.
pub const MutationTarget = composer_mod.MutationTarget;

/// Why the ReviewCard under the cursor refuses a mutation. The Action stays
/// discoverable; this is the precise reason the reviewer is told.
pub const MutationRefusal = enum {
    /// The cursor is not on a ReviewCard at all.
    no_review_item,
    /// An active or recovered SubmissionRun froze this Draft's graph.
    submission_owns_draft,
    /// `outcome_unknown`: publication must be resolved before editing.
    outcome_unresolved,
    /// `submitting`: Bitbucket owns the next transition.
    submission_in_flight,
    /// Transient `posted`: Bitbucket, not this Draft, is now its home.
    already_published,
    /// The Session has no proven Authenticated Account UUID.
    authenticated_account_unknown,
    /// The Comment has no author UUID to compare.
    comment_author_unknown,
    /// The Authenticated Account did not author this Comment.
    comment_owned_by_other,
    /// A structural Deleted Comment has no authored body.
    comment_deleted,
    /// Submission or another published mutation owns the global write lane.
    remote_write_busy,
    /// Reconciliation failed after a write from this stale Session.
    authoritative_reload_required,
    /// Published mutation is not supported by this particular Action.
    published_comment,
    /// A Reply inherits its root's placement, so it has no Anchor of its own.
    reply_inherits_scope,
    /// A Review-level or File-level root; re-anchor never converts a scope.
    scope_not_inline,
    /// A Reply somewhere below this Draft is run-owned or immutable, so the
    /// complete cascade is refused rather than partially applied.
    descendant_locked,
};

pub const ActionAvailability = struct {
    remote: bool,
    has_review: bool = true,
    context: keymap_mod.InteractionContext = .diff,
    source: bool = true,
    selection: bool = true,
    /// null means the ReviewCard under the cursor is editable.
    edit_refusal: ?MutationRefusal = .no_review_item,
    /// null means the ReviewCard under the cursor — or, while re-anchor is
    /// armed, the Draft it retained — accepts a replacement Anchor.
    reanchor_refusal: ?MutationRefusal = .no_review_item,
    /// null means the ReviewCard under the cursor — and its complete Draft
    /// Reply-descendant closure — can be deleted.
    delete_refusal: ?MutationRefusal = .no_review_item,

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
            .toggle_select => self.selection,
            .edit_review_item => self.edit_refusal == null,
            .reanchor_review_item => self.reanchor_refusal == null,
            .delete_review_item => self.delete_refusal == null,
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

pub const SubmissionItemState = enum {
    queued,
    posting,
    waiting_to_retry,
    checking_publication,
    persisting,
    posted,
    failed,
    skipped,
    outcome_unknown,
};

pub const SubmissionItemProjection = struct {
    temp_id: bbr.review.TempId,
    parent: ?bbr.review.draft.Parent,
    depth: usize,
    body: []const u8,
    context: []const u8,
    state: SubmissionItemState,
    reason: ?bbr.bitbucket.ApiError = null,
    posted_comment_id: ?bbr.review.CommentId = null,
    blocking_ancestor: ?bbr.review.TempId = null,
    reply_descendants: usize = 0,
    post_attempts: u8 = 0,
    publication_checks: u8 = 0,
    retry: ?bbr.review.SubmissionRetryCheckpoint = null,
    retry_eligible: bool = false,
    repair_eligible: bool = false,
};

/// One Session-independent dependency-tree surface from authorization through
/// terminal inspection. The strings and rows borrow Presentation-owned state.
pub const SubmissionTreeProjection = struct {
    operation_id: bbr.review.OperationId,
    key: OwnedReviewIdentity,
    items: []const SubmissionItemProjection,
    selected: usize,
    completion: ?bbr.review.SubmissionCompletion,
    posted: usize,
    failed: usize,
    skipped: usize,
    outcome_unknown: usize,
    stale_repair: ?StaleRepairProjection = null,

    pub fn selectedItem(self: SubmissionTreeProjection) ?SubmissionItemProjection {
        if (self.selected >= self.items.len) return null;
        return self.items[self.selected];
    }
};

pub const StaleRepairProjection = struct {
    loaded_source_commit: []const u8,
    observed_source_commit: []const u8,
    reloaded: bool,
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
    footer: ?[]const u8 = null,
    pending_external_edit: bool = false,
};

pub const UnknownResolutionProjection = struct {
    temp_id: bbr.review.TempId,
    comment_id: []const u8,
};

pub const AnchorSide = enum { old, new };

/// The replacement Anchor the current source cursor or Selection names, as the
/// armed banner shows it. `path` borrows the published Session's Diff.
pub const AnchorCandidate = struct {
    path: []const u8,
    side: AnchorSide,
    top: u32,
    bottom: u32,
};

/// The armed half of the two-stage re-anchor interaction: which Draft is being
/// repaired, and what the source cursor currently proposes. `refusal` is why
/// the proposal is not acceptable yet; navigating changes it without ending
/// the interaction.
pub const ReanchorProjection = struct {
    temp_id: bbr.review.TempId,
    candidate: ?AnchorCandidate,
    refusal: ?ActionError,
};

/// The armed delete confirmation: which local Draft it names and the complete
/// Reply-descendant consequence the reviewer is being asked to accept.
pub const DeleteConfirmationProjection = struct {
    temp_id: bbr.review.TempId,
    comment_id: ?bbr.review.CommentId = null,
    descendant_count: usize,
    root_has_replies: bool = false,
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
    draft_owned_by_submission,
    draft_outcome_unresolved,
    draft_submission_in_flight,
    draft_already_published,
    authenticated_account_unknown,
    comment_author_unknown,
    comment_owned_by_other,
    comment_deleted,
    remote_write_busy,
    authoritative_reload_required,
    comment_edit_failed,
    comment_edit_launch_failed,
    comment_delete_failed,
    comment_delete_launch_failed,
    published_comment_edit_unsupported,
    no_review_item,
    draft_edit_conflict,
    draft_reply_has_no_anchor,
    draft_scope_not_inline,
    draft_descendant_locked,
    anchor_candidate_ambiguous,
    anchor_range_too_long,
    suggestion_anchor_not_new_side,
};

const BufferTransactionError = error{ BufferBuildFailed, OutOfMemory };
const SaveDraftError = BufferTransactionError || error{ PersistenceFailed, AnchorRangeTooLong, InvalidDraftScope };
const EditDraftError = SaveDraftError || error{ DraftEditConflict, DraftLocked };
const ReanchorDraftError = EditDraftError || error{ DraftNotAnchorable, InvalidAnchor };
const DeleteDraftError = EditDraftError;

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
                resolveRemoteScope(authored, session)
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
                .content_statuses = enrichment.content_statuses,
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
        new_draft.validate() catch |err| return err;
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
            .body = try bbr.review.storedBody(review_allocator, new_draft.kind, new_draft.body),
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

    /// Replace one Draft's body: stage the candidate graph and Buffer, persist
    /// through the transaction-shaped store, then publish. A failure anywhere
    /// leaves the previous Frame, graph, and ScopeProjection exactly as they
    /// were. `editable` is the reviewer-facing content; a Suggestion is stored
    /// re-fenced. Byte-identical content is a clean no-op: nothing is persisted
    /// and any failure evidence survives.
    fn editDraftBody(
        self: *Published,
        store: bbr.review.PendingReviewStore,
        preferences: Preferences,
        temp_id: bbr.review.TempId,
        editable: []const u8,
    ) EditDraftError!void {
        const draft = self.review.get(temp_id) orelse return error.DraftEditConflict;
        const review_allocator = self.review_arena.allocator();
        const candidate_body = try bbr.review.storedBody(review_allocator, draft.kind, editable);
        if (std.mem.eql(u8, draft.body, candidate_body)) return;

        const previous_body = draft.body;
        const previous_state = draft.state;
        draft.body = candidate_body;
        // A real body change is a new attempt, so a confirmed failure resets.
        if (draft.state == .failed) draft.state = .draft;
        errdefer {
            const rollback = self.review.get(temp_id).?;
            rollback.body = previous_body;
            rollback.state = previous_state;
        }

        var staged = try self.prepareBuffer(preferences, self.expanded_disclosures.items, self.isolated_file, self.geometry);
        defer staged.deinit();
        store.editDraftBody(self.key.storeKey(), .{
            .temp_id = temp_id,
            .expected_kind = draft.kind,
            .expected_parent = draft.parent,
            .body = candidate_body,
        }) catch |err| return switch (err) {
            error.DraftLocked, error.DraftNotEditable => error.DraftLocked,
            error.DraftEditConflict, error.DraftNotFound => error.DraftEditConflict,
            else => error.PersistenceFailed,
        };
        staged.publish();
    }

    /// Replace one inline root Draft's Anchor: stage the candidate graph, its
    /// `current` ScopeProjection, and the Buffer, persist through the
    /// transaction-shaped store, then publish. Body, kind, TempId, and the
    /// whole Reply subtree survive; an identical Anchor is a clean no-op that
    /// persists nothing and retains any failure evidence. `snapshot` is the
    /// LocalReview replacement evidence, null for a RemoteReview.
    fn reanchorDraft(
        self: *Published,
        store: bbr.review.PendingReviewStore,
        preferences: Preferences,
        temp_id: bbr.review.TempId,
        anchor: bbr.review.Anchor,
        snapshot: ?bbr.review.AnchorSnapshot,
    ) ReanchorDraftError!void {
        const draft = self.review.get(temp_id) orelse return error.DraftEditConflict;
        if (draft.parent != null or draft.effectiveScope() != .@"inline") return error.DraftNotAnchorable;
        if (bbr.review.Anchor.eql(draft.effectiveScope().@"inline", anchor)) return;

        const review_allocator = self.review_arena.allocator();
        var owned = anchor;
        owned.path = try review_allocator.dupe(u8, anchor.path);
        if (anchor.commit) |commit| owned.commit = try review_allocator.dupe(u8, commit);
        const owned_snapshot: ?bbr.review.AnchorSnapshot = if (snapshot) |captured| .{
            .text = try review_allocator.dupe(u8, captured.text),
            .selection_start = captured.selection_start,
            .selection_len = captured.selection_len,
        } else null;

        const previous_scope = draft.scope;
        const previous_anchor = draft.anchor;
        const previous_snapshot = draft.snapshot;
        const previous_state = draft.state;
        draft.scope = .{ .@"inline" = owned };
        draft.anchor = owned;
        draft.snapshot = owned_snapshot;
        // A real Anchor change is a new attempt, so a confirmed failure resets.
        if (draft.state == .failed) draft.state = .draft;

        // The repaired root was placed against this Session, so its projected
        // scope is `current`; every Reply reuses this same entry.
        var projection_index: ?usize = null;
        var previous_resolution: bbr.review.ScopeResolution = undefined;
        for (self.scope_projection.items, 0..) |entry, index| if (entry.temp_id == temp_id) {
            projection_index = index;
            previous_resolution = entry.resolution;
            break;
        };
        if (projection_index) |index| self.scope_projection.items[index].resolution = .{
            .resolved = .{ .state = .current, .scope = .{ .@"inline" = owned } },
        };
        errdefer {
            const rollback = self.review.get(temp_id).?;
            rollback.scope = previous_scope;
            rollback.anchor = previous_anchor;
            rollback.snapshot = previous_snapshot;
            rollback.state = previous_state;
            if (projection_index) |index| self.scope_projection.items[index].resolution = previous_resolution;
        }

        var staged = try self.prepareBuffer(preferences, self.expanded_disclosures.items, self.isolated_file, self.geometry);
        defer staged.deinit();
        store.reanchorDraft(self.key.storeKey(), .{
            .temp_id = temp_id,
            .expected_kind = draft.kind,
            .anchor = owned,
            .snapshot = owned_snapshot,
        }) catch |err| return switch (err) {
            error.DraftLocked, error.DraftNotEditable => error.DraftLocked,
            error.DraftEditConflict, error.DraftNotFound => error.DraftEditConflict,
            error.DraftNotAnchorable => error.DraftNotAnchorable,
            error.InvalidAnchor => error.InvalidAnchor,
            else => error.PersistenceFailed,
        };
        staged.publish();
    }

    /// Delete one Draft and its complete confirmed Reply-descendant closure:
    /// stage the candidate graph and ScopeProjection by compacting both in
    /// place, stage the Buffer, persist through the transaction-shaped store,
    /// then publish. Any failure restores the exact previous graph, projection,
    /// and Frame — a partial cascade is never observable. `next_id` deliberately
    /// does not walk back, so a deleted TempId is never handed out again.
    fn deleteDraftSubtree(
        self: *Published,
        store: bbr.review.PendingReviewStore,
        preferences: Preferences,
        temp_id: bbr.review.TempId,
        cascade: []const bbr.review.TempId,
    ) DeleteDraftError!void {
        const draft = self.review.getConst(temp_id) orelse return error.DraftEditConflict;
        const expected_parent = draft.parent;

        const saved_drafts = try self.allocator.dupe(bbr.review.Draft, self.review.drafts.items);
        defer self.allocator.free(saved_drafts);
        const saved_projection = try self.allocator.dupe(bbr.review.ScopeProjectionEntry, self.scope_projection.items);
        defer self.allocator.free(saved_projection);

        var kept: usize = 0;
        for (self.review.drafts.items) |candidate| {
            if (bbr.review.containsTempId(cascade, candidate.local_id)) continue;
            self.review.drafts.items[kept] = candidate;
            kept += 1;
        }
        self.review.drafts.shrinkRetainingCapacity(kept);
        var kept_projection: usize = 0;
        for (self.scope_projection.items) |entry| {
            if (bbr.review.containsTempId(cascade, entry.temp_id)) continue;
            self.scope_projection.items[kept_projection] = entry;
            kept_projection += 1;
        }
        self.scope_projection.shrinkRetainingCapacity(kept_projection);
        errdefer {
            self.review.drafts.clearRetainingCapacity();
            self.review.drafts.appendSliceAssumeCapacity(saved_drafts);
            self.scope_projection.clearRetainingCapacity();
            self.scope_projection.appendSliceAssumeCapacity(saved_projection);
        }

        var staged = try self.prepareBuffer(preferences, self.expanded_disclosures.items, self.isolated_file, self.geometry);
        defer staged.deinit();
        store.deleteDraftSubtree(self.key.storeKey(), .{
            .root_temp_id = temp_id,
            .expected_parent = expected_parent,
            .cascade = cascade,
        }) catch |err| return switch (err) {
            error.DraftLocked, error.DraftNotEditable => error.DraftLocked,
            error.DraftEditConflict, error.DraftNotFound, error.DraftCascadeConflict => error.DraftEditConflict,
            else => error.PersistenceFailed,
        };
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
                .content_statuses = enrichment.content_statuses,
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

fn resolveRemoteScope(authored: bbr.review.CommentScope, session: *const Session) bbr.review.ScopeResolution {
    return switch (authored) {
        .review => .{ .resolved = .{ .state = .current, .scope = .review } },
        .file => |file| .{ .resolved = .{
            .state = if (scopeFileExists(session.diff, file.path, false)) .current else .outdated,
            .scope = authored,
        } },
        .@"inline" => |anchor| .{ .resolved = .{
            .state = if (scopeAnchorExists(session.diff, anchor)) .current else .outdated,
            .scope = authored,
        } },
    };
}

fn scopeFileExists(diff: bbr.diff.Diff, path: []const u8, old_side: bool) bool {
    for (diff.files) |file| {
        const candidate = if (old_side) file.old_path else file.new_path;
        if (std.mem.eql(u8, candidate, path) and !std.mem.eql(u8, candidate, "/dev/null")) return true;
    }
    return false;
}

fn scopeAnchorExists(diff: bbr.diff.Diff, anchor: bbr.review.Anchor) bool {
    const old_side = anchor.to == null;
    const top = anchor.top() orelse return false;
    const bottom = anchor.line() orelse return false;
    for (diff.files) |file| {
        const path = if (old_side) file.old_path else file.new_path;
        if (!std.mem.eql(u8, path, anchor.path)) continue;
        for (file.hunks) |hunk| {
            var wanted = top;
            for (hunk.lines) |line| {
                const number = if (old_side) line.old_no else line.new_no;
                if (number == wanted) {
                    if (wanted == bottom) return true;
                    wanted += 1;
                } else if (wanted > top and number != null and number.? > wanted) break;
            }
        }
    }
    return false;
}

/// Stage one of re-anchor: the retained typed identity. It deliberately carries
/// no candidate — the candidate is whatever the source cursor names right now,
/// so navigating re-reads it instead of accumulating interaction state.
const ReanchorCapture = struct {
    key: OwnedReviewIdentity,
    temp_id: bbr.review.TempId,
};

/// The armed delete confirmation. It retains the typed identity and the exact
/// consequence the reviewer was shown, so a graph that changed underneath the
/// overlay is refused instead of silently deleting a different set.
const DeleteConfirmation = struct {
    key: OwnedReviewIdentity,
    target: MutationTarget,
    descendant_count: usize,
    root_has_replies: bool = false,
};

/// Where the cursor goes once a deleted subtree's rows are gone: the identity
/// of the first surviving row after it, else the last surviving row before it.
const SurvivingRow = union(enum) {
    draft: bbr.review.TempId,
    comment: bbr.review.CommentId,
    line: *const bbr.diff.Line,
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

const StaleRepairGate = struct {
    key: OwnedReviewIdentity,
    loaded_source_commit: BoundedText(64),
    observed_source_commit: BoundedText(64),
    reloaded: bool = false,
};

const Replacement = struct {
    intent: LoadIntent,
    key: OwnedReviewIdentity,
    cause: SessionLoadCause,
};

const DurableCommentEdit = struct {
    allocator: Allocator,
    key: OwnedReviewIdentity,
    comment_id: bbr.review.CommentId,
    initiating_epoch: SessionEpoch,
    body: []u8,
    outcome: ?CommentEditOutcome = null,

    fn destroy(self: *DurableCommentEdit) void {
        const allocator = self.allocator;
        allocator.free(self.body);
        allocator.destroy(self);
    }
};

const DurableCommentDelete = struct {
    allocator: Allocator,
    key: OwnedReviewIdentity,
    comment_id: bbr.review.CommentId,
    initiating_epoch: SessionEpoch,
    outcome: ?CommentDeleteOutcome = null,

    fn destroy(self: *DurableCommentDelete) void {
        self.allocator.destroy(self);
    }
};

const IssuedEnrichment = struct {
    work_id: WorkId,
    session_epoch: SessionEpoch,
    file_index: usize,
};

const SubmissionPhase = enum {
    post_queued,
    awaiting_post,
    post_retry_paused,
    wait_queued,
    awaiting_wait,
    wait_retry_paused,
    admission_paused,
    persistence_paused,
    recovery_check_queued,
    awaiting_recovery_check,
    recovery_check_paused,
    recovery_source_changed,
    duplicate_queued,
    awaiting_duplicate,
    duplicate_check_paused,
    duplicate_persistence_paused,
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
    phase: SubmissionPhase = .post_queued,
    pending_admission: ?PendingAdmission = null,
    pending_persistence: ?PendingPersistence = null,
    pending_wait_retry: ?WaitSubmission = null,
    posted_any: bool = false,
    recovery_source_commit: ?BoundedText(64) = null,
    observed_source_commit: ?BoundedText(64) = null,
    source_changed: bool = false,
    recovered: bool = false,
    pending_duplicate: ?struct { outcome: DuplicateCheckOutcome, checkpoint_done: bool = false } = null,
    policy_check: bool = false,

    const Started = struct {
        durable: *DurableSubmission,
        tree: *SubmissionTree,
        command: union(enum) { post: *PostDraft, wait: WaitSubmission },
    };

    const Recovered = struct {
        durable: *DurableSubmission,
        tree: *SubmissionTree,
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
        retry_checkpoint: ?bbr.review.SubmissionRetryCheckpoint = null,
        retry_checkpoint_done: bool = false,
        checkpoint_done: bool = false,
    };

    const PendingAdmission = union(enum) {
        post: PostDraftCompleted,
        wait: WaitSubmission,
    };

    const AfterPost = union(enum) {
        next: struct { command: *PostDraft, transition: PersistedTransition },
        check: *PostDraft,
        wait: WaitSubmission,
        finished: struct { result: SubmissionResultProjection, transition: PersistedTransition },
    };

    fn create(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        key: OwnedReviewIdentity,
        lock: bbr.review.SubmissionLockGuard,
        frozen_items: ?[]const bbr.review.SubmissionRunItem,
        selected_root: ?bbr.review.TempId,
    ) !*DurableSubmission {
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
        durable.machine = if (frozen_items) |items|
            try bbr.review.Submission.initFrozen(durable.arena.allocator(), &durable.review, items)
        else if (selected_root) |root|
            try bbr.review.Submission.initSubtree(durable.arena.allocator(), &durable.review, root)
        else
            try bbr.review.Submission.init(durable.arena.allocator(), &durable.review);
        durable.phase = .post_queued;
        durable.pending_admission = null;
        durable.pending_persistence = null;
        durable.pending_wait_retry = null;
        durable.posted_any = false;
        durable.recovery_source_commit = null;
        durable.observed_source_commit = null;
        durable.source_changed = false;
        durable.recovered = false;
        durable.pending_duplicate = null;
        durable.policy_check = false;
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
        selected_root: ?bbr.review.TempId,
    ) !?Started {
        const durable = try create(allocator, store, key, lock, null, selected_root);
        errdefer durable.destroy();
        const post = switch (durable.machine.advance()) {
            .post => |value| value,
            .done => {
                durable.destroy();
                return null;
            },
            .wait, .check, .aborted => unreachable,
        };
        const draft = durable.review.getConst(post.temp_id) orelse return error.DraftNotFound;
        const command = try PostDraft.create(allocator, durable.key, draft.*, post);
        errdefer command.destroy();
        const remaining = durable.machine.order[durable.machine.idx..];
        const items = try durable.arena.allocator().alloc(bbr.review.SubmissionRunItem, remaining.len);
        for (remaining, items) |temp_id, *item| {
            const participant = durable.review.getConst(temp_id) orelse return error.DraftNotFound;
            item.* = .{ .temp_id = temp_id, .parent = participant.parent };
        }
        const tree = try SubmissionTree.create(allocator, durable, remaining);
        errdefer tree.destroy();
        const operation_id = try store.beginSubmission(durable.key.storeKey(), source_commit, items);
        durable.operation_id = operation_id;
        tree.operation_id = operation_id;
        durable.current_temp_id = post.temp_id;
        command.operation_id = operation_id;
        if (try store.activeSubmission(durable.arena.allocator())) |run| if (run.retry) |retry| {
            durable.machine.restoreRetry(retry);
            command.destroy();
            const wait = durable.machine.advance().wait;
            durable.phase = .wait_queued;
            return .{ .durable = durable, .tree = tree, .command = .{ .wait = .{
                .operation_id = operation_id,
                .identity = .init(durable.key),
                .temp_id = wait.temp_id,
                .ms = wait.ms,
                .checkpoint = wait.checkpoint,
            } } };
        };
        return .{ .durable = durable, .tree = tree, .command = .{ .post = command } };
    }

    fn recover(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        run: bbr.review.ActiveSubmissionRun,
        key: OwnedReviewIdentity,
        lock: bbr.review.SubmissionLockGuard,
    ) !Recovered {
        const durable = try create(allocator, store, key, lock, run.items, null);
        errdefer durable.destroy();
        if (run.retry) |retry| {
            durable.machine.restoreRetry(retry);
        } else {
            // Intent was durable before the process disappeared. With no
            // response checkpoint, publication is ambiguous and recovery must
            // read before it can issue another POST.
            durable.machine.attempts[durable.machine.idx] = 1;
            durable.machine.ambiguous_last[durable.machine.idx] = true;
        }
        const current_temp_id = switch (durable.machine.advance()) {
            .post, .check => |value| value.temp_id,
            .wait => |wait| blk: {
                durable.pending_wait_retry = .{
                    .operation_id = run.operation_id,
                    .identity = .init(key),
                    .temp_id = wait.temp_id,
                    .ms = wait.ms,
                    .checkpoint = wait.checkpoint,
                };
                break :blk wait.temp_id;
            },
            else => return error.InvalidRecoveryState,
        };
        if (current_temp_id != run.current_temp_id.?) return error.InvalidRecoveryState;
        durable.operation_id = run.operation_id;
        durable.current_temp_id = run.current_temp_id;
        durable.recovery_source_commit = try BoundedText(64).init(run.source_commit);
        durable.recovered = true;
        durable.phase = .recovery_check_queued;
        return .{ .durable = durable, .tree = try SubmissionTree.create(allocator, durable, durable.machine.order) };
    }

    fn acceptPost(
        self: *DurableSubmission,
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        completed: PostDraftCompleted,
    ) !AfterPost {
        self.machine.report(completed.outcome, completed.retry_after_ms);
        const terminal_retry: ?bbr.review.SubmissionRetryCheckpoint = if (self.machine.terminal_server_delay_ms) |server_delay| blk: {
            const reason: bbr.review.SubmissionRetryReason = switch (completed.outcome.rejected) {
                error.RateLimited => .rate_limited,
                error.ServerError => .server_error,
                else => unreachable,
            };
            break :blk .{
                .phase = .post,
                .attempt = bbr.review.submission.max_attempts,
                .reason = reason,
                .local_delay_ms = 0,
                .server_delay_ms = server_delay,
                .effective_delay_ms = server_delay,
                .pending_wait = false,
            };
        } else null;
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
                    .retry_checkpoint = terminal_retry,
                };
            },
            .done => {
                const completion: bbr.review.SubmissionCompletion = if (self.machine.isClean()) .clean else .partial;
                self.pending_persistence = .{
                    .transition = .{ .temp_id = completed.temp_id, .state = outcome.draftState() },
                    .outcome = outcome,
                    .completion = completion,
                    .retry_checkpoint = terminal_retry,
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
                const command: WaitSubmission = .{
                    .operation_id = self.operation_id,
                    .identity = .init(self.key),
                    .temp_id = wait.temp_id,
                    .ms = wait.ms,
                    .checkpoint = wait.checkpoint,
                };
                self.pending_wait_retry = command;
                self.phase = .wait_retry_paused;
                try store.checkpointSubmissionRetry(self.operation_id, self.key.storeKey(), wait.temp_id, wait.checkpoint);
                self.pending_wait_retry = null;
                self.phase = .wait_queued;
                return .{ .wait = command };
            },
            .check => {
                self.phase = .duplicate_queued;
                return .{ .check = try self.materializeDuplicateCheck(allocator) };
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

        if (!pending.retry_checkpoint_done) if (pending.retry_checkpoint) |checkpoint| {
            try store.checkpointSubmissionRetry(
                self.operation_id,
                self.key.storeKey(),
                pending.transition.temp_id,
                checkpoint,
            );
            pending.retry_checkpoint_done = true;
        };

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

    fn completeWait(self: *DurableSubmission, allocator: Allocator, store: bbr.review.PendingReviewStore, wait: WaitSubmission) !*PostDraft {
        if (self.operation_id != wait.operation_id or self.current_temp_id != wait.temp_id or self.phase != .awaiting_wait)
            return error.StaleSubmissionWait;
        if (wait.checkpoint) |checkpoint| {
            var completed = checkpoint;
            completed.pending_wait = false;
            try store.checkpointSubmissionRetry(self.operation_id, self.key.storeKey(), wait.temp_id, completed);
        }
        if (self.machine.must_wait) self.machine.completeWait();
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
        const step = self.machine.advance();
        const post = switch (step) {
            .post, .check => |value| value,
            else => return error.InvalidRecoveryState,
        };
        if (self.current_temp_id != post.temp_id) return error.InvalidRecoveryState;
        const draft = self.review.getConst(post.temp_id) orelse return error.DraftNotFound;
        const command = try PostDraft.create(allocator, self.key, draft.*, post);
        command.operation_id = self.operation_id;
        command.dedupe = true;
        self.policy_check = step == .check and !self.source_changed;
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

const SubmissionTree = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    key: OwnedReviewIdentity,
    operation_id: bbr.review.OperationId,
    items: std.ArrayList(SubmissionItemProjection) = .empty,
    selected: usize = 0,
    completion: ?bbr.review.SubmissionCompletion = null,
    stale_repair: ?StaleRepairProjection = null,

    fn create(allocator: Allocator, durable: *const DurableSubmission, order: []const bbr.review.TempId) !*SubmissionTree {
        const tree = try allocator.create(SubmissionTree);
        errdefer allocator.destroy(tree);
        tree.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .key = durable.key,
            .operation_id = durable.operation_id,
        };
        errdefer tree.arena.deinit();
        const arena = tree.arena.allocator();
        try tree.items.ensureTotalCapacity(arena, order.len);
        for (order) |temp_id| {
            const draft = durable.review.getConst(temp_id) orelse return error.DraftNotFound;
            tree.items.appendAssumeCapacity(.{
                .temp_id = temp_id,
                .parent = draft.parent,
                .depth = tree.depth(draft.parent),
                .body = try arena.dupe(u8, draft.body),
                .context = try submissionContext(arena, draft.*),
                .state = .queued,
                .reply_descendants = submissionDescendantCount(durable.review.drafts.items, temp_id, order),
            });
        }
        tree.sync(durable);
        return tree;
    }

    fn createPersisted(
        allocator: Allocator,
        key: OwnedReviewIdentity,
        operation_id: bbr.review.OperationId,
        review: *const bbr.review.PendingReview,
        run_items: []const bbr.review.SubmissionRunItem,
        completion: bbr.review.SubmissionCompletion,
    ) !*SubmissionTree {
        const tree = try allocator.create(SubmissionTree);
        errdefer allocator.destroy(tree);
        tree.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .key = key,
            .operation_id = operation_id,
            .completion = completion,
        };
        errdefer tree.arena.deinit();
        const arena = tree.arena.allocator();
        const order = try arena.alloc(bbr.review.TempId, run_items.len);
        for (run_items, order) |run_item, *temp_id| temp_id.* = run_item.temp_id;
        try tree.items.ensureTotalCapacity(arena, order.len);
        for (order) |temp_id| {
            const draft = review.getConst(temp_id) orelse return error.DraftNotFound;
            const state: SubmissionItemState = switch (draft.state) {
                .draft => .queued,
                .submitting, .outcome_unknown => .outcome_unknown,
                .posted => .posted,
                .failed => .failed,
            };
            tree.items.appendAssumeCapacity(.{
                .temp_id = temp_id,
                .parent = draft.parent,
                .depth = tree.depth(draft.parent),
                .body = try arena.dupe(u8, draft.body),
                .context = try submissionContext(arena, draft.*),
                .state = state,
                .reason = if (draft.state == .failed) draft.state.failed else null,
                .posted_comment_id = if (draft.state == .posted) draft.state.posted else null,
                .reply_descendants = submissionDescendantCount(review.drafts.items, temp_id, order),
                .retry_eligible = state == .failed,
                .repair_eligible = state == .failed,
            });
        }
        for (tree.items.items) |*item| {
            if (item.state != .queued) continue;
            if (tree.nearestBlockingAncestor(item.parent)) |ancestor| {
                item.state = .skipped;
                item.blocking_ancestor = ancestor;
                if (tree.findConst(ancestor)) |blocked| item.reason = blocked.reason;
            }
        }
        return tree;
    }

    fn destroy(self: *SubmissionTree) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn depth(self: *const SubmissionTree, parent: ?bbr.review.draft.Parent) usize {
        var current = parent;
        var result: usize = 0;
        while (current) |value| {
            const parent_id = switch (value) {
                .comment => break,
                .draft => |id| id,
            };
            var found: ?bbr.review.draft.Parent = null;
            for (self.items.items) |item| if (item.temp_id == parent_id) {
                result += 1;
                found = item.parent;
                break;
            };
            current = found;
            if (found == null) break;
        }
        return result;
    }

    fn sync(self: *SubmissionTree, durable: *const DurableSubmission) void {
        for (self.items.items) |*item| {
            const machine_index = submissionOrderIndex(durable.machine.order, item.temp_id) orelse continue;
            item.reason = null;
            item.posted_comment_id = null;
            item.blocking_ancestor = null;
            item.post_attempts = durable.machine.attempts[machine_index];
            item.publication_checks = durable.machine.check_attempts[machine_index];
            item.retry = null;
            if (durable.machine.results[machine_index]) |result| {
                item.state = switch (result.status) {
                    .posted => .posted,
                    .failed => .failed,
                    .skipped => .skipped,
                    .outcome_unknown => .outcome_unknown,
                };
                item.reason = result.reason;
                item.posted_comment_id = result.id;
                if (result.status == .failed) item.retry_eligible = true;
                if (result.status == .failed) item.repair_eligible = true;
                continue;
            }
            item.state = if (durable.current_temp_id != item.temp_id) .queued else submissionProgressState(durable.phase);
            if (item.state == .posting) item.post_attempts += 1;
            if (durable.current_temp_id == item.temp_id and (durable.machine.must_wait or durable.pending_wait_retry != null))
                item.retry = durable.machine.retry_checkpoint;
        }
        for (self.items.items) |*item| {
            if (item.state == .skipped) item.blocking_ancestor = self.nearestBlockingAncestor(item.parent);
        }
    }

    fn finish(self: *SubmissionTree, durable: *const DurableSubmission, completion: bbr.review.SubmissionCompletion) void {
        self.sync(durable);
        if (completion == .aborted) {
            for (self.items.items) |*item| if (item.state != .posted) {
                item.state = .queued;
                if (durable.current_temp_id == item.temp_id) item.reason = durable.machine.aborted_reason;
            };
        }
        if (durable.machine.terminal_server_delay_ms) |server_delay| {
            for (self.items.items) |*item| {
                if (item.state == .failed and item.post_attempts == bbr.review.submission.max_attempts) {
                    item.retry = .{
                        .phase = .post,
                        .attempt = bbr.review.submission.max_attempts,
                        .reason = switch (item.reason orelse error.ServerError) {
                            error.RateLimited => .rate_limited,
                            else => .server_error,
                        },
                        .local_delay_ms = 0,
                        .server_delay_ms = server_delay,
                        .effective_delay_ms = server_delay,
                        .pending_wait = false,
                    };
                    break;
                }
            }
        }
        self.completion = completion;
    }

    fn nearestBlockingAncestor(self: *const SubmissionTree, parent: ?bbr.review.draft.Parent) ?bbr.review.TempId {
        var current = parent;
        while (current) |value| {
            const temp_id = switch (value) {
                .comment => return null,
                .draft => |id| id,
            };
            const item = self.findConst(temp_id) orelse return null;
            if (item.state == .failed or item.state == .outcome_unknown) return temp_id;
            if (item.blocking_ancestor) |blocked| return blocked;
            current = item.parent;
        }
        return null;
    }

    fn find(self: *SubmissionTree, temp_id: bbr.review.TempId) ?*SubmissionItemProjection {
        for (self.items.items) |*item| if (item.temp_id == temp_id) return item;
        return null;
    }

    fn findConst(self: *const SubmissionTree, temp_id: bbr.review.TempId) ?*const SubmissionItemProjection {
        for (self.items.items) |*item| if (item.temp_id == temp_id) return item;
        return null;
    }

    fn move(self: *SubmissionTree, delta: isize) void {
        if (self.items.items.len == 0) return;
        if (delta < 0) self.selected -|= 1 else self.selected = @min(self.selected + 1, self.items.items.len - 1);
    }

    fn selectedItem(self: *SubmissionTree) ?*SubmissionItemProjection {
        if (self.selected >= self.items.items.len) return null;
        return &self.items.items[self.selected];
    }

    /// Re-read authored fields after a terminal repair. The tree keeps its
    /// logical TempId selection, removes a confirmed deleted subtree, and marks
    /// a repaired failed root queued for a fresh selected-subtree run.
    fn refresh(self: *SubmissionTree, review: *const bbr.review.PendingReview) void {
        const selected_temp_id = if (self.selectedItem()) |item| item.temp_id else null;
        var index: usize = 0;
        while (index < self.items.items.len) {
            const item = &self.items.items[index];
            const draft = review.getConst(item.temp_id) orelse {
                _ = self.items.orderedRemove(index);
                continue;
            };
            const arena = self.arena.allocator();
            item.body = arena.dupe(u8, draft.body) catch item.body;
            item.context = submissionContext(arena, draft.*) catch item.context;
            switch (draft.state) {
                .failed => |reason| {
                    item.state = .failed;
                    item.reason = reason;
                    item.retry_eligible = true;
                    item.repair_eligible = true;
                },
                .draft => if (item.retry_eligible) {
                    item.state = .queued;
                    item.reason = null;
                },
                .posted => |comment_id| {
                    item.state = .posted;
                    item.posted_comment_id = comment_id;
                    item.retry_eligible = false;
                    item.repair_eligible = false;
                },
                .outcome_unknown => {
                    item.state = .outcome_unknown;
                    item.retry_eligible = false;
                    item.repair_eligible = false;
                },
                .submitting => {},
            }
            index += 1;
        }
        self.selected = 0;
        if (selected_temp_id) |temp_id| for (self.items.items, 0..) |item, item_index| {
            if (item.temp_id == temp_id) {
                self.selected = item_index;
                break;
            }
        };
        if (self.items.items.len > 0) self.selected = @min(self.selected, self.items.items.len - 1);
    }

    fn projection(self: *const SubmissionTree) SubmissionTreeProjection {
        var posted: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;
        var outcome_unknown: usize = 0;
        for (self.items.items) |item| switch (item.state) {
            .posted => posted += 1,
            .failed => failed += 1,
            .skipped => skipped += 1,
            .outcome_unknown => outcome_unknown += 1,
            else => {},
        };
        return .{
            .operation_id = self.operation_id,
            .key = self.key,
            .items = self.items.items,
            .selected = self.selected,
            .completion = self.completion,
            .posted = posted,
            .failed = failed,
            .skipped = skipped,
            .outcome_unknown = outcome_unknown,
            .stale_repair = self.stale_repair,
        };
    }
};

fn submissionOrderIndex(order: []const bbr.review.TempId, temp_id: bbr.review.TempId) ?usize {
    for (order, 0..) |candidate, index| if (candidate == temp_id) return index;
    return null;
}

fn submissionProgressState(phase: SubmissionPhase) SubmissionItemState {
    return switch (phase) {
        .post_queued, .post_retry_paused => .queued,
        .awaiting_post => .posting,
        .wait_queued, .awaiting_wait, .wait_retry_paused => .waiting_to_retry,
        .recovery_check_queued,
        .awaiting_recovery_check,
        .recovery_check_paused,
        .recovery_source_changed,
        .duplicate_queued,
        .awaiting_duplicate,
        .duplicate_check_paused,
        => .checking_publication,
        .admission_paused, .persistence_paused, .duplicate_persistence_paused => .persisting,
    };
}

fn submissionDescendantCount(drafts: []const bbr.review.Draft, root: bbr.review.TempId, order: []const bbr.review.TempId) usize {
    var count: usize = 0;
    for (order) |temp_id| if (temp_id != root and bbr.review.descendsFrom(drafts, root, temp_id)) {
        count += 1;
    };
    return count;
}

fn submissionContext(allocator: Allocator, draft: bbr.review.Draft) ![]const u8 {
    if (draft.parent) |parent| return switch (parent) {
        .draft => |temp_id| std.fmt.allocPrint(allocator, "Reply to Draft #{d}", .{temp_id}),
        .comment => |comment_id| std.fmt.allocPrint(allocator, "Reply to Comment {d}", .{comment_id}),
    };
    return switch (draft.effectiveScope()) {
        .review => allocator.dupe(u8, "Review scope"),
        .file => |file| std.fmt.allocPrint(allocator, "File {s}", .{file.path}),
        .@"inline" => |anchor| std.fmt.allocPrint(allocator, "Inline {s}:{d}", .{ anchor.path, anchor.line() orelse 0 }),
    };
}

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
    submission_tree: ?*SubmissionTree = null,
    durable_comment_edit: ?*DurableCommentEdit = null,
    durable_comment_delete: ?*DurableCommentDelete = null,
    authenticated_account_uuid: ?BoundedText(256) = null,
    reload_required_epoch: ?SessionEpoch = null,
    comment_edit_result: ?CommentEditResultProjection = null,
    comment_delete_result: ?CommentDeleteResultProjection = null,
    submission_result: ?SubmissionResultProjection = null,
    stale_repair: ?StaleRepairGate = null,
    recovery: ?RecoveryNotice = null,
    /// The recovered run's frozen participants, read only while `recovery` is
    /// set. They make a recovered run's ownership of a Draft visible before the
    /// store refuses the mutation.
    recovery_participants: std.ArrayList(bbr.review.TempId) = .empty,
    unknown_resolution: ?UnknownResolutionEditor = null,
    /// The armed first stage of re-anchor: the Draft whose Anchor a later
    /// source cursor or Selection will replace.
    reanchor: ?ReanchorCapture = null,
    /// The armed delete confirmation, if any. It captures input like any other
    /// Overlay and survives a refusal so the reviewer can retry.
    delete_confirmation: ?DeleteConfirmation = null,
    shutdown_requested: bool = false,
    replacement_error: ?ReplacementError = null,
    action_error: ?ActionError = null,
    fatal_error: ?FatalError = null,
    clipboard_status: ?ClipboardStatus = null,
    external_edit_pending: ?SessionEpoch = null,
    composer_footer: std.ArrayList(u8) = .empty,
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
            if (initial.session.authenticated_account_uuid) |uuid|
                self.authenticated_account_uuid = BoundedText(256).init(uuid) catch null;
            if (initial.session.authenticated_account_unauthorized) self.authenticated_account_uuid = null;
        }
        self.discoverRecovery();
        return self;
    }

    pub fn deinit(self: *Presentation) void {
        for (self.commands.items) |*command| command.deinit();
        if (self.durable_submission) |durable| durable.destroy();
        if (self.submission_tree) |tree| tree.destroy();
        if (self.durable_comment_edit) |edit| edit.destroy();
        if (self.durable_comment_delete) |delete| delete.destroy();
        if (self.picker) |*picker| picker.deinit();
        if (self.file_finder) |*finder| finder.deinit();
        if (self.picker_summaries) |summaries| summaries.destroy();
        if (self.published) |published| published.destroy();
        self.commands.deinit(self.allocator);
        self.issued_commands.deinit(self.allocator);
        self.issued_enrichments.deinit(self.allocator);
        self.recovery_participants.deinit(self.allocator);
        self.composer_footer.deinit(self.allocator);
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
            .reanchor => |reanchor_input| self.applyReanchorInput(reanchor_input),
            .delete_confirmation => |confirmation_input| self.applyDeleteConfirmationInput(confirmation_input),
            .ensure_focused_enrichment => try self.ensureFocusedEnrichment(),
            .file_enrichment_completed => |completed| self.acceptFileEnrichment(completed),
            .post_draft_completed => |completed| self.acceptPostDraft(completed),
            .post_draft_launch_failed => |failed| self.acceptPostDraftLaunchFailure(failed),
            .comment_edit_completed => |completed| self.acceptCommentEdit(completed),
            .comment_edit_launch_failed => |failed| self.acceptCommentEditLaunchFailure(failed),
            .comment_delete_completed => |completed| self.acceptCommentDelete(completed),
            .comment_delete_launch_failed => |failed| self.acceptCommentDeleteLaunchFailure(failed),
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
            .external_edit_completed => |completed| self.acceptExternalEdit(completed),
            .dismiss_submission_result => self.dismissSubmissionTree(),
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
            .update_comment, .delete_comment => {},
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
            .external_edit => {},
        }
        if (self.durable_submission) |durable| self.syncSubmissionTree(durable);
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
            .submission_tree = if (self.submission_tree) |tree| blk: {
                if (self.submissionRepairInteractionActive()) break :blk null;
                break :blk tree.projection();
            } else null,
            .comment_edit_result = self.comment_edit_result,
            .comment_delete_result = self.comment_delete_result,
            .recovery = self.recovery,
            .unknown_resolution = if (self.unknown_resolution) |*editor| .{
                .temp_id = editor.temp_id,
                .comment_id = editor.text(),
            } else null,
            .reanchor = self.reanchorProjection(),
            .delete_confirmation = if (self.delete_confirmation) |confirmation| .{
                .temp_id = if (confirmation.target == .draft) confirmation.target.draft else 0,
                .comment_id = if (confirmation.target == .comment) confirmation.target.comment else null,
                .descendant_count = confirmation.descendant_count,
                .root_has_replies = confirmation.root_has_replies,
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
                .footer = if (self.composer_footer.items.len > 0) self.composer_footer.items else null,
                .pending_external_edit = self.external_edit_pending != null,
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
        if (builtin.is_test) return self.shutdown_requested and self.durable_submission == null and self.durable_comment_edit == null and self.durable_comment_delete == null and self.commands.items.len == 0 and self.outstanding_loads == 0 and self.outstanding_picker_loads == 0 and self.issued_enrichments.items.len == 0;
        return self.shutdown_requested and self.durable_submission == null and self.durable_comment_edit == null and self.durable_comment_delete == null and self.commands.items.len == 0 and self.issued_commands.items.len == 0;
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
        if (self.help_visible or self.unknown_resolution != null or self.delete_confirmation != null or self.visibleSubmissionOverlay())
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
        if (self.submissionRepairInteractionActive()) return false;
        if (self.submission_tree) |tree| if (OwnedReviewIdentity.eql(tree.key, published.key)) return true;
        return false;
    }

    fn submissionRepairInteractionActive(self: *const Presentation) bool {
        if (self.help_visible or self.unknown_resolution != null or self.delete_confirmation != null or self.reanchor != null) return true;
        if (self.picker != null or self.file_finder != null) return true;
        if (self.published) |published| return published.composer != null;
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
                const previous_cursor = published.navigation.cursor;
                published.navigation.jumpTo(index);
                clampSelectionAtStatusPlaceholder(published, previous_cursor);
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
        self.recovery_participants.ensureTotalCapacity(self.allocator, run.items.len) catch {
            self.action_error = .recovery_claim_failed;
            return;
        };
        self.recovery_participants.clearRetainingCapacity();
        for (run.items) |item| self.recovery_participants.appendAssumeCapacity(item.temp_id);
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
            self.completeRecoveredTerminal(notice, active, &lock);
            return;
        }
        const recovered = DurableSubmission.recover(self.allocator, self.dependencies.reviews, active, notice.key, lock) catch {
            lock.ptr = null;
            self.action_error = .recovery_claim_failed;
            return;
        };
        lock.ptr = null;
        if (self.submission_tree) |tree| tree.destroy();
        self.durable_submission = recovered.durable;
        self.submission_tree = recovered.tree;
        self.recovery = null;
        self.commands.appendAssumeCapacity(.{ .check_recovery = .{
            .operation_id = notice.operation_id,
            .identity = .init(notice.key),
            .source_commit = notice.source_commit,
        } });
        self.syncSubmissionTree(recovered.durable);
        self.action_error = null;
    }

    fn completeRecoveredTerminal(self: *Presentation, notice: RecoveryNotice, run: bbr.review.ActiveSubmissionRun, lock: *bbr.review.SubmissionLockGuard) void {
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
        const tree = SubmissionTree.createPersisted(self.allocator, notice.key, notice.operation_id, &review, run.items, result.completion) catch {
            self.action_error = .out_of_memory;
            return;
        };
        self.dependencies.reviews.completeSubmission(notice.operation_id, notice.key.storeKey(), result.completion) catch {
            tree.destroy();
            self.action_error = .recovery_claim_failed;
            return;
        };
        if (self.submission_tree) |previous| previous.destroy();
        self.submission_tree = tree;
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
        const source_changed = durable.source_changed;
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
        self.action_error = if (source_changed) .recovery_source_changed else null;
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
            if (command == .post_draft or command == .update_comment or command == .delete_comment or command == .wait_submission or command == .check_recovery or command == .find_duplicate) {
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
        if (self.delete_confirmation != null) return .delete_confirmation;
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
        return .{
            .remote = published.key.isRemote(),
            .context = context,
            .source = source,
            .selection = published.navigation.hasSelection() or (published.navigation.cursor < published.buffer.rows.len and published.buffer.rows[published.navigation.cursor] != .status_placeholder),
            .edit_refusal = self.editRefusal(published),
            .reanchor_refusal = self.reanchorRefusal(published),
            .delete_refusal = self.deleteRefusal(published),
        };
    }

    /// Why editing the ReviewCard under the cursor is refused, or null when it
    /// is editable. Edit stays discoverable either way.
    fn editRefusal(self: *const Presentation, published: *const Published) ?MutationRefusal {
        const target = reviewCardTarget(published) orelse return .no_review_item;
        const temp_id = switch (target) {
            .comment => |comment_id| {
                const comment = findPublishedComment(published, comment_id) orelse return .no_review_item;
                if (comment.deleted) return .comment_deleted;
                const account = self.authenticated_account_uuid orelse return .authenticated_account_unknown;
                const author_uuid = comment.author_uuid orelse return .comment_author_unknown;
                if (!std.mem.eql(u8, account.slice(), author_uuid)) return .comment_owned_by_other;
                if (self.reload_required_epoch == published.epoch) return .authoritative_reload_required;
                if (self.remoteWriteBusy()) return .remote_write_busy;
                return null;
            },
            .draft => |id| id,
        };
        const draft = published.review.getConst(temp_id) orelse return .no_review_item;
        switch (draft.state) {
            .draft, .failed => {},
            .submitting => return .submission_in_flight,
            .posted => return .already_published,
            .outcome_unknown => return .outcome_unresolved,
        }
        if (self.submissionOwnsDraft(published.key, temp_id)) return .submission_owns_draft;
        return null;
    }

    /// Why re-anchoring is refused, or null when a replacement Anchor is
    /// acceptable. While armed the answer is about the retained Draft, because
    /// the cursor has deliberately moved to the source that will replace it.
    fn reanchorRefusal(self: *const Presentation, published: *const Published) ?MutationRefusal {
        if (self.reanchor) |capture| {
            if (!OwnedReviewIdentity.eql(published.key, capture.key)) return .no_review_item;
            return self.draftReanchorRefusal(published, capture.temp_id);
        }
        const target = reviewCardTarget(published) orelse return .no_review_item;
        return switch (target) {
            .comment => .published_comment,
            .draft => |temp_id| self.draftReanchorRefusal(published, temp_id),
        };
    }

    fn draftReanchorRefusal(self: *const Presentation, published: *const Published, temp_id: bbr.review.TempId) ?MutationRefusal {
        const draft = published.review.getConst(temp_id) orelse return .no_review_item;
        // Shape first: a Reply or an unanchored root is never re-anchorable,
        // whatever its state.
        if (draft.parent != null) return .reply_inherits_scope;
        if (draft.effectiveScope() != .@"inline") return .scope_not_inline;
        switch (draft.state) {
            .draft, .failed => {},
            .submitting => return .submission_in_flight,
            .posted => return .already_published,
            .outcome_unknown => return .outcome_unresolved,
        }
        if (self.submissionOwnsDraft(published.key, temp_id)) return .submission_owns_draft;
        return null;
    }

    /// Why deleting is refused, or null when the complete subtree can go. While
    /// a confirmation is armed the answer is about the Draft it retained, so a
    /// state change under the overlay is visible before the reviewer confirms.
    fn deleteRefusal(self: *const Presentation, published: *const Published) ?MutationRefusal {
        if (self.delete_confirmation) |confirmation| {
            if (!OwnedReviewIdentity.eql(published.key, confirmation.key)) return .no_review_item;
            return switch (confirmation.target) {
                .comment => |comment_id| self.commentDeleteRefusal(published, comment_id),
                .draft => |temp_id| self.draftDeleteRefusal(published, temp_id),
            };
        }
        const target = reviewCardTarget(published) orelse return .no_review_item;
        return switch (target) {
            .comment => |comment_id| self.commentDeleteRefusal(published, comment_id),
            .draft => |temp_id| self.draftDeleteRefusal(published, temp_id),
        };
    }

    fn commentDeleteRefusal(self: *const Presentation, published: *const Published, comment_id: bbr.review.CommentId) ?MutationRefusal {
        const comment = findPublishedComment(published, comment_id) orelse return .no_review_item;
        if (comment.deleted) return .comment_deleted;
        const account = self.authenticated_account_uuid orelse return .authenticated_account_unknown;
        const author_uuid = comment.author_uuid orelse return .comment_author_unknown;
        if (!std.mem.eql(u8, account.slice(), author_uuid)) return .comment_owned_by_other;
        if (self.reload_required_epoch == published.epoch) return .authoritative_reload_required;
        if (self.remoteWriteBusy()) return .remote_write_busy;
        return null;
    }

    fn remoteWriteBusy(self: *const Presentation) bool {
        return self.durable_submission != null or self.durable_comment_edit != null or self.durable_comment_delete != null;
    }

    /// The whole cascade must be deletable: one run-owned, in-flight, published,
    /// or unresolved member anywhere below the root refuses all of it, because
    /// deleting the rest would strand it or destroy ambiguous evidence.
    fn draftDeleteRefusal(self: *const Presentation, published: *const Published, temp_id: bbr.review.TempId) ?MutationRefusal {
        if (published.review.getConst(temp_id) == null) return .no_review_item;
        for (published.review.drafts.items) |candidate| {
            if (!bbr.review.descendsFrom(published.review.drafts.items, temp_id, candidate.local_id)) continue;
            const root = candidate.local_id == temp_id;
            switch (candidate.state) {
                .draft, .failed => {},
                .submitting => return if (root) .submission_in_flight else .descendant_locked,
                .posted => return if (root) .already_published else .descendant_locked,
                .outcome_unknown => return if (root) .outcome_unresolved else .descendant_locked,
            }
            if (self.submissionOwnsDraft(published.key, candidate.local_id))
                return if (root) .submission_owns_draft else .descendant_locked;
        }
        return null;
    }

    /// `D` on a deletable ReviewCard: arm the keyboard-complete confirmation
    /// naming the local TempId and the complete Reply-descendant consequence.
    fn openDeleteConfirmation(self: *Presentation, published: *Published) void {
        if (published.composer != null) return;
        // Already armed: `D` neither re-targets nor confirms the deletion.
        if (self.delete_confirmation != null) return;
        if (self.deleteRefusal(published)) |refusal| {
            self.action_error = mutationRefusalError(refusal);
            return;
        }
        const target = reviewCardTarget(published) orelse {
            self.action_error = .no_review_item;
            return;
        };
        self.delete_confirmation = switch (target) {
            .draft => |temp_id| .{
                .key = published.key,
                .target = .{ .draft = temp_id },
                .descendant_count = descendantCount(published, temp_id),
            },
            .comment => |comment_id| .{
                .key = published.key,
                .target = .{ .comment = comment_id },
                .descendant_count = publishedReplyCount(published, comment_id),
                .root_has_replies = (findPublishedComment(published, comment_id) orelse unreachable).parent_id == null and publishedReplyCount(published, comment_id) > 0,
            },
        };
        self.action_error = null;
    }

    fn applyDeleteConfirmationInput(self: *Presentation, input: DeleteConfirmationInput) void {
        if (self.shutdown_requested or self.replacement != null) return;
        const confirmation = self.delete_confirmation orelse return;
        if (input == .cancel) {
            self.delete_confirmation = null;
            self.action_error = null;
            return;
        }
        const published = self.published orelse {
            self.delete_confirmation = null;
            return;
        };
        if (!OwnedReviewIdentity.eql(published.key, confirmation.key)) {
            self.delete_confirmation = null;
            return;
        }
        if (confirmation.target == .comment) return self.confirmCommentDelete(published, confirmation);
        const temp_id = confirmation.target.draft;
        if (published.review.getConst(temp_id) == null) {
            self.delete_confirmation = null;
            self.action_error = .no_review_item;
            return;
        }
        if (self.draftDeleteRefusal(published, temp_id)) |refusal| {
            self.action_error = mutationRefusalError(refusal);
            return;
        }

        const cascade = self.allocator.alloc(bbr.review.TempId, published.review.drafts.items.len) catch {
            self.action_error = .out_of_memory;
            return;
        };
        defer self.allocator.free(cascade);
        // The cascade is recomputed here rather than retained from the
        // confirmation, and the store rechecks it again inside its own write:
        // that transaction, not this snapshot, is what makes it authoritative.
        const len = collectCascade(published, temp_id, cascade);
        const surviving = survivingRowAfterDeletion(published, cascade[0..len]);
        published.deleteDraftSubtree(
            self.dependencies.reviews,
            self.preferences,
            temp_id,
            cascade[0..len],
        ) catch |err| {
            self.action_error = switch (err) {
                error.AnchorRangeTooLong => .anchor_range_too_long,
                error.InvalidDraftScope => .action_refused,
                error.DraftLocked => .draft_owned_by_submission,
                error.DraftEditConflict => .draft_edit_conflict,
                error.PersistenceFailed => .persistence_failed,
                error.BufferBuildFailed => .buffer_build_failed,
                error.OutOfMemory => .out_of_memory,
            };
            return;
        };
        self.delete_confirmation = null;
        published.navigation.clearMark();
        followSurvivingRow(published, surviving);
        if (self.submission_tree) |tree| if (OwnedReviewIdentity.eql(tree.key, published.key)) tree.refresh(&published.review);
        self.refreshStaleRepairTree();
        self.action_error = null;
    }

    fn confirmCommentDelete(self: *Presentation, published: *Published, confirmation: DeleteConfirmation) void {
        const comment_id = confirmation.target.comment;
        if (self.commentDeleteRefusal(published, comment_id)) |refusal| {
            self.action_error = mutationRefusalError(refusal);
            return;
        }
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        const durable = self.allocator.create(DurableCommentDelete) catch {
            self.action_error = .out_of_memory;
            return;
        };
        durable.* = .{
            .allocator = self.allocator,
            .key = published.key,
            .comment_id = comment_id,
            .initiating_epoch = published.epoch,
        };
        const command = DeleteComment.create(self.allocator, published.key, comment_id) catch {
            durable.destroy();
            self.action_error = .out_of_memory;
            return;
        };
        self.delete_confirmation = null;
        self.comment_edit_result = null;
        self.durable_comment_delete = durable;
        self.commands.appendAssumeCapacity(.{ .delete_comment = command });
        self.action_error = null;
    }

    fn reanchorProjection(self: *const Presentation) ?ReanchorProjection {
        const capture = self.reanchor orelse return null;
        const published = self.published orelse return null;
        if (!OwnedReviewIdentity.eql(published.key, capture.key)) return null;
        const draft = published.review.getConst(capture.temp_id) orelse return null;
        const candidate = reanchorCandidate(published, draft.kind) catch |err| return .{
            .temp_id = capture.temp_id,
            .candidate = null,
            .refusal = candidateError(err),
        };
        return .{
            .temp_id = capture.temp_id,
            .candidate = .{
                .path = candidate.anchor.path,
                .side = if (candidate.anchor.to != null) .new else .old,
                .top = candidate.anchor.top().?,
                .bottom = candidate.anchor.line().?,
            },
            .refusal = null,
        };
    }

    /// `a` on an eligible inline root Draft: retain its TempId and hand input
    /// back to the DiffPane, where a later cursor or Selection names the
    /// replacement Anchor.
    fn armReanchor(self: *Presentation, published: *Published) void {
        if (published.composer != null) return;
        // Already armed: `a` neither re-targets nor cancels the interaction.
        if (self.reanchor != null) return;
        if (self.reanchorRefusal(published)) |refusal| {
            self.action_error = mutationRefusalError(refusal);
            return;
        }
        const target = reviewCardTarget(published) orelse {
            self.action_error = .no_review_item;
            return;
        };
        self.reanchor = .{ .key = published.key, .temp_id = target.draft };
        self.action_error = null;
    }

    fn applyReanchorInput(self: *Presentation, input: ReanchorInput) void {
        if (self.shutdown_requested or self.replacement != null) return;
        const capture = self.reanchor orelse return;
        if (input == .cancel) {
            self.reanchor = null;
            self.action_error = null;
            return;
        }
        const published = self.published orelse {
            self.reanchor = null;
            return;
        };
        if (!OwnedReviewIdentity.eql(published.key, capture.key)) {
            self.reanchor = null;
            return;
        }
        const draft = published.review.getConst(capture.temp_id) orelse {
            self.reanchor = null;
            self.action_error = .no_review_item;
            return;
        };
        if (self.draftReanchorRefusal(published, capture.temp_id)) |refusal| {
            self.action_error = mutationRefusalError(refusal);
            return;
        }
        const candidate = reanchorCandidate(published, draft.kind) catch |err| {
            self.action_error = candidateError(err);
            return;
        };
        // A LocalReview replaces its authored evidence from the newly selected
        // source; a RemoteReview invents no snapshot.
        const snapshot = if (published.key.isRemote()) null else captureAnchorSnapshot(
            published.review_arena.allocator(),
            published.session.diff.files[candidate.file_index],
            candidate.lines.items(),
        ) catch {
            self.action_error = .out_of_memory;
            return;
        };
        published.reanchorDraft(
            self.dependencies.reviews,
            self.preferences,
            capture.temp_id,
            candidate.anchor,
            snapshot,
        ) catch |err| {
            self.action_error = switch (err) {
                error.AnchorRangeTooLong => .anchor_range_too_long,
                error.InvalidDraftScope => .action_refused,
                error.DraftLocked => .draft_owned_by_submission,
                error.DraftEditConflict => .draft_edit_conflict,
                error.DraftNotAnchorable => .draft_scope_not_inline,
                error.InvalidAnchor => .anchor_candidate_ambiguous,
                error.PersistenceFailed => .persistence_failed,
                error.BufferBuildFailed => .buffer_build_failed,
                error.OutOfMemory => .out_of_memory,
            };
            return;
        };
        self.reanchor = null;
        published.navigation.clearMark();
        followDraftCard(published, capture.temp_id);
        if (self.submission_tree) |tree| if (OwnedReviewIdentity.eql(tree.key, published.key)) tree.refresh(&published.review);
        self.refreshStaleRepairTree();
        self.action_error = null;
    }

    /// True while an active or recovered SubmissionRun holds this Draft in its
    /// frozen participant graph — immutable for the run's whole lifetime, not
    /// only while the item itself carries `submitting`.
    fn submissionOwnsDraft(self: *const Presentation, key: OwnedReviewIdentity, temp_id: bbr.review.TempId) bool {
        if (self.durable_submission) |durable| {
            if (OwnedReviewIdentity.eql(durable.key, key))
                for (durable.machine.order) |participant| if (participant == temp_id) return true;
        }
        if (self.recovery) |notice| {
            if (OwnedReviewIdentity.eql(notice.key, key))
                for (self.recovery_participants.items) |participant| if (participant == temp_id) return true;
        }
        return false;
    }

    fn applyKey(self: *Presentation, key: keymap_mod.KeyStroke) !void {
        if (self.visibleSubmissionOverlay()) {
            self.applySubmissionTreeKey(key);
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
        // The confirmation is keyboard-complete and captures everything else:
        // no motion can drift the cursor away from the Draft it names.
        if (self.delete_confirmation != null) {
            if (key.matches(keymap_mod.special.escape, .{}) or key.matches('c', .{ .ctrl = true }) or key.matches('n', .{}))
                return self.applyDeleteConfirmationInput(.cancel);
            if (key.matches(keymap_mod.special.enter, .{}) or key.matches('y', .{}))
                return self.applyDeleteConfirmationInput(.confirm);
            return;
        }
        if (self.published) |published| if (published.composer != null) {
            if (self.external_edit_pending != null) return;
            if (self.resolver.feed(self.dependencies.keymap, .composer, key) == .action)
                return self.applyComposerInput(.external_edit);
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
        // Stage two of re-anchor keeps the DiffPane's whole motion and Selection
        // vocabulary; only accept and cancel are claimed from it.
        if (self.reanchor != null) {
            if (key.matches(keymap_mod.special.escape, .{}) or key.matches('c', .{ .ctrl = true })) return self.applyReanchorInput(.cancel);
            if (key.matches(keymap_mod.special.enter, .{})) return self.applyReanchorInput(.accept);
        }
        switch (self.resolver.feed(self.dependencies.keymap, self.interactionContext(), key)) {
            .none => {},
            .digit => |digit| self.pushCountDigit(digit),
            .action => |action| self.applyAction(action),
        }
    }

    fn applySubmissionTreeKey(self: *Presentation, key: keymap_mod.KeyStroke) void {
        const tree = self.submission_tree orelse return;
        // The tree is the blocking surface, but Review switching remains
        // available without dismissing or cancelling the durable run.
        if (key.matches('p', .{})) {
            self.openPicker();
            return;
        }
        if (key.matches('j', .{}) or key.matches(keymap_mod.special.down, .{})) {
            tree.move(1);
            return;
        }
        if (key.matches('k', .{}) or key.matches(keymap_mod.special.up, .{})) {
            tree.move(-1);
            return;
        }
        if (tree.completion == null) {
            if (key.matches('A', .{})) self.abandonRecoveredSubmission();
            return;
        }
        if (tree.stale_repair != null and key.matches('R', .{})) {
            const published = self.published orelse return;
            if (OwnedReviewIdentity.eql(published.key, tree.key)) self.queueRefresh(tree.key);
            return;
        }
        if (key.matches(keymap_mod.special.escape, .{}) or key.matches('q', .{})) {
            self.dismissSubmissionTree();
            return;
        }
        const item = tree.selectedItem() orelse return;
        if (self.replacement != null) return;
        const published = self.published orelse return;
        if (!OwnedReviewIdentity.eql(published.key, tree.key)) return;
        if (item.state == .outcome_unknown) {
            if (key.matches('U', .{})) self.resolveUnknownAsUnpublished(published, item.temp_id) else if (key.matches('L', .{})) self.openUnknownResolutionEditorFor(published, item.temp_id) else if (key.matches('A', .{})) self.dismissSubmissionTree();
            return;
        }
        if (key.matches('e', .{})) {
            if (!item.repair_eligible) return;
            const draft = published.review.getConst(item.temp_id) orelse return;
            switch (draft.state) {
                .draft, .failed => {},
                .submitting => return self.setMutationActionError(.submission_in_flight),
                .posted => return self.setMutationActionError(.already_published),
                .outcome_unknown => return self.setMutationActionError(.outcome_unresolved),
            }
            self.openDraftEditComposer(published, item.temp_id);
        } else if (key.matches('a', .{})) {
            if (!item.repair_eligible) return;
            if (self.draftReanchorRefusal(published, item.temp_id)) |refusal| {
                self.action_error = mutationRefusalError(refusal);
                return;
            }
            self.reanchor = .{ .key = published.key, .temp_id = item.temp_id };
            self.action_error = null;
        } else if (key.matches('D', .{})) {
            if (!item.repair_eligible) return;
            if (self.draftDeleteRefusal(published, item.temp_id)) |refusal| {
                self.action_error = mutationRefusalError(refusal);
                return;
            }
            self.delete_confirmation = .{
                .key = published.key,
                .target = .{ .draft = item.temp_id },
                .descendant_count = descendantCount(published, item.temp_id),
            };
            self.action_error = null;
        } else if (key.matches('X', .{})) {
            if (!item.retry_eligible) return;
            self.startSubmissionSelection(published, item.temp_id);
        }
    }

    fn setMutationActionError(self: *Presentation, refusal: MutationRefusal) void {
        self.action_error = mutationRefusalError(refusal);
    }

    fn dismissSubmissionTree(self: *Presentation) void {
        const tree = self.submission_tree orelse {
            self.submission_result = null;
            return;
        };
        if (tree.completion == null) return;
        self.submission_tree = null;
        tree.destroy();
        self.submission_result = null;
    }

    fn abandonRecoveredSubmission(self: *Presentation) void {
        const durable = self.durable_submission orelse return;
        if (!durable.recovered) return;
        const temp_id = durable.current_temp_id orelse return;
        self.dependencies.reviews.abandonSubmission(durable.operation_id, durable.key.storeKey()) catch {
            self.action_error = .persistence_failed;
            return;
        };
        durable.review.setState(temp_id, .outcome_unknown);
        const completion: bbr.review.SubmissionCompletion = .partial;
        const result = durable.persistedResultProjection(completion);
        if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, durable.key))
            published.review.setState(temp_id, .outcome_unknown);
        if (self.submission_tree) |tree| {
            tree.finish(durable, completion);
            if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, durable.key)) tree.refresh(&published.review);
        }
        self.removeQueuedSubmissionCommands(durable.operation_id);
        self.durable_submission = null;
        durable.destroy();
        self.submission_result = result;
        self.refreshStaleRepairTree();
        self.action_error = null;
    }

    fn removeQueuedSubmissionCommands(self: *Presentation, operation_id: bbr.review.OperationId) void {
        var write: usize = 0;
        for (self.commands.items) |command_value| {
            var command = command_value;
            const matches = switch (command) {
                .post_draft => |post| post.operation_id == operation_id,
                .wait_submission => |wait| wait.operation_id == operation_id,
                .check_recovery => |check| check.operation_id == operation_id,
                .find_duplicate => |check| check.operation_id == operation_id,
                else => false,
            };
            if (matches) {
                command.deinit();
            } else {
                self.commands.items[write] = command;
                write += 1;
            }
        }
        self.commands.shrinkRetainingCapacity(write);
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
        const availability = self.actionAvailability();
        if (visible_key != null and !availability.available(action)) {
            self.action_error = switch (action) {
                .open_pull_request_picker => .local_review_no_picker,
                .submit => .local_review_no_submission,
                .inline_comment, .suggest, .yank, .toggle_select => .source_action_unavailable,
                .edit_review_item => mutationRefusalError(availability.edit_refusal),
                .reanchor_review_item => mutationRefusalError(availability.reanchor_refusal),
                .delete_review_item => mutationRefusalError(availability.delete_refusal),
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
        const selection_cursor_before = published.navigation.cursor;
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
                if (published.navigation.cursor < published.buffer.rows.len and published.buffer.rows[published.navigation.cursor] != .status_placeholder) published.navigation.ensureMark();
                published.navigation.down();
            },
            .select_up => {
                if (published.navigation.cursor < published.buffer.rows.len and published.buffer.rows[published.navigation.cursor] != .status_placeholder) published.navigation.ensureMark();
                published.navigation.up();
            },
            .toggle_select => {
                if (published.navigation.hasSelection())
                    published.navigation.clearMark()
                else if (published.navigation.cursor < published.buffer.rows.len and published.buffer.rows[published.navigation.cursor] != .status_placeholder)
                    published.navigation.toggleMark()
                else
                    self.action_error = .source_action_unavailable;
            },
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
            .edit_review_item => self.openEditComposer(published),
            .external_edit => self.applyComposerInput(.external_edit),
            .reanchor_review_item => self.armReanchor(published),
            .delete_review_item => self.openDeleteConfirmation(published),
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
        clampSelectionAtStatusPlaceholder(published, selection_cursor_before);
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
        self.resolveUnknownAsUnpublished(published, draft.local_id);
    }

    fn resolveUnknownAsUnpublished(self: *Presentation, published: *Published, temp_id: bbr.review.TempId) void {
        const draft = published.review.get(temp_id) orelse {
            self.action_error = .action_refused;
            return;
        };
        if (draft.state != .outcome_unknown) {
            self.action_error = .action_refused;
            return;
        }
        self.dependencies.reviews.resolveUnknown(published.key.storeKey(), temp_id, .unpublished) catch {
            self.action_error = .persistence_failed;
            return;
        };
        draft.state = .draft;
        if (self.submission_tree) |tree| if (OwnedReviewIdentity.eql(tree.key, published.key)) {
            tree.refresh(&published.review);
            if (tree.find(temp_id)) |item| {
                item.state = .queued;
                item.retry_eligible = true;
                item.repair_eligible = true;
            }
        };
        self.refreshStaleRepairTree();
        published.rebuild(self.preferences, published.expanded_disclosures.items, published.isolated_file) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        self.action_error = null;
    }

    fn openUnknownResolutionEditor(self: *Presentation, published: *Published) void {
        const draft = selectedUnknownDraft(published) orelse {
            self.action_error = .action_refused;
            return;
        };
        self.openUnknownResolutionEditorFor(published, draft.local_id);
    }

    fn openUnknownResolutionEditorFor(self: *Presentation, published: *Published, temp_id: bbr.review.TempId) void {
        const draft = published.review.getConst(temp_id) orelse {
            self.action_error = .action_refused;
            return;
        };
        if (draft.state != .outcome_unknown) {
            self.action_error = .action_refused;
            return;
        }
        self.unknown_resolution = .{ .key = published.key, .temp_id = temp_id };
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
                const published = self.published orelse {
                    self.action_error = .action_refused;
                    return;
                };
                if (!OwnedReviewIdentity.eql(published.key, editor.key)) {
                    self.action_error = .action_refused;
                    return;
                }
                const comment = findPublishedComment(published, comment_id) orelse {
                    self.action_error = .action_refused;
                    return;
                };
                const account = self.authenticated_account_uuid orelse {
                    self.action_error = .authenticated_account_unknown;
                    return;
                };
                const author = comment.author_uuid orelse {
                    self.action_error = .comment_author_unknown;
                    return;
                };
                if (!std.mem.eql(u8, account.slice(), author)) {
                    self.action_error = .comment_owned_by_other;
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
                if (self.published) |current| if (OwnedReviewIdentity.eql(current.key, editor.key))
                    current.review.setState(editor.temp_id, .{ .posted = comment_id });
                const key = editor.key;
                self.unknown_resolution = null;
                if (self.published) |current| if (OwnedReviewIdentity.eql(current.key, key)) self.queueReconciliation(key);
                self.action_error = null;
            },
        }
    }

    fn startSubmission(self: *Presentation, published: *Published) void {
        self.startSubmissionSelection(published, null);
    }

    fn startSubmissionSelection(self: *Presentation, published: *Published, selected_root: ?bbr.review.TempId) void {
        if (!published.key.isRemote()) {
            self.action_error = .local_review_no_submission;
            return;
        }
        if (self.durable_comment_edit != null or self.durable_comment_delete != null) {
            self.action_error = .remote_write_busy;
            return;
        }
        if (self.stale_repair) |gate| if (OwnedReviewIdentity.eql(gate.key, published.key)) {
            const root = selected_root orelse {
                self.action_error = .recovery_source_changed;
                return;
            };
            if (!gate.reloaded or !staleSubtreeEligible(published, root)) {
                self.action_error = .recovery_source_changed;
                return;
            }
        };
        if (self.durable_submission) |durable| {
            if (selected_root != null) {
                self.action_error = .submission_already_active;
                return;
            }
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
            selected_root,
        ) catch |err| {
            self.action_error = if (err == error.SubmissionAlreadyActive) .submission_already_active else .submission_start_failed;
            return;
        } orelse {
            self.action_error = .action_refused;
            return;
        };
        if (self.dependencies.require_source_check) {
            switch (started.command) {
                .post => |command| command.destroy(),
                .wait => {},
            }
            started.durable.recovery_source_commit = source_check.?;
            started.durable.phase = .recovery_check_queued;
            self.commands.appendAssumeCapacity(.{ .check_recovery = .{
                .operation_id = started.durable.operation_id,
                .identity = .init(started.durable.key),
                .source_commit = started.durable.recovery_source_commit.?,
            } });
        } else {
            switch (started.command) {
                .post => |command| self.commands.appendAssumeCapacity(.{ .post_draft = command }),
                .wait => |wait| self.commands.appendAssumeCapacity(.{ .wait_submission = wait }),
            }
        }
        if (self.submission_tree) |tree| tree.destroy();
        self.durable_submission = started.durable;
        self.submission_tree = started.tree;
        published.review.setState(started.durable.current_temp_id.?, .submitting);
        self.syncSubmissionTree(started.durable);
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
            self.syncSubmissionTree(durable);
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
        self.syncSubmissionTree(durable);
        self.action_error = .submission_launch_failed;
    }

    fn acceptCommentEdit(self: *Presentation, completed: CommentEditCompleted) void {
        if (!self.consumeCommand(completed.command_id, .update_comment)) return;
        const durable = self.durable_comment_edit orelse return;
        if (!durableIdentityMatches(durable.key, completed.identity) or durable.comment_id != completed.comment_id) return;
        if (completed.outcome == .definitive_failure) {
            if (completed.outcome.definitive_failure == error.Unauthorized) self.authenticated_account_uuid = null;
            self.restoreCommentEditComposer(durable);
            self.comment_edit_result = .{ .key = durable.key, .comment_id = durable.comment_id, .outcome = .failed };
            self.durable_comment_edit = null;
            durable.destroy();
            self.action_error = .comment_edit_failed;
            return;
        }
        durable.outcome = completed.outcome;
        self.comment_edit_result = .{
            .key = durable.key,
            .comment_id = durable.comment_id,
            .outcome = if (completed.outcome == .outcome_unknown) .outcome_unknown else .updated,
        };
        const visible = !self.shutdown_requested and self.published != null and OwnedReviewIdentity.eql(self.published.?.key, durable.key) and self.replacement == null;
        if (visible) {
            self.queueReconciliation(durable.key);
            return;
        }
        self.durable_comment_edit = null;
        durable.destroy();
        self.action_error = null;
    }

    fn acceptCommentEditLaunchFailure(self: *Presentation, failed: CommentEditLaunchFailed) void {
        if (!self.consumeCommand(failed.command_id, .update_comment)) return;
        const durable = self.durable_comment_edit orelse return;
        if (!durableIdentityMatches(durable.key, failed.identity) or durable.comment_id != failed.comment_id) return;
        self.restoreCommentEditComposer(durable);
        self.comment_edit_result = .{ .key = durable.key, .comment_id = durable.comment_id, .outcome = .failed };
        self.durable_comment_edit = null;
        durable.destroy();
        self.action_error = .comment_edit_launch_failed;
    }

    fn acceptCommentDelete(self: *Presentation, completed: CommentDeleteCompleted) void {
        if (!self.consumeCommand(completed.command_id, .delete_comment)) return;
        const durable = self.durable_comment_delete orelse return;
        if (!durableIdentityMatches(durable.key, completed.identity) or durable.comment_id != completed.comment_id) return;
        if (completed.outcome == .definitive_failure) {
            if (completed.outcome.definitive_failure == error.Unauthorized) self.authenticated_account_uuid = null;
            self.restoreCommentDeleteConfirmation(durable);
            self.comment_delete_result = .{ .key = durable.key, .comment_id = durable.comment_id, .outcome = .failed };
            self.durable_comment_delete = null;
            durable.destroy();
            self.action_error = .comment_delete_failed;
            return;
        }
        durable.outcome = completed.outcome;
        self.comment_delete_result = .{
            .key = durable.key,
            .comment_id = durable.comment_id,
            .outcome = if (completed.outcome == .outcome_unknown) .outcome_unknown else .deleted,
        };
        const visible = !self.shutdown_requested and self.published != null and OwnedReviewIdentity.eql(self.published.?.key, durable.key) and self.replacement == null;
        if (visible) {
            self.queueReconciliation(durable.key);
            return;
        }
        self.durable_comment_delete = null;
        durable.destroy();
        self.action_error = null;
    }

    fn acceptCommentDeleteLaunchFailure(self: *Presentation, failed: CommentDeleteLaunchFailed) void {
        if (!self.consumeCommand(failed.command_id, .delete_comment)) return;
        const durable = self.durable_comment_delete orelse return;
        if (!durableIdentityMatches(durable.key, failed.identity) or durable.comment_id != failed.comment_id) return;
        self.restoreCommentDeleteConfirmation(durable);
        self.comment_delete_result = .{ .key = durable.key, .comment_id = durable.comment_id, .outcome = .failed };
        self.durable_comment_delete = null;
        durable.destroy();
        self.action_error = .comment_delete_launch_failed;
    }

    fn restoreCommentDeleteConfirmation(self: *Presentation, durable: *const DurableCommentDelete) void {
        const current = self.published orelse return;
        if (!OwnedReviewIdentity.eql(current.key, durable.key) or current.epoch != durable.initiating_epoch) return;
        const comment = findPublishedComment(current, durable.comment_id) orelse return;
        const replies = publishedReplyCount(current, durable.comment_id);
        self.delete_confirmation = .{
            .key = durable.key,
            .target = .{ .comment = durable.comment_id },
            .descendant_count = replies,
            .root_has_replies = comment.parent_id == null and replies > 0,
        };
    }

    fn restoreCommentEditComposer(self: *Presentation, durable: *const DurableCommentEdit) void {
        const current = self.published orelse return;
        if (!OwnedReviewIdentity.eql(current.key, durable.key) or current.epoch != durable.initiating_epoch) return;
        const comment = findPublishedComment(current, durable.comment_id);
        _ = current.composer_arena.reset(.retain_capacity);
        current.composer = Composer.init(current.composer_arena.allocator(), .{
            .kind = .comment,
            .target = .bitbucket,
            .scope = if (comment) |value| value.scope else null,
            .anchor = if (comment) |value| value.anchor else null,
            .parent = if (comment) |value| if (value.parent_id) |parent_id| .{ .comment = parent_id } else null else null,
            .label = "Edit Bitbucket Comment",
            .mutation = .{ .comment = durable.comment_id },
        });
        current.composer.?.seed(durable.body) catch {
            current.composer = null;
        };
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
            self.syncSubmissionTree(durable);
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
            self.syncSubmissionTree(durable);
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
            .check => |command| self.commands.appendAssumeCapacity(.{ .find_duplicate = command }),
            .wait => |wait| self.commands.appendAssumeCapacity(.{ .wait_submission = wait }),
            .finished => |finished| {
                self.recordVisibleTransition(durable, finished.transition);
                if (self.submission_tree) |tree| tree.finish(durable, finished.result.completion);
                const reconcile = durable.posted_any and !self.shutdown_requested and self.replacement == null and
                    (if (self.published) |published| OwnedReviewIdentity.eql(published.key, durable.key) else false);
                const key = durable.key;
                self.submission_result = finished.result;
                self.durable_submission = null;
                durable.destroy();
                if (reconcile) self.queueReconciliation(key);
            },
        }
        if (self.durable_submission) |active| self.syncSubmissionTree(active);
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
            durable.observed_source_commit = current_source;
            if (durable.recovered) {
                self.stale_repair = .{
                    .key = durable.key,
                    .loaded_source_commit = recovered_source,
                    .observed_source_commit = current_source,
                };
                durable.source_changed = true;
                durable.phase = .recovery_source_changed;
                self.queueDuplicateCheck(durable);
                self.refreshStaleRepairTree();
            } else {
                self.abortChangedSubmission(durable);
            }
            return;
        }
        if (!durable.recovered) {
            if (self.stale_repair) |gate| {
                if (OwnedReviewIdentity.eql(gate.key, durable.key)) self.stale_repair = null;
            }
        }
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.phase = .recovery_check_paused;
            self.action_error = .out_of_memory;
            return;
        };
        switch (durable.machine.advance()) {
            .wait => |wait| {
                durable.phase = .wait_queued;
                self.commands.appendAssumeCapacity(.{ .wait_submission = .{
                    .operation_id = durable.operation_id,
                    .identity = .init(durable.key),
                    .temp_id = wait.temp_id,
                    .ms = wait.ms,
                    .checkpoint = wait.checkpoint,
                } });
                self.action_error = null;
            },
            .post => |post| {
                if (durable.recovered) {
                    self.queueDuplicateCheck(durable);
                    return;
                }
                const draft = durable.review.getConst(post.temp_id) orelse {
                    durable.phase = .recovery_check_paused;
                    self.action_error = .recovery_check_failed;
                    return;
                };
                const command = PostDraft.create(self.allocator, durable.key, draft.*, post) catch {
                    durable.phase = .recovery_check_paused;
                    self.action_error = .out_of_memory;
                    return;
                };
                command.operation_id = durable.operation_id;
                durable.phase = .post_queued;
                self.commands.appendAssumeCapacity(.{ .post_draft = command });
                self.action_error = null;
            },
            .check => self.queueDuplicateCheck(durable),
            else => {
                durable.phase = .recovery_check_paused;
                self.action_error = .recovery_check_failed;
            },
        }
    }

    fn abortChangedSubmission(self: *Presentation, durable: *DurableSubmission) void {
        const observed = durable.observed_source_commit orelse {
            durable.phase = .recovery_check_paused;
            self.action_error = .recovery_check_failed;
            return;
        };
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
        if (self.submission_tree) |tree| tree.finish(durable, completion);
        self.stale_repair = .{
            .key = durable.key,
            .loaded_source_commit = durable.recovery_source_commit.?,
            .observed_source_commit = observed,
        };
        self.durable_submission = null;
        durable.destroy();
        self.submission_result = result;
        self.refreshStaleRepairTree();
        self.action_error = .recovery_source_changed;
    }

    fn acceptDuplicateCheck(self: *Presentation, checked: DuplicateChecked) void {
        if (!self.consumeCommand(checked.command_id, .find_duplicate)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != checked.operation_id or !durableIdentityMatches(durable.key, checked.identity) or durable.current_temp_id != checked.temp_id or durable.phase != .awaiting_duplicate) return;
        if (durable.policy_check) {
            durable.policy_check = false;
            const result: bbr.review.CheckResult = .{
                .outcome = switch (checked.outcome) {
                    .found => |id| .{ .found = id },
                    .missing => .missing,
                    .rejected => |err| .{ .rejected = err },
                    .failed => .ambiguous,
                },
                .retry_after_ms = checked.retry_after_ms,
            };
            durable.machine.reportCheck(result);
            self.advanceAfterPolicyCheck(durable, checked.temp_id);
            return;
        }
        if (checked.outcome == .failed or checked.outcome == .rejected) {
            durable.phase = .duplicate_check_paused;
            self.action_error = .duplicate_check_failed;
            return;
        }
        durable.pending_duplicate = .{ .outcome = checked.outcome };
        durable.phase = .duplicate_persistence_paused;
        self.persistDuplicateResolution(durable);
    }

    fn advanceAfterPolicyCheck(self: *Presentation, durable: *DurableSubmission, temp_id: bbr.review.TempId) void {
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.phase = .duplicate_check_paused;
            durable.policy_check = true;
            self.action_error = .out_of_memory;
            return;
        };
        switch (durable.machine.advance()) {
            .post => |post| {
                const draft = durable.review.getConst(post.temp_id) orelse return;
                const command = PostDraft.create(self.allocator, durable.key, draft.*, post) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                command.operation_id = durable.operation_id;
                durable.phase = .post_queued;
                self.commands.appendAssumeCapacity(.{ .post_draft = command });
                self.action_error = null;
            },
            .check => {
                self.queueDuplicateCheck(durable);
            },
            .wait => |wait| {
                const command: WaitSubmission = .{
                    .operation_id = durable.operation_id,
                    .identity = .init(durable.key),
                    .temp_id = wait.temp_id,
                    .ms = wait.ms,
                    .checkpoint = wait.checkpoint,
                };
                durable.pending_wait_retry = command;
                durable.phase = .wait_retry_paused;
                self.dependencies.reviews.checkpointSubmissionRetry(durable.operation_id, durable.key.storeKey(), wait.temp_id, wait.checkpoint) catch {
                    self.action_error = .persistence_failed;
                    return;
                };
                durable.pending_wait_retry = null;
                durable.phase = .wait_queued;
                self.commands.appendAssumeCapacity(.{ .wait_submission = command });
                self.action_error = null;
            },
            .done => {
                const result = durable.machine.results[durable.machine.idx - 1].?;
                const outcome: bbr.review.SubmissionOutcome = switch (result.status) {
                    .posted => .{ .posted = result.id.? },
                    .outcome_unknown => .outcome_unknown,
                    .failed => .{ .failed = result.reason.? },
                    .skipped => return,
                };
                durable.pending_persistence = .{
                    .transition = .{ .temp_id = temp_id, .state = outcome.draftState() },
                    .outcome = outcome,
                    .completion = if (durable.machine.isClean()) .clean else .partial,
                };
                durable.phase = .persistence_paused;
                const progress = durable.retryPersistence(self.allocator, self.dependencies.reviews) catch {
                    self.action_error = .persistence_failed;
                    return;
                };
                self.publishSubmissionProgress(durable, progress);
            },
            .aborted => unreachable,
        }
    }

    fn persistDuplicateResolution(self: *Presentation, durable: *DurableSubmission) void {
        const pending = if (durable.pending_duplicate) |*value| value else return;
        const temp_id = durable.current_temp_id orelse return;
        const outcome: bbr.review.SubmissionOutcome = switch (pending.outcome) {
            .found => |id| .{ .posted = id },
            .missing => .outcome_unknown,
            .rejected => unreachable,
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
        if (self.submission_tree) |tree| tree.finish(durable, completion);
        if (self.published) |published| if (OwnedReviewIdentity.eql(published.key, durable.key)) {
            published.review.setState(temp_id, outcome.draftState());
            if (self.submission_tree) |tree| tree.refresh(&published.review);
        };
        const reconcile = outcome == .posted and !self.shutdown_requested and self.replacement == null and
            (if (self.published) |published| OwnedReviewIdentity.eql(published.key, durable.key) else false);
        const key = durable.key;
        if (completion == .clean and durable.source_changed) self.stale_repair = null;
        self.durable_submission = null;
        durable.destroy();
        self.submission_result = result;
        if (reconcile) self.queueReconciliation(key);
        self.refreshStaleRepairTree();
        self.action_error = null;
    }

    fn acceptSubmissionWait(self: *Presentation, completed: WaitSubmission) void {
        if (!self.consumeCommand(completed.command_id, .wait_submission)) return;
        const durable = self.durable_submission orelse return;
        if (durable.operation_id != completed.operation_id or !durableIdentityMatches(durable.key, completed.identity) or durable.current_temp_id != completed.temp_id or durable.phase != .awaiting_wait) return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            durable.pending_admission = .{ .wait = completed };
            durable.phase = .admission_paused;
            self.syncSubmissionTree(durable);
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
        self.syncSubmissionTree(durable);
        self.action_error = .submission_launch_failed;
    }

    fn resumeSubmissionWaitLaunch(self: *Presentation, durable: *DurableSubmission) void {
        const wait = durable.pending_wait_retry orelse return;
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        if (wait.checkpoint) |checkpoint| self.dependencies.reviews.checkpointSubmissionRetry(
            durable.operation_id,
            durable.key.storeKey(),
            wait.temp_id,
            checkpoint,
        ) catch {
            self.action_error = .persistence_failed;
            return;
        };
        durable.pending_wait_retry = null;
        durable.phase = .wait_queued;
        self.commands.appendAssumeCapacity(.{ .wait_submission = wait });
        self.syncSubmissionTree(durable);
        self.action_error = null;
    }

    fn processSubmissionWait(self: *Presentation, durable: *DurableSubmission, completed: WaitSubmission) void {
        const command = durable.completeWait(self.allocator, self.dependencies.reviews, completed) catch |err| {
            durable.pending_admission = .{ .wait = completed };
            durable.phase = .admission_paused;
            self.action_error = if (err == error.OutOfMemory) .out_of_memory else .persistence_failed;
            return;
        };
        self.commands.appendAssumeCapacity(.{ .post_draft = command });
        self.syncSubmissionTree(durable);
        self.action_error = null;
    }

    fn syncSubmissionTree(self: *Presentation, durable: *const DurableSubmission) void {
        if (self.submission_tree) |tree| if (tree.operation_id == durable.operation_id and OwnedReviewIdentity.eql(tree.key, durable.key))
            tree.sync(durable);
    }

    fn refreshStaleRepairTree(self: *Presentation) void {
        const gate = self.stale_repair orelse return;
        const tree = self.submission_tree orelse return;
        if (!OwnedReviewIdentity.eql(tree.key, gate.key)) return;
        tree.stale_repair = .{
            .loaded_source_commit = gate.loaded_source_commit.slice(),
            .observed_source_commit = gate.observed_source_commit.slice(),
            .reloaded = gate.reloaded,
        };
        const published = self.published orelse return;
        if (!OwnedReviewIdentity.eql(published.key, gate.key)) return;
        for (tree.items.items) |*item| {
            const draft = published.review.getConst(item.temp_id);
            item.repair_eligible = if (draft) |value| value.state == .draft or value.state == .failed else false;
            item.retry_eligible = gate.reloaded and staleSubtreeEligible(published, item.temp_id);
        }
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

    /// `e` on a ReviewCard: the same Composer as creation, prefilled with the
    /// item's editable content and carrying its typed mutation target.
    fn openEditComposer(self: *Presentation, published: *Published) void {
        if (published.composer != null) return;
        const target = reviewCardTarget(published) orelse {
            self.action_error = .no_review_item;
            return;
        };
        if (target == .comment) {
            const comment = findPublishedComment(published, target.comment) orelse {
                self.action_error = .no_review_item;
                return;
            };
            _ = published.composer_arena.reset(.retain_capacity);
            published.composer = Composer.init(published.composer_arena.allocator(), .{
                .kind = .comment,
                .target = .bitbucket,
                .scope = comment.scope,
                .anchor = comment.anchor,
                .parent = if (comment.parent_id) |parent_id| .{ .comment = parent_id } else null,
                .label = "Edit Bitbucket Comment",
                .mutation = .{ .comment = comment.id },
            });
            published.composer.?.seed(comment.body) catch {
                published.composer = null;
                self.action_error = .out_of_memory;
                return;
            };
            self.action_error = null;
            return;
        }
        self.openDraftEditComposer(published, target.draft);
    }

    fn openDraftEditComposer(self: *Presentation, published: *Published, temp_id: bbr.review.TempId) void {
        if (published.composer != null) return;
        const draft = published.review.getConst(temp_id) orelse {
            self.action_error = .no_review_item;
            return;
        };
        _ = published.composer_arena.reset(.retain_capacity);
        published.composer = Composer.init(published.composer_arena.allocator(), .{
            .kind = draft.kind,
            .target = draft.target,
            .scope = draft.scope,
            .anchor = draft.anchor,
            .snapshot = draft.snapshot,
            .parent = draft.parent,
            .label = "Edit local Draft",
            .mutation = .{ .draft = temp_id },
        });
        published.composer.?.seed(draft.editableBody()) catch {
            published.composer = null;
            self.action_error = .out_of_memory;
            return;
        };
        self.action_error = null;
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
        const span = spanFromLines(lines.items, kind == .suggestion) catch |err| {
            self.action_error = switch (err) {
                error.RangeTooLong => .anchor_range_too_long,
                else => .invalid_selection,
            };
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
        if (self.external_edit_pending != null) return;
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
                self.composer_footer.clearRetainingCapacity();
            },
            .save => self.saveComposer(published),
            .external_edit => {
                const command = ExternalEdit.create(
                    self.allocator,
                    published.epoch,
                    self.dependencies.external_edit_max_bytes,
                    composer.body(),
                ) catch {
                    self.setComposerFooter("External Edit could not allocate the body snapshot");
                    return;
                };
                self.commands.append(self.allocator, .{ .external_edit = command }) catch {
                    command.destroy();
                    self.setComposerFooter("External Edit could not be started");
                    return;
                };
                self.external_edit_pending = published.epoch;
                self.composer_footer.clearRetainingCapacity();
                self.action_error = null;
            },
        }
    }

    fn acceptExternalEdit(self: *Presentation, completed: *ExternalEditCompleted) void {
        defer completed.destroy();
        if (!self.consumeCommand(completed.command_id, .external_edit)) return;
        const expected_epoch = self.external_edit_pending orelse return;
        self.external_edit_pending = null;
        const published = self.published orelse return;
        const composer = if (published.composer) |*value| value else return;
        if (expected_epoch != completed.session_epoch or published.epoch != completed.session_epoch) return;
        switch (completed.outcome) {
            .changed => |body| composer.seed(body) catch {
                self.setComposerFooter("External Edit returned content, but reseeding ran out of memory");
                return;
            },
            .cleanup_failed => |retained| {
                composer.seed(retained.body) catch {
                    self.setComposerFooter("External Edit returned content, but reseeding ran out of memory");
                    return;
                };
                self.setComposerFooterFmt("External Edit accepted; temporary file retained at {s}", .{retained.path});
                return;
            },
            .unchanged => return self.setComposerFooter("External Edit made no changes"),
            .cancelled => return self.setComposerFooter("External Edit was cancelled"),
            .missing_editor => return self.setComposerFooter("External Edit needs GIT_EDITOR, VISUAL, or EDITOR"),
            .invalid_editor => return self.setComposerFooter("External Edit refuses /bin/sh as the configured editor"),
            .too_large => return self.setComposerFooter("External Edit returned a file above external_edit.max_bytes"),
            .invalid_utf8 => return self.setComposerFooter("External Edit returned invalid UTF-8"),
            .contains_nul => return self.setComposerFooter("External Edit returned a NUL byte"),
            .failed => return self.setComposerFooter("External Edit failed"),
            .restoration_failed => |path| return self.setComposerFooterFmt("Terminal restoration failed; temporary file retained at {s}", .{path}),
        }
        self.setComposerFooter("External Edit accepted");
    }

    fn setComposerFooter(self: *Presentation, text: []const u8) void {
        self.composer_footer.clearRetainingCapacity();
        self.composer_footer.appendSlice(self.allocator, text) catch {};
    }

    fn setComposerFooterFmt(self: *Presentation, comptime fmt: []const u8, args: anytype) void {
        self.composer_footer.clearRetainingCapacity();
        self.composer_footer.print(self.allocator, fmt, args) catch {};
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
        if (composer.request.mutation) |target| return self.saveComposerEdit(published, target);
        published.saveDraft(self.dependencies.reviews, self.preferences, composer.toNewDraft()) catch |err| {
            self.action_error = switch (err) {
                error.AnchorRangeTooLong => .anchor_range_too_long,
                error.InvalidDraftScope => .invalid_selection,
                error.PersistenceFailed => .persistence_failed,
                error.BufferBuildFailed => .buffer_build_failed,
                error.OutOfMemory => .out_of_memory,
            };
            return;
        };
        composer.deinit();
        published.composer = null;
        if (self.submission_tree) |tree| if (OwnedReviewIdentity.eql(tree.key, published.key)) tree.refresh(&published.review);
        self.action_error = null;
    }

    /// Save an edit rather than a creation. Every failure keeps the Composer
    /// open with the reviewer's attempted bytes and the previous Frame intact.
    fn saveComposerEdit(self: *Presentation, published: *Published, target: MutationTarget) void {
        const composer = if (published.composer) |*value| value else return;
        const temp_id = switch (target) {
            .comment => |comment_id| return self.startCommentEdit(published, comment_id, composer.body()),
            .draft => |id| id,
        };
        published.editDraftBody(self.dependencies.reviews, self.preferences, temp_id, composer.body()) catch |err| {
            self.action_error = switch (err) {
                error.AnchorRangeTooLong => .anchor_range_too_long,
                error.InvalidDraftScope => .action_refused,
                error.DraftLocked => .draft_owned_by_submission,
                error.DraftEditConflict => .draft_edit_conflict,
                error.PersistenceFailed => .persistence_failed,
                error.BufferBuildFailed => .buffer_build_failed,
                error.OutOfMemory => .out_of_memory,
            };
            return;
        };
        composer.deinit();
        published.composer = null;
        if (self.submission_tree) |tree| if (OwnedReviewIdentity.eql(tree.key, published.key)) tree.refresh(&published.review);
        self.refreshStaleRepairTree();
        self.action_error = null;
    }

    fn startCommentEdit(self: *Presentation, published: *Published, comment_id: bbr.review.CommentId, body: []const u8) void {
        const comment = findPublishedComment(published, comment_id) orelse {
            self.action_error = .no_review_item;
            return;
        };
        if (std.mem.eql(u8, comment.body, body)) {
            published.composer.?.deinit();
            published.composer = null;
            self.action_error = null;
            return;
        }
        if (self.editRefusal(published)) |refusal| {
            self.action_error = mutationRefusalError(refusal);
            return;
        }
        self.commands.ensureUnusedCapacity(self.allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };
        const durable = self.allocator.create(DurableCommentEdit) catch {
            self.action_error = .out_of_memory;
            return;
        };
        durable.* = .{
            .allocator = self.allocator,
            .key = published.key,
            .comment_id = comment_id,
            .initiating_epoch = published.epoch,
            .body = self.allocator.dupe(u8, body) catch {
                self.allocator.destroy(durable);
                self.action_error = .out_of_memory;
                return;
            },
        };
        const command = UpdateComment.create(self.allocator, published.key, comment_id, body) catch {
            durable.destroy();
            self.action_error = .out_of_memory;
            return;
        };
        published.composer.?.deinit();
        published.composer = null;
        self.comment_delete_result = null;
        self.durable_comment_edit = durable;
        self.commands.appendAssumeCapacity(.{ .update_comment = command });
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
        // An explicit switch may supersede a queued Reconciliation after the
        // write has settled. The qualified result survives; the global lane no
        // longer waits on a Session the reviewer chose to replace.
        if (self.durable_comment_edit) |durable| if (durable.outcome != null) {
            self.durable_comment_edit = null;
            durable.destroy();
        };
        if (self.durable_comment_delete) |durable| if (durable.outcome != null) {
            self.durable_comment_delete = null;
            durable.destroy();
        };
        // Commands not yet transferred to the terminal adapter are still ours
        // to supersede. Already-taken commands complete normally and are
        // rejected later by their LoadIntent.
        self.removeQueuedSessionLoads();
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key, .cause = .picker } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key, .cause = .picker };
        self.replacement_error = null;
    }

    fn queueReconciliation(self: *Presentation, key: OwnedReviewIdentity) void {
        const intent = self.next_intent + 1;
        self.removeQueuedSessionLoads();
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key, .cause = .reconciliation } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key, .cause = .reconciliation };
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
        self.replacement = .{ .intent = intent, .key = key, .cause = .refresh };
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
                if (replacement.cause == .reconciliation) if (self.durable_comment_edit) |durable| {
                    if (OwnedReviewIdentity.eql(durable.key, replacement.key)) {
                        if (self.published) |published| {
                            if (OwnedReviewIdentity.eql(published.key, durable.key) and published.epoch == durable.initiating_epoch)
                                self.reload_required_epoch = published.epoch;
                        }
                        self.comment_edit_result = .{ .key = durable.key, .comment_id = durable.comment_id, .outcome = .reload_required };
                        self.durable_comment_edit = null;
                        durable.destroy();
                    }
                };
                if (replacement.cause == .reconciliation) if (self.durable_comment_delete) |durable| {
                    if (OwnedReviewIdentity.eql(durable.key, replacement.key)) {
                        if (self.published) |published| {
                            if (OwnedReviewIdentity.eql(published.key, durable.key) and published.epoch == durable.initiating_epoch)
                                self.reload_required_epoch = published.epoch;
                        }
                        self.comment_delete_result = .{ .key = durable.key, .comment_id = durable.comment_id, .outcome = .reload_required };
                        self.durable_comment_delete = null;
                        durable.destroy();
                    }
                };
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
                if (previous) |current| {
                    if (OwnedReviewIdentity.eql(current.key, candidate.key))
                        candidate.navigation = frame_mod.restoreNavigation(current.frameProjection(), candidate.targets, candidate.geometry);
                }
                self.published = candidate;
                if (self.stale_repair) |*gate| if (OwnedReviewIdentity.eql(gate.key, candidate.key)) {
                    gate.observed_source_commit = BoundedText(64).init(candidate.session.header.source_commit) catch gate.observed_source_commit;
                    gate.reloaded = true;
                };
                if (candidate.session.authenticated_account_uuid) |uuid|
                    self.authenticated_account_uuid = BoundedText(256).init(uuid) catch self.authenticated_account_uuid;
                if (candidate.session.authenticated_account_unauthorized) self.authenticated_account_uuid = null;
                self.next_session_epoch = epoch;
                self.reload_required_epoch = null;
                // The armed candidate named rows in the replaced Session, and
                // the confirmed cascade described the replaced graph.
                self.reanchor = null;
                self.delete_confirmation = null;
                self.resolver = .{};
                self.mouse_press = null;
                self.interaction_revision +%= 1;
                self.replacement = null;
                self.replacement_error = null;
                self.action_error = null;
                if (replacement.cause == .reconciliation) if (self.durable_comment_edit) |durable| {
                    if (OwnedReviewIdentity.eql(durable.key, replacement.key)) {
                        self.durable_comment_edit = null;
                        durable.destroy();
                    }
                };
                if (replacement.cause == .reconciliation) if (self.durable_comment_delete) |durable| {
                    if (OwnedReviewIdentity.eql(durable.key, replacement.key)) {
                        self.durable_comment_delete = null;
                        durable.destroy();
                    }
                };
                if (previous) |published| published.destroy();
                self.refreshStaleRepairTree();
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

fn staleSubtreeEligible(published: *const Published, selected: bbr.review.TempId) bool {
    const selected_draft = published.review.getConst(selected) orelse return false;
    switch (selected_draft.state) {
        .draft, .failed => {},
        .submitting, .posted, .outcome_unknown => return false,
    }
    for (published.review.drafts.items) |draft| {
        if (!bbr.review.descendsFrom(published.review.drafts.items, selected, draft.local_id)) continue;
        switch (draft.state) {
            .draft, .failed, .posted => {},
            .submitting, .outcome_unknown => return false,
        }
    }

    var root = selected_draft;
    while (root.parent) |parent| switch (parent) {
        .comment => |comment_id| return findPublishedComment(published, comment_id) != null,
        .draft => |temp_id| {
            root = published.review.getConst(temp_id) orelse return false;
            switch (root.state) {
                .draft, .failed => {},
                .posted => return true,
                .submitting, .outcome_unknown => return false,
            }
        },
    };

    return switch (root.effectiveScope()) {
        .review => true,
        .file => |file| !bbr.review.headChanged(file.source_commit, published.session.header.source_commit) and
            scopeFileExists(published.session.diff, file.path, false),
        .@"inline" => |anchor| blk: {
            const commit = anchor.commit orelse break :blk false;
            const expected = if (anchor.to != null) published.session.header.source_commit else published.session.header.base_commit;
            break :blk !bbr.review.headChanged(commit, expected) and scopeAnchorExists(published.session.diff, anchor);
        },
    };
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

fn mutationRefusalError(refusal: ?MutationRefusal) ActionError {
    return switch (refusal orelse return .action_refused) {
        .no_review_item => .no_review_item,
        .submission_owns_draft => .draft_owned_by_submission,
        .outcome_unresolved => .draft_outcome_unresolved,
        .submission_in_flight => .draft_submission_in_flight,
        .already_published => .draft_already_published,
        .published_comment => .published_comment_edit_unsupported,
        .authenticated_account_unknown => .authenticated_account_unknown,
        .comment_author_unknown => .comment_author_unknown,
        .comment_owned_by_other => .comment_owned_by_other,
        .comment_deleted => .comment_deleted,
        .remote_write_busy => .remote_write_busy,
        .authoritative_reload_required => .authoritative_reload_required,
        .reply_inherits_scope => .draft_reply_has_no_anchor,
        .scope_not_inline => .draft_scope_not_inline,
        .descendant_locked => .draft_descendant_locked,
    };
}

/// Why the source under the cursor cannot become an Anchor. Every reason is a
/// refusal to guess, not a partially accepted range.
fn candidateError(err: anyerror) ActionError {
    return switch (err) {
        error.RangeTooLong => .anchor_range_too_long,
        error.SuggestionOnRemoved => .suggestion_anchor_not_new_side,
        error.NotOnSource, error.NotOnALine => .source_action_unavailable,
        else => .anchor_candidate_ambiguous,
    };
}

/// The lines a replacement Anchor would cover. Bounded by `max_anchor_lines`,
/// so reading a candidate for the armed banner allocates nothing: anything
/// longer is refused rather than measured.
const CandidateLines = struct {
    storage: [bbr.review.max_anchor_lines]*const bbr.diff.Line = undefined,
    len: usize = 0,

    fn items(self: *const CandidateLines) []const *const bbr.diff.Line {
        return self.storage[0..self.len];
    }
};

const AnchorCandidatePlacement = struct {
    file_index: usize,
    anchor: bbr.review.Anchor,
    lines: CandidateLines,
};

fn candidateLines(published: *const Published) !CandidateLines {
    if (published.navigation.cursor >= published.buffer.rows.len) return error.NotOnSource;
    var lines: CandidateLines = .{};
    if (published.navigation.selection()) |selection| {
        var index = selection[0];
        while (index <= selection[1] and index < published.buffer.rows.len) : (index += 1) {
            // A File header inside the Selection means it left this File.
            if (published.buffer.rows[index] == .file_header) return error.CrossesFile;
            const line = lineAtRow(published.buffer.rows[index]) orelse continue;
            if (lines.len == lines.storage.len) return error.RangeTooLong;
            lines.storage[lines.len] = line;
            lines.len += 1;
        }
    } else if (lineAtRow(published.buffer.rows[published.navigation.cursor])) |line| {
        lines.storage[0] = line;
        lines.len = 1;
    }
    if (lines.len == 0) return error.NotOnSource;
    return lines;
}

/// The Anchor the current source cursor or Selection proposes, under exactly
/// the rules authoring uses — one File, one side, matched and ascending — plus
/// the shared `max_anchor_lines` cap. Strings borrow the published Session.
fn reanchorCandidate(published: *const Published, kind: bbr.review.DraftKind) !AnchorCandidatePlacement {
    const lines = try candidateLines(published);
    const file_index = published.isolated_file orelse fileIndexForRow(published.buffer, published.navigation.cursor);
    if (file_index >= published.session.diff.files.len) return error.NotOnSource;
    const span = try spanFromLines(lines.items(), kind == .suggestion);
    const file = published.session.diff.files[file_index];
    const old_side = span.to == null;
    const anchor: bbr.review.Anchor = .{
        .path = if (old_side) file.old_path else file.new_path,
        .from = span.from,
        .to = span.to,
        .start_from = span.start_from,
        .start_to = span.start_to,
        .commit = if (old_side) published.session.header.base_commit else published.session.header.source_commit,
    };
    anchor.validateShape() catch |err| return switch (err) {
        error.AnchorRangeTooLong => error.RangeTooLong,
        else => error.MixedSides,
    };
    return .{ .file_index = file_index, .anchor = anchor, .lines = lines };
}

/// How many Reply descendants a Draft carries — the consequence the reviewer
/// confirms before deleting. Allocation-free, so reading the armed banner
/// cannot fail.
fn descendantCount(published: *const Published, temp_id: bbr.review.TempId) usize {
    var count: usize = 0;
    for (published.review.drafts.items) |candidate| {
        if (candidate.local_id == temp_id) continue;
        if (bbr.review.descendsFrom(published.review.drafts.items, temp_id, candidate.local_id)) count += 1;
    }
    return count;
}

/// The complete closure to delete, root first (the order every store adapter
/// rechecks). `out` must hold one entry per Draft; the used length is returned.
fn collectCascade(published: *const Published, temp_id: bbr.review.TempId, out: []bbr.review.TempId) usize {
    out[0] = temp_id;
    var len: usize = 1;
    for (published.review.drafts.items) |candidate| {
        if (candidate.local_id == temp_id) continue;
        if (!bbr.review.descendsFrom(published.review.drafts.items, temp_id, candidate.local_id)) continue;
        out[len] = candidate.local_id;
        len += 1;
    }
    return len;
}

/// Where the cursor belongs once `cascade`'s rows are gone: the first surviving
/// semantic row after the deleted card, falling back to the last surviving one
/// before it. Source rows qualify, so a Draft that owned the tail of a File
/// still lands on real content.
fn survivingRowAfterDeletion(published: *const Published, cascade: []const bbr.review.TempId) ?SurvivingRow {
    const rows = published.buffer.rows;
    var first: ?usize = null;
    for (rows, 0..) |row, index| {
        if (!rowOwnedByCascade(row, cascade)) continue;
        first = index;
        break;
    }
    const start = first orelse return null;
    var forward = start;
    while (forward < rows.len) : (forward += 1) {
        if (rowOwnedByCascade(rows[forward], cascade)) continue;
        if (survivingRowIdentity(rows[forward])) |identity| return identity;
    }
    var backward = start;
    while (backward > 0) {
        backward -= 1;
        if (rowOwnedByCascade(rows[backward], cascade)) continue;
        if (survivingRowIdentity(rows[backward])) |identity| return identity;
    }
    return null;
}

fn rowOwnedByCascade(row: buffer_mod.Row, cascade: []const bbr.review.TempId) bool {
    return switch (row) {
        .draft => |card| bbr.review.containsTempId(cascade, card.owner.draft),
        .snapshot => |snapshot| bbr.review.containsTempId(cascade, snapshot.draft.local_id),
        else => false,
    };
}

fn survivingRowIdentity(row: buffer_mod.Row) ?SurvivingRow {
    return switch (row) {
        .draft => |card| .{ .draft = card.owner.draft },
        .comment => |card| .{ .comment = card.owner.comment },
        else => if (lineAtRow(row)) |line| .{ .line = line } else null,
    };
}

fn followSurvivingRow(published: *Published, surviving: ?SurvivingRow) void {
    const wanted = surviving orelse return;
    for (published.buffer.rows, 0..) |row, index| {
        const identity = survivingRowIdentity(row) orelse continue;
        const matches = switch (wanted) {
            .draft => |temp_id| identity == .draft and identity.draft == temp_id,
            .comment => |id| identity == .comment and identity.comment == id,
            .line => |line| identity == .line and identity.line == line,
        };
        if (!matches) continue;
        published.navigation.jumpTo(index);
        return;
    }
}

/// Put the cursor back on `temp_id`'s ReviewCard wherever the reprojection put
/// it — identity, not a row number, survives a mutation.
fn followDraftCard(published: *Published, temp_id: bbr.review.TempId) void {
    for (published.buffer.rows, 0..) |row, index| {
        if (row != .draft or row.draft.owner.draft != temp_id or row.draft.part != .header) continue;
        published.navigation.jumpTo(index);
        return;
    }
}

/// The typed owner of the ReviewCard row under the cursor. Every row of a card
/// resolves to the same stable identity — a local TempId or a Bitbucket
/// CommentId — never a generic numeric id.
fn reviewCardTarget(published: *const Published) ?MutationTarget {
    if (published.navigation.cursor >= published.buffer.rows.len) return null;
    return switch (published.buffer.rows[published.navigation.cursor]) {
        .comment => |row| .{ .comment = row.owner.comment },
        .draft => |row| .{ .draft = row.owner.draft },
        else => null,
    };
}

fn findPublishedComment(published: *const Published, id: bbr.review.CommentId) ?*const bbr.review.Comment {
    for (published.session.threads) |thread| {
        if (thread.root.id == id) return thread.root;
        for (thread.replies) |reply| if (reply.id == id) return reply;
    }
    return null;
}

fn publishedReplyCount(published: *const Published, id: bbr.review.CommentId) usize {
    var count: usize = 0;
    for (published.session.threads) |thread| {
        if (thread.root.id == id) return thread.replies.len;
        for (thread.replies) |reply| {
            if (reply.parent_id == id) count += 1;
        }
    }
    return count;
}

fn lineAtRow(row: buffer_mod.Row) ?*const bbr.diff.Line {
    return switch (row) {
        .line => |line| line.line,
        .line_pair => |pair| if (pair.right) |right| right.line else if (pair.left) |left| left.line else null,
        else => null,
    };
}

fn clampSelectionAtStatusPlaceholder(published: *Published, previous_cursor: usize) void {
    if (!published.navigation.hasSelection()) return;
    const cursor = published.navigation.cursor;
    const target = selectionTarget(published.buffer.rows, previous_cursor, cursor);
    if (target != cursor) published.navigation.jumpTo(target);
}

fn selectionTarget(rows: []const buffer_mod.Row, from: usize, to: usize) usize {
    if (to > from) {
        var index = from + 1;
        while (index <= to and index < rows.len) : (index += 1) {
            if (rows[index] == .status_placeholder) return index - 1;
        }
    } else if (to < from) {
        var index = from;
        while (index > to) {
            index -= 1;
            if (rows[index] == .status_placeholder) return index + 1;
        }
    }
    return to;
}

const AnchorSpan = struct {
    from: ?u32 = null,
    to: ?u32 = null,
    start_from: ?u32 = null,
    start_to: ?u32 = null,
};

fn spanFromLines(lines: []const *const bbr.diff.Line, suggestion: bool) !AnchorSpan {
    if (lines.len == 0) return error.NotOnALine;
    if (lines.len > bbr.review.max_anchor_lines) return error.RangeTooLong;
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

test "Status Placeholder refuses Selection and clamps an active Selection before it" {
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
    const responses = [_]bbr.http.Canned{
        .{ .status = 404, .body = "" },
        .{ .status = 200, .body = "new\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
    var highlighter = TestNoopHighlighter{};
    const result = try file_enrichment.enrich(testing.allocator, client, highlighter.highlighter(), command.request());
    try presentation.dispatch(.{ .file_enrichment_completed = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = .{ .completed = result },
    } });

    try presentation.dispatch(.{ .action = .down });
    var projected = presentation.projection();
    try testing.expect(projected.review.?.buffer.rows[projected.review.?.navigation.cursor] == .status_placeholder);
    try testing.expect(!projected.action_availability.available(.toggle_select));
    try presentation.dispatch(.{ .action = .toggle_select });
    projected = presentation.projection();
    try testing.expect(projected.review.?.navigation.selection() == null);
    try testing.expectEqual(ActionError.source_action_unavailable, projected.action_error.?);

    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .toggle_select });
    try presentation.dispatch(.{ .action = .to_top });
    projected = presentation.projection();
    const selection = projected.review.?.navigation.selection().?;
    var index = selection[0];
    while (index <= selection[1]) : (index += 1) {
        try testing.expect(projected.review.?.buffer.rows[index] != .status_placeholder);
    }

    const content = projected.review.?.frame.panes.diff_content;
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 1, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = content.x, .row = content.y + 1, .button = .left, .type = .release } });
    projected = presentation.projection();
    try testing.expect(projected.review.?.buffer.rows[projected.review.?.navigation.cursor] != .status_placeholder);
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

test "initial inline authoring refuses oversized selections at the same boundary as re-anchor" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.initLocal(42, "refs/remotes/origin/main", "refs/heads/feature");
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try selectSource(&presentation, .new, 2, 32);
    try presentation.dispatch(.{ .action = .inline_comment });
    try testing.expectEqual(ActionError.anchor_range_too_long, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().composer == null);

    try selectSource(&presentation, .new, 2, 31);
    try presentation.dispatch(.{ .action = .inline_comment });
    try testing.expect(presentation.projection().composer != null);
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("boundary") } });
    try presentation.dispatch(.{ .composer = .save });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(@as(?u32, bbr.review.max_anchor_lines), drafts[0].effectiveScope().@"inline".span());
}

test "External Edit snapshots exactly once blocks input and accepts only matching completion" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.initLocal(42, "refs/remotes/origin/main", "refs/heads/feature");
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testLocalSession(testing.allocator) },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .review_comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("exact\nbody") } });
    try presentation.dispatch(.{ .composer = .external_edit });
    var command = presentation.takeCommand().?;
    try testing.expect(command == .external_edit);
    try testing.expectEqualStrings("exact\nbody", command.external_edit.body);
    try testing.expect(presentation.projection().composer.?.pending_external_edit);

    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("ignored") } });
    try testing.expectEqualStrings("exact\nbody", presentation.projection().composer.?.body);

    const stale = try ExternalEditCompleted.create(testing.allocator, command.external_edit.command_id + 1, command.external_edit.session_epoch);
    stale.outcome = .{ .changed = try stale.arena.allocator().dupe(u8, "stale") };
    try presentation.dispatch(.{ .external_edit_completed = stale });
    try testing.expectEqualStrings("exact\nbody", presentation.projection().composer.?.body);
    try testing.expect(presentation.projection().composer.?.pending_external_edit);

    const accepted = try ExternalEditCompleted.create(testing.allocator, command.external_edit.command_id, command.external_edit.session_epoch);
    accepted.outcome = .{ .changed = try accepted.arena.allocator().dupe(u8, "changed") };
    command.external_edit.destroy();
    command = undefined;
    try presentation.dispatch(.{ .external_edit_completed = accepted });
    try testing.expectEqualStrings("changed", presentation.projection().composer.?.body);
    try testing.expect(!presentation.projection().composer.?.pending_external_edit);
    try testing.expectEqualStrings("External Edit accepted", presentation.projection().composer.?.footer.?);
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

/// Move the DiffPane cursor onto the header row of `temp_id`'s ReviewCard.
fn cursorToDraftCard(presentation: *Presentation, temp_id: bbr.review.TempId) !void {
    const rows = presentation.projection().review.?.buffer.rows;
    for (rows, 0..) |row, index| {
        if (row != .draft or row.draft.owner.draft != temp_id or row.draft.part != .header) continue;
        const cursor = presentation.published.?.navigation.cursor;
        const action: Action = if (index >= cursor) .down else .up;
        const steps = if (index >= cursor) index - cursor else cursor - index;
        for (0..steps) |_| try presentation.dispatch(.{ .action = action });
        try testing.expectEqual(index, presentation.published.?.navigation.cursor);
        return;
    }
    return error.DraftCardNotFound;
}

/// Move the DiffPane cursor onto the header row of a published Comment's card.
fn cursorToCommentCard(presentation: *Presentation, comment_id: bbr.review.CommentId) !void {
    const rows = presentation.projection().review.?.buffer.rows;
    for (rows, 0..) |row, index| {
        if (row != .comment or row.comment.owner.comment != comment_id or row.comment.part != .header) continue;
        try moveToRow(presentation, index);
        return;
    }
    return error.CommentCardNotFound;
}

fn draftBody(presentation: *Presentation, temp_id: bbr.review.TempId) []const u8 {
    for (presentation.projection().review.?.drafts) |draft| {
        if (draft.local_id == temp_id) return draft.body;
    }
    return "";
}

test "editing a Draft Comment replaces its body and keeps its identity" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 5,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
        .body = "origin",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 5);
    // Every row of the card resolves to the same typed target, not just its
    // header, so editing from a body row edits the same Draft.
    try presentation.dispatch(.{ .action = .down });
    try testing.expect(presentation.published.?.buffer.rows[presentation.published.?.navigation.cursor].draft.owner.draft == 5);
    try testing.expect(presentation.projection().action_availability.available(.edit_review_item));

    try presentation.dispatch(.{ .action = .edit_review_item });
    const composer = presentation.projection().composer.?;
    try testing.expectEqualStrings("Edit local Draft", composer.label);
    try testing.expectEqualStrings("origin", composer.body);

    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" reworded") } });
    try presentation.dispatch(.{ .composer = .save });

    const drafts = presentation.projection().review.?.drafts;
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqual(@as(bbr.review.TempId, 5), drafts[0].local_id);
    try testing.expectEqualStrings("origin reworded", drafts[0].body);
    try testing.expect(drafts[0].parent == null);
    try testing.expectEqualStrings("a.zig", drafts[0].effectiveScope().@"inline".path);
    try testing.expect(presentation.projection().composer == null);
    // Navigation follows the same TempId through the reprojection.
    try testing.expect(presentation.published.?.buffer.rows[presentation.published.?.navigation.cursor].draft.owner.draft == 5);

    var resumed = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer resumed.deinit();
    try testing.expectEqualStrings("origin reworded", resumed.projection().review.?.drafts[0].body);
}

test "editing a Reply keeps its parent relationship" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "root" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "child" });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 2);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqualStrings("child", presentation.projection().composer.?.body);
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" again") } });
    try presentation.dispatch(.{ .composer = .save });

    const drafts = presentation.projection().review.?.drafts;
    try testing.expectEqualStrings("root", draftBody(&presentation, 1));
    try testing.expectEqualStrings("child again", draftBody(&presentation, 2));
    try testing.expect(drafts[1].parent.? == .draft and drafts[1].parent.?.draft == 1);
}

test "editing a Suggestion exposes replacement code and restores the fence" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 3,
        .kind = .suggestion,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
        .body = "```suggestion\nold code\n```",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 10,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 3);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqualStrings("old code", presentation.projection().composer.?.body);
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("r") } });
    try presentation.dispatch(.{ .composer = .save });

    const draft = presentation.projection().review.?.drafts[0];
    try testing.expect(draft.kind == .suggestion);
    try testing.expectEqualStrings("```suggestion\nold coder\n```", draft.body);
}

test "a blank edit is refused and an identical edit is a clean no-op" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .body = "keep",
        .state = .{ .failed = error.ServerError },
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .edit_review_item });
    for (0..4) |_| try presentation.dispatch(.{ .composer = .backspace });
    try presentation.dispatch(.{ .composer = .save });
    // Blank content is refused by creation's rule: the Composer stays open.
    try testing.expect(presentation.projection().composer != null);

    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("keep") } });
    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .composer = .save });

    const after = presentation.projection();
    try testing.expect(after.composer == null);
    try testing.expect(after.action_error == null);
    // No persistence and no state change: the failure evidence survives.
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expectEqual(bbr.bitbucket.ApiError.ServerError, after.review.?.drafts[0].state.failed);
    try testing.expectEqualStrings("keep", after.review.?.drafts[0].body);
}

test "a real edit of a failed Draft resets it to draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .body = "rejected",
        .state = .{ .failed = error.ServerError },
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" once more") } });
    try presentation.dispatch(.{ .composer = .save });

    try testing.expect(presentation.projection().review.?.drafts[0].state == .draft);

    var resumed = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer resumed.deinit();
    try testing.expect(resumed.projection().review.?.drafts[0].state == .draft);
}

test "edit stays discoverable but refuses Drafts an active SubmissionRun owns" {
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
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    const command = presentation.takeCommand().?.post_draft;
    defer command.destroy();

    // The in-flight item and the not-yet-posted participant are both immutable.
    try cursorToDraftCard(&presentation, 1);
    try testing.expect(!presentation.projection().action_availability.available(.edit_review_item));
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqual(ActionError.draft_submission_in_flight, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().composer == null);

    try cursorToDraftCard(&presentation, 2);
    try testing.expect(!presentation.projection().action_availability.available(.edit_review_item));
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqual(ActionError.draft_owned_by_submission, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().composer == null);
    try testing.expectEqualStrings("second", draftBody(&presentation, 2));
}

test "edit refuses a Draft a recovered SubmissionRun still owns" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "in flight" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "queued" });
    try store.store().put(key.storeKey(), .{ .local_id = 3, .kind = .comment, .body = "bystander" });
    // An interrupted run left behind by a previous process.
    _ = try store.store().beginSubmission(key.storeKey(), "source", &.{
        .{ .temp_id = 1, .parent = null },
        .{ .temp_id = 2, .parent = null },
    });

    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 14,
    });
    defer presentation.deinit();
    try testing.expect(presentation.projection().recovery != null);

    try cursorToDraftCard(&presentation, 2);
    try testing.expect(!presentation.projection().action_availability.available(.edit_review_item));
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqual(ActionError.draft_owned_by_submission, presentation.projection().action_error.?);

    // A Draft outside the frozen graph stays editable.
    try cursorToDraftCard(&presentation, 3);
    try testing.expect(presentation.projection().action_availability.available(.edit_review_item));
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("!") } });
    try presentation.dispatch(.{ .composer = .save });
    try testing.expectEqualStrings("bystander!", draftBody(&presentation, 3));
}

test "edit refuses posted and unresolved Drafts with their own reasons" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "unknown", .state = .outcome_unknown });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "in a batch" });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqual(ActionError.draft_outcome_unresolved, presentation.projection().action_error.?);

    // The transient `posted` window of a partial batch, before Reconciliation
    // replaces the Draft's row with the published Comment.
    try cursorToDraftCard(&presentation, 2);
    presentation.published.?.review.setState(2, .{ .posted = 42 });
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqual(ActionError.draft_already_published, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().composer == null);
}

test "edit away from a ReviewCard reports having no target" {
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

    try testing.expect(!presentation.projection().action_availability.available(.edit_review_item));
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqual(ActionError.no_review_item, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().composer == null);
}

test "a failed edit preserves the previous Frame and the attempted body" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .body = "original",
        .state = .{ .failed = error.ServerError },
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" retried") } });
    const before = presentation.projection().review.?;

    store.fail_next_edit = true;
    try presentation.dispatch(.{ .composer = .save });

    const failed = presentation.projection();
    try testing.expectEqual(ActionError.persistence_failed, failed.action_error.?);
    try testing.expectEqualStrings("original retried", failed.composer.?.body);
    try testing.expectEqualStrings("original", failed.review.?.drafts[0].body);
    try testing.expectEqual(bbr.bitbucket.ApiError.ServerError, failed.review.?.drafts[0].state.failed);
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, failed.review.?.navigation));

    // The retained interaction retries successfully.
    try presentation.dispatch(.{ .composer = .save });
    try testing.expect(presentation.projection().composer == null);
    try testing.expectEqualStrings("original retried", presentation.projection().review.?.drafts[0].body);
    try testing.expect(presentation.projection().review.?.drafts[0].state == .draft);
}

test "an edit staged against a changed graph is refused, keeping the Composer" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "root" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "child" });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 2);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" edited") } });
    // Another writer re-parents the same Draft under the staged edit.
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .comment = 9 }, .body = "child" });
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .composer = .save });

    const failed = presentation.projection();
    try testing.expectEqual(ActionError.draft_edit_conflict, failed.action_error.?);
    try testing.expectEqualStrings("child edited", failed.composer.?.body);
    try testing.expectEqualStrings("child", draftBody(&presentation, 2));
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
}

/// One File with four removed and forty added lines: enough source to exercise
/// both sides, ranges, and the 30-line Anchor boundary.
fn testWideSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try testSession(backing, id, 'w');
    errdefer s.destroy();
    const a = s.arena.allocator();
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, "diff --git a/wide.zig b/wide.zig\n--- a/wide.zig\n+++ b/wide.zig\n@@ -1,4 +1,40 @@\n");
    for (0..4) |index| try raw.print(a, "-removed {d}\n", .{index + 1});
    for (0..40) |index| try raw.print(a, "+added {d}\n", .{index + 1});
    s.diff = try bbr.diff.parse(a, raw.items);
    return s;
}

fn testCommentSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try testSession(backing, id, 'a');
    errdefer s.destroy();
    const a = s.arena.allocator();
    const comments = try a.alloc(bbr.review.Comment, 1);
    comments[0] = .{
        .id = 99,
        .author = "Author",
        .author_uuid = "{me}",
        .body = "published",
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1 } },
    };
    s.threads = try bbr.review.buildThreads(a, comments);
    s.authenticated_account_uuid = "{me}";
    return s;
}

test "stale repair requires the exact authored old and new side ranges" {
    const s = try testWideSession(testing.allocator, 1);
    defer s.destroy();

    try testing.expect(scopeAnchorExists(s.diff, .{ .path = "wide.zig", .start_from = 1, .from = 4, .commit = "destination" }));
    try testing.expect(scopeAnchorExists(s.diff, .{ .path = "wide.zig", .start_to = 1, .to = 30, .commit = "source" }));
    try testing.expect(!scopeAnchorExists(s.diff, .{ .path = "wide.zig", .start_to = 1, .to = 41, .commit = "source" }));
    try testing.expect(!scopeAnchorExists(s.diff, .{ .path = "other.zig", .start_from = 1, .from = 4, .commit = "destination" }));
}

fn testCommentThreadSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try testSession(backing, id, 'a');
    errdefer s.destroy();
    const a = s.arena.allocator();
    const comments = try a.alloc(bbr.review.Comment, 2);
    comments[0] = .{
        .id = 99,
        .author = "Author",
        .author_uuid = "{me}",
        .body = "published",
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1 } },
    };
    comments[1] = .{
        .id = 100,
        .parent_id = 99,
        .author = "Author",
        .author_uuid = "{me}",
        .body = "reply",
    };
    s.threads = try bbr.review.buildThreads(a, comments);
    s.authenticated_account_uuid = "{me}";
    return s;
}

test "author-owned root deletion confirms tombstone consequence and reconciles without local cascade" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentThreadSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .delete_review_item });
    const confirmation = presentation.projection().delete_confirmation.?;
    try testing.expectEqual(@as(?bbr.review.CommentId, 99), confirmation.comment_id);
    try testing.expectEqual(@as(usize, 1), confirmation.descendant_count);
    try presentation.dispatch(.{ .delete_confirmation = .confirm });

    var command = presentation.takeCommand().?;
    try testing.expect(command == .delete_comment);
    try testing.expectEqual(@as(bbr.review.CommentId, 99), command.delete_comment.comment_id);
    try testing.expect(findPublishedComment(presentation.published.?, 99) != null);
    try testing.expect(findPublishedComment(presentation.published.?, 100) != null);
    try presentation.dispatch(.{ .comment_delete_completed = .{
        .command_id = command.delete_comment.command_id,
        .identity = command.delete_comment.identity,
        .comment_id = 99,
        .outcome = .deleted,
    } });
    command.delete_comment.destroy();
    command = undefined;
    try testing.expect(presentation.takeCommand().?.load_session.cause == .reconciliation);
}

test "Reply deletion confirms only the named Comment and definitive failure restores confirmation" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentThreadSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToCommentCard(&presentation, 100);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(@as(?bbr.review.CommentId, 100), presentation.projection().delete_confirmation.?.comment_id);
    try testing.expectEqual(@as(usize, 0), presentation.projection().delete_confirmation.?.descendant_count);
    try presentation.dispatch(.{ .delete_confirmation = .confirm });
    var command = presentation.takeCommand().?;
    try presentation.dispatch(.{ .comment_delete_completed = .{
        .command_id = command.delete_comment.command_id,
        .identity = command.delete_comment.identity,
        .comment_id = 100,
        .outcome = .{ .definitive_failure = error.Forbidden },
    } });
    command.delete_comment.destroy();
    command = undefined;
    try testing.expectEqual(ActionError.comment_delete_failed, presentation.projection().action_error.?);
    try testing.expectEqual(@as(?bbr.review.CommentId, 100), presentation.projection().delete_confirmation.?.comment_id);
}

test "delete not-found and unknown outcomes reconcile and failed reload gates the stale Session" {
    inline for (.{ CommentDeleteOutcome.not_found, CommentDeleteOutcome.outcome_unknown }) |outcome| {
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
        var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
            .viewport_rows = 12,
        });
        defer presentation.deinit();
        try cursorToCommentCard(&presentation, 99);
        try presentation.dispatch(.{ .action = .delete_review_item });
        try presentation.dispatch(.{ .delete_confirmation = .confirm });
        var command = presentation.takeCommand().?;
        try presentation.dispatch(.{ .comment_delete_completed = .{
            .command_id = command.delete_comment.command_id,
            .identity = command.delete_comment.identity,
            .comment_id = 99,
            .outcome = outcome,
        } });
        command.delete_comment.destroy();
        command = undefined;
        const reconcile = presentation.takeCommand().?.load_session;
        try presentation.dispatch(.{ .session_loaded = .{
            .command_id = reconcile.command_id,
            .intent = reconcile.intent,
            .outcome = .{ .failed = error.NetworkFailure },
        } });
        try testing.expectEqual(.reload_required, presentation.projection().comment_delete_result.?.outcome);
        try testing.expectEqual(MutationRefusal.authoritative_reload_required, presentation.projection().action_availability.delete_refusal.?);
    }
}

test "published deletion owns the global lane and survives Session replacement" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const first_key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    const second_key = try OwnedReviewIdentity.init("workspace", "repo", 2);
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = first_key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();
    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try presentation.dispatch(.{ .delete_confirmation = .confirm });
    var deletion = presentation.takeCommand().?;

    try presentation.dispatch(.{ .action = .submit });
    try testing.expectEqual(ActionError.remote_write_busy, presentation.projection().action_error.?);
    try presentation.dispatch(.{ .choose_pull_request = second_key });
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .command_id = load.command_id,
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try presentation.dispatch(.{ .comment_delete_completed = .{
        .command_id = deletion.delete_comment.command_id,
        .identity = deletion.delete_comment.identity,
        .comment_id = 99,
        .outcome = .deleted,
    } });
    deletion.delete_comment.destroy();
    deletion = undefined;

    const result = presentation.projection().comment_delete_result.?;
    try testing.expect(OwnedReviewIdentity.eql(first_key, result.key));
    try testing.expectEqual(.deleted, result.outcome);
    try testing.expect(presentation.takeCommand() == null);
}

test "author-owned published Comment edit queues exact body and reconciles authoritatively" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToCommentCard(&presentation, 99);
    try testing.expect(presentation.projection().action_availability.available(.edit_review_item));
    try presentation.dispatch(.{ .action = .edit_review_item });
    try testing.expectEqualStrings("Edit Bitbucket Comment", presentation.projection().composer.?.label);
    try testing.expectEqualStrings("published", presentation.projection().composer.?.body);
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" edited") } });
    try presentation.dispatch(.{ .composer = .save });

    var command = presentation.takeCommand().?;
    try testing.expect(command == .update_comment);
    try testing.expectEqual(@as(bbr.review.CommentId, 99), command.update_comment.comment_id);
    try testing.expectEqualStrings("published edited", command.update_comment.body);
    try presentation.dispatch(.{ .comment_edit_completed = .{
        .command_id = command.update_comment.command_id,
        .identity = command.update_comment.identity,
        .comment_id = 99,
        .outcome = .updated,
    } });
    command.update_comment.destroy();
    command = undefined;

    const reconcile = presentation.takeCommand().?.load_session;
    try testing.expect(reconcile.cause == .reconciliation);
    try testing.expectEqualStrings("published", findPublishedComment(presentation.published.?, 99).?.body);
}

test "published edit ownership fails closed for missing evidence and other authors" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    const s = try testCommentSession(testing.allocator, 1);
    s.authenticated_account_uuid = null;
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = s },
        .viewport_rows = 12,
    });
    defer presentation.deinit();
    try cursorToCommentCard(&presentation, 99);
    try testing.expectEqual(MutationRefusal.authenticated_account_unknown, presentation.projection().action_availability.edit_refusal.?);

    presentation.authenticated_account_uuid = try BoundedText(256).init("{other}");
    try testing.expectEqual(MutationRefusal.comment_owned_by_other, presentation.projection().action_availability.edit_refusal.?);
}

test "definitive published edit failure restores exact attempted bytes" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();
    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" attempted") } });
    try presentation.dispatch(.{ .composer = .save });
    var command = presentation.takeCommand().?;
    try presentation.dispatch(.{ .comment_edit_completed = .{
        .command_id = command.update_comment.command_id,
        .identity = command.update_comment.identity,
        .comment_id = 99,
        .outcome = .{ .definitive_failure = error.Forbidden },
    } });
    command.update_comment.destroy();
    command = undefined;

    try testing.expectEqualStrings("Edit Bitbucket Comment", presentation.projection().composer.?.label);
    try testing.expectEqualStrings("published attempted", presentation.projection().composer.?.body);
    try testing.expectEqual(ActionError.comment_edit_failed, presentation.projection().action_error.?);
}

test "unknown edit delivery reconciles and failed Reconciliation gates the stale Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();
    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" maybe") } });
    try presentation.dispatch(.{ .composer = .save });
    var update = presentation.takeCommand().?;
    try presentation.dispatch(.{ .comment_edit_completed = .{
        .command_id = update.update_comment.command_id,
        .identity = update.update_comment.identity,
        .comment_id = 99,
        .outcome = .outcome_unknown,
    } });
    update.update_comment.destroy();
    update = undefined;
    try testing.expectEqual(.outcome_unknown, presentation.projection().comment_edit_result.?.outcome);

    const reconcile = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .command_id = reconcile.command_id,
        .intent = reconcile.intent,
        .outcome = .{ .failed = error.NetworkFailure },
    } });
    try testing.expectEqual(.reload_required, presentation.projection().comment_edit_result.?.outcome);
    try testing.expectEqual(MutationRefusal.authoritative_reload_required, presentation.projection().action_availability.edit_refusal.?);
}

test "published edit owns the global remote-write lane against Submission" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();
    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" lane") } });
    try presentation.dispatch(.{ .composer = .save });

    try presentation.dispatch(.{ .action = .submit });
    try testing.expectEqual(ActionError.remote_write_busy, presentation.projection().action_error.?);
}

test "published edit completion survives Session replacement as a qualified result" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const first_key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    const second_key = try OwnedReviewIdentity.init("workspace", "repo", 2);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = first_key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();
    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .edit_review_item });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init(" durable") } });
    try presentation.dispatch(.{ .composer = .save });
    var update = presentation.takeCommand().?;

    try presentation.dispatch(.{ .choose_pull_request = second_key });
    const load = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .command_id = load.command_id,
        .intent = load.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try presentation.dispatch(.{ .comment_edit_completed = .{
        .command_id = update.update_comment.command_id,
        .identity = update.update_comment.identity,
        .comment_id = 99,
        .outcome = .updated,
    } });
    update.update_comment.destroy();
    update = undefined;

    const result = presentation.projection().comment_edit_result.?;
    try testing.expect(OwnedReviewIdentity.eql(first_key, result.key));
    try testing.expectEqual(.updated, result.outcome);
    try testing.expect(presentation.takeCommand() == null);
}

fn sourceRow(presentation: *Presentation, side: AnchorSide, number: u32) !usize {
    for (presentation.projection().review.?.buffer.rows, 0..) |row, index| {
        const line = lineAtRow(row) orelse continue;
        switch (side) {
            .new => if (line.new_no == number) return index,
            .old => if (line.old_no == number and line.new_no == null) return index,
        }
    }
    return error.SourceRowNotFound;
}

/// Put the cursor on `side`:`number` and, when `through` is larger, extend a
/// Selection down to it.
fn selectSource(presentation: *Presentation, side: AnchorSide, number: u32, through: u32) !void {
    try presentation.dispatch(.{ .action = .clear_selection });
    try moveToRow(presentation, try sourceRow(presentation, side, number));
    if (through <= number) return;
    try presentation.dispatch(.{ .action = .toggle_select });
    for (number..through) |_| try presentation.dispatch(.{ .action = .down });
}

fn draftAnchor(presentation: *Presentation, temp_id: bbr.review.TempId) bbr.review.Anchor {
    for (presentation.projection().review.?.drafts) |draft| {
        if (draft.local_id == temp_id) return draft.effectiveScope().@"inline";
    }
    unreachable;
}

test "re-anchoring an inline root Draft replaces its Anchor and keeps its subtree" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "this belongs elsewhere",
        .state = .{ .failed = error.ServerError },
    });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "agreed" });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try testing.expect(presentation.projection().action_availability.available(.reanchor_review_item));
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    // Stage one retains the Draft while navigation returns to the DiffPane.
    try testing.expectEqual(@as(bbr.review.TempId, 1), presentation.projection().reanchor.?.temp_id);

    try selectSource(&presentation, .new, 5, 7);
    const armed = presentation.projection().reanchor.?;
    try testing.expectEqualStrings("wide.zig", armed.candidate.?.path);
    try testing.expect(armed.candidate.?.side == .new);
    try testing.expectEqual(@as(u32, 5), armed.candidate.?.top);
    try testing.expectEqual(@as(u32, 7), armed.candidate.?.bottom);
    try testing.expect(armed.refusal == null);

    try presentation.dispatch(.{ .reanchor = .accept });

    const after = presentation.projection();
    try testing.expect(after.reanchor == null);
    try testing.expect(after.action_error == null);
    const anchor = draftAnchor(&presentation, 1);
    try testing.expectEqualStrings("wide.zig", anchor.path);
    try testing.expectEqual(@as(?u32, 5), anchor.start_to);
    try testing.expectEqual(@as(?u32, 7), anchor.to);
    try testing.expectEqualStrings("source", anchor.commit.?);
    // Identity, body, kind, and the Reply subtree survive; the failure resets.
    try testing.expectEqualStrings("this belongs elsewhere", draftBody(&presentation, 1));
    try testing.expect(after.review.?.drafts[0].state == .draft);
    try testing.expectEqual(@as(usize, 2), after.review.?.drafts.len);
    try testing.expect(after.review.?.drafts[1].parent.?.draft == 1);
    // Success follows the TempId to its new ReviewCard.
    const cursor_row = presentation.published.?.buffer.rows[presentation.published.?.navigation.cursor];
    try testing.expect(cursor_row == .draft and cursor_row.draft.owner.draft == 1);

    var resumed = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer resumed.deinit();
    try testing.expectEqual(@as(?u32, 5), draftAnchor(&resumed, 1).start_to);
    try testing.expectEqual(@as(?u32, 7), draftAnchor(&resumed, 1).to);
}

test "cancelling an armed re-anchor changes nothing" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "keep me here",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .new, 9, 11);
    try presentation.dispatch(.{ .reanchor = .cancel });

    const after = presentation.projection();
    try testing.expect(after.reanchor == null);
    try testing.expect(after.action_error == null);
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 1).to);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
}

test "an identical replacement Anchor is a clean no-op" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 3, .commit = "source" } },
        .body = "already right",
        .state = .{ .failed = error.ServerError },
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .new, 3, 3);
    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .reanchor = .accept });

    const after = presentation.projection();
    try testing.expect(after.reanchor == null);
    try testing.expect(after.action_error == null);
    // Nothing persisted and no reprojection: the failure evidence survives.
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expectEqual(bbr.bitbucket.ApiError.ServerError, after.review.?.drafts[0].state.failed);
    try testing.expectEqual(@as(?u32, 3), draftAnchor(&presentation, 1).to);
}

test "re-anchoring accepts an old-side Comment range and refuses an old-side Suggestion" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "about the removed code",
    });
    try store.store().put(key.storeKey(), .{
        .local_id = 2,
        .kind = .suggestion,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "```suggestion\nadded 1\n```",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .old, 2, 3);
    try presentation.dispatch(.{ .reanchor = .accept });

    const old_side = draftAnchor(&presentation, 1);
    try testing.expectEqual(@as(?u32, 2), old_side.start_from);
    try testing.expectEqual(@as(?u32, 3), old_side.from);
    try testing.expectEqual(@as(?u32, null), old_side.to);
    // An old-side Anchor binds the base commit, not the source commit.
    try testing.expectEqualStrings("destination", old_side.commit.?);

    try cursorToDraftCard(&presentation, 2);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .old, 2, 2);
    try testing.expectEqual(ActionError.suggestion_anchor_not_new_side, presentation.projection().reanchor.?.refusal.?);
    try presentation.dispatch(.{ .reanchor = .accept });

    try testing.expectEqual(ActionError.suggestion_anchor_not_new_side, presentation.projection().action_error.?);
    // The interaction stays armed so the reviewer can pick a new-side range.
    try testing.expectEqual(@as(bbr.review.TempId, 2), presentation.projection().reanchor.?.temp_id);
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 2).to);
}

test "an accepted Anchor covers at most thirty inclusive lines" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "wide",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .new, 2, 32);
    try testing.expectEqual(ActionError.anchor_range_too_long, presentation.projection().reanchor.?.refusal.?);
    try presentation.dispatch(.{ .reanchor = .accept });
    try testing.expectEqual(ActionError.anchor_range_too_long, presentation.projection().action_error.?);
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 1).to);

    // One line shorter is exactly the boundary and is accepted.
    try selectSource(&presentation, .new, 2, 31);
    try presentation.dispatch(.{ .reanchor = .accept });
    const anchor = draftAnchor(&presentation, 1);
    try testing.expectEqual(@as(?u32, 2), anchor.start_to);
    try testing.expectEqual(@as(?u32, 31), anchor.to);
    try testing.expectEqual(@as(?u32, bbr.review.max_anchor_lines), anchor.span());
}

test "re-anchoring refuses mixed-side and cross-File source ranges" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "wide",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    // The last removed line through the first added line: two sides at once.
    try moveToRow(&presentation, try sourceRow(&presentation, .old, 4));
    try presentation.dispatch(.{ .action = .toggle_select });
    try presentation.dispatch(.{ .action = .down });
    try testing.expectEqual(ActionError.anchor_candidate_ambiguous, presentation.projection().reanchor.?.refusal.?);
    try presentation.dispatch(.{ .reanchor = .accept });
    try testing.expectEqual(ActionError.anchor_candidate_ambiguous, presentation.projection().action_error.?);
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 1).to);

    var two_file = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testTwoFileSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer two_file.deinit();
    try two_file.dispatch(.{ .action = .reanchor_review_item });
    try testing.expectEqual(ActionError.no_review_item, two_file.projection().action_error.?);
}

/// One File whose two hunks leave an unshown gap between line 2 and line 20.
fn testHunkGapSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try testSession(backing, id, 'g');
    errdefer s.destroy();
    s.diff = try bbr.diff.parse(s.arena.allocator(),
        \\diff --git a/gap.zig b/gap.zig
        \\--- a/gap.zig
        \\+++ b/gap.zig
        \\@@ -1,2 +1,2 @@
        \\-old a
        \\+new a
        \\ context a
        \\@@ -20,2 +20,2 @@
        \\-old b
        \\+new b
        \\ context b
    );
    return s;
}

test "a Selection that crosses a hidden hunk gap is refused" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "gap.zig", .to = 1, .commit = "source" } },
        .body = "across the gap",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testHunkGapSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 40 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });

    // Both ends are real new-side lines; only the unshown lines between them
    // make the range a guess.
    const top = try sourceRow(&presentation, .new, 2);
    const bottom = try sourceRow(&presentation, .new, 20);
    try moveToRow(&presentation, top);
    try presentation.dispatch(.{ .action = .toggle_select });
    for (top..bottom) |_| try presentation.dispatch(.{ .action = .down });

    try testing.expectEqual(ActionError.anchor_candidate_ambiguous, presentation.projection().reanchor.?.refusal.?);
    try presentation.dispatch(.{ .reanchor = .accept });
    try testing.expectEqual(ActionError.anchor_candidate_ambiguous, presentation.projection().action_error.?);
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 1).to);

    // Either side of the gap on its own is a perfectly good Anchor.
    try selectSource(&presentation, .new, 20, 21);
    try presentation.dispatch(.{ .reanchor = .accept });
    const anchor = draftAnchor(&presentation, 1);
    try testing.expectEqual(@as(?u32, 20), anchor.start_to);
    try testing.expectEqual(@as(?u32, 21), anchor.to);
}

test "re-anchoring a Draft in a LocalReview captures replacement authored evidence" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.initLocal(42, "refs/remotes/origin/main", "refs/heads/feature");
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .target = .local,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .from = 1, .commit = "base" } },
        .snapshot = .{ .text = "authored elsewhere", .selection_start = 0, .selection_len = 1 },
        .body = "local note",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testLocalSession(testing.allocator) },
        .viewport_rows = 12,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .new, 1, 1);
    try presentation.dispatch(.{ .reanchor = .accept });

    const draft = presentation.projection().review.?.drafts[0];
    try testing.expectEqual(@as(?u32, 1), draft.effectiveScope().@"inline".to);
    try testing.expectEqualStrings("source", draft.effectiveScope().@"inline".commit.?);
    try testing.expectEqualStrings("old\nnew", draft.snapshot.?.text);
    try testing.expectEqual(@as(u32, 1), draft.snapshot.?.selection_start);
    try testing.expectEqual(@as(u32, 1), draft.snapshot.?.selection_len);
}

test "re-anchor stays discoverable but names why each ineligible item refuses it" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
        .body = "root",
    });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
    try store.store().put(key.storeKey(), .{ .local_id = 3, .kind = .comment, .scope = .review, .body = "review level" });
    try store.store().put(key.storeKey(), .{
        .local_id = 4,
        .kind = .comment,
        .scope = .{ .file = .{ .path = "a.zig", .source_commit = "source" } },
        .body = "file level",
    });
    try store.store().put(key.storeKey(), .{
        .local_id = 5,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
        .body = "unknown",
        .state = .outcome_unknown,
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    const refusals = [_]struct { temp_id: bbr.review.TempId, err: ActionError }{
        .{ .temp_id = 2, .err = .draft_reply_has_no_anchor },
        .{ .temp_id = 3, .err = .draft_scope_not_inline },
        .{ .temp_id = 4, .err = .draft_scope_not_inline },
        .{ .temp_id = 5, .err = .draft_outcome_unresolved },
    };
    for (refusals) |refusal| {
        try cursorToDraftCard(&presentation, refusal.temp_id);
        try testing.expect(!presentation.projection().action_availability.available(.reanchor_review_item));
        try presentation.dispatch(.{ .action = .reanchor_review_item });
        try testing.expectEqual(refusal.err, presentation.projection().action_error.?);
        try testing.expect(presentation.projection().reanchor == null);
    }

    // A published Bitbucket Comment is Bitbucket's to place, not ours.
    var comment_row: usize = 0;
    for (presentation.projection().review.?.buffer.rows, 0..) |row, index| if (row == .comment) {
        comment_row = index;
        break;
    };
    try moveToRow(&presentation, comment_row);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try testing.expectEqual(ActionError.published_comment_edit_unsupported, presentation.projection().action_error.?);

    // The eligible root keeps the Action available.
    try cursorToDraftCard(&presentation, 1);
    try testing.expect(presentation.projection().action_availability.available(.reanchor_review_item));
}

test "re-anchor refuses a Draft an active SubmissionRun owns" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "in flight",
    });
    try store.store().put(key.storeKey(), .{
        .local_id = 2,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 2, .commit = "source" } },
        .body = "queued",
    });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    const command = presentation.takeCommand().?.post_draft;
    defer command.destroy();

    try cursorToDraftCard(&presentation, 1);
    try testing.expect(!presentation.projection().action_availability.available(.reanchor_review_item));
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try testing.expectEqual(ActionError.draft_submission_in_flight, presentation.projection().action_error.?);

    try cursorToDraftCard(&presentation, 2);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try testing.expectEqual(ActionError.draft_owned_by_submission, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().reanchor == null);
}

test "the armed re-anchor keeps DiffPane keys and claims only Enter and Escape" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "by key",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    // Escape cancels without mutating, and Enter is a plain disclosure toggle
    // again afterwards rather than an acceptance.
    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .key = .{ .codepoint = 'a', .text = "a" } });
    try testing.expect(presentation.projection().reanchor != null);
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.escape } });
    try testing.expect(presentation.projection().reanchor == null);
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 1).to);

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .key = .{ .codepoint = 'a', .text = "a" } });
    try moveToRow(&presentation, try sourceRow(&presentation, .new, 3));
    // Motions and Selection still resolve normally while armed.
    try presentation.dispatch(.{ .key = .{ .codepoint = 'v', .text = "v" } });
    try presentation.dispatch(.{ .key = .{ .codepoint = 'j', .text = "j" } });
    try testing.expectEqual(@as(u32, 4), presentation.projection().reanchor.?.candidate.?.bottom);
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.enter } });

    try testing.expect(presentation.projection().reanchor == null);
    const anchor = draftAnchor(&presentation, 1);
    try testing.expectEqual(@as(?u32, 3), anchor.start_to);
    try testing.expectEqual(@as(?u32, 4), anchor.to);
}

test "a re-anchored Draft survives Session replacement, which disarms an armed capture" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "repaired",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .new, 12, 13);
    try presentation.dispatch(.{ .reanchor = .accept });

    // Arm again, then replace the Session underneath the armed capture.
    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try testing.expect(presentation.projection().reanchor != null);
    try presentation.dispatch(.{ .action = .refresh });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testWideSession(testing.allocator, 1) },
    } });

    try testing.expect(presentation.projection().reanchor == null);
    const anchor = draftAnchor(&presentation, 1);
    try testing.expectEqual(@as(?u32, 12), anchor.start_to);
    try testing.expectEqual(@as(?u32, 13), anchor.to);
}

test "a failed re-anchor preserves the previous Frame and the armed candidate" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .body = "unmoved",
        .state = .{ .failed = error.ServerError },
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .viewport_rows = 20,
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .reanchor_review_item });
    try selectSource(&presentation, .new, 6, 8);
    const before = presentation.projection().review.?;

    store.fail_next_reanchor = true;
    try presentation.dispatch(.{ .reanchor = .accept });

    const failed = presentation.projection();
    try testing.expectEqual(ActionError.persistence_failed, failed.action_error.?);
    // The Draft, its ScopeProjection, and the Frame are exactly as they were,
    // and the reviewer's candidate is still armed.
    try testing.expectEqual(@as(?u32, 1), draftAnchor(&presentation, 1).to);
    try testing.expectEqual(bbr.bitbucket.ApiError.ServerError, failed.review.?.drafts[0].state.failed);
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, failed.review.?.navigation));
    try testing.expectEqual(@as(u32, 6), failed.reanchor.?.candidate.?.top);

    // The retained interaction retries successfully.
    try presentation.dispatch(.{ .reanchor = .accept });
    try testing.expect(presentation.projection().reanchor == null);
    try testing.expectEqual(@as(?u32, 8), draftAnchor(&presentation, 1).to);
    try testing.expect(presentation.projection().review.?.drafts[0].state == .draft);
}

/// A root inline Draft on `wide.zig` line 1 with a two-deep Reply chain and an
/// unrelated bystander root, so a cascade has something to spare.
fn seedDeletableSubtree(store: bbr.review.PendingReviewStore, key: OwnedReviewIdentity) !void {
    try store.put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 1, .commit = "source" } },
        .snapshot = .{ .text = "added 1", .selection_start = 0, .selection_len = 1 },
        .body = "root",
    });
    try store.put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .parent = .{ .draft = 1 }, .body = "reply" });
    try store.put(key.storeKey(), .{ .local_id = 3, .kind = .comment, .parent = .{ .draft = 2 }, .body = "deep reply" });
    try store.put(key.storeKey(), .{
        .local_id = 4,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 2, .commit = "source" } },
        .body = "bystander",
    });
}

/// How many distinct Drafts still own a ReviewCard header row.
fn draftCardCount(presentation: *Presentation) usize {
    var count: usize = 0;
    for (presentation.projection().review.?.buffer.rows) |row| {
        if (row == .draft and row.draft.part == .header) count += 1;
    }
    return count;
}

fn sidebarDraftCount(presentation: *Presentation) usize {
    var count: usize = 0;
    for (presentation.published.?.tree.entries) |entry| {
        if (entry.identity == .file) count += entry.drafts;
    }
    return count;
}

fn draftTempIds(presentation: *Presentation, out: []bbr.review.TempId) []const bbr.review.TempId {
    const drafts = presentation.projection().review.?.drafts;
    for (drafts, 0..) |draft, index| out[index] = draft.local_id;
    return out[0..drafts.len];
}

test "deleting a root Draft removes its complete Reply-descendant subtree" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try testing.expect(presentation.projection().action_availability.available(.delete_review_item));
    try presentation.dispatch(.{ .action = .delete_review_item });

    // The confirmation names the local TempId and the complete consequence.
    const confirmation = presentation.projection().delete_confirmation.?;
    try testing.expectEqual(@as(bbr.review.TempId, 1), confirmation.temp_id);
    try testing.expectEqual(@as(usize, 2), confirmation.descendant_count);
    // The Sidebar tallies anchored roots: two before, one after.
    try testing.expectEqual(@as(usize, 2), sidebarDraftCount(&presentation));

    try presentation.dispatch(.{ .delete_confirmation = .confirm });

    const after = presentation.projection();
    try testing.expect(after.delete_confirmation == null);
    try testing.expect(after.action_error == null);
    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{4}, draftTempIds(&presentation, &ids));
    // PendingReview nodes, ScopeProjection entries, ReviewCard rows, and the
    // Sidebar counts all move together, only after durable success.
    try testing.expectEqual(@as(usize, 1), presentation.published.?.scope_projection.items.len);
    try testing.expectEqual(@as(bbr.review.TempId, 4), presentation.published.?.scope_projection.items[0].temp_id);
    try testing.expectEqual(@as(usize, 1), draftCardCount(&presentation));
    try testing.expectEqual(@as(usize, 1), sidebarDraftCount(&presentation));

    // A fresh Session over the same store proves it is durably gone, and the
    // deleted TempIds are never handed out again.
    var resumed = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer resumed.deinit();
    try testing.expectEqualSlices(bbr.review.TempId, &.{4}, draftTempIds(&resumed, &ids));
    try testing.expectEqual(@as(bbr.review.TempId, 5), try store.store().reserveTempId(key.storeKey()));
}

test "deleting a leaf Reply keeps its root and every sibling" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 3);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(@as(usize, 0), presentation.projection().delete_confirmation.?.descendant_count);
    try presentation.dispatch(.{ .delete_confirmation = .confirm });

    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 4 }, draftTempIds(&presentation, &ids));
    try testing.expectEqualStrings("root", draftBody(&presentation, 1));
}

test "cancelling a delete confirmation changes nothing" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .action = .delete_review_item });
    try presentation.dispatch(.{ .delete_confirmation = .cancel });

    const after = presentation.projection();
    try testing.expect(after.delete_confirmation == null);
    try testing.expect(after.action_error == null);
    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 3, 4 }, draftTempIds(&presentation, &ids));
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
}

test "the delete confirmation is keyboard-complete and captures every other key" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 4);
    const cursor = presentation.published.?.navigation.cursor;
    try presentation.dispatch(.{ .key = .{ .codepoint = 'D', .text = "D" } });
    try testing.expect(presentation.projection().delete_confirmation != null);

    // A motion neither moves the cursor nor re-targets the confirmation.
    try presentation.dispatch(.{ .key = .{ .codepoint = 'j', .text = "j" } });
    try testing.expectEqual(cursor, presentation.published.?.navigation.cursor);
    try testing.expectEqual(@as(bbr.review.TempId, 4), presentation.projection().delete_confirmation.?.temp_id);

    try presentation.dispatch(.{ .key = .{ .codepoint = 'n', .text = "n" } });
    try testing.expect(presentation.projection().delete_confirmation == null);
    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 3, 4 }, draftTempIds(&presentation, &ids));

    try presentation.dispatch(.{ .key = .{ .codepoint = 'D', .text = "D" } });
    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.enter } });
    try testing.expect(presentation.projection().delete_confirmation == null);
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 3 }, draftTempIds(&presentation, &ids));
}

test "delete stays discoverable but names why each ineligible item refuses it" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 1,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
        .body = "root with an unresolved Reply",
    });
    try store.store().put(key.storeKey(), .{
        .local_id = 2,
        .kind = .comment,
        .parent = .{ .draft = 1 },
        .body = "ambiguous reply",
        .state = .outcome_unknown,
    });
    try store.store().put(key.storeKey(), .{
        .local_id = 3,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } },
        .body = "in a batch",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    // A root is refused for its descendant's sake, not its own.
    try cursorToDraftCard(&presentation, 1);
    try testing.expect(!presentation.projection().action_availability.available(.delete_review_item));
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(ActionError.draft_descendant_locked, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().delete_confirmation == null);

    try cursorToDraftCard(&presentation, 2);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(ActionError.draft_outcome_unresolved, presentation.projection().action_error.?);

    // The transient `posted` window of a partial batch, before Reconciliation
    // replaces the Draft's row with the published Comment.
    try cursorToDraftCard(&presentation, 3);
    presentation.published.?.review.setState(3, .{ .posted = 71 });
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(ActionError.draft_already_published, presentation.projection().action_error.?);
    presentation.published.?.review.setState(3, .draft);

    // An author-owned published Comment gets a remote-effect confirmation.
    try cursorToCommentCard(&presentation, 99);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(@as(?bbr.review.CommentId, 99), presentation.projection().delete_confirmation.?.comment_id);
    try presentation.dispatch(.{ .delete_confirmation = .cancel });

    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 3 }, draftTempIds(&presentation, &ids));
}

test "delete refuses a subtree an active SubmissionRun owns" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    const command = presentation.takeCommand().?.post_draft;
    defer command.destroy();

    try cursorToDraftCard(&presentation, 1);
    try testing.expect(!presentation.projection().action_availability.available(.delete_review_item));
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(ActionError.draft_submission_in_flight, presentation.projection().action_error.?);

    try cursorToDraftCard(&presentation, 4);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expectEqual(ActionError.draft_owned_by_submission, presentation.projection().action_error.?);
    try testing.expect(presentation.projection().delete_confirmation == null);
    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 3, 4 }, draftTempIds(&presentation, &ids));
}

test "a failed deletion preserves the previous Frame and keeps the confirmation" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .delete_review_item });
    const before = presentation.projection().review.?;
    store.fail_next_delete = true;
    try presentation.dispatch(.{ .delete_confirmation = .confirm });

    const failed = presentation.projection();
    try testing.expectEqual(ActionError.persistence_failed, failed.action_error.?);
    // The whole graph, ScopeProjection, Frame, and navigation survive intact.
    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{ 1, 2, 3, 4 }, draftTempIds(&presentation, &ids));
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, failed.review.?.navigation));
    // The confirmation stays available for a retry that then succeeds.
    try testing.expectEqual(@as(bbr.review.TempId, 1), failed.delete_confirmation.?.temp_id);

    try presentation.dispatch(.{ .delete_confirmation = .confirm });
    try testing.expect(presentation.projection().delete_confirmation == null);
    try testing.expectEqualSlices(bbr.review.TempId, &.{4}, draftTempIds(&presentation, &ids));
}

test "success selects the next surviving semantic row and falls back to the previous one" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    // A Draft on the File's last line has no surviving row after its card.
    try store.store().put(key.storeKey(), .{
        .local_id = 5,
        .kind = .comment,
        .scope = .{ .@"inline" = .{ .path = "wide.zig", .to = 40, .commit = "source" } },
        .body = "at the end",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    // The Draft on line 1 is followed by line 2's source row, which survives.
    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try presentation.dispatch(.{ .delete_confirmation = .confirm });
    const forward = presentation.published.?.buffer.rows[presentation.published.?.navigation.cursor];
    try testing.expectEqual(@as(?u32, 2), lineAtRow(forward).?.new_no);

    // Nothing semantic follows the last Draft, so the cursor falls back to the
    // nearest source row before it.
    try cursorToDraftCard(&presentation, 5);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try presentation.dispatch(.{ .delete_confirmation = .confirm });
    const back = presentation.published.?.buffer.rows[presentation.published.?.navigation.cursor];
    try testing.expectEqual(@as(?u32, 40), lineAtRow(back).?.new_no);
}

test "a Session replacement disarms a delete confirmation and a deleted subtree stays gone" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try seedDeletableSubtree(store.store(), key);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testWideSession(testing.allocator, 1) },
        .geometry = .{ .cols = 100, .rows = 60 },
    });
    defer presentation.deinit();

    try cursorToDraftCard(&presentation, 1);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try presentation.dispatch(.{ .delete_confirmation = .confirm });

    try cursorToDraftCard(&presentation, 4);
    try presentation.dispatch(.{ .action = .delete_review_item });
    try testing.expect(presentation.projection().delete_confirmation != null);
    try presentation.dispatch(.{ .action = .refresh });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testWideSession(testing.allocator, 1) },
    } });

    // The armed confirmation described the replaced graph, so it is dropped —
    // while the completed deletion survives the reload.
    try testing.expect(presentation.projection().delete_confirmation == null);
    var ids: [8]bbr.review.TempId = undefined;
    try testing.expectEqualSlices(bbr.review.TempId, &.{4}, draftTempIds(&presentation, &ids));
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
        testing.allocator.free(run.items);
    }
    try testing.expectEqual(run.operation_id, command.operation_id);
    try testing.expectEqual(@as(?bbr.review.TempId, 1), run.current_temp_id);
    try testing.expect((try locks.locks().tryAcquire(key.storeKey())) == null);
    try testing.expectEqual(run.operation_id, presentation.projection().submission.?.operation_id);
}

test "Submission dependency tree projects progress waits and publication checks explicitly" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "root body" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    try testing.expectEqual(SubmissionItemState.queued, presentation.projection().submission_tree.?.items[0].state);
    var post = presentation.takeCommand().?;
    const command_id = post.post_draft.command_id;
    const operation_id = post.post_draft.operation_id;
    post.deinit();
    try testing.expectEqual(SubmissionItemState.posting, presentation.projection().submission_tree.?.items[0].state);

    try presentation.dispatch(.{ .post_draft_completed = .{
        .command_id = command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = 1,
        .outcome = .{ .rejected = error.RateLimited },
        .retry_after_ms = 4_000,
    } });
    const waiting = presentation.projection().submission_tree.?.items[0];
    try testing.expectEqual(SubmissionItemState.waiting_to_retry, waiting.state);
    try testing.expectEqual(@as(u8, 1), waiting.post_attempts);
    try testing.expectEqual(@as(u64, 1_000), waiting.retry.?.local_delay_ms);
    try testing.expectEqual(@as(?u64, 4_000), waiting.retry.?.server_delay_ms);
    try testing.expectEqual(@as(u64, 4_000), waiting.retry.?.effective_delay_ms);

    try presentation.dispatch(.{ .key = .{ .codepoint = keymap_mod.special.escape } });
    try testing.expect(presentation.projection().submission_tree != null);
}

test "terminal dependency tree names blockers and retries only the selected failed subtree" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "failed root" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "blocked reply", .parent = .{ .draft = 1 } });
    try store.store().put(key.storeKey(), .{ .local_id = 3, .kind = .comment, .body = "unrelated root" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    var root_post = presentation.takeCommand().?;
    const root_command_id = root_post.post_draft.command_id;
    const operation_id = root_post.post_draft.operation_id;
    root_post.deinit();
    try presentation.dispatch(.{ .post_draft_completed = .{
        .command_id = root_command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = 1,
        .outcome = .{ .rejected = error.NotFound },
    } });
    var unrelated = presentation.takeCommand().?;
    const unrelated_command_id = unrelated.post_draft.command_id;
    unrelated.deinit();
    const progress = presentation.projection().submission_tree.?;
    try testing.expectEqual(SubmissionItemState.failed, progress.items[0].state);
    try testing.expectEqual(SubmissionItemState.skipped, progress.items[1].state);
    try testing.expectEqual(@as(?bbr.review.TempId, 1), progress.items[1].blocking_ancestor);
    try testing.expect(!progress.items[1].retry_eligible);
    try testing.expectEqual(@as(usize, 1), progress.items[0].reply_descendants);

    try presentation.dispatch(.{ .post_draft_completed = .{
        .command_id = unrelated_command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = 3,
        .outcome = .{ .posted = 903 },
    } });
    const terminal = presentation.projection().submission_tree.?;
    try testing.expect(terminal.completion.? == .partial);
    try testing.expectEqual(@as(usize, 3), terminal.items.len);

    const reconciliation = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .command_id = reconciliation.command_id,
        .intent = reconciliation.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 1, 'a') },
    } });

    try presentation.dispatch(.{ .key = .{ .codepoint = 'X', .text = "X" } });
    const retried = presentation.projection().submission_tree.?;
    try testing.expect(retried.completion == null);
    try testing.expectEqual(@as(usize, 2), retried.items.len);
    try testing.expectEqual(@as(bbr.review.TempId, 1), retried.items[0].temp_id);
    try testing.expectEqual(@as(bbr.review.TempId, 2), retried.items[1].temp_id);
    try testing.expectEqual(@as(usize, 1), retried.items[1].depth);
    var retry_post = presentation.takeCommand().?;
    defer retry_post.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 1), retry_post.post_draft.draft.local_id);
}

test "ambiguous POST projects checking publication before another POST" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "maybe posted" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') } });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    const command_id = post.post_draft.command_id;
    const operation_id = post.post_draft.operation_id;
    post.deinit();
    try presentation.dispatch(.{ .post_draft_completed = .{
        .command_id = command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = 1,
        .outcome = .ambiguous,
    } });
    try testing.expectEqual(SubmissionItemState.checking_publication, presentation.projection().submission_tree.?.items[0].state);
    var check = presentation.takeCommand().?;
    defer check.deinit();
    try testing.expect(check == .find_duplicate);
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
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", &.{.{ .temp_id = 1, .parent = null }});

    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
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
    try testing.expect(post.find_duplicate.dedupe);
    try testing.expectEqual(@as(bbr.review.TempId, 1), post.find_duplicate.draft.local_id);
}

test "recovery resumes only frozen participants and preserves parent remapping" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "root" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "reply", .parent = .{ .draft = 1 } });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", &.{ .{ .temp_id = 1, .parent = null }, .{ .temp_id = 2, .parent = .{ .draft = 1 } } });
    try store.store().checkpointSubmission(operation_id, key.storeKey(), 1, .{ .posted = 900 }, 2);
    try store.store().put(key.storeKey(), .{ .local_id = 3, .kind = .comment, .body = "later" });

    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .viewport_rows = 8 });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .recover_submission });
    const check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(check.command_id, operation_id, null, "old-head"));
    var command = presentation.takeCommand().?;
    defer command.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 2), command.find_duplicate.draft.local_id);
    try testing.expectEqual(@as(?bbr.review.CommentId, 900), command.find_duplicate.parent);
}

test "startup reports a live owner without stealing its Submission" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "owned" });
    _ = try store.store().beginSubmission(key.storeKey(), "head", &.{.{ .temp_id = 1, .parent = null }});
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
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", &.{.{ .temp_id = 1, .parent = null }});
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
    const operation_id = try store.store().beginSubmission(key.storeKey(), "old-head", &.{.{ .temp_id = 1, .parent = null }});
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
        .initial = .{ .key = key, .session = try testCommentSession(testing.allocator, 1) },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    for (presentation.published.?.buffer.rows, 0..) |row, index| if (row == .draft and row.draft.draftItem().local_id == 1) {
        presentation.published.?.navigation.jumpTo(index);
        break;
    };
    try presentation.dispatch(.{ .action = .link_existing_comment });
    try presentation.dispatch(.{ .unknown_resolution = .{ .digit = 9 } });
    try presentation.dispatch(.{ .unknown_resolution = .{ .digit = 9 } });
    try presentation.dispatch(.{ .unknown_resolution = .confirm });

    try testing.expect(presentation.projection().unknown_resolution == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(bbr.review.CommentId, 99), (try store.store().load(arena.allocator(), key.storeKey()))[0].state.posted);
    try testing.expect(presentation.takeCommand().? == .load_session);
}

fn submissionTreeItem(tree: SubmissionTreeProjection, temp_id: bbr.review.TempId) SubmissionItemProjection {
    for (tree.items) |item| if (item.temp_id == temp_id) return item;
    unreachable;
}

test "Submission Overlay permits Review switching without cancelling the run" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "queued" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    var post = presentation.takeCommand().?;
    post.deinit();
    try testing.expect(presentation.projection().submission_tree != null);

    try presentation.dispatch(.{ .key = .{ .codepoint = 'p', .text = "p" } });
    try testing.expect(presentation.projection().picker != null);
    var list = presentation.takeCommand().?;
    try testing.expect(list == .list_pull_requests);
    list.deinit();
    try testing.expect(presentation.projection().submission != null);
}

test "stale repair reload evaluates each root scope independently and checks the refreshed source again" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "review", .scope = .review });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "file", .scope = .{ .file = .{ .path = "a.zig", .source_commit = "source" } } });
    try store.store().put(key.storeKey(), .{ .local_id = 3, .kind = .comment, .body = "new", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1, .commit = "source" } } });
    try store.store().put(key.storeKey(), .{ .local_id = 4, .kind = .comment, .body = "old", .scope = .{ .@"inline" = .{ .path = "a.zig", .from = 1, .commit = "destination" } } });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
        .require_source_check = true,
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    const first_check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(first_check.command_id, first_check.operation_id, null, "new-head"));
    var stale = presentation.projection().submission_tree.?;
    try testing.expectEqualStrings("source", stale.stale_repair.?.loaded_source_commit);
    try testing.expectEqualStrings("new-head", stale.stale_repair.?.observed_source_commit);
    try testing.expect(!stale.stale_repair.?.reloaded);
    for (stale.items) |item| try testing.expect(!item.retry_eligible);
    try testing.expect(presentation.takeCommand() == null);

    try presentation.dispatch(.{ .key = .{ .codepoint = 'R', .text = "R" } });
    const reload = presentation.takeCommand().?.load_session;
    const refreshed = try testSession(testing.allocator, 1, 'a');
    refreshed.header.source_commit = "new-head";
    refreshed.source.remote.source_commit = "new-head";
    try presentation.dispatch(.{ .session_loaded = .{
        .command_id = reload.command_id,
        .intent = reload.intent,
        .outcome = .{ .loaded = refreshed },
    } });

    stale = presentation.projection().submission_tree.?;
    try testing.expect(stale.stale_repair.?.reloaded);
    try testing.expect(submissionTreeItem(stale, 1).retry_eligible);
    try testing.expect(!submissionTreeItem(stale, 2).retry_eligible);
    try testing.expect(!submissionTreeItem(stale, 3).retry_eligible);
    try testing.expect(submissionTreeItem(stale, 4).retry_eligible);

    try presentation.dispatch(.{ .key = .{ .codepoint = 'X', .text = "X" } });
    const second_check = presentation.takeCommand().?.check_recovery;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const selected = (try store.store().activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(usize, 1), selected.items.len);
    try testing.expectEqual(@as(bbr.review.TempId, 1), selected.items[0].temp_id);
    try testing.expectEqualStrings("new-head", selected.source_commit);

    try presentation.dispatch(recoveryCheckSucceeded(second_check.command_id, second_check.operation_id, null, "third-head"));
    const changed_again = presentation.projection().submission_tree.?.stale_repair.?;
    try testing.expectEqualStrings("new-head", changed_again.loaded_source_commit);
    try testing.expectEqualStrings("third-head", changed_again.observed_source_commit);
    try testing.expect(presentation.takeCommand() == null);
}

test "abandoning recovered ambiguity posts nothing and releases only settled Drafts" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "ambiguous" });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "eligible" });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "source", &.{ .{ .temp_id = 1, .parent = null }, .{ .temp_id = 2, .parent = null } });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 7, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .recover_submission });
    const source_check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(source_check.command_id, operation_id, null, "source"));
    var duplicate = presentation.takeCommand().?;
    const duplicate_command_id = duplicate.find_duplicate.command_id;
    duplicate.deinit();
    try presentation.dispatch(.{ .duplicate_checked = .{
        .command_id = duplicate_command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = 1,
        .outcome = .failed,
    } });
    try presentation.dispatch(.{ .key = .{ .codepoint = 'A', .text = "A" } });

    try testing.expect(presentation.takeCommand() == null);
    try testing.expect(presentation.projection().submission == null);
    try testing.expect(presentation.projection().submission_tree.?.completion.? == .partial);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expect(drafts[0].state == .outcome_unknown);
    try testing.expect(drafts[1].state == .draft);
    try testing.expect((try store.store().activeSubmission(arena.allocator())) == null);
    var reacquired = (try locks.locks().tryAcquire(key.storeKey())).?;
    reacquired.release();
}

test "current-source recovery checks publication before resuming with a new POST" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "resume" });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "source", &.{.{ .temp_id = 1, .parent = null }});
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 7, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .recover_submission });
    const source_check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(source_check.command_id, operation_id, null, "source"));
    var duplicate = presentation.takeCommand().?;
    const duplicate_command_id = duplicate.find_duplicate.command_id;
    duplicate.deinit();
    try presentation.dispatch(.{ .duplicate_checked = .{
        .command_id = duplicate_command_id,
        .operation_id = operation_id,
        .identity = .init(key),
        .temp_id = 1,
        .outcome = .missing,
    } });

    const wait = presentation.takeCommand().?.wait_submission;
    try testing.expectEqual(@as(u64, 1_000), wait.ms);
    try presentation.dispatch(.{ .submission_wait_completed = wait });
    var post = presentation.takeCommand().?;
    defer post.deinit();
    try testing.expect(post == .post_draft);
    try testing.expectEqual(@as(bbr.review.TempId, 1), post.post_draft.draft.local_id);
}

test "current-source check sends a fresh Submission directly to POST" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 7);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "fresh" });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
        .require_source_check = true,
    }, .{ .initial = .{ .key = key, .session = try testSession(testing.allocator, 7, 'a') } });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .submit });
    const source_check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(source_check.command_id, source_check.operation_id, null, "source"));
    var post = presentation.takeCommand().?;
    defer post.deinit();
    try testing.expect(post == .post_draft);
    try testing.expectEqual(@as(bbr.review.TempId, 1), post.post_draft.draft.local_id);
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
    try testing.expectEqual(@as(u64, 1_000), wait.ms);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const before_retry = try store.store().load(arena.allocator(), key.storeKey());
    try testing.expect(before_retry[0].state == .submitting);
    const retry_checkpoint = (try store.store().activeSubmission(arena.allocator())).?.retry.?;
    try testing.expectEqual(@as(u8, 1), retry_checkpoint.attempt);
    try testing.expectEqual(bbr.review.SubmissionRetryReason.rate_limited, retry_checkpoint.reason);
    try testing.expectEqual(@as(u64, 1_000), retry_checkpoint.local_delay_ms);
    try testing.expectEqual(@as(?u64, 17), retry_checkpoint.server_delay_ms);
    try testing.expectEqual(@as(u64, 1_000), retry_checkpoint.effective_delay_ms);
    try testing.expect(retry_checkpoint.pending_wait);
    try presentation.dispatch(.{ .submission_wait_completed = wait });
    var retry = presentation.takeCommand().?;
    defer retry.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 1), retry.post_draft.draft.local_id);
    try testing.expect(!retry.post_draft.dedupe);
}

test "selective retry freezes the failed subtree without re-admitting posted ancestors" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "posted", .state = .{ .posted = 900 } });
    try store.store().put(key.storeKey(), .{ .local_id = 2, .kind = .comment, .body = "retry", .parent = .{ .draft = 1 }, .state = .{ .failed = error.ServerError } });
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
    defer command.deinit();
    try testing.expectEqual(@as(bbr.review.TempId, 2), command.post_draft.draft.local_id);
    try testing.expectEqual(@as(?bbr.review.CommentId, 900), command.post_draft.parent);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = (try store.store().activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expectEqual(@as(bbr.review.TempId, 2), run.items[0].temp_id);
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

test "recovery repeats a durably pending wait in full before any network effect" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var locks = bbr.review.InMemorySubmissionLocks.init(testing.allocator);
    defer locks.deinit();
    const key = try OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{ .local_id = 1, .kind = .comment, .body = "recover wait" });
    const operation_id = try store.store().beginSubmission(key.storeKey(), "head", &.{.{ .temp_id = 1, .parent = null }});
    try store.store().checkpointSubmissionRetry(operation_id, key.storeKey(), 1, .{
        .phase = .post,
        .attempt = 1,
        .reason = .server_error,
        .local_delay_ms = 1_000,
        .server_delay_ms = 4_000,
        .effective_delay_ms = 4_000,
        .pending_wait = true,
    });
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .submission_locks = locks.locks(),
    }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .recover_submission });
    const source_check = presentation.takeCommand().?.check_recovery;
    try presentation.dispatch(recoveryCheckSucceeded(source_check.command_id, operation_id, null, "head"));
    const wait = presentation.takeCommand().?.wait_submission;
    try testing.expectEqual(@as(u64, 4_000), wait.ms);
    try presentation.dispatch(.{ .submission_wait_launch_failed = wait });
    try presentation.dispatch(.{ .action = .submit });
    const repeated = presentation.takeCommand().?.wait_submission;
    try testing.expectEqual(wait.ms, repeated.ms);
    const run = (try store.store().activeSubmission(testing.allocator)).?;
    defer {
        testing.allocator.free(run.key.workspace);
        testing.allocator.free(run.key.repository);
        testing.allocator.free(run.source_commit);
        testing.allocator.free(run.items);
    }
    try testing.expect(run.retry.?.pending_wait);
    try testing.expectEqual(@as(u8, 1), run.retry.?.attempt);
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
        var check = presentation.takeCommand().?;
        try testing.expect(check == .find_duplicate);
        check.deinit();
        try presentation.dispatch(.{ .duplicate_checked = .{
            .operation_id = operation_id,
            .temp_id = 1,
            .outcome = .missing,
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
