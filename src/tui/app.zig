//! M2 TUI: the unified diff viewer. Boots vaxis on the alt-screen, renders a
//! file Sidebar + unified DiffPane for one PR's `Diff`, and navigates with vim
//! motions and arrows. Quit on `q`/ctrl-c.
//!
//! Concurrency note: the PR metadata and diff are fetched synchronously in
//! `main` before we get here, so this loop is purely local. Background loads
//! with an Epoch (design §10) are only needed once PRs can be *switched* — that
//! lands with the Picker in M4.
//!
//! Lifetime: vaxis cells borrow their text until `render`. Line body text
//! borrows the raw diff (lives for the whole session); the only per-frame text
//! is the gutter, synthesized into `frame_arena`, which we reset *after* render.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const render = @import("render.zig");
const theme = @import("theme.zig");
const Nav = @import("nav.zig").Nav;

const PullRequest = bbr.bitbucket.PullRequest;

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    pr: PullRequest,
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
) !void {
    // Buffer-scoped arena: the flattened rows live here for the whole view. It
    // is reset and rebuilt whenever the resolved toggle flips.
    var buf_arena = std.heap.ArenaAllocator.init(gpa);
    defer buf_arena.deinit();

    var show_resolved = false;
    var buf = try bbr.diff.buffer.buildWithComments(buf_arena.allocator(), diff, .unified, threads, .{ .show_resolved = show_resolved });

    // Per-frame arena for synthesized gutter text; reset after each render.
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var write_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &write_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, env_map, .{});
    defer vx.deinit(gpa, writer);

    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);

    const active_theme = theme.dark;
    var nav = Nav.init(buf.rows.len, vx.window().height);
    var pending_g = false; // saw the first `g` of a `gg`

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;

                if (key.matches('R', .{})) {
                    // Toggle resolved threads: rebuild the buffer in place. Rows
                    // borrow diff/threads, not buf_arena, so a reset is safe.
                    show_resolved = !show_resolved;
                    _ = buf_arena.reset(.retain_capacity);
                    buf = try bbr.diff.buffer.buildWithComments(buf_arena.allocator(), diff, .unified, threads, .{ .show_resolved = show_resolved });
                    nav.setRowCount(buf.rows.len);
                } else if (handleKey(&nav, &pending_g, key)) |_| {} // motions mutate nav in place
            },
            .winsize => |ws| {
                try vx.resize(gpa, writer, ws);
                nav.setViewport(vx.window().height);
            },
            else => {},
        }

        const selected_file = fileIndexForRow(buf, nav.cursor);

        const win = vx.window();
        const frame = frame_arena.allocator();
        render.draw(frame, win, diff, buf, active_theme, nav, selected_file);
        drawStatus(frame, win, pr, nav, buf, show_resolved);
        try vx.render(writer);
        _ = frame_arena.reset(.retain_capacity);
    }
}

/// Apply a key to `nav`. Returns non-null when the key was a recognized motion
/// (so the caller could clear transient state; today it's informational).
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
fn drawStatus(frame: std.mem.Allocator, win: vaxis.Window, pr: PullRequest, nav: Nav, buf: bbr.diff.Buffer, show_resolved: bool) void {
    if (win.height == 0) return;
    const row = win.height - 1;
    const resolved_hint: []const u8 = if (show_resolved) "R hide resolved" else "R show resolved";
    const text = std.fmt.allocPrint(frame, " #{d} {s}  ·  {s} → {s}  ·  {d}/{d}  ·  {s}  ·  q quit ", .{
        pr.id,
        pr.title,
        pr.source_branch,
        pr.destination_branch,
        @min(nav.cursor + 1, buf.rows.len),
        buf.rows.len,
        resolved_hint,
    }) catch " q quit ";
    const style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } };
    var c: u16 = 0;
    while (c < win.width) : (c += 1) win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .wrap = .none });
}

// ---------------------------------------------------------------------------
// Tests — pure helpers; the render/nav/theme modules test their own drawing.
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
}
