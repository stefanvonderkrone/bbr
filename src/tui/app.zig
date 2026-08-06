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
const theme = @import("theme.zig");
const Nav = @import("nav.zig").Nav;
const keymap = @import("keymap.zig");
const session = @import("session.zig");
const file_enrichment = @import("file_enrichment.zig");
const presentation_adapter = @import("presentation_adapter.zig");
const presentation_runtime = @import("presentation_runtime.zig");
const presentation = @import("presentation.zig");
const buffer_mod = @import("buffer.zig");
const Session = session.Session;

const Credential = bbr.bitbucket.Credential;
const PendingReviewStore = bbr.review.PendingReviewStore;

/// Everything `run` needs to fetch and switch PRs. `online` is false for the
/// offline `demo`, which disables the network-backed Picker. `store` persists
/// the reviewer's pending Drafts (SQLite in production, `:memory:` for demo).
pub const RunCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    repo: []const u8,
    store: PendingReviewStore,
    active_theme: theme.Theme,
    keymap: keymap.Keymap,
    highlighter: bbr.highlight.Highlighter,
    highlight_max_file_bytes: usize,
    file_cache_enabled: bool,
    inactive_file_cache_max_bytes: usize,
    comments_collapsed_rows: usize,
    mouse_enabled: bool = true,
    mouse_vertical_scroll_rows: usize = 3,
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

fn runPresentation(ctx: RunCtx, initial: ?*Session, initial_key: presentation.ReviewKey) !void {
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
        .require_source_check = ctx.online,
        .keymap = ctx.keymap,
        .remote_enabled = ctx.online,
        .cell_metrics = vaxis_cell_metrics,
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
    defer tty.deinit();
    const writer = tty.writer();
    var vx = try vaxis.init(ctx.io, ctx.gpa, ctx.env_map, .{});
    defer vx.deinit(ctx.gpa, writer);
    var loop: Loop = .init(ctx.io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);
    if (ctx.mouse_enabled) try vx.setMouseMode(writer, true);
    try state.dispatch(.{ .resize = contentGeometry(vx.window()) });

    var futures: std.ArrayList(PresentationWork) = .empty;
    defer {
        for (futures.items) |*work| _ = work.future.await(ctx.io);
        futures.deinit(ctx.gpa);
    }
    var next_work_id: u64 = 1;
    var picker_tick_work: ?PickerTickWork = null;
    var frame_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer frame_arena.deinit();

    try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, vx, writer);
    try syncPickerTick(&state, ctx, &loop, &futures, &next_work_id, &picker_tick_work);
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try state.dispatch(.{ .key = portableKey(key) }),
            .mouse => |mouse| if (portableMouse(mouse)) |input| try state.dispatch(.{ .mouse = input }),
            .winsize => |winsize| {
                try vx.resize(ctx.gpa, writer, winsize);
                try state.dispatch(.{ .resize = contentGeometry(vx.window()) });
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

        try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, vx, writer);
        if (state.projection().review != null) {
            try state.dispatch(.ensure_focused_enrichment);
            try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id, vx, writer);
        }
        try syncPickerTick(&state, ctx, &loop, &futures, &next_work_id, &picker_tick_work);
        // A completed worker may still own a payload queued for Presentation.
        // Keep the loop alive until every completion has been received and
        // reaped so shutdown cannot strand that payload in the event queue.
        if (state.readyToExit() and futures.items.len == 0) break;

        const projection = state.projection();
        const win = vx.window();
        const content_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = win.height -| 1,
        });
        const frame = frame_arena.allocator();
        if (projection.review) |review_projection| {
            const selected_file = fileIndexForRow(review_projection.frame.buffer, review_projection.frame.navigation.cursor);
            render.drawReview(frame, content_win, review_projection, ctx.active_theme, selected_file);
            const status = presentationStatus(frame, projection, review_projection.key);
            drawStatus(
                frame,
                win,
                review_projection.header,
                review_projection.navigation,
                review_projection.buffer,
                review_projection.preferences.layout,
                switch (review_projection.preferences.scope) {
                    .changes => .changes,
                    .fetched => .fetched,
                    .whole => .whole,
                },
                review_projection.isolated_file != null,
                projection.replacing,
                projection.submission != null,
                review_projection.drafts.len,
                status,
            );
        } else {
            const status = presentationStatus(frame, projection, null);
            render.drawLoading(frame, content_win, projection.loading_pull_request_id, ctx.active_theme, status);
        }
        if (projection.picker) |active_picker| render.drawPicker(frame, content_win, active_picker, ctx.active_theme);
        if (projection.file_finder) |finder| render.drawFileFinder(frame, content_win, finder, ctx.active_theme);
        if (projection.composer) |composer| render.drawComposerProjection(frame, content_win, composer, ctx.active_theme);
        if (projection.unknown_resolution) |resolution| render.drawComposerProjection(frame, content_win, .{
            .label = "Link existing Bitbucket Comment ID",
            .body = resolution.comment_id,
        }, ctx.active_theme);
        if (projection.submission) |submission| {
            if (projection.review) |review_projection| if (presentation.ReviewKey.eql(submission.key, review_projection.key))
                render.drawSubmit(frame, content_win, ctx.active_theme, submission.completed, submission.total);
        } else if (projection.submission_result) |result| {
            if (projection.review) |review_projection| if (presentation.ReviewKey.eql(result.key, review_projection.key))
                render.drawSubmitResult(
                    frame,
                    content_win,
                    ctx.active_theme,
                    result.posted,
                    result.failed + result.outcome_unknown,
                    result.skipped,
                    submissionAbortName(result.completion),
                    false,
                );
        }
        if (projection.help_visible) render.drawHelp(frame, content_win, ctx.active_theme, ctx.keymap, projection.action_availability);
        try vx.render(writer);
        _ = frame_arena.reset(.retain_capacity);
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

const metrics_context: u8 = 0;
const metrics_vtable: @import("cell_metrics.zig").CellMetrics.VTable = .{ .next = nextVaxisGrapheme };
const vaxis_cell_metrics: @import("cell_metrics.zig").CellMetrics = .{ .ptr = &metrics_context, .vtable = &metrics_vtable };

fn nextVaxisGrapheme(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
    var iterator = vaxis.unicode.graphemeIterator(text);
    const grapheme = iterator.next() orelse return .{ .byte_len = 1, .cell_width = 1 };
    return .{
        .byte_len = grapheme.len,
        .cell_width = vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode),
    };
}

fn contentGeometry(win: vaxis.Window) presentation.FrameGeometry {
    return .{ .cols = win.width, .rows = @intCast(contentViewportRows(win.height)) };
}

fn presentationStatus(
    frame: std.mem.Allocator,
    projection: presentation.Projection,
    visible_key: ?presentation.ReviewKey,
) ?[]const u8 {
    if (projection.fatal_error) |err| return @tagName(err);
    if (projection.action_error) |err| return switch (err) {
        .local_review_no_picker => "Pull Request Picker is unavailable for a local review",
        .local_review_no_submission => "Submit is unavailable for a local review; drafts remain local",
        .local_review_remote_action_unavailable => "This action is unavailable for a local review",
        .source_action_unavailable => "This action requires a source line or Selection",
        .target_action_unavailable => "This action is unavailable for the current target",
        else => @tagName(err),
    };
    if (projection.clipboard_status) |status| return switch (status) {
        .copied => "copied source text",
        .failed => "could not copy source text",
    };
    if (projection.shutting_down) {
        if (projection.submission) |submission|
            return std.fmt.allocPrint(frame, "finishing Submission for {s}#{d}", .{ submission.key.repository(), submission.key.pull_request_id }) catch "finishing Submission";
        return "shutting down…";
    }
    if (projection.submission) |submission| {
        if (visible_key == null or !presentation.ReviewKey.eql(submission.key, visible_key.?))
            return std.fmt.allocPrint(frame, "submitting {s}#{d} · {d}/{d}", .{
                submission.key.repository(),
                submission.key.pull_request_id,
                submission.completed,
                submission.total,
            }) catch "submitting another pull request…";
    }
    if (projection.submission_result) |result| {
        if (visible_key == null or !presentation.ReviewKey.eql(result.key, visible_key.?))
            return std.fmt.allocPrint(frame, "{s}#{d}: {d} posted · {d} failed · {d} skipped", .{
                result.key.repository(),
                result.key.pull_request_id,
                result.posted,
                result.failed + result.outcome_unknown,
                result.skipped,
            }) catch "submission finished for another pull request";
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

fn portableMouse(mouse: vaxis.Mouse) ?presentation.MouseInput {
    if (mouse.col < 0 or mouse.row < 0) return null;
    return .{
        .col = @intCast(mouse.col),
        .row = @intCast(mouse.row),
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
pub fn run(ctx: RunCtx, initial: ?*Session, initial_key: presentation.ReviewKey) !void {
    return runPresentation(ctx, initial, initial_key);
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
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    command: *presentation.PostDraft,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(scratch.allocator(), env_map) catch {};
    const client = bbr.bitbucket.Client.init(http.httpClient(), cred);
    var poster = bbr.bitbucket.Poster{
        .client = client,
        .allocator = scratch.allocator(),
        .repo_slug = command.key.repository(),
        .pr_id = command.key.pull_request_id,
    };
    presentation_runtime.executePost(presentationSink(&sink_context), command, poster.poster());
}

fn presentationLoadWorker(
    loop: *Loop,
    work_id: u64,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    command: presentation.LoadSession,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    const outcome: presentation.SessionLoadOutcome = switch (command.key.kind) {
        .remote => if (session.load(
            io,
            std.heap.page_allocator,
            env_map,
            cred,
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
        .intent = command.intent,
        .outcome = outcome,
    } });
}

fn presentationEnrichmentWorker(
    loop: *Loop,
    work_id: u64,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    highlighter: bbr.highlight.Highlighter,
    command: presentation.EnrichFile,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const outcome: presentation.FileEnrichmentOutcome = switch (command.source) {
        .remote => blk: {
            var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
            defer http.deinit();
            http.initDefaultProxies(scratch.allocator(), env_map) catch {};
            const client = bbr.bitbucket.Client.init(http.httpClient(), cred);
            break :blk if (file_enrichment.enrich(
                std.heap.page_allocator,
                client,
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
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = outcome,
    } });
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
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    check: presentation.CheckRecovery,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(scratch.allocator(), env_map) catch {};
    const client = bbr.bitbucket.Client.init(http.httpClient(), cred);
    const input = if (client.getPullRequest(scratch.allocator(), check.key.repository(), check.key.pull_request_id)) |pr|
        presentation.recoveryCheckSucceeded(check.operation_id, pr.source_commit)
    else |_|
        presentation.OwnedInput{ .recovery_checked = .{ .operation_id = check.operation_id, .outcome = .failed } };
    presentation_runtime.deliver(presentationSink(&sink_context), input);
}

fn presentationDuplicateCheckWorker(
    loop: *Loop,
    work_id: u64,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    command: *presentation.PostDraft,
) void {
    defer command.destroy();
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(scratch.allocator(), env_map) catch {};
    const client = bbr.bitbucket.Client.init(http.httpClient(), cred);
    var poster = bbr.bitbucket.Poster{
        .client = client,
        .allocator = scratch.allocator(),
        .repo_slug = command.key.repository(),
        .pr_id = command.key.pull_request_id,
    };
    const outcome: presentation.DuplicateCheckOutcome = if (poster.poster().findExisting(command.draft, command.parent)) |existing|
        if (existing) |id| .{ .found = id } else .missing
    else |_|
        .failed;
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .duplicate_checked = .{
        .operation_id = command.operation_id,
        .temp_id = command.draft.local_id,
        .outcome = outcome,
    } });
}

fn presentationListPullRequestsWorker(
    loop: *Loop,
    work_id: u64,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    command: presentation.ListPullRequests,
) void {
    var sink_context: PresentationSinkContext = .{ .loop = loop, .work_id = work_id };
    const summaries = presentation.PullRequestSummaries.create(std.heap.page_allocator) catch {
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .pull_requests_loaded = .{
            .work_id = command.work_id,
            .outcome = .failed,
        } });
        return;
    };
    var http = bbr.http.StdHttpClient.init(summaries.arena.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(summaries.arena.allocator(), env_map) catch {};
    const client = bbr.bitbucket.Client.init(http.httpClient(), cred);
    summaries.prs = client.listPullRequests(summaries.arena.allocator(), command.repositoryName(), .{}) catch {
        summaries.destroy();
        presentation_runtime.deliver(presentationSink(&sink_context), .{ .pull_requests_loaded = .{
            .work_id = command.work_id,
            .outcome = .failed,
        } });
        return;
    };
    presentation_runtime.deliver(presentationSink(&sink_context), .{ .pull_requests_loaded = .{
        .work_id = command.work_id,
        .outcome = .{ .loaded = summaries },
    } });
}

fn drainPresentationCommands(
    state: *presentation.Presentation,
    ctx: RunCtx,
    loop: *Loop,
    futures: *std.ArrayList(PresentationWork),
    next_work_id: *u64,
    vx: vaxis.Vaxis,
    writer: *std.Io.Writer,
) !void {
    while (state.takeCommand()) |command_value| {
        var command = command_value;
        if (command == .copy_clipboard) {
            const input = presentation_adapter.copyToClipboard(vx, writer, command.copy_clipboard);
            command = undefined;
            try state.dispatch(input);
            continue;
        }
        futures.ensureUnusedCapacity(ctx.gpa, 1) catch {
            try admitPresentationLaunchFailure(state, &command);
            continue;
        };
        const work_id = next_work_id.*;
        next_work_id.* +%= 1;
        const future = switch (command) {
            .load_session => |load| ctx.io.concurrent(presentationLoadWorker, .{ loop, work_id, ctx.io, ctx.env_map, ctx.cred, load }),
            .enrich_file => |enrich| ctx.io.concurrent(presentationEnrichmentWorker, .{ loop, work_id, ctx.io, ctx.env_map, ctx.cred, ctx.highlighter, enrich }),
            .post_draft => |post| ctx.io.concurrent(presentationPostWorker, .{ loop, work_id, ctx.io, ctx.env_map, ctx.cred, post }),
            .wait_submission => |wait| ctx.io.concurrent(presentationWaitWorker, .{ loop, work_id, ctx.io, wait }),
            .check_recovery => |check| ctx.io.concurrent(presentationRecoveryCheckWorker, .{ loop, work_id, ctx.io, ctx.env_map, ctx.cred, check }),
            .find_duplicate => |check| ctx.io.concurrent(presentationDuplicateCheckWorker, .{ loop, work_id, ctx.io, ctx.env_map, ctx.cred, check }),
            .list_pull_requests => |list| ctx.io.concurrent(presentationListPullRequestsWorker, .{ loop, work_id, ctx.io, ctx.env_map, ctx.cred, list }),
            .copy_clipboard => unreachable,
        } catch {
            try admitPresentationLaunchFailure(state, &command);
            continue;
        };
        futures.appendAssumeCapacity(.{ .id = work_id, .future = future });
        // A POST pointer moved into its worker. Value commands need no cleanup.
        command = undefined;
    }
}

fn admitPresentationLaunchFailure(state: *presentation.Presentation, command: *presentation.OwnedCommand) !void {
    const input: presentation.OwnedInput = switch (command.*) {
        .load_session => |load| .{ .session_loaded = .{ .intent = load.intent, .outcome = .{ .failed = error.WorkerLaunchFailed } } },
        .enrich_file => |enrich| .{ .file_enrichment_completed = .{
            .work_id = enrich.work_id,
            .session_epoch = enrich.session_epoch,
            .file_index = enrich.file_index,
            .outcome = .{ .failed = .launch_failed },
        } },
        .post_draft => |post| presentation_adapter.postLaunchFailed(post),
        .wait_submission => |wait| .{ .submission_wait_launch_failed = wait },
        .check_recovery => |check| .{ .recovery_checked = .{ .operation_id = check.operation_id, .outcome = .failed } },
        .find_duplicate => |check| blk: {
            const input: presentation.OwnedInput = .{ .duplicate_checked = .{
                .operation_id = check.operation_id,
                .temp_id = check.draft.local_id,
                .outcome = .failed,
            } };
            check.destroy();
            break :blk input;
        },
        .list_pull_requests => |list| .{ .pull_requests_loaded = .{ .work_id = list.work_id, .outcome = .failed } },
        .copy_clipboard => |copy| blk: {
            copy.destroy();
            break :blk .{ .clipboard_completed = false };
        },
    };
    command.* = undefined;
    try state.dispatch(input);
}

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

fn fileIndexForRow(buf: buffer_mod.Buffer, cursor: usize) usize {
    var idx: usize = 0;
    var seen_any = false;
    var i: usize = 0;
    while (i <= cursor and i < buf.rows.len) : (i += 1) {
        if (buf.rows[i] == .file_header) {
            if (seen_any) idx += 1 else seen_any = true;
        }
    }
    return idx;
}

fn contentViewportRows(window_rows: u16) usize {
    return @max(window_rows -| 1, 1);
}

/// A one-line status bar across the bottom row. `frame` is the per-frame arena
/// (outlives render); a stack buffer would dangle since cells borrow the text.
fn drawStatus(
    frame: std.mem.Allocator,
    win: vaxis.Window,
    header: session.ReviewHeader,
    nav: Nav,
    buf: buffer_mod.Buffer,
    layout: buffer_mod.Layout,
    scope: presentation.Scope,
    isolate: bool,
    loading: bool,
    submitting: bool,
    draft_count: usize,
    status_msg: ?[]const u8,
) void {
    if (win.height == 0) return;
    const row = win.height - 1;
    const layout_hint: []const u8 = if (layout == .unified) "s split" else "s unified";
    // Names the *current* scope; `f` cycles Changes → fetched → whole.
    const scope_hint: []const u8 = switch (scope) {
        .changes => "f: changes",
        .fetched => "f: fetched",
        .whole => "f: whole",
    };
    const file_hint: []const u8 = if (isolate) "o all files" else "o isolate";
    // A transient message (error/summary) or an in-progress indicator takes the
    // tail slot; otherwise the key hints, with the pending-draft count on `X`.
    const default_tail: []const u8 = if (draft_count > 0)
        (std.fmt.allocPrint(frame, "X submit {d}  ·  c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit", .{draft_count}) catch "q quit")
    else
        "c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit";
    const tail: []const u8 = if (status_msg) |m| m else if (submitting) "submitting…" else if (loading) "loading…" else default_tail;
    const identity = if (header.pull_request_id) |id|
        (std.fmt.allocPrint(frame, "#{d} {s}", .{ id, header.title }) catch header.title)
    else
        header.title;
    const text = std.fmt.allocPrint(frame, " {s}  ·  {s} → {s}  ·  {d}/{d}  ·  {s}  ·  {s}  ·  {s}  ·  {s} ", .{
        identity,
        header.source_ref,
        header.base_ref,
        @min(nav.cursor + 1, buf.rows.len),
        buf.rows.len,
        layout_hint,
        scope_hint,
        file_hint,
        tail,
    }) catch " q quit ";
    const style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } };
    var c: u16 = 0;
    while (c < win.width) : (c += 1) win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .wrap = .none });
}

// Force the presentation modules' tests into the exe test binary.
test {
    _ = @import("buffer.zig");
    _ = @import("frame.zig");
    _ = @import("file_tree.zig");
    _ = @import("render.zig");
    _ = @import("theme.zig");
    _ = @import("nav.zig");
    _ = @import("keymap.zig");
    _ = @import("picker.zig");
    _ = @import("session.zig");
    _ = @import("arena_ring.zig");
    _ = @import("composer.zig");
    _ = @import("file_enrichment.zig");
}

test "content viewport reserves the bottom status row" {
    try std.testing.expectEqual(@as(usize, 9), contentViewportRows(10));
    try std.testing.expectEqual(@as(usize, 1), contentViewportRows(1));
    try std.testing.expectEqual(@as(usize, 1), contentViewportRows(0));
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
