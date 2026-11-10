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
    diagnostic: bbr.diagnostics.Handle = .{},
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

fn runPresentation(shared: RunCtx, initial: ?*Session, initial_key: presentation.OwnedReviewIdentity) !void {
    // Workers note client evidence concurrently, so the CLI evidence slot stays out of the
    // TUI, and each worker owns its own slot in its PresentationSinkContext.
    var ctx = shared;
    ctx.diagnostic = ctx.diagnostic.withLeaf(null);
    if (ctx.bitbucket) |client| ctx.bitbucket = client.withDiagnostics(ctx.diagnostic);
    var anchor_git = bbr.git.ShellGitClient.init(ctx.gpa, ctx.io);
    var git_anchor_resolver = bbr.review.GitAnchorResolver.init(ctx.gpa, anchor_git.gitClient(), ctx.diagnostic.forContext(.git, .{}));
    defer git_anchor_resolver.deinit();
    var state = presentation.Presentation.init(ctx.gpa, .{
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
        .diagnostic_state = if (ctx.diagnostic.sink) |sink| sink.state() else .off,
        .initial = if (initial) |loaded| .{
            .key = initial_key,
            .session = loaded,
        } else null,
        .viewport_rows = 1,
    }) catch |err| switch (err) {
        // The store recorded the failure. The terminal is not in raw mode yet.
        error.Reported => {
            var buf: [128]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(ctx.io, &buf);
            try stderr.interface.writeAll("bbr: could not load the pending review drafts\n");
            try stderr.interface.flush();
            return error.Reported;
        },
        else => return err,
    };
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
        if (ctx.diagnostic.sink) |sink| {
            const actual = sink.state();
            if (!std.meta.eql(actual, state.projection().diagnostic_state))
                try state.dispatch(.{ .diagnostics_changed = .{ .state = actual } });
        }
        if (try syncContentGeometry(&state, &frame_arena, vx.window(), &sent_geometry)) {
            // A taller DiffPane can expose Files outside the old Enrichment Range.
            if (state.projection().review != null) try state.dispatch(.ensure_focused_enrichment);
            try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, &vx, &tty, &tty_active, &write_buf);
        }
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
            switch (review_projection.frame.main_pane) {
                .diff_pane => render.drawReview(frame, content_win, review_projection, active_theme, selected_file),
                .comment_overview => render.drawCommentOverview(frame, content_win, review_projection, active_theme),
            }
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
        if (projection.help) |help| render.drawHelp(frame, content_win, active_theme, help, projection.action_availability);
        try vx.render(writer);
        painted_revision = projection.revision;
        _ = frame_arena.reset(.{ .retain_with_limit = frame_arena_retained_limit });
    }
}

fn pickerTickWorker(loop: *Loop, future_id: u64, scope: presentation.WorkId, io: std.Io) void {
    io.sleep(std.Io.Duration.fromMilliseconds(picker_tick_interval_ms), .awake) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return;
        },
    };
    loop.postEvent(.{ .picker_tick = .{ .future_id = future_id, .scope = scope } }) catch |err| switch (err) {
        error.Canceled => io.recancel(),
    };
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
    const future = try bbr.diagnostics.concurrent(ctx.io, pickerTickWorker, .{ loop, id, start_scope.?, ctx.io });
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
    if (projection.diagnostic_pending) return "changing diagnostic logging";
    if (projection.clipboard_status) |status| return switch (status) {
        .copied => "copied text",
        .failed => "could not copy text",
    };
    if (projection.shutting_down) {
        if (projection.submission) |submission|
            return std.fmt.allocPrint(frame, "finishing Submission for {s}#{d}", .{ submission.key.repository(), submission.key.pull_request_id }) catch |err| switch (err) {
                error.OutOfMemory => "finishing Submission",
            };
        return "shutting down…";
    }
    if (projection.submission) |submission| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(submission.key, visible_key.?))
            return std.fmt.allocPrint(frame, "submitting {s}#{d} · {d}/{d}", .{
                submission.key.repository(),
                submission.key.pull_request_id,
                submission.completed,
                submission.total,
            }) catch |err| switch (err) {
                error.OutOfMemory => "submitting another pull request…",
            };
    }
    if (projection.submission_result) |result| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: {d} posted · {d} failed · {d} skipped", .{
                result.key.repository(),
                result.key.pull_request_id,
                result.posted,
                result.failed + result.outcome_unknown,
                result.skipped,
            }) catch |err| switch (err) {
                error.OutOfMemory => "submission finished for another pull request",
            };
    }
    if (projection.reviewer_verdict_result) |result| {
        if (visible_key == null or !presentation.OwnedReviewIdentity.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: Reviewer Verdict {s}", .{
                result.key.repository(),
                result.key.pull_request_id,
                reviewerVerdictOutcomeLabel(result.outcome),
            }) catch |err| switch (err) {
                error.OutOfMemory => "Reviewer Verdict changed for another pull request",
            };
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
            }) catch |err| switch (err) {
                error.OutOfMemory => "Comment edit finished for another pull request",
            };
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
            }) catch |err| switch (err) {
                error.OutOfMemory => "Comment deletion finished for another pull request",
            };
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
        }) catch |err| switch (err) {
            error.OutOfMemory => "interrupted Submission · Y resume",
        },
        .running_elsewhere => std.fmt.allocPrint(frame, "{s}#{d} is submitting in another bbr instance", .{
            recovery.key.repository(),
            recovery.key.pull_request_id,
        }) catch |err| switch (err) {
            error.OutOfMemory => "Submission owned by another bbr instance",
        },
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
        (std.fmt.allocPrint(frame, " 0/0", .{}) catch |err| switch (err) {
            error.OutOfMemory => "",
        })
    else if (search_projection.active) |active|
        (std.fmt.allocPrint(frame, " {d}/{d}", .{ active, search_projection.total }) catch |err| switch (err) {
            error.OutOfMemory => "",
        })
    else
        (std.fmt.allocPrint(frame, " -/{d}", .{search_projection.total}) catch |err| switch (err) {
            error.OutOfMemory => "",
        });
    const verbose_suffix = std.fmt.allocPrint(frame, "{s}{s}", .{ count, message }) catch |err| switch (err) {
        error.OutOfMemory => count,
    };
    const suffix = if (vaxis.gwidth.gwidth(verbose_suffix, .unicode) + 2 <= width)
        verbose_suffix
    else
        count;
    const fixed_width = vaxis.gwidth.gwidth(suffix, .unicode) + 2;
    const available = @as(usize, width) -| fixed_width;
    var query_start: usize = 0;
    while (query_start < search_projection.query.len and vaxis.gwidth.gwidth(search_projection.query[query_start..], .unicode) > available) {
        const length = std.unicode.utf8ByteSequenceLength(search_projection.query[query_start]) catch |err| switch (err) {
            error.Utf8InvalidStartByte => 1,
        };
        query_start += length;
    }
    return std.fmt.allocPrint(frame, "/{s}{s}", .{ search_projection.query[query_start..], suffix }) catch |err| switch (err) {
        error.OutOfMemory => "/",
    };
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
        .theme_not_saved_unreadable => "Theme applied, but config.toml could not be read",
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
        .overview_entry_unavailable => "The entry is no longer in the Review",
        .overview_filters_cleared => "Comment Overview filters cleared to show the entry",
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
        .anchor_range_descending => "an Anchor range must run forward",
        .suggestion_anchor_not_new_side => "a Suggestion cannot anchor to removed lines",
        .replacement_pending => "the Review is reloading; try again when it finishes",
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
            return std.fmt.allocPrint(frame, "Delete Bitbucket Comment {d}? Bitbucket removes its body, retains a Deleted Comment tombstone, and keeps {d} Reply/Replies.", .{ comment_id, confirmation.descendant_count }) catch |err| switch (err) {
                error.OutOfMemory => "Delete this Bitbucket Comment remotely?",
            };
        return std.fmt.allocPrint(frame, "Delete Bitbucket Comment {d} from Bitbucket?", .{comment_id}) catch |err| switch (err) {
            error.OutOfMemory => "Delete this Bitbucket Comment remotely?",
        };
    }
    const fallback = "Delete this local Draft and every Reply below it?";
    if (confirmation.descendant_count == 0)
        return std.fmt.allocPrint(frame, "Delete local Draft #{d}? It has no Replies.", .{confirmation.temp_id}) catch |err| switch (err) {
            error.OutOfMemory => fallback,
        };
    return std.fmt.allocPrint(frame, "Delete local Draft #{d} and its {d} Reply Draft(s)?", .{
        confirmation.temp_id,
        confirmation.descendant_count,
    }) catch |err| switch (err) {
        error.OutOfMemory => fallback,
    };
}

/// Maps a Theme save error to the status outcome. The diagnostic record keeps `err`.
fn themeSaveOutcome(err: anyerror) presentation.ThemePersisted.Outcome {
    return switch (err) {
        error.NoConfigLocation => .no_config_location,
        error.ConfigInvalid => .config_invalid,
        error.OutOfMemory, error.WriteFailed, error.Canceled => .write_failed,
        else => .read_failed,
    };
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
    }) catch |err| switch (err) {
        error.OutOfMemory => return fallback,
    } else actionErrorText(reanchor.refusal orelse projection.action_error orelse .action_refused);
    return std.fmt.allocPrint(frame, "Re-anchor local Draft #{d} → {s} · Enter accept · Esc cancel", .{
        reanchor.temp_id,
        detail,
    }) catch |err| switch (err) {
        error.OutOfMemory => fallback,
    };
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
    diagnostic: bbr.diagnostics.Handle = .{},
    /// The worker's evidence slot. The worker's boundary record of a client error carries
    /// the evidence that the client noted here.
    leaf: ?bbr.diagnostic.Leaf = null,

    fn handle(self: *PresentationSinkContext) bbr.diagnostics.Handle {
        return self.diagnostic.withLeaf(&self.leaf);
    }

    fn bitbucket(self: *PresentationSinkContext, client: bbr.bitbucket.Client) bbr.bitbucket.Client {
        return client.withDiagnostics(self.handle());
    }
};

fn presentationSink(context: *PresentationSinkContext) presentation_runtime.CompletionSink {
    return .{ .ptr = context, .post_fn = postPresentationInput, .diagnostic = context.handle() };
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
    diagnostic: bbr.diagnostics.Handle,
    client: bbr.bitbucket.Client,
    command: *presentation.PostDraft,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var poster = bbr.bitbucket.Poster{
        .client = sink_context.bitbucket(client),
        .allocator = scratch.allocator(),
        .repo_slug = command.identity.repository(),
        .pr_id = command.identity.pullRequestId(),
    };
    presentation_runtime.executePost(presentationSink(&sink_context), command, poster.poster());
}

fn presentationCommentEditWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    client: bbr.bitbucket.Client,
    command: *presentation.UpdateComment,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    presentation_runtime.executeCommentEdit(presentationSink(&sink_context), command, sink_context.bitbucket(client));
}

fn presentationCommentDeleteWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    client: bbr.bitbucket.Client,
    command: *presentation.DeleteComment,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    presentation_runtime.executeCommentDelete(presentationSink(&sink_context), command, sink_context.bitbucket(client));
}

fn presentationReviewerVerdictWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    client: bbr.bitbucket.Client,
    command: presentation.ChangeReviewerVerdict,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    presentation_runtime.deliver(presentationSink(&sink_context), presentation_adapter.executeReviewerVerdict(scratch.allocator(), command, sink_context.bitbucket(client)));
}

fn presentationLoadWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    io: std.Io,
    client: ?bbr.bitbucket.Client,
    command: presentation.LoadSession,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    // The load runs on its own task, so it notes into its own slot, and a failure moves it here.
    var load_slot: ?bbr.diagnostic.Leaf = null;
    const outcome: presentation.SessionLoadOutcome = if (loadSessionWithin(io, session_load_timeout, loadSession, .{ io, client, diagnostic, &load_slot, command })) |loaded|
        .{ .loaded = loaded }
    else |err| failed: {
        sink_context.handle().adopt(&load_slot);
        break :failed .{ .failed = err };
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .session_loaded = .{
        .evidence = if (outcome == .failed) bbr.diagnostic.Failure.capture(.session_load, .execute, diagnostic.context, .{ .zig = outcome.failed }, @src()) else null,
        .command_id = command.command_id,
        .intent = command.intent,
        .outcome = outcome,
    } });
}

/// A stalled connection must not hold a Session replacement forever, because
/// replacement suspends Session-specific Actions until it completes.
const session_load_timeout = std.Io.Duration.fromSeconds(60);

fn loadSession(io: std.Io, client: ?bbr.bitbucket.Client, spawn_diagnostic: bbr.diagnostics.Handle, task_slot: *?bbr.diagnostic.Leaf, command: presentation.LoadSession) anyerror!*Session {
    const diagnostic = spawn_diagnostic.withLeaf(task_slot);
    return switch (command.key.kind) {
        .remote => session.loadWith(
            io,
            std.heap.page_allocator,
            client.?.withDiagnostics(diagnostic),
            command.key.repository(),
            command.key.pull_request_id,
        ),
        .local => blk: {
            var git = bbr.git.ShellGitClient.init(std.heap.page_allocator, io);
            git.diagnostic = diagnostic;
            break :blk session.loadLocalWith(
                std.heap.page_allocator,
                git.gitClient(),
                command.key.baseRef(),
                command.key.sourceRef(),
                diagnostic,
            );
        },
    };
}

const LoadRace = union(enum) {
    loaded: anyerror!*Session,
    expired: std.Io.Cancelable!void,
};

/// Run `load` until it finishes or `timeout` passes. On timeout, cancel the
/// load, destroy a Session that finishes during cancelation, and return
/// `error.Timeout`.
fn loadSessionWithin(io: std.Io, timeout: std.Io.Duration, load: anytype, args: std.meta.ArgsTuple(@TypeOf(load))) anyerror!*Session {
    var buffer: [2]LoadRace = undefined;
    var race = std.Io.Select(LoadRace).init(io, &buffer);
    defer discardLoadRace(&race);
    try bbr.diagnostics.selectConcurrent(&race, .loaded, load, args);
    try bbr.diagnostics.selectConcurrent(&race, .expired, std.Io.sleep, .{ io, timeout, .awake });
    return switch (try race.await()) {
        .loaded => |result| result,
        .expired => error.Timeout,
    };
}

fn discardLoadRace(race: *std.Io.Select(LoadRace)) void {
    while (race.cancel()) |late| switch (late) {
        .loaded => |result| if (result) |loaded| loaded.destroy() else |_| {},
        .expired => {},
    };
}

fn presentationEnrichmentWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    io: std.Io,
    client: ?bbr.bitbucket.Client,
    highlighter: bbr.highlight.Highlighter,
    command: presentation.EnrichFile,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    const input = enrichFileInput(&sink_context, io, client, highlighter, command) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            presentation_runtime.deliver(presentationSink(&sink_context), .{ .file_enrichment_completed = .{
                .command_id = command.command_id,
                .work_id = command.work_id,
                .session_epoch = command.session_epoch,
                .file_index = command.file_index,
                .outcome = .{ .failed = .launch_failed },
            } });
            return;
        },
    };
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    presentation_runtime.deliver(presentationSink(&sink_context), input);
}

/// The worker's File Enrichment. The request and the client note into the worker's slot, so
/// the worker's one record of a failure holds the evidence.
fn enrichFileInput(
    sink_context: *PresentationSinkContext,
    io: std.Io,
    client: ?bbr.bitbucket.Client,
    highlighter: bbr.highlight.Highlighter,
    command: presentation.EnrichFile,
) error{Canceled}!presentation.OwnedInput {
    var request = command.request();
    request.diagnostic = sink_context.handle();
    const enriched = switch (command.source) {
        .remote => file_enrichment.enrichConcurrent(io, std.heap.page_allocator, sink_context.bitbucket(client.?), highlighter, request),
        .local => blk: {
            var git = bbr.git.ShellGitClient.init(std.heap.page_allocator, io);
            var source: file_enrichment.GitBlobSource = .{ .client = git.gitClient() };
            break :blk file_enrichment.enrichFrom(std.heap.page_allocator, source.source(), highlighter, request);
        },
    };
    var evidence: ?bbr.diagnostic.Failure = null;
    const outcome: presentation.FileEnrichmentOutcome = if (enriched) |result| .{ .completed = result } else |err| failed: {
        switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => {},
        }
        evidence = bbr.diagnostic.Failure.capture(.file_enrichment, .execute, sink_context.diagnostic.context, .{ .zig = err }, @src());
        break :failed .{ .failed = .out_of_memory };
    };
    return .{ .file_enrichment_completed = .{
        .evidence = evidence,
        .command_id = command.command_id,
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = outcome,
    } };
}

fn presentationBufferSearchWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    command_value: presentation.ScanBufferSearch,
) void {
    var command = command_value;
    defer command.deinit();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    presentation_runtime.deliver(
        presentationSink(&sink_context),
        .{ .buffer_search_scanned = presentation.executeBufferSearchScan(std.heap.page_allocator, &command) },
    );
}

fn presentationDisclosureWorker(loop: *Loop, work_id: u64, diagnostic: bbr.diagnostics.Handle, job: *presentation.DisclosureBuild) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    job.build();
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .buffer_disclosure_built = job });
}

fn presentationPrepareSessionWorker(loop: *Loop, work_id: u64, diagnostic: bbr.diagnostics.Handle, job: *presentation.PrepareSession) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    job.build();
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .session_prepared = job });
}

fn presentationReviewSourceWorker(loop: *Loop, work_id: u64, diagnostic: bbr.diagnostics.Handle, command_value: presentation.ScanReviewSource) void {
    var command = command_value;
    defer command.deinit();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .review_source_scanned = presentation.executeReviewSourceScan(std.heap.page_allocator, &command) });
}

fn presentationWaitWorker(loop: *Loop, work_id: u64, diagnostic: bbr.diagnostics.Handle, io: std.Io, wait: presentation.WaitSubmission) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(wait.ms)), .awake) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            presentation_runtime.deliver(presentationSink(&sink_context), .{ .submission_wait_launch_failed = wait });
            return;
        },
    };
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .submission_wait_completed = wait });
}

fn presentationRecoveryCheckWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    client: bbr.bitbucket.Client,
    check: presentation.CheckRecovery,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const input = presentation_adapter.checkRecovery(scratch.allocator(), sink_context.bitbucket(client), check);
    presentation_runtime.deliver(presentationSink(&sink_context), input);
}

fn presentationDuplicateCheckWorker(
    loop: *Loop,
    work_id: u64,
    diagnostic: bbr.diagnostics.Handle,
    unbound: bbr.bitbucket.Client,
    command: *presentation.PostDraft,
) void {
    defer command.destroy();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    const client = sink_context.bitbucket(unbound);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const author_uuid = client.getAuthenticatedAccountUuid(scratch.allocator()) catch |err| {
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .duplicate_checked = .{
            .evidence = bbr.diagnostic.Failure.capture(.duplicate_check, .execute, diagnostic.context, .{ .zig = err }, @src()),
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
    const checked = poster.poster().findExisting(command.draft, command.parent) catch |err| blk: {
        _ = client.diagnostic.failure(.execute, .{ .zig = err }, @src());
        break :blk bbr.review.CheckResult{ .outcome = .ambiguous };
    };
    const outcome: presentation.DuplicateCheckOutcome = switch (checked.outcome) {
        .found => |id| .{ .found = id },
        .missing => .missing,
        .rejected => |err| rejected: {
            _ = client.diagnostic.failure(.rejection, .{ .zig = err }, @src());
            break :rejected .{ .rejected = err };
        },
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
    diagnostic: bbr.diagnostics.Handle,
    client: bbr.bitbucket.Client,
    command: presentation.ListPullRequests,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    presentation_runtime.deliver(presentationSink(&sink_context), presentation_adapter.listPullRequests(std.heap.page_allocator, sink_context.bitbucket(client), command));
}

fn presentationCodeHighlightWorker(loop: *Loop, work_id: u64, diagnostic: bbr.diagnostics.Handle, highlighter: bbr.highlight.Highlighter, command: *@import("code_highlighting.zig").Analyze) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id, .diagnostic = diagnostic };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .code_highlight_completed = command.execute(highlighter.withDiagnostics(diagnostic)) });
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
        if (command == .report_diagnostic) {
            ctx.diagnostic.record(command.report_diagnostic);
            continue;
        }
        if (command == .set_diagnostics) {
            const actual = if (ctx.diagnostic.sink) |sink| sink.setEnabled(command.set_diagnostics.enabled) else .off;
            try state.dispatch(.{ .diagnostics_changed = .{ .command_id = command.set_diagnostics.command_id, .state = actual } });
            continue;
        }
        if (command == .copy_clipboard) {
            const diagnostic = presentation_runtime.commandHandle(command, ctx.diagnostic, null);
            const input = presentation_adapter.copyToClipboard(vx.*, tty.writer(), command.copy_clipboard);
            command = undefined;
            presentation_runtime.recordFailures(diagnostic, input);
            try state.dispatch(input);
            continue;
        }
        // config.toml is at most 64 KiB, so the write runs on the terminal
        // thread and completes before the next event.
        if (command == .persist_theme) {
            const diagnostic = presentation_runtime.commandHandle(command, ctx.diagnostic, null);
            const persist = command.persist_theme;
            const outcome: presentation.ThemePersisted.Outcome = if (config.persistTheme(ctx.gpa, ctx.io, ctx.env_map, persist.theme)) |_| .saved else |err| blk: {
                _ = diagnostic.failure(.write, .{ .zig = err }, @src());
                switch (err) {
                    error.Canceled => ctx.io.recancel(),
                    else => {},
                }
                break :blk themeSaveOutcome(err);
            };
            try state.dispatch(.{ .theme_persisted = .{ .command_id = persist.command_id, .outcome = outcome } });
            continue;
        }
        if (command == .external_edit) {
            const diagnostic = presentation_runtime.commandHandle(command, ctx.diagnostic, null);
            var handoff_context: TerminalHandoffContext = .{
                .ctx = ctx,
                .loop = loop,
                .tty = tty,
                .tty_active = tty_active,
                .vx = vx,
                .write_buf = write_buf,
            };
            const completed = presentation_adapter.externalEdit(ctx.io, ctx.env_map, handoff_context.handoff(), command.external_edit) catch |err| {
                command = undefined;
                return err;
            };
            command = undefined;
            presentation_runtime.recordFailures(diagnostic, .{ .external_edit_completed = completed });
            const restoration_failed = completed.outcome == .restoration_failed;
            const retained_path = if (restoration_failed) completed.outcome.restoration_failed else null;
            if (retained_path) |path| {
                std.debug.print("bbr: terminal restoration failed; External Edit file retained at {s}\n", .{path});
                std.process.exit(1);
            }
            try state.dispatch(.{ .external_edit_completed = completed });
            continue;
        }
        futures.ensureUnusedCapacity(ctx.gpa, 1) catch |err| {
            const diagnostic = presentation_runtime.commandHandle(command, ctx.diagnostic, null);
            const input = try command.launchFailed(err);
            presentation_runtime.recordFailures(diagnostic, input);
            try state.dispatch(input);
            continue;
        };
        const work_id = next_work_id.*;
        next_work_id.* +%= 1;
        const diagnostic = presentation_runtime.commandHandle(command, ctx.diagnostic, work_id);
        const client = if (ctx.bitbucket) |value| value.withDiagnostics(diagnostic) else null;
        const future = switch (command) {
            .load_session => |load| bbr.diagnostics.concurrent(ctx.io, presentationLoadWorker, .{ loop, work_id, diagnostic, ctx.io, workerBitbucketForReviewKind(client, load.key.kind), load }),
            .prepare_session => |job| bbr.diagnostics.concurrent(ctx.io, presentationPrepareSessionWorker, .{ loop, work_id, diagnostic, job }),
            .enrich_file => |enrich| bbr.diagnostics.concurrent(ctx.io, presentationEnrichmentWorker, .{ loop, work_id, diagnostic, ctx.io, workerBitbucketForEnrichment(client, enrich.source), ctx.highlighter, enrich }),
            .highlight_code => |job| bbr.diagnostics.concurrent(ctx.io, presentationCodeHighlightWorker, .{ loop, work_id, diagnostic, ctx.highlighter, job }),
            .post_draft => |post| bbr.diagnostics.concurrent(ctx.io, presentationPostWorker, .{ loop, work_id, diagnostic, client.?, post }),
            .update_comment => |update| bbr.diagnostics.concurrent(ctx.io, presentationCommentEditWorker, .{ loop, work_id, diagnostic, client.?, update }),
            .delete_comment => |delete| bbr.diagnostics.concurrent(ctx.io, presentationCommentDeleteWorker, .{ loop, work_id, diagnostic, client.?, delete }),
            .change_reviewer_verdict => |verdict| bbr.diagnostics.concurrent(ctx.io, presentationReviewerVerdictWorker, .{ loop, work_id, diagnostic, client.?, verdict }),
            .wait_submission => |wait| bbr.diagnostics.concurrent(ctx.io, presentationWaitWorker, .{ loop, work_id, diagnostic, ctx.io, wait }),
            .check_recovery => |check| bbr.diagnostics.concurrent(ctx.io, presentationRecoveryCheckWorker, .{ loop, work_id, diagnostic, client.?, check }),
            .find_duplicate => |check| bbr.diagnostics.concurrent(ctx.io, presentationDuplicateCheckWorker, .{ loop, work_id, diagnostic, client.?, check }),
            .list_pull_requests => |list| bbr.diagnostics.concurrent(ctx.io, presentationListPullRequestsWorker, .{ loop, work_id, diagnostic, client.?, list }),
            .copy_clipboard, .persist_theme, .set_diagnostics, .report_diagnostic => unreachable,
            .external_edit => unreachable,
            .scan_buffer_search => |scan| bbr.diagnostics.concurrent(ctx.io, presentationBufferSearchWorker, .{ loop, work_id, diagnostic, scan }),
            .build_buffer_disclosure => |job| bbr.diagnostics.concurrent(ctx.io, presentationDisclosureWorker, .{ loop, work_id, diagnostic, job }),
            .scan_review_source => |scan| bbr.diagnostics.concurrent(ctx.io, presentationReviewSourceWorker, .{ loop, work_id, diagnostic, scan }),
        } catch |err| {
            const input = try command.launchFailed(err);
            presentation_runtime.recordFailures(diagnostic, input);
            try state.dispatch(input);
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
    main_pane: presentation.MainPane = .diff_pane,
    /// The 1-based cursor row or selected Overview Entry, or 0 when empty.
    position: usize,
    total: usize,
    layout: buffer_mod.Layout,
    scope: presentation.Scope,
    isolate: bool,
    loading: bool = false,
    submitting: bool = false,
    draft_count: usize = 0,
    status_msg: ?[]const u8 = null,
    diagnostic_state: bbr.diagnostic.State = .off,
    searching: bool = false,
    search_has_no_matches: bool = false,
};

/// Diagnostic logging state is its own meta item, so it never hides an
/// operation status or the key hints.
fn diagnosticStatus(state: bbr.diagnostic.State) ?[]const u8 {
    return switch (state) {
        .on => "diagnostic logging enabled",
        .unavailable => "diagnostic logging unavailable",
        .off => null,
    };
}

fn projectionStatusItems(frame: std.mem.Allocator, projection: presentation.Projection) StatusItems {
    const active_theme = theme.value(projection.theme);
    const review = projection.review orelse return loadingStatusItems(active_theme, presentationStatus(frame, projection, null), projection.diagnostic_state);
    const visual_cursor = review.navigation.cursor;
    const overview = review.frame.overview;
    return statusItems(frame, active_theme, .{
        .header = review.header,
        .reviewer_verdict = review.reviewer_verdict,
        .main_pane = review.frame.main_pane,
        .position = switch (review.frame.main_pane) {
            .diff_pane => @min(visual_cursor + 1, review.buffer.rows.len),
            .comment_overview => if (overview.selected) |index| index + 1 else 0,
        },
        .total = switch (review.frame.main_pane) {
            .diff_pane => review.buffer.rows.len,
            .comment_overview => overview.listing.entries.len,
        },
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
        .diagnostic_state = projection.diagnostic_state,
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
            items.add(.title, std.fmt.allocPrint(frame, "#{d}", .{id}) catch |err| switch (err) {
                error.OutOfMemory => "#",
            }, .pull_request);
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
        items.add(.position, std.fmt.allocPrint(frame, "{d}/{d}", .{ facts.position, facts.total }) catch |err| switch (err) {
            error.OutOfMemory => "",
        }, .position);
        items.position_width = @intCast(std.fmt.count("{d}/{d}", .{ facts.total, facts.total }));
        if (diagnosticStatus(facts.diagnostic_state)) |text| items.add(.diagnostics, text, .message);
    }
    switch (facts.main_pane) {
        .diff_pane => {
            items.hint(.layout, "s", if (facts.layout == .unified) " split" else " unified");
            // Names the *current* scope; `f` cycles Changes → fetched → whole.
            items.hint(.scope, "f", switch (facts.scope) {
                .changes => ": changes",
                .fetched => ": fetched",
                .whole => ": whole",
            });
            items.hint(.isolate, "o", if (facts.isolate) " all files" else " isolate");
        },
        .comment_overview => {},
    }
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
            items.add(.submit, std.fmt.allocPrint(frame, " submit {d}", .{facts.draft_count}) catch |err| switch (err) {
                error.OutOfMemory => " submit",
            }, .drafts);
        }
        switch (facts.main_pane) {
            .diff_pane => {
                items.hint(.comment, "c/i", " comment");
                items.hint(.file, "[ ]", " file");
                items.hint(.main_pane, "g o", " comments");
                items.hint(.switch_review, "p", " switch");
            },
            .comment_overview => {
                items.hint(.filter, "/", " filter");
                items.hint(.open, "↵", " open");
                items.hint(.main_pane, "g d", " DiffPane");
            },
        }
        items.hint(.help, "?", " help");
        items.hint(.quit, "q", " quit");
    }
    return items;
}

/// Before a review exists, the hint part holds the loading message alone.
fn loadingStatusItems(active_theme: theme.Theme, status_msg: ?[]const u8, diagnostic_state: bbr.diagnostic.State) StatusItems {
    var items: StatusItems = .init(active_theme);
    if (diagnosticStatus(diagnostic_state)) |text| items.add(.diagnostics, text, .message);
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
    _ = @import("help.zig");
    _ = @import("list_overlay.zig");
    _ = @import("theme_id.zig");
    _ = @import("session.zig");
    _ = @import("arena_ring.zig");
    _ = @import("composer.zig");
    _ = @import("file_enrichment.zig");
    _ = @import("presentation_adapter.zig");
    _ = @import("presentation_runtime.zig");
}

test "a directory config.toml is a read failure on the Theme status" {
    try std.testing.expectEqual(presentation.ThemePersisted.Outcome.read_failed, themeSaveOutcome(error.IsDir));
    try std.testing.expectEqual(presentation.ThemePersisted.Outcome.write_failed, themeSaveOutcome(error.WriteFailed));
    try std.testing.expectEqual(presentation.ThemePersisted.Outcome.write_failed, themeSaveOutcome(error.Canceled));
    try std.testing.expectEqualStrings("Theme applied, but config.toml could not be read", actionErrorText(.theme_not_saved_unreadable));
    try std.testing.expectEqualStrings("Theme applied, but config.toml could not be written", actionErrorText(.theme_not_saved));
    try std.testing.expectEqualStrings("an Anchor range must run forward", actionErrorText(.anchor_range_descending));
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

var test_store_diagnostic: bbr.diagnostics.Handle = .{};

fn failTestLoad(_: *anyopaque, _: std.mem.Allocator, _: bbr.review.RemoteReviewIdentity) anyerror![]bbr.review.Draft {
    return test_store_diagnostic.fail(.step, .{ .sqlite = .{ .result = 7, .extended = 7 } }, @src());
}

/// An Io that captures stderr writes and fails every other operation.
const TestStderr = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.operate = operate;
        break :blk table;
    };

    fn io(self: *TestStderr) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self: *TestStderr = @ptrCast(@alignCast(userdata.?));
        const write = switch (operation) {
            .file_write_streaming => |write| write,
            else => unreachable,
        };
        std.debug.assert(write.file.handle == std.Io.File.stderr().handle);
        var writer = std.Io.Writer.fixed(self.buffer[self.len..]);
        writer.writeAll(write.header) catch |err| switch (err) {
            error.WriteFailed => return .{ .file_write_streaming = error.NoSpaceLeft },
        };
        for (write.data, 0..) |part, index| for (0..if (index + 1 == write.data.len) write.splat else 1) |_| writer.writeAll(part) catch |err| switch (err) {
            error.WriteFailed => return .{ .file_write_streaming = error.NoSpaceLeft },
        };
        self.len += writer.buffered().len;
        return .{ .file_write_streaming = writer.buffered().len };
    }
};

fn testBoundedText(comptime T: type, value: []const u8) T {
    var text: T = .{ .len = value.len };
    @memcpy(text.bytes[0..value.len], value);
    return text;
}

test "diagnostics a canceled File Enrichment worker keeps its retirement completion and rearms cancellation" {
    const Rearmed = struct {
        var count: usize = 0;

        fn recancel(_: ?*anyopaque) void {
            count += 1;
        }
    };
    Rearmed.count = 0;
    var vtable = std.testing.io.vtable.*;
    vtable.recancel = Rearmed.recancel;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var loop: Loop = .init(std.testing.io, undefined, undefined);
    var fake: bbr.http.FakeHttpClient = .{ .send_error = error.Canceled };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var plain: bbr.highlight.PlainHighlighter = .{};
    const Command = presentation.EnrichFile;
    presentationEnrichmentWorker(&loop, 9, .{}, io, client, plain.highlighter(), .{
        .work_id = 9,
        .session_epoch = 1,
        .file_index = 0,
        .source = .{ .remote = testBoundedText(@FieldType(@FieldType(Command, "source"), "remote"), "repo") },
        .source_commit = testBoundedText(@FieldType(Command, "source_commit"), "source"),
        .destination_commit = testBoundedText(@FieldType(Command, "destination_commit"), "destination"),
        .old_path = testBoundedText(@FieldType(Command, "old_path"), "file.zig"),
        .new_path = testBoundedText(@FieldType(Command, "new_path"), "file.zig"),
        .status = .modified,
        .max_file_bytes = 0,
    });
    var done = (try loop.tryEvent()).?.presentation_done;
    defer done.input.deinit();
    try std.testing.expectEqual(@as(u64, 9), done.work_id);
    try std.testing.expect(done.input.file_enrichment_completed.evidence == null);
    try std.testing.expectEqual(presentation.FileEnrichmentOutcome{ .failed = .launch_failed }, done.input.file_enrichment_completed.outcome);
    try std.testing.expectEqual(@as(usize, 1), Rearmed.count);
    try std.testing.expect((try loop.tryEvent()) == null);
}

test "diagnostics a transport OutOfMemory on one File side keeps its phase in the worker record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", home);
    var sink = bbr.diagnostics.Sink.init(std.testing.allocator, std.testing.io, &env);
    defer sink.deinit();
    try std.testing.expect(sink.setEnabled(true) == .on);
    const responses = [_]bbr.http.Canned{
        .{ .request_key = "/destination/", .send_error = error.OutOfMemory, .send_phase = .receive_body },
        .{ .request_key = "/source/", .status = 200, .body = "new" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    // The worker gets the spawn handle and client, which have no slot, as `drainPresentationCommands` passes them.
    const spawn_handle = sink.handle(.file_enrichment, .{ .work_id = 9 });
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" }).withDiagnostics(spawn_handle);
    var sink_context: PresentationSinkContext = .{ .loop = undefined, .work_id = 9, .diagnostic = spawn_handle };
    const Command = presentation.EnrichFile;
    var plain: bbr.highlight.PlainHighlighter = .{};
    var input = try enrichFileInput(&sink_context, std.testing.io, client, plain.highlighter(), .{
        .work_id = 9,
        .session_epoch = 1,
        .file_index = 0,
        .source = .{ .remote = testBoundedText(@FieldType(@FieldType(Command, "source"), "remote"), "repo") },
        .source_commit = testBoundedText(@FieldType(Command, "source_commit"), "source"),
        .destination_commit = testBoundedText(@FieldType(Command, "destination_commit"), "destination"),
        .old_path = testBoundedText(@FieldType(Command, "old_path"), "file.zig"),
        .new_path = testBoundedText(@FieldType(Command, "new_path"), "file.zig"),
        .status = .modified,
        .max_file_bytes = 0,
    });
    defer input.deinit();
    try std.testing.expect(input.file_enrichment_completed.outcome == .failed);
    presentation_runtime.recordFailures(sink_context.handle(), input);
    _ = sink.setEnabled(false);
    var dir = try tmp.dir.openDir(std.testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(std.testing.io)).?;
    const bytes = try dir.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    _ = lines.next();
    const only = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, only, "operation=file_enrichment phase=receive_body source=tui/app.zig:") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "work_id=9") != null);
    try std.testing.expect(std.mem.endsWith(u8, only, "cause=zig error=OutOfMemory"));
}

test "diagnostics the worker Session load spawns with its own slot and its one record keeps the status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", home);
    var sink = bbr.diagnostics.Sink.init(std.testing.allocator, std.testing.io, &env);
    defer sink.deinit();
    try std.testing.expect(sink.setEnabled(true) == .on);
    const responses = [_]bbr.http.Canned{
        .{ .request_key = "/2.0/user", .body = "{\"uuid\":\"{account}\"}" },
        .{ .request_key = "/pullrequests/7/diff", .body = "" },
        .{ .request_key = "/pullrequests/7", .status = 404, .body = "{}" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    // The worker gets the spawn handle and client, which have no slot, as `drainPresentationCommands` passes them.
    // A Debug build panics when the worker spawns its load with a handle that has a slot.
    const spawn_handle = sink.handle(.session_load, .{ .work_id = 4 });
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" }).withDiagnostics(spawn_handle);
    var loop: Loop = .init(std.testing.io, undefined, undefined);
    presentationLoadWorker(&loop, 4, spawn_handle, std.testing.io, client, .{
        .command_id = 8,
        .intent = 3,
        .key = try presentation.OwnedReviewIdentity.init("ws", "repo", 7),
    });
    var event = (try loop.tryEvent()) orelse return error.TestUnexpectedResult;
    defer event.presentation_done.input.deinit();
    const loaded = event.presentation_done.input.session_loaded;
    try std.testing.expectEqual(error.NotFound, loaded.outcome.failed);
    _ = sink.setEnabled(false);
    var dir = try tmp.dir.openDir(std.testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(std.testing.io)).?;
    const bytes = try dir.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    _ = lines.next();
    const only = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, only, "operation=session_load phase=rejection source=tui/app.zig:") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "work_id=4") != null);
    try std.testing.expect(std.mem.endsWith(u8, only, "cause=http status=404 classification=not_found"));
}

test "diagnostics an initial load that the store reported shows its message and keeps one record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", home);
    var sink = bbr.diagnostics.Sink.init(std.testing.allocator, std.testing.io, &env);
    defer sink.deinit();
    try std.testing.expect(sink.setEnabled(true) == .on);
    test_store_diagnostic = sink.handle(.persistence, .{});
    defer test_store_diagnostic = .{};

    var store = bbr.review.InMemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var vtable = store.store().vtable.*;
    vtable.load = failTestLoad;
    var reviews = store.store();
    reviews.vtable = &vtable;
    const initial = try session.create(std.testing.allocator);
    initial.diff = .{ .files = &.{} };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var output: TestStderr = .{};
    try std.testing.expectError(error.Reported, run(.{
        .diagnostic = sink.handle(.session_load, .{}),
        .io = output.io(),
        .gpa = std.testing.allocator,
        .env_map = &env,
        .repo = "",
        .store = reviews,
        .theme = .dark,
        .keymap = keymap.Keymap.default,
        .highlighter = plain.highlighter(),
        .highlight_max_file_bytes = 0,
        .file_cache_enabled = false,
        .inactive_file_cache_max_bytes = 0,
        .comments_collapsed_rows = 0,
        .online = false,
    }, initial, try presentation.OwnedReviewIdentity.init("workspace", "repo", 1)));
    try std.testing.expectEqualStrings("bbr: could not load the pending review drafts\n", output.buffer[0..output.len]);
    _ = sink.setEnabled(false);
    var dir = try tmp.dir.openDir(std.testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(std.testing.io)).?;
    const bytes = try dir.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    _ = lines.next();
    const only = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.endsWith(u8, only, "cause=sqlite result=7 extended=7"));
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
    diagnostic_state: bbr.diagnostic.State = .off,
    searching: bool = false,
    search_has_no_matches: bool = false,
    main_pane: presentation.MainPane = .diff_pane,
};

fn testStatusItems(arena: std.mem.Allocator, active_theme: theme.Theme, case: TestStatus) StatusItems {
    return statusItems(arena, active_theme, .{
        .header = .{ .pull_request_id = 7, .title = case.title, .source_ref = "review", .base_ref = "main", .source_commit = "", .base_commit = "", .locator = "", .source_label = "" },
        .reviewer_verdict = case.verdict,
        .main_pane = case.main_pane,
        .position = case.position,
        .total = case.total,
        .layout = .unified,
        .scope = .changes,
        .isolate = false,
        .loading = case.loading,
        .draft_count = 2,
        .status_msg = case.status_msg,
        .diagnostic_state = case.diagnostic_state,
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
    try std.testing.expectEqualStrings("s split  ·  f: changes  ·  o isolate  ·  g o comments  ·  X submit 2  ·  c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit", wide[1]);

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

test "M29 overview the status shows the Comment Overview hints and the listing position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try testStatusRows(a, try testDrawStatus(a, theme.dark, .{ .main_pane = .comment_overview, .position = 3, .total = 12 }));
    try std.testing.expect(std.mem.endsWith(u8, rows[0], "3/12"));
    try std.testing.expectEqualStrings("/ filter  ·  ↵ open  ·  g d DiffPane  ·  X submit 2  ·  ? help  ·  q quit", rows[1]);
    try std.testing.expectEqualStrings("The entry is no longer in the Review", actionErrorText(.overview_entry_unavailable));
    try std.testing.expectEqualStrings("Comment Overview filters cleared to show the entry", actionErrorText(.overview_filters_cleared));
}

test "diagnostic logging state is a meta item that hides no status message or key hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enabled = try testStatusRows(a, try testDrawStatus(a, theme.dark, .{ .diagnostic_state = .on }));
    try std.testing.expectEqualStrings("#7 Fix parser  ·  Approved  ·  review → main  ·  1/1  ·  diagnostic logging enabled", enabled[0]);
    try std.testing.expect(std.mem.indexOf(u8, enabled[1], "? help") != null);
    const copied = try testStatusRows(a, try testDrawStatus(a, theme.dark, .{ .diagnostic_state = .on, .status_msg = "copied text" }));
    try std.testing.expect(std.mem.indexOf(u8, copied[0], "diagnostic logging enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied[1], "copied text") != null);
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
    io.sleep(std.Io.Duration.fromSeconds(60), .awake) catch |err| switch (err) {
        error.Canceled => return,
    };
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

/// Set when a test Picker tick reaches its wait, so the test cancels it there.
var test_picker_tick_waits: std.Io.Event = .unset;

/// A Picker tick wait that only a cancel ends.
fn testSleepUntilCanceled(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
    const io: std.Io = .{ .userdata = userdata, .vtable = std.testing.io.vtable };
    test_picker_tick_waits.set(io);
    var never: std.Io.Event = .unset;
    return never.wait(io);
}

/// A Picker tick wait that ends at once.
fn testSleepNotAtAll(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
    test_picker_tick_waits.set(.{ .userdata = userdata, .vtable = std.testing.io.vtable });
}

fn testPickerTickIo(vtable: *std.Io.VTable, sleep: @FieldType(std.Io.VTable, "sleep")) std.Io {
    vtable.* = std.testing.io.vtable.*;
    vtable.sleep = sleep;
    test_picker_tick_waits = .unset;
    return .{ .userdata = std.testing.io.userdata, .vtable = vtable };
}

test "a Picker tick canceled in its wait posts no tick" {
    var vtable: std.Io.VTable = undefined;
    const worker_io = testPickerTickIo(&vtable, testSleepUntilCanceled);
    var loop: Loop = .init(std.testing.io, undefined, undefined);
    var future = try std.testing.io.concurrent(pickerTickWorker, .{ &loop, 3, 7, worker_io });
    try test_picker_tick_waits.wait(std.testing.io);
    future.cancel(std.testing.io);
    try std.testing.expect((try loop.tryEvent()) == null);
}

test "diagnostics a canceled Submission wait retires its worker without failure evidence" {
    var vtable: std.Io.VTable = undefined;
    const worker_io = testPickerTickIo(&vtable, testSleepUntilCanceled);
    var loop: Loop = .init(std.testing.io, undefined, undefined);
    var futures: std.ArrayList(PresentationWork) = .empty;
    defer futures.deinit(std.testing.allocator);
    var future = try std.testing.io.concurrent(presentationWaitWorker, .{ &loop, 3, bbr.diagnostics.Handle{}, worker_io, presentation.WaitSubmission{
        .operation_id = 1,
        .temp_id = 1,
        .ms = 60000,
    } });
    try test_picker_tick_waits.wait(std.testing.io);
    future.cancel(std.testing.io);
    try futures.append(std.testing.allocator, .{ .id = 3, .future = future });
    const done = (try loop.tryEvent()).?.presentation_done;
    try std.testing.expectEqual(@as(u64, 3), done.work_id);
    try std.testing.expect(done.input.submission_wait_launch_failed.evidence == null);
    reapPresentationWork(&futures, std.testing.io, done.work_id);
    try std.testing.expectEqual(@as(usize, 0), futures.items.len);
    try std.testing.expect((try loop.tryEvent()) == null);
}

test "a Picker tick canceled while the event queue is full ends without its tick" {
    var vtable: std.Io.VTable = undefined;
    const worker_io = testPickerTickIo(&vtable, testSleepNotAtAll);
    var loop: Loop = .init(std.testing.io, undefined, undefined);
    var capacity: usize = 0;
    while (try loop.tryPostEvent(.{ .picker_tick = .{ .future_id = 1, .scope = 1 } })) capacity += 1;
    var future = try std.testing.io.concurrent(pickerTickWorker, .{ &loop, 3, 7, worker_io });
    try test_picker_tick_waits.wait(std.testing.io);
    future.cancel(std.testing.io);
    var queued: usize = 0;
    while (try loop.tryEvent()) |event| : (queued += 1) try std.testing.expectEqual(@as(u64, 1), event.picker_tick.future_id);
    try std.testing.expectEqual(capacity, queued);
}

test "diagnostics a completed Submission wait canceled with a full event queue still retires its worker" {
    const Race = struct {
        var delivery: std.Io.Event = .unset;

        fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const io: std.Io = .{ .userdata = userdata, .vtable = std.testing.io.vtable };
            testSleepUntilCanceled(userdata, timeout) catch |err| switch (err) {
                error.Canceled => io.recancel(),
            };
        }

        fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const io: std.Io = .{ .userdata = userdata, .vtable = std.testing.io.vtable };
            try io.checkCancel();
            delivery.set(io);
            return io.vtable.futexWait(userdata, ptr, expected, timeout);
        }

        fn run(loop: *Loop, io: std.Io, wait: presentation.WaitSubmission) void {
            presentationWaitWorker(loop, 3, .{}, io, wait);
            delivery.set(std.testing.io);
        }

        fn drain(loop: *Loop, count: usize) !void {
            try delivery.wait(std.testing.io);
            for (0..count) |_| try std.testing.expectEqual(@as(u64, 1), (try loop.nextEvent()).picker_tick.future_id);
        }
    };
    Race.delivery = .unset;
    var vtable: std.Io.VTable = undefined;
    const worker_io = testPickerTickIo(&vtable, Race.sleep);
    var queue_vtable = std.testing.io.vtable.*;
    queue_vtable.futexWait = Race.futexWait;
    var loop: Loop = .init(.{ .userdata = std.testing.io.userdata, .vtable = &queue_vtable }, undefined, undefined);
    var capacity: usize = 0;
    while (try loop.tryPostEvent(.{ .picker_tick = .{ .future_id = 1, .scope = 1 } })) capacity += 1;
    var futures: std.ArrayList(PresentationWork) = .empty;
    defer futures.deinit(std.testing.allocator);
    const wait: presentation.WaitSubmission = .{ .operation_id = 1, .temp_id = 1, .ms = 1 };
    var future = try std.testing.io.concurrent(Race.run, .{ &loop, worker_io, wait });
    try test_picker_tick_waits.wait(std.testing.io);
    var drain = try std.testing.io.concurrent(Race.drain, .{ &loop, capacity });
    defer drain.await(std.testing.io) catch unreachable;
    future.cancel(std.testing.io);
    try drain.await(std.testing.io);
    try futures.append(std.testing.allocator, .{ .id = 3, .future = future });
    const event = (try loop.tryEvent()) orelse return error.TestUnexpectedResult;
    const done = event.presentation_done;
    try std.testing.expectEqual(@as(u64, 3), done.work_id);
    try std.testing.expectEqualDeep(wait, done.input.submission_wait_completed);
    try std.testing.expect(done.input.submission_wait_completed.evidence == null);
    reapPresentationWork(&futures, std.testing.io, done.work_id);
    try std.testing.expectEqual(@as(usize, 0), futures.items.len);
    try std.testing.expect((try loop.tryEvent()) == null);
}

fn testStalledLoad(io: std.Io) anyerror!*Session {
    try io.sleep(std.Io.Duration.fromSeconds(60), .awake);
    return error.TestUnexpectedResult;
}

fn testQuickLoad() anyerror!*Session {
    return session.create(std.heap.page_allocator);
}

test "a stalled Session load times out and its load is canceled" {
    const io = std.testing.io;
    const started = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, loadSessionWithin(io, std.Io.Duration.fromMilliseconds(20), testStalledLoad, .{io}));
    // The stalled load sleeps for 60 seconds, so a quick return proves its cancelation.
    try std.testing.expect(started.untilNow(io, .awake).toSeconds() < 10);
}

test "a Session load that finishes before its timeout returns the Session" {
    const loaded = try loadSessionWithin(std.testing.io, std.Io.Duration.fromSeconds(60), testQuickLoad, .{});
    loaded.destroy();
}
