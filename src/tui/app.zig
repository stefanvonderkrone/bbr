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
    file_cache_max_retained_bytes_per_review: usize,
    submission_locks: ?bbr.review.SubmissionLocks = null,
    online: bool = true,
};

/// Terminal events plus the single typed completion channel used by every
/// Presentation worker.
const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    presentation_done: PresentationDone,
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

fn runPresentation(ctx: RunCtx, initial: ?*Session, initial_id: u64) !void {
    var state = try presentation.Presentation.init(ctx.gpa, .{
        .reviews = ctx.store,
        .submission_locks = ctx.submission_locks,
        .highlight_max_file_bytes = ctx.highlight_max_file_bytes,
        .file_cache_enabled = ctx.file_cache_enabled,
        .file_cache_max_retained_bytes_per_review = ctx.file_cache_max_retained_bytes_per_review,
        .require_source_check = ctx.online,
        .keymap = ctx.keymap,
        .remote_enabled = ctx.online,
    }, .{
        .initial = if (initial) |loaded| .{
            .key = try presentation.ReviewKey.init(ctx.cred.workspace, ctx.repo, loaded.pr.id),
            .session = loaded,
        } else null,
        .viewport_rows = 1,
    });
    defer state.deinit();
    if (initial == null) try state.dispatch(.{ .choose_pull_request = try presentation.ReviewKey.init(ctx.cred.workspace, ctx.repo, initial_id) });

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
    try state.dispatch(.{ .resize_viewport = vx.window().height });

    var futures: std.ArrayList(PresentationWork) = .empty;
    defer {
        for (futures.items) |*work| _ = work.future.await(ctx.io);
        futures.deinit(ctx.gpa);
    }
    var next_work_id: u64 = 1;
    var frame_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer frame_arena.deinit();

    try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id);
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try state.dispatch(.{ .key = portableKey(key) }),
            .winsize => |winsize| {
                try vx.resize(ctx.gpa, writer, winsize);
                try state.dispatch(.{ .resize_viewport = vx.window().height });
            },
            .presentation_done => |done| {
                reapPresentationWork(&futures, ctx.io, done.work_id);
                try state.dispatch(done.input);
            },
        }

        try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id);
        if (state.projection().review != null) {
            try state.dispatch(.ensure_focused_enrichment);
            try drainPresentationCommands(&state, ctx, &loop, &futures, &next_work_id);
        }
        // A completed worker may still own a payload queued for Presentation.
        // Keep the loop alive until every completion has been received and
        // reaped so shutdown cannot strand that payload in the event queue.
        if (state.readyToExit() and futures.items.len == 0) break;

        const projection = state.projection();
        const win = vx.window();
        const frame = frame_arena.allocator();
        if (projection.review) |review_projection| {
            const selected_file = fileIndexForRow(review_projection.buffer, review_projection.navigation.cursor);
            render.drawReview(frame, win, review_projection, ctx.active_theme, selected_file);
            const status = presentationStatus(frame, projection, review_projection.key);
            drawStatus(
                frame,
                win,
                review_projection.pull_request.*,
                review_projection.navigation,
                review_projection.buffer,
                review_projection.preferences.layout,
                switch (review_projection.preferences.scope) {
                    .changes => .changes,
                    .fetched => .fetched,
                    .whole => .whole,
                },
                review_projection.preferences.show_resolved,
                review_projection.isolated_file != null,
                projection.replacing,
                projection.submission != null,
                review_projection.drafts.len,
                status,
            );
        } else {
            const status = presentationStatus(frame, projection, null);
            render.drawLoading(frame, win, projection.loading_pull_request_id orelse initial_id, ctx.active_theme, status);
        }
        if (projection.picker) |active_picker| render.drawPicker(frame, win, active_picker, ctx.active_theme);
        if (projection.composer) |composer| render.drawComposerProjection(frame, win, composer, ctx.active_theme);
        if (projection.unknown_resolution) |resolution| render.drawComposerProjection(frame, win, .{
            .label = "Link existing Bitbucket Comment ID",
            .body = resolution.comment_id,
        }, ctx.active_theme);
        if (projection.submission) |submission| {
            if (projection.review) |review_projection| if (presentation.ReviewKey.eql(submission.key, review_projection.key))
                render.drawSubmit(frame, win, ctx.active_theme, submission.completed, submission.total);
        } else if (projection.submission_result) |result| {
            if (projection.review) |review_projection| if (presentation.ReviewKey.eql(result.key, review_projection.key))
                render.drawSubmitResult(
                    frame,
                    win,
                    ctx.active_theme,
                    result.posted,
                    result.failed + result.outcome_unknown,
                    result.skipped,
                    submissionAbortName(result.completion),
                    false,
                );
        }
        if (projection.help_visible) render.drawHelp(frame, win, ctx.active_theme, ctx.keymap);
        try vx.render(writer);
        _ = frame_arena.reset(.retain_capacity);
    }
}

fn presentationStatus(
    frame: std.mem.Allocator,
    projection: presentation.Projection,
    visible_key: ?presentation.ReviewKey,
) ?[]const u8 {
    if (projection.fatal_error) |err| return @tagName(err);
    if (projection.action_error) |err| return @tagName(err);
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
pub fn run(ctx: RunCtx, initial: ?*Session, initial_id: u64) !void {
    return runPresentation(ctx, initial, initial_id);
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
    const outcome: presentation.SessionLoadOutcome = if (session.load(
        io,
        std.heap.page_allocator,
        env_map,
        cred,
        command.key.repository(),
        command.key.pull_request_id,
    )) |loaded| .{ .loaded = loaded } else |err| .{ .failed = err };
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
    var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(scratch.allocator(), env_map) catch {};
    const client = bbr.bitbucket.Client.init(http.httpClient(), cred);
    const outcome: presentation.FileEnrichmentOutcome = if (file_enrichment.enrich(
        std.heap.page_allocator,
        client,
        highlighter,
        command.request(),
    )) |result| .{ .completed = result } else |err| .{ .failed = if (err == error.OutOfMemory) .out_of_memory else .launch_failed };
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
    const outcome: presentation.DuplicateCheckOutcome = if (poster.poster().findExisting(command.draft)) |existing|
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
) !void {
    while (state.takeCommand()) |command_value| {
        var command = command_value;
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

fn fileIndexForRow(buf: bbr.diff.Buffer, cursor: usize) usize {
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

/// A one-line status bar across the bottom row. `frame` is the per-frame arena
/// (outlives render); a stack buffer would dangle since cells borrow the text.
fn drawStatus(
    frame: std.mem.Allocator,
    win: vaxis.Window,
    pr: bbr.bitbucket.PullRequest,
    nav: Nav,
    buf: bbr.diff.Buffer,
    layout: bbr.diff.Layout,
    scope: presentation.Scope,
    show_resolved: bool,
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
    const resolved_hint: []const u8 = if (show_resolved) "R hide resolved" else "R show resolved";
    // A transient message (error/summary) or an in-progress indicator takes the
    // tail slot; otherwise the key hints, with the pending-draft count on `X`.
    const default_tail: []const u8 = if (draft_count > 0)
        (std.fmt.allocPrint(frame, "X submit {d}  ·  c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit", .{draft_count}) catch "q quit")
    else
        "c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit";
    const tail: []const u8 = if (status_msg) |m| m else if (submitting) "submitting…" else if (loading) "loading…" else default_tail;
    const text = std.fmt.allocPrint(frame, " #{d} {s}  ·  {s} → {s}  ·  {d}/{d}  ·  {s}  ·  {s}  ·  {s}  ·  {s}  ·  {s} ", .{
        pr.id,
        pr.title,
        pr.source_branch,
        pr.destination_branch,
        @min(nav.cursor + 1, buf.rows.len),
        buf.rows.len,
        layout_hint,
        scope_hint,
        file_hint,
        resolved_hint,
        tail,
    }) catch " q quit ";
    const style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } };
    var c: u16 = 0;
    while (c < win.width) : (c += 1) win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .wrap = .none });
}

// Force the presentation modules' tests into the exe test binary.
test {
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
