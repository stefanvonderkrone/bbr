//! Renderer — projects a `Buffer` onto vaxis Panes: a file Sidebar on the left
//! and the unified DiffPane on the right. Pure drawing; it mutates no state and
//! reads `Nav` for scroll/cursor. Diff lines get full-width neutral/green/red
//! bands (via `Theme`) so changes read as color across the pane.
//!
//! Cell text is *borrowed* by vaxis until the frame is rendered. Line body text
//! borrows the raw diff (long-lived); the only text we synthesize per frame is
//! the gutter (line numbers), so `draw` takes a `scratch` allocator that must
//! outlive the render/read that follows (a per-frame arena, reset after render).

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const Theme = @import("theme.zig").Theme;
const Nav = @import("nav.zig").Nav;
const Buffer = bbr.diff.buffer.Buffer;
const Row = bbr.diff.buffer.Row;
const FileStatus = bbr.diff.FileStatus;

pub const sidebar_width: u16 = 28;

/// Draw one frame. `selected_file` indexes `diff.files` for sidebar highlight.
pub fn draw(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    diff: bbr.diff.Diff,
    buf: Buffer,
    theme: Theme,
    nav: Nav,
    selected_file: usize,
) void {
    win.clear();

    const sb_w = @min(sidebar_width, win.width);
    const sidebar = win.child(.{ .x_off = 0, .y_off = 0, .width = sb_w, .height = win.height });
    // +1 leaves a one-column divider gutter between the panes.
    const pane_x = @min(sb_w + 1, win.width);
    const pane = win.child(.{ .x_off = pane_x, .y_off = 0, .width = win.width - pane_x, .height = win.height });

    drawSidebar(sidebar, diff, theme, selected_file);
    drawPane(scratch, pane, buf, theme, nav);
}

/// Single-char status label. Returns a static string so vaxis cells can borrow
/// it safely for the whole frame (a stack byte would dangle before render).
fn statusChar(status: FileStatus) []const u8 {
    return switch (status) {
        .added => "A",
        .modified => "M",
        .removed => "D",
        .renamed => "R",
    };
}

fn drawSidebar(win: vaxis.Window, diff: bbr.diff.Diff, theme: Theme, selected_file: usize) void {
    var row: u16 = 0;
    for (diff.files, 0..) |file, i| {
        if (row >= win.height) break;
        const selected = i == selected_file;
        const style = if (selected) theme.sidebar_selected else theme.sidebar_item;
        fillRow(win, row, style);

        // Prefix cells use static graphemes so nothing is borrowed from the stack.
        win.writeCell(0, row, .{ .char = .{ .grapheme = if (selected) ">" else " ", .width = 1 }, .style = style });
        win.writeCell(2, row, .{ .char = .{ .grapheme = statusChar(file.status), .width = 1 }, .style = style });
        _ = win.printSegment(.{ .text = file.new_path, .style = style }, .{ .row_offset = row, .col_offset = 4, .wrap = .none });
        row += 1;
    }
}

fn drawPane(scratch: std.mem.Allocator, win: vaxis.Window, buf: Buffer, theme: Theme, nav: Nav) void {
    var r: u16 = 0;
    while (r < win.height) : (r += 1) {
        const idx = nav.scroll + r;
        if (idx >= buf.rows.len) break;
        drawRow(scratch, win, r, buf.rows[idx], theme, idx == nav.cursor);
    }
}

/// Gutter is two 4-wide line-number columns; body text starts after it.
const gutter_cols: u16 = 10;

fn drawRow(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, row: Row, theme: Theme, is_cursor: bool) void {
    switch (row) {
        .file_header => |file| {
            fillRow(win, r, theme.file_header);
            const text = std.fmt.allocPrint(scratch, "{s} {s}", .{ statusChar(file.status), file.new_path }) catch file.new_path;
            _ = win.printSegment(.{ .text = text, .style = theme.file_header }, .{ .row_offset = r, .wrap = .none });
        },
        .hunk_header => |hunk| {
            fillRow(win, r, theme.hunk_header);
            _ = win.printSegment(.{ .text = hunk.header, .style = theme.hunk_header }, .{ .row_offset = r, .wrap = .none });
        },
        .line => |ln| {
            const style = theme.lineStyle(ln.kind);
            fillRow(win, r, style);

            const gutter = std.fmt.allocPrint(scratch, "{s} {s} ", .{
                numCol(scratch, ln.old_no),
                numCol(scratch, ln.new_no),
            }) catch "";
            _ = win.printSegment(.{ .text = gutter, .style = theme.gutter }, .{ .row_offset = r, .wrap = .none });
            _ = win.printSegment(.{ .text = ln.text, .style = style }, .{ .row_offset = r, .col_offset = gutter_cols, .wrap = .none });

            if (is_cursor) {
                // A cursor marker in column 0, over the gutter, without disturbing
                // the band background elsewhere on the row.
                win.writeCell(0, r, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = .{ .index = 6 } } });
            }
        },
    }
}

/// Render an optional line number right-justified in 4 columns (blank if absent).
fn numCol(scratch: std.mem.Allocator, no: ?u32) []const u8 {
    const n = no orelse return "    ";
    return std.fmt.allocPrint(scratch, "{d: >4}", .{n}) catch "    ";
}

fn fillRow(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    var c: u16 = 0;
    while (c < win.width) : (c += 1) {
        win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    }
}

// ---------------------------------------------------------------------------
// Tests — headless: draw onto an in-memory Screen and read cells back.
// ---------------------------------------------------------------------------
const testing = std.testing;

const Screen = @import("vaxis").Screen;

/// Build a detached root Window over an allocated Screen — no tty required.
fn headlessWindow(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = screen,
    };
}

test "diff lines render with their band background at the text cells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-old
        \\+new
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try bbr.diff.buffer.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0);

    // Row layout in the pane: 0 file_header, 1 hunk_header, 2 context(keep),
    // 3 removed(old), 4 added(new). Pane starts at x = sidebar_width + 1.
    const px = sidebar_width + 1;
    const body_x = px + gutter_cols;

    const removed_cell = win.readCell(body_x, 3).?;
    try testing.expectEqual(theme_dark.removed.bg, removed_cell.style.bg);

    const added_cell = win.readCell(body_x, 4).?;
    try testing.expectEqual(theme_dark.added.bg, added_cell.style.bg);

    // Context line keeps the neutral (default) background.
    const context_cell = win.readCell(body_x, 2).?;
    try testing.expect(context_cell.style.bg == .default);
}

test "sidebar highlights the selected file" {
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

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 1); // select second file

    // Selected row (sidebar row 1) carries the selected background.
    const sel = win.readCell(0, 1).?;
    try testing.expectEqual(theme_dark.sidebar_selected.bg, sel.style.bg);
    // The unselected row does not.
    const unsel = win.readCell(0, 0).?;
    try testing.expect(unsel.style.bg == .default);
}

const theme_dark = @import("theme.zig").dark;

test "sidebar prefix shows selection marker and status, borrowing no stack" {
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
        \\diff --git a/gone.txt b/gone.txt
        \\deleted file mode 100644
        \\--- a/gone.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-x
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try bbr.diff.buffer.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0); // first file selected

    // Row 0: selected → ">", modified → "M". Read back after draw (the bug this
    // guards against was borrowing a per-iteration stack buffer, which showed
    // the *last* file's prefix on every row).
    try testing.expectEqualStrings(">", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("M", win.readCell(2, 0).?.char.grapheme);
    // Row 1: not selected → " ", deleted → "D".
    try testing.expectEqualStrings(" ", win.readCell(0, 1).?.char.grapheme);
    try testing.expectEqualStrings("D", win.readCell(2, 1).?.char.grapheme);
}
