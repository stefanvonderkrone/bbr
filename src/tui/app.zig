//! Thin terminal adapter for the Presentation state machine (ADR-0012).
//!
//! This module translates vaxis events into portable inputs, executes typed
//! commands on workers or timers, admits their correlated completions, renders
//! borrowed projections, and reaps every future before teardown. Review,
//! navigation, overlay, replacement, and submission state live in Presentation.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const render = @import("render.zig");
const view = @import("view.zig");
const layouts = @import("layouts.zig");
const theme = @import("theme.zig");
const config = @import("config.zig");
const ThemeId = @import("theme_id.zig").ThemeId;
const Nav = @import("nav.zig").Nav;
const keymap = @import("keymap.zig");
const session = @import("session.zig");
const file_enrichment = @import("file_enrichment.zig");
const presentation_adapter = @import("presentation_adapter.zig");
const presentation_runtime = @import("presentation_runtime.zig");
const presentation = @import("presentation.zig");
const buffer_mod = @import("buffer.zig");
const Session = session.Session;

const PendingReviewStore = bbr.review.PendingReviewStore;
const frame_arena_retained_limit = 4 * 1024 * 1024;

/// Everything `run` needs to fetch and switch PRs. `online` is false for the
/// offline `demo`, which disables the network-backed Picker. `store` persists
/// the reviewer's pending Drafts (SQLite in production, `:memory:` for demo).
pub const RunCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    bitbucket: ?bbr.bitbucket.Client = null,
    repo: []const u8,
    store: PendingReviewStore,
    theme: ThemeId,
    /// False for the demo, which must not change the reviewer's config.toml.
    persist_theme: bool = true,
    keymap: keymap.Keymap,
    highlighter: bbr.highlight.Highlighter,
    highlight_max_file_bytes: usize,
    file_cache_enabled: bool,
    inactive_file_cache_max_bytes: usize,
    comments_collapsed_rows: usize,
    mouse_enabled: bool = true,
    mouse_vertical_scroll_rows: usize = 3,
    external_edit_max_bytes: usize = 1024 * 1024,
    submission_locks: ?bbr.review.SubmissionLocks = null,
    online: bool = true,
};

/// Terminal events plus the single typed completion channel used by every
/// Presentation worker.
const AppEvent = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    presentation_done: PresentationDone,
    picker_tick: PickerTickDone,
};

const PickerTickDone = struct {
    future_id: u64,
    scope: presentation.WorkId,
};

const PresentationDone = struct {
    work_id: u64,
    input: presentation.OwnedInput,
};

const Loop = vaxis.Loop(AppEvent);

const PresentationWork = struct {
    id: u64,
    future: std.Io.Future(void),
};

const PickerTickWork = struct {
    id: u64,
    scope: presentation.WorkId,
};

const PickerTickTransition = union(enum) {
    idle,
    start: presentation.WorkId,
    keep,
    stop,
    replace: presentation.WorkId,
};

const picker_tick_interval_ms = 250;

fn runPresentation(ctx: RunCtx, initial: ?*Session, initial_key: presentation.OwnedReviewIdentity) !void {
    var anchor_git = bbr.git.ShellGitClient.init(ctx.gpa, ctx.io);
    var git_anchor_resolver = bbr.review.GitAnchorResolver.init(ctx.gpa, anchor_git.gitClient());
    defer git_anchor_resolver.deinit();
    var state = try presentation.Presentation.init(ctx.gpa, .{
        .reviews = ctx.store,
        .anchor_resolver = git_anchor_resolver.resolver(),
        .scope_resolver = git_anchor_resolver.scopeResolver(),
        .submission_locks = ctx.submission_locks,
        .highlight_max_file_bytes = ctx.highlight_max_file_bytes,
        .file_cache_enabled = ctx.file_cache_enabled,
        .inactive_file_cache_max_bytes = ctx.inactive_file_cache_max_bytes,
        .comments_collapsed_rows = ctx.comments_collapsed_rows,
        .mouse_enabled = ctx.mouse_enabled,
        .mouse_vertical_scroll_rows = ctx.mouse_vertical_scroll_rows,
        .external_edit_max_bytes = ctx.external_edit_max_bytes,
        .require_source_check = ctx.online,
        .keymap = ctx.keymap,
        .remote_enabled = ctx.online,
        .cell_metrics = vaxis_cell_metrics,
        .configured_theme = ctx.theme,
        .persist_theme = ctx.persist_theme,
    }, .{
        .initial = if (initial) |loaded| .{
            .key = initial_key,
            .session = loaded,
        } else null,
        .viewport_rows = 1,
    });
    defer state.deinit();
    if (initial == null) try state.dispatch(.{ .choose_pull_request = initial_key });

    var write_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(ctx.io, &write_buf);
    var tty_active = true;
    defer if (tty_active) tty.deinit();
    const writer = tty.writer();
    var vx = try vaxis.init(ctx.io, ctx.gpa, ctx.env_map, .{});
    defer vx.deinit(ctx.gpa, writer);
    var loop: Loop = .init(ctx.io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();
    vx.screen.width_method = .unicode;
    try vx.enterAltScreen(writer);
    if (ctx.mouse_enabled) try vx.setMouseMode(writer, true);

    var futures: std.ArrayList(PresentationWork) = .empty;
    defer {
        for (futures.items) |*work| _ = work.future.await(ctx.io);
        futures.deinit(ctx.gpa);
    }
    var next_work_id: u64 = 1;
    var picker_tick_work: ?PickerTickWork = null;
    var frame_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer frame_arena.deinit();
    var painted_revision: ?presentation.PaintRevision = null;
    var sent_geometry: ?presentation.FrameGeometry = null;

    _ = try syncContentGeometry(&state, &frame_arena, vx.window(), &sent_geometry);
    try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, &vx, &tty, &tty_active, &write_buf);
    try syncPickerTick(&state, ctx, &loop, &futures, &next_work_id, &picker_tick_work);
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try state.dispatch(.{ .key = portableKey(key) }),
            .mouse => |mouse| if (portableMouse(mouse, ctx.io)) |input| try state.dispatch(.{ .mouse = input }),
            .winsize => |winsize| {
                try vx.resize(ctx.gpa, writer, winsize);
                vx.screen.width_method = .unicode;
                painted_revision = null;
            },
            .presentation_done => |done| {
                reapPresentationWork(&futures, ctx.io, done.work_id);
                try state.dispatch(done.input);
            },
            .picker_tick => |done| {
                reapPresentationWork(&futures, ctx.io, done.future_id);
                if (picker_tick_work != null and picker_tick_work.?.id == done.future_id)
                    picker_tick_work = null;
                try state.dispatch(.{ .picker_tick = done.scope });
            },
        }

        try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, &vx, &tty, &tty_active, &write_buf);
        if (state.projection().review != null) {
            try state.dispatch(.ensure_focused_enrichment);
            try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, &vx, &tty, &tty_active, &write_buf);
        }
        try syncPickerTick(&state, ctx, &loop, &futures, &next_work_id, &picker_tick_work);
        if (try syncContentGeometry(&state, &frame_arena, vx.window(), &sent_geometry))
            try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, &vx, &tty, &tty_active, &write_buf);
        // A completed worker may still own a payload queued for Presentation.
        // Keep the loop alive until every completion has been received and
        // reaped so shutdown cannot strand that payload in the event queue.
        if (state.readyToExit() and futures.items.len == 0) break;

        const projection = state.projection();
        if (painted_revision) |revision| if (std.meta.eql(revision, projection.revision)) continue;
        const active_theme = theme.value(projection.theme);
        const win = vx.window();
        const frame = frame_arena.allocator();
        const status_items = projectionStatusItems(frame, projection);
        const regions = windowRegions(win, statusRows(&status_items, win));
        const content_win = childRect(win, regions.get(.content).content);
        drawStatus(childRect(win, regions.get(.status).content), &status_items);
        if (projection.review) |review_projection| {
            const visual_cursor = review_projection.frame.navigation.cursor;
            const buffer_cursor = if (visual_cursor < review_projection.frame.visual_rows.len) review_projection.frame.visual_rows[visual_cursor].buffer_index else 0;
            const selected_file = review_projection.frame.buffer.fileIndexForRow(buffer_cursor) orelse 0;
            render.drawReview(frame, content_win, review_projection, active_theme, selected_file);
        } else {
            const status = presentationStatus(frame, projection, null);
            render.drawLoading(frame, content_win, projection.loading_pull_request_id, active_theme, status);
        }
        if (projection.list_overlay) |overlay| render.drawListOverlay(frame, content_win, overlay, projection.action_availability, projection.configured_theme, if (projection.review) |review| review.diff.files else &.{}, active_theme);
        if (projection.review_search) |review_search| render.drawReviewSearch(frame, content_win, review_search, active_theme);
        if (projection.composer) |composer| render.drawComposerProjection(frame, content_win, composer, active_theme);
        if (projection.unknown_resolution) |resolution| render.drawComposerProjection(frame, content_win, .{
            .label = "Link existing Bitbucket Comment ID",
            .body = resolution.comment_id,
        }, active_theme);
        if (projection.delete_confirmation) |confirmation| render.drawComposerProjection(frame, content_win, .{
            .label = "Delete local Draft · Enter delete · Esc cancel",
            .body = deleteConfirmationText(frame, confirmation),
        }, active_theme);
        if (projection.submission_tree) |tree| if (projection.review) |review_projection|
            if (presentation.OwnedReviewIdentity.eql(tree.key, review_projection.key))
                render.drawSubmissionTree(frame, content_win, active_theme, tree);
        if (projection.help_visible) render.drawHelp(frame, content_win, active_theme, ctx.keymap, projection.action_availability);
        try vx.render(writer);
        painted_revision = projection.revision;
        _ = frame_arena.reset(.{ .retain_with_limit = frame_arena_retained_limit });
    }
}

fn pickerTickWorker(loop: *Loop, future_id: u64, scope: presentation.WorkId, io: std.Io) void {
    io.sleep(std.Io.Duration.fromMilliseconds(picker_tick_interval_ms), .awake) catch return;
    loop.postEvent(.{ .picker_tick = .{ .future_id = future_id, .scope = scope } }) catch {};
}

fn pickerTickTransition(scope: ?presentation.WorkId, active: ?PickerTickWork) PickerTickTransition {
    if (active) |running| {
        const wanted = scope orelse return .stop;
        return if (wanted == running.scope) .keep else .{ .replace = wanted };
    }
    return if (scope) |wanted| .{ .start = wanted } else .idle;
}

fn syncPickerTick(
    state: *const presentation.Presentation,
    ctx: RunCtx,
    loop: *Loop,
    futures: *std.ArrayList(PresentationWork),
    next_work_id: *u64,
    active: *?PickerTickWork,
) !void {
    const scope = state.projection().picker_tick_scope;
    const start_scope: ?presentation.WorkId = switch (pickerTickTransition(scope, active.*)) {
        .idle, .keep => return,
        .stop => {
            cancelPresentationWork(futures, ctx.io, active.*.?.id);
            active.* = null;
            return;
        },
        .replace => |wanted| blk: {
            cancelPresentationWork(futures, ctx.io, active.*.?.id);
            active.* = null;
            break :blk wanted;
        },
        .start => |wanted| wanted,
    };
    try futures.ensureUnusedCapacity(ctx.gpa, 1);
    const id = next_work_id.*;
    next_work_id.* +%= 1;
    const future = try ctx.io.concurrent(pickerTickWorker, .{ loop, id, start_scope.?, ctx.io });
    futures.appendAssumeCapacity(.{ .id = id, .future = future });
    active.* = .{ .id = id, .scope = start_scope.? };
}

const vaxis_cell_metrics = render.terminal_cell_metrics;

fn windowRegions(win: vaxis.Window, status_rows: u16) view.Rects(layouts.AppSlot) {
    return view.solve(layouts.AppSlot, layouts.app, status_rows, .{ .width = win.width, .height = win.height });
}

fn childRect(win: vaxis.Window, rect: view.Rect) vaxis.Window {
    return win.child(.{ .x_off = rect.x, .y_off = rect.y, .width = rect.width, .height = rect.height });
}

/// Presentation lays out the content region. It keeps at least one row.
fn contentGeometry(win: vaxis.Window, status_rows: u16) presentation.FrameGeometry {
    const content = windowRegions(win, status_rows).get(.content).content;
    return .{ .cols = content.width, .rows = @max(content.height, 1) };
}

/// The rows the status needs at the window width, leaving the content at
/// least one row.
fn statusRows(items: *const StatusItems, win: vaxis.Window) u16 {
    return @min(layouts.statusHeight(items.params(), win.width), win.height -| 1);
}

/// The status height depends on the projection text, so the content geometry
/// can change without a window resize. Sends Presentation the content
/// geometry when it differs from the last one sent, and returns whether it
/// did. The cursor position never changes the height (see
/// `StatusItems.position_width`), so a resize does not feed back into
/// another one.
fn syncContentGeometry(
    state: *presentation.Presentation,
    frame_arena: *std.heap.ArenaAllocator,
    win: vaxis.Window,
    sent: *?presentation.FrameGeometry,
) !bool {
    defer _ = frame_arena.reset(.{ .retain_with_limit = frame_arena_retained_limit });
    const items = projectionStatusItems(frame_arena.allocator(), state.projection());
    const geometry = contentGeometry(win, statusRows(&items, win));
    if (sent.*) |previous| if (std.meta.eql(previous, geometry)) return false;
    sent.* = geometry;
    try state.dispatch(.{ .resize = geometry });
    return true;
}

fn presentationStatus(
    frame: std.mem.Allocator,
    projection: presentation.Projection,
    visible_key: ?presentation.OwnedReviewIdentity,
) ?[]const u8 {
    if (projection.fatal_error) |err| return @tagName(err);
    // The armed re-anchor banner outlives one refusal: it keeps naming the
    // Draft and whatever the source cursor currently proposes.
    if (projection.reanchor) |reanchor| return reanchorStatus(frame, projection, reanchor);
    if (projection.review_search != null and projection.action_error != null) return switch (projection.action_error.?) {
        .buffer_search_query_too_long => "Review Search Query limit is 256 characters",
        .buffer_search_invalid_query => "Review Search Query is invalid",
        .buffer_search_scan_failed => "Review Search failed",
        else => actionErrorText(projection.action_error.?),
    };
    if (projection.buffer_search) |search_projection| return bufferSearchStatus(frame, projection, search_projection);
    if (projection.action_error) |err| return actionErrorText(err);
    if (projection.clipboard_status) |status| return switch (status) {
        .copied => "copied text",
        .failed => "could not copy text",
    };
    if (projection.shutting_down) {
        if (projection.submission) |submission|
            return std.fmt.allocPrint(frame, "finishing Submission for {s}#{d}", .{ submission.key.repository(), submission.key.pull_request_id }) catch "finishing Submission";
        return "shutting down…";
    }
    if (projection.submission) |submission| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(submission.key, visible_key.?))
            return std.fmt.allocPrint(frame, "submitting {s}#{d} · {d}/{d}", .{
                submission.key.repository(),
                submission.key.pull_request_id,
                submission.completed,
                submission.total,
            }) catch "submitting another pull request…";
    }
    if (projection.submission_result) |result| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: {d} posted · {d} failed · {d} skipped", .{
                result.key.repository(),
                result.key.pull_request_id,
                result.posted,
                result.failed + result.outcome_unknown,
                result.skipped,
            }) catch "submission finished for another pull request";
    }
    if (projection.reviewer_verdict_result) |result| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: Reviewer Verdict {s}", .{
                result.key.repository(),
                result.key.pull_request_id,
                reviewerVerdictOutcomeLabel(result.outcome),
            }) catch "Reviewer Verdict changed for another pull request";
        return switch (result.outcome) {
            .completed => |completed| switch (completed) {
                .success, .reconciled_success => "Reviewer Verdict changed",
                .api_error => "Reviewer Verdict change failed",
                .stale_source_commit => "Reviewer Verdict unchanged; SourceCommit changed",
                .unresolved => "Reviewer Verdict outcome unresolved",
            },
            .launch_failed => "Reviewer Verdict change could not start",
            .adapter_failed => "Reviewer Verdict change failed",
        };
    }
    if (projection.comment_edit_result) |result| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: Comment {d} edit {s}", .{
                result.key.repository(),
                result.key.pull_request_id,
                result.comment_id,
                @tagName(result.outcome),
            }) catch "Comment edit finished for another pull request";
        return switch (result.outcome) {
            .updated => "Bitbucket Comment updated",
            .failed => "Bitbucket Comment edit failed",
            .outcome_unknown => "Comment edit delivery unknown; reconciling",
            .reload_required => "Comment updated, but authoritative reload is required",
        };
    }
    if (projection.comment_delete_result) |result| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: Comment {d} deletion {s}", .{
                result.key.repository(),
                result.key.pull_request_id,
                result.comment_id,
                @tagName(result.outcome),
            }) catch "Comment deletion finished for another pull request";
        return switch (result.outcome) {
            .deleted => "Bitbucket Comment deleted",
            .failed => "Bitbucket Comment deletion failed",
            .outcome_unknown => "Comment deletion delivery unknown; reconciling",
            .reload_required => "Comment deleted, but authoritative reload is required",
        };
    }
    if (projection.recovery) |recovery| return switch (recovery.ownership) {
        .recoverable => std.fmt.allocPrint(frame, "interrupted Submission for {s}#{d} · Y resume", .{
            recovery.key.repository(),
            recovery.key.pull_request_id,
        }) catch "interrupted Submission · Y resume",
        .running_elsewhere => std.fmt.allocPrint(frame, "{s}#{d} is submitting in another bbr instance", .{
            recovery.key.repository(),
            recovery.key.pull_request_id,
        }) catch "Submission owned by another bbr instance",
    };
    if (projection.replacement_error) |err| return @tagName(err);
    return null;
}

fn bufferSearchStatus(frame: std.mem.Allocator, projection: presentation.Projection, search_projection: presentation.BufferSearchProjection) []const u8 {
    const width = (if (projection.review) |review| review.frame.geometry.cols else 80) -| 2 * layouts.status_padding;
    return formatBufferSearchStatus(frame, width, projection.action_error, search_projection);
}

fn formatBufferSearchStatus(frame: std.mem.Allocator, width: u16, action_error: ?presentation.ActionError, search_projection: presentation.BufferSearchProjection) []const u8 {
    const message: []const u8 = if (search_projection.pending)
        " · Searching"
    else if (search_projection.query.len > 0 and search_projection.total == 0)
        " · No matches"
    else switch (action_error orelse .action_refused) {
        .buffer_search_no_matches => " · No matches",
        .buffer_search_hit_bottom => " · Search hit BOTTOM, continuing at TOP",
        .buffer_search_hit_top => " · Search hit TOP, continuing at BOTTOM",
        .buffer_search_query_too_long => " · Query limit is 256 characters",
        .buffer_search_invalid_query => " · Invalid Query",
        .buffer_search_scan_failed => " · Search failed",
        else => "",
    };
    const count = if (search_projection.total == 0)
        (std.fmt.allocPrint(frame, " 0/0", .{}) catch "")
    else if (search_projection.active) |active|
        (std.fmt.allocPrint(frame, " {d}/{d}", .{ active, search_projection.total }) catch "")
    else
        (std.fmt.allocPrint(frame, " -/{d}", .{search_projection.total}) catch "");
    const verbose_suffix = std.fmt.allocPrint(frame, "{s}{s}", .{ count, message }) catch count;
    const suffix = if (vaxis.gwidth.gwidth(verbose_suffix, .unicode) + 2 <= width)
        verbose_suffix
    else
        count;
    const fixed_width = vaxis.gwidth.gwidth(suffix, .unicode) + 2;
    const available = @as(usize, width) -| fixed_width;
    var query_start: usize = 0;
    while (query_start < search_projection.query.len and vaxis.gwidth.gwidth(search_projection.query[query_start..], .unicode) > available) {
        const length = std.unicode.utf8ByteSequenceLength(search_projection.query[query_start]) catch 1;
        query_start += length;
    }
    return std.fmt.allocPrint(frame, "/{s}{s}", .{ search_projection.query[query_start..], suffix }) catch "/";
}

fn reviewerVerdictOutcomeLabel(outcome: presentation.ReviewerVerdictCommandOutcome) []const u8 {
    return switch (outcome) {
        .completed => |result| switch (result) {
            .success => "changed",
            .reconciled_success => "changed after reconciliation",
            .api_error => "failed",
            .stale_source_commit => "refused because SourceCommit changed",
            .unresolved => "outcome unresolved",
        },
        .launch_failed => "could not start",
        .adapter_failed => "failed",
    };
}

fn actionErrorText(err: presentation.ActionError) []const u8 {
    return switch (err) {
        .local_review_no_picker => "Pull Request Picker is unavailable for a local review",
        .theme_not_saved => "Theme applied, but config.toml could not be written",
        .theme_not_saved_invalid_config => "Theme applied, but config.toml is invalid and was not changed",
        .local_review_no_submission => "Submit is unavailable for a local review; drafts remain local",
        .local_review_remote_action_unavailable => "This action is unavailable for a local review",
        .source_action_unavailable => "This action requires a source line or Selection",
        .yank_no_source => "No copyable text exists at the cursor or in Selection",
        .yank_no_body => "No authored body exists at the cursor",
        .yank_opposite_version => "ReviewCard belongs to the opposite Selected Version",
        .old_content_unavailable => "Old content is unavailable",
        .new_content_unavailable => "New content is unavailable",
        .source_not_hunk_line => "This action requires a Hunk Line",
        .source_opposite_version => "This source belongs to the other File version",
        .suggestion_requires_new_version => "Suggestions require the new File version",
        .target_action_unavailable => "This action is unavailable for the current target",
        .no_review_item => "This action requires a Comment or Draft under the cursor",
        .draft_owned_by_submission => "an active Submission owns this local Draft",
        .draft_submission_in_flight => "this local Draft is being submitted",
        .draft_outcome_unresolved => "outcome unknown — resolve before editing",
        .draft_already_published => "this Draft is published; Bitbucket owns the Comment",
        .authenticated_account_unknown => "Authenticated Account identity is unavailable; reload to retry",
        .comment_author_unknown => "this Comment has no author UUID; ownership cannot be proven",
        .comment_owned_by_other => "only the author can mutate this Bitbucket Comment",
        .comment_deleted => "a Deleted Comment cannot be mutated",
        .remote_write_busy => "another remote write is already in progress",
        .reviewer_verdict_local_review => "Reviewer Verdict is unavailable for a LocalReview",
        .pull_request_not_open => "Reviewer Verdict requires an open PullRequest",
        .reviewer_verdict_unknown => "Reviewer Verdict data is unavailable; reload to retry",
        .pull_request_author_unknown => "PullRequest Author identity is unavailable; reload to retry",
        .pull_request_author => "the PullRequest Author cannot set a Reviewer Verdict",
        .reviewer_verdict_unchanged => "the PullRequest already has this Reviewer Verdict",
        .reviewer_verdict_failed => "Bitbucket refused the Reviewer Verdict change",
        .reviewer_verdict_source_changed => "Reviewer Verdict unchanged; SourceCommit changed",
        .reviewer_verdict_unresolved => "Reviewer Verdict outcome is unresolved; reload to inspect",
        .reviewer_verdict_launch_failed => "could not start the Reviewer Verdict change",
        .authoritative_reload_required => "remote Comment changed, but authoritative reload is required",
        .comment_edit_failed => "Bitbucket refused the Comment edit",
        .comment_edit_launch_failed => "could not start the Comment edit",
        .comment_delete_failed => "Bitbucket refused the Comment deletion",
        .comment_delete_launch_failed => "could not start the Comment deletion",
        .published_comment_edit_unsupported => "this published Comment mutation is unavailable",
        .draft_edit_conflict => "this local Draft changed underneath the edit",
        .draft_reply_has_no_anchor => "a Reply inherits its root's placement",
        .draft_scope_not_inline => "only an inline root Draft has an Anchor to replace",
        .draft_descendant_locked => "a Reply below this Draft cannot be deleted yet",
        .anchor_candidate_ambiguous => "that source range is ambiguous; select one side of one File",
        .anchor_range_too_long => "an Anchor covers at most 30 lines",
        .suggestion_anchor_not_new_side => "a Suggestion cannot anchor to removed lines",
        .buffer_search_selection_active => "Clear Selection before Buffer Search",
        .buffer_search_query_too_long => "Buffer Search Query limit is 256 characters",
        .buffer_search_invalid_query => "Buffer Search Query is invalid",
        .buffer_search_scan_failed => "Buffer Search failed",
        .buffer_search_no_matches => "No matches",
        .buffer_search_hit_bottom => "Search hit BOTTOM, continuing at TOP",
        .buffer_search_hit_top => "Search hit TOP, continuing at BOTTOM",
        else => @tagName(err),
    };
}

/// The complete consequence the reviewer confirms: the local TempId and every
/// Reply that goes with it.
fn deleteConfirmationText(
    frame: std.mem.Allocator,
    confirmation: presentation.DeleteConfirmationProjection,
) []const u8 {
    if (confirmation.comment_id) |comment_id| {
        if (confirmation.root_has_replies)
            return std.fmt.allocPrint(frame, "Delete Bitbucket Comment {d}? Bitbucket removes its body, retains a Deleted Comment tombstone, and keeps {d} Reply/Replies.", .{ comment_id, confirmation.descendant_count }) catch "Delete this Bitbucket Comment remotely?";
        return std.fmt.allocPrint(frame, "Delete Bitbucket Comment {d} from Bitbucket?", .{comment_id}) catch "Delete this Bitbucket Comment remotely?";
    }
    const fallback = "Delete this local Draft and every Reply below it?";
    if (confirmation.descendant_count == 0)
        return std.fmt.allocPrint(frame, "Delete local Draft #{d}? It has no Replies.", .{confirmation.temp_id}) catch fallback;
    return std.fmt.allocPrint(frame, "Delete local Draft #{d} and its {d} Reply Draft(s)?", .{
        confirmation.temp_id,
        confirmation.descendant_count,
    }) catch fallback;
}

/// `Re-anchor local Draft #7 → src/f.zig new 12-14 · Enter accept · Esc cancel`
fn reanchorStatus(
    frame: std.mem.Allocator,
    projection: presentation.Projection,
    reanchor: presentation.ReanchorProjection,
) []const u8 {
    const fallback = "Re-anchor local Draft · Enter accept · Esc cancel";
    const detail = if (reanchor.candidate) |candidate| std.fmt.allocPrint(frame, "{s} {s} {d}-{d}", .{
        candidate.path,
        @tagName(candidate.side),
        candidate.top,
        candidate.bottom,
    }) catch return fallback else actionErrorText(reanchor.refusal orelse projection.action_error orelse .action_refused);
    return std.fmt.allocPrint(frame, "Re-anchor local Draft #{d} → {s} · Enter accept · Esc cancel", .{
        reanchor.temp_id,
        detail,
    }) catch fallback;
}

fn portableKey(key: vaxis.Key) keymap.KeyStroke {
    return .{
        .codepoint = key.codepoint,
        .text = key.text,
        .mods = .{
            .shift = key.mods.shift,
            .alt = key.mods.alt,
            .ctrl = key.mods.ctrl,
            .super = key.mods.super,
            .hyper = key.mods.hyper,
            .meta = key.mods.meta,
        },
    };
}

fn portableMouse(mouse: vaxis.Mouse, io: std.Io) ?presentation.MouseInput {
    if (mouse.col < 0 or mouse.row < 0) return null;
    return .{
        .col = @intCast(mouse.col),
        .row = @intCast(mouse.row),
        .time_ns = std.Io.Clock.awake.now(io).nanoseconds,
        .button = switch (mouse.button) {
            .left => .left,
            .middle => .middle,
            .right => .right,
            .wheel_up => .wheel_up,
            .wheel_down => .wheel_down,
            .wheel_left => .wheel_left,
            .wheel_right => .wheel_right,
            .none, .button_8, .button_9, .button_10, .button_11 => .unsupported,
        },
        .type = switch (mouse.type) {
            .press => .press,
            .release => .release,
            .motion => .motion,
            .drag => .drag,
        },
        .modified = mouse.mods.shift or mouse.mods.alt or mouse.mods.ctrl,
    };
}

fn submissionAbortName(completion: bbr.review.SubmissionCompletion) ?[]const u8 {
    return switch (completion) {
        .clean, .partial => null,
        .aborted => |pending| switch (pending) {
            .failed => |err| @errorName(err),
            .draft => "submission aborted",
            .outcome_unknown => "outcome unknown",
        },
    };
}

/// Run the viewer. `initial` is a pre-built Session (the offline demo) or null,
/// in which case PR `initial_id` is loaded on a worker thread while a "Loading
/// PR #N…" frame shows — the TUI never blocks the alt-screen on the first fetch.
/// Takes ownership of the current Session and destroys it (and any it switches
/// to) before returning.
pub fn run(ctx: RunCtx, initial: ?*Session, initial_key: presentation.OwnedReviewIdentity) !void {
    return runPresentation(ctx, initial, initial_key);
}

/// Opt-in interactive PTY check for the terminal behavior deterministic fakes
/// cannot establish. The controlled editor validates inherited streams,
/// canonical input, echo, and exact bytes while the handoff exercises the same
/// suspend/restore sequence used by External Edit in the TUI.
pub fn externalEditSmoke(io: std.Io, gpa: std.mem.Allocator, environment: *const std.process.Environ.Map) !void {
    var env = try environment.clone(gpa);
    defer env.deinit();
    try env.put("GIT_EDITOR",
        \\sh -c 'test -t 0 && test -t 1 && test -t 2 || exit 20; mode=$(stty -a </dev/tty) || exit 21; printf "%s" "$mode" | grep -Eq "(^|[ ;])icanon([ ;]|$)" || exit 22; printf "%s" "$mode" | grep -Eq "(^|[ ;])echo([ ;]|$)" || exit 23; test "$(cat "$1")" = bbr-pty-before || exit 24; printf bbr-pty-after > "$1"' sh
    );

    var write_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &write_buf);
    var tty_active = true;
    defer if (tty_active) tty.deinit();
    var vx = try vaxis.init(io, gpa, &env, .{});
    defer vx.deinit(gpa, tty.writer());
    var loop: Loop = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();
    try vx.enterAltScreen(tty.writer());
    try vx.setMouseMode(tty.writer(), true);

    var handoff: SmokeHandoffContext = .{
        .io = io,
        .gpa = gpa,
        .loop = &loop,
        .tty = &tty,
        .tty_active = &tty_active,
        .vx = &vx,
        .write_buf = &write_buf,
    };
    const command = try createSmokeExternalEdit(gpa);
    const completed = try presentation_adapter.externalEdit(io, &env, handoff.handoff(), command);
    defer completed.destroy();
    if (completed.outcome == .restoration_failed) {
        std.debug.print("bbr: PTY smoke restoration failed; file retained at {s}\n", .{completed.outcome.restoration_failed});
        std.process.exit(1);
    }
    if (completed.outcome != .changed or !std.mem.eql(u8, completed.outcome.changed, "bbr-pty-after"))
        return error.ExternalEditPtySmokeFailed;

    const win = vx.window();
    win.clear();
    _ = win.printSegment(.{ .text = "External Edit PTY smoke passed. Press q to verify recreated input.", .style = .{} }, .{ .wrap = .word });
    try vx.render(tty.writer());
    while (true) switch (try loop.nextEvent()) {
        .key_press => |key| if (key.matches('q', .{})) break,
        .winsize => |winsize| try vx.resize(gpa, tty.writer(), winsize),
        else => {},
    };
    try vx.setMouseMode(tty.writer(), false);
    try vx.exitAltScreen(tty.writer());
}

fn createSmokeExternalEdit(allocator: std.mem.Allocator) !*presentation.ExternalEdit {
    const body = try allocator.dupe(u8, "bbr-pty-before");
    errdefer allocator.free(body);
    const command = try allocator.create(presentation.ExternalEdit);
    errdefer allocator.destroy(command);
    command.* = .{
        .allocator = allocator,
        .command_id = 1,
        .session_epoch = 1,
        .max_bytes = 64,
        .body = body,
    };
    return command;
}

const PresentationSinkContext = struct {
    loop: *Loop,
    work_id: u64,
};

fn presentationSink(context: *PresentationSinkContext) presentation_runtime.CompletionSink {
    return .{ .ptr = context, .post_fn = postPresentationInput };
}

fn postPresentationInput(ptr: *anyopaque, input: presentation.OwnedInput) anyerror!void {
    const context: *PresentationSinkContext = @ptrCast(@alignCast(ptr));
    try context.loop.postEvent(.{ .presentation_done = .{ .work_id = context.work_id, .input = input } });
}

/// Runs one typed POST command. The worker consumes the command and returns one
/// correlated completion through the same terminal event queue as all other
/// Presentation inputs.
fn presentationPostWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    command: *presentation.PostDraft,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var poster = bbr.bitbucket.Poster{
        .client = client,
        .allocator = scratch.allocator(),
        .repo_slug = command.identity.repository(),
        .pr_id = command.identity.pullRequestId(),
    };
    presentation_runtime.executePost(presentationSink(&sink_context), command, poster.poster());
}

fn presentationCommentEditWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    command: *presentation.UpdateComment,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    presentation_runtime.executeCommentEdit(presentationSink(&sink_context), command, client);
}

fn presentationCommentDeleteWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    command: *presentation.DeleteComment,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    presentation_runtime.executeCommentDelete(presentationSink(&sink_context), command, client);
}

fn presentationReviewerVerdictWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    command: presentation.ChangeReviewerVerdict,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    presentation_runtime.deliver(presentationSink(&sink_context), presentation_adapter.executeReviewerVerdict(scratch.allocator(), command, client));
}

fn presentationLoadWorker(
    loop: *Loop,
    work_id: u64,
    io: std.Io,
    client: ?bbr.bitbucket.Client,
    command: presentation.LoadSession,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    const outcome: presentation.SessionLoadOutcome = switch (command.key.kind) {
        .remote => if (session.loadWith(
            io,
            std.heap.page_allocator,
            client.?,
            command.key.repository(),
            command.key.pull_request_id,
        )) |loaded| .{ .loaded = loaded } else |err| .{ .failed = err },
        .local => blk: {
            var git = bbr.git.ShellGitClient.init(std.heap.page_allocator, io);
            break :blk if (session.loadLocalWith(
                std.heap.page_allocator,
                git.gitClient(),
                command.key.baseRef(),
                command.key.sourceRef(),
            )) |loaded| .{ .loaded = loaded } else |err| .{ .failed = err };
        },
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .session_loaded = .{
        .command_id = command.command_id,
        .intent = command.intent,
        .outcome = outcome,
    } });
}

fn presentationEnrichmentWorker(
    loop: *Loop,
    work_id: u64,
    io: std.Io,
    client: ?bbr.bitbucket.Client,
    highlighter: bbr.highlight.Highlighter,
    command: presentation.EnrichFile,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const outcome: presentation.FileEnrichmentOutcome = switch (command.source) {
        .remote => blk: {
            break :blk if (file_enrichment.enrichConcurrent(
                io,
                std.heap.page_allocator,
                client.?,
                highlighter,
                command.request(),
            )) |result| .{ .completed = result } else |err| .{ .failed = if (err == error.OutOfMemory) .out_of_memory else .launch_failed };
        },
        .local => blk: {
            var git = bbr.git.ShellGitClient.init(std.heap.page_allocator, io);
            var source: file_enrichment.GitBlobSource = .{ .client = git.gitClient() };
            break :blk if (file_enrichment.enrichFrom(
                std.heap.page_allocator,
                source.source(),
                highlighter,
                command.request(),
            )) |result| .{ .completed = result } else |err| .{ .failed = if (err == error.OutOfMemory) .out_of_memory else .launch_failed };
        },
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .file_enrichment_completed = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = outcome,
    } });
}

fn presentationBufferSearchWorker(
    loop: *Loop,
    work_id: u64,
    command_value: presentation.ScanBufferSearch,
) void {
    var command = command_value;
    defer command.deinit();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    presentation_runtime.deliver(
        presentationSink(&sink_context),
        .{ .buffer_search_scanned = presentation.executeBufferSearchScan(std.heap.page_allocator, &command) },
    );
}

fn presentationDisclosureWorker(loop: *Loop, work_id: u64, job: *presentation.DisclosureBuild) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    job.build();
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .buffer_disclosure_built = job });
}

fn presentationPrepareSessionWorker(loop: *Loop, work_id: u64, job: *presentation.PrepareSession) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    job.build();
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .session_prepared = job });
}

fn presentationReviewSourceWorker(loop: *Loop, work_id: u64, command_value: presentation.ScanReviewSource) void {
    var command = command_value;
    defer command.deinit();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .review_source_scanned = presentation.executeReviewSourceScan(std.heap.page_allocator, &command) });
}

fn presentationWaitWorker(loop: *Loop, work_id: u64, io: std.Io, wait: presentation.WaitSubmission) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(wait.ms)), .awake) catch {
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .submission_wait_launch_failed = wait });
        return;
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .submission_wait_completed = wait });
}

fn presentationRecoveryCheckWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    check: presentation.CheckRecovery,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const input = if (client.getPullRequest(scratch.allocator(), check.identity.repository(), check.identity.pullRequestId())) |pr|
        presentation.recoveryCheckSucceeded(check.command_id, check.operation_id, check.identity, pr.source_commit)
    else |_|
        presentation.OwnedInput{ .recovery_checked = .{ .command_id = check.command_id, .operation_id = check.operation_id, .identity = check.identity, .outcome = .failed } };
    presentation_runtime.deliver(presentationSink(&sink_context), input);
}

fn presentationDuplicateCheckWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    command: *presentation.PostDraft,
) void {
    defer command.destroy();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const author_uuid = client.getAuthenticatedAccountUuid(scratch.allocator()) catch {
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .duplicate_checked = .{
            .command_id = command.command_id,
            .operation_id = command.operation_id,
            .identity = command.identity,
            .temp_id = command.draft.local_id,
            .outcome = .failed,
        } });
        return;
    };
    var poster = bbr.bitbucket.Poster{
        .client = client,
        .allocator = scratch.allocator(),
        .repo_slug = command.identity.repository(),
        .pr_id = command.identity.pullRequestId(),
        .author_uuid = author_uuid,
        .require_author_match = true,
    };
    const checked = poster.poster().findExisting(command.draft, command.parent) catch bbr.review.CheckResult{ .outcome = .ambiguous };
    const outcome: presentation.DuplicateCheckOutcome = switch (checked.outcome) {
        .found => |id| .{ .found = id },
        .missing => .missing,
        .rejected => |err| .{ .rejected = err },
        .ambiguous => .failed,
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .duplicate_checked = .{
        .command_id = command.command_id,
        .operation_id = command.operation_id,
        .identity = command.identity,
        .temp_id = command.draft.local_id,
        .outcome = outcome,
        .retry_after_ms = checked.retry_after_ms,
    } });
}

fn presentationListPullRequestsWorker(
    loop: *Loop,
    work_id: u64,
    client: bbr.bitbucket.Client,
    command: presentation.ListPullRequests,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    const summaries = presentation.PullRequestSummaries.create(std.heap.page_allocator) catch {
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .pull_requests_loaded = .{
            .command_id = command.command_id,
            .work_id = command.work_id,
            .outcome = .failed,
        } });
        return;
    };
    loadPullRequestSummaries(client, command.repositoryName(), summaries) catch {
        summaries.destroy();
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .pull_requests_loaded = .{
            .command_id = command.command_id,
            .work_id = command.work_id,
            .outcome = .failed,
        } });
        return;
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .pull_requests_loaded = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .outcome = .{ .loaded = summaries },
    } });
}

fn loadPullRequestSummaries(
    client: bbr.bitbucket.Client,
    repository: []const u8,
    summaries: *presentation.PullRequestSummaries,
) !void {
    summaries.prs = try client.listPullRequests(summaries.arena.allocator(), repository, .{});
}

fn presentationCodeHighlightWorker(loop: *Loop, work_id: u64, highlighter: bbr.highlight.Highlighter, command: *@import("code_highlighting.zig").Analyze) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .code_highlight_completed = command.execute(highlighter) });
}

fn drainPresentationCommands(
    state: *presentation.Presentation,
    ctx: RunCtx,
    loop: *Loop,
    futures: *std.ArrayList(PresentationWork),
    next_work_id: *u64,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    tty_active: *bool,
    write_buf: []u8,
) !void {
    while (state.takeCommand()) |command_value| {
        var command = command_value;
        if (command == .copy_clipboard) {
            const input = presentation_adapter.copyToClipboard(vx.*, tty.writer(), command.copy_clipboard);
            command = undefined;
            try state.dispatch(input);
            continue;
        }
        // config.toml is at most 64 KiB, so the write runs on the terminal
        // thread and completes before the next event.
        if (command == .persist_theme) {
            const persist = command.persist_theme;
            const outcome: presentation.ThemePersisted.Outcome = if (config.persistTheme(ctx.gpa, ctx.io, ctx.env_map, persist.theme)) |_| .saved else |err| switch (err) {
                error.NoConfigLocation => .no_config_location,
                error.ConfigInvalid => .config_invalid,
                error.WriteFailed, error.OutOfMemory => .write_failed,
            };
            try state.dispatch(.{ .theme_persisted = .{ .command_id = persist.command_id, .outcome = outcome } });
            continue;
        }
        if (command == .external_edit) {
            var handoff_context: TerminalHandoffContext = .{
                .ctx = ctx,
                .loop = loop,
                .tty = tty,
                .tty_active = tty_active,
                .vx = vx,
                .write_buf = write_buf,
            };
            const completed = presentation_adapter.externalEdit(ctx.io, ctx.env_map, handoff_context.handoff(), command.external_edit) catch {
                command = undefined;
                return error.OutOfMemory;
            };
            command = undefined;
            const restoration_failed = completed.outcome == .restoration_failed;
            const retained_path = if (restoration_failed) completed.outcome.restoration_failed else null;
            if (retained_path) |path| {
                std.debug.print("bbr: terminal restoration failed; External Edit file retained at {s}\n", .{path});
                std.process.exit(1);
            }
            try state.dispatch(.{ .external_edit_completed = completed });
            continue;
        }
        futures.ensureUnusedCapacity(ctx.gpa, 1) catch {
            try state.dispatch(try command.launchFailed());
            continue;
        };
        const work_id = next_work_id.*;
        next_work_id.* +%= 1;
        const future = switch (command) {
            .load_session => |load| ctx.io.concurrent(presentationLoadWorker, .{ loop, work_id, ctx.io, workerBitbucketForReviewKind(ctx.bitbucket, load.key.kind), load }),
            .prepare_session => |job| ctx.io.concurrent(presentationPrepareSessionWorker, .{ loop, work_id, job }),
            .enrich_file => |enrich| ctx.io.concurrent(presentationEnrichmentWorker, .{ loop, work_id, ctx.io, workerBitbucketForEnrichment(ctx.bitbucket, enrich.source), ctx.highlighter, enrich }),
            .highlight_code => |job| ctx.io.concurrent(presentationCodeHighlightWorker, .{ loop, work_id, ctx.highlighter, job }),
            .post_draft => |post| ctx.io.concurrent(presentationPostWorker, .{ loop, work_id, ctx.bitbucket.?, post }),
            .update_comment => |update| ctx.io.concurrent(presentationCommentEditWorker, .{ loop, work_id, ctx.bitbucket.?, update }),
            .delete_comment => |delete| ctx.io.concurrent(presentationCommentDeleteWorker, .{ loop, work_id, ctx.bitbucket.?, delete }),
            .change_reviewer_verdict => |verdict| ctx.io.concurrent(presentationReviewerVerdictWorker, .{ loop, work_id, ctx.bitbucket.?, verdict }),
            .wait_submission => |wait| ctx.io.concurrent(presentationWaitWorker, .{ loop, work_id, ctx.io, wait }),
            .check_recovery => |check| ctx.io.concurrent(presentationRecoveryCheckWorker, .{ loop, work_id, ctx.bitbucket.?, check }),
            .find_duplicate => |check| ctx.io.concurrent(presentationDuplicateCheckWorker, .{ loop, work_id, ctx.bitbucket.?, check }),
            .list_pull_requests => |list| ctx.io.concurrent(presentationListPullRequestsWorker, .{ loop, work_id, ctx.bitbucket.?, list }),
            .copy_clipboard, .persist_theme => unreachable,
            .external_edit => unreachable,
            .scan_buffer_search => |scan| ctx.io.concurrent(presentationBufferSearchWorker, .{ loop, work_id, scan }),
            .build_buffer_disclosure => |job| ctx.io.concurrent(presentationDisclosureWorker, .{ loop, work_id, job }),
            .scan_review_source => |scan| ctx.io.concurrent(presentationReviewSourceWorker, .{ loop, work_id, scan }),
        } catch {
            try state.dispatch(try command.launchFailed());
            continue;
        };
        futures.appendAssumeCapacity(.{ .id = work_id, .future = future });
        // A POST pointer moved into its worker. Value commands need no cleanup.
        command = undefined;
    }
}

fn workerBitbucketForReviewKind(client: ?bbr.bitbucket.Client, kind: presentation.ReviewKind) ?bbr.bitbucket.Client {
    return if (kind == .remote) client.? else null;
}

fn workerBitbucketForEnrichment(client: ?bbr.bitbucket.Client, source: presentation.EnrichmentSource) ?bbr.bitbucket.Client {
    return switch (source) {
        .remote => client.?,
        .local => null,
    };
}

const TerminalHandoffContext = struct {
    ctx: RunCtx,
    loop: *Loop,
    tty: *vaxis.Tty,
    tty_active: *bool,
    vx: *vaxis.Vaxis,
    write_buf: []u8,

    fn handoff(self: *TerminalHandoffContext) presentation_adapter.TerminalHandoff {
        return .{ .ptr = self, .suspend_fn = suspendTerminal, .restore_fn = restoreTerminal };
    }

    fn suspendTerminal(ptr: *anyopaque) !void {
        const self: *TerminalHandoffContext = @ptrCast(@alignCast(ptr));
        self.loop.stop();
        if (self.ctx.mouse_enabled) try self.vx.setMouseMode(self.tty.writer(), false);
        try self.vx.exitAltScreen(self.tty.writer());
        self.tty.deinit();
        self.tty_active.* = false;
    }

    fn restoreTerminal(ptr: *anyopaque) !void {
        const self: *TerminalHandoffContext = @ptrCast(@alignCast(ptr));
        self.tty.* = try vaxis.Tty.init(self.ctx.io, self.write_buf);
        self.tty_active.* = true;
        const winsize = try self.tty.getWinsize();
        try self.vx.resize(self.ctx.gpa, self.tty.writer(), winsize);
        try self.vx.enterAltScreen(self.tty.writer());
        if (self.ctx.mouse_enabled) try self.vx.setMouseMode(self.tty.writer(), true);
        try self.loop.start();
    }
};

const SmokeHandoffContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    loop: *Loop,
    tty: *vaxis.Tty,
    tty_active: *bool,
    vx: *vaxis.Vaxis,
    write_buf: []u8,

    fn handoff(self: *SmokeHandoffContext) presentation_adapter.TerminalHandoff {
        return .{ .ptr = self, .suspend_fn = suspendTui, .restore_fn = restoreTui };
    }

    fn suspendTui(ptr: *anyopaque) !void {
        const self: *SmokeHandoffContext = @ptrCast(@alignCast(ptr));
        self.loop.stop();
        try self.vx.setMouseMode(self.tty.writer(), false);
        try self.vx.exitAltScreen(self.tty.writer());
        self.tty.deinit();
        self.tty_active.* = false;
    }

    fn restoreTui(ptr: *anyopaque) !void {
        const self: *SmokeHandoffContext = @ptrCast(@alignCast(ptr));
        self.tty.* = try vaxis.Tty.init(self.io, self.write_buf);
        self.tty_active.* = true;
        const winsize = try self.tty.getWinsize();
        try self.vx.resize(self.gpa, self.tty.writer(), winsize);
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.setMouseMode(self.tty.writer(), true);
        try self.loop.start();
    }
};

fn reapPresentationWork(work: *std.ArrayList(PresentationWork), io: std.Io, id: u64) void {
    for (work.items, 0..) |item, index| {
        if (item.id != id) continue;
        var completed = work.swapRemove(index);
        _ = completed.future.await(io);
        return;
    }
}

fn cancelPresentationWork(work: *std.ArrayList(PresentationWork), io: std.Io, id: u64) void {
    for (work.items, 0..) |item, index| {
        if (item.id != id) continue;
        var canceled = work.swapRemove(index);
        _ = canceled.future.cancel(io);
        return;
    }
}

/// What the status shows for a published review.
const StatusFacts = struct {
    header: session.ReviewHeader,
    reviewer_verdict: ?bbr.bitbucket.ReviewerVerdict,
    /// The 1-based cursor row, or 0 in an empty Buffer.
    position: usize,
    total: usize,
    layout: buffer_mod.Layout,
    scope: presentation.Scope,
    isolate: bool,
    loading: bool = false,
    submitting: bool = false,
    draft_count: usize = 0,
    status_msg: ?[]const u8 = null,
    searching: bool = false,
    search_has_no_matches: bool = false,
};

fn projectionStatusItems(frame: std.mem.Allocator, projection: presentation.Projection) StatusItems {
    const active_theme = theme.value(projection.theme);
    const review = projection.review orelse return loadingStatusItems(active_theme, presentationStatus(frame, projection, null));
    const visual_cursor = review.navigation.cursor;
    return statusItems(frame, active_theme, .{
        .header = review.header,
        .reviewer_verdict = review.reviewer_verdict,
        .position = @min(visual_cursor + 1, review.buffer.rows.len),
        .total = review.buffer.rows.len,
        .layout = review.preferences.layout,
        .scope = switch (review.preferences.scope) {
            .changes => .changes,
            .fetched => .fetched,
            .whole => .whole,
        },
        .isolate = review.isolated_file != null,
        .loading = projection.replacing,
        .submitting = projection.submission != null,
        .draft_count = review.drafts.len,
        .status_msg = presentationStatus(frame, projection, review.key),
        .searching = projection.buffer_search != null,
        .search_has_no_matches = if (projection.buffer_search) |search| search.query.len > 0 and search.total == 0 else false,
    });
}

/// The meta items, then the hint items. In Buffer Search the search status
/// replaces the meta items, and the hint items stay.
fn statusItems(frame: std.mem.Allocator, active_theme: theme.Theme, facts: StatusFacts) StatusItems {
    var items: StatusItems = .init(active_theme);
    if (facts.searching) {
        if (facts.status_msg) |message| items.add(.search, message, if (facts.search_has_no_matches) .no_match else .message);
    } else {
        if (facts.header.pull_request_id) |id| {
            items.add(.title, std.fmt.allocPrint(frame, "#{d}", .{id}) catch "#", .pull_request);
            items.add(.title, " ", .bar);
            items.add(.verdict, reviewerVerdictLabel(facts.reviewer_verdict), if (facts.reviewer_verdict) |verdict| switch (verdict) {
                .approved => .verdict_approved,
                .changes_requested => .verdict_changes_requested,
                .no_verdict => .verdict_none,
            } else .verdict_none);
        }
        items.add(.title, facts.header.title, .title);
        items.add(.refs, facts.header.source_ref, .ref);
        items.add(.refs, " → ", .separator);
        items.add(.refs, facts.header.base_ref, .ref);
        items.add(.position, std.fmt.allocPrint(frame, "{d}/{d}", .{ facts.position, facts.total }) catch "", .position);
        items.position_width = @intCast(std.fmt.count("{d}/{d}", .{ facts.total, facts.total }));
    }
    items.hint(.layout, "s", if (facts.layout == .unified) " split" else " unified");
    // Names the *current* scope; `f` cycles Changes → fetched → whole.
    items.hint(.scope, "f", switch (facts.scope) {
        .changes => ": changes",
        .fetched => ": fetched",
        .whole => ": whole",
    });
    items.hint(.isolate, "o", if (facts.isolate) " all files" else " isolate");
    // A transient message (error/summary) or an in-progress indicator takes the
    // place of the key hints, with the pending-draft count on `X`.
    const message = if (facts.searching) null else facts.status_msg;
    if (message) |text| {
        items.add(.message, text, .message);
    } else if (facts.submitting) {
        items.add(.message, "submitting…", .busy);
    } else if (facts.loading) {
        items.add(.message, "loading…", .busy);
    } else {
        if (facts.draft_count > 0) {
            items.add(.submit, "X", .key);
            items.add(.submit, std.fmt.allocPrint(frame, " submit {d}", .{facts.draft_count}) catch " submit", .drafts);
        }
        items.hint(.comment, "c/i", " comment");
        items.hint(.file, "[ ]", " file");
        items.hint(.switch_review, "p", " switch");
        items.hint(.help, "?", " help");
        items.hint(.quit, "q", " quit");
    }
    return items;
}

/// Before a review exists, the hint part holds the loading message alone.
fn loadingStatusItems(active_theme: theme.Theme, status_msg: ?[]const u8) StatusItems {
    var items: StatusItems = .init(active_theme);
    if (status_msg) |message| items.add(.message, message, .message) else items.add(.message, "loading…", .busy);
    return items;
}

/// The status in its own window: each item in its rect from
/// `layouts.statusRects`, and a separator in the gap between two items on
/// one row.
fn drawStatus(win: vaxis.Window, items: *const StatusItems) void {
    if (win.height == 0) return;
    win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = items.theme.statusStyle(.bar) });
    const rects = layouts.statusRects(items.params(), .{ .width = win.width, .height = win.height });
    const separator = [_]vaxis.Segment{.{ .text = "  ·  ", .style = items.theme.statusStyle(.separator) }};
    var previous: ?view.Rect = null;
    for (std.enums.values(layouts.StatusSlot)) |slot| {
        const segments = items.lines.getPtrConst(slot).items();
        const rect = rects.get(slot).content;
        if (segments.len == 0 or rect.isEmpty()) continue;
        if (previous) |before| if (before.y == rect.y) {
            const x = before.x + before.width;
            _ = childRect(win, .{ .x = x, .y = rect.y, .width = rect.x -| x, .height = 1 }).print(&separator, .{ .wrap = .none });
        };
        _ = childRect(win, rect).print(segments, .{ .wrap = .none });
        previous = rect;
    }
}

/// The styled Segments of each status item. The texts live in the frame
/// arena because cells borrow them until render.
const StatusItems = struct {
    theme: theme.Theme,
    lines: std.EnumArray(layouts.StatusSlot, StatusLine) = .initFill(.{}),
    /// The layout width of the position: the width of `total/total`, the
    /// widest the position gets. A cursor move then never changes the status
    /// height, and with it the content geometry.
    position_width: u16 = 0,

    fn init(active_theme: theme.Theme) StatusItems {
        return .{ .theme = active_theme };
    }

    fn add(self: *StatusItems, slot: layouts.StatusSlot, text: []const u8, part: theme.StatusPart) void {
        self.lines.getPtr(slot).add(.{ .text = text, .style = self.theme.statusStyle(part) });
    }

    fn hint(self: *StatusItems, slot: layouts.StatusSlot, key: []const u8, label: []const u8) void {
        self.add(slot, key, .key);
        self.add(slot, label, .hint);
    }

    fn params(self: *const StatusItems) layouts.Status {
        var result: layouts.Status = .initFill(0);
        for (std.enums.values(layouts.StatusSlot)) |slot| result.set(slot, self.lines.getPtrConst(slot).width());
        if (result.get(.position) > 0) result.set(.position, self.position_width);
        return result;
    }
};

/// One status item as styled Segments.
const StatusLine = struct {
    segments: [3]vaxis.Segment = undefined,
    len: usize = 0,

    fn add(self: *StatusLine, segment: vaxis.Segment) void {
        std.debug.assert(self.len < self.segments.len);
        self.segments[self.len] = segment;
        self.len += 1;
    }

    fn items(self: *const StatusLine) []const vaxis.Segment {
        return self.segments[0..self.len];
    }

    fn width(self: *const StatusLine) u16 {
        var total: u16 = 0;
        for (self.items()) |segment| total +|= cellWidth(segment.text);
        return total;
    }
};

fn cellWidth(text: []const u8) u16 {
    return @intCast(@min(vaxis.gwidth.gwidth(text, .unicode), std.math.maxInt(u16)));
}

fn reviewerVerdictLabel(verdict: ?bbr.bitbucket.ReviewerVerdict) []const u8 {
    return if (verdict) |value| switch (value) {
        .approved => "Approved",
        .changes_requested => "Changes requested",
        .no_verdict => "No verdict",
    } else "Verdict unavailable";
}

// Force the presentation modules' tests into the exe test binary.
test {
    _ = @import("cell_metrics.zig");
    _ = @import("buffer.zig");
    _ = @import("frame.zig");
    _ = @import("view.zig");
    _ = @import("layouts.zig");
    _ = @import("view_paint.zig");
    _ = @import("file_tree.zig");
    _ = @import("render.zig");
    _ = @import("theme.zig");
    _ = @import("nav.zig");
    _ = @import("keymap.zig");
    _ = @import("list_overlay.zig");
    _ = @import("theme_id.zig");
    _ = @import("session.zig");
    _ = @import("arena_ring.zig");
    _ = @import("composer.zig");
    _ = @import("file_enrichment.zig");
    _ = @import("presentation_adapter.zig");
    _ = @import("presentation_runtime.zig");
}

test "whole-text vaxis width matches grapheme measurement" {
    for ([_][]const u8{ "plain", "\x00", "\t", "\x7f", "e\xcc\x81", "\xe7\x95\x8c", "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb", "\xff" }) |text| {
        var scalar_width: usize = 0;
        var rest = text;
        while (rest.len > 0) {
            const measured = vaxis_cell_metrics.next(rest);
            scalar_width += measured.cell_width;
            rest = rest[measured.byte_len..];
        }
        try std.testing.expectEqual(scalar_width, vaxis_cell_metrics.width(text));
    }
}

test "pinned vaxis fixtures preserve Shift Arrow selection input" {
    const fixtures = [_]struct { bytes: []const u8, codepoint: u21 }{
        .{ .bytes = "\x1b[1;2A", .codepoint = vaxis.Key.up },
        .{ .bytes = "\x1b[1;2B", .codepoint = vaxis.Key.down },
        .{ .bytes = "\x1b[57352;2u", .codepoint = vaxis.Key.up },
        .{ .bytes = "\x1b[57353;2u", .codepoint = vaxis.Key.down },
    };
    for (fixtures) |fixture| {
        var parser: vaxis.Parser = .{};
        const parsed = try parser.parse(fixture.bytes, std.testing.allocator);
        try std.testing.expectEqual(fixture.bytes.len, parsed.n);
        const key = parsed.event.?.key_press;
        const portable = portableKey(key);
        try std.testing.expectEqual(fixture.codepoint, portable.codepoint);
        try std.testing.expect(portable.mods.shift);
    }
}

test "status labels project every Reviewer Verdict" {
    try std.testing.expectEqualStrings("Approved", reviewerVerdictLabel(.approved));
    try std.testing.expectEqualStrings("Changes requested", reviewerVerdictLabel(.changes_requested));
    try std.testing.expectEqualStrings("No verdict", reviewerVerdictLabel(.no_verdict));
    try std.testing.expectEqualStrings("Verdict unavailable", reviewerVerdictLabel(null));
}

test "qualified Reviewer Verdict results retain their outcome" {
    try std.testing.expectEqualStrings("changed", reviewerVerdictOutcomeLabel(.{ .completed = .success }));
    try std.testing.expectEqualStrings("refused because SourceCommit changed", reviewerVerdictOutcomeLabel(.{ .completed = .stale_source_commit }));
    try std.testing.expectEqualStrings("outcome unresolved", reviewerVerdictOutcomeLabel(.{ .completed = .{ .unresolved = null } }));
}

const TestStatus = struct {
    title: []const u8 = "Fix parser",
    verdict: ?bbr.bitbucket.ReviewerVerdict = .approved,
    position: usize = 1,
    total: usize = 1,
    loading: bool = false,
    status_msg: ?[]const u8 = null,
    searching: bool = false,
    search_has_no_matches: bool = false,
};

fn testStatusItems(arena: std.mem.Allocator, active_theme: theme.Theme, case: TestStatus) StatusItems {
    return statusItems(arena, active_theme, .{
        .header = .{ .pull_request_id = 7, .title = case.title, .source_ref = "review", .base_ref = "main", .source_commit = "", .base_commit = "", .locator = "", .source_label = "" },
        .reviewer_verdict = case.verdict,
        .position = case.position,
        .total = case.total,
        .layout = .unified,
        .scope = .changes,
        .isolate = false,
        .loading = case.loading,
        .draft_count = 2,
        .status_msg = case.status_msg,
        .searching = case.searching,
        .search_has_no_matches = case.search_has_no_matches,
    });
}

/// The status drawn in a window `cols` wide and as tall as the status needs.
fn testDrawStatusAt(arena: std.mem.Allocator, active_theme: theme.Theme, case: TestStatus, cols: u16) !vaxis.Window {
    const items = testStatusItems(arena, active_theme, case);
    const screen = try arena.create(vaxis.Screen);
    screen.* = try vaxis.Screen.init(arena, .{ .rows = layouts.statusHeight(items.params(), cols), .cols = cols, .x_pixel = 0, .y_pixel = 0 });
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = screen };
    drawStatus(win, &items);
    return win;
}

fn testDrawStatus(arena: std.mem.Allocator, active_theme: theme.Theme, case: TestStatus) !vaxis.Window {
    return testDrawStatusAt(arena, active_theme, case, 200);
}

/// The text of each status row without its side padding.
fn testStatusRows(arena: std.mem.Allocator, win: vaxis.Window) ![]const []const u8 {
    const rows = try arena.alloc([]const u8, win.height);
    for (rows, 0..) |*row, index| {
        var text: std.ArrayList(u8) = .empty;
        for (0..win.width) |col| try text.appendSlice(arena, win.readCell(@intCast(col), @intCast(index)).?.char.grapheme);
        row.* = std.mem.trim(u8, text.items, " ");
    }
    return rows;
}

test "the status puts the meta items above the hint items and separates items on one row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wide = try testStatusRows(a, try testDrawStatus(a, theme.dark, .{}));
    try std.testing.expectEqual(@as(usize, 2), wide.len);
    try std.testing.expectEqualStrings("#7 Fix parser  ·  Approved  ·  review → main  ·  1/1", wide[0]);
    try std.testing.expectEqualStrings("s split  ·  f: changes  ·  o isolate  ·  X submit 2  ·  c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit", wide[1]);

    const case: TestStatus = .{ .title = "Teach the parser to keep comments" };
    const win = try testDrawStatusAt(a, theme.dark, case, 50);
    const narrow = try testStatusRows(a, win);
    const bar = theme.dark.statusStyle(.bar);
    for (0..win.height) |row| for (0..win.width) |col|
        try std.testing.expectEqual(bar.bg, win.readCell(@intCast(col), @intCast(row)).?.style.bg);
    try std.testing.expectEqualStrings("#7 Teach the parser to keep comments", narrow[0]);
    try std.testing.expect(std.mem.startsWith(u8, narrow[1], "Approved  ·  review → main"));
    try std.testing.expect(narrow.len > 3);
    try std.testing.expect(std.mem.startsWith(u8, narrow[2], "s split"));
    for (narrow) |row| {
        try std.testing.expect(!std.mem.startsWith(u8, row, "·"));
        try std.testing.expect(!std.mem.endsWith(u8, row, "·"));
    }
    const items = [_][]const u8{ "1/1", "o isolate", "X submit 2", "c/i comment", "[ ] file", "p switch", "? help", "q quit" };
    for (items) |item| {
        var rows_with_item: usize = 0;
        for (narrow) |row| rows_with_item += @intFromBool(std.mem.indexOf(u8, row, item) != null);
        try std.testing.expectEqual(@as(usize, 1), rows_with_item);
    }
}

test "the status height does not change when only the cursor moves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (20..200) |cols| {
        const first = testStatusItems(arena.allocator(), theme.dark, .{ .position = 1, .total = 120 });
        const last = testStatusItems(arena.allocator(), theme.dark, .{ .position = 120, .total = 120 });
        try std.testing.expectEqual(layouts.statusHeight(first.params(), @intCast(cols)), layouts.statusHeight(last.params(), @intCast(cols)));
    }
}

test "content geometry leaves the rows the status needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = testStatusItems(arena.allocator(), theme.dark, .{});
    for ([_][2]u16{ .{ 200, 40 }, .{ 50, 40 }, .{ 20, 3 }, .{ 4, 1 }, .{ 4, 0 } }) |size| {
        var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = size[0], .rows = size[1], .x_pixel = 0, .y_pixel = 0 });
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = &screen };
        const status_rows = statusRows(&items, win);
        const geometry = contentGeometry(win, status_rows);
        try std.testing.expect(geometry.rows >= 1);
        try std.testing.expectEqual(size[0], geometry.cols);
        if (size[1] < 10) continue;
        const needed = layouts.statusHeight(items.params(), size[0]);
        try std.testing.expect(needed >= 2);
        try std.testing.expectEqual(size[1] - needed, geometry.rows);
        try std.testing.expectEqual(size[1] - needed, windowRegions(win, status_rows).get(.status).content.y);
    }
}

/// The first cell where a row's cells spell `needle`.
fn testStatusCell(win: vaxis.Window, needle: []const u8) !struct { col: u16, row: u16 } {
    for (0..win.height) |row| for (0..win.width) |start| {
        var offset: usize = 0;
        var col: u16 = @intCast(start);
        while (offset < needle.len and col < win.width) : (col += 1) {
            const grapheme = win.readCell(col, @intCast(row)).?.char.grapheme;
            if (!std.mem.startsWith(u8, needle[offset..], grapheme)) break;
            offset += grapheme.len;
        }
        if (offset == needle.len) return .{ .col = @intCast(start), .row = @intCast(row) };
    };
    return error.TestUnexpectedResult;
}

fn testStatusStyle(win: vaxis.Window, needle: []const u8, skip: u16) !vaxis.Style {
    const cell = try testStatusCell(win, needle);
    return win.readCell(cell.col + skip, cell.row).?.style;
}

fn testLuminance(color: vaxis.Cell.Color) f64 {
    const channels = color.rgb;
    return (0.2126 * @as(f64, @floatFromInt(channels[0])) + 0.7152 * @as(f64, @floatFromInt(channels[1])) + 0.0722 * @as(f64, @floatFromInt(channels[2]))) / 255;
}

test "the status follows the Theme polarity and emphasizes its parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (theme.builtins) |builtin| {
        const active = builtin.value;
        const bar = active.statusStyle(.bar);
        const muted = active.statusStyle(.separator).fg;
        const win = try testDrawStatus(arena.allocator(), active, .{});
        for (0..win.height) |row| for (0..win.width) |col|
            try std.testing.expectEqual(bar.bg, win.readCell(@intCast(col), @intCast(row)).?.style.bg);
        if (bar.bg == .rgb) {
            const bg = testLuminance(bar.bg);
            const fg = testLuminance(bar.fg);
            if (bg < 0.5) try std.testing.expect(fg > bg) else try std.testing.expect(fg < bg);
            if (std.mem.eql(u8, builtin.name, "dark")) try std.testing.expect(bg < 0.5);
            if (std.mem.eql(u8, builtin.name, "light")) try std.testing.expect(bg >= 0.5);
        }
        const pull_request = try testStatusStyle(win, "#7", 0);
        try std.testing.expectEqual(active.accent, pull_request.fg);
        try std.testing.expect(pull_request.bold);
        try std.testing.expect((try testStatusStyle(win, "Fix parser", 0)).bold);
        try std.testing.expectEqual(active.status_added, (try testStatusStyle(win, "Approved", 0)).fg);
        const key = try testStatusStyle(win, "s split", 0);
        try std.testing.expectEqual(active.accent, key.fg);
        try std.testing.expect(key.bold);
        const hint = try testStatusStyle(win, "s split", 2);
        try std.testing.expectEqual(muted, hint.fg);
        try std.testing.expect(!hint.bold);
        try std.testing.expectEqual(muted, (try testStatusStyle(win, "·", 0)).fg);
        try std.testing.expect(!std.meta.eql(bar.fg, muted));
    }
}

test "the status colors each Reviewer Verdict, Buffer Search miss, and busy state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (theme.builtins) |builtin| {
        const active = builtin.value;
        const muted = active.statusStyle(.separator).fg;
        const changes = try testDrawStatus(arena.allocator(), active, .{ .verdict = .changes_requested });
        try std.testing.expectEqual(active.status_removed, (try testStatusStyle(changes, "Changes requested", 0)).fg);
        const unavailable = try testStatusStyle(try testDrawStatus(arena.allocator(), active, .{ .verdict = null }), "Verdict unavailable", 0);
        try std.testing.expectEqual(muted, unavailable.fg);
        try std.testing.expect(unavailable.italic);
        const missed = try testDrawStatus(arena.allocator(), active, .{ .status_msg = "/nope 0/0", .searching = true, .search_has_no_matches = true });
        const no_match = try testStatusStyle(missed, "/nope 0/0", 0);
        try std.testing.expectEqual(active.search_no_match, no_match.fg);
        try std.testing.expect(no_match.bold);
        try std.testing.expectEqual(active.search_no_match, (try testStatusStyle(missed, "/nope 0/0", 6)).fg);
        const busy = try testStatusStyle(try testDrawStatus(arena.allocator(), active, .{ .loading = true }), "loading…", 0);
        try std.testing.expectEqual(active.status_modified, busy.fg);
        try std.testing.expect(busy.italic);
    }
}

test "M21 narrow Buffer Search status keeps the Query end before the count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const status = formatBufferSearchStatus(arena.allocator(), 12, null, .{
        .query = "abcdefghij",
        .input = true,
        .active = 2,
        .total = 3,
    });
    try std.testing.expect(std.mem.startsWith(u8, status, "/"));
    try std.testing.expect(std.mem.indexOf(u8, status, "hij") != null);
    try std.testing.expect(std.mem.endsWith(u8, status, " 2/3"));
    try std.testing.expect(vaxis.gwidth.gwidth(status, .unicode) <= 12);

    const inactive = formatBufferSearchStatus(arena.allocator(), 12, null, .{
        .query = "abc",
        .input = false,
        .active = null,
        .total = 3,
    });
    try std.testing.expect(std.mem.endsWith(u8, inactive, " -/3"));

    const pending = formatBufferSearchStatus(arena.allocator(), 30, null, .{
        .query = "new",
        .input = true,
        .active = null,
        .total = 0,
        .pending = true,
    });
    try std.testing.expect(std.mem.indexOf(u8, pending, "Searching") != null);
}

test "LocalReview worker dispatch does not require Bitbucket" {
    try std.testing.expect(workerBitbucketForReviewKind(null, .local) == null);
    try std.testing.expect(workerBitbucketForEnrichment(null, .local) == null);
}

test "Picker tick scheduler starts only while loading and stops on every scope end" {
    try std.testing.expectEqual(PickerTickTransition.idle, pickerTickTransition(null, null));
    try std.testing.expectEqual(PickerTickTransition{ .start = 7 }, pickerTickTransition(7, null));
    try std.testing.expectEqual(PickerTickTransition.keep, pickerTickTransition(7, .{ .id = 11, .scope = 7 }));
    try std.testing.expectEqual(PickerTickTransition.stop, pickerTickTransition(null, .{ .id = 11, .scope = 7 }));
    try std.testing.expectEqual(PickerTickTransition{ .replace = 8 }, pickerTickTransition(8, .{ .id = 11, .scope = 7 }));
}

fn testSleepingPickerTick(io: std.Io) void {
    io.sleep(std.Io.Duration.fromSeconds(60), .awake) catch return;
}

test "stopping a Picker tick cancels and reaps its sleeping future" {
    const io = std.testing.io;
    var work: std.ArrayList(PresentationWork) = .empty;
    defer work.deinit(std.testing.allocator);
    const future = try io.concurrent(testSleepingPickerTick, .{io});
    try work.append(std.testing.allocator, .{ .id = 19, .future = future });

    cancelPresentationWork(&work, io, 19);

    try std.testing.expectEqual(@as(usize, 0), work.items.len);
}
