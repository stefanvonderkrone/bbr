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
const presentation = @import("presentation.zig");
const ReviewProjection = presentation.ReviewProjection;
const Buffer = buffer_mod.Buffer;
const Row = buffer_mod.Row;
const LineRow = buffer_mod.LineRow;
const CommentRow = buffer_mod.CommentRow;
const DraftRow = buffer_mod.DraftRow;
const Section = buffer_mod.Section;
const FileStatus = bbr.diff.FileStatus;
const Thread = bbr.review.Thread;
const Draft = bbr.review.Draft;
const Picker = @import("picker.zig").Picker;
const FileFinder = @import("picker.zig").FileFinder;
const keymap = @import("keymap.zig");
const buffer_mod = @import("buffer.zig");

pub const sidebar_width: u16 = 28;

/// Draw one frame. `selected_file` indexes `diff.files` for sidebar highlight;
/// `threads` and `drafts` feed the per-file comment / pending-draft counts.
pub fn draw(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    diff: bbr.diff.Diff,
    buf: Buffer,
    theme: Theme,
    nav: Nav,
    selected_file: usize,
    threads: []const Thread,
    drafts: []const Draft,
) void {
    const sb_w = @min(sidebar_width, win.width);
    // +1 leaves a one-column divider gutter between the panes.
    const pane_x = @min(sb_w + 1, win.width);
    drawProjected(scratch, win, diff, buf, theme, nav, selected_file, threads, drafts, .{
        .sidebar = .{ .x = 0, .y = 0, .width = sb_w, .height = win.height },
        .diff = .{ .x = pane_x, .y = 0, .width = win.width - pane_x, .height = win.height },
        .sidebar_content = .{ .x = 0, .y = 0, .width = sb_w, .height = win.height },
        .diff_content = .{ .x = pane_x, .y = 0, .width = win.width - pane_x, .height = win.height },
    });
}

fn drawProjected(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    diff: bbr.diff.Diff,
    buf: Buffer,
    theme: Theme,
    nav: Nav,
    selected_file: usize,
    threads: []const Thread,
    drafts: []const Draft,
    panes: @import("frame.zig").PaneRects,
) void {
    win.clear();
    const sidebar = win.child(.{ .x_off = panes.sidebar.x, .y_off = panes.sidebar.y, .width = panes.sidebar.width, .height = panes.sidebar.height });
    const pane = win.child(.{ .x_off = panes.diff.x, .y_off = panes.diff.y, .width = panes.diff.width, .height = panes.diff.height });
    drawSidebar(scratch, sidebar, diff, theme, selected_file, threads, drafts);
    drawPane(scratch, pane, buf, theme, nav);
}

/// Render the immutable snapshot exposed by Presentation. The terminal adapter
/// selects only the sidebar focus; it cannot reach the owned mutable review.
pub fn drawReview(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    review: ReviewProjection,
    theme: Theme,
    selected_file: usize,
) void {
    _ = selected_file;
    win.clear();
    drawPaneFrame(win, review.frame.panes.sidebar, "Files", theme, review.frame.focus == .sidebar);
    drawPaneFrame(win, review.frame.panes.diff, "Diff", theme, review.frame.focus == .diff);
    const sidebar = childRect(win, review.frame.panes.sidebar_content);
    const diff_pane = childRect(win, review.frame.panes.diff_content);
    drawFileTree(sidebar, review.frame.file_tree, theme);
    drawPane(scratch, diff_pane, review.frame.buffer, theme, review.frame.navigation);
    joinSectionRules(win, review.frame.panes.diff, review.frame.panes.diff_content, review.frame.buffer, review.frame.navigation, theme);
}

fn joinSectionRules(win: vaxis.Window, outer: @import("frame.zig").Rect, content: @import("frame.zig").Rect, buf: Buffer, nav: Nav, theme: Theme) void {
    if (outer.width == 0) return;
    var screen_row: u16 = 0;
    while (screen_row < content.height) : (screen_row += 1) {
        const index = nav.scroll + screen_row;
        if (index >= buf.rows.len) break;
        const joined = switch (buf.rows[index]) {
            .file_header, .section => true,
            else => false,
        };
        if (!joined) continue;
        const row = content.y + screen_row;
        win.writeCell(outer.x, row, .{ .char = .{ .grapheme = "├", .width = 1 }, .style = theme.section_rule });
        if (outer.width > 1) win.writeCell(outer.x + outer.width - 1, row, .{ .char = .{ .grapheme = "┤", .width = 1 }, .style = theme.section_rule });
    }
}

fn childRect(win: vaxis.Window, rect: @import("frame.zig").Rect) vaxis.Window {
    return win.child(.{ .x_off = rect.x, .y_off = rect.y, .width = rect.width, .height = rect.height });
}

fn drawPaneFrame(win: vaxis.Window, rect: @import("frame.zig").Rect, title: []const u8, theme: Theme, focused: bool) void {
    if (rect.width == 0 or rect.height == 0) return;
    const pane = childRect(win, rect);
    const style = if (focused) theme.pane_border_focused else theme.pane_border;
    const last_col = rect.width - 1;
    const last_row = rect.height - 1;
    var col: u16 = 0;
    while (col < rect.width) : (col += 1) {
        pane.writeCell(col, 0, .{ .char = .{ .grapheme = if (col == 0) "┌" else if (col == last_col) "┐" else "─", .width = 1 }, .style = style });
        if (last_row > 0) pane.writeCell(col, last_row, .{ .char = .{ .grapheme = if (col == 0) "└" else if (col == last_col) "┘" else "─", .width = 1 }, .style = style });
    }
    var row: u16 = 1;
    while (row < last_row) : (row += 1) {
        pane.writeCell(0, row, .{ .char = .{ .grapheme = if (row == 1) "├" else "│", .width = 1 }, .style = style });
        if (last_col > 0) pane.writeCell(last_col, row, .{ .char = .{ .grapheme = if (row == 1) "┤" else "│", .width = 1 }, .style = style });
    }
    if (rect.height > 1 and rect.width > 2) {
        col = 1;
        while (col < last_col) : (col += 1) pane.writeCell(col, 1, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }
    if (rect.width > 4) _ = pane.printSegment(.{ .text = title, .style = style }, .{ .row_offset = 0, .col_offset = 2, .wrap = .none });
}

fn drawFileTree(win: vaxis.Window, tree: @import("file_tree.zig").Projection, theme: Theme) void {
    var screen_row: u16 = 0;
    while (screen_row < win.height) : (screen_row += 1) {
        const index = tree.scroll + screen_row;
        if (index >= tree.entries.len) break;
        const entry = tree.entries[index];
        const style = if (entry.active or index == tree.cursor) theme.sidebar_selected else theme.sidebar_item;
        fillRow(win, screen_row, style);
        var col: u16 = @intCast(@min(entry.depth * 2, win.width));
        if (col < win.width) {
            const marker = if (entry.active) "›" else if (entry.active_descendant) "·" else " ";
            win.writeCell(col, screen_row, .{ .char = .{ .grapheme = marker, .width = 1 }, .style = style });
            col += 1;
        }
        if (entry.identity == .directory) {
            if (col < win.width) win.writeCell(col, screen_row, .{ .char = .{ .grapheme = if (entry.expanded) "▾" else "▸", .width = 1 }, .style = style });
            col +|= 1;
        } else if (entry.status) |status| {
            if (col < win.width) win.writeCell(col, screen_row, .{ .char = .{ .grapheme = statusChar(status), .width = 1 }, .style = .{ .fg = theme.statusColor(status), .bg = style.bg } });
            col +|= 1;
        }
        col +|= 1;
        if (col < win.width) _ = win.printSegment(.{ .text = entry.label, .style = style }, .{ .row_offset = screen_row, .col_offset = col, .wrap = .none });
        const tally_width: u16 = @intCast(@min(entry.tally_width, win.width));
        if (tally_width > 0) _ = win.printSegment(.{ .text = entry.tally, .style = style }, .{ .row_offset = screen_row, .col_offset = win.width - tally_width, .wrap = .none });
    }
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

fn drawSidebar(scratch: std.mem.Allocator, win: vaxis.Window, diff: bbr.diff.Diff, theme: Theme, selected_file: usize, threads: []const Thread, drafts: []const Draft) void {
    var row: u16 = 0;
    for (diff.files, 0..) |file, i| {
        if (row >= win.height) break;
        const selected = i == selected_file;
        const style = if (selected) theme.sidebar_selected else theme.sidebar_item;
        fillRow(win, row, style);

        // The status letter and file name are colored by change kind (green add,
        // yellow modify/rename, red remove) while keeping the row's background.
        const name_style: vaxis.Style = .{ .fg = theme.statusColor(file.status), .bg = style.bg, .bold = style.bold };

        // Prefix cells use static graphemes so nothing is borrowed from the stack.
        win.writeCell(0, row, .{ .char = .{ .grapheme = if (selected) ">" else " ", .width = 1 }, .style = style });
        win.writeCell(2, row, .{ .char = .{ .grapheme = statusChar(file.status), .width = 1 }, .style = name_style });
        var res = win.printSegment(.{ .text = file.displayPath(), .style = name_style }, .{ .row_offset = row, .col_offset = 4, .wrap = .none });

        // Tallies trail the name, each hidden at zero: 🗨 published comments,
        // ✎ the reviewer's own pending drafts on this file.
        const comments = fileAnchoredCount(Thread, threads, file);
        if (comments > 0) {
            const s: vaxis.Style = .{ .fg = theme.comment.fg, .bg = style.bg };
            const t = std.fmt.allocPrint(scratch, " 🗨 {d}", .{comments}) catch " 🗨";
            res = win.printSegment(.{ .text = t, .style = s }, .{ .row_offset = row, .col_offset = res.col, .wrap = .none });
        }
        const draft_n = fileAnchoredCount(Draft, drafts, file);
        if (draft_n > 0) {
            const s: vaxis.Style = .{ .fg = theme.draft.fg, .bg = style.bg };
            const t = std.fmt.allocPrint(scratch, " ✎ {d}", .{draft_n}) catch " ✎";
            _ = win.printSegment(.{ .text = t, .style = s }, .{ .row_offset = row, .col_offset = res.col, .wrap = .none });
        }
        row += 1;
    }
}

/// How many `items` (comment `Thread`s or `Draft`s) are anchored to this file —
/// a sidebar tally. Matches an anchor against either side of the path so a
/// removed file (whose display name is its old path) still counts. `T` must
/// expose its anchor: a Thread via `root.anchor`, a Draft via `anchor`.
fn fileAnchoredCount(comptime T: type, items: []const T, file: bbr.diff.File) usize {
    var n: usize = 0;
    for (items) |*it| {
        const anc = (if (T == Thread) it.root.anchor else it.anchor) orelse continue;
        if (std.mem.eql(u8, anc.path, file.new_path) or std.mem.eql(u8, anc.path, file.displayPath())) n += 1;
    }
    return n;
}

fn drawPane(scratch: std.mem.Allocator, win: vaxis.Window, buf: Buffer, theme: Theme, nav: Nav) void {
    const sel = nav.selection();
    var r: u16 = 0;
    while (r < win.height) : (r += 1) {
        const idx = nav.scroll + r;
        if (idx >= buf.rows.len) break;
        drawRow(scratch, win, r, buf.rows[idx], theme);
        // Tint the whole visual-selection band; the cursor row takes the tint a
        // second time so it stays distinguishable within the band.
        if (sel) |s| {
            if (idx >= s[0] and idx <= s[1]) highlightCursorRow(win, r, theme);
        }
        if (idx == nav.cursor) highlightCursorRow(win, r, theme);
    }
}

/// Highlight the whole cursor row (TUI "cursorline" convention): re-tint every
/// cell's background after the row is drawn, so the diff band colors show
/// through — a context row gets the neutral cursor tint, a banded row keeps its
/// hue nudged lighter. Runs after `drawRow` so it also covers a `line_pair`'s
/// two halves and the divider gap.
fn highlightCursorRow(win: vaxis.Window, r: u16, theme: Theme) void {
    var c: u16 = 0;
    while (c < win.width) : (c += 1) {
        if (win.readCell(c, r)) |cell| {
            var lit = cell;
            lit.style.bg = theme.cursorBg(cell.style.bg);
            win.writeCell(c, r, lit);
        }
    }
}

/// Gutter is two 4-wide line-number columns; body text starts after it.
const gutter_cols: u16 = 10;

fn drawRow(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, row: Row, theme: Theme) void {
    switch (row) {
        .file_header => |file| {
            fillRuleRow(win, r, theme.section_rule);
            const text = std.fmt.allocPrint(scratch, "─ {s} {s} ", .{ statusChar(file.status), file.displayPath() }) catch file.displayPath();
            _ = win.printSegment(.{ .text = text, .style = theme.file_header }, .{ .row_offset = r, .wrap = .none });
        },
        .hunk_header => |hunk| {
            fillRow(win, r, theme.hunk_header);
            _ = win.printSegment(.{ .text = hunk.header, .style = theme.hunk_header }, .{ .row_offset = r, .wrap = .none });
        },
        .line => |lr| {
            const ln = lr.line;
            const style = theme.lineStyle(ln.kind);
            fillRow(win, r, style);

            const gutter = std.fmt.allocPrint(scratch, "{s} {s} ", .{
                numCol(scratch, ln.old_no),
                numCol(scratch, ln.new_no),
            }) catch "";
            _ = win.printSegment(.{ .text = gutter, .style = theme.gutter }, .{ .row_offset = r, .wrap = .none });
            drawLineBody(scratch, win, r, gutter_cols, lr, theme, style);
        },
        .line_pair => |pair| drawLinePair(scratch, win, r, pair, theme),
        .disclosure => |value| drawDisclosure(scratch, win, r, value, theme),
        .comment => |cr| drawComment(scratch, win, r, cr, theme),
        .draft => |dr| drawDraft(scratch, win, r, dr, theme),
        .snapshot => |snapshot| drawSnapshot(win, r, snapshot, theme),
        .section => |sec| drawSection(scratch, win, r, sec, theme),
    }
}

fn fillRuleRow(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    var col: u16 = 0;
    while (col < win.width) : (col += 1) win.writeCell(col, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
}

fn drawSnapshot(win: vaxis.Window, row: u16, snapshot: buffer_mod.SnapshotRow, theme: Theme) void {
    const style = if (snapshot.selected) theme.section else theme.gutter;
    fillRow(win, row, style);
    _ = win.printSegment(.{ .text = snapshot.line, .style = style }, .{ .row_offset = row, .col_offset = gutter_cols, .wrap = .none });
}

/// Side-by-side gutter: one 4-wide line-number column plus a trailing space.
const side_gutter: u16 = 5;

/// Draw one side-by-side row: the old line in the left half, the new line in the
/// right half, split by a one-column divider. Each half is a 1-row child window
/// so a long line is clipped at the divider instead of bleeding into the other
/// pane. An absent side is drawn as a neutral empty half.
fn drawLinePair(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, pair: buffer_mod.LinePair, theme: Theme) void {
    const half = win.width / 2;
    if (half == 0) return;
    const right_x = half + 1; // divider column sits at `half`
    const right_w = if (win.width > right_x) win.width - right_x else 0;

    const left = win.child(.{ .x_off = 0, .y_off = r, .width = half, .height = 1 });
    drawHalf(scratch, left, pair.left, theme, .old);
    if (right_w > 0) {
        const right = win.child(.{ .x_off = right_x, .y_off = r, .width = right_w, .height = 1 });
        drawHalf(scratch, right, pair.right, theme, .new);
    }
}

/// Which line number a side shows: old for the left pane, new for the right.
const Side = enum { old, new };

/// Draw one half of a side-by-side row into its 1-row child window: band fill,
/// a single line-number gutter, then the (optionally emphasized) body. A null
/// side leaves a neutral empty half.
fn drawHalf(scratch: std.mem.Allocator, win: vaxis.Window, side_row: ?LineRow, theme: Theme, side: Side) void {
    const lr = side_row orelse {
        fillRow(win, 0, theme.context);
        return;
    };
    const style = theme.lineStyle(lr.line.kind);
    fillRow(win, 0, style);
    const no = switch (side) {
        .old => lr.line.old_no,
        .new => lr.line.new_no,
    };
    _ = win.printSegment(.{ .text = numCol(scratch, no), .style = theme.gutter }, .{ .row_offset = 0, .wrap = .none });
    drawLineBody(scratch, win, 0, side_gutter, lr, theme, style);
}

/// Draw a diff line's body after the gutter. Without intra-line emphasis the
/// whole line prints in its band `style`; with emphasis, the line is drawn as a
/// run of styled segments so only the changed runs get the brighter band.
fn drawLineBody(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, body_col: u16, lr: LineRow, theme: Theme, style: vaxis.Style) void {
    const emph = theme.emphasisStyle(lr.line.kind);
    const segs = scratch.alloc(vaxis.Segment, lr.decoration.runs.len) catch {
        _ = win.printSegment(.{ .text = lr.line.text, .style = style }, .{ .row_offset = r, .col_offset = body_col, .wrap = .none });
        return;
    };
    for (lr.decoration.runs, 0..) |run, i| {
        var run_style = if (run.emphasis) emph else style;
        if (run.capture) |capture| {
            if (theme.captureColor(capture)) |fg| run_style.fg = fg;
        }
        segs[i] = .{ .text = run.text, .style = run_style };
    }
    _ = win.print(segs, .{ .row_offset = r, .col_offset = body_col, .wrap = .none });
}

/// First line of a body (comment bodies may be multi-line; one row shows the
/// A woven comment, one visual line per row (M11 A2). The `is_first` row carries
/// the marker + author; continuation rows hang-indent the body two columns in.
/// Root at col 2, reply at col 6. A ```suggestion gets the suggestion style and
/// a `±` marker so it reads distinctly; the body is drawn verbatim (fences and
/// all — markdown rendering is a later follow-up).
fn drawComment(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, cr: CommentRow, theme: Theme) void {
    drawReviewCard(scratch, win, r, cr, theme);
}

/// A pending Draft — the reviewer's own unsent comment, one visual line per row.
/// Marked `✎` (root) or `↳` (reply) in the draft band so it never reads as
/// already-published; a suggestion Draft shows its `±` marker. Continuation rows
/// hang-indent like a comment. The body is drawn verbatim.
fn drawDraft(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, dr: DraftRow, theme: Theme) void {
    drawReviewCard(scratch, win, r, dr, theme);
}

fn drawReviewCard(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, card: buffer_mod.ReviewCardRow, theme: Theme) void {
    var base = theme.reviewCardStyle(card.role, card.part, .{});
    if (card.block_kind == .heading) base.bold = true;
    fillRow(win, r, base);
    if (card.segments.len == 0) return;
    const segments = scratch.alloc(vaxis.Segment, card.segments.len) catch return;
    for (card.segments, 0..) |segment, index| segments[index] = .{
        .text = segment.text,
        .style = theme.reviewCardStyle(card.role, card.part, segment.marks),
    };
    const col: u16 = (if (card.isReply()) @as(u16, 6) else 2) + (if (card.part == .header) @as(u16, 0) else 2);
    _ = win.print(segments, .{ .row_offset = r, .col_offset = col, .wrap = .none });
}

fn drawDisclosure(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, value: buffer_mod.Disclosure, theme: Theme) void {
    const style = if (value.kind == .fold) theme.fold else theme.section;
    fillRow(win, r, style);
    const glyph: []const u8 = if (value.expanded) "▾" else "▸";
    const text = switch (value.kind) {
        .resolved_thread => std.fmt.allocPrint(scratch, "{s} ✓ Resolved thread · {d} replies", .{ glyph, value.count }) catch glyph,
        .fold => std.fmt.allocPrint(scratch, "{s} ⋯ {d} unchanged lines", .{ glyph, value.count }) catch glyph,
        .outdated => if (value.path.len > 0)
            std.fmt.allocPrint(scratch, "{s} Outdated · {s} · {d} threads", .{ glyph, value.path, value.count }) catch glyph
        else
            std.fmt.allocPrint(scratch, "{s} Outdated · {d} threads", .{ glyph, value.count }) catch glyph,
        .review_card => unreachable,
    };
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = r, .col_offset = gutter_cols, .wrap = .none });
}

/// A section divider: "── PR comments (N) ──" or "── Outdated · path (N) ──".
fn drawSection(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, sec: Section, theme: Theme) void {
    fillRow(win, r, .{});
    const text = switch (sec.kind) {
        .pr_comments => std.fmt.allocPrint(scratch, "── PR comments ({d}) ──", .{sec.count}) catch "── PR comments ──",
        .pending => std.fmt.allocPrint(scratch, "── Pending ({d}) ──", .{sec.count}) catch "── Pending ──",
        .outdated => if (sec.path.len > 0)
            std.fmt.allocPrint(scratch, "── Outdated · {s} ({d}) ──", .{ sec.path, sec.count }) catch "── Outdated ──"
        else
            std.fmt.allocPrint(scratch, "── Outdated ({d}) ──", .{sec.count}) catch "── Outdated ──",
        .unavailable => std.fmt.allocPrint(scratch, "── Anchor unavailable ({d}) ──", .{sec.count}) catch "── Anchor unavailable ──",
    };
    _ = win.printSegment(.{ .text = text, .style = theme.section }, .{ .row_offset = r, .wrap = .none });
}

/// Draw the PR Picker as a centered modal over the current frame. Shows a
/// query/prompt line, then the ranked matches (best first), the selected one
/// highlighted, scrolled to keep the cursor visible. `scratch` outlives render.
/// Center a modal box of up to `max_w`×`max_h` over `win`, bounded by it.
/// Returns null when there's no room. The shared geometry behind every overlay.
fn centeredModal(win: vaxis.Window, max_w: u16, max_h: u16) ?vaxis.Window {
    const rect = @import("frame.zig").overlayRect(.{ .cols = win.width, .rows = win.height }, max_w, max_h) orelse return null;
    return childRect(win, rect);
}

pub fn drawPicker(scratch: std.mem.Allocator, win: vaxis.Window, picker: *const Picker, theme: Theme) void {
    // Modal geometry: centered, up to 60 cols × 16 rows, but bounded by the win.
    const modal = centeredModal(win, 60, 16) orelse return;
    const h = modal.height;

    // Row 0: prompt + query. Rows 1..h-1: matches.
    fillRow(modal, 0, theme.picker_query);
    const prompt = std.fmt.allocPrint(scratch, "› {s}", .{picker.query()}) catch "›";
    _ = modal.printSegment(.{ .text = prompt, .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });

    const list_rows: u16 = h - 1;
    const matches = picker.matches();

    // Before the summaries fetch returns (async open) show a placeholder in the
    // list area; an empty repo after loading gets a distinct "none" line.
    if (picker.loading or picker.prs.len == 0) {
        var r: u16 = 1;
        while (r <= list_rows) : (r += 1) fillRow(modal, r, theme.picker);
        const msg: []const u8 = if (picker.loading)
            (std.fmt.allocPrint(scratch, "{s} Loading pull requests…", .{picker.spinnerGlyph()}) catch "  Loading pull requests…")
        else
            "  no open pull requests";
        _ = modal.printSegment(.{ .text = msg, .style = theme.picker }, .{ .row_offset = 1, .wrap = .none });
        return;
    }

    // Scroll so the selected row stays on screen.
    var top: usize = 0;
    if (picker.selected >= list_rows) top = picker.selected - list_rows + 1;

    var r: u16 = 1;
    while (r <= list_rows) : (r += 1) {
        const mi = top + (r - 1);
        if (mi >= matches.len) {
            fillRow(modal, r, theme.picker);
            continue;
        }
        const selected = mi == picker.selected;
        const style = if (selected) theme.picker_selected else theme.picker;
        fillRow(modal, r, style);

        const pr = picker.prs[matches[mi]];
        const marker: []const u8 = if (selected) "▸ " else "  ";
        const text = std.fmt.allocPrint(scratch, "{s}#{d}  {s}  ({s})", .{
            marker, pr.id, pr.title, pr.source_branch,
        }) catch pr.title;
        _ = modal.printSegment(.{ .text = text, .style = style }, .{ .row_offset = r, .wrap = .none });
    }
}

pub fn drawFileFinder(scratch: std.mem.Allocator, win: vaxis.Window, finder: *const FileFinder, theme: Theme) void {
    const modal = centeredModal(win, 60, 16) orelse return;
    fillRow(modal, 0, theme.picker_query);
    const prompt = std.fmt.allocPrint(scratch, "File › {s}", .{finder.query()}) catch "File ›";
    _ = modal.printSegment(.{ .text = prompt, .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });
    const list_rows = modal.height - 1;
    const matches = finder.matches();
    var top: usize = 0;
    if (finder.selected >= list_rows) top = finder.selected - list_rows + 1;
    var row: u16 = 1;
    while (row <= list_rows) : (row += 1) {
        const match_index = top + row - 1;
        const selected = match_index < matches.len and match_index == finder.selected;
        const style = if (selected) theme.picker_selected else theme.picker;
        fillRow(modal, row, style);
        if (match_index < matches.len) {
            const file = finder.files[matches[match_index]];
            const text = std.fmt.allocPrint(scratch, "{s}{s}", .{ if (selected) "▸ " else "  ", file.displayPath() }) catch file.displayPath();
            _ = modal.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .wrap = .none });
        } else if (row == 1 and matches.len == 0) {
            const message = if (finder.files.len == 0) "  no changed files" else "  no matching files";
            _ = modal.printSegment(.{ .text = message, .style = style }, .{ .row_offset = row, .wrap = .none });
        }
    }
}

/// Draw the Composer as a centered modal: a header naming what's being authored,
/// the body typed so far (scrolled to the tail with a cursor block), and a hint
/// line. Borrowed text (the label, the body) outlives render via the composer's
/// own arena. `scratch` outlives render for the synthesized header/hint.
pub fn drawComposerProjection(scratch: std.mem.Allocator, win: vaxis.Window, composer: presentation.ComposerProjection, theme: Theme) void {
    drawComposerText(scratch, win, composer.label, composer.body, theme);
}

fn drawComposerText(scratch: std.mem.Allocator, win: vaxis.Window, label: []const u8, body: []const u8, theme: Theme) void {
    const modal = centeredModal(win, 72, 14) orelse return;
    const h = modal.height;

    // Header (row 0) and hint (last row).
    fillRow(modal, 0, theme.picker_query);
    const header = std.fmt.allocPrint(scratch, "✎ {s}", .{label}) catch "✎ compose";
    _ = modal.printSegment(.{ .text = header, .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });

    const hint_row = h - 1;
    fillRow(modal, hint_row, theme.picker_query);
    _ = modal.printSegment(
        .{ .text = "^D submit · ^W del word · ^U del line · esc cancel", .style = theme.picker_query },
        .{ .row_offset = hint_row, .wrap = .none },
    );

    // Body region: rows 1..hint_row-1. Split the body into lines, scroll so the
    // tail (where the cursor is) stays visible, and mark the end with a block.
    const body_rows: u16 = if (hint_row > 1) hint_row - 1 else 0;
    var r: u16 = 1;
    while (r < hint_row) : (r += 1) fillRow(modal, r, theme.picker);

    var total: u16 = 1; // one line, plus one per newline
    for (body) |ch| {
        if (ch == '\n') total += 1;
    }
    const first_visible: u16 = if (total > body_rows) total - body_rows else 0;

    var li: u16 = 0;
    var out_row: u16 = 1;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| : (li += 1) {
        if (li < first_visible) continue;
        if (out_row >= hint_row) break;
        const is_last = it.peek() == null;
        const text = if (is_last)
            std.fmt.allocPrint(scratch, "{s}▌", .{line}) catch line
        else
            line;
        _ = modal.printSegment(.{ .text = text, .style = theme.picker }, .{ .row_offset = out_row, .col_offset = 1, .wrap = .none });
        out_row += 1;
    }
}

/// Draw the "Submitting review" progress modal over the viewer while a batch
/// runs (M10b). A small centered box: a title, an `n / total posted` line, and
/// a note that it can't be interrupted. `scratch` outlives render.
pub fn drawSubmit(scratch: std.mem.Allocator, win: vaxis.Window, theme: Theme, seen: usize, total: usize) void {
    const modal = centeredModal(win, 40, 5) orelse return;
    var r: u16 = 0;
    while (r < modal.height) : (r += 1) fillRow(modal, r, theme.picker);

    fillRow(modal, 0, theme.picker_query);
    _ = modal.printSegment(.{ .text = " Submitting review", .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });

    if (modal.height > 2) {
        const line = std.fmt.allocPrint(scratch, "  {d} / {d} items", .{ seen, total }) catch "  submitting…";
        _ = modal.printSegment(.{ .text = line, .style = theme.picker }, .{ .row_offset = 2, .wrap = .none });
    }
    const hint_row = modal.height - 1;
    if (hint_row >= 3) {
        fillRow(modal, hint_row, theme.picker_query);
        _ = modal.printSegment(.{ .text = " publishing to Bitbucket…", .style = theme.picker_query }, .{ .row_offset = hint_row, .wrap = .none });
    }
}

/// Draw the finished-Submission result dialog (M10b): a title reflecting the
/// terminal state (submitted / aborted / stale) and the tallies, held up until
/// the reviewer dismisses it. Takes over from `drawSubmit` when the batch ends.
pub fn drawSubmitResult(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    theme: Theme,
    posted: usize,
    failed: usize,
    skipped: usize,
    aborted: ?[]const u8,
    stale: bool,
) void {
    const modal = centeredModal(win, 48, 6) orelse return;
    var r: u16 = 0;
    while (r < modal.height) : (r += 1) fillRow(modal, r, theme.picker);

    fillRow(modal, 0, theme.picker_query);
    const title: []const u8 = if (stale)
        " Submit refused — PR moved"
    else if (aborted != null)
        " Submit aborted"
    else if (failed > 0 or skipped > 0)
        " Submission completed with issues"
    else
        " Review submitted";
    _ = modal.printSegment(.{ .text = title, .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });

    if (modal.height > 2) {
        const line: []const u8 = if (stale)
            "  reopen the PR before submitting"
        else if (aborted) |name|
            std.fmt.allocPrint(scratch, "  {s} — all kept pending", .{name}) catch "  aborted"
        else
            std.fmt.allocPrint(scratch, "  {d} posted · {d} failed · {d} skipped", .{ posted, failed, skipped }) catch "  done";
        _ = modal.printSegment(.{ .text = line, .style = theme.picker }, .{ .row_offset = 2, .wrap = .none });
    }

    const hint_row = modal.height - 1;
    if (hint_row >= 3) {
        fillRow(modal, hint_row, theme.picker_query);
        _ = modal.printSegment(.{ .text = " press any key to dismiss", .style = theme.picker_query }, .{ .row_offset = hint_row, .wrap = .none });
    }
}

/// A short display label for a key codepoint: named for the special keys,
/// otherwise the codepoint's own utf8. `scratch` outlives render.
fn keyName(scratch: std.mem.Allocator, cp: u21) []const u8 {
    return switch (cp) {
        vaxis.Key.enter => "⏎",
        vaxis.Key.escape => "esc",
        vaxis.Key.up => "↑",
        vaxis.Key.down => "↓",
        vaxis.Key.home => "home",
        vaxis.Key.end => "end",
        vaxis.Key.page_up => "pgup",
        vaxis.Key.page_down => "pgdn",
        else => blk: {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &b) catch break :blk "?";
            break :blk scratch.dupe(u8, b[0..n]) catch "?";
        },
    };
}

/// Format a Chord for the help overlay, including configured multi-chord Actions.
fn chordLabel(scratch: std.mem.Allocator, c: keymap.Chord) []const u8 {
    var out: []const u8 = "";
    for (0..c.len()) |i| {
        const stroke = c.at(i);
        var label = keyName(scratch, stroke.cp);
        if (stroke.mods.shift) label = std.fmt.allocPrint(scratch, "shift-{s}", .{label}) catch label;
        if (stroke.mods.alt) label = std.fmt.allocPrint(scratch, "alt-{s}", .{label}) catch label;
        if (stroke.mods.ctrl) label = std.fmt.allocPrint(scratch, "ctrl-{s}", .{label}) catch label;
        if (stroke.mods.super) label = std.fmt.allocPrint(scratch, "super-{s}", .{label}) catch label;
        if (stroke.mods.hyper) label = std.fmt.allocPrint(scratch, "hyper-{s}", .{label}) catch label;
        if (stroke.mods.meta) label = std.fmt.allocPrint(scratch, "meta-{s}", .{label}) catch label;
        out = std.fmt.allocPrint(scratch, "{s}{s}{s}", .{ out, if (i == 0) "" else " ", label }) catch label;
    }
    return out;
}

/// Coalesce the Keymap into two help columns — Motions and commands — one line
/// per Action ("keys  label"), merging the (adjacent) alternate bindings of an
/// Action into one "j ↓"-style key list.
const HelpRow = struct { text: []const u8, available: bool };
const HelpRows = struct { motions: []HelpRow, commands: []HelpRow };
fn buildHelpRows(scratch: std.mem.Allocator, km: keymap.Keymap, availability: presentation.ActionAvailability) HelpRows {
    var motions: std.ArrayList(HelpRow) = .empty;
    var commands: std.ArrayList(HelpRow) = .empty;
    var i: usize = 0;
    while (i < km.bindings.len) {
        const act = km.bindings[i].action;
        const help = km.bindings[i].help;
        var keys: std.ArrayList(u8) = .empty;
        while (i < km.bindings.len and km.bindings[i].action == act) : (i += 1) {
            if (keys.items.len > 0) keys.append(scratch, ' ') catch {};
            keys.appendSlice(scratch, chordLabel(scratch, km.bindings[i].chord)) catch {};
        }
        const line = std.fmt.allocPrint(scratch, "{s:<8}{s}", .{ keys.items, help }) catch help;
        (if (keymap.isMotion(act)) &motions else &commands).append(scratch, .{
            .text = line,
            .available = availability.available(act),
        }) catch {};
    }
    return .{ .motions = motions.items, .commands = commands.items };
}

/// Draw the keybinding-help Overlay: a centered modal with Motions in the left
/// column and commands in the right, read straight from the Keymap so it can
/// never drift from the live bindings. Dismissed by any key. `scratch` outlives
/// render for the synthesized rows.
pub fn drawHelp(scratch: std.mem.Allocator, win: vaxis.Window, theme: Theme, km: keymap.Keymap, availability: presentation.ActionAvailability) void {
    const rows = buildHelpRows(scratch, km, availability);
    const n = @max(rows.motions.len, rows.commands.len);
    const want_h: u16 = @intCast(@min(n + 5, 255));
    const modal = centeredModal(win, 74, want_h) orelse return;
    var r: u16 = 0;
    while (r < modal.height) : (r += 1) fillRow(modal, r, theme.picker);

    fillRow(modal, 0, theme.picker_query);
    _ = modal.printSegment(.{ .text = " Keybindings", .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });

    const col_right: u16 = modal.width / 2 + 1;
    const keyboard_rows = @min(n, modal.height -| 5);
    var i: usize = 0;
    while (i < keyboard_rows) : (i += 1) {
        const rr: u16 = 1 + @as(u16, @intCast(i));
        if (i < rows.motions.len)
            _ = modal.printSegment(.{ .text = rows.motions[i].text, .style = if (rows.motions[i].available) theme.picker else theme.gutter }, .{ .row_offset = rr, .col_offset = 2, .wrap = .none });
        if (i < rows.commands.len)
            _ = modal.printSegment(.{ .text = rows.commands[i].text, .style = if (rows.commands[i].available) theme.picker else theme.gutter }, .{ .row_offset = rr, .col_offset = col_right, .wrap = .none });
    }

    const mouse_row: u16 = @intCast(keyboard_rows + 1);
    if (mouse_row + 2 < modal.height) {
        _ = modal.printSegment(.{ .text = " Mouse", .style = theme.picker_query }, .{ .row_offset = mouse_row, .col_offset = 1, .wrap = .none });
        _ = modal.printSegment(.{ .text = " click focus/select/toggle · wheel scroll", .style = theme.picker }, .{ .row_offset = mouse_row + 1, .col_offset = 2, .wrap = .none });
        _ = modal.printSegment(.{ .text = " Shift/Option: native selection · [input.mouse] enabled=false", .style = theme.gutter }, .{ .row_offset = mouse_row + 2, .col_offset = 2, .wrap = .none });
    }

    const hint_row = modal.height - 1;
    fillRow(modal, hint_row, theme.picker_query);
    _ = modal.printSegment(.{ .text = " press any key to dismiss", .style = theme.picker_query }, .{ .row_offset = hint_row, .wrap = .none });
}

/// The boot/switch frame shown until a Session arrives: a centered floating
/// "Loading PR #N…" dialog (or the error, if the fetch failed), over a cleared
/// backdrop. `scratch` outlives render for the synthesized text.
pub fn drawLoading(scratch: std.mem.Allocator, win: vaxis.Window, id: ?u64, theme: Theme, status_msg: ?[]const u8) void {
    if (win.height == 0 or win.width == 0) return;
    // Blank the whole window first: on a switch the previous viewer frame is
    // still in the screen buffer behind the dialog.
    win.clear();
    const modal = centeredModal(win, 48, 3) orelse return;
    var r: u16 = 0;
    while (r < modal.height) : (r += 1) fillRow(modal, r, theme.picker);
    const text: []const u8 = if (status_msg) |m|
        if (id) |pr_id| std.fmt.allocPrint(scratch, " PR #{d}: {s}", .{ pr_id, m }) catch m else m
    else if (id) |pr_id|
        std.fmt.allocPrint(scratch, " Loading PR #{d}…", .{pr_id}) catch "Loading…"
    else
        " Loading local review…";
    const row = modal.height / 2;
    _ = modal.printSegment(.{ .text = text, .style = theme.picker_query }, .{ .row_offset = row, .wrap = .none });
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
    const buf = try buffer_mod.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

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

test "syntax foreground composes over an added Line background" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\diff --git a/a.js b/a.js
        \\--- a/a.js
        \\+++ b/a.js
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const spans = [_]bbr.highlight.Span{.{ .line = 1, .start = 0, .end = 3, .capture = .{ .name = "keyword" } }};
    const highlights = [_]bbr.highlight.FileHighlights{.{ .new = .{ .spans = &spans } }};
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, &.{}, .{ .highlights = &highlights });

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    draw(a, win, diff, buf, theme_dark, Nav.init(buf.rows.len, 24), 0, &.{}, &.{});

    const cell = win.readCell(sidebar_width + 1 + gutter_cols, 3).?;
    try testing.expectEqual(theme_dark.syntax_keyword, cell.style.fg);
    try testing.expectEqual(theme_dark.added.bg, cell.style.bg);
}

test "a modified line paints only its changed run with the emphasis band" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-let value = 1;
        \\+let value = 2;
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try buffer_mod.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    // Pane rows: 0 header, 1 hunk, 2 removed, 3 added. Body starts after gutter.
    const px = sidebar_width + 1;
    const body_x = px + gutter_cols;
    // "let value = " is common (base band); the digit at the end is emphasized.
    // Column of the common prefix keeps the base removed band...
    try testing.expectEqual(theme_dark.removed.bg, win.readCell(body_x, 2).?.style.bg);
    // ...while the changed "1" (13 chars in: "let value = " is 12) gets the brighter band.
    try testing.expectEqual(theme_dark.removed_emphasis.bg, win.readCell(body_x + 12, 2).?.style.bg);
    // Same on the added side for "2".
    try testing.expectEqual(theme_dark.added_emphasis.bg, win.readCell(body_x + 12, 3).?.style.bg);
}

test "side-by-side draws old on the left, new on the right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-let x = 1;
        \\+let x = 2;
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try buffer_mod.build(a, diff, .side_by_side);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    // Pane starts at sidebar_width+1. Rows: 0 header, 1 hunk, 2 ctx, 3 modified.
    // Read the first body cell of each half (after its line-number gutter) — the
    // gutter cells and the col-0 cursor marker carry their own styles.
    const px = sidebar_width + 1;
    const pane_w = 80 - px;
    const half = pane_w / 2;
    const body_l = px + side_gutter;
    const body_r = px + (half + 1) + side_gutter;

    // Modified row (3): the common leading run keeps the base band — removed on
    // the left, added on the right.
    try testing.expectEqual(theme_dark.removed.bg, win.readCell(body_l, 3).?.style.bg);
    try testing.expectEqual(theme_dark.added.bg, win.readCell(body_r, 3).?.style.bg);

    // Context row (2): both halves are neutral.
    try testing.expect(win.readCell(body_l, 2).?.style.bg == .default);
    try testing.expect(win.readCell(body_r, 2).?.style.bg == .default);
}

test "the cursor row is highlighted across its whole width, keeping band hue" {
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
    const buf = try buffer_mod.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    // Put the cursor on the removed line (pane row 3).
    var nav = Nav.init(buf.rows.len, 24);
    nav.cursor = 3;
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    const px = sidebar_width + 1;
    const body_x = px + gutter_cols;

    // The removed band keeps its hue but is nudged to the cursor variant.
    const expected = theme_dark.cursorBg(theme_dark.removed.bg);
    try testing.expectEqual(expected, win.readCell(body_x, 3).?.style.bg);
    // The tint reaches the far edge of the row (whole-line highlight).
    try testing.expectEqual(expected, win.readCell(79, 3).?.style.bg);

    // A neutral cell on the cursor row (the gutter, default bg) takes the plain
    // cursor_line tint.
    try testing.expectEqual(theme_dark.cursor_line, win.readCell(px, 3).?.style.bg);

    // An off-cursor line keeps its untinted band.
    try testing.expectEqual(theme_dark.added.bg, win.readCell(body_x, 4).?.style.bg);
}

test "a folded context run renders as a fold row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
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
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, &.{}, .{ .fold_context = true });

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    // Find the fold row's screen position by scanning the buffer.
    var fold_row: ?u16 = null;
    for (buf.rows, 0..) |row, idx| {
        if (row == .disclosure and row.disclosure.kind == .fold) fold_row = @intCast(idx);
    }
    const fr = fold_row.?;
    const px = sidebar_width + 1;
    try testing.expectEqual(theme_dark.fold.bg, win.readCell(px + gutter_cols, fr).?.style.bg);
    // "  ⋯ …" — the ellipsis sits two columns into the body.
    try testing.expectEqualStrings("⋯", win.readCell(px + gutter_cols + 2, fr).?.char.grapheme);
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
    const buf = try buffer_mod.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 1, &.{}, &.{}); // select second file

    // Selected row (sidebar row 1) carries the selected background.
    const sel = win.readCell(0, 1).?;
    try testing.expectEqual(theme_dark.sidebar_selected.bg, sel.style.bg);
    // The unselected row does not.
    const unsel = win.readCell(0, 0).?;
    try testing.expect(unsel.style.bg == .default);
}

const theme_dark = @import("theme.zig").dark;

test "the sidebar tallies comments per file and hides a zero count" {
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
    const buf = try buffer_mod.build(a, diff, .unified);

    // Two comments on one.txt, none on two.txt.
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Ada", .body = "x", .anchor = .{ .path = "one.txt", .to = 1 } },
        .{ .id = 2, .author = "Bo", .body = "y", .anchor = .{ .path = "one.txt", .to = 1 } },
    };
    const threads = try bbr.review.buildThreads(a, &comments);
    // One pending draft on two.txt.
    const drafts = [_]bbr.review.Draft{
        .{ .local_id = 1, .kind = .comment, .body = "wip", .anchor = .{ .path = "two.txt", .to = 1 } },
    };

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, threads, &drafts);

    // Row 0 (one.txt) shows the comment tally bubble and the count "2", no drafts.
    try testing.expect(rowHasGrapheme(win, 0, "🗨"));
    try testing.expect(rowHasGrapheme(win, 0, "2"));
    try testing.expect(!rowHasGrapheme(win, 0, "✎"));
    // Row 1 (two.txt) has no comments (no bubble) but one draft (✎).
    try testing.expect(!rowHasGrapheme(win, 1, "🗨"));
    try testing.expect(rowHasGrapheme(win, 1, "✎"));
}

/// True if any cell in sidebar-width row `r` renders `g`.
fn rowHasGrapheme(win: vaxis.Window, r: u16, g: []const u8) bool {
    var c: u16 = 0;
    while (c < sidebar_width) : (c += 1) {
        if (win.readCell(c, r)) |cell| {
            if (std.mem.eql(u8, cell.char.grapheme, g)) return true;
        }
    }
    return false;
}

test "the Composer Overlay draws its projected header and body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawComposerProjection(a, win, .{ .label = "New comment", .body = "looks good" }, theme_dark);

    // Modal geometry: 72×14 centered on 80×24 → origin (4, 5). Header row 0.
    const mx: u16 = (80 - 72) / 2;
    const my: u16 = (24 - 14) / 2;
    try testing.expectEqualStrings("✎", win.readCell(mx, my).?.char.grapheme);
    try testing.expectEqual(theme_dark.picker_query.bg, win.readCell(mx, my).?.style.bg);
    // The body's first line sits one column in on the first body row.
    try testing.expectEqualStrings("l", win.readCell(mx + 1, my + 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.picker.bg, win.readCell(mx + 1, my + 1).?.style.bg);
}

test "a pending draft renders in the draft band with its marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const drafts = [_]bbr.review.Draft{
        .{ .local_id = 1, .kind = .comment, .body = "author it", .anchor = .{ .path = "a.txt", .to = 1, .commit = "c0" } },
    };
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    // Find the draft row's screen position.
    var draft_row: ?u16 = null;
    for (buf.rows, 0..) |row, idx| {
        if (row == .draft and row.draft.part == .header) draft_row = @intCast(idx);
    }
    const dr = draft_row.?;
    const px = sidebar_width + 1;
    try testing.expectEqualStrings("✎", win.readCell(px + 2, dr).?.char.grapheme);
    try testing.expectEqual(theme_dark.draft.bg, win.readCell(px + 2, dr).?.style.bg);
}

test "picker overlay draws the query line and highlights the selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prs = [_]bbr.bitbucket.PullRequestSummary{
        .{ .id = 10, .title = "Add diff parser", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/diff", .destination_branch = "main" },
        .{ .id = 11, .title = "Fix navigation", .state = "OPEN", .author_display_name = "Grace", .source_branch = "feature/nav", .destination_branch = "main" },
    };
    var picker = try Picker.init(a, &prs);
    defer picker.deinit();
    picker.moveDown(); // select the second entry

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPicker(a, win, &picker, theme_dark);

    // Modal geometry: 60×16, centered on 80×24 → origin (10, 4).
    const mx: u16 = 10;
    const my: u16 = 4;
    // Row 0 of the modal is the query prompt "› …".
    try testing.expectEqualStrings("›", win.readCell(mx, my).?.char.grapheme);
    try testing.expectEqual(theme_dark.picker_query.bg, win.readCell(mx, my).?.style.bg);
    // Match rows follow. The selected (second) entry carries the ▸ marker and the
    // selected background; the first entry does not.
    try testing.expectEqualStrings("▸", win.readCell(mx, my + 2).?.char.grapheme);
    try testing.expectEqual(theme_dark.picker_selected.bg, win.readCell(mx, my + 2).?.style.bg);
    try testing.expectEqual(theme_dark.picker.bg, win.readCell(mx, my + 1).?.style.bg);
}

test "a loading picker shows its single-glyph spinner beside the placeholder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var picker = Picker.initLoading(a);
    defer picker.deinit();

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPicker(a, win, &picker, theme_dark);

    // Modal at (10, 4); row 1 of the modal carries "  loading…".
    const mx: u16 = 10;
    const my: u16 = 4;
    try testing.expectEqualStrings("L", win.readCell(mx + 2, my + 1).?.char.grapheme);
    try testing.expectEqualStrings(picker.spinnerGlyph(), win.readCell(mx, my + 1).?.char.grapheme);
}

test "the boot loading view floats a Loading PR dialog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawLoading(a, win, 42, theme_dark, null);

    // Dialog: 48×3 centered on 80×24 → x=16, y=10; text on the middle row (11),
    // one leading space, so 'L' of "Loading" is at col 17.
    try testing.expectEqualStrings("L", win.readCell(17, 11).?.char.grapheme);
    try testing.expectEqualStrings("#", win.readCell(28, 11).?.char.grapheme);

    // With a status message the id-prefixed error takes its place.
    var screen2 = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen2.deinit(a);
    const win2 = headlessWindow(&screen2);
    drawLoading(a, win2, 42, theme_dark, "NotFound");
    try testing.expectEqualStrings("P", win2.readCell(17, 11).?.char.grapheme);
}

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
    const buf = try buffer_mod.build(a, diff, .unified);

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{}); // first file selected

    // Row 0: selected → ">", modified → "M". Read back after draw (the bug this
    // guards against was borrowing a per-iteration stack buffer, which showed
    // the *last* file's prefix on every row).
    try testing.expectEqualStrings(">", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("M", win.readCell(2, 0).?.char.grapheme);
    // Row 1: not selected → " ", deleted → "D".
    try testing.expectEqualStrings(" ", win.readCell(0, 1).?.char.grapheme);
    try testing.expectEqualStrings("D", win.readCell(2, 1).?.char.grapheme);

    // A deleted file shows its real name, NOT the diff's `/dev/null` new side.
    try testing.expectEqualStrings("g", win.readCell(4, 1).?.char.grapheme);

    // The name is colored by change kind: modified → yellow, removed → red.
    try testing.expectEqual(theme_dark.status_modified, win.readCell(4, 0).?.style.fg);
    try testing.expectEqual(theme_dark.status_removed, win.readCell(4, 1).?.style.fg);
}

test "focused Pane frames and File Tree tallies use Frame-owned geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const panes = @import("frame.zig").paneRects(.{ .cols = 32, .rows = 8 });
    drawPaneFrame(win, panes.sidebar, "Files", theme_dark, true);
    drawPaneFrame(win, panes.diff, "Diff", theme_dark, false);
    try testing.expectEqualStrings("┌", win.readCell(panes.sidebar.x, 0).?.char.grapheme);
    try testing.expect(win.readCell(panes.sidebar.x, 0).?.style.bold);
    try testing.expect(!win.readCell(panes.diff.x, 0).?.style.bold);
    try testing.expectEqualStrings("├", win.readCell(panes.sidebar.x, 1).?.char.grapheme);

    const entries = [_]@import("file_tree.zig").Entry{.{
        .identity = .{ .file = 0 },
        .parent = null,
        .depth = 0,
        .label = "long-name…",
        .active = true,
        .status = .modified,
        .comments = 3,
        .drafts = 1,
        .tally = "●3 ✎1",
        .tally_width = 5,
    }};
    const content = childRect(win, panes.sidebar_content);
    drawFileTree(content, .{ .entries = &entries, .cursor = 0, .scroll = 0, .viewport = content.height }, theme_dark);
    try testing.expectEqualStrings("1", content.readCell(content.width - 1, 0).?.char.grapheme);
    try testing.expectEqualStrings("●", content.readCell(content.width - 5, 0).?.char.grapheme);
}

test "a woven comment renders with its marker and style; a suggestion is distinct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Ada", .body = "please rename", .anchor = .{ .path = "a.txt", .to = 1 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "```suggestion\nrenamed\n```" },
    };
    const threads = try bbr.review.buildThreads(a, &comments);
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, threads, .{});

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    // Pane rows: root header/body, then Suggestion reply header, semantic label,
    // and literal code body. Fences themselves are structural, not displayed.
    const px = sidebar_width + 1;
    // Root comment marker "▸" at its indent (col 2 within the pane).
    try testing.expectEqualStrings("▸", win.readCell(px + 2, 4).?.char.grapheme);
    try testing.expectEqual(theme_dark.comment.bg, win.readCell(px + 2, 4).?.style.bg);
    try testing.expectEqualStrings("±", win.readCell(px + 6, 6).?.char.grapheme);
    try testing.expectEqual(theme_dark.comment_reply.bg, win.readCell(px + 6, 6).?.style.bg);
    try testing.expectEqualStrings("s", win.readCell(px + 8, 7).?.char.grapheme);
    try testing.expectEqual(theme_dark.suggestion.bg, win.readCell(px + 8, 7).?.style.bg);
    try testing.expectEqualStrings("r", win.readCell(px + 8, 8).?.char.grapheme);
    try testing.expectEqual(theme_dark.suggestion.bg, win.readCell(px + 8, 8).?.style.bg);
}

test "the help overlay floats a centered Keybindings modal from the Keymap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawHelp(a, win, theme_dark, keymap.Keymap.default, .{ .remote = true });

    const rows = buildHelpRows(a, keymap.Keymap.default, .{ .remote = true });
    const modal_height: u16 = @intCast(@min(@max(rows.motions.len, rows.commands.len) + 5, screen.height));
    const modal_y = (screen.height - modal_height) / 2;
    // Title " Keybindings" begins one cell into the centered 74-column modal.
    try testing.expectEqualStrings("K", win.readCell(4, modal_y).?.char.grapheme);
    // First motion row starts at col_offset 2 and one row below the title →
    // screen col 5, and the first motion binding is `j`/`↓` → down.
    try testing.expectEqualStrings("j", win.readCell(5, modal_y + 1).?.char.grapheme);
    const mouse_row: u16 = @intCast(@min(@max(rows.motions.len, rows.commands.len), modal_height -| 5) + 1);
    try testing.expectEqualStrings("M", win.readCell(5, modal_y + mouse_row).?.char.grapheme);
}

test "local help projection marks remote-only commands unavailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = false });
    var unavailable: usize = 0;
    for (rows.commands) |row| {
        if (!row.available) unavailable += 1;
    }
    // Four remote-only commands, plus edit, re-anchor, and delete — visible but
    // refused away from a ReviewCard — and the Picker.
    try testing.expectEqual(@as(usize, 8), unavailable);
    for (rows.motions) |row| try testing.expect(row.available);
}

test "delete stays discoverable in the help Overlay when it is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refused = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .delete_refusal = .descendant_locked });
    const deletable = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .delete_refusal = null });
    try testing.expect(!helpRowAvailable(refused.commands, "delete local Draft subtree").?);
    try testing.expect(helpRowAvailable(deletable.commands, "delete local Draft subtree").?);
}

test "re-anchor stays discoverable in the help Overlay when it is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refused = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .reanchor_refusal = .reply_inherits_scope });
    const anchorable = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .reanchor_refusal = null });
    try testing.expect(!helpRowAvailable(refused.commands, "re-anchor local root Draft").?);
    try testing.expect(helpRowAvailable(anchorable.commands, "re-anchor local root Draft").?);
}

test "edit stays discoverable in the help Overlay when it is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refused = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .edit_refusal = .submission_owns_draft });
    const editable = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .edit_refusal = null });
    try testing.expect(!helpRowAvailable(refused.commands, "edit local Draft").?);
    try testing.expect(helpRowAvailable(editable.commands, "edit local Draft").?);
}

fn helpRowAvailable(rows: []const HelpRow, help: []const u8) ?bool {
    for (rows) |row| if (std.mem.indexOf(u8, row.text, help) != null) return row.available;
    return null;
}
