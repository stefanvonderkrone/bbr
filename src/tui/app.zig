//! The TUI: a unified diff viewer for one PR at a time, with a fuzzy PR Picker
//! (`p`) for switching. Boots vaxis on the alt-screen, renders a file Sidebar +
//! unified DiffPane over the current `Session`, and navigates with vim motions.
//!
//! Concurrency (design §10): the initial Session is loaded before we get here;
//! switching PRs loads the new Session on a worker thread (`std.Io.concurrent`)
//! so the UI stays live. Each switch bumps an Epoch; the worker stamps its
//! result with the epoch it was launched under and posts it back as a custom
//! `load_done` event. Only the result whose epoch is still current is applied —
//! results from superseded switches are discarded (Epoch cancellation). Workers
//! allocate from the stateless `page_allocator`, never the main thread's `gpa`.
//!
//! Lifetime: vaxis cells borrow their text until `render`. A Session owns its
//! diff/threads for as long as it is current; per-frame gutter/overlay text is
//! synthesized into `frame_arena`, reset *after* render.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const render = @import("render.zig");
const theme = @import("theme.zig");
const Nav = @import("nav.zig").Nav;
const Picker = @import("picker.zig").Picker;
const session = @import("session.zig");
const Session = session.Session;

const Credential = bbr.bitbucket.Credential;
const PullRequestSummary = bbr.bitbucket.PullRequestSummary;

/// Everything `run` needs to fetch and switch PRs. `online` is false for the
/// offline `demo`, which disables the network-backed Picker.
pub const RunCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    repo: []const u8,
    online: bool = true,
};

/// The event type our vaxis loop carries: the terminal events we consume plus
/// `load_done`, posted by a background load worker.
const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    load_done: LoadDone,
};

const LoadOutcome = union(enum) {
    ok: *Session,
    err: anyerror,
};

const LoadDone = struct {
    epoch: u64,
    outcome: LoadOutcome,
};

const Loop = vaxis.Loop(AppEvent);

/// A background load and the epoch it was launched under. We keep the future so
/// its thread resources are reclaimed (awaited) once its result event arrives.
const Load = struct {
    epoch: u64,
    future: std.Io.Future(void),
};

/// Request handed to a load worker. `repo` is copied by value (a fixed buffer)
/// so the worker has no dangling reference to the caller's slice.
const LoadReq = struct {
    repo: [256]u8,
    repo_len: usize,
    id: u64,
    epoch: u64,
};

/// Run the viewer. Takes ownership of `initial` and destroys it (and any PR it
/// later switches to) before returning.
pub fn run(ctx: RunCtx, initial: *Session) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;

    var current: *Session = initial;
    defer current.destroy();

    // Buffer-scoped arena: the flattened rows for the *current* session. Reset
    // and rebuilt when the resolved toggle flips or the session switches.
    var buf_arena = std.heap.ArenaAllocator.init(gpa);
    defer buf_arena.deinit();

    var show_resolved = false;
    var layout: bbr.diff.Layout = .unified;
    var buf = try bbr.diff.buffer.buildWithComments(buf_arena.allocator(), current.diff, layout, current.threads, .{ .show_resolved = show_resolved });

    // Per-frame arena for synthesized gutter/overlay text; reset after render.
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    // Picker overlay + its own arena (summaries + haystacks live here while open).
    var picker_arena = std.heap.ArenaAllocator.init(gpa);
    defer picker_arena.deinit();
    var picker: ?Picker = null;

    var write_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &write_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, ctx.env_map, .{});
    defer vx.deinit(gpa, writer);

    var loop: Loop = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    // In-flight loads. Declared *after* the loop so this defer runs *before*
    // loop.stop(): we must await every worker (so none posts into a torn-down
    // queue) before the loop is destroyed.
    var epoch: u64 = 0;
    var loads: std.ArrayList(Load) = .empty;
    defer {
        for (loads.items) |*l| _ = l.future.await(io);
        loads.deinit(gpa);
    }

    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);

    const active_theme = theme.dark;
    var nav = Nav.init(buf.rows.len, vx.window().height);
    var pending_g = false; // saw the first `g` of a `gg`
    var loading = false; // a switch is in flight for the current epoch
    var status_msg: ?[]const u8 = null; // transient error/status (static string)

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (picker) |*p| {
                    // --- Picker mode: keys drive the overlay. ---
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                        picker = null;
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        const sel = p.selection();
                        picker = null;
                        if (sel) |s| {
                            spawnLoad(ctx, &loop, &loads, &epoch, gpa, s.id) catch |err| {
                                status_msg = @errorName(err);
                            };
                            if (loads.items.len > 0) {
                                loading = true;
                                status_msg = null;
                            }
                        }
                    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
                        p.moveUp();
                    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
                        p.moveDown();
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        p.backspace();
                    } else if (key.text) |t| {
                        p.insert(t);
                    }
                } else {
                    // --- Viewer mode. ---
                    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;

                    if (key.matches('p', .{}) and ctx.online) {
                        openPicker(ctx, &picker, &picker_arena) catch |err| {
                            status_msg = @errorName(err);
                        };
                    } else if (key.matches('R', .{})) {
                        show_resolved = !show_resolved;
                        buf = rebuild(&buf_arena, current, layout, show_resolved) catch buf;
                        nav.setRowCount(buf.rows.len);
                    } else if (key.matches('s', .{})) {
                        layout = if (layout == .unified) .side_by_side else .unified;
                        buf = rebuild(&buf_arena, current, layout, show_resolved) catch buf;
                        nav.setRowCount(buf.rows.len);
                    } else if (handleKey(&nav, &pending_g, key)) |_| {}
                }
            },
            .winsize => |ws| {
                try vx.resize(gpa, writer, ws);
                nav.setViewport(vx.window().height);
            },
            .load_done => |done| {
                reap(&loads, io, done.epoch);
                if (done.epoch != epoch) {
                    // Superseded by a newer switch: discard.
                    if (done.outcome == .ok) done.outcome.ok.destroy();
                } else {
                    loading = false;
                    switch (done.outcome) {
                        .ok => |s| {
                            current.destroy();
                            current = s;
                            buf = rebuild(&buf_arena, current, layout, show_resolved) catch buf;
                            nav = Nav.init(buf.rows.len, vx.window().height);
                            pending_g = false;
                            status_msg = null;
                        },
                        .err => |e| status_msg = @errorName(e),
                    }
                }
            },
        }

        const selected_file = fileIndexForRow(buf, nav.cursor);

        const win = vx.window();
        const frame = frame_arena.allocator();
        render.draw(frame, win, current.diff, buf, active_theme, nav, selected_file);
        drawStatus(frame, win, current.pr, nav, buf, layout, show_resolved, loading, status_msg);
        if (picker) |*p| render.drawPicker(frame, win, p, active_theme);
        try vx.render(writer);
        _ = frame_arena.reset(.retain_capacity);
    }
}

/// Rebuild the row buffer for `s` against the resolved toggle. Rows borrow the
/// session's diff/threads (not `buf_arena`), so resetting the arena is safe.
fn rebuild(buf_arena: *std.heap.ArenaAllocator, s: *const Session, layout: bbr.diff.Layout, show_resolved: bool) !bbr.diff.Buffer {
    _ = buf_arena.reset(.retain_capacity);
    return bbr.diff.buffer.buildWithComments(buf_arena.allocator(), s.diff, layout, s.threads, .{ .show_resolved = show_resolved });
}

/// Fetch the repo's open PRs (synchronously — one request) and open the Picker
/// over them. Summaries and picker state live in `picker_arena`, reset per open.
fn openPicker(ctx: RunCtx, picker: *?Picker, picker_arena: *std.heap.ArenaAllocator) !void {
    _ = picker_arena.reset(.retain_capacity);
    const a = picker_arena.allocator();

    var http = bbr.http.StdHttpClient.init(a, ctx.io);
    defer http.deinit();
    try http.initDefaultProxies(a, ctx.env_map);
    const bb = bbr.bitbucket.Client.init(http.httpClient(), ctx.cred);

    const prs = try bb.listPullRequests(a, ctx.repo, .{});
    picker.* = try Picker.init(a, prs);
}

/// Launch a background load for `id`, bumping the epoch. The worker posts a
/// `load_done` event stamped with this epoch; only the current epoch's result
/// is applied. On success the future is tracked so we can await it later.
fn spawnLoad(
    ctx: RunCtx,
    loop: *Loop,
    loads: *std.ArrayList(Load),
    epoch: *u64,
    gpa: std.mem.Allocator,
    id: u64,
) !void {
    epoch.* += 1;
    var req: LoadReq = .{ .repo = undefined, .repo_len = @min(ctx.repo.len, 256), .id = id, .epoch = epoch.* };
    @memcpy(req.repo[0..req.repo_len], ctx.repo[0..req.repo_len]);

    const fut = try ctx.io.concurrent(loadWorker, .{ loop, ctx.io, ctx.env_map, ctx.cred, req });
    try loads.append(gpa, .{ .epoch = epoch.*, .future = fut });
}

/// Await and drop the tracked load with `epoch` (its result has arrived). The
/// worker returns right after posting, so the await completes promptly.
fn reap(loads: *std.ArrayList(Load), io: std.Io, epoch: u64) void {
    var i: usize = 0;
    while (i < loads.items.len) : (i += 1) {
        if (loads.items[i].epoch == epoch) {
            _ = loads.items[i].future.await(io);
            _ = loads.swapRemove(i);
            return;
        }
    }
}

/// Runs on a worker thread. Loads the Session off the main allocator (via the
/// stateless page_allocator) and posts it back. If the hand-off fails (shutting
/// down), the session is freed here rather than leaked.
fn loadWorker(
    loop: *Loop,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    req: LoadReq,
) void {
    const repo = req.repo[0..req.repo_len];
    const outcome: LoadOutcome = if (session.load(io, std.heap.page_allocator, env_map, cred, repo, req.id)) |s|
        .{ .ok = s }
    else |err|
        .{ .err = err };

    loop.postEvent(.{ .load_done = .{ .epoch = req.epoch, .outcome = outcome } }) catch {
        if (outcome == .ok) outcome.ok.destroy();
    };
}

/// Apply a key to `nav`. Returns non-null when the key was a recognized motion.
fn handleKey(nav: *Nav, pending_g: *bool, key: vaxis.Key) ?void {
    // `gg` is a two-key motion: the first `g` arms, the second fires.
    if (pending_g.*) {
        pending_g.* = false;
        if (key.matches('g', .{})) {
            nav.toTop();
            return {};
        }
        // Any other key after a lone `g` just falls through to normal handling.
    }

    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        nav.down();
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        nav.up();
    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
        nav.halfPageDown();
    } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
        nav.halfPageUp();
    } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) {
        nav.toBottom();
    } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) {
        pending_g.* = true;
    } else if (key.text) |t| {
        // Numeric Count prefix (5j, 42G, …).
        if (t.len == 1 and t[0] >= '0' and t[0] <= '9') {
            nav.pushDigit(t[0] - '0');
        } else return null;
    } else return null;
    return {};
}

/// Which file (index into `diff.files`) the row at `cursor` belongs to, so the
/// sidebar highlight tracks the diff pane. Counts file headers up to the cursor.
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
    show_resolved: bool,
    loading: bool,
    status_msg: ?[]const u8,
) void {
    if (win.height == 0) return;
    const row = win.height - 1;
    const layout_hint: []const u8 = if (layout == .unified) "s split" else "s unified";
    const resolved_hint: []const u8 = if (show_resolved) "R hide resolved" else "R show resolved";
    // A transient message (error) or the loading indicator takes the tail slot.
    const tail: []const u8 = if (status_msg) |m| m else if (loading) "loading…" else "p switch  ·  q quit";
    const text = std.fmt.allocPrint(frame, " #{d} {s}  ·  {s} → {s}  ·  {d}/{d}  ·  {s}  ·  {s}  ·  {s} ", .{
        pr.id,
        pr.title,
        pr.source_branch,
        pr.destination_branch,
        @min(nav.cursor + 1, buf.rows.len),
        buf.rows.len,
        layout_hint,
        resolved_hint,
        tail,
    }) catch " q quit ";
    const style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } };
    var c: u16 = 0;
    while (c < win.width) : (c += 1) win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .wrap = .none });
}

// ---------------------------------------------------------------------------
// Tests — pure helpers; the render/nav/theme/picker modules test their drawing.
// ---------------------------------------------------------------------------
const testing = std.testing;

test "fileIndexForRow tracks which file a row belongs to" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/one.txt b/one.txt
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\diff --git a/two.txt b/two.txt
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try bbr.diff.buffer.build(a, diff, .unified);

    // File one: rows 0..3 (header, hunk, removed, added).
    try testing.expectEqual(@as(usize, 0), fileIndexForRow(buf, 0));
    try testing.expectEqual(@as(usize, 0), fileIndexForRow(buf, 3));
    // File two: rows 4..7.
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(buf, 4));
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(buf, 7));
}

// Force the presentation modules' tests into the exe test binary.
test {
    _ = @import("render.zig");
    _ = @import("theme.zig");
    _ = @import("nav.zig");
    _ = @import("picker.zig");
    _ = @import("session.zig");
}
