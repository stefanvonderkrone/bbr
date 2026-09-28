//! Renderer — projects a `Buffer` onto vaxis Panes: a file Sidebar on the left
//! and the unified DiffPane on the right. Pure drawing; it mutates no state and
//! reads `Nav` for scroll/cursor. Diff lines get full-width neutral/green/red
//! bands (via `Theme`) so changes read as color across the pane.
//!
//! Cell text is *borrowed* by vaxis until the frame is rendered. Line body text
//! borrows the raw diff (long-lived); the only text we synthesize per frame is
//! dynamic labels, so `draw` takes a `scratch` allocator that must outlive the
//! render/read that follows (a per-frame arena, reset after render). Gutters use
//! stack formatting but write static digit glyphs into vaxis cells.

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
const LinePair = buffer_mod.LinePair;
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
    const frame = review.frame;
    const cursor = frame.navigation.cursor;
    const buffer_index = if (cursor < frame.visual_rows.len) frame.visual_rows[cursor].buffer_index else 0;
    const path = if (frame.buffer.fileIndexForRow(buffer_index)) |index|
        frame.buffer.rows[frame.buffer.fileHeaderRow(index).?].file_header.path
    else
        "Diff";
    drawDiffPaneFrame(scratch, win, frame, path, review.preferences.scope, theme);
    const sidebar = childRect(win, review.frame.panes.sidebar_content);
    const diff_pane = childRect(win, review.frame.panes.diff_content);
    var diff_theme = theme;
    diff_theme.section_rule = if (frame.focus == .diff) theme.pane_border_focused else theme.pane_border;
    drawFileTree(sidebar, review.frame.file_tree, theme);
    drawVisualPane(scratch, diff_pane, review.frame.buffer, review.frame.visual_rows, diff_theme, review.frame.navigation);
    drawSearchRanges(diff_pane, review.frame, theme);
    joinSectionRules(win, review.frame.panes.diff, review.frame.panes.diff_content, review.frame.visual_rows, review.frame.navigation);
}

fn drawSearchRanges(win: vaxis.Window, frame: @import("frame.zig").Projection, theme: Theme) void {
    for (frame.search_ranges) |range| {
        if (range.visual_row < frame.navigation.scroll) continue;
        const screen_row = range.visual_row - frame.navigation.scroll;
        if (screen_row >= win.height or range.visual_row >= frame.visual_rows.len) continue;
        const visual = frame.visual_rows[range.visual_row];
        const row = frame.buffer.rows[visual.buffer_index];
        switch (row) {
            .line, .line_pair => {
                const text = searchSourceText(row, visual, range.relation) orelse continue;
                const row_start = if (visual.halves) |halves| switch (range.relation) {
                    .old => if (halves.left) |half| half.source_start else continue,
                    .new => if (halves.right) |half| half.source_start else continue,
                    .neutral => visual.source_start,
                } else visual.source_start;
                if (range.source.start < row_start or range.source.end > text.len) continue;
                const base: usize = if (visual.halves != null) switch (range.relation) {
                    .old => side_gutter,
                    .new => win.width / 2 + 1 + side_gutter,
                    .neutral => gutter_cols,
                } else gutter_cols;
                const start = base + vaxis.gwidth.gwidth(text[row_start..range.source.start], .unicode);
                const width = vaxis.gwidth.gwidth(text[range.source.start..range.source.end], .unicode);
                paintSearchCells(win, @intCast(screen_row), start, width, range.active, theme);
            },
            .comment => |card| drawReviewCardSearchRange(win, @intCast(screen_row), card, range, theme),
            .draft => |card| drawReviewCardSearchRange(win, @intCast(screen_row), card, range, theme),
            else => {},
        }
    }
}

fn searchSourceText(row: Row, visual: @import("frame.zig").VisualRow, relation: @import("search.zig").VersionRelation) ?[]const u8 {
    if (visual.halves) |halves| return switch (relation) {
        .old => if (halves.left) |half| half.line.text else null,
        .new => if (halves.right) |half| half.line.text else null,
        .neutral => null,
    };
    return switch (row) {
        .line => |line| line.line.text,
        else => null,
    };
}

fn drawReviewCardSearchRange(win: vaxis.Window, row: u16, card: buffer_mod.ReviewCardRow, range: @import("frame.zig").ProjectedSourceRange, theme: Theme) void {
    var col: usize = (if (card.isReply()) @as(usize, 6) else 2) + (if (card.part == .header) @as(usize, 0) else 2);
    for (card.segments) |segment| {
        const start = @max(range.source.start, segment.source.start);
        const end = @min(range.source.end, segment.source.end);
        if (start < end) {
            const local_start = start - segment.source.start;
            const local_end = end - segment.source.start;
            if (local_end <= segment.text.len) {
                const cell_start = col + vaxis.gwidth.gwidth(segment.text[0..local_start], .unicode);
                const width = vaxis.gwidth.gwidth(segment.text[local_start..local_end], .unicode);
                paintSearchCells(win, row, cell_start, width, range.active, theme);
            }
        }
        col += vaxis.gwidth.gwidth(segment.text, .unicode);
    }
}

fn paintSearchCells(win: vaxis.Window, row: u16, start: usize, width: usize, active: bool, theme: Theme) void {
    if (start >= win.width) return;
    const end = start + @min(width, win.width - start);
    for (start..end) |column| {
        const cell = win.readCell(@intCast(column), row) orelse continue;
        var style = cell.style;
        style.bg = if (active) theme.search_active else theme.search_match;
        win.writeCell(@intCast(column), row, .{ .char = cell.char, .style = style });
    }
}

fn drawDiffPaneFrame(scratch: std.mem.Allocator, win: vaxis.Window, frame: @import("frame.zig").Projection, path: []const u8, scope: presentation.Scope, theme: Theme) void {
    const focused = frame.focus == .diff;
    drawPaneFrame(win, frame.panes.diff, "", theme, focused);
    const title_x = frame.panes.diff.x +| @min(frame.panes.diff.width, 2);
    const control_x = if (frame.version_title_targets.old) |old| old.x else if (frame.version_title_targets.new) |new| new.x else frame.panes.diff.x +| frame.panes.diff.width -| 2;
    const title_width = control_x -| title_x -| 1;
    if (title_width > 0) {
        const title = std.fmt.allocPrint(scratch, "{s} · {s}", .{ path, scopeLabel(scope) }) catch path;
        const style = if (focused) theme.pane_border_focused else theme.pane_border;
        _ = childRect(win, .{ .x = title_x, .y = frame.panes.diff.y, .width = title_width, .height = 1 }).printSegment(.{ .text = title, .style = style }, .{ .wrap = .none });
    }
    drawVersionTitleSegment(win, frame.version_title_targets.old, "g< OLD", frame.selected_version == .old, theme, focused);
    drawVersionTitleSegment(win, frame.version_title_targets.new, "NEW g>", frame.selected_version == .new, theme, focused);
}

fn scopeLabel(scope: presentation.Scope) []const u8 {
    return switch (scope) {
        .changes => "Changes",
        .fetched => "Fetched",
        .whole => "WholeFile",
    };
}

fn drawVersionTitleSegment(win: vaxis.Window, target: ?@import("frame.zig").Rect, text: []const u8, selected: bool, theme: Theme, focused: bool) void {
    const rect = target orelse return;
    var style = if (focused) theme.pane_border_focused else theme.pane_border;
    if (selected) {
        style.fg = theme.accent;
        style.bold = true;
    }
    _ = childRect(win, rect).printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
}

fn joinSectionRules(win: vaxis.Window, outer: @import("frame.zig").Rect, content: @import("frame.zig").Rect, visual_rows: []const @import("frame.zig").VisualRow, nav: Nav) void {
    if (outer.width == 0) return;
    var screen_row: u16 = 0;
    while (screen_row < content.height) : (screen_row += 1) {
        const index = nav.scroll + screen_row;
        if (index >= visual_rows.len) break;
        const joined = switch (visual_rows[index].kind) {
            .file_header, .section => true,
            else => false,
        };
        if (!joined) continue;
        const row = content.y + screen_row;
        if (win.readCell(outer.x, row)) |cell| win.writeCell(outer.x, row, .{ .char = .{ .grapheme = "├", .width = 1 }, .style = cell.style });
        if (outer.width > 1) {
            const right = outer.x + outer.width - 1;
            if (win.readCell(right, row)) |cell| win.writeCell(right, row, .{ .char = .{ .grapheme = "┤", .width = 1 }, .style = cell.style });
        }
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
    drawProjectedRows(scratch, win, buf.rows, buf.layout, buf.selected_column, theme, nav);
}

fn drawVisualPane(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    buf: Buffer,
    visual_rows: []const @import("frame.zig").VisualRow,
    theme: Theme,
    nav: Nav,
) void {
    const sel = nav.selection();
    var screen_row: u16 = 0;
    while (screen_row < win.height) : (screen_row += 1) {
        const index = nav.scroll + screen_row;
        if (index >= visual_rows.len) break;
        const visual_row = visual_rows[index];
        const row = buf.rows[visual_row.buffer_index];
        const selected = if (sel) |selection|
            visual_row.kind != .status_placeholder and visualRowSelected(visual_rows, selection, index)
        else
            false;
        const row_theme = if (selected or index == nav.cursor) cursorRowTheme(theme) else theme;
        drawVisualRow(scratch, win, screen_row, buf.layout, buf.selected_column, row, visual_row, row_theme);
    }
}

fn drawProjectedRows(scratch: std.mem.Allocator, win: vaxis.Window, rows: []const Row, layout: buffer_mod.Layout, selected_column: ?buffer_mod.SelectedColumn, theme: Theme, nav: Nav) void {
    const sel = nav.selection();
    var screen_row: u16 = 0;
    while (screen_row < win.height) : (screen_row += 1) {
        const index = nav.scroll + screen_row;
        if (index >= rows.len) break;
        const row = rows[index];
        const selected = if (sel) |selection|
            row != .status_placeholder and index >= selection[0] and index <= selection[1]
        else
            false;
        const row_theme = if (selected or index == nav.cursor) cursorRowTheme(theme) else theme;
        drawRow(scratch, win, screen_row, layout, selected_column, row, row_theme);
    }
}

fn visualRowSelected(rows: []const @import("frame.zig").VisualRow, selection: [2]usize, index: usize) bool {
    if (index >= rows.len) return false;
    const candidate = rows[index];
    if (candidate.owner != .line) return index >= selection[0] and index <= selection[1];
    var selected = selection[0];
    while (selected <= selection[1] and selected < rows.len) : (selected += 1) {
        if (candidate.kind == .line_pair and rows[selected].buffer_index == candidate.buffer_index) return true;
        if (rows[selected].owner.eql(candidate.owner)) return true;
    }
    return false;
}

fn drawVisualRow(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, layout: buffer_mod.Layout, selected_column: ?buffer_mod.SelectedColumn, row: Row, visual_row: @import("frame.zig").VisualRow, theme: Theme) void {
    if (layout == .side_by_side and visual_row.halves != null) {
        drawVisualLinePair(scratch, win, r, visual_row.halves.?, row.line_pair, theme);
        drawSelectedColumnEdge(win, r, selected_column, theme);
        return;
    }
    if (row != .line or layout != .unified) {
        drawRow(scratch, win, r, layout, selected_column, row, theme);
        return;
    }
    const line_row = row.line;
    const style = theme.lineStyle(line_row.line.kind);
    fillRow(win, r, style);
    if (!visual_row.continuation) {
        drawUnifiedGutter(win, r, line_row.oldNo(), line_row.newNo(), theme.gutter);
    }
    drawLineBodyText(
        scratch,
        win,
        r,
        gutter_cols,
        line_row.line,
        line_row.line.text[visual_row.source_start..visual_row.source_end],
        line_row.decoration,
        theme,
        style,
    );
}

fn cursorRowTheme(theme: Theme) Theme {
    var result = theme;
    result.context.bg = theme.cursorBg(theme.context.bg);
    result.added.bg = theme.cursorBg(theme.added.bg);
    result.removed.bg = theme.cursorBg(theme.removed.bg);
    result.added_emphasis.bg = theme.cursorBg(theme.added_emphasis.bg);
    result.removed_emphasis.bg = theme.cursorBg(theme.removed_emphasis.bg);
    result.gutter.bg = theme.cursorBg(theme.gutter.bg);
    result.file_header.bg = theme.cursorBg(theme.file_header.bg);
    result.hunk_header.bg = theme.cursorBg(theme.hunk_header.bg);
    result.fold.bg = theme.cursorBg(theme.fold.bg);
    result.comment.bg = theme.cursorBg(theme.comment.bg);
    result.comment_reply.bg = theme.cursorBg(theme.comment_reply.bg);
    result.suggestion.bg = theme.cursorBg(theme.suggestion.bg);
    result.draft.bg = theme.cursorBg(theme.draft.bg);
    result.draft_reply.bg = theme.cursorBg(theme.draft_reply.bg);
    result.outcome_unknown.bg = theme.cursorBg(theme.outcome_unknown.bg);
    result.outcome_unknown_reply.bg = theme.cursorBg(theme.outcome_unknown_reply.bg);
    result.section.bg = theme.cursorBg(theme.section.bg);
    result.section_rule.bg = theme.cursorBg(theme.section_rule.bg);
    return result;
}

/// Gutter is two 4-wide line-number columns; body text starts after it.
const gutter_cols: u16 = @intCast(@import("frame.zig").unified_gutter_cols);

fn drawRow(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, layout: buffer_mod.Layout, selected_column: ?buffer_mod.SelectedColumn, row: Row, theme: Theme) void {
    switch (row) {
        .file_header => |header| {
            if (selected_column) |selected| {
                drawSideFileHeader(scratch, win, r, header, selected, theme);
            } else {
                fillRuleRow(win, r, theme.section_rule);
                const text = std.fmt.allocPrint(scratch, "─ {s} {s} ", .{ statusChar(header.file.status), header.path }) catch header.path;
                _ = win.printSegment(.{ .text = text, .style = theme.file_header }, .{ .row_offset = r, .wrap = .none });
            }
        },
        .hunk_header => |hunk| {
            fillRow(win, r, theme.hunk_header);
            _ = win.printSegment(.{ .text = hunk.header, .style = theme.hunk_header }, .{ .row_offset = r, .wrap = .none });
        },
        .status_placeholder => |value| drawStatusPlaceholder(scratch, win, r, layout, value, theme),
        .line => |lr| {
            const ln = lr.line;
            const style = theme.lineStyle(ln.kind);
            fillRow(win, r, style);

            drawUnifiedGutter(win, r, lr.oldNo(), lr.newNo(), theme.gutter);
            drawLineBody(scratch, win, r, gutter_cols, lr, theme, style);
        },
        .line_pair => |pair| drawLinePair(scratch, win, r, pair, theme),
        .disclosure => |value| drawDisclosure(scratch, win, r, value, theme),
        .comment => |cr| drawComment(scratch, win, r, cr, theme),
        .draft => |dr| drawDraft(scratch, win, r, dr, theme),
        .snapshot => |snapshot| drawSnapshot(win, r, snapshot, theme),
        .section => |sec| drawSection(scratch, win, r, sec, theme),
    }
    if (layout == .side_by_side) drawSelectedColumnEdge(win, r, selected_column, theme);
}

fn drawSideFileHeader(scratch: std.mem.Allocator, win: vaxis.Window, row: u16, header: buffer_mod.FileHeader, selected: buffer_mod.SelectedColumn, theme: Theme) void {
    fillRuleRow(win, row, theme.section_rule);
    const half = win.width / 2;
    const right_x = half + 1;
    var old_style = theme.file_header;
    var new_style = theme.file_header;
    if (selected.version == .old) {
        old_style.fg = theme.accent;
        old_style.bold = true;
    } else {
        new_style.fg = theme.accent;
        new_style.bold = true;
    }
    const old = std.fmt.allocPrint(scratch, "OLD {s}", .{header.file.old_path}) catch "OLD";
    const new = std.fmt.allocPrint(scratch, "NEW {s}", .{header.file.new_path}) catch "NEW";
    if (half > 0) _ = win.child(.{ .x_off = 0, .y_off = row, .width = half, .height = 1 }).printSegment(.{ .text = old, .style = old_style }, .{ .wrap = .none });
    if (right_x < win.width) _ = win.child(.{ .x_off = right_x, .y_off = row, .width = win.width - right_x, .height = 1 }).printSegment(.{ .text = new, .style = new_style }, .{ .wrap = .none });
}

fn drawSelectedColumnEdge(win: vaxis.Window, row: u16, selected: ?buffer_mod.SelectedColumn, theme: Theme) void {
    const column = selected orelse return;
    const divider = win.width / 2;
    if (divider >= win.width) return;
    const current = win.readCell(divider, row) orelse return;
    win.writeCell(divider, row, .{
        .char = .{ .grapheme = if (column.inner_gutter_edge == .right) "▐" else "▌", .width = 1 },
        .style = .{ .fg = theme.accent, .bg = current.style.bg, .bold = true },
    });
}

fn drawStatusPlaceholder(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    row: u16,
    layout: buffer_mod.Layout,
    value: buffer_mod.StatusPlaceholder,
    theme: Theme,
) void {
    fillRow(win, row, theme.section);
    if (layout == .unified) {
        const text = if (value.old) |status|
            statusPlaceholderText(scratch, .old, status)
        else if (value.new) |status|
            statusPlaceholderText(scratch, .new, status)
        else
            return;
        _ = win.printSegment(.{ .text = text, .style = theme.section }, .{ .row_offset = row, .wrap = .none });
        return;
    }

    const half = win.width / 2;
    if (half == 0) return;
    if (value.old) |status| {
        const left = win.child(.{ .x_off = 0, .y_off = row, .width = half, .height = 1 });
        _ = left.printSegment(.{ .text = statusPlaceholderText(scratch, .old, status), .style = theme.section }, .{ .wrap = .none });
    } else if (value.file.status == .added) {
        const left = win.child(.{ .x_off = 0, .y_off = row, .width = half, .height = 1 });
        _ = left.printSegment(.{ .text = "Old content absent", .style = theme.section }, .{ .wrap = .none });
    }
    const right_x = half + 1;
    if (value.new) |status| {
        if (right_x < win.width) {
            const right = win.child(.{ .x_off = right_x, .y_off = row, .width = win.width - right_x, .height = 1 });
            _ = right.printSegment(.{ .text = statusPlaceholderText(scratch, .new, status), .style = theme.section }, .{ .wrap = .none });
        }
    } else if (value.file.status == .removed and right_x < win.width) {
        const right = win.child(.{ .x_off = right_x, .y_off = row, .width = win.width - right_x, .height = 1 });
        _ = right.printSegment(.{ .text = "New content absent", .style = theme.section }, .{ .wrap = .none });
    }
}

fn statusPlaceholderText(scratch: std.mem.Allocator, side: Side, state: buffer_mod.VersionContentState) []const u8 {
    const side_name = if (side == .old) "Old" else "New";
    return switch (state) {
        .loading => |bytes| statusPlaceholderDetail(scratch, side_name, "loading", bytes),
        .absent => std.fmt.allocPrint(scratch, "{s} content absent", .{side_name}) catch "Content absent",
        .empty => std.fmt.allocPrint(scratch, "{s} Empty file", .{side_name}) catch "Empty file",
        .binary => |bytes| statusPlaceholderDetail(scratch, side_name, "binary", bytes),
        .unavailable => |status| switch (status.unavailable.reason) {
            .invalid_utf8 => statusPlaceholderDetail(scratch, side_name, "unavailable: invalid UTF-8", status.byteSize()),
            .invalid_path => statusPlaceholderDetail(scratch, side_name, "unavailable: invalid path", status.byteSize()),
            .acquisition_failed => |err| blk: {
                const reason = std.fmt.allocPrint(scratch, "unavailable: acquisition failed ({s})", .{@errorName(err)}) catch "unavailable: acquisition failed";
                break :blk statusPlaceholderDetail(scratch, side_name, reason, status.byteSize());
            },
        },
    };
}

fn statusPlaceholderDetail(scratch: std.mem.Allocator, side: []const u8, state: []const u8, bytes: ?usize) []const u8 {
    if (bytes) |size| return std.fmt.allocPrint(scratch, "{s} content {s}, {d} bytes", .{ side, state, size }) catch "Content unavailable";
    return std.fmt.allocPrint(scratch, "{s} content {s}, size unavailable", .{ side, state }) catch "Content unavailable";
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
const side_gutter: u16 = @intCast(@import("frame.zig").side_gutter_cols);

/// Draw one side-by-side row: the old line in the left half, the new line in the
/// right half, split by a one-column divider. Each half is a 1-row child window
/// so a long line is clipped at the divider instead of bleeding into the other
/// pane. An absent side is drawn as a neutral empty half.
fn drawLinePair(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, pair: buffer_mod.LinePair, theme: Theme) void {
    const half = win.width / 2;
    if (half == 0) return;
    const right_x = half + 1; // divider column sits at `half`
    const right_w = if (win.width > right_x) win.width - right_x else 0;
    fillRow(win, r, theme.context);

    const left = win.child(.{ .x_off = 0, .y_off = r, .width = half, .height = 1 });
    drawHalf(scratch, left, pair.left, theme, .old);
    if (right_w > 0) {
        const right = win.child(.{ .x_off = right_x, .y_off = r, .width = right_w, .height = 1 });
        drawHalf(scratch, right, pair.right, theme, .new);
    }
}

fn drawVisualLinePair(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, halves: @import("frame.zig").Halves, pair: LinePair, theme: Theme) void {
    const half = win.width / 2;
    if (half == 0) return;
    const right_x = half + @as(u16, @intCast(@import("frame.zig").side_divider_cols));
    const right_w = if (win.width > right_x) win.width - right_x else 0;
    fillRow(win, r, theme.context);
    drawVisualHalf(scratch, win.child(.{ .x_off = 0, .y_off = r, .width = half, .height = 1 }), halves.left, pair.left, theme, .old);
    if (right_w > 0) drawVisualHalf(scratch, win.child(.{ .x_off = right_x, .y_off = r, .width = right_w, .height = 1 }), halves.right, pair.right, theme, .new);
}

fn drawVisualHalf(scratch: std.mem.Allocator, win: vaxis.Window, half: ?@import("frame.zig").VisualHalf, line_row: ?LineRow, theme: Theme, side: Side) void {
    const value = half orelse {
        fillRow(win, 0, theme.context);
        return;
    };
    const decoration = line_row.?.decoration;
    const style = theme.lineStyle(value.line.kind);
    fillRow(win, 0, style);
    if (!value.continuation) {
        const no = if (side == .old) value.line.oldNo() else value.line.newNo();
        drawSideGutter(win, 0, no, theme.gutter);
    }
    drawLineBodyText(
        scratch,
        win,
        0,
        side_gutter,
        value.line,
        value.line.text[value.source_start..value.source_end],
        decoration,
        theme,
        style,
    );
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
        .old => lr.line.oldNo(),
        .new => lr.line.newNo(),
    };
    drawSideGutter(win, 0, no, theme.gutter);
    drawLineBody(scratch, win, 0, side_gutter, lr, theme, style);
}

/// Draw a diff line's body after the gutter. Without intra-line emphasis the
/// whole line prints in its band `style`; with emphasis, the line is drawn as a
/// run of styled segments so only the changed runs get the brighter band.
fn drawLineBody(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, body_col: u16, lr: LineRow, theme: Theme, style: vaxis.Style) void {
    drawLineBodyText(scratch, win, r, body_col, lr.line, lr.line.text, lr.decoration, theme, style);
}

fn drawLineBodyText(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, body_col: u16, line: *const bbr.diff.Line, text: []const u8, decoration: bbr.highlight.LineDecoration, theme: Theme, style: vaxis.Style) void {
    const emph = theme.emphasisStyle(line.kind);
    const source_start = @intFromPtr(text.ptr) - @intFromPtr(line.text.ptr);
    const source_end = source_start + text.len;
    var count: usize = 0;
    var offset: usize = 0;
    for (decoration.runs) |run| {
        const run_end = offset + run.text.len;
        if (offset < source_end and run_end > source_start) count += 1;
        offset = run_end;
    }
    const segs = scratch.alloc(vaxis.Segment, count) catch {
        _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = r, .col_offset = body_col, .wrap = .none });
        return;
    };
    offset = 0;
    var index: usize = 0;
    for (decoration.runs) |run| {
        const run_end = offset + run.text.len;
        const overlap_start = @max(offset, source_start);
        const overlap_end = @min(run_end, source_end);
        if (overlap_start >= overlap_end) {
            offset = run_end;
            continue;
        }
        var run_style = if (run.emphasis) emph else style;
        if (run.capture) |capture| {
            if (theme.captureColor(capture)) |fg| run_style.fg = fg;
        }
        segs[index] = .{ .text = run.text[overlap_start - offset .. overlap_end - offset], .style = run_style };
        index += 1;
        offset = run_end;
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
        .opposite_version => std.fmt.allocPrint(scratch, "{s} {s} · {d} threads", .{ glyph, value.path, value.count }) catch glyph,
        .review_card => unreachable,
    };
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = r, .col_offset = gutter_cols, .wrap = .none });
}

/// A section divider: "── PR comments (N)" or "── Outdated · path (N)".
fn drawSection(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, sec: Section, theme: Theme) void {
    fillRuleRow(win, r, theme.section_rule);
    const text = switch (sec.kind) {
        .pr_comments => std.fmt.allocPrint(scratch, "── PR comments ({d}) ", .{sec.count}) catch "── PR comments ",
        .pending => std.fmt.allocPrint(scratch, "── Pending ({d}) ", .{sec.count}) catch "── Pending ",
        .outdated => if (sec.path.len > 0)
            std.fmt.allocPrint(scratch, "── Outdated · {s} ({d}) ", .{ sec.path, sec.count }) catch "── Outdated "
        else
            std.fmt.allocPrint(scratch, "── Outdated ({d}) ", .{sec.count}) catch "── Outdated ",
        .unavailable => std.fmt.allocPrint(scratch, "── Anchor unavailable ({d}) ", .{sec.count}) catch "── Anchor unavailable ",
    };
    const style = if (sec.kind == .pr_comments) theme.file_header else theme.section;
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = r, .wrap = .none });
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

/// Draw only the immutable Review Search projection. The same rectangles give
/// Presentation its list and Preview pointer targets.
pub fn drawReviewSearch(scratch: std.mem.Allocator, win: vaxis.Window, projection: presentation.ReviewSearchProjection, theme: Theme) void {
    const geometry = projection.geometry;
    const modal = childRect(win, geometry.rect);
    modal.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = theme.picker });
    const search_box = childRect(win, .{ .x = geometry.rect.x, .y = geometry.rect.y, .width = geometry.rect.width, .height = @min(geometry.rect.height, 3) });
    drawSearchBorder(search_box, theme);
    searchBorderTitle(search_box, 0, search_box.width, "Review Search", theme);
    if (search_box.height > 1 and search_box.width > 2) {
        const input = search_box.child(.{ .x_off = 1, .y_off = 1, .width = search_box.width - 2, .height = 1 });
        const query = std.fmt.allocPrint(scratch, "> {s}", .{projection.query}) catch "> ";
        _ = input.printSegment(.{ .text = query, .style = theme.picker }, .{ .wrap = .none });
    }
    if (search_box.height > 2) {
        const status = std.fmt.allocPrint(scratch, "{d}/{d} matches · {d} candidates{s}", .{
            if (projection.selected) |index| index + 1 else @as(usize, 0), projection.results.len, projection.candidate_count,
            if (projection.pending) " · searching" else "",
        }) catch "";
        const short_status = std.fmt.allocPrint(scratch, "{d} matches · {d} candidates", .{ projection.results.len, projection.candidate_count }) catch "";
        const tiny_status = std.fmt.allocPrint(scratch, "{d}/{d}", .{ projection.results.len, projection.candidate_count }) catch "";
        const label = if (searchCellWidth(status) + 4 <= search_box.width) status else if (searchCellWidth(short_status) + 4 <= search_box.width) short_status else if (searchCellWidth(tiny_status) + 4 <= search_box.width) tiny_status else "";
        if (label.len > 0) _ = search_box.printSegment(.{ .text = label, .style = theme.overlay_border }, .{ .row_offset = 2, .col_offset = search_box.width - @as(u16, @intCast(searchCellWidth(label))) - 2, .wrap = .none });
    }
    const body = childRect(win, geometry.body);
    drawSearchBorder(body, theme);
    if (geometry.landscape) {
        const split = geometry.divider - geometry.body.x;
        searchBorderTitle(body, 0, split, if (split > searchCellWidth("Results · Position") + 2) "Results · Position" else "Position", theme);
        searchBorderTitle(body, split, body.width - split, "Preview", theme);
        for (0..body.height) |row| body.writeCell(split, @intCast(row), .{
            .char = .{ .grapheme = if (row == 0) "┬" else if (row == body.height - 1) "┴" else "│", .width = 1 },
            .style = theme.overlay_border,
        });
    } else {
        searchBorderTitle(body, 0, body.width, if (body.width > searchCellWidth("Results · Position") + 2) "Results · Position" else "Position", theme);
        if (body.height > 0) {
            const split = geometry.divider - geometry.body.y;
            for (0..body.width) |col| body.writeCell(@intCast(col), split, .{
                .char = .{ .grapheme = if (col == 0) "├" else if (col == body.width - 1) "┤" else "─", .width = 1 },
                .style = theme.overlay_border,
            });
            const preview_line = body.child(.{ .y_off = split, .height = 1 });
            searchBorderTitle(preview_line, 0, body.width, "Preview", theme);
        }
    }
    const list = childRect(win, geometry.list);
    const list_total = if (projection.results.len > 0) projection.results.len else projection.files.len;
    const has_scrollbar = list.width > 1 and list.height > 0 and list_total > list.height;
    const list_text = if (has_scrollbar) list.child(.{ .width = list.width - 1 }) else list;
    const preview = childRect(win, geometry.preview);
    const header = childRect(win, geometry.header);
    if (geometry.header.height > 0) {
        const separator = childRect(win, .{ .x = geometry.header.x -| 1, .y = geometry.header.y +| 1, .width = geometry.header.width +| 2, .height = 1 });
        for (0..separator.width) |col| separator.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = if (col == 0) "├" else if (col == separator.width - 1) "┤" else "─", .width = 1 },
            .style = theme.overlay_border,
        });
    }
    if (projection.results.len == 0 and list.height > 0) {
        for (0..list.height) |row| {
            const index = projection.list_scroll + row;
            if (index >= projection.files.len or index >= projection.content_statuses.len or index >= projection.highlight_statuses.len) break;
            const file = projection.files[index];
            const content = projection.content_statuses[index];
            const status = projection.highlight_statuses[index];
            const label = std.fmt.allocPrint(scratch, "{s}  old {s} · new {s}", .{
                shortSearchPath(scratch, file.displayPath(), @max(list_text.width / 2, 1)),
                sourceContentLabel(scratch, content.old, status.old),
                sourceContentLabel(scratch, content.new, status.new),
            }) catch file.displayPath();
            _ = list_text.printSegment(.{ .text = label, .style = theme.picker }, .{ .row_offset = @intCast(row), .wrap = .none });
        }
        if (projection.files.len == 0)
            _ = list_text.printSegment(.{ .text = if (projection.pending) "Searching ReviewBodies…" else "No matching occurrence", .style = theme.picker }, .{ .wrap = .none });
    }
    for (0..list.height) |row_index| {
        const index = projection.list_scroll + row_index;
        if (index >= projection.results.len) break;
        const result = projection.results[index];
        const selected = projection.selected == index;
        const style = if (selected) theme.picker_selected else theme.picker;
        fillRow(list_text, @intCast(row_index), style);
        const position = switch (result.occurrence.location) {
            .review_body => |owner| std.fmt.allocPrint(scratch, " L{d}:C{d}", .{ owner.logical_line, result.occurrence.column }) catch "",
            .source => |source| std.fmt.allocPrint(scratch, " {s} L{d}:C{d}", .{ @tagName(source.relation), source.new_line orelse source.old_line orelse 0, result.occurrence.column }) catch "",
        };
        const path = switch (result.occurrence.location) {
            .source => |source| if (source.relation == .old) source.old_path else source.new_path,
            .review_body => switch (result.scope) {
                .review => "Review",
                .file => |file| file.path,
                .@"inline" => |anchor| std.fmt.allocPrint(scratch, "{s}:{d}", .{ anchor.path, anchor.line() orelse 0 }) catch anchor.path,
            },
        };
        const available = list_text.width -| 2;
        const filename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        const show_position = available > position.len + 2 and searchCellWidth(filename) <= available - position.len;
        const location = shortSearchPath(scratch, path, available -| (if (show_position) position.len else @as(usize, 0)));
        const suffix = if (show_position) position else "";
        const row_text = std.fmt.allocPrint(scratch, "{s}{s}{s}", .{ if (selected) "▸ " else "  ", location, suffix }) catch location;
        _ = list_text.printSegment(.{ .text = row_text, .style = style }, .{ .row_offset = @intCast(row_index), .wrap = .none });
    }
    if (has_scrollbar) drawReviewSearchScrollbar(list, list_total, projection.list_scroll, theme);
    const selected = projection.selected orelse {
        if (projection.status_preview) |view| {
            if (projection.list_scroll < projection.files.len) {
                const path = projection.files[projection.list_scroll].displayPath();
                if (header.height > 0) _ = header.printSegment(.{ .text = path, .style = theme.picker }, .{ .wrap = .none });
                const old = std.fmt.allocPrint(scratch, "old: {s}", .{sourceSideState(scratch, view.old)}) catch "old";
                const new = std.fmt.allocPrint(scratch, "new: {s}", .{sourceSideState(scratch, view.new)}) catch "new";
                if (preview.height > 0) _ = preview.printSegment(.{ .text = old, .style = theme.picker }, .{ .wrap = .none });
                if (preview.height > 1) _ = preview.printSegment(.{ .text = new, .style = theme.picker }, .{ .row_offset = 1, .wrap = .none });
            }
        } else if (preview.height > 0) _ = preview.printSegment(.{ .text = "No preview", .style = theme.picker }, .{ .wrap = .none });
        return;
    };
    if (selected >= projection.results.len) return;
    if (projection.results[selected].occurrence.location == .source) {
        drawReviewSourcePreview(scratch, header, preview, projection.results[selected], projection.source_preview, projection.preview_scroll, projection.preview_horizontal, theme);
    } else {
        drawReviewSearchHeader(scratch, header, projection.results[selected], theme);
        if (preview.height > 0) drawReviewSearchPreview(scratch, preview, projection.results[selected], projection.preview_scroll, theme);
    }
}

fn drawReviewSearchScrollbar(list: vaxis.Window, total: usize, scroll: usize, theme: Theme) void {
    const height: usize = list.height;
    const thumb = @max(1, (height * height + total - 1) / total);
    const max_scroll = total - height;
    const first = @min(scroll, max_scroll) * (height - thumb) / max_scroll;
    for (first..first + thumb) |row| list.writeCell(list.width - 1, @intCast(row), .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = theme.picker,
    });
}

fn sourceContentLabel(scratch: std.mem.Allocator, content: ?@import("bbr").diff.FileContentStatus, state: @import("bbr").highlight.SideState) []const u8 {
    const value = content orelse return "absent";
    return switch (value) {
        .text => |size| if (size) |bytes| std.fmt.allocPrint(scratch, "text ({d} bytes)", .{bytes}) catch "text" else if (state == .pending or state == .loading) "loading" else "unavailable",
        .binary => |size| if (size) |bytes| std.fmt.allocPrint(scratch, "binary ({d} bytes)", .{bytes}) catch "binary" else "binary",
        .unavailable => |unavailable| switch (unavailable.reason) {
            .invalid_utf8 => if (unavailable.byte_size) |bytes| std.fmt.allocPrint(scratch, "invalid UTF-8 ({d} bytes)", .{bytes}) catch "invalid UTF-8" else "invalid UTF-8",
            .acquisition_failed => "acquisition failure",
            .invalid_path => "unavailable",
        },
    };
}

fn drawReviewSourcePreview(scratch: std.mem.Allocator, header: vaxis.Window, preview: vaxis.Window, result: presentation.ReviewSearchResult, file_view: ?@import("file_enrichment.zig").FileView, scroll: usize, horizontal: usize, theme: Theme) void {
    const source = result.occurrence.location.source;
    const path = if (source.relation == .old) source.old_path else source.new_path;
    const version = if (source.relation == .old) "old" else if (source.relation == .new) "new" else "old + new";
    if (header.height > 0) {
        fillRow(header, 0, theme.picker);
        const old_state = if (file_view) |view| sourceSideState(scratch, view.old) else "loading";
        const new_state = if (file_view) |view| sourceSideState(scratch, view.new) else "loading";
        const label = std.fmt.allocPrint(scratch, "{s} · {s} · L{d}:C{d} · old {s} · new {s}", .{ path, version, source.new_line orelse source.old_line orelse 0, result.occurrence.column, old_state, new_state }) catch path;
        _ = header.printSegment(.{ .text = label, .style = theme.picker }, .{ .wrap = .none });
    }
    if (preview.height == 0) return;
    const view = file_view orelse {
        _ = preview.printSegment(.{ .text = "Reacquiring File content…", .style = theme.picker }, .{ .wrap = .none });
        return;
    };
    const side = if (source.relation == .old) view.old else view.new;
    if (side != .content) {
        _ = preview.printSegment(.{ .text = "Reacquiring File content…", .style = theme.picker }, .{ .wrap = .none });
        return;
    }
    const text = side.content.blob;
    const matched_line = source.new_line orelse source.old_line orelse 0;
    const spans = if (side.content.highlighting == .ready) side.content.highlighting.ready.spans else &.{};
    var span_cursor: usize = 0;
    var start: usize = 0;
    var line_number: usize = 1;
    var row: u16 = 0;
    while (start < text.len and row < preview.height) : (line_number += 1) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (line_number > scroll) {
            const line = text[start..(if (end > start and text[end - 1] == '\r') end - 1 else end)];
            var offset: usize = 0;
            var skipped: usize = 0;
            while (offset < line.len and skipped < horizontal) {
                const scalar_length = std.unicode.utf8ByteSequenceLength(line[offset]) catch 1;
                offset += @min(scalar_length, line.len - offset);
                skipped += 1;
            }
            const style = if (line_number == matched_line) theme.picker_selected else theme.picker;
            while (span_cursor < spans.len and spans[span_cursor].line < line_number) span_cursor += 1;
            const first_span = span_cursor;
            while (span_cursor < spans.len and spans[span_cursor].line == line_number) span_cursor += 1;
            const decorated = bbr.highlight.decoration.decorate(scratch, line, spans[first_span..span_cursor], &.{}) catch
                bbr.highlight.LineDecoration{ .runs = &.{.{ .text = line }} };
            var segments: std.ArrayList(vaxis.Segment) = .empty;
            var run_start: usize = 0;
            for (decorated.runs) |run| {
                const run_end = run_start + run.text.len;
                var cursor = @max(run_start, offset);
                if (cursor >= run_end) {
                    run_start = run_end;
                    continue;
                }
                var syntax_style = style;
                if (run.capture) |capture| if (theme.captureColor(capture)) |fg| {
                    syntax_style.fg = fg;
                };
                while (cursor < run_end) {
                    var segment_end = run_end;
                    var matched = false;
                    if (line_number == matched_line) for (result.occurrence.ranges) |range| {
                        if (range.end <= cursor) continue;
                        if (range.start <= cursor) {
                            matched = true;
                            segment_end = @min(segment_end, range.end);
                        } else segment_end = @min(segment_end, range.start);
                        break;
                    };
                    var segment_style = syntax_style;
                    if (matched) {
                        segment_style.bg = theme.search_active;
                        segment_style.bold = true;
                    }
                    segments.append(scratch, .{ .text = line[cursor..segment_end], .style = segment_style }) catch return;
                    cursor = segment_end;
                }
                run_start = run_end;
            }
            if (segments.items.len == 0) segments.append(scratch, .{ .text = "", .style = style }) catch return;
            _ = preview.print(segments.items, .{ .row_offset = row, .wrap = .none });
            row += 1;
        }
        start = end + @intFromBool(end < text.len);
    }
}

fn sourceSideState(scratch: std.mem.Allocator, side: @import("file_enrichment.zig").SideView) []const u8 {
    return switch (side) {
        .pending => "loading",
        .absent => "absent",
        .binary => |size| if (size) |bytes| std.fmt.allocPrint(scratch, "binary ({d} bytes)", .{bytes}) catch "binary" else "binary",
        .unavailable => |status| switch (status) {
            .unavailable => |unavailable| switch (unavailable.reason) {
                .invalid_utf8 => if (unavailable.byte_size) |bytes| std.fmt.allocPrint(scratch, "invalid UTF-8 ({d} bytes)", .{bytes}) catch "invalid UTF-8" else "invalid UTF-8",
                .acquisition_failed => "acquisition failure",
                .invalid_path => "unavailable",
            },
            else => "unavailable",
        },
        .fetch_failed => "acquisition failure",
        .content => "text",
    };
}

fn drawSearchBorder(win: vaxis.Window, theme: Theme) void {
    if (win.width == 0 or win.height == 0) return;
    const last_col = win.width - 1;
    const last_row = win.height - 1;
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = if (col == 0) "┌" else if (col == last_col) "┐" else "─", .width = 1 }, .style = theme.overlay_border });
        if (last_row > 0) win.writeCell(@intCast(col), last_row, .{ .char = .{ .grapheme = if (col == 0) "└" else if (col == last_col) "┘" else "─", .width = 1 }, .style = theme.overlay_border });
    }
    if (last_row > 1) {
        for (1..last_row) |row| {
            win.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = theme.overlay_border });
            if (last_col > 0) win.writeCell(last_col, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = theme.overlay_border });
        }
    }
}

fn searchBorderTitle(win: vaxis.Window, start: u16, width: u16, title: []const u8, theme: Theme) void {
    const title_width = searchCellWidth(title);
    if (win.height == 0 or width <= title_width + 2) return;
    _ = win.printSegment(.{ .text = title, .style = theme.overlay_border }, .{ .col_offset = start + (width - @as(u16, @intCast(title_width))) / 2, .wrap = .none });
}

fn searchCellWidth(text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}

fn shortSearchPath(scratch: std.mem.Allocator, path: []const u8, width: usize) []const u8 {
    if (searchCellWidth(path) <= width) return path;
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const filename = if (last_slash) |slash| path[slash + 1 ..] else path;
    if (last_slash != null) {
        var compact: std.ArrayList(u8) = .empty;
        var dirs = std.mem.splitScalar(u8, path[0..last_slash.?], '/');
        while (dirs.next()) |dir| {
            if (dir.len > 0) {
                const length = std.unicode.utf8ByteSequenceLength(dir[0]) catch 1;
                compact.appendSlice(scratch, dir[0..@min(dir.len, length)]) catch return filename;
            }
            compact.append(scratch, '/') catch return filename;
        }
        compact.appendSlice(scratch, filename) catch return filename;
        if (searchCellWidth(compact.items) <= width) return compact.items;
        var remaining: []const u8 = compact.items;
        while (std.mem.indexOfScalar(u8, remaining, '/')) |slash| {
            remaining = remaining[slash + 1 ..];
            if (searchCellWidth(remaining) + 2 <= width) return std.fmt.allocPrint(scratch, "…/{s}", .{remaining}) catch remaining;
        }
    }
    if (searchCellWidth(filename) <= width) return filename;
    if (width == 0) return "";
    if (width == 1) return "…";
    var start: usize = 0;
    while (start < filename.len and searchCellWidth(filename[start..]) + 1 > width) {
        start += @min(filename.len - start, std.unicode.utf8ByteSequenceLength(filename[start]) catch 1);
    }
    return std.fmt.allocPrint(scratch, "…{s}", .{filename[start..]}) catch filename[start..];
}

fn drawReviewSearchHeader(scratch: std.mem.Allocator, win: vaxis.Window, result: presentation.ReviewSearchResult, theme: Theme) void {
    if (win.height == 0) return;
    const owner = result.occurrence.location.review_body;
    const id = switch (owner.owner) {
        .comment => |value| value,
        .draft => |value| value,
    };
    const prefix = std.fmt.allocPrint(scratch, "{s} · {s} #{d} · ", .{ result.kind, result.source, id }) catch "";
    const scope = switch (result.scope) {
        .review => "Review",
        .file => |file| std.fmt.allocPrint(scratch, "File {s}", .{shortSearchPath(scratch, file.path, win.width -| searchCellWidth(prefix) -| 5)}) catch "File",
        .@"inline" => |anchor| std.fmt.allocPrint(scratch, "Inline {s}", .{shortSearchPath(scratch, anchor.path, win.width -| searchCellWidth(prefix) -| 7)}) catch "Inline",
    };
    const label = std.fmt.allocPrint(scratch, "{s}{s} · L{d}:C{d}", .{ prefix, scope, owner.logical_line, result.occurrence.column }) catch prefix;
    fillRow(win, 0, theme.picker);
    _ = win.printSegment(.{ .text = label, .style = theme.picker }, .{ .wrap = .none });
}

fn drawReviewSearchPreview(scratch: std.mem.Allocator, win: vaxis.Window, result: presentation.ReviewSearchResult, scroll: usize, theme: Theme) void {
    const owner = result.occurrence.location.review_body;
    var start: usize = 0;
    var logical_line: usize = 0;
    var row: u16 = 0;
    while (start <= result.body.len and row < win.height) {
        const newline = std.mem.indexOfScalarPos(u8, result.body, start, '\n') orelse result.body.len;
        logical_line += 1;
        if (logical_line > scroll) {
            const line = result.body[start..newline];
            const line_style = if (logical_line == owner.logical_line) theme.picker_selected else theme.picker;
            const segments = scratch.alloc(vaxis.Segment, result.occurrence.ranges.len * 2 + 1) catch return;
            var count: usize = 0;
            var cursor = start;
            for (result.occurrence.ranges) |range| {
                const first = @max(range.start, start);
                const last = @min(range.end, newline);
                if (first >= last) continue;
                if (cursor < first) {
                    segments[count] = .{ .text = result.body[cursor..first], .style = line_style };
                    count += 1;
                }
                var match_style = line_style;
                match_style.bg = theme.search_active;
                match_style.bold = true;
                segments[count] = .{ .text = result.body[first..last], .style = match_style };
                count += 1;
                cursor = last;
            }
            if (cursor < newline) {
                segments[count] = .{ .text = result.body[cursor..newline], .style = line_style };
                count += 1;
            }
            if (count == 0) {
                segments[0] = .{ .text = line, .style = line_style };
                count = 1;
            }
            const position = win.print(segments[0..count], .{ .row_offset = row, .wrap = .grapheme });
            row = @max(row +| 1, position.row +| @intFromBool(position.col > 0));
        }
        if (newline == result.body.len) break;
        start = newline + 1;
    }
}

/// Draw the Composer as a centered modal: a header naming what's being authored,
/// the body typed so far (scrolled to the tail with a cursor block), and a hint
/// line. Borrowed text (the label, the body) outlives render via the composer's
/// own arena. `scratch` outlives render for the synthesized header/hint.
pub fn drawComposerProjection(scratch: std.mem.Allocator, win: vaxis.Window, composer: presentation.ComposerProjection, theme: Theme) void {
    drawComposerText(scratch, win, composer.label, composer.body, composer.footer, composer.pending_external_edit, theme);
}

fn drawComposerText(scratch: std.mem.Allocator, win: vaxis.Window, label: []const u8, body: []const u8, footer: ?[]const u8, pending: bool, theme: Theme) void {
    const modal = centeredModal(win, 72, 14) orelse return;
    const h = modal.height;

    // Header (row 0) and hint (last row).
    fillRow(modal, 0, theme.picker_query);
    const header = std.fmt.allocPrint(scratch, "✎ {s}", .{label}) catch "✎ compose";
    _ = modal.printSegment(.{ .text = header, .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });

    const hint_row = h - 1;
    fillRow(modal, hint_row, theme.picker_query);
    _ = modal.printSegment(
        .{ .text = footer orelse if (pending) "External Edit in progress…" else "^D submit · ^E external · ^W del word · ^U del line · esc cancel", .style = theme.picker_query },
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

/// Draw one dependency-tree Overlay for both live progress and terminal
/// inspection. Every state and consequence is textual; styles only reinforce
/// information already present in the row and detail region.
pub fn drawSubmissionTree(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    theme: Theme,
    tree: @import("presentation.zig").SubmissionTreeProjection,
) void {
    const modal = centeredModal(win, 78, 22) orelse return;
    var row: u16 = 0;
    while (row < modal.height) : (row += 1) fillRow(modal, row, theme.picker);

    fillRow(modal, 0, theme.picker_query);
    const title = std.fmt.allocPrint(scratch, " Submission for {s}#{d}", .{ tree.key.repository(), tree.key.pull_request_id }) catch " Submission";
    _ = modal.printSegment(.{ .text = title, .style = theme.picker_query }, .{ .row_offset = 0, .wrap = .none });
    if (modal.height < 4) return;
    const summary = std.fmt.allocPrint(scratch, " {d} posted | {d} failed | {d} skipped | {d} outcome unknown", .{
        tree.posted,
        tree.failed,
        tree.skipped,
        tree.outcome_unknown,
    }) catch " Submission progress";
    _ = modal.printSegment(.{ .text = summary, .style = theme.picker }, .{ .row_offset = 1, .wrap = .none });

    const detail_rows: u16 = @min(6, modal.height - 3);
    const detail_start = modal.height - detail_rows;
    const list_height = detail_start -| 2;
    const selected: u16 = @intCast(@min(tree.selected, std.math.maxInt(u16)));
    const top: usize = if (selected >= list_height and list_height > 0) selected - list_height + 1 else 0;
    var item_row: u16 = 2;
    var index = top;
    while (index < tree.items.len and item_row < detail_start) : ({
        index += 1;
        item_row += 1;
    }) {
        const item = tree.items[index];
        var body = std.mem.trim(u8, item.body, " \t\r\n");
        if (std.mem.indexOfScalar(u8, body, '\n')) |newline| body = body[0..newline];
        const indent = tryIndent(scratch, item.depth);
        const text = std.fmt.allocPrint(scratch, "{s}{s}Draft #{d} [{s}] {s} - {s}", .{
            if (index == tree.selected) "> " else "  ",
            indent,
            item.temp_id,
            submissionStateText(item.state),
            item.context,
            body,
        }) catch "Draft";
        const style = if (index == tree.selected) theme.picker_selected else if (item.state == .outcome_unknown) theme.outcome_unknown else theme.picker;
        fillRow(modal, item_row, style);
        _ = modal.printSegment(.{ .text = text, .style = style }, .{ .row_offset = item_row, .wrap = .none });
    }

    if (tree.selectedItem()) |item| drawSubmissionDetail(scratch, modal, theme, tree, item, detail_start);
}

fn tryIndent(scratch: std.mem.Allocator, depth: usize) []const u8 {
    const amount = @min(depth * 2, 20);
    const result = scratch.alloc(u8, amount) catch return "";
    @memset(result, ' ');
    return result;
}

fn submissionStateText(state: @import("presentation.zig").SubmissionItemState) []const u8 {
    return switch (state) {
        .queued => "queued",
        .posting => "posting",
        .waiting_to_retry => "waiting to retry",
        .checking_publication => "checking publication",
        .persisting => "persisting",
        .posted => "posted",
        .failed => "failed",
        .skipped => "skipped",
        .outcome_unknown => "outcome unknown",
    };
}

fn drawSubmissionDetail(
    scratch: std.mem.Allocator,
    modal: vaxis.Window,
    theme: Theme,
    tree: @import("presentation.zig").SubmissionTreeProjection,
    item: @import("presentation.zig").SubmissionItemProjection,
    start: u16,
) void {
    if (start >= modal.height) return;
    fillRow(modal, start, theme.picker_query);
    const identity = std.fmt.allocPrint(scratch, " Draft #{d}: {s}; {d} Reply descendant(s)", .{ item.temp_id, item.context, item.reply_descendants }) catch " Draft detail";
    _ = modal.printSegment(.{ .text = identity, .style = theme.picker_query }, .{ .row_offset = start, .wrap = .none });
    var row = start + 1;
    if (tree.stale_repair) |stale| if (row < modal.height) {
        const source = std.fmt.allocPrint(scratch, " Stale repair: loaded {s}; observed {s}; {s}", .{
            stale.loaded_source_commit,
            stale.observed_source_commit,
            if (stale.reloaded) "reloaded - repair this scope before retry" else "R reload PullRequest; no submit-anyway",
        }) catch " Stale repair required";
        _ = modal.printSegment(.{ .text = source, .style = theme.outcome_unknown }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    };
    if (row < modal.height) {
        const reason = if (item.reason) |err|
            std.fmt.allocPrint(scratch, " Reason: {s}", .{@errorName(err)}) catch " Reason unavailable"
        else if (item.blocking_ancestor) |ancestor|
            std.fmt.allocPrint(scratch, " Blocked by nearest ancestor Draft #{d}; no independent retry", .{ancestor}) catch " Blocked by ancestor"
        else if (item.state == .outcome_unknown)
            " outcome unknown - resolve before editing"
        else
            " Reason: none";
        _ = modal.printSegment(.{ .text = reason, .style = if (item.state == .outcome_unknown) theme.outcome_unknown else theme.picker }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < modal.height) {
        const attempts = std.fmt.allocPrint(scratch, " Attempts: POST {d}/{d}; publication checks {d}/{d}", .{
            item.post_attempts,
            bbr.review.submission.max_attempts,
            item.publication_checks,
            bbr.review.submission.max_attempts,
        }) catch " Attempts unavailable";
        _ = modal.printSegment(.{ .text = attempts, .style = theme.picker }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < modal.height) {
        const delay = if (item.retry) |retry| std.fmt.allocPrint(scratch, " Static delay: local {d}ms; server {s}; effective {d}ms", .{
            retry.local_delay_ms,
            if (retry.server_delay_ms) |server| std.fmt.allocPrint(scratch, "{d}ms", .{server}) catch "set" else "none",
            retry.effective_delay_ms,
        }) catch " Static delay unavailable" else " Static delay: none";
        _ = modal.printSegment(.{ .text = delay, .style = theme.picker }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < modal.height) {
        fillRow(modal, row, theme.picker_query);
        const footer: []const u8 = if (tree.completion == null)
            " In progress; A abandons recovered ambiguity only"
        else if (item.retry_eligible)
            " e edit | a re-anchor | D delete | X retry selected subtree | Esc dismiss"
        else if (item.repair_eligible)
            " e edit | a re-anchor | D delete | R reload | repair before retry | Esc dismiss"
        else if (item.state == .outcome_unknown)
            " L link author-owned Comment | U confirm not published | A decide later"
        else if (item.state == .posted)
            " Posted items are inspectable, never retryable | Esc dismiss"
        else if (item.state == .skipped)
            " Select its blocking ancestor to repair or retry | Esc dismiss"
        else
            " j/k select | Esc dismiss";
        _ = modal.printSegment(.{ .text = footer, .style = theme.picker_query }, .{ .row_offset = row, .wrap = .none });
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
        const reason = sourceRefusalLabel(availability, act);
        const line = if (reason) |label|
            std.fmt.allocPrint(scratch, "{s:<8}{s} ({s})", .{ keys.items, help, label }) catch help
        else
            std.fmt.allocPrint(scratch, "{s:<8}{s}", .{ keys.items, help }) catch help;
        (if (keymap.isMotion(act)) &motions else &commands).append(scratch, .{
            .text = line,
            .available = availability.available(act),
        }) catch {};
    }
    return .{ .motions = motions.items, .commands = commands.items };
}

fn sourceRefusalLabel(availability: presentation.ActionAvailability, action: keymap.Action) ?[]const u8 {
    return switch (action) {
        .yank => if (availability.yank_refusal) |refusal| switch (refusal) {
            .no_source => "no source",
            .selected_content_unavailable => if (availability.selected_version == .old) "old content unavailable" else "new content unavailable",
        } else null,
        .inline_comment => if (availability.inline_comment_refusal) |refusal| switch (refusal) {
            .no_source => "no source",
            .selected_content_unavailable => if (availability.selected_version == .old) "old content unavailable" else "new content unavailable",
            .not_hunk_line => "not a Hunk Line",
            .opposite_version => "opposite File version",
        } else null,
        .suggest => if (availability.suggestion_refusal) |refusal| switch (refusal) {
            .no_source => "no source",
            .selected_content_unavailable => if (availability.selected_version == .old) "old content unavailable" else "new content unavailable",
            .not_hunk_line => "not a Hunk Line",
            .opposite_version => "opposite File version",
            .old_version => "requires new File version",
        } else null,
        else => null,
    };
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

fn drawUnifiedGutter(win: vaxis.Window, row: u16, old_no: ?u32, new_no: ?u32, style: vaxis.Style) void {
    var text: [32]u8 = undefined;
    var length = formatNumCol(&text, old_no);
    text[length] = ' ';
    length += 1;
    length += formatNumCol(text[length..], new_no);
    text[length] = ' ';
    paintStaticDigits(win, row, text[0 .. length + 1], style);
}

fn drawSideGutter(win: vaxis.Window, row: u16, no: ?u32, style: vaxis.Style) void {
    var text: [16]u8 = undefined;
    const length = formatNumCol(&text, no);
    paintStaticDigits(win, row, text[0..length], style);
}

fn formatNumCol(output: []u8, no: ?u32) usize {
    if (no) |number| return (std.fmt.bufPrint(output, "{d: >4}", .{number}) catch return 0).len;
    @memcpy(output[0..4], "    ");
    return 4;
}

fn paintStaticDigits(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    for (text, 0..) |byte, column| {
        if (column >= win.width) break;
        win.writeCell(@intCast(column), row, .{ .char = .{ .grapheme = digitGlyph(byte), .width = 1 }, .style = style });
    }
}

fn digitGlyph(byte: u8) []const u8 {
    return switch (byte) {
        '0' => "0",
        '1' => "1",
        '2' => "2",
        '3' => "3",
        '4' => "4",
        '5' => "5",
        '6' => "6",
        '7' => "7",
        '8' => "8",
        '9' => "9",
        else => " ",
    };
}

fn fillRow(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    win.child(.{ .y_off = row, .height = 1 }).fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
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

fn expectScreenText(win: vaxis.Window, row: u16, expected: []const u8) !void {
    for (expected, 0..) |char, col| {
        const cell = win.readCell(@intCast(col), row) orelse return error.MissingCell;
        try testing.expectEqualStrings(&.{char}, cell.char.grapheme);
    }
}

test "M21 authored Overlay renders ranked rows and matched Preview in landscape and portrait" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const search = @import("search.zig");
    const ranges = [_]search.Range{.{ .start = 7, .end = 13 }};
    const occurrence: search.Occurrence = .{
        .location = .{ .review_body = .{ .owner = .{ .comment = 42 }, .logical_line = 2 } },
        .ranges = @constCast(&ranges),
        .column = 1,
        .candidate_scalars = 6,
        .corpus_order = 0,
        .session_epoch = 1,
    };
    const result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = "before\nneedle after\nlater",
        .scope = .review,
        .scope_state = .current,
        .occurrence = occurrence,
    };
    inline for (.{ @as(u16, 100), @as(u16, 20) }) |cols| {
        var screen = try vaxis.Screen.init(a, .{ .rows = 26, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        const geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = cols, .rows = 26 }).?;
        drawReviewSearch(a, win, .{
            .query = "need",
            .occurrences = &.{occurrence},
            .results = &.{result},
            .candidate_count = 3,
            .selected = 0,
            .list_scroll = 0,
            .preview_scroll = 0,
            .pending = false,
            .geometry = geometry,
        }, theme_dark);
        const list = childRect(win, geometry.list);
        const preview = childRect(win, geometry.preview);
        const input = childRect(win, .{ .x = geometry.rect.x + 1, .y = geometry.rect.y + 1, .width = geometry.rect.width - 2, .height = 1 });
        const header = childRect(win, geometry.header);
        try testing.expectEqual(theme_dark.picker.bg, input.readCell(0, 0).?.style.bg);
        try testing.expectEqual(theme_dark.picker.bg, input.readCell(2, 0).?.style.bg);
        try testing.expectEqual(theme_dark.picker.bg, header.readCell(0, 0).?.style.bg);
        try testing.expectEqual(theme_dark.picker.bg, header.readCell(header.width - 1, 0).?.style.bg);
        try testing.expectEqualStrings("▸", list.readCell(0, 0).?.char.grapheme);
        try testing.expectEqualStrings("b", preview.readCell(0, 0).?.char.grapheme);
        try testing.expect(geometry.landscape == (cols == 100));
        try testing.expectEqual(theme_dark.search_active, preview.readCell(0, 1).?.style.bg);
        if (cols == 20) try testing.expectEqualStrings("├", win.readCell(geometry.body.x, geometry.divider).?.char.grapheme);
    }
}

test "M21 authored source Preview shows exact ranges, version states, horizontal scroll, and reacquisition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const search = @import("search.zig");
    const ranges = [_]search.Range{.{ .start = 4, .end = 10 }};
    const occurrence: search.Occurrence = .{
        .location = .{ .source = .{ .file_index = 0, .relation = .new, .old_path = "src/a.txt", .new_path = "src/a.txt", .new_line = 2 } },
        .ranges = @constCast(&ranges),
        .column = 5,
        .candidate_scalars = 11,
        .corpus_order = 0,
        .session_epoch = 1,
    };
    const result: presentation.ReviewSearchResult = .{ .kind = "SOURCE", .source = "File", .body = "", .scope = .review, .scope_state = null, .occurrence = occurrence };
    const spans = [_]bbr.highlight.Span{
        .{ .line = 1, .start = 0, .end = 6, .capture = bbr.highlight.Capture.init(0, "comment") },
        .{ .line = 2, .start = 4, .end = 7, .capture = bbr.highlight.Capture.init(1, "keyword") },
    };
    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 100, .rows = 24 }).?;
    const base: presentation.ReviewSearchProjection = .{
        .query = "needle",
        .occurrences = &.{occurrence},
        .results = &.{result},
        .candidate_count = 2,
        .selected = 0,
        .list_scroll = 0,
        .preview_scroll = 0,
        .pending = false,
        .geometry = geometry,
        .source_preview = .{ .old = .{ .binary = 12 }, .new = .{ .content = .{ .blob = "before\nxxxxneedle after\n", .highlighting = .{ .ready = .{ .spans = &spans } } } } },
    };
    drawReviewSearch(a, win, base, theme_dark);
    const preview = childRect(win, geometry.preview);
    const header = childRect(win, geometry.header);
    try testing.expectEqual(theme_dark.picker.bg, header.readCell(0, 0).?.style.bg);
    try testing.expectEqual(theme_dark.picker.bg, header.readCell(header.width - 1, 0).?.style.bg);
    try testing.expectEqualStrings("x", preview.readCell(0, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.syntax_comment, preview.readCell(0, 0).?.style.fg);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(4, 1).?.style.bg);
    try testing.expectEqual(theme_dark.syntax_keyword, preview.readCell(4, 1).?.style.fg);
    try testing.expect(!std.meta.eql(preview.readCell(0, 1).?.style.fg, theme_dark.syntax_keyword));
    try testing.expectEqual(theme_dark.search_active, preview.readCell(8, 1).?.style.bg);
    try testing.expect(!std.meta.eql(preview.readCell(8, 1).?.style.fg, theme_dark.syntax_keyword));
    var horizontal = base;
    horizontal.preview_horizontal = 4;
    drawReviewSearch(a, win, horizontal, theme_dark);
    try testing.expectEqualStrings("n", preview.readCell(0, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(0, 1).?.style.bg);
    try testing.expectEqual(theme_dark.syntax_keyword, preview.readCell(0, 1).?.style.fg);
    var evicted = base;
    evicted.source_preview = .{ .old = .{ .binary = 12 }, .new = .pending };
    drawReviewSearch(a, win, evicted, theme_dark);
    try testing.expectEqualStrings("R", preview.readCell(0, 0).?.char.grapheme);
}

test "M21 authored Overlay exposes both File version states without a Query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 100, .rows = 24 }).?;
    const files = [_]@import("bbr").diff.File{.{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = &.{} }};
    const contents = [_]@import("bbr").diff.FileContent{.{
        .old = .{ .binary = 12 },
        .new = .{ .unavailable = .{ .byte_size = 3, .reason = .invalid_utf8 } },
    }};
    const statuses = [_]@import("bbr").highlight.FileHighlightStatus{.{ .old = .absent, .new = .absent }};
    drawReviewSearch(a, win, .{
        .query = "",
        .occurrences = &.{},
        .results = &.{},
        .candidate_count = 0,
        .selected = null,
        .list_scroll = 0,
        .preview_scroll = 0,
        .pending = false,
        .geometry = geometry,
        .files = &files,
        .content_statuses = &contents,
        .highlight_statuses = &statuses,
        .status_preview = .{ .old = .{ .binary = 12 }, .new = .{ .unavailable = contents[0].new.? } },
    }, theme_dark);
    const list = childRect(win, geometry.list);
    try testing.expectEqualStrings("a", list.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("b", list.readCell(11, 0).?.char.grapheme);
    const preview = childRect(win, geometry.preview);
    try testing.expectEqualStrings("o", preview.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("n", preview.readCell(0, 1).?.char.grapheme);
}

test "M21 authored Review Search list shows a scroll bar for long results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 100, .rows = 24 }).?;
    const occurrence: @import("search.zig").Occurrence = .{
        .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } },
        .ranges = @constCast(&[_]@import("search.zig").Range{}),
        .column = 1,
        .candidate_scalars = 1,
        .corpus_order = 0,
        .session_epoch = 1,
    };
    const result: presentation.ReviewSearchResult = .{ .kind = "COMMENT", .source = "Ada", .body = "text", .scope = .review, .scope_state = .current, .occurrence = occurrence };
    const results = [_]presentation.ReviewSearchResult{result} ** 60;
    var projection: presentation.ReviewSearchProjection = .{
        .query = "text",
        .occurrences = &.{},
        .results = &results,
        .candidate_count = 60,
        .selected = 0,
        .list_scroll = 0,
        .preview_scroll = 0,
        .pending = false,
        .geometry = geometry,
    };
    drawReviewSearch(a, win, projection, theme_dark);
    const list = childRect(win, geometry.list);
    const bar_col = list.width - 1;
    const thumb = @max(@as(usize, 1), (@as(usize, list.height) * list.height + results.len - 1) / results.len);
    try testing.expect(thumb < list.height);
    try testing.expectEqualStrings("│", list.readCell(bar_col, 0).?.char.grapheme);
    try testing.expectEqualStrings("│", list.readCell(bar_col, @intCast(thumb - 1)).?.char.grapheme);
    try testing.expectEqualStrings(" ", list.readCell(bar_col, @intCast(thumb)).?.char.grapheme);
    try testing.expectEqualStrings(" ", list.readCell(bar_col, list.height - 1).?.char.grapheme);
    projection.list_scroll = (60 - list.height) / 2;
    drawReviewSearch(a, win, projection, theme_dark);
    try testing.expectEqualStrings(" ", list.readCell(bar_col, 0).?.char.grapheme);
    try testing.expectEqualStrings("│", list.readCell(bar_col, list.height / 2).?.char.grapheme);
    try testing.expectEqualStrings(" ", list.readCell(bar_col, list.height - 1).?.char.grapheme);
    projection.list_scroll = 60 - list.height;
    drawReviewSearch(a, win, projection, theme_dark);
    try testing.expectEqualStrings(" ", list.readCell(bar_col, 0).?.char.grapheme);
    try testing.expectEqualStrings(" ", list.readCell(bar_col, list.height - @as(u16, @intCast(thumb)) - 1).?.char.grapheme);
    try testing.expectEqualStrings("│", list.readCell(bar_col, list.height - 1).?.char.grapheme);
}

test "M21 authored Preview paints every disjoint Markdown match range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 12, .cols = 45, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const search = @import("search.zig");
    const ranges = [_]search.Range{ .{ .start = 2, .end = 6 }, .{ .start = 8, .end = 13 } };
    const occurrence: search.Occurrence = .{
        .location = .{ .review_body = .{ .owner = .{ .draft = 9 }, .logical_line = 1 } },
        .ranges = @constCast(&ranges),
        .column = 1,
        .candidate_scalars = 9,
        .corpus_order = 0,
        .session_epoch = 1,
    };
    const geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 45, .rows = 12 }).?;
    drawReviewSearch(a, headlessWindow(&screen), .{
        .query = "bold text",
        .occurrences = &.{occurrence},
        .results = &.{.{ .kind = "DRAFT", .source = "local", .body = "**bold** text", .scope = .review, .scope_state = .current, .occurrence = occurrence }},
        .candidate_count = 1,
        .selected = 0,
        .list_scroll = 0,
        .preview_scroll = 0,
        .pending = false,
        .geometry = geometry,
    }, theme_dark);
    const preview = childRect(headlessWindow(&screen), geometry.preview);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(2, 0).?.style.bg);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(8, 0).?.style.bg);
    try testing.expect(!std.meta.eql(preview.readCell(6, 0).?.style.bg, theme_dark.search_active));
}

test "Review Search shortens directories and keeps the filename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("src/components/review.zig", shortSearchPath(a, "src/components/review.zig", 25));
    try testing.expectEqualStrings("s/c/review.zig", shortSearchPath(a, "src/components/review.zig", 14));
    try testing.expectEqualStrings("…/review.zig", shortSearchPath(a, "src/components/review.zig", 12));
    try testing.expectEqualStrings("review.zig", shortSearchPath(a, "src/components/review.zig", 10));
    try testing.expectEqualStrings("…ew.zig", shortSearchPath(a, "src/components/review.zig", 7));
    try testing.expectEqualStrings("界/über.zig", shortSearchPath(a, "界界/über.zig", 11));
}

test "Review Search draws titled borders, top query, Position, and separated Preview header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 30, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 100, .rows = 30 }).?;
    const search = @import("search.zig");
    const ranges = [_]search.Range{.{ .start = 0, .end = 4 }};
    const occurrence: search.Occurrence = .{
        .location = .{ .review_body = .{ .owner = .{ .comment = 42 }, .logical_line = 1 } },
        .ranges = @constCast(&ranges),
        .column = 1,
        .candidate_scalars = 4,
        .corpus_order = 0,
        .session_epoch = 1,
    };
    drawReviewSearch(a, win, .{
        .query = "text",
        .occurrences = &.{occurrence},
        .results = &.{.{ .kind = "COMMENT", .source = "Ada", .body = "text", .scope = .{ .file = .{ .path = "src/components/review.zig", .source_commit = "abc" } }, .scope_state = .current, .occurrence = occurrence }},
        .candidate_count = 2,
        .selected = 0,
        .list_scroll = 0,
        .preview_scroll = 0,
        .pending = false,
        .geometry = geometry,
    }, theme_dark);
    try testing.expectEqualStrings("┌", win.readCell(geometry.rect.x, geometry.rect.y).?.char.grapheme);
    try testing.expectEqualStrings(">", win.readCell(geometry.rect.x + 1, geometry.rect.y + 1).?.char.grapheme);
    const status = "1/1 matches · 2 candidates";
    try testing.expectEqualStrings("1", win.readCell(geometry.rect.x + geometry.rect.width - @as(u16, @intCast(searchCellWidth(status))) - 2, geometry.rect.y + 2).?.char.grapheme);
    try testing.expectEqualStrings("┌", win.readCell(geometry.body.x, geometry.body.y).?.char.grapheme);
    try testing.expectEqualStrings("┬", win.readCell(geometry.divider, geometry.body.y).?.char.grapheme);
    try testing.expectEqualStrings("▸", win.readCell(geometry.list.x, geometry.list.y).?.char.grapheme);
    try testing.expectEqualStrings("C", win.readCell(geometry.header.x, geometry.header.y).?.char.grapheme);
    try testing.expectEqualStrings("─", win.readCell(geometry.header.x, geometry.header.y + 1).?.char.grapheme);
    try testing.expectEqualStrings("t", win.readCell(geometry.preview.x, geometry.preview.y).?.char.grapheme);
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
    const spans = [_]bbr.highlight.Span{.{ .line = 1, .start = 0, .end = 3, .capture = bbr.highlight.Capture.init(0, "keyword") }};
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

test "zero-width Diff visual-row projection clips exactly like Buffer rendering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "long highlighted source" };
    const runs = [_]bbr.highlight.decoration.Run{
        .{ .text = line.text[0..4], .capture = bbr.highlight.Capture.init(0, "keyword") },
        .{ .text = line.text[4..], .emphasis = true },
    };
    const rows = [_]Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } }};
    const buf: Buffer = .{ .rows = &rows, .layout = .unified };
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{ .layout = .unified, .width = 0 });
    var buffer_screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 14, .x_pixel = 0, .y_pixel = 0 });
    defer buffer_screen.deinit(a);
    var frame_screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 14, .x_pixel = 0, .y_pixel = 0 });
    defer frame_screen.deinit(a);
    const buffer_window = headlessWindow(&buffer_screen);
    const frame_window = headlessWindow(&frame_screen);
    const nav = Nav.init(1, 1);

    drawPane(a, buffer_window, buf, theme_dark, nav);
    drawVisualPane(a, frame_window, buf, visual_rows, theme_dark, nav);

    for (0..buffer_window.width) |col| {
        const expected = buffer_window.readCell(@intCast(col), 0).?;
        const actual = frame_window.readCell(@intCast(col), 0).?;
        try testing.expectEqualStrings(expected.char.grapheme, actual.char.grapheme);
        try testing.expectEqual(expected.style, actual.style);
    }
}

test "M21 Buffer Search overlays active and inactive ranges without erasing syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "long highlighted" };
    const runs = [_]bbr.highlight.decoration.Run{.{ .text = line.text, .capture = bbr.highlight.Capture.init(0, "keyword") }};
    const rows = [_]Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } }};
    const buf: Buffer = .{ .rows = &rows, .layout = .unified };
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{ .layout = .unified, .width = 40 });
    const ranges = [_]@import("frame.zig").ProjectedSourceRange{
        .{ .visual_row = 0, .relation = .new, .source = .{ .start = 0, .end = 4 }, .row = .{ .start = 0, .end = 4 }, .active = true },
        .{ .visual_row = 0, .relation = .new, .source = .{ .start = 5, .end = 16 }, .row = .{ .start = 5, .end = 16 }, .active = false },
    };
    const nav = Nav.init(1, 1);
    const frame: @import("frame.zig").Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 40, .rows = 1 },
        .panes = @import("frame.zig").paneRects(.{ .cols = 40, .rows = 1 }),
        .visual_rows = visual_rows,
        .buffer = buf,
        .navigation = nav,
        .search_ranges = &ranges,
    };
    var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawVisualPane(a, win, buf, visual_rows, theme_dark, nav);
    drawSearchRanges(win, frame, theme_dark);

    try testing.expectEqual(theme_dark.search_active, win.readCell(gutter_cols, 0).?.style.bg);
    try testing.expectEqual(theme_dark.search_match, win.readCell(gutter_cols + 5, 0).?.style.bg);
    try testing.expectEqual(theme_dark.syntax_keyword, win.readCell(gutter_cols, 0).?.style.fg);
}

test "Buffer Search clips matches outside a narrow DiffPane" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = headlessWindow(&screen);

    paintSearchCells(win, 0, 3, 2, true, theme_dark);
    paintSearchCells(win, 0, 4, 2, true, theme_dark);
    try testing.expect(!std.meta.eql(theme_dark.search_active, win.readCell(2, 0).?.style.bg));

    paintSearchCells(win, 0, 2, 4, true, theme_dark);
    try testing.expectEqual(theme_dark.search_active, win.readCell(2, 0).?.style.bg);
    try testing.expect(!std.meta.eql(theme_dark.search_active, win.readCell(1, 0).?.style.bg));
}

test "zero-width SideBySide visual rows clip exactly like Buffer rendering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left: bbr.diff.Line = .{ .old_no = 1, .new_no = 0, .kind = .removed, .text = "long old source" };
    const right: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "long new source" };
    const rows = [_]Row{.{ .line_pair = .{
        .left = .{ .line = &left, .decoration = .{ .runs = &.{.{ .text = left.text }} } },
        .right = .{ .line = &right, .decoration = .{ .runs = &.{.{ .text = right.text }} } },
    } }};
    const buf: Buffer = .{ .rows = &rows, .layout = .side_by_side };
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{ .layout = .side_by_side, .width = 0 });
    var buffer_screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 19, .x_pixel = 0, .y_pixel = 0 });
    defer buffer_screen.deinit(a);
    var frame_screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 19, .x_pixel = 0, .y_pixel = 0 });
    defer frame_screen.deinit(a);
    const buffer_window = headlessWindow(&buffer_screen);
    const frame_window = headlessWindow(&frame_screen);
    const nav = Nav.init(1, 1);

    drawPane(a, buffer_window, buf, theme_dark, nav);
    drawVisualPane(a, frame_window, buf, visual_rows, theme_dark, nav);

    for (0..buffer_window.width) |col| {
        const expected = buffer_window.readCell(@intCast(col), 0).?;
        const actual = frame_window.readCell(@intCast(col), 0).?;
        try testing.expectEqualStrings(expected.char.grapheme, actual.char.grapheme);
        try testing.expectEqual(expected.style, actual.style);
    }
}

test "Unified continuation rows keep decoration and use a blank gutter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 7, .kind = .added, .text = "alpha beta" };
    const rows = [_]Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &.{
        .{ .text = line.text[0..3], .capture = bbr.highlight.Capture.init(0, "keyword") },
        .{ .text = line.text[3..8], .emphasis = true },
        .{ .text = line.text[8..] },
    } } } }};
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{
        .layout = .unified,
        .width = 16,
    });
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = 16, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    var nav = Nav.init(visual_rows.len, 2);
    nav.mark = 0;
    drawVisualPane(a, win, .{ .rows = &rows, .layout = .unified }, visual_rows, theme_dark, nav);

    try testing.expectEqualStrings("7", win.readCell(8, 0).?.char.grapheme);
    for (0..gutter_cols) |col| try testing.expectEqualStrings(" ", win.readCell(@intCast(col), 1).?.char.grapheme);
    try testing.expectEqualStrings("b", win.readCell(gutter_cols, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.cursorBg(theme_dark.added_emphasis.bg), win.readCell(gutter_cols, 1).?.style.bg);
    try testing.expectEqual(theme_dark.cursorBg(theme_dark.added.bg), win.readCell(gutter_cols + 2, 1).?.style.bg);
}

test "SideBySide continuation rows keep halves inside the fixed divider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left: bbr.diff.Line = .{ .old_no = 7, .new_no = 0, .kind = .removed, .text = "old one two" };
    const right: bbr.diff.Line = .{ .old_no = 0, .new_no = 9, .kind = .added, .text = "new" };
    const rows = [_]Row{.{ .line_pair = .{
        .left = .{ .line = &left, .decoration = .{ .runs = &.{.{ .text = left.text, .emphasis = true }} } },
        .right = .{ .line = &right, .decoration = .{ .runs = &.{.{ .text = right.text }} } },
    } }};
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{
        .layout = .side_by_side,
        .width = 27,
    });
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = 27, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    var nav = Nav.init(visual_rows.len, 2);
    nav.mark = 0;
    drawVisualPane(a, win, .{ .rows = &rows, .layout = .side_by_side }, visual_rows, theme_dark, nav);

    try testing.expectEqualStrings("7", win.readCell(3, 0).?.char.grapheme);
    try testing.expectEqualStrings("9", win.readCell(17, 0).?.char.grapheme);
    try testing.expectEqualStrings("t", win.readCell(side_gutter, 1).?.char.grapheme);
    try testing.expectEqualStrings(" ", win.readCell(17, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.cursorBg(theme_dark.removed_emphasis.bg), win.readCell(side_gutter, 1).?.style.bg);
}

test "Status Placeholder renders side, reason, and known or unavailable size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: bbr.diff.File = .{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = &.{} };
    const rows = [_]buffer_mod.Row{
        .{ .status_placeholder = .{
            .file = &file,
            .old = .{ .unavailable = .{ .unavailable = .{ .byte_size = 27, .reason = .{ .acquisition_failed = error.NotFound } } } },
        } },
        .{ .status_placeholder = .{
            .file = &file,
            .new = .{ .unavailable = .{ .unavailable = .{ .reason = .{ .acquisition_failed = error.NetworkError } } } },
        } },
    };
    const buf: Buffer = .{ .rows = &rows, .layout = .unified };
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPane(a, win, buf, theme_dark, Nav.init(rows.len, rows.len));

    try expectScreenText(win, 0, "Old content unavailable: acquisition failed (NotFound), 27 bytes");
    try expectScreenText(win, 1, "New content unavailable: acquisition failed (NetworkError), size unavailable");
}

test "SideBySide Status Placeholders render each side independently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: bbr.diff.File = .{ .old_path = "a.bin", .new_path = "a.bin", .status = .modified, .hunks = &.{} };
    const rows = [_]buffer_mod.Row{.{ .status_placeholder = .{
        .file = &file,
        .old = .{ .binary = 3 },
        .new = .{ .unavailable = .{ .unavailable = .{ .reason = .{ .acquisition_failed = error.NotFound } } } },
    } }};
    const buf: Buffer = .{ .rows = &rows, .layout = .side_by_side };
    var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPane(a, win, buf, theme_dark, Nav.init(1, 1));

    try expectScreenText(win, 0, "Old content binary, 3 bytes");
    const right = win.child(.{ .x_off = win.width / 2 + 1, .width = win.width - (win.width / 2 + 1), .height = 1 });
    try expectScreenText(right, 0, "New content unavailable: acquisition failed");
}

test "binary Status Placeholder renders an unknown size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const added: bbr.diff.File = .{ .old_path = "/dev/null", .new_path = "a.bin", .status = .added, .hunks = &.{} };
    const removed: bbr.diff.File = .{ .old_path = "b.bin", .new_path = "/dev/null", .status = .removed, .hunks = &.{} };
    const rows = [_]buffer_mod.Row{
        .{ .status_placeholder = .{ .file = &added, .new = .{ .binary = null } } },
        .{ .status_placeholder = .{ .file = &removed, .old = .{ .binary = 7 } } },
    };
    const buf: Buffer = .{ .rows = &rows, .layout = .side_by_side };
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPane(a, win, buf, theme_dark, Nav.init(2, 2));

    try expectScreenText(win, 0, "Old content absent");
    const right = win.child(.{ .x_off = win.width / 2 + 1, .width = win.width - (win.width / 2 + 1), .height = 2 });
    try expectScreenText(right, 0, "New content binary, size unavailable");
    try expectScreenText(win, 1, "Old content binary, 7 bytes");
    try expectScreenText(right, 1, "New content absent");
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

test "File header junctions keep the DiffPane border style" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: bbr.diff.File = .{ .old_path = "a.zig", .new_path = "a.zig", .status = .modified, .hunks = &.{} };
    const rows = [_]Row{.{ .file_header = .{ .file = &file, .path = file.new_path } }};
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{ .layout = .unified, .width = 10 });
    var screen = try vaxis.Screen.init(a, .{ .rows = 6, .cols = 16, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const outer: @import("frame.zig").Rect = .{ .x = 2, .y = 0, .width = 12, .height = 6 };
    const content: @import("frame.zig").Rect = .{ .x = 3, .y = 2, .width = 10, .height = 3 };

    for ([_]bool{ false, true }) |focused| {
        drawPaneFrame(win, outer, "", theme_dark, focused);
        joinSectionRules(win, outer, content, visual_rows, Nav.init(visual_rows.len, content.height));

        try testing.expectEqualStrings("├", win.readCell(outer.x, content.y).?.char.grapheme);
        try testing.expectEqualStrings("┤", win.readCell(outer.x + outer.width - 1, content.y).?.char.grapheme);
        try testing.expectEqual(win.readCell(outer.x, content.y + 1).?.style, win.readCell(outer.x, content.y).?.style);
        try testing.expectEqual(win.readCell(outer.x + outer.width - 1, content.y + 1).?.style, win.readCell(outer.x + outer.width - 1, content.y).?.style);
    }
}

test "File and PR Comment headers end in DiffPane border rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: bbr.diff.File = .{ .old_path = "a.zig", .new_path = "a.zig", .status = .modified, .hunks = &.{} };
    var theme = theme_dark;
    theme.section_rule = theme.pane_border_focused;
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawRow(a, win, 0, .unified, null, .{ .file_header = .{ .file = &file, .path = file.new_path } }, theme);
    drawRow(a, win, 1, .unified, null, .{ .section = .{ .kind = .pr_comments, .count = 2 } }, theme);

    try testing.expectEqualStrings("─", win.readCell(win.width - 1, 0).?.char.grapheme);
    try testing.expectEqual(theme.pane_border_focused.fg, win.readCell(win.width - 1, 0).?.style.fg);
    try testing.expectEqualStrings("P", win.readCell(3, 1).?.char.grapheme);
    try testing.expectEqual(theme.file_header.fg, win.readCell(3, 1).?.style.fg);
    try testing.expectEqualStrings("─", win.readCell(win.width - 1, 1).?.char.grapheme);
    try testing.expectEqual(theme.pane_border_focused.fg, win.readCell(win.width - 1, 1).?.style.fg);
}

test "ReviewCard wide grapheme keeps the DiffPane right border" {
    const Metrics = struct {
        fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            var iterator = vaxis.unicode.graphemeIterator(text);
            const grapheme = iterator.next() orelse return .{ .byte_len = 1, .cell_width = 1 };
            return .{
                .byte_len = grapheme.len,
                .cell_width = vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode),
            };
        }

        const context: u8 = 0;
        const value: @import("cell_metrics.zig").CellMetrics = .{ .ptr = &context, .vtable = &.{ .next = next } };
    };

    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const session = try @import("session.zig").create(testing.allocator);
    const a = session.arena.allocator();
    session.source = .{ .remote = .{
        .id = 1,
        .title = "Border test",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    } };
    session.header = .{
        .title = "Border test",
        .source_ref = "feature",
        .base_ref = "main",
        .source_commit = "source",
        .base_commit = "destination",
        .author = "Reviewer",
        .locator = "repo",
        .source_label = "Bitbucket",
        .pull_request_id = 1,
    };
    session.diff = try bbr.diff.parse(a,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
    );
    const comments = try a.alloc(bbr.review.Comment, 1);
    comments[0] = .{ .id = 1, .author = "Ada", .body = "aaaaaaaaaaaaaaaaaaaaaaaa⚠️" };
    session.threads = try bbr.review.buildThreads(a, comments);
    try session.initializeEnrichment();

    var state = try presentation.Presentation.init(testing.allocator, .{
        .reviews = store.store(),
        .cell_metrics = Metrics.value,
    }, .{
        .initial = .{ .key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1), .session = session },
        .geometry = .{ .cols = 60, .rows = 10 },
    });
    defer state.deinit();
    const review = state.projection().review.?;

    var projected_body_rows: usize = 0;
    for (review.buffer.rows) |row| if (row == .comment and row.comment.part == .body) {
        projected_body_rows += 1;
    };
    try testing.expectEqual(@as(usize, 2), projected_body_rows);

    var screen = try vaxis.Screen.init(a, .{ .rows = 10, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    drawReview(a, win, review, theme_dark, 0);

    var body_row: ?usize = null;
    for (review.frame.visual_rows, 0..) |visual, index| {
        const row = review.buffer.rows[visual.buffer_index];
        if (row == .comment and row.comment.part == .body) {
            body_row = index;
            break;
        }
    }
    const screen_row: u16 = review.frame.panes.diff_content.y + @as(u16, @intCast(body_row.? - review.navigation.scroll));
    const right = review.frame.panes.diff.x + review.frame.panes.diff.width - 1;
    try testing.expectEqualStrings("│", win.readCell(right, screen_row).?.char.grapheme);
}

test "DiffPane title reserves and renders published Selected Version targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(arena.allocator(), .{ .rows = 8, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(arena.allocator());
    const win = headlessWindow(&screen);
    const panes = @import("frame.zig").paneRects(.{ .cols = 80, .rows = 8 });
    const targets = @import("frame.zig").versionTitleTargets(panes.diff, .old);
    const frame: @import("frame.zig").Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 80, .rows = 8 },
        .panes = panes,
        .visual_rows = &.{},
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(0, panes.diff_content.height),
        .focus = .sidebar,
        .selected_version = .old,
        .version_title_targets = targets,
    };

    drawDiffPaneFrame(arena.allocator(), win, frame, "src/a-very-long-file-name.zig", .whole, theme_dark);

    try testing.expectEqualStrings("g", win.readCell(targets.old.?.x, 0).?.char.grapheme);
    try testing.expectEqualStrings("D", win.readCell(targets.old.?.x + 5, 0).?.char.grapheme);
    try testing.expectEqualStrings("N", win.readCell(targets.new.?.x, 0).?.char.grapheme);
    try testing.expectEqual(theme_dark.accent, win.readCell(targets.old.?.x, 0).?.style.fg);
    try testing.expect(win.readCell(targets.old.?.x, 0).?.style.bold);
    try testing.expect(!std.meta.eql(win.readCell(targets.new.?.x, 0).?.style.fg, theme_dark.accent));
    try testing.expectEqualStrings("─", win.readCell(targets.old.?.x - 1, 0).?.char.grapheme);
}

test "SideBySide WholeFile accents only the selected header and inner gutter edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a,
        \\diff --git a/old.txt b/new.txt
        \\similarity index 80%
        \\rename from old.txt
        \\rename to new.txt
        \\--- a/old.txt
        \\+++ b/new.txt
        \\@@ -1 +1 @@
        \\-let value = 1
        \\+let value = 2
    );
    const blobs = [_]bbr.diff.FileBlob{.{ .old = "let value = 1\n", .new = "let value = 2\n" }};
    const buf = try buffer_mod.buildWithComments(a, diff, .side_by_side, &.{}, .{ .whole_file = true, .selected_version = .old, .blobs = &blobs });
    var screen = try vaxis.Screen.init(a, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPane(a, win, buf, theme_dark, Nav.init(buf.rows.len, 6));

    const half = win.width / 2;
    try testing.expectEqual(theme_dark.accent, win.readCell(0, 0).?.style.fg);
    try testing.expect(!std.meta.eql(win.readCell(half + 1, 0).?.style.fg, theme_dark.accent));
    try testing.expectEqualStrings("▐", win.readCell(half, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.accent, win.readCell(half, 1).?.style.fg);
    try testing.expectEqual(theme_dark.removed.bg, win.readCell(side_gutter, 1).?.style.bg);
    try testing.expectEqual(theme_dark.added.bg, win.readCell(half + 1 + side_gutter, 1).?.style.bg);
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
    // Remote-only commands, plus edit, re-anchor, and delete, stay visible.
    try testing.expectEqual(@as(usize, 11), unavailable);
    for (rows.motions) |row| try testing.expect(row.available);
}

test "help keeps refused source Actions visible with typed reasons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{
        .remote = true,
        .selected_version = .old,
        .yank_refusal = .selected_content_unavailable,
        .inline_comment_refusal = .not_hunk_line,
        .suggestion_refusal = .old_version,
    });
    try testing.expect(!helpRowAvailable(rows.commands, "yank source text (old content unavailable)").?);
    try testing.expect(!helpRowAvailable(rows.commands, "inline comment (not a Hunk Line)").?);
    try testing.expect(!helpRowAvailable(rows.commands, "suggestion (requires new File version)").?);
}

test "delete stays discoverable in the help Overlay when it is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refused = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .delete_refusal = .descendant_locked });
    const deletable = buildHelpRows(arena.allocator(), keymap.Keymap.default, .{ .remote = true, .delete_refusal = null });
    try testing.expect(!helpRowAvailable(refused.commands, "delete Comment or Draft").?);
    try testing.expect(helpRowAvailable(deletable.commands, "delete Comment or Draft").?);
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
