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
const Section = buffer_mod.Section;
const FileStatus = bbr.diff.FileStatus;
const Thread = bbr.review.Thread;
const Draft = bbr.review.Draft;
const list_overlay_mod = @import("list_overlay.zig");
const ListOverlay = list_overlay_mod.ListOverlay;
const ThemeId = @import("theme_id.zig").ThemeId;
const keymap = @import("keymap.zig");
const buffer_mod = @import("buffer.zig");
const layouts = @import("layouts.zig");
const view_paint = @import("view_paint.zig");

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
    const frame = review.frame;
    const panes = view_paint.paint(layouts.PaneSlot, layouts.panes, layouts.Panes{
        .sidebar_focused = frame.focus == .sidebar,
        .sidebar_scroll = .{ .total = frame.file_tree.entries.len, .offset = frame.file_tree.scroll },
        .diff_scroll = .{ .total = frame.visual_rows.len, .offset = frame.navigation.scroll },
    }, win, theme);
    const cursor = frame.navigation.cursor;
    const buffer_index = if (cursor < frame.visual_rows.len) frame.visual_rows[cursor].buffer_index else 0;
    const path = if (frame.buffer.fileIndexForRow(buffer_index)) |index|
        frame.buffer.rows[frame.buffer.fileHeaderRow(index).?].file_header.path
    else
        "Diff";
    drawDiffPaneTitle(scratch, win, frame, path, review.preferences.scope, theme);
    const sidebar = childRect(win, panes.get(.sidebar).content);
    const diff_pane = childRect(win, panes.get(.diff).content);
    var diff_theme = theme;
    diff_theme.section_rule = if (frame.focus == .diff) theme.pane_border_focused else theme.pane_border;
    drawFileTree(sidebar, review.frame.file_tree, theme);
    drawVisualPane(scratch, diff_pane, review.frame.buffer, review.frame.visual_rows, diff_theme, review.frame.navigation);
    drawCodeHighlights(diff_pane, review.frame, theme);
    drawSearchRanges(diff_pane, review.frame, theme);
    joinSectionRules(win, panes.get(.diff).border, panes.get(.diff).content, review.frame.visual_rows, review.frame.navigation);
}

fn drawCodeHighlights(win: vaxis.Window, frame: @import("frame.zig").Projection, theme: Theme) void {
    const first = @min(frame.navigation.scroll, frame.visual_rows.len);
    const last = @min(first +| win.height, frame.visual_rows.len);
    for (frame.visual_rows[first..last], first..) |visual, index| {
        const card = switch (frame.buffer.rows[visual.buffer_index]) {
            .comment, .draft => |value| value,
            else => continue,
        };
        if (card.part != .code_body and card.part != .suggestion_body) continue;
        for (frame.code_highlights) |view| {
            if (std.meta.eql(view.owner, card.owner) and view.block == card.block_ordinal and std.mem.eql(u8, view.body, card.source.body())) {
                drawReviewCardSyntax(win, @intCast(index - first), card, view.spans, theme);
                break;
            }
        }
    }
}

fn drawReviewCardSyntax(win: vaxis.Window, row: u16, card: buffer_mod.ReviewCardRow, spans: []const @import("code_highlighting.zig").SourceSpan, theme: Theme) void {
    drawReviewCardSyntaxAt(win, row, card, card.contentColumn(), spans, theme);
}

fn drawReviewCardSyntaxAt(win: vaxis.Window, row: u16, card: buffer_mod.ReviewCardRow, start_column: usize, spans: []const @import("code_highlighting.zig").SourceSpan, theme: Theme) void {
    var col = start_column;
    for (card.segments) |segment| {
        if (segment.authored) for (spans) |span| {
            const start = @max(segment.source.start, span.source.start);
            const end = @min(segment.source.end, span.source.end);
            if (start >= end) continue;
            const fg = theme.captureColor(span.capture) orelse continue;
            const cells = mappedSegmentCells(segment, segment.source, start, end) orelse continue;
            const cell_start = col + cells.start;
            const width = cells.width;
            if (cell_start >= win.width) continue;
            for (cell_start..@min(cell_start +| width, win.width)) |column| {
                var cell = win.readCell(@intCast(column), row) orelse continue;
                cell.style.fg = fg;
                cell.style = theme.resolveStyle(cell.style);
                win.writeCell(@intCast(column), row, cell);
            }
        };
        col += vaxis.gwidth.gwidth(segment.text, .unicode);
    }
}

fn drawSearchRanges(win: vaxis.Window, frame: @import("frame.zig").Projection, theme: Theme) void {
    var ranges = frame.search_ranges;
    if (frame.search_ranges_sorted) {
        var low: usize = 0;
        var high = ranges.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (ranges[middle].visual_row < frame.navigation.scroll) low = middle + 1 else high = middle;
        }
        ranges = ranges[low..];
    }
    for (ranges) |range| {
        const active = if (frame.buffer_search_ranges and range.occurrence_index != null) frame.buffer_search_active == range.occurrence_index else range.active;
        if (frame.search_ranges_sorted and range.visual_row >= frame.navigation.scroll +| win.height) break;
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
                paintSearchCells(win, @intCast(screen_row), start, width, active, theme);
            },
            .comment => |card| drawReviewCardSearchRange(win, @intCast(screen_row), card, range, active, theme),
            .draft => |card| drawReviewCardSearchRange(win, @intCast(screen_row), card, range, active, theme),
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

fn drawReviewCardSearchRange(win: vaxis.Window, row: u16, card: buffer_mod.ReviewCardRow, range: @import("frame.zig").ProjectedSourceRange, active: bool, theme: Theme) void {
    drawReviewCardSearchRangeAt(win, row, card, card.contentColumn(), range, active, theme);
}

fn drawReviewCardSearchRangeAt(win: vaxis.Window, row: u16, card: buffer_mod.ReviewCardRow, column: usize, range: @import("frame.zig").ProjectedSourceRange, active: bool, theme: Theme) void {
    var col = column;
    for (card.segments) |segment| {
        const source = segment.definition_source orelse segment.source;
        const use_matches = range.source.start < segment.source.end and range.source.end > segment.source.start;
        const matched = if (segment.definition_source != null and use_matches) range.definition else if (segment.definition_source == null and range.definition == null) range.source else null;
        const start = if (matched) |value| @max(value.start, source.start) else 0;
        const end = if (matched) |value| @min(value.end, source.end) else 0;
        if (segment.authored and start < end) {
            if (mappedSegmentCells(segment, source, start, end)) |cells| paintSearchCells(win, row, col + cells.start, cells.width, active, theme);
        }
        col += vaxis.gwidth.gwidth(segment.text, .unicode);
    }
}

fn mappedSegmentCells(segment: @import("review_card.zig").Segment, source: @import("review_card.zig").SourceRange, start: usize, end: usize) ?struct { start: usize, width: usize } {
    const equal_length = !segment.atomic and source.end - source.start == segment.text.len;
    const lo = if (equal_length) start - source.start else 0;
    const hi = if (equal_length) end - source.start else segment.text.len;
    if (hi > segment.text.len) return null;
    return .{ .start = vaxis.gwidth.gwidth(segment.text[0..lo], .unicode), .width = vaxis.gwidth.gwidth(segment.text[lo..hi], .unicode) };
}

fn paintSearchCells(win: vaxis.Window, row: u16, start: usize, width: usize, active: bool, theme: Theme) void {
    if (start >= win.width) return;
    const end = start + @min(width, win.width - start);
    for (start..end) |column| {
        const cell = win.readCell(@intCast(column), row) orelse continue;
        var style = cell.style;
        style.bg = if (active) theme.search_active else theme.search_match;
        style = theme.resolveStyle(style);
        win.writeCell(@intCast(column), row, .{ .char = cell.char, .style = style });
    }
}

/// The DiffPane title is a control strip: the path and Scope, then the
/// published Selected Version targets. It sits on the top border that
/// view_paint.zig paints.
fn drawDiffPaneTitle(scratch: std.mem.Allocator, win: vaxis.Window, frame: @import("frame.zig").Projection, path: []const u8, scope: presentation.Scope, theme: Theme) void {
    const focused = frame.focus == .diff;
    const title_x = frame.panes.diff.x +| @min(frame.panes.diff.width, 2);
    const control_x = (if (frame.version_title_targets.old) |old| old.x else if (frame.version_title_targets.new) |new| new.x else frame.panes.diff.x +| frame.panes.diff.width -| 1) -| 1;
    const title_width = control_x -| title_x -| 1;
    if (title_width > 0) {
        const title = std.fmt.allocPrint(scratch, "{s} · {s}", .{ path, scopeLabel(scope) }) catch path;
        const style = if (focused) theme.pane_border_focused else theme.pane_border;
        view_paint.titleText(win, .{ .x = title_x, .y = frame.panes.diff.y, .width = title_width, .height = 1 }, title, style);
    }
    const buffer_index = if (frame.navigation.cursor < frame.visual_rows.len) frame.visual_rows[frame.navigation.cursor].buffer_index else 0;
    drawVersionTitleSegment(win, frame.version_title_targets.old, "h← OLD", frame.selected_version == .old, frame.buffer.hasFileVersion(buffer_index, .old), theme, focused);
    drawVersionTitleSegment(win, frame.version_title_targets.new, "NEW l→", frame.selected_version == .new, frame.buffer.hasFileVersion(buffer_index, .new), theme, focused);
    const old = frame.version_title_targets.old orelse frame.version_title_targets.new orelse return;
    const new = frame.version_title_targets.new orelse old;
    const x = @min(old.x, new.x);
    const end = @max(old.x + old.width, new.x + new.width);
    view_paint.titleGaps(win, .{ .x = x, .y = old.y, .width = end - x, .height = 1 }, if (focused) theme.pane_border_focused else theme.pane_border);
}

fn scopeLabel(scope: presentation.Scope) []const u8 {
    return switch (scope) {
        .changes => "Changes",
        .fetched => "Fetched",
        .whole => "WholeFile",
    };
}

fn drawVersionTitleSegment(win: vaxis.Window, target: ?@import("frame.zig").Rect, text: []const u8, selected: bool, available: bool, theme: Theme, focused: bool) void {
    const rect = target orelse return;
    var style = if (focused) theme.pane_border_focused else theme.pane_border;
    if (!available) style = theme.gutter;
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
        view_paint.join(win, outer.x, row, .{ .right = true });
        if (outer.width > 1) view_paint.join(win, outer.x + outer.width - 1, row, .{ .left = true });
    }
}

fn childRect(win: vaxis.Window, rect: @import("frame.zig").Rect) vaxis.Window {
    return win.child(.{ .x_off = rect.x, .y_off = rect.y, .width = rect.width, .height = rect.height });
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
    drawProjectedRows(scratch, win, buf, theme, nav);
}

fn drawVisualPane(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    buf: Buffer,
    visual_rows: []const @import("frame.zig").VisualRow,
    theme: Theme,
    nav: Nav,
) void {
    const sel = nav.selection() orelse .{ nav.cursor, nav.cursor };
    const path = if (nav.cursor < visual_rows.len) buf.activePath(scratch, visual_rows[nav.cursor].buffer_index) catch buffer_mod.ActivePath{} else buffer_mod.ActivePath{};
    const ancestry_theme = ancestryRowTheme(theme);
    var screen_row: u16 = 0;
    while (screen_row < win.height) : (screen_row += 1) {
        const index = nav.scroll + screen_row;
        if (index >= visual_rows.len) break;
        const visual_row = visual_rows[index];
        const row = buf.rows[visual_row.buffer_index];
        const selected = visual_row.kind != .status_placeholder and buf.hasFileVersion(visual_row.buffer_index, buf.selected_version) and visualRowSelected(visual_rows, sel, index, buf.selected_version);
        const row_theme = if (path.banded(buf, visual_row.buffer_index)) ancestry_theme else theme;
        drawVisualRow(scratch, win, screen_row, buf.layout, buf.selected_column, row, visual_row, row_theme, if (selected) buf.selected_version else null, .{ .path = path, .row = visual_row.buffer_index });
        if (path.indicator(visual_row.buffer_index)) |part| {
            var style = row_theme.reviewCardStyle(path.root().?.role, .body, .{});
            style.bg = (win.readCell(0, screen_row) orelse continue).style.bg;
            style = row_theme.resolveStyle(style);
            switch (part) {
                .top, .through => view_paint.anchorIndicator(win, screen_row, part == .top and !visual_row.continuation, style),
                .corner => view_paint.anchorCorner(win, screen_row, style),
            }
        }
    }
}

/// The row of a ReviewCard and the Active Path, which decide whether its
/// border, Title, and lines take the normal or the dim card border style.
const CardChrome = struct {
    path: buffer_mod.ActivePath = .{},
    row: usize = 0,
};

fn drawProjectedRows(scratch: std.mem.Allocator, win: vaxis.Window, buf: Buffer, theme: Theme, nav: Nav) void {
    const rows = buf.rows;
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
        const active = buf.hasFileVersion(index, buf.selected_version) and (selected or index == nav.cursor);
        if (row == .line_pair) {
            drawLinePair(scratch, win, screen_row, row.line_pair, theme, if (active) buf.selected_version else null);
            drawSelectedColumnEdge(win, screen_row, buf.selected_column, theme);
        } else {
            const eligible = row != .line or (if (buf.selected_version == .old) row.line.oldNo() != null else row.line.newNo() != null);
            const row_theme = if (active and eligible and row != .status_placeholder) cursorRowTheme(theme) else theme;
            drawRow(scratch, win, screen_row, buf.layout, buf.selected_column, row, row_theme, .{});
        }
    }
}

fn visualRowSelected(rows: []const @import("frame.zig").VisualRow, selection: [2]usize, index: usize, version: buffer_mod.SelectedVersion) bool {
    if (index >= rows.len) return false;
    const candidate = rows[index];
    if (candidate.owner != .line) return index >= selection[0] and index <= selection[1];
    const line = @import("frame.zig").selectedSource(candidate, version) orelse return false;
    var selected = selection[0];
    while (selected <= selection[1] and selected < rows.len) : (selected += 1) {
        if (@import("frame.zig").selectedSource(rows[selected], version) == line) return true;
    }
    return false;
}

fn drawVisualRow(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, layout: buffer_mod.Layout, selected_column: ?buffer_mod.SelectedColumn, row: Row, visual_row: @import("frame.zig").VisualRow, base_theme: Theme, highlighted_version: ?buffer_mod.SelectedVersion, chrome: CardChrome) void {
    if (layout == .side_by_side and visual_row.halves != null) {
        drawVisualLinePair(scratch, win, r, visual_row.halves.?, row.line_pair, base_theme, highlighted_version);
        drawSelectedColumnEdge(win, r, selected_column, base_theme);
        return;
    }
    if (row == .line_pair) {
        drawLinePair(scratch, win, r, row.line_pair, base_theme, highlighted_version);
        drawSelectedColumnEdge(win, r, selected_column, base_theme);
        return;
    }
    const theme = if (highlighted_version != null) cursorRowTheme(base_theme) else base_theme;
    if (row != .line or layout != .unified) {
        drawRow(scratch, win, r, layout, selected_column, row, theme, chrome);
        return;
    }
    const line_row = row.line;
    const style = theme.lineStyle(line_row.line.kind);
    fillRow(win, r, style);
    if (!visual_row.continuation) {
        drawUnifiedGutter(win, r, line_row.oldNo(), line_row.newNo(), gutterStyle(theme, style));
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
    return tintedRowTheme(theme, Theme.cursorBg);
}

fn ancestryRowTheme(theme: Theme) Theme {
    return tintedRowTheme(theme, Theme.ancestryBg);
}

fn tintedRowTheme(theme: Theme, comptime tint: fn (Theme, vaxis.Cell.Color) vaxis.Cell.Color) Theme {
    var result = theme;
    inline for (.{
        "context",               "added",       "removed",      "added_emphasis",  "removed_emphasis",
        "gutter",                "file_header", "hunk_header",  "fold",            "comment",
        "comment_reply",         "suggestion",  "draft",        "draft_reply",     "outcome_unknown",
        "outcome_unknown_reply", "section",     "section_rule", "card_border_dim",
    }) |field| {
        var style = @field(theme, field);
        style.bg = tint(theme, style.bg);
        @field(result, field) = theme.resolveStyle(style);
    }
    result.code_background = tint(theme, theme.code_background);
    return result;
}

/// The line numbers of a Diff Line: the muted gutter digits on the Line's
/// band, so an added or removed band starts at the left edge of its row.
fn gutterStyle(theme: Theme, band: vaxis.Style) vaxis.Style {
    var style = theme.gutter;
    style.bg = band.bg;
    return style;
}

/// Gutter is two 4-wide line-number columns; body text starts after it.
const gutter_cols: u16 = @intCast(@import("frame.zig").unified_gutter_cols);

fn drawRow(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, layout: buffer_mod.Layout, selected_column: ?buffer_mod.SelectedColumn, row: Row, theme: Theme, chrome: CardChrome) void {
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
            _ = win.printSegment(.{ .text = hunk.header, .style = theme.hunk_header }, .{ .row_offset = r, .col_offset = if (layout == .side_by_side) anchor_cols else 0, .wrap = .none });
        },
        .status_placeholder => |value| drawStatusPlaceholder(scratch, win, r, layout, value, theme),
        .line => |lr| {
            const ln = lr.line;
            const style = theme.lineStyle(ln.kind);
            fillRow(win, r, style);

            drawUnifiedGutter(win, r, lr.oldNo(), lr.newNo(), gutterStyle(theme, style));
            drawLineBody(scratch, win, r, gutter_cols, lr, theme, style);
        },
        .line_pair => |pair| drawLinePair(scratch, win, r, pair, theme, null),
        .disclosure => |value| drawDisclosure(scratch, win, r, value, theme),
        .comment, .draft => |card| drawReviewCard(scratch, win, r, card, theme, chrome),
        .snapshot => |snapshot| drawSnapshot(win, r, snapshot, theme),
        .section => |sec| drawSection(scratch, win, r, sec, theme),
    }
    // A ReviewCard spans both columns, so the column edge stays off its rows.
    if (layout == .side_by_side and row != .comment and row != .draft) drawSelectedColumnEdge(win, r, selected_column, theme);
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
    if (half > 0) _ = win.child(.{ .x_off = anchor_cols, .y_off = row, .width = half - anchor_cols, .height = 1 }).printSegment(.{ .text = old, .style = theme.resolveStyle(old_style) }, .{ .wrap = .none });
    if (right_x < win.width) _ = win.child(.{ .x_off = right_x, .y_off = row, .width = win.width - right_x, .height = 1 }).printSegment(.{ .text = new, .style = theme.resolveStyle(new_style) }, .{ .wrap = .none });
}

fn drawSelectedColumnEdge(win: vaxis.Window, row: u16, selected: ?buffer_mod.SelectedColumn, theme: Theme) void {
    const column = selected orelse return;
    const edge: u16 = if (column.version == .old) 0 else win.width / 2;
    const current = win.readCell(edge, row) orelse return;
    win.writeCell(edge, row, .{
        .char = .{ .grapheme = if (column.inner_gutter_edge == .right) "▐" else "▌", .width = 1 },
        .style = theme.resolveStyle(.{ .fg = theme.accent, .bg = current.style.bg, .bold = true }),
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
        const left = win.child(.{ .x_off = anchor_cols, .y_off = row, .width = half - anchor_cols, .height = 1 });
        _ = left.printSegment(.{ .text = statusPlaceholderText(scratch, .old, status), .style = theme.section }, .{ .wrap = .none });
    } else if (value.file.status == .added) {
        const left = win.child(.{ .x_off = anchor_cols, .y_off = row, .width = half - anchor_cols, .height = 1 });
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
fn drawLinePair(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, pair: buffer_mod.LinePair, theme: Theme, highlighted_version: ?buffer_mod.SelectedVersion) void {
    const half = win.width / 2;
    if (half == 0) return;
    const right_x = half + 1; // divider column sits at `half`
    const right_w = if (win.width > right_x) win.width - right_x else 0;
    fillRow(win, r, theme.context);

    const left = win.child(.{ .x_off = 0, .y_off = r, .width = half, .height = 1 });
    drawHalf(scratch, left, pair.left, if (highlighted_version == .old and pair.left != null) cursorRowTheme(theme) else theme, .old);
    if (right_w > 0) {
        const right = win.child(.{ .x_off = right_x, .y_off = r, .width = right_w, .height = 1 });
        drawHalf(scratch, right, pair.right, if (highlighted_version == .new and pair.right != null) cursorRowTheme(theme) else theme, .new);
    }
}

fn drawVisualLinePair(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, halves: @import("frame.zig").Halves, pair: LinePair, theme: Theme, highlighted_version: ?buffer_mod.SelectedVersion) void {
    const half = win.width / 2;
    if (half == 0) return;
    const right_x = half + @as(u16, @intCast(@import("frame.zig").side_divider_cols));
    const right_w = if (win.width > right_x) win.width - right_x else 0;
    fillRow(win, r, theme.context);
    drawVisualHalf(scratch, win.child(.{ .x_off = 0, .y_off = r, .width = half, .height = 1 }), halves.left, pair.left, if (highlighted_version == .old and halves.left != null) cursorRowTheme(theme) else theme, .old);
    if (right_w > 0) drawVisualHalf(scratch, win.child(.{ .x_off = right_x, .y_off = r, .width = right_w, .height = 1 }), halves.right, pair.right, if (highlighted_version == .new and halves.right != null) cursorRowTheme(theme) else theme, .new);
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
        drawSideGutter(win, 0, no, gutterStyle(theme, style));
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
    drawSideGutter(win, 0, no, gutterStyle(theme, style));
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
        segs[index] = .{ .text = run.text[overlap_start - offset .. overlap_end - offset], .style = theme.resolveStyle(run_style) };
        index += 1;
        offset = run_end;
    }
    _ = win.print(segs, .{ .row_offset = r, .col_offset = body_col, .wrap = .none });
}

/// One row of a bordered ReviewCard. The cells left of its left border keep the
/// Theme base background. view_paint.cardEdge paints the border and Titles. A
/// card on the Active Path takes the border style of its role, every other
/// card the dim one.
fn drawReviewCard(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, card: buffer_mod.ReviewCardRow, theme: Theme, chrome: CardChrome) void {
    var base = theme.reviewCardStyle(card.role, card.part, .{});
    if (card.block_kind == .heading) base.bold = true;
    const dim = theme.resolveStyle(theme.card_border_dim);
    const on_path = chrome.path.holds(card.card);
    const border = if (card.resolved_thread) theme.resolvedThreadStyle() else if (on_path) theme.reviewCardStyle(card.role, .body, .{}) else dim;
    var title = base;
    if (card.resolved_thread) title = theme.resolvedThreadStyle() else if (!on_path) title.fg = dim.fg;
    const left = card.indent;
    const right = card.rightBorderColumn();
    const col: u16 = @intCast(card.contentColumn());
    fillRow(win, r, theme.resolveStyle(theme.context));
    fillCells(win, r, left, right + 1, if (card.code_area != null) border else base);
    if (card.code_area) |area| fillCells(win, r, col + area.column, col + area.column + area.width, base);
    const edge: view_paint.CardEdge = switch (card.part) {
        .header => .{ .top = card.text() },
        .disclosure_footer => .{ .bottom = card.text() },
        .bottom => .{ .bottom = "" },
        .body, .code_body, .suggestion_label, .suggestion_body => .side,
    };
    view_paint.cardEdge(win, r, left, right, edge, border, title);
    // A Reply joins the border directly above its top-left corner.
    // A Title cell above the corner holds no line, so it stays.
    // The join cell keeps the style of the border that holds it.
    if (card.part == .header and card.depth > 0) {
        if (r > 0) view_paint.join(win, left, r - 1, .{ .down = true });
        view_paint.join(win, left, r, .{ .up = true });
    }
    // The line from a card to its later sibling: `├` at the card's bottom-left
    // corner, then `│` at that column on every row between them.
    if (card.sibling_below) view_paint.join(win, left, r, .{ .down = true });
    var rails = card.rails;
    while (rails) |rail| : (rails = rail.next) {
        const target = chrome.path.railTarget(chrome.row, rail.*);
        view_paint.rail(win, rail.column, r, if (target) |path_card| theme.reviewCardStyle(path_card.role, .body, .{}) else dim);
    }
    if (card.part.isBorder() or card.segments.len == 0) return;
    const segments = scratch.alloc(vaxis.Segment, card.segments.len) catch return;
    var links: TerminalLinks = .{ .scratch = scratch, .owner = card.owner };
    var column: usize = 0;
    for (card.segments, 0..) |segment, index| {
        const prefix = if (card.code_area) |area| column < area.column else false;
        segments[index] = .{
            .text = segment.text,
            .style = theme.reviewCardStyle(card.role, if (prefix) .body else card.part, segment.marks),
            .link = links.get(segment.link),
        };
        column += terminal_cell_metrics.width(segment.text);
    }
    _ = win.print(segments, .{ .row_offset = r, .col_offset = col, .wrap = .none });
}

fn fillCells(win: vaxis.Window, row: u16, start: usize, end: usize, style: vaxis.Style) void {
    const first = @min(start, win.width);
    const last = @min(end, win.width);
    if (last <= first) return;
    win.child(.{ .x_off = @intCast(first), .y_off = row, .width = @intCast(last - first), .height = 1 }).fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
}

fn fillReviewCardBackground(win: vaxis.Window, row: u16, card: buffer_mod.ReviewCardRow, column: usize, normal: vaxis.Style, code: vaxis.Style) void {
    fillRow(win, row, normal);
    const area = card.code_area orelse return;
    const start = @min(column + area.column, win.width);
    const width = @min(area.width, win.width - start);
    if (width == 0) return;
    win.child(.{ .x_off = @intCast(start), .y_off = row, .width = @intCast(width), .height = 1 }).fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = code,
    });
}

const TerminalLinks = struct {
    scratch: std.mem.Allocator,
    owner: @import("review_card.zig").Owner,
    start: ?usize = null,
    link: vaxis.Cell.Hyperlink = .{},

    fn get(self: *TerminalLinks, target: ?@import("review_body.zig").LinkTarget) vaxis.Cell.Hyperlink {
        const link = target orelse return .{};
        if (self.start == link.start) return self.link;
        self.start = link.start;
        self.link = .{};
        for (link.destination) |byte| if (byte <= 0x20 or byte == 0x7f) return .{};
        // Relative destinations stay visible without guessing a Repository base URL.
        _ = std.Uri.parse(link.destination) catch return .{};
        const id = switch (self.owner) {
            .comment => |value| value,
            .draft => |value| value,
        };
        const params = std.fmt.allocPrint(self.scratch, "id=bbr-{s}-{d}-{d}", .{ @tagName(self.owner), id, link.start }) catch return .{};
        self.link = .{ .uri = link.destination, .params = params };
        return self.link;
    }
};

fn drawDisclosure(scratch: std.mem.Allocator, win: vaxis.Window, r: u16, value: buffer_mod.Disclosure, theme: Theme) void {
    const style = switch (value.kind) {
        .resolved_thread => theme.resolvedThreadStyle(),
        .fold => theme.fold,
        else => theme.section,
    };
    fillRow(win, r, style);
    const glyph: []const u8 = if (value.expanded) "▾" else "▸";
    const text = switch (value.kind) {
        .resolved_thread => std.fmt.allocPrint(scratch, "{s} ✓ Resolved · {s} · {d} replies", .{ glyph, value.author, value.count }) catch glyph,
        .fold => std.fmt.allocPrint(scratch, "{s} ⋯ {d} unchanged lines", .{ glyph, value.count }) catch glyph,
        .outdated => if (value.path.len > 0)
            std.fmt.allocPrint(scratch, "{s} Outdated · {s} · {d} threads", .{ glyph, value.path, value.count }) catch glyph
        else
            std.fmt.allocPrint(scratch, "{s} Outdated · {d} threads", .{ glyph, value.count }) catch glyph,
        .opposite_version => std.fmt.allocPrint(scratch, "{s} {s} · {d} threads", .{ glyph, value.path, value.count }) catch glyph,
        .review_card => unreachable,
    };
    if (value.kind == .resolved_thread) {
        view_paint.titledRule(win, r, anchor_cols, win.width -| 1, text, style);
    } else {
        _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = r, .col_offset = gutter_cols, .wrap = .none });
    }
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

/// Draw the open List Overlay as a centered modal: a query row, then one row
/// per ranked match, scrolled to keep the selected row visible. `scratch`
/// outlives render. A Command Palette row whose Action `availability` refuses
/// is greyed.
pub fn drawListOverlay(
    scratch: std.mem.Allocator,
    win: vaxis.Window,
    overlay: *const ListOverlay,
    availability: presentation.ActionAvailability,
    configured_theme: ThemeId,
    files: []const bbr.diff.File,
    theme: Theme,
) void {
    const rects = view_paint.paint(layouts.ListSlot, layouts.listOverlay, layouts.ListOverlay{ .box = overlay.box(), .title = overlay.title() }, win, theme);
    if (rects.get(.surface).border.isEmpty()) return;
    const query = childRect(win, rects.get(.query).content);
    const entries = childRect(win, rects.get(.entries).content);
    const list = overlay.list();

    const prompt = std.fmt.allocPrint(scratch, "› {s}", .{list.query()}) catch "›";
    _ = query.printSegment(.{ .text = prompt, .style = theme.picker }, .{ .wrap = .none });

    if (listPlaceholder(scratch, overlay, files)) |message| {
        _ = entries.printSegment(.{ .text = message, .style = theme.picker }, .{ .wrap = .none });
        return;
    }

    const matches = list.matches();
    const top = list.scrollTop(entries.height);
    var row: u16 = 0;
    while (row < entries.height) : (row += 1) {
        const match_index = top + row;
        if (match_index >= matches.len) break;
        const selected = match_index == list.selected;
        const style = if (selected) theme.picker_selected else theme.picker;
        fillRow(entries, row, style);
        _ = entries.print(listRow(scratch, overlay, matches[match_index], selected, style, availability, configured_theme, files, theme), .{ .row_offset = row, .wrap = .none });
    }
}

/// The list-area message when there are no rows to draw, or null.
fn listPlaceholder(scratch: std.mem.Allocator, overlay: *const ListOverlay, files: []const bbr.diff.File) ?[]const u8 {
    return switch (overlay.*) {
        .pull_request_picker => |*picker| if (picker.loading())
            std.fmt.allocPrint(scratch, "{s} Loading pull requests…", .{picker.spinnerGlyph()}) catch "  Loading pull requests…"
        else if (picker.prs().len == 0) "  no open pull requests" else null,
        .file_finder => |*finder| if (finder.list.matches().len > 0) null else if (files.len == 0) "  no changed files" else "  no matching files",
        .command_palette => |*palette| if (palette.list.matches().len > 0) null else "  no matching commands",
        .theme => |*theme_overlay| if (theme_overlay.list.matches().len > 0) null else "  no matching Themes",
    };
}

fn listRow(
    scratch: std.mem.Allocator,
    overlay: *const ListOverlay,
    item: usize,
    selected: bool,
    style: vaxis.Style,
    availability: presentation.ActionAvailability,
    configured_theme: ThemeId,
    files: []const bbr.diff.File,
    theme: Theme,
) []const vaxis.Segment {
    const marker: []const u8 = if (selected) "▸ " else "  ";
    const text = switch (overlay.*) {
        .command_palette => |*palette| {
            const command = palette.command(item);
            var row_style = style;
            if (!availability.available(command.action)) row_style.fg = theme.gutter.fg;
            var title_style = row_style;
            title_style.bold = true;
            row_style.bold = false;
            const reason = sourceRefusalLabel(availability, command.action);
            const description = if (reason) |label|
                std.fmt.allocPrint(scratch, "  {s} ({s})", .{ command.description, label }) catch command.description
            else
                std.fmt.allocPrint(scratch, "  {s}", .{command.description}) catch command.description;
            const segments = scratch.alloc(vaxis.Segment, 3) catch return &.{};
            segments[0] = .{ .text = marker, .style = row_style };
            segments[1] = .{ .text = command.title, .style = title_style };
            segments[2] = .{ .text = description, .style = row_style };
            return segments;
        },
        .pull_request_picker => |*picker| blk: {
            const pr = picker.prs()[item];
            break :blk std.fmt.allocPrint(scratch, "{s}#{d}  {s}  ({s})", .{ marker, pr.id, pr.title, pr.source_branch }) catch pr.title;
        },
        .file_finder => blk: {
            const path = files[item].displayPath();
            break :blk std.fmt.allocPrint(scratch, "{s}{s}", .{ marker, path }) catch path;
        },
        .theme => blk: {
            const id = ThemeId.at(item);
            const suffix: []const u8 = if (id == configured_theme) "  (configured)" else "";
            break :blk std.fmt.allocPrint(scratch, "{s}{s}{s}", .{ marker, id.name(), suffix }) catch id.name();
        },
    };
    const segments = scratch.alloc(vaxis.Segment, 1) catch return &.{};
    segments[0] = .{ .text = text, .style = style };
    return segments;
}

/// Draw only the immutable Review Search projection. The same rectangles give
/// Presentation its list and Preview pointer targets.
pub fn drawReviewSearch(scratch: std.mem.Allocator, win: vaxis.Window, projection: presentation.ReviewSearchProjection, theme: Theme) void {
    const geometry = projection.geometry;
    // A terminal shrink can precede publication of the replacement geometry.
    // Keep the shared paint and pointer geometry intact until it fits again.
    if (geometry.rect.width > win.width -| geometry.rect.x or geometry.rect.height > win.height -| geometry.rect.y) return;
    const full_status = std.fmt.allocPrint(scratch, "{d}/{d} matches · {d} candidates{s}", .{
        if (projection.selected) |index| index + 1 else @as(usize, 0), projection.results.len, projection.candidate_count,
        if (projection.pending) " · searching" else "",
    }) catch "";
    const short_status = std.fmt.allocPrint(scratch, "{d} matches · {d} candidates", .{ projection.results.len, projection.candidate_count }) catch "";
    const tiny_status = std.fmt.allocPrint(scratch, "{d}/{d}", .{ projection.results.len, projection.candidate_count }) catch "";
    const box_width = geometry.rect.width;
    const status_label = if (searchCellWidth(full_status) + 6 <= box_width) full_status else if (searchCellWidth(short_status) + 6 <= box_width) short_status else if (searchCellWidth(tiny_status) + 6 <= box_width) tiny_status else "";
    const results_span = if (geometry.landscape) geometry.divider - geometry.body.x else geometry.body.width;
    const list_total = if (projection.results.len > 0) projection.results.len else projection.files.len;
    const rects = view_paint.paint(layouts.SearchSlot, layouts.reviewSearch, layouts.ReviewSearch{
        .status = status_label,
        .results_title = if (results_span > searchCellWidth("Results · Position") + 4) "Results · Position" else "Position",
        .list_scroll = .{ .total = list_total, .offset = projection.list_scroll },
    }, win, theme);
    const input = childRect(win, rects.get(.query).content);
    const query = std.fmt.allocPrint(scratch, "> {s}", .{projection.query}) catch "> ";
    _ = input.printSegment(.{ .text = query, .style = theme.picker }, .{ .wrap = .none });
    const list = childRect(win, rects.get(.list).content);
    const preview = childRect(win, rects.get(.preview).content);
    const header = childRect(win, rects.get(.header).content);
    if (projection.results.len == 0 and list.height > 0) {
        for (0..list.height) |row| {
            const index = projection.list_scroll + row;
            if (index >= projection.files.len or index >= projection.content_statuses.len or index >= projection.highlight_statuses.len) break;
            const file = projection.files[index];
            const content = projection.content_statuses[index];
            const status = projection.highlight_statuses[index];
            const label = std.fmt.allocPrint(scratch, "{s}  old {s} · new {s}", .{
                shortSearchPath(scratch, file.displayPath(), @max(list.width / 2, 1)),
                sourceContentLabel(scratch, content.old, status.old),
                sourceContentLabel(scratch, content.new, status.new),
            }) catch file.displayPath();
            _ = list.printSegment(.{ .text = label, .style = theme.picker }, .{ .row_offset = @intCast(row), .wrap = .none });
        }
        if (projection.files.len == 0)
            _ = list.printSegment(.{ .text = if (projection.pending) "Searching ReviewBodies…" else "No matching occurrence", .style = theme.picker }, .{ .wrap = .none });
    }
    for (0..list.height) |row_index| {
        const index = projection.list_scroll + row_index;
        if (index >= projection.results.len) break;
        const result = projection.results[index];
        const selected = projection.selected == index;
        const style = if (selected) theme.picker_selected else theme.picker;
        fillRow(list, @intCast(row_index), style);
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
        const available = list.width -| 2;
        const filename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        const show_position = available > position.len + 2 and searchCellWidth(filename) <= available - position.len;
        const location = shortSearchPath(scratch, path, available -| (if (show_position) position.len else @as(usize, 0)));
        const suffix = if (show_position) position else "";
        const row_text = std.fmt.allocPrint(scratch, "{s}{s}{s}", .{ if (selected) "▸ " else "  ", location, suffix }) catch location;
        _ = list.printSegment(.{ .text = row_text, .style = style }, .{ .row_offset = @intCast(row_index), .wrap = .none });
    }
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
        if (preview.height > 0) {
            var result = projection.results[selected];
            result.code_highlights = projection.code_highlights;
            drawReviewSearchPreview(scratch, preview, result, projection.preview_scroll, theme, projection.cell_metrics orelse terminal_cell_metrics);
        }
    }
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
            const style = theme.picker;
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
                    segments.append(scratch, .{ .text = line[cursor..segment_end], .style = theme.resolveStyle(segment_style) }) catch return;
                    cursor = segment_end;
                }
                run_start = run_end;
            }
            if (segments.items.len == 0) segments.append(scratch, .{ .text = "", .style = style }) catch return;
            _ = preview.print(segments.items, .{ .row_offset = row, .wrap = .none });
            if (line_number == matched_line) tintReviewSearchPreviewRow(preview, row, theme);
            row += 1;
        }
        start = end + @intFromBool(end < text.len);
    }
}

fn tintReviewSearchPreviewRow(win: vaxis.Window, row: u16, theme: Theme) void {
    for (0..win.width) |column| {
        var cell = win.readCell(@intCast(column), row) orelse continue;
        if (std.meta.eql(cell.style.bg, theme.search_active)) continue;
        cell.style.bg = theme.cursorBg(cell.style.bg);
        cell.style = theme.resolveStyle(cell.style);
        win.writeCell(@intCast(column), row, cell);
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

test "mention labels and filtered emoji paint in Review Search previews" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: @import("review_body.zig").MentionNames = .empty;
    try names.put(a, "id", "@Ada");
    const raw = "@{id} :pray:{: data-emoji-id='1f64f' data-emoji-text='🙏' }";
    const ranges = [_]@import("search.zig").Range{.{ .start = 0, .end = 5 }};
    const result: presentation.ReviewSearchResult = .{
        .mention_names = &names,
        .kind = "COMMENT",
        .source = "Bo",
        .body = raw,
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } }, .ranges = @constCast(&ranges), .column = 1, .candidate_scalars = 4, .corpus_order = 0, .session_epoch = 1 },
    };
    var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    screen.width_method = .unicode;
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
        for ("@Ada", 0..) |byte, col| {
            const cell = win.readCell(@intCast(col), 0).?;
            try testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
            try testing.expectEqual(theme.search_active, cell.style.bg);
            try testing.expectEqual(theme.resolveStyle(.{ .fg = theme.accent, .bg = theme.search_active }).fg, cell.style.fg);
            try testing.expect(cell.style.bold);
        }
        try testing.expectEqualStrings("🙏", win.readCell(5, 0).?.char.grapheme);
        try testing.expect(!win.readCell(5, 0).?.style.bold);
        for (7..40) |col| try testing.expectEqualStrings(" ", win.readCell(@intCast(col), 0).?.char.grapheme);
    }
}

fn drawReviewSearchPreview(scratch: std.mem.Allocator, win: vaxis.Window, result: presentation.ReviewSearchResult, scroll: usize, theme: Theme, metrics: @import("cell_metrics.zig").CellMetrics) void {
    const owner = result.occurrence.location.review_body;
    const card_mod = @import("review_card.zig");
    const body = card_mod.ReviewBody.parseWithMentions(scratch, result.body, result.mention_names) catch return;
    const comment: bbr.review.Comment = .{ .id = if (owner.owner == .comment) owner.owner.comment else 0, .author = result.source, .body = result.body };
    const draft: bbr.review.Draft = .{ .local_id = if (owner.owner == .draft) owner.owner.draft else 0, .kind = .comment, .body = result.body };
    const rows = card_mod.projectPreview(scratch, body, .{
        .owner = if (owner.owner == .draft) .{ .draft = owner.owner.draft } else .{ .comment = owner.owner.comment },
        .source = if (owner.owner == .draft) .{ .draft = &draft } else .{ .comment = &comment },
        .role = .comment,
        .header = "",
        .content_width = win.width,
        .metrics = metrics,
        .collapsed_rows = 0,
    }, scroll, win.height) catch return;
    var row: u16 = 0;
    for (rows) |card| {
        const code = card.part == .code_body or card.part == .suggestion_body or card.part == .suggestion_label;
        fillReviewCardBackground(win, row, card, 0, if (code and card.code_area == null) theme.reviewCardStyle(card.role, card.part, .{}) else theme.picker, theme.reviewCardStyle(card.role, card.part, .{}));
        const segments = scratch.alloc(vaxis.Segment, card.segments.len) catch return;
        var links: TerminalLinks = .{ .scratch = scratch, .owner = card.owner };
        var column: usize = 0;
        var matched_row = false;
        for (card.segments, 0..) |segment, index| {
            const prefix = if (card.code_area) |area| column < area.column else false;
            var style = theme.reviewCardStyle(card.role, if (prefix) .body else card.part, segment.marks);
            if (!code or prefix) style.bg = theme.picker.bg;
            const source = segment.definition_source orelse segment.source;
            var use_matches = false;
            for (result.occurrence.ranges) |range| use_matches = use_matches or (range.start < segment.source.end and range.end > segment.source.start);
            const matched = if (segment.definition_source != null and use_matches) result.occurrence.definition_ranges else if (segment.definition_source == null and result.occurrence.definition_ranges.len == 0) result.occurrence.ranges else &.{};
            if (segment.authored) for (matched) |range| {
                if (range.start < source.end and range.end > source.start) {
                    style.bg = theme.search_active;
                    matched_row = true;
                    break;
                }
            };
            segments[index] = .{ .text = segment.text, .style = theme.resolveStyle(style), .link = links.get(segment.link) };
            column += metrics.width(segment.text);
        }
        _ = win.print(segments, .{ .row_offset = row, .wrap = .none });
        if (card.part == .code_body or card.part == .suggestion_body) for (result.code_highlights) |view| {
            if (std.meta.eql(view.owner, card.owner) and view.block == card.block_ordinal and std.mem.eql(u8, view.body, result.body)) {
                drawReviewCardSyntaxAt(win, row, card, 0, view.spans, theme);
                break;
            }
        };
        // vaxis prints the leading cell of a wide grapheme. Paint the complete
        // terminal range, including continuation cells, just as ReviewCards do.
        for (result.occurrence.ranges) |range| {
            if (result.occurrence.definition_ranges.len == 0) {
                drawReviewCardSearchRangeAt(win, row, card, 0, .{ .visual_row = row, .relation = .neutral, .source = range, .row = range, .active = true }, true, theme);
            } else {
                for (result.occurrence.definition_ranges) |definition| {
                    drawReviewCardSearchRangeAt(win, row, card, 0, .{ .visual_row = row, .relation = .neutral, .source = range, .definition = definition, .row = range, .active = true }, true, theme);
                }
            }
        }
        if (matched_row) tintReviewSearchPreviewRow(win, row, theme);
        row += 1;
    }
}

pub const terminal_cell_metrics: @import("cell_metrics.zig").CellMetrics = .{ .ptr = &metrics_context, .vtable = &metrics_vtable };
const metrics_context: u8 = 0;
const metrics_vtable: @import("cell_metrics.zig").CellMetrics.VTable = .{ .next = nextVaxisGrapheme, .width = widthVaxisText };
fn nextVaxisGrapheme(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
    var iterator = vaxis.unicode.graphemeIterator(text);
    const grapheme = iterator.next() orelse return .{ .byte_len = 1, .cell_width = 1 };
    return .{ .byte_len = grapheme.len, .cell_width = vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode) };
}

fn widthVaxisText(_: *const anyopaque, text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}

test "M23 emoji ReviewCards and Preview paint complete sequences with shared terminal columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const examples = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = ":v:", .text = "✌️" },
        .{ .name = ":heart:", .text = "❤️" },
        .{ .name = ":one:", .text = "1️⃣" },
        .{ .name = ":flag_gb:", .text = "🇬🇧" },
        .{ .name = ":woman_technologist:", .text = "👩‍💻" },
        .{ .name = ":woman_technologist::skin-tone-2:", .text = "👩🏻‍💻" },
    };
    for (examples) |example| {
        const raw = try std.fmt.allocPrint(a, "**{s}** x", .{example.name});
        const ranges = [_]@import("search.zig").Range{.{ .start = 3, .end = 4 }};
        const result: presentation.ReviewSearchResult = .{
            .kind = "COMMENT",
            .source = "Ada",
            .body = raw,
            .scope = .review,
            .scope_state = .current,
            .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } }, .ranges = @constCast(&ranges), .column = 3, .candidate_scalars = 1, .corpus_order = 0, .session_epoch = 1 },
        };
        const cells = terminal_cell_metrics.width(example.text);
        var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = @intCast(cells + 12), .x_pixel = 0, .y_pixel = 0 });
        screen.width_method = .unicode;
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        const draft: bbr.review.Draft = .{ .local_id = 1, .kind = .comment, .body = raw };
        const card_mod = @import("review_card.zig");
        const body = try card_mod.ReviewBody.parse(a, raw);
        for (@import("theme.zig").builtins) |builtin| {
            const theme = builtin.value;
            drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
            try testing.expectEqualStrings(example.text, win.readCell(0, 0).?.char.grapheme);
            try testing.expectEqualStrings("x", win.readCell(@intCast(cells + 1), 0).?.char.grapheme);
            for (0..cells) |col| {
                const style = win.readCell(@intCast(col), 0).?.style;
                try testing.expectEqual(theme.search_active, style.bg);
            }
            try testing.expectEqual(theme.markdown_bold, win.readCell(0, 0).?.style.fg);
            try testing.expect(win.readCell(0, 0).?.style.bold);
            inline for (std.meta.tags(card_mod.CardRole)) |role| {
                const is_draft = switch (role) {
                    .draft, .draft_reply, .outcome_unknown, .outcome_unknown_reply => true,
                    else => false,
                };
                const rows = try card_mod.project(a, body, .{ .owner = if (is_draft) .{ .draft = 1 } else .{ .comment = 1 }, .source = if (is_draft) .{ .draft = &draft } else .{ .comment = &comment }, .role = role, .header = "Ada", .content_width = cells + 3, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
                drawReviewCard(a, win, 1, rows[1], theme, .{});
                drawReviewCardSearchRange(win, 1, rows[1], .{ .visual_row = 1, .relation = .neutral, .source = ranges[0], .row = ranges[0], .active = true }, true, theme);
                try testing.expectEqualStrings(example.text, win.readCell(2, 1).?.char.grapheme);
                try testing.expectEqualStrings("x", win.readCell(@intCast(2 + cells + 1), 1).?.char.grapheme);
                for (2..2 + cells) |col| {
                    const style = win.readCell(@intCast(col), 1).?.style;
                    try testing.expectEqual(theme.search_active, style.bg);
                }
                try testing.expectEqual(theme.markdown_bold, win.readCell(2, 1).?.style.fg);
                try testing.expect(win.readCell(2, 1).?.style.bold);
            }
        }
    }
}

test "M23 tables Preview and ReviewCards share layouts and Theme styles as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "| **Name** | *State* |\n| :--- | ---: |\n| ~~Ada~~ | `Ready` |";
    const ready = std.mem.indexOf(u8, raw, "Ready").?;
    const ranges = [_]@import("search.zig").Range{.{ .start = ready, .end = ready + 5 }};
    const result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = raw,
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 3 } }, .ranges = @constCast(&ranges), .column = 14, .candidate_scalars = 5, .corpus_order = 0, .session_epoch = 1 },
    };
    for ([_]u16{ 40, 7 }) |width| {
        var screen = try vaxis.Screen.init(a, .{ .rows = 12, .cols = width + 4, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        const preview = win.child(.{ .width = width });
        const card_mod = @import("review_card.zig");
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        const rows = try card_mod.project(a, try card_mod.ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = width, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
        const expected: []const []const u8 = if (width == 40) &.{ "Name │ State", "─────┼──────", "Ada  │ Ready" } else &.{ "Name", "State", "Name: ", "Ada", "State: ", "Ready" };
        for (@import("theme.zig").builtins) |builtin| {
            const theme = builtin.value;
            drawReviewSearchPreview(a, preview, result, 0, theme, terminal_cell_metrics);
            for (expected, 0..) |text, row| {
                var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
                var col: u16 = 0;
                while (iterator.nextCodepointSlice()) |grapheme| : (col += 1) try testing.expectEqualStrings(grapheme, win.readCell(col, @intCast(row)).?.char.grapheme);
            }
            const state_row: u16 = if (width == 40) 0 else 1;
            const ada_row: u16 = if (width == 40) 2 else 3;
            const ready_row: u16 = if (width == 40) 2 else 5;
            const value_col: u16 = if (width == 40) 7 else 0;
            try testing.expect(win.readCell(0, 0).?.style.bold);
            try testing.expectEqual(theme.markdown_bold, win.readCell(0, 0).?.style.fg);
            try testing.expect(win.readCell(value_col, state_row).?.style.italic);
            try testing.expectEqual(theme.markdown_italic, win.readCell(value_col, state_row).?.style.fg);
            try testing.expect(win.readCell(0, ada_row).?.style.strikethrough);
            try expectComposedForeground(theme, theme.markdown_inline_code, win.readCell(value_col, ready_row).?.style);
            try testing.expectEqual(theme.search_active, win.readCell(value_col, ready_row).?.style.bg);
            if (width == 40) for (0..12) |col| {
                const divider = win.readCell(@intCast(col), 1).?;
                try testing.expect(divider.style.dim);
                try expectComposedForeground(theme, theme.gutter.fg, divider.style);
            };
            if (width == 40) for ([_]u16{ 0, 2 }) |row| {
                const divider = win.readCell(5, row).?;
                try testing.expect(divider.style.dim);
                try expectComposedForeground(theme, theme.gutter.fg, divider.style);
            };
            if (width == 7) try testing.expectEqual(theme.picker.bg, win.readCell(0, 4).?.style.bg);
            for (rows[1..], 0..) |card, row| drawReviewCard(a, win, @intCast(row), card, theme, .{});
            try testing.expectEqual(theme.markdown_inline_code, win.readCell(value_col + 4, ready_row).?.style.fg);
            drawReviewCardSearchRange(win, ready_row, rows[ready_row + 1], .{ .visual_row = ready_row, .relation = .neutral, .source = ranges[0], .row = ranges[0], .active = true }, true, theme);
            try testing.expectEqual(theme.search_active, win.readCell(value_col + 4, ready_row).?.style.bg);
        }
    }
}

test "M23 links highlight only the matched reference use in ReviewCards and Preview as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[A][id] [B][id]\n\n[id]: /host";
    const use = [_]@import("search.zig").Range{.{ .start = 2, .end = 7 }};
    const definition = [_]@import("search.zig").Range{.{ .start = raw.len - 4, .end = raw.len }};
    const result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = raw,
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } }, .ranges = @constCast(&use), .definition_ranges = &definition, .column = 3, .candidate_scalars = 4, .corpus_order = 0, .session_epoch = 1 },
    };
    var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
        try testing.expectEqualStrings("h", win.readCell(4, 0).?.char.grapheme);
        try testing.expectEqual(theme.search_active, win.readCell(4, 0).?.style.bg);
        try testing.expectEqualStrings("h", win.readCell(14, 0).?.char.grapheme);
        try testing.expectEqual(theme.cursorBg(theme.picker.bg), win.readCell(14, 0).?.style.bg);
        const card_mod = @import("review_card.zig");
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        const rows = try card_mod.project(a, try card_mod.ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 76, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
        drawReviewCard(a, win, 0, rows[1], theme, .{});
        const before = win.readCell(18, 0).?.style.bg;
        drawReviewCardSearchRange(win, 0, rows[1], .{ .visual_row = 0, .relation = .neutral, .source = use[0], .definition = definition[0], .row = use[0], .active = true }, true, theme);
        try testing.expectEqual(theme.search_active, win.readCell(8, 0).?.style.bg);
        try testing.expectEqual(before, win.readCell(18, 0).?.style.bg);
    }
}

test "M23 links Preview wraps full reference destinations and highlights only matched definition bytes as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[***Docs***][id]\n\n[id]: ../abcdefgh \"Guide\"";
    const definition = std.mem.indexOf(u8, raw, "abcdefgh").?;
    const ranges = [_]@import("search.zig").Range{.{ .start = 11, .end = 15 }};
    const definition_ranges = [_]@import("search.zig").Range{.{ .start = definition + 2, .end = definition + 6 }};
    const result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = raw,
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } }, .ranges = @constCast(&ranges), .definition_ranges = &definition_ranges, .column = 12, .candidate_scalars = 4, .corpus_order = 0, .session_epoch = 1 },
    };
    var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const expected = [_][]const u8{ "Docs ‹..", "/abcdefg", "h› \"Guid", "e\"" };
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
        for (expected, 0..) |text, row| {
            var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
            var col: u16 = 0;
            while (iterator.nextCodepointSlice()) |grapheme| : (col += 1) {
                try testing.expectEqualStrings(grapheme, win.readCell(col, @intCast(row)).?.char.grapheme);
            }
        }
        const label = win.readCell(0, 0).?.style;
        try testing.expect(label.bold and label.italic and label.ul_style == .single);
        try testing.expectEqual(theme.markdown_bold, label.fg);
        for (0..8) |col| {
            const style = win.readCell(@intCast(col), 1).?.style;
            try testing.expectEqual(if (col >= 3 and col < 7) theme.search_active else theme.cursorBg(theme.picker.bg), style.bg);
        }
    }
}

test "M23 links terminal hyperlinks retain complete destinations across wrapped ReviewCards and Preview" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const destination = "https://example.invalid/abcdefgh?first=one#fragment";
    const card_mod = @import("review_card.zig");
    for ([_][]const u8{
        "[***Docs***](" ++ destination ++ " \"Guide\") tail",
        "[***Docs***][id] tail\n\n[id]: " ++ destination ++ " \"Guide\"",
    }) |raw| {
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        const result: presentation.ReviewSearchResult = .{
            .kind = "COMMENT",
            .source = "Ada",
            .body = raw,
            .scope = .review,
            .scope_state = .current,
            .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } }, .ranges = &.{}, .column = 0, .candidate_scalars = 0, .corpus_order = 0, .session_epoch = 1 },
        };
        for ([_]u16{ 12, 100 }) |width| {
            var screen = try vaxis.Screen.init(a, .{ .rows = 20, .cols = width, .x_pixel = 0, .y_pixel = 0 });
            defer screen.deinit(a);
            const win = headlessWindow(&screen);
            const rows = try card_mod.project(a, try card_mod.ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = width - 4, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
            var destination_rows: usize = 0;
            for (rows[1..]) |row| {
                drawReviewCard(a, win, 0, row, @import("theme.zig").dark, .{});
                var col: u16 = @intCast(row.contentColumn());
                var has_destination = false;
                for (row.segments) |segment| {
                    const cell = win.readCell(col, 0).?;
                    if (segment.marks.link_label or segment.marks.link_destination) {
                        try testing.expectEqualStrings(destination, cell.link.uri);
                        try testing.expectEqualStrings("id=bbr-comment-1-0", cell.link.params);
                    } else try testing.expectEqualStrings("", cell.link.uri);
                    has_destination = has_destination or segment.marks.link_destination;
                    col += @intCast(terminal_cell_metrics.width(segment.text));
                }
                destination_rows += @intFromBool(has_destination);
                try testing.expectEqualStrings("", win.readCell(0, 0).?.link.uri);
            }
            try testing.expect(destination_rows > if (width == 12) @as(usize, 1) else 0);
            drawReviewSearchPreview(a, win, result, 0, @import("theme.zig").dark, terminal_cell_metrics);
            try testing.expectEqualStrings(destination, win.readCell(0, 0).?.link.uri);
            const label = win.readCell(0, 0).?.style;
            try testing.expect(label.bold and label.italic and label.ul_style == .single);
        }
    }
}

test "M23 links terminal targets exclude relative destinations controls and unrelated cells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var links: TerminalLinks = .{ .scratch = a, .owner = .{ .draft = 1 } };
    for ([_][]const u8{ "../relative", "#fragment", "https://example.invalid/\x1b]52;", "https://example.invalid/\x07", "https://example.invalid/\n", "https://example.invalid/\x7f", "https://example.invalid/space here" }, 0..) |destination, start| {
        try testing.expectEqualStrings("", links.get(.{ .destination = destination, .start = start }).uri);
    }
    const target: @import("review_body.zig").LinkTarget = .{ .destination = "https://example.invalid/path", .start = 99 };
    const first = links.get(target);
    try testing.expectEqualStrings(target.destination, first.uri);
    try testing.expectEqualStrings("id=bbr-draft-1-99", first.params);
    try testing.expectEqual(first.params.ptr, links.get(target).params.ptr);
    try testing.expectEqualStrings("", links.get(null).uri);
    links.owner = .{ .comment = 1 };
    links.start = null;
    try testing.expectEqualStrings("id=bbr-comment-1-99", links.get(target).params);

    const card_mod = @import("review_card.zig");
    for ([_][]const u8{
        "https://example.invalid/path tail",
        "![alt](https://example.invalid/path) tail",
        "| Item |\n| --- |\n| [docs](https://example.invalid/path) |",
        "`https://example.invalid/path` tail",
        "[docs](../relative) tail",
    }, 0..) |raw, index| {
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        const rows = try card_mod.project(a, try card_mod.ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 8, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
        var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 12, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        var linked_cells: usize = 0;
        for (rows) |row| {
            drawReviewCard(a, win, 0, row, @import("theme.zig").dark, .{});
            for (0..win.width) |col| {
                const cell = win.readCell(@intCast(col), 0).?;
                if (cell.link.uri.len > 0) {
                    linked_cells += 1;
                    try testing.expectEqualStrings(target.destination, cell.link.uri);
                }
            }
        }
        try testing.expectEqual(index < 3, linked_cells > 0);
    }
}

test "M23 literal code backgrounds follow block rectangles in Comments Drafts and Preview" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card_mod = @import("review_card.zig");
    const raw = "before\n\n> ```text\n> a\tb\n>\n> 界\n> ```\n\nafter";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const draft: bbr.review.Draft = .{ .local_id = 1, .kind = .comment, .body = raw };
    var screen = try vaxis.Screen.init(a, .{ .rows = 12, .cols = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for ([_]bool{ false, true }) |is_draft| {
        const role: card_mod.CardRole = if (is_draft) .draft_reply else .comment_reply;
        const rows = try card_mod.project(a, try card_mod.ReviewBody.parse(a, raw), .{
            .owner = if (is_draft) .{ .draft = 1 } else .{ .comment = 1 },
            .source = if (is_draft) .{ .draft = &draft } else .{ .comment = &comment },
            .role = role,
            .header = "Ada",
            .content_width = 20,
            .metrics = terminal_cell_metrics,
            .collapsed_rows = 0,
            .indent = 7,
        });
        for (@import("theme.zig").builtins) |builtin| for ([_]bool{ false, true }) |focused| {
            const theme = if (focused) cursorRowTheme(builtin.value) else builtin.value;
            var code_rows: usize = 0;
            for (rows[1..], 0..) |card, row| {
                drawReviewCard(a, win, @intCast(row), card, theme, .{});
                const area = card.code_area;
                if (area) |rect| {
                    try testing.expectEqual(@as(usize, 2), rect.column);
                    try testing.expectEqual(@as(usize, 5), rect.width);
                    code_rows += 1;
                }
                for (0..win.width) |col| {
                    const inside = if (area) |rect| col >= card.contentColumn() + rect.column and col < card.contentColumn() + rect.column + rect.width else false;
                    const outside = col < card.indent or col > card.rightBorderColumn();
                    const expected = if (inside) theme.code_background else if (outside) theme.context.bg else theme.reviewCardStyle(role, .body, .{}).bg;
                    try testing.expectEqual(expected, win.readCell(@intCast(col), @intCast(row)).?.style.bg);
                }
            }
            try testing.expectEqual(@as(usize, 3), code_rows);
            const result: presentation.ReviewSearchResult = .{
                .kind = "COMMENT",
                .source = "Ada",
                .body = raw,
                .scope = .review,
                .scope_state = .current,
                .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } }, .ranges = &.{}, .column = 1, .candidate_scalars = 0, .corpus_order = 0, .session_epoch = 1 },
            };
            drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
            for (rows[1 .. rows.len - 1], 0..) |card, row| for (0..win.width) |col| {
                const inside = if (card.code_area) |rect| col >= rect.column and col < rect.column + rect.width else false;
                try testing.expectEqual(if (inside) theme.code_background else theme.picker.bg, win.readCell(@intCast(col), @intCast(row)).?.style.bg);
            };
        };
    }
}

test "M23 literal Preview shares code and Suggestion backgrounds and tab search cells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 10, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for ([_][]const u8{ "```zig\r\na\tb  \r\n\n*x* :mask:\n```", "```suggestion\r\na\tb  \r\n\n*x* :mask:\n```" }, 0..) |raw, kind| {
        const tab = std.mem.indexOfScalar(u8, raw, '\t').?;
        const ranges = [_]@import("search.zig").Range{.{ .start = tab, .end = tab + 1 }};
        const result: presentation.ReviewSearchResult = .{
            .kind = "COMMENT",
            .source = "Ada",
            .body = raw,
            .scope = .review,
            .scope_state = .current,
            .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 2 } }, .ranges = @constCast(&ranges), .column = 2, .candidate_scalars = 1, .corpus_order = 0, .session_epoch = 1 },
        };
        for (@import("theme.zig").builtins) |builtin| {
            const theme = builtin.value;
            drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
            const row: u16 = @intCast(kind * 2);
            const bg = if (kind == 0) theme.code_background else theme.suggestion.bg;
            const fg = theme.resolveStyle(.{ .fg = if (kind == 0) theme.context.fg else theme.suggestion.fg, .bg = theme.cursorBg(bg) }).fg;
            try testing.expectEqualStrings("a", win.readCell(0, row).?.char.grapheme);
            try testing.expectEqual(fg, win.readCell(0, row).?.style.fg);
            try testing.expectEqual(theme.cursorBg(bg), win.readCell(0, row).?.style.bg);
            for (1..4) |col| {
                try testing.expectEqualStrings(" ", win.readCell(@intCast(col), row).?.char.grapheme);
                try testing.expectEqual(theme.search_active, win.readCell(@intCast(col), row).?.style.bg);
                try testing.expectEqual(fg, win.readCell(@intCast(col), row).?.style.fg);
            }
            try testing.expectEqual(theme.cursorBg(bg), win.readCell(7, row).?.style.bg);
            try testing.expectEqual(bg, win.readCell(0, row + 1).?.style.bg);
            try testing.expectEqualStrings("*", win.readCell(0, row + 2).?.char.grapheme);
            try testing.expectEqualStrings(":", win.readCell(4, row + 2).?.char.grapheme);
        }
    }
}

test "M23 containers Preview keeps quote bars list styles and code tab search cells as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 10, .cols = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const raw = "> - **item**\n>     ```zig\n>     a\tb\n>     ```\n>> _deep_";
    const tab = std.mem.indexOfScalar(u8, raw, '\t').?;
    const ranges = [_]@import("search.zig").Range{.{ .start = tab, .end = tab + 1 }};
    const result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = raw,
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 3 } }, .ranges = @constCast(&ranges), .column = 8, .candidate_scalars = 1, .corpus_order = 0, .session_epoch = 1 },
    };
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
        try testing.expectEqualStrings("│", win.readCell(0, 0).?.char.grapheme);
        try testing.expectEqualStrings("•", win.readCell(2, 0).?.char.grapheme);
        try testing.expectEqualStrings("i", win.readCell(4, 0).?.char.grapheme);
        try testing.expectEqual(theme.markdown_bold, win.readCell(4, 0).?.style.fg);
        try testing.expect(win.readCell(4, 0).?.style.bold);
        try testing.expectEqualStrings("a", win.readCell(4, 1).?.char.grapheme);
        for (5..8) |col| {
            const cell = win.readCell(@intCast(col), 1).?;
            try testing.expectEqualStrings(" ", cell.char.grapheme);
            try testing.expectEqual(theme.search_active, cell.style.bg);
            try expectComposedForeground(theme, theme.context.fg, cell.style);
        }
        try testing.expectEqual(theme.cursorBg(theme.picker.bg), win.readCell(0, 1).?.style.bg);
        try testing.expectEqualStrings("│", win.readCell(2, 2).?.char.grapheme);
        try testing.expectEqualStrings("d", win.readCell(4, 2).?.char.grapheme);
        try testing.expectEqual(theme.markdown_italic, win.readCell(4, 2).?.style.fg);
        try testing.expect(win.readCell(4, 2).?.style.italic);
    }
}

test "M23 inline Preview shows joined prose and Setext headings with every matched part styled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const ranges = [_]@import("search.zig").Range{.{ .start = 13, .end = 25 }};
    const result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = "Title\n=====\n\nfirst\nsecond",
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 4 } }, .ranges = @constCast(&ranges), .column = 1, .candidate_scalars = 12, .corpus_order = 0, .session_epoch = 1 },
    };
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
        try testing.expectEqualStrings("#", win.readCell(0, 0).?.char.grapheme);
        try testing.expect(win.readCell(0, 0).?.style.dim);
        try testing.expectEqual(theme.gutter.fg, win.readCell(0, 0).?.style.fg);
        try testing.expectEqualStrings(" ", win.readCell(1, 0).?.char.grapheme);
        try testing.expect(win.readCell(2, 0).?.style.bold);
        try testing.expectEqualStrings("f", win.readCell(0, 2).?.char.grapheme);
        try testing.expectEqualStrings("s", win.readCell(6, 2).?.char.grapheme);
        for (0..12) |col| try testing.expectEqual(theme.search_active, win.readCell(@intCast(col), 2).?.style.bg);
    }
}

test "M23 inline Review Search Preview shares Markdown styles, literal code, and authored tab matches in every Theme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const ranges = [_]@import("search.zig").Range{.{ .start = 16, .end = 17 }};
    const result: presentation.ReviewSearchResult = .{
        .kind = "DRAFT",
        .source = "local",
        .body = "plain ***x*** `a\tb` ~~gone~~",
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .draft = 1 }, .logical_line = 1 } }, .ranges = @constCast(&ranges), .column = 17, .candidate_scalars = 1, .corpus_order = 0, .session_epoch = 1 },
    };
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
        try testing.expectEqualStrings("p", win.readCell(0, 0).?.char.grapheme);
        try testing.expect(!win.readCell(0, 0).?.style.bold);
        try testing.expectEqualStrings("x", win.readCell(6, 0).?.char.grapheme);
        try testing.expectEqual(theme.markdown_bold, win.readCell(6, 0).?.style.fg);
        try testing.expect(win.readCell(6, 0).?.style.bold and win.readCell(6, 0).?.style.italic);
        try testing.expectEqualStrings("a", win.readCell(8, 0).?.char.grapheme);
        for (9..12) |col| {
            const cell = win.readCell(@intCast(col), 0).?;
            try testing.expectEqualStrings(" ", cell.char.grapheme);
            try expectComposedForeground(theme, theme.markdown_inline_code, cell.style);
            try testing.expectEqual(theme.search_active, cell.style.bg);
            try testing.expect(!cell.style.bold);
        }
        try testing.expectEqualStrings("g", win.readCell(14, 0).?.char.grapheme);
        try testing.expect(win.readCell(14, 0).?.style.strikethrough);
        var fallback = terminal_cell_metrics;
        fallback.strikethrough_supported = false;
        drawReviewSearchPreview(a, win, result, 0, theme, fallback);
        try testing.expectEqualStrings("~", win.readCell(14, 0).?.char.grapheme);
        try testing.expectEqualStrings("g", win.readCell(16, 0).?.char.grapheme);
        try testing.expect(!win.readCell(16, 0).?.style.strikethrough);
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
    const rects = view_paint.paint(layouts.DialogSlot, layouts.dialog, layouts.composer, win, theme);
    if (rects.get(.surface).border.isEmpty()) return;
    const header = std.fmt.allocPrint(scratch, "✎ {s}", .{label}) catch "✎ compose";
    _ = childRect(win, rects.get(.header).content).printSegment(.{ .text = header, .style = theme.picker_query }, .{ .wrap = .none });
    _ = childRect(win, rects.get(.hint).content).printSegment(
        .{ .text = footer orelse if (pending) "External Edit in progress…" else "^D submit · ^E external · ^W del word · ^U del line · esc cancel", .style = theme.picker_query },
        .{ .wrap = .none },
    );

    // Split the body into lines, scroll so the tail (where the cursor is)
    // stays visible, and mark the end with a block.
    const body_win = childRect(win, rects.get(.body).content);
    const body_rows = body_win.height;

    var total: u16 = 1; // one line, plus one per newline
    for (body) |ch| {
        if (ch == '\n') total += 1;
    }
    const first_visible: u16 = if (total > body_rows) total - body_rows else 0;

    var li: u16 = 0;
    var out_row: u16 = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| : (li += 1) {
        if (li < first_visible) continue;
        if (out_row >= body_rows) break;
        const is_last = it.peek() == null;
        const text = if (is_last)
            std.fmt.allocPrint(scratch, "{s}▌", .{line}) catch line
        else
            line;
        _ = body_win.printSegment(.{ .text = text, .style = theme.picker }, .{ .row_offset = out_row, .wrap = .none });
        out_row += 1;
    }
}

/// Draw the "Submitting review" progress modal over the viewer while a batch
/// runs (M10b). A small centered box: a title, an `n / total posted` line, and
/// a note that it can't be interrupted. `scratch` outlives render.
pub fn drawSubmit(scratch: std.mem.Allocator, win: vaxis.Window, theme: Theme, seen: usize, total: usize) void {
    const rects = view_paint.paint(layouts.DialogSlot, layouts.dialog, layouts.submit_progress, win, theme);
    _ = childRect(win, rects.get(.header).content).printSegment(.{ .text = " Submitting review", .style = theme.picker_query }, .{ .wrap = .none });
    const line = std.fmt.allocPrint(scratch, "  {d} / {d} items", .{ seen, total }) catch "  submitting…";
    _ = childRect(win, rects.get(.body).content).printSegment(.{ .text = line, .style = theme.picker }, .{ .wrap = .none });
    _ = childRect(win, rects.get(.hint).content).printSegment(.{ .text = " publishing to Bitbucket…", .style = theme.picker_query }, .{ .wrap = .none });
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
    const rects = view_paint.paint(layouts.DialogSlot, layouts.dialog, layouts.submit_result, win, theme);
    const title: []const u8 = if (stale)
        " Submit refused — PR moved"
    else if (aborted != null)
        " Submit aborted"
    else if (failed > 0 or skipped > 0)
        " Submission completed with issues"
    else
        " Review submitted";
    _ = childRect(win, rects.get(.header).content).printSegment(.{ .text = title, .style = theme.picker_query }, .{ .wrap = .none });
    const line: []const u8 = if (stale)
        "  reopen the PR before submitting"
    else if (aborted) |name|
        std.fmt.allocPrint(scratch, "  {s} — all kept pending", .{name}) catch "  aborted"
    else
        std.fmt.allocPrint(scratch, "  {d} posted · {d} failed · {d} skipped", .{ posted, failed, skipped }) catch "  done";
    _ = childRect(win, rects.get(.body).content).printSegment(.{ .text = line, .style = theme.picker }, .{ .wrap = .none });
    _ = childRect(win, rects.get(.hint).content).printSegment(.{ .text = " press any key to dismiss", .style = theme.picker_query }, .{ .wrap = .none });
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
    const rects = view_paint.paint(layouts.SubmissionSlot, layouts.submission, {}, win, theme);
    const title = std.fmt.allocPrint(scratch, " Submission for {s}#{d}", .{ tree.key.repository(), tree.key.pull_request_id }) catch " Submission";
    _ = childRect(win, rects.get(.title).content).printSegment(.{ .text = title, .style = theme.picker_query }, .{ .wrap = .none });
    const summary = std.fmt.allocPrint(scratch, " {d} posted | {d} failed | {d} skipped | {d} outcome unknown", .{
        tree.posted,
        tree.failed,
        tree.skipped,
        tree.outcome_unknown,
    }) catch " Submission progress";
    _ = childRect(win, rects.get(.summary).content).printSegment(.{ .text = summary, .style = theme.picker }, .{ .wrap = .none });

    const items = childRect(win, rects.get(.items).content);
    const list_height = items.height;
    const selected: u16 = @intCast(@min(tree.selected, std.math.maxInt(u16)));
    const top: usize = if (selected >= list_height and list_height > 0) selected - list_height + 1 else 0;
    var item_row: u16 = 0;
    var index = top;
    while (index < tree.items.len and item_row < list_height) : ({
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
        fillRow(items, item_row, style);
        _ = items.printSegment(.{ .text = text, .style = style }, .{ .row_offset = item_row, .wrap = .none });
    }

    if (tree.selectedItem()) |item| drawSubmissionDetail(scratch, childRect(win, rects.get(.detail).content), theme, tree, item);
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
    detail: vaxis.Window,
    theme: Theme,
    tree: @import("presentation.zig").SubmissionTreeProjection,
    item: @import("presentation.zig").SubmissionItemProjection,
) void {
    if (detail.height == 0) return;
    fillRow(detail, 0, theme.picker_query);
    const identity = std.fmt.allocPrint(scratch, " Draft #{d}: {s}; {d} Reply descendant(s)", .{ item.temp_id, item.context, item.reply_descendants }) catch " Draft detail";
    _ = detail.printSegment(.{ .text = identity, .style = theme.picker_query }, .{ .wrap = .none });
    var row: u16 = 1;
    if (tree.stale_repair) |stale| if (row < detail.height) {
        const source = std.fmt.allocPrint(scratch, " Stale repair: loaded {s}; observed {s}; {s}", .{
            stale.loaded_source_commit,
            stale.observed_source_commit,
            if (stale.reloaded) "reloaded - repair this scope before retry" else "R reload PullRequest; no submit-anyway",
        }) catch " Stale repair required";
        _ = detail.printSegment(.{ .text = source, .style = theme.outcome_unknown }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    };
    if (row < detail.height) {
        const reason = if (item.reason) |err|
            std.fmt.allocPrint(scratch, " Reason: {s}", .{@errorName(err)}) catch " Reason unavailable"
        else if (item.blocking_ancestor) |ancestor|
            std.fmt.allocPrint(scratch, " Blocked by nearest ancestor Draft #{d}; no independent retry", .{ancestor}) catch " Blocked by ancestor"
        else if (item.state == .outcome_unknown)
            " outcome unknown - resolve before editing"
        else
            " Reason: none";
        _ = detail.printSegment(.{ .text = reason, .style = if (item.state == .outcome_unknown) theme.outcome_unknown else theme.picker }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < detail.height) {
        const attempts = std.fmt.allocPrint(scratch, " Attempts: POST {d}/{d}; publication checks {d}/{d}", .{
            item.post_attempts,
            bbr.review.submission.max_attempts,
            item.publication_checks,
            bbr.review.submission.max_attempts,
        }) catch " Attempts unavailable";
        _ = detail.printSegment(.{ .text = attempts, .style = theme.picker }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < detail.height) {
        const delay = if (item.retry) |retry| std.fmt.allocPrint(scratch, " Static delay: local {d}ms; server {s}; effective {d}ms", .{
            retry.local_delay_ms,
            if (retry.server_delay_ms) |server| std.fmt.allocPrint(scratch, "{d}ms", .{server}) catch "set" else "none",
            retry.effective_delay_ms,
        }) catch " Static delay unavailable" else " Static delay: none";
        _ = detail.printSegment(.{ .text = delay, .style = theme.picker }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < detail.height) {
        fillRow(detail, row, theme.picker_query);
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
        _ = detail.printSegment(.{ .text = footer, .style = theme.picker_query }, .{ .row_offset = row, .wrap = .none });
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
        vaxis.Key.left => "←",
        vaxis.Key.right => "→",
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
        .select_old_version => if (!availability.old_version) "old File version absent" else null,
        .select_new_version => if (!availability.new_version) "new File version absent" else null,
        .yank => if (availability.yank_refusal) |refusal| switch (refusal) {
            .no_source => "no copyable text",
            .no_body => "no authored body",
            .opposite_version => "opposite Selected Version",
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
    const rects = view_paint.paint(layouts.HelpSlot, layouts.help, n, win, theme);
    if (rects.get(.surface).border.isEmpty()) return;
    _ = childRect(win, rects.get(.title).content).printSegment(.{ .text = " Keybindings", .style = theme.picker_query }, .{ .wrap = .none });

    const motions = childRect(win, rects.get(.motions).content);
    const commands = childRect(win, rects.get(.commands).content);
    for (rows.motions, 0..) |row, i| {
        if (i >= motions.height) break;
        _ = motions.printSegment(.{ .text = row.text, .style = if (row.available) theme.picker else theme.gutter }, .{ .row_offset = @intCast(i), .wrap = .none });
    }
    for (rows.commands, 0..) |row, i| {
        if (i >= commands.height) break;
        _ = commands.printSegment(.{ .text = row.text, .style = if (row.available) theme.picker else theme.gutter }, .{ .row_offset = @intCast(i), .wrap = .none });
    }

    const mouse = childRect(win, rects.get(.mouse).content);
    if (mouse.height == 3) {
        _ = mouse.printSegment(.{ .text = " Mouse", .style = theme.picker_query }, .{ .wrap = .none });
        _ = mouse.printSegment(.{ .text = " click focus/select/toggle · wheel scroll", .style = theme.picker }, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });
        _ = mouse.printSegment(.{ .text = " Shift/Option: native selection · [input.mouse] enabled=false", .style = theme.gutter }, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });
    }
    _ = childRect(win, rects.get(.hint).content).printSegment(.{ .text = " press any key to dismiss", .style = theme.picker_query }, .{ .wrap = .none });
}

/// The boot/switch frame shown until a Session arrives: a centered floating
/// "Loading PR #N…" dialog (or the error, if the fetch failed), over a cleared
/// backdrop. `scratch` outlives render for the synthesized text.
pub fn drawLoading(scratch: std.mem.Allocator, win: vaxis.Window, id: ?u64, theme: Theme, status_msg: ?[]const u8) void {
    if (win.height == 0 or win.width == 0) return;
    // Blank the whole window first: on a switch the previous viewer frame is
    // still in the screen buffer behind the dialog.
    win.clear();
    const rects = view_paint.paint(layouts.LoadingSlot, layouts.loading, {}, win, theme);
    const text: []const u8 = if (status_msg) |m|
        if (id) |pr_id| std.fmt.allocPrint(scratch, " PR #{d}: {s}", .{ pr_id, m }) catch m else m
    else if (id) |pr_id|
        std.fmt.allocPrint(scratch, " Loading PR #{d}…", .{pr_id}) catch "Loading…"
    else
        " Loading local review…";
    _ = childRect(win, rects.get(.line).content).printSegment(.{ .text = text, .style = theme.picker_query }, .{ .wrap = .none });
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

const anchor_cols: u16 = @intCast(@import("frame.zig").anchor_cols);

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
    for (text, anchor_cols..) |byte, column| {
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
        try testing.expectEqual(theme_dark.context.bg, input.readCell(0, 0).?.style.bg);
        try testing.expectEqual(theme_dark.context.bg, input.readCell(2, 0).?.style.bg);
        try testing.expectEqual(theme_dark.context.bg, header.readCell(0, 0).?.style.bg);
        try testing.expectEqual(theme_dark.context.bg, header.readCell(header.width - 1, 0).?.style.bg);
        try testing.expectEqualStrings("▸", list.readCell(0, 0).?.char.grapheme);
        try testing.expectEqualStrings("b", preview.readCell(0, 0).?.char.grapheme);
        try testing.expect(geometry.landscape == (cols == 100));
        try testing.expectEqualStrings("n", preview.readCell(7, 0).?.char.grapheme);
        try testing.expectEqual(theme_dark.search_active, preview.readCell(7, 0).?.style.bg);
        if (cols == 20) try testing.expectEqualStrings("├", win.readCell(geometry.body.x, geometry.divider).?.char.grapheme);
    }
}

test "M23 acceptance Review Search waits for geometry that fits after a terminal shrink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 54, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    win.fill(.{ .char = .{ .grapheme = ".", .width = 1 }, .style = theme_dark.context });
    const ranges = [_]@import("search.zig").Range{.{ .start = 0, .end = 12 }};
    const occurrence: @import("search.zig").Occurrence = .{
        .location = .{ .review_body = .{ .owner = .{ .draft = 41 }, .logical_line = 1 } },
        .ranges = @constCast(&ranges),
        .column = 1,
        .candidate_scalars = 12,
        .corpus_order = 0,
        .session_epoch = 1,
    };
    const result: presentation.ReviewSearchResult = .{
        .kind = "DRAFT",
        .source = "local #41",
        .body = "first\nsecond\n\nhidden tail",
        .scope = .review,
        .scope_state = .current,
        .occurrence = occurrence,
    };
    var projection: presentation.ReviewSearchProjection = .{
        .query = "first second",
        .occurrences = &.{occurrence},
        .results = &.{result},
        .candidate_count = 1,
        .selected = 0,
        .list_scroll = 0,
        .preview_scroll = 0,
        .pending = false,
        .geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 150, .rows = 54 }).?,
    };
    drawReviewSearch(a, win, projection, theme_dark);
    for (0..win.height) |row| for (0..win.width) |col| {
        try testing.expectEqualStrings(".", win.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
    };
    projection.geometry = @import("frame.zig").reviewSearchGeometry(.{ .cols = 40, .rows = 54 }).?;
    drawReviewSearch(a, win, projection, theme_dark);
    const list = childRect(win, projection.geometry.list);
    const preview = childRect(win, projection.geometry.preview);
    try testing.expectEqualStrings("▸", list.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("f", preview.readCell(0, 0).?.char.grapheme);
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

test "M23 acceptance Preview line tint preserves query contrast for source Comments and Drafts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const search = @import("search.zig");
    var screen = try vaxis.Screen.init(a, .{ .rows = 8, .cols = 48, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const source_ranges = [_]search.Range{.{ .start = 6, .end = 12 }};
    const source_result: presentation.ReviewSearchResult = .{
        .kind = "SOURCE",
        .source = "File",
        .body = "",
        .scope = .review,
        .scope_state = null,
        .occurrence = .{
            .location = .{ .source = .{ .file_index = 0, .relation = .new, .old_path = "a.js", .new_path = "a.js", .new_line = 2 } },
            .ranges = @constCast(&source_ranges),
            .column = 7,
            .candidate_scalars = 18,
            .corpus_order = 0,
            .session_epoch = 1,
        },
    };
    const source_spans = [_]bbr.highlight.Span{.{ .line = 2, .start = 0, .end = 5, .capture = bbr.highlight.Capture.init(0, "keyword") }};
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        win.fill(.{ .style = theme.picker });
        drawReviewSourcePreview(a, win.child(.{ .height = 0 }), win, source_result, .{
            .old = .absent,
            .new = .{ .content = .{ .blob = "before\nconst needle = 42;\nafter", .highlighting = .{ .ready = .{ .spans = &source_spans } } } },
        }, 0, 0, theme);
        try testing.expectEqual(theme.cursorBg(theme.picker.bg), win.readCell(0, 1).?.style.bg);
        try expectComposedForeground(theme, theme.syntax_keyword, win.readCell(0, 1).?.style);
        try testing.expect(!win.readCell(0, 1).?.style.reverse);
        try testing.expect(!win.readCell(6, 1).?.style.reverse);
        try testing.expectEqual(theme.search_active, win.readCell(6, 1).?.style.bg);
        try testing.expectEqual(theme.cursorBg(theme.picker.bg), win.readCell(47, 1).?.style.bg);
        try testing.expectEqual(theme.picker.bg, win.readCell(0, 0).?.style.bg);
        for ([_]search.ReviewBodyOwner{ .{ .comment = 42 }, .{ .draft = 29 } }) |owner| {
            for ([_][]const u8{ "before\n\n**left** needle after\n\nlater", "before\n\n```js\nconst needle = 42;\n```\n\nlater" }, 0..) |body, code| {
                const start = std.mem.indexOf(u8, body, "needle").?;
                const ranges = [_]search.Range{.{ .start = start, .end = start + 6 }};
                const result: presentation.ReviewSearchResult = .{
                    .kind = if (owner == .draft) "DRAFT" else "COMMENT",
                    .source = "Ada",
                    .body = body,
                    .scope = .review,
                    .scope_state = .current,
                    .occurrence = .{
                        .location = .{ .review_body = .{ .owner = owner, .logical_line = 3 } },
                        .ranges = @constCast(&ranges),
                        .column = 1,
                        .candidate_scalars = 18,
                        .corpus_order = 0,
                        .session_epoch = 1,
                    },
                };
                win.fill(.{ .style = theme.picker });
                drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
                const match_col: u16 = if (code == 0) 5 else 6;
                const base_bg = if (code == 0) theme.picker.bg else theme.code_background;
                try testing.expectEqual(theme.cursorBg(base_bg), win.readCell(0, 2).?.style.bg);
                try testing.expectEqual(theme.search_active, win.readCell(match_col, 2).?.style.bg);
                try testing.expectEqual(theme.cursorBg(theme.picker.bg), win.readCell(47, 2).?.style.bg);
                try testing.expectEqual(theme.picker.bg, win.readCell(0, 0).?.style.bg);
                try testing.expect(!win.readCell(match_col, 2).?.style.reverse);
                if (code == 0) {
                    try testing.expectEqual(theme.markdown_bold, win.readCell(0, 2).?.style.fg);
                    try testing.expect(win.readCell(0, 2).?.style.bold);
                }
            }
        }
    }
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
    const list = childRect(win, .{ .x = geometry.list.x, .y = geometry.list.y, .width = geometry.list.width + 1, .height = geometry.list.height });
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
    try testing.expectEqualStrings("b", preview.readCell(0, 0).?.char.grapheme);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(0, 0).?.style.bg);
    try testing.expectEqual(theme_dark.markdown_bold, preview.readCell(0, 0).?.style.fg);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(5, 0).?.style.bg);
    try testing.expectEqual(theme_dark.search_active, preview.readCell(4, 0).?.style.bg);
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
    try testing.expectEqualStrings("╭", win.readCell(geometry.rect.x, geometry.rect.y).?.char.grapheme);
    try testing.expectEqualStrings(">", win.readCell(geometry.rect.x + 1, geometry.rect.y + 1).?.char.grapheme);
    const status = "1/1 matches · 2 candidates";
    try testing.expectEqualStrings("1", win.readCell(geometry.rect.x + geometry.rect.width - @as(u16, @intCast(searchCellWidth(status))) - 3, geometry.rect.y + 2).?.char.grapheme);
    try testing.expectEqualStrings("╭", win.readCell(geometry.body.x, geometry.body.y).?.char.grapheme);
    try testing.expectEqualStrings("┬", win.readCell(geometry.divider, geometry.body.y).?.char.grapheme);
    try testing.expectEqualStrings("▸", win.readCell(geometry.list.x, geometry.list.y).?.char.grapheme);
    try testing.expectEqualStrings("C", win.readCell(geometry.header.x, geometry.header.y).?.char.grapheme);
    try testing.expectEqualStrings("─", win.readCell(geometry.header.x, geometry.header.y + 1).?.char.grapheme);
    try testing.expectEqualStrings("t", win.readCell(geometry.preview.x, geometry.preview.y).?.char.grapheme);
}

test "an added or removed Line paints its band from the first gutter cell of every row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a,
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-old line that is long enough to wrap twice in a narrow pane
        \\+new line that is long enough to wrap twice in a narrow pane
        \\
    );
    var screen = try vaxis.Screen.init(a, .{ .rows = 16, .cols = 48, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for (@import("theme.zig").builtins) |builtin| for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| {
        const theme = builtin.value;
        const buf = try buffer_mod.build(a, diff, layout);
        const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, buf.rows, .bytes, .{ .layout = layout, .width = win.width });
        try testing.expect(visual_rows.len <= win.height);
        win.clear();
        drawVisualPane(a, win, buf, visual_rows, theme, Nav.init(visual_rows.len, win.height));
        var banded: usize = 0;
        for (visual_rows, 0..) |visual, index| {
            const row: u16 = @intCast(index);
            if (visual.halves) |halves| {
                for ([_]?@import("frame.zig").VisualHalf{ halves.left, halves.right }, [_]u16{ 0, win.width / 2 + 1 }) |half, x| {
                    const value = half orelse continue;
                    if (value.line.kind == .context) continue;
                    try testing.expectEqual(theme.lineStyle(value.line.kind).bg, win.readCell(x, row).?.style.bg);
                    banded += 1;
                }
            } else if (visual.owner == .line and visual.owner.line.kind != .context) {
                try testing.expectEqual(theme.lineStyle(visual.owner.line.kind).bg, win.readCell(0, row).?.style.bg);
                banded += 1;
            }
        }
        try testing.expect(banded >= 4);
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

test "sorted Buffer Search ranges paint only the visible row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "needle" };
    const runs = [_]bbr.highlight.decoration.Run{.{ .text = line.text }};
    const rows = [_]Row{ .{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } }, .{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } } };
    const buf: Buffer = .{ .rows = &rows, .layout = .unified };
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, &rows, .bytes, .{ .layout = .unified, .width = 30 });
    const ranges = [_]@import("frame.zig").ProjectedSourceRange{
        .{ .visual_row = 0, .relation = .new, .source = .{ .start = 0, .end = 6 }, .row = .{ .start = 0, .end = 6 }, .active = true },
        .{ .visual_row = 1, .relation = .new, .source = .{ .start = 0, .end = 6 }, .row = .{ .start = 0, .end = 6 }, .active = false },
    };
    var nav = Nav.init(2, 1);
    nav.jumpTo(1);
    const frame: @import("frame.zig").Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 30, .rows = 1 },
        .panes = @import("frame.zig").paneRects(.{ .cols = 30, .rows = 1 }),
        .visual_rows = visual_rows,
        .buffer = buf,
        .navigation = nav,
        .search_ranges = &ranges,
        .search_ranges_sorted = true,
    };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = headlessWindow(&screen);
    drawVisualPane(a, win, buf, visual_rows, theme_dark, nav);
    drawSearchRanges(win, frame, theme_dark);
    try testing.expectEqual(theme_dark.search_match, win.readCell(gutter_cols, 0).?.style.bg);
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
        .width = gutter_cols + 6,
    });
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = gutter_cols + 6, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    var nav = Nav.init(visual_rows.len, 2);
    nav.mark = 0;
    drawVisualPane(a, win, .{ .rows = &rows, .layout = .unified }, visual_rows, theme_dark, nav);

    try testing.expectEqualStrings("7", win.readCell(gutter_cols - 2, 0).?.char.grapheme);
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
        .width = 29,
    });
    var screen = try vaxis.Screen.init(a, .{ .rows = 2, .cols = 29, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    var nav = Nav.init(visual_rows.len, 2);
    nav.mark = 0;
    drawVisualPane(a, win, .{ .rows = &rows, .layout = .side_by_side, .selected_version = .old }, visual_rows, theme_dark, nav);

    try testing.expectEqualStrings("7", win.readCell(side_gutter - 2, 0).?.char.grapheme);
    try testing.expectEqualStrings("9", win.readCell(15 + side_gutter - 2, 0).?.char.grapheme);
    try testing.expectEqualStrings("t", win.readCell(side_gutter, 1).?.char.grapheme);
    try testing.expectEqualStrings(" ", win.readCell(15 + side_gutter - 2, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.cursorBg(theme_dark.removed_emphasis.bg), win.readCell(side_gutter, 1).?.style.bg);
}

test "cursor and Selection paint only Selected Version across complete wrapped source Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-const value = old source that wraps through several rows
        \\+const value = new
    );
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for ([_]buffer_mod.SelectedVersion{ .old, .new }) |version| {
        const buf = try buffer_mod.buildWithComments(a, diff, layout, &.{}, .{ .selected_version = version });
        const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, buf.rows, .bytes, .{ .layout = layout, .width = 40 });
        const cursor = for (visual_rows, 0..) |row, index| {
            if (@import("frame.zig").selectedSource(row, version) != null) break index;
        } else return error.MissingSourceLine;
        const line = @import("frame.zig").selectedSource(visual_rows[cursor], version).?;
        var screen = try vaxis.Screen.init(a, .{ .rows = 20, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        var backgrounds: [20][2]@TypeOf(theme_dark.context.bg) = undefined;
        drawVisualPane(a, win, buf, visual_rows, theme_dark, Nav.init(visual_rows.len, 20));
        for (visual_rows, 0..) |row, index| {
            if (row.owner != .line) continue;
            backgrounds[index][0] = win.readCell(if (layout == .unified) gutter_cols else side_gutter, @intCast(index)).?.style.bg;
            if (layout == .side_by_side) backgrounds[index][1] = win.readCell(21 + side_gutter, @intCast(index)).?.style.bg;
        }
        for ([_]bool{ false, true }) |selection| {
            var nav = Nav.init(visual_rows.len, 20);
            nav.cursor = cursor;
            if (selection) nav.mark = cursor;
            drawVisualPane(a, win, buf, visual_rows, theme_dark, nav);
            for (visual_rows, 0..) |row, index| {
                if (row.owner != .line) continue;
                if (layout == .unified) {
                    const candidate = row.owner.line;
                    const band = backgrounds[index][0];
                    const expected = if (candidate == line) theme_dark.cursorBg(band) else band;
                    try testing.expectEqual(expected, win.readCell(gutter_cols, @intCast(index)).?.style.bg);
                } else {
                    for ([_]buffer_mod.SelectedVersion{ .old, .new }) |side| {
                        const candidate = @import("frame.zig").selectedSource(row, side);
                        const band = backgrounds[index][if (side == .old) 0 else 1];
                        const expected = if (side == version and candidate == line) theme_dark.cursorBg(band) else band;
                        const column: u16 = if (side == .old) side_gutter else 21 + side_gutter;
                        try testing.expectEqual(expected, win.readCell(column, @intCast(index)).?.style.bg);
                    }
                }
            }
        }
    };
}

test "Selection leaves skipped File headers unhighlighted in both layouts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a,
        \\diff --git a/added.zig b/added.zig
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/added.zig
        \\@@ -0,0 +1 @@
        \\+new
        \\diff --git a/deleted.zig b/deleted.zig
        \\deleted file mode 100644
        \\--- a/deleted.zig
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-old
    );
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for ([_]buffer_mod.SelectedVersion{ .old, .new }) |version| {
        const buf = try buffer_mod.buildWithComments(a, diff, layout, &.{}, .{ .selected_version = version });
        const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, buf.rows, .bytes, .{ .layout = layout, .width = 60 });
        var screen = try vaxis.Screen.init(a, .{ .rows = 12, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        var nav = Nav.init(visual_rows.len, 12);
        nav.mark = 0;
        nav.cursor = visual_rows.len - 1;
        drawVisualPane(a, win, buf, visual_rows, theme_dark, nav);
        for (visual_rows, 0..) |row, index| {
            if (row.kind != .file_header) continue;
            const expected = if (buf.hasFileVersion(row.buffer_index, version)) theme_dark.cursorBg(theme_dark.file_header.bg) else theme_dark.file_header.bg;
            try testing.expectEqual(expected, win.readCell(0, @intCast(index)).?.style.bg);
        }
    };
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
    const buf: Buffer = .{ .rows = &rows, .layout = .side_by_side, .selected_version = .old, .selected_column = .{ .version = .old, .inner_gutter_edge = .right } };
    var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawPane(a, win, buf, theme_dark, Nav.init(1, 1));

    try testing.expectEqualStrings("▐", win.readCell(0, 0).?.char.grapheme);
    const left = win.child(.{ .x_off = 1, .width = win.width / 2 - 1, .height = 1 });
    try expectScreenText(left, 0, "Old content binary, 3 bytes");
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

    const left = win.child(.{ .x_off = 1, .width = win.width / 2 - 1, .height = 2 });
    try expectScreenText(left, 0, "Old content absent");
    const right = win.child(.{ .x_off = win.width / 2 + 1, .width = win.width - (win.width / 2 + 1), .height = 2 });
    try expectScreenText(right, 0, "New content binary, size unavailable");
    try expectScreenText(left, 1, "Old content binary, 7 bytes");
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

test "the cursor source row is highlighted only for Selected Version, keeping band hue" {
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
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, &.{}, .{ .selected_version = .old });

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

    // The gutter carries the same cursor band, so the row is tinted from its
    // first cell.
    try testing.expectEqual(expected, win.readCell(px, 3).?.style.bg);

    // An off-cursor line keeps its untinted band.
    try testing.expectEqual(theme_dark.added.bg, win.readCell(body_x, 4).?.style.bg);
    var opposite = buf;
    opposite.selected_version = .new;
    draw(a, win, diff, opposite, theme_dark, nav, 0, &.{}, &.{});
    try testing.expectEqual(theme_dark.removed.bg, win.readCell(body_x, 3).?.style.bg);
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
    try testing.expectEqual(theme_dark.context.bg, win.readCell(mx, my).?.style.bg);
    // The body's first line sits one column in on the first body row.
    try testing.expectEqualStrings("l", win.readCell(mx + 1, my + 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.context.bg, win.readCell(mx + 1, my + 1).?.style.bg);
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
    try testing.expectEqualStrings("✎", win.readCell(px + 4, dr).?.char.grapheme);
    try testing.expectEqual(theme_dark.draft.bg, win.readCell(px + 4, dr).?.style.bg);
}

test "picker overlay draws the query line and highlights the selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prs = [_]bbr.bitbucket.PullRequestSummary{
        .{ .id = 10, .title = "Add diff parser", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/diff", .destination_branch = "main" },
        .{ .id = 11, .title = "Fix navigation", .state = "OPEN", .author_display_name = "Grace", .source_branch = "feature/nav", .destination_branch = "main" },
    };
    var picker = ListOverlay.openPullRequestPicker(a, 1, .{});
    defer picker.deinit();
    const summaries = try list_overlay_mod.PullRequestSummaries.create(a);
    summaries.prs = &prs;
    try picker.populatePullRequests(1, summaries);
    picker.moveDown(); // select the second entry

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawListOverlay(a, win, &picker, .{ .remote = true }, .system, &.{}, theme_dark);

    // Surface geometry: 62×20, centered on 80×24 → origin (9, 2). The query
    // row sits inside the input box at (10, 3). The entries start inside the
    // result box at (10, 6).
    const mx: u16 = 10;
    const qy: u16 = 3;
    const ey: u16 = 6;
    try testing.expectEqualStrings("›", win.readCell(mx, qy).?.char.grapheme);
    try testing.expectEqual(theme_dark.context.bg, win.readCell(mx, qy).?.style.bg);
    // The selected (second) entry carries the ▸ marker and the selected
    // background. The first entry does not.
    try testing.expectEqualStrings("▸", win.readCell(mx, ey + 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.picker_selected.bg, win.readCell(mx, ey + 1).?.style.bg);
    try testing.expectEqual(theme_dark.context.bg, win.readCell(mx, ey).?.style.bg);
}

test "Command Palette rows show a bold title, a regular description, and grey an unavailable Action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const mx: u16 = 10;
    const qy: u16 = 3;
    const ey: u16 = 6;
    const local_review: presentation.ActionAvailability = .{ .remote = false };

    for ([_]struct { query: []const u8, title: []const u8, available: bool }{
        .{ .query = "toggle layout", .title = "Toggle Layout", .available = true },
        .{ .query = "submit review", .title = "Submit Review", .available = false },
    }) |case| {
        var palette = try ListOverlay.openCommandPalette(a, .diff);
        defer palette.deinit();
        palette.insert(case.query, &.{});
        win.clear();
        drawListOverlay(a, win, &palette, local_review, .system, &.{}, theme_dark);

        try testing.expectEqualStrings("›", win.readCell(mx, qy).?.char.grapheme);
        const title = win.readCell(mx + 2, ey).?;
        try testing.expectEqualStrings(case.title[0..1], title.char.grapheme);
        try testing.expect(title.style.bold);
        const description = win.readCell(mx + 2 + @as(u16, @intCast(case.title.len)) + 2, ey).?;
        try testing.expect(!description.style.bold);
        try testing.expect(!std.mem.eql(u8, " ", description.char.grapheme));
        const expected_fg = if (case.available) theme_dark.picker_selected.fg else theme_dark.gutter.fg;
        try testing.expectEqual(expected_fg, title.style.fg);
        try testing.expectEqual(expected_fg, description.style.fg);
        try testing.expectEqual(theme_dark.picker_selected.bg, title.style.bg);
    }
}

test "the Theme Overlay marks the Configured Theme and the screen repaints in the previewed Theme" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);
    const session = try @import("session.zig").create(testing.allocator);
    session.source = .{ .remote = .{ .id = 1, .title = "Theme", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature", .destination_branch = "main", .source_commit = "source", .destination_commit = "base" } };
    session.header = .{ .title = "Theme", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Bitbucket" };
    session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1 @@\n-old\n+new\n");
    try session.initializeEnrichment();
    var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store(), .configured_theme = .dark }, .{
        .initial = .{ .key = key, .session = session },
        .geometry = .{ .cols = 60, .rows = 24 },
    });
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const themes = @import("theme.zig");

    try state.dispatch(.{ .action = .open_theme_overlay });
    try state.dispatch(.{ .key = .{ .codepoint = keymap.special.down } });
    var projection = state.projection();
    try testing.expectEqual(ThemeId.light, projection.theme);
    drawReview(a, win, projection.review.?, themes.value(projection.theme), 0);
    try testing.expect(screenHasBackground(win, themes.light.added.bg));
    try testing.expect(!screenHasBackground(win, themes.dark.added.bg));

    drawListOverlay(a, win, projection.list_overlay.?, projection.action_availability, projection.configured_theme, &.{}, themes.value(projection.theme));
    // "dark" is the first Theme row after "system".
    const themes_at = @import("frame.zig").listOverlayTarget(.{ .cols = 60, .rows = 24 }, projection.list_overlay.?.box()).?.entries;
    try testing.expectEqualStrings("d", win.readCell(themes_at.x + 2, themes_at.y + 1).?.char.grapheme);
    try testing.expectEqualStrings("(", win.readCell(themes_at.x + 8, themes_at.y + 1).?.char.grapheme);
    try testing.expectEqualStrings(" ", win.readCell(themes_at.x + 8, themes_at.y).?.char.grapheme);

    try state.dispatch(.{ .key = .{ .codepoint = keymap.special.escape } });
    projection = state.projection();
    try testing.expectEqual(ThemeId.dark, projection.theme);
    win.clear();
    drawReview(a, win, projection.review.?, themes.value(projection.theme), 0);
    try testing.expect(screenHasBackground(win, themes.dark.added.bg));

    try state.dispatch(.{ .action = .open_file_finder });
    projection = state.projection();
    win.clear();
    drawListOverlay(a, win, projection.list_overlay.?, projection.action_availability, projection.configured_theme, projection.review.?.diff.files, themes.value(projection.theme));
    const files_at = @import("frame.zig").listOverlayTarget(.{ .cols = 60, .rows = 24 }, projection.list_overlay.?.box()).?.entries;
    try expectScreenText(win.child(.{ .x_off = files_at.x + 2, .y_off = files_at.y }), 0, "a.zig");
}

fn screenHasBackground(win: vaxis.Window, bg: vaxis.Cell.Color) bool {
    for (0..win.height) |row| for (0..win.width) |col| {
        if (std.meta.eql(win.readCell(@intCast(col), @intCast(row)).?.style.bg, bg)) return true;
    };
    return false;
}

test "a loading picker shows its single-glyph spinner beside the placeholder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var picker = ListOverlay.openPullRequestPicker(a, 1, .{});
    defer picker.deinit();

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawListOverlay(a, win, &picker, .{ .remote = true }, .system, &.{}, theme_dark);

    // The first entry row, at (10, 6), carries "  loading…".
    const mx: u16 = 10;
    const ey: u16 = 6;
    try testing.expectEqualStrings("L", win.readCell(mx + 2, ey).?.char.grapheme);
    try testing.expectEqualStrings(picker.pull_request_picker.spinnerGlyph(), win.readCell(mx, ey).?.char.grapheme);
}

test "every Overlay surface has a rounded border" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Check = struct {
        fn corners(win: vaxis.Window, rect: @import("frame.zig").Rect) !void {
            try testing.expect(!rect.isEmpty());
            const right = rect.x + rect.width - 1;
            const bottom = rect.y + rect.height - 1;
            try testing.expectEqualStrings("╭", win.readCell(rect.x, rect.y).?.char.grapheme);
            try testing.expectEqualStrings("╮", win.readCell(right, rect.y).?.char.grapheme);
            try testing.expectEqualStrings("╰", win.readCell(rect.x, bottom).?.char.grapheme);
            try testing.expectEqualStrings("╯", win.readCell(right, bottom).?.char.grapheme);
        }
    };
    for ([_][2]u16{ .{ 120, 40 }, .{ 50, 12 } }) |size| {
        var screen = try vaxis.Screen.init(a, .{ .rows = size[1], .cols = size[0], .x_pixel = 0, .y_pixel = 0 });
        const win = headlessWindow(&screen);
        try Check.corners(win, view_paint.paint(layouts.ListSlot, layouts.listOverlay, layouts.ListOverlay{ .box = .{ .width = 60, .height = 16 } }, win, theme_dark).get(.surface).border);
        for ([_]layouts.Dialog{ layouts.composer, layouts.submit_progress, layouts.submit_result }) |dialog|
            try Check.corners(win, view_paint.paint(layouts.DialogSlot, layouts.dialog, dialog, win, theme_dark).get(.surface).border);
        try Check.corners(win, view_paint.paint(layouts.LoadingSlot, layouts.loading, {}, win, theme_dark).get(.surface).border);
        try Check.corners(win, view_paint.paint(layouts.HelpSlot, layouts.help, @as(usize, 20), win, theme_dark).get(.surface).border);
        try Check.corners(win, view_paint.paint(layouts.SubmissionSlot, layouts.submission, {}, win, theme_dark).get(.surface).border);
        try Check.corners(win, view_paint.paint(layouts.SearchSlot, layouts.reviewSearch, layouts.ReviewSearch{}, win, theme_dark).get(.surface).border);
    }
}

test "an input Overlay is a bordered input box above a bordered result list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = @import("frame.zig");
    const Check = struct {
        fn shape(win: vaxis.Window, surface: frame.Rect, query: frame.Rect, title: []const u8) !void {
            try testing.expect(!surface.isEmpty());
            const bottom = surface.y + surface.height - 1;
            try testing.expectEqualStrings("╭", win.readCell(surface.x, surface.y).?.char.grapheme);
            try testing.expectEqualStrings("╰", win.readCell(surface.x, surface.y + 2).?.char.grapheme);
            try testing.expectEqualStrings("╭", win.readCell(surface.x, surface.y + 3).?.char.grapheme);
            try testing.expectEqualStrings("╰", win.readCell(surface.x, bottom).?.char.grapheme);
            try testing.expectEqual(surface.x + 1, query.x);
            try testing.expectEqual(surface.y + 1, query.y);
            var top: [1024]u8 = undefined;
            var len: usize = 0;
            for (0..surface.width) |col| {
                const grapheme = win.readCell(surface.x + @as(u16, @intCast(col)), surface.y).?.char.grapheme;
                @memcpy(top[len..][0..grapheme.len], grapheme);
                len += grapheme.len;
            }
            try testing.expect(std.mem.indexOf(u8, top[0..len], title) != null);
        }
    };
    var overlays = [_]struct { overlay: ListOverlay, title: []const u8 }{
        .{ .overlay = ListOverlay.openPullRequestPicker(a, 1, .{}), .title = " Pull Requests " },
        .{ .overlay = try ListOverlay.openFileFinder(a, &.{}), .title = " File Finder " },
        .{ .overlay = try ListOverlay.openCommandPalette(a, .diff), .title = " Command Palette " },
        .{ .overlay = try ListOverlay.openTheme(a, .dark), .title = " Theme " },
    };
    for ([_][2]u16{ .{ 120, 40 }, .{ 50, 12 } }) |size| {
        var screen = try vaxis.Screen.init(a, .{ .rows = size[1], .cols = size[0], .x_pixel = 0, .y_pixel = 0 });
        const win = headlessWindow(&screen);
        for (&overlays) |*case| {
            win.clear();
            drawListOverlay(a, win, &case.overlay, .{ .remote = true }, .system, &.{}, theme_dark);
            const target = frame.listOverlayTarget(.{ .cols = size[0], .rows = size[1] }, case.overlay.box()).?;
            try testing.expectEqualStrings("›", win.readCell(target.rect.x + 1, target.rect.y + 1).?.char.grapheme);
            try Check.shape(win, target.rect, .{ .x = target.rect.x + 1, .y = target.rect.y + 1 }, case.title);
            try testing.expectEqual(target.rect.y + 4, target.entries.y);
        }
        win.clear();
        const rects = view_paint.paint(layouts.SearchSlot, layouts.reviewSearch, layouts.ReviewSearch{}, win, theme_dark);
        try Check.shape(win, rects.get(.surface).border, rects.get(.query).content, " Review Search ");
    }
}

test "every Overlay paints the Theme base background" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = @import("frame.zig");
    const view = @import("view.zig");
    const geometry: frame.Geometry = .{ .cols = 120, .rows = 40 };
    const area: view.Rect = .{ .width = geometry.cols, .height = geometry.rows };
    const backdrop: vaxis.Cell.Color = .{ .rgb = .{ 1, 2, 3 } };
    const Check = struct {
        fn surface(win: vaxis.Window, rect: frame.Rect, base: vaxis.Cell.Color, highlight: frame.Rect) !void {
            try testing.expect(!rect.isEmpty());
            for (rect.y..rect.y + rect.height) |row| for (rect.x..rect.x + rect.width) |col| {
                const inside_highlight = row >= highlight.y and row < highlight.y + highlight.height and col >= highlight.x and col < highlight.x + highlight.width;
                if (!inside_highlight) {
                    const style = win.readCell(@intCast(col), @intCast(row)).?.style;
                    try testing.expectEqual(base, style.bg);
                    try testing.expect(!style.reverse);
                }
            };
        }
    };
    const prs = [_]bbr.bitbucket.PullRequestSummary{
        .{ .id = 10, .title = "Add diff parser", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/diff", .destination_branch = "main" },
        .{ .id = 11, .title = "Fix navigation", .state = "OPEN", .author_display_name = "Grace", .source_branch = "feature/nav", .destination_branch = "main" },
    };
    var picker = ListOverlay.openPullRequestPicker(a, 1, .{});
    defer picker.deinit();
    const summaries = try list_overlay_mod.PullRequestSummaries.create(a);
    summaries.prs = &prs;
    try picker.populatePullRequests(1, summaries);
    picker.moveDown();
    const target = frame.listOverlayTarget(geometry, picker.box()).?;
    const selected: frame.Rect = .{ .x = target.entries.x, .y = target.entries.y + 1, .width = target.entries.width, .height = 1 };
    const search = frame.reviewSearchGeometry(geometry).?;
    const key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);

    var screen = try vaxis.Screen.init(a, .{ .rows = geometry.rows, .cols = geometry.cols, .x_pixel = 0, .y_pixel = 0 });
    const win = headlessWindow(&screen);
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        const base = theme.context.bg;

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawListOverlay(a, win, &picker, .{ .remote = true }, .system, &.{}, theme);
        try Check.surface(win, target.rect, base, selected);

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawReviewSearch(a, win, .{ .query = "needle", .occurrences = &.{}, .results = &.{}, .candidate_count = 0, .selected = null, .list_scroll = 0, .preview_scroll = 0, .pending = false, .geometry = search }, theme);
        try Check.surface(win, search.rect, base, .{});

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawComposerProjection(a, win, .{ .label = "New comment", .body = "looks good" }, theme);
        try Check.surface(win, view.solve(layouts.DialogSlot, layouts.dialog, layouts.composer, area).get(.surface).border, base, .{});

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawSubmit(a, win, theme, 1, 3);
        try Check.surface(win, view.solve(layouts.DialogSlot, layouts.dialog, layouts.submit_progress, area).get(.surface).border, base, .{});

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawSubmitResult(a, win, theme, 2, 1, 0, null, false);
        try Check.surface(win, view.solve(layouts.DialogSlot, layouts.dialog, layouts.submit_result, area).get(.surface).border, base, .{});

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawHelp(a, win, theme, keymap.Keymap.default, .{ .remote = true });
        const help_rows = buildHelpRows(a, keymap.Keymap.default, .{ .remote = true });
        try Check.surface(win, view.solve(layouts.HelpSlot, layouts.help, @max(help_rows.motions.len, help_rows.commands.len), area).get(.surface).border, base, .{});

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawLoading(a, win, 42, theme, null);
        try Check.surface(win, view.solve(layouts.LoadingSlot, layouts.loading, {}, area).get(.surface).border, base, .{});

        win.fill(.{ .style = .{ .bg = backdrop } });
        drawSubmissionTree(a, win, theme, .{ .operation_id = 1, .key = key, .items = &.{}, .selected = 0, .completion = null, .posted = 0, .failed = 0, .skipped = 0, .outcome_unknown = 0 });
        try Check.surface(win, view.solve(layouts.SubmissionSlot, layouts.submission, {}, area).get(.surface).border, base, .{});
    }
}

test "the boot loading view floats a Loading PR dialog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    drawLoading(a, win, 42, theme_dark, null);

    // Dialog: 48×3 centered on 80×24 → x=16, y=10. The text sits inside the
    // rounded border on row 11 after one leading space, so 'L' is at col 18.
    try testing.expectEqualStrings("╭", win.readCell(16, 10).?.char.grapheme);
    try testing.expectEqualStrings("L", win.readCell(18, 11).?.char.grapheme);
    try testing.expectEqualStrings("#", win.readCell(29, 11).?.char.grapheme);

    // With a status message the id-prefixed error takes its place.
    var screen2 = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen2.deinit(a);
    const win2 = headlessWindow(&screen2);
    drawLoading(a, win2, 42, theme_dark, "NotFound");
    try testing.expectEqualStrings("P", win2.readCell(18, 11).?.char.grapheme);
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
    _ = view_paint.paint(layouts.PaneSlot, layouts.panes, layouts.Panes{ .sidebar_focused = true }, win, theme_dark);
    try testing.expectEqualStrings("╭", win.readCell(panes.sidebar.x, 0).?.char.grapheme);
    try testing.expect(win.readCell(panes.sidebar.x, 0).?.style.bold);
    try testing.expect(!win.readCell(panes.diff.x, 0).?.style.bold);
    try testing.expectEqualStrings("│", win.readCell(panes.sidebar.x, 1).?.char.grapheme);
    try testing.expectEqualStrings("│", win.readCell(panes.diff.x, 1).?.char.grapheme);
    try testing.expectEqual(@as(u16, 1), panes.sidebar_content.y);
    try testing.expectEqual(@as(u16, 1), panes.diff_content.y);

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

    const BodySlot = enum { body };
    const framed = struct {
        fn tree(focused: bool, area: @import("view.zig").Rect, visitor: anytype) void {
            const V = @import("view.zig").View(BodySlot);
            const stroke: @import("view.zig").Stroke = .{ .focused = focused };
            const root: V = .{
                .margin = @import("view.zig").Edges.sides(2),
                .border = .{ .stroke = stroke },
                .composition = .{ .flow = .{} },
                .children = &.{ .{ .composition = .{ .rule = stroke } }, .{ .slot = .body } },
            };
            @import("view.zig").walk(BodySlot, &root, area, visitor);
        }
    };
    for ([_]bool{ false, true }) |focused| {
        const body = view_paint.paint(BodySlot, framed.tree, focused, win, theme_dark).get(.body).content;
        try testing.expectEqual(content, body);
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

    drawRow(a, win, 0, .unified, null, .{ .file_header = .{ .file = &file, .path = file.new_path } }, theme, .{});
    drawRow(a, win, 1, .unified, null, .{ .section = .{ .kind = .pr_comments, .count = 2 } }, theme, .{});

    try testing.expectEqualStrings("─", win.readCell(win.width - 1, 0).?.char.grapheme);
    try testing.expectEqual(theme.pane_border_focused.fg, win.readCell(win.width - 1, 0).?.style.fg);
    try testing.expectEqualStrings("P", win.readCell(3, 1).?.char.grapheme);
    try testing.expectEqual(theme.file_header.fg, win.readCell(3, 1).?.style.fg);
    try testing.expectEqualStrings("─", win.readCell(win.width - 1, 1).?.char.grapheme);
    try testing.expectEqual(theme.pane_border_focused.fg, win.readCell(win.width - 1, 1).?.style.fg);
}

test "M23 ancestry renders shared offsets and visible capped depth with search cells" {
    const cases = [_]struct { width: u16, depth: usize, indent: usize }{
        .{ .width = 100, .depth = 2, .indent = 9 },
        .{ .width = 60, .depth = 2, .indent = 5 },
        .{ .width = 40, .depth = 2, .indent = 1 },
        .{ .width = 60, .depth = 20, .indent = 16 },
    };
    for (cases) |case| for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var comments: [21]bbr.review.Comment = undefined;
        for (comments[0 .. case.depth + 1], 0..) |*comment, index| comment.* = .{
            .id = index + 1,
            .parent_id = if (index == 0) null else index,
            .author = "author with a name longer than the available header width at the indentation cap",
            .body = "bodyabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
        };
        const threads = try bbr.review.buildThreads(a, comments[0 .. case.depth + 1]);
        const diff: bbr.diff.Diff = .{ .files = &.{} };
        const buf = try buffer_mod.buildWithComments(a, diff, layout, threads, .{ .card_width = case.width, .collapsed_rows = 1 });
        var screen = try vaxis.Screen.init(a, .{ .rows = 120, .cols = case.width + 29, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        for (@import("theme.zig").builtins) |builtin| {
            draw(a, win, diff, buf, builtin.value, Nav.init(buf.rows.len, 120), 0, threads, &.{});
            for (buf.rows, 0..) |row, index| if (row == .comment and row.comment.owner.comment == case.depth + 1) {
                const card = row.comment;
                const left = 29 + case.indent;
                const start = left + 2;
                if (card.part == .header and (case.indent == 1 or case.depth == 20)) {
                    var text: std.ArrayList(u8) = .empty;
                    for (start..win.width) |col| try text.appendSlice(a, win.readCell(@intCast(col), @intCast(index)).?.char.grapheme);
                    const label = try std.fmt.allocPrint(a, "depth {d}", .{case.depth});
                    try testing.expect(std.mem.indexOf(u8, text.items, label) != null);
                } else {
                    const cell: struct { col: usize, text: []const u8 } = switch (card.part) {
                        .header => .{ .col = left + 3, .text = "a" },
                        .body => .{ .col = start, .text = "b" },
                        .disclosure_footer => .{ .col = left, .text = "╰" },
                        else => unreachable,
                    };
                    try testing.expectEqualStrings(cell.text, win.readCell(@intCast(cell.col), @intCast(index)).?.char.grapheme);
                }
                if (card.part == .body) {
                    const pane = win.child(.{ .x_off = 29, .width = case.width, .height = 120 });
                    drawReviewCardSearchRange(pane, @intCast(index), card, .{
                        .visual_row = index,
                        .relation = .neutral,
                        .source = .{ .start = 0, .end = 4 },
                        .row = .{ .start = 0, .end = 4 },
                        .active = true,
                    }, true, builtin.value);
                    try testing.expectEqualDeep(builtin.value.search_active, win.readCell(@intCast(start), @intCast(index)).?.style.bg);
                    try testing.expect(!std.meta.eql(builtin.value.search_active, win.readCell(@intCast(start - 1), @intCast(index)).?.style.bg));
                }
            };
        }
    };
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
        .geometry = .{ .cols = 59, .rows = 16 },
    });
    defer state.deinit();
    const review = state.projection().review.?;

    var projected_body_rows: usize = 0;
    for (review.buffer.rows) |row| if (row == .comment and row.comment.part == .body) {
        projected_body_rows += 1;
    };
    try testing.expectEqual(@as(usize, 2), projected_body_rows);

    var screen = try vaxis.Screen.init(a, .{ .rows = 16, .cols = 59, .x_pixel = 0, .y_pixel = 0 });
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
    try testing.expectEqualStrings("│", win.readCell(right - 1, screen_row).?.char.grapheme);
}

test "M23 highlighting syntax foreground preserves tab cells and interaction backgrounds in every Theme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card_mod = @import("review_card.zig");
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "```TS\na\tb\n```" };
    const body = try card_mod.ReviewBody.parse(a, comment.body);
    const rows = try card_mod.project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 60, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
    var screen = try vaxis.Screen.init(a, .{ .rows = 4, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const spans = [_]@import("code_highlighting.zig").SourceSpan{.{ .source = .{ .start = 6, .end = 9 }, .capture = bbr.highlight.Capture.init(1, "keyword") }};
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewCard(a, win, 1, rows[1], cursorRowTheme(theme), .{});
        drawReviewCardSyntax(win, 1, rows[1], &spans, theme);
        drawReviewCardSearchRange(win, 1, rows[1], .{ .visual_row = 1, .relation = .neutral, .source = .{ .start = 7, .end = 8 }, .row = .{ .start = 0, .end = 1 }, .active = true }, true, theme);
        for (3..6) |col| {
            try testing.expectEqual(theme.search_active, win.readCell(@intCast(col), 1).?.style.bg);
            try expectComposedForeground(theme, theme.syntax_keyword, win.readCell(@intCast(col), 1).?.style);
        }
        try testing.expectEqual(theme.cursorBg(theme.code_background), win.readCell(2, 1).?.style.bg);
        try expectComposedForeground(theme, theme.syntax_keyword, win.readCell(2, 1).?.style);
        try testing.expectEqualStrings("b", win.readCell(6, 1).?.char.grapheme);
    }
}

test "M23 highlighting selected Suggestion Preview uses shared syntax and retains its label background and search foreground" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.identity().remote, .{ .local_id = 7, .kind = .comment, .scope = .{ .@"inline" = .{ .path = "before.js", .to = 1 } }, .body = "```suggestion\nconst\tvalue = 1; // :mask: **literal**\n```" });
    const session = try @import("session.zig").create(testing.allocator);
    session.source = .{ .remote = .{ .id = 1, .title = "Code", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature", .destination_branch = "main", .source_commit = "source", .destination_commit = "base" } };
    session.header = .{ .title = "Code", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Bitbucket" };
    session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1 @@\n-old\n+new\n");
    try session.initializeEnrichment();
    var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store(), .cell_metrics = terminal_cell_metrics }, .{
        .initial = .{ .key = key, .session = session },
        .geometry = .{ .cols = 120, .rows = 40 },
    });
    defer state.deinit();
    try state.dispatch(.{ .action = .open_review_search });
    try state.dispatch(.{ .key = .{ .codepoint = 'c', .text = "const" } });
    var scan = state.takeCommand().?;
    while (scan == .build_buffer_disclosure) {
        scan.build_buffer_disclosure.build();
        try state.dispatch(.{ .buffer_disclosure_built = scan.build_buffer_disclosure });
        scan = state.takeCommand().?;
    }
    const completed = presentation.executeBufferSearchScan(testing.allocator, &scan.scan_buffer_search);
    scan.deinit();
    try state.dispatch(.{ .buffer_search_scanned = completed });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 40, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const before = state.projection();
    const preview = childRect(win, before.review_search.?.geometry.preview);
    drawReviewSearch(a, win, before.review_search.?, theme_dark);
    try testing.expectEqualStrings("s", preview.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("c", preview.readCell(0, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.suggestion.fg, preview.readCell(0, 1).?.style.fg);
    var command = state.takeCommand().?;
    while (command == .enrich_file) command = state.takeCommand().?;
    const job = command.highlight_code;
    try testing.expectEqualStrings("before.js", job.path);
    var highlighter = try @import("../highlight/tree_sitter_highlighter.zig").TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try state.dispatch(.{ .code_highlight_completed = job.execute(highlighter.highlighter()) });
    const after = state.projection();
    try testing.expectEqual(before.review.?.frame.visual_rows.ptr, after.review.?.frame.visual_rows.ptr);
    try testing.expectEqualDeep(before.review.?.navigation, after.review.?.navigation);
    try testing.expectEqualDeep(before.review_search.?.occurrences[0], after.review_search.?.occurrences[0]);
    try testing.expectEqual(after.review.?.frame.code_highlights[0].spans.ptr, after.review_search.?.code_highlights[0].spans.ptr);
    for (@import("theme.zig").builtins) |builtin| {
        const theme = builtin.value;
        drawReviewSearch(a, win, after.review_search.?, theme);
        try testing.expectEqualStrings("s", preview.readCell(0, 0).?.char.grapheme);
        try testing.expectEqual(theme.suggestion.bg, preview.readCell(0, 0).?.style.bg);
        try expectComposedForeground(theme, theme.syntax_keyword, preview.readCell(0, 1).?.style);
        try testing.expectEqual(theme.search_active, preview.readCell(0, 1).?.style.bg);
        try testing.expectEqual(theme.cursorBg(theme.suggestion.bg), preview.readCell(10, 1).?.style.bg);
    }
}

test "M23 highlighting published Frame renders real syntax through wrapping Selection search and Theme changes" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1);
    try store.store().put(key.identity().remote, .{ .local_id = 1, .kind = .comment, .scope = .review, .body = "```TS\nconst\tx = 1; // enough code to wrap across several rows\n```" });
    const session = try @import("session.zig").create(testing.allocator);
    session.source = .{ .remote = .{ .id = 1, .title = "Code", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature", .destination_branch = "main", .source_commit = "source", .destination_commit = "base" } };
    session.header = .{ .title = "Code", .source_ref = "feature", .base_ref = "main", .source_commit = "source", .base_commit = "base", .locator = "repo", .source_label = "Bitbucket" };
    session.diff = try bbr.diff.parse(session.arena.allocator(), "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -1 +1 @@\n-old\n+new\n");
    try session.initializeEnrichment();
    var state = try presentation.Presentation.init(testing.allocator, .{ .reviews = store.store(), .comments_collapsed_rows = 0, .cell_metrics = terminal_cell_metrics }, .{
        .initial = .{ .key = key, .session = session },
        .geometry = .{ .cols = 48, .rows = 24 },
    });
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 48, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    const plain = state.projection().review.?;
    var code_row: ?usize = null;
    var wrapped_rows: usize = 0;
    for (plain.frame.visual_rows, 0..) |visual, index| {
        const row = plain.buffer.rows[visual.buffer_index];
        if (row == .draft and row.draft.part == .code_body) {
            if (code_row == null) code_row = index;
            wrapped_rows += 1;
        }
    }
    try testing.expect(wrapped_rows > 1);
    for (0..code_row.?) |_| try state.dispatch(.{ .action = .down });
    const x = plain.frame.panes.diff_content.x + 3;
    const y = plain.frame.panes.diff_content.y + @as(u16, @intCast(code_row.?));
    drawReview(a, win, state.projection().review.?, theme_dark, 0);
    try testing.expectEqualStrings("c", win.readCell(x, y).?.char.grapheme);
    try testing.expectEqual(theme_dark.context.fg, win.readCell(x, y).?.style.fg);
    var highlighter = try @import("../highlight/tree_sitter_highlighter.zig").TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const job = state.takeCommand().?.highlight_code;
    try state.dispatch(.{ .code_highlight_completed = job.execute(highlighter.highlighter()) });
    const spans = state.projection().review.?.frame.code_highlights[0].spans.ptr;
    try state.dispatch(.{ .action = .toggle_select });
    try state.dispatch(.{ .action = .down });
    for (@import("theme.zig").builtins) |builtin| {
        drawReview(a, win, state.projection().review.?, builtin.value, 0);
        try expectComposedForeground(builtin.value, builtin.value.syntax_keyword, win.readCell(x, y).?.style);
        try testing.expectEqual(builtin.value.cursorBg(builtin.value.code_background), win.readCell(x, y).?.style.bg);
    }
    try state.dispatch(.{ .action = .clear_selection });
    try state.dispatch(.{ .action = .open_buffer_search });
    try state.dispatch(.{ .key = .{ .codepoint = 'c', .text = "const" } });
    var scan = state.takeCommand().?;
    const completed = presentation.executeBufferSearchScan(testing.allocator, &scan.scan_buffer_search);
    scan.deinit();
    try state.dispatch(.{ .buffer_search_scanned = completed });
    for (@import("theme.zig").builtins) |builtin| {
        drawReview(a, win, state.projection().review.?, builtin.value, 0);
        try expectComposedForeground(builtin.value, builtin.value.syntax_keyword, win.readCell(x, y).?.style);
        try testing.expectEqual(builtin.value.search_active, win.readCell(x, y).?.style.bg);
    }
    try testing.expectEqual(spans, state.projection().review.?.frame.code_highlights[0].spans.ptr);
    try testing.expect(state.takeCommand() == null);
}

test "M23 literal code cells keep foreground under cursor Selection and search in every Theme and role" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card_mod = @import("review_card.zig");
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "```zig\na\tb **x** :mask:\n```" };
    const body = try card_mod.ReviewBody.parse(a, comment.body);
    var screen = try vaxis.Screen.init(a, .{ .rows = 4, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for (@import("theme.zig").builtins) |builtin| inline for (std.meta.tags(card_mod.CardRole)) |role| {
        const theme = builtin.value;
        const rows = try card_mod.project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = role, .header = "Ada", .content_width = 60, .metrics = terminal_cell_metrics, .collapsed_rows = 0, .indent = 7 });
        const buffer_rows = [_]buffer_mod.Row{ .{ .comment = rows[0] }, .{ .comment = rows[1] } };
        const buf: Buffer = .{ .rows = &buffer_rows, .layout = .unified };
        for ([_]bool{ false, true }) |selected| {
            var nav = Nav.init(2, 4);
            nav.cursor = if (selected) 0 else 1;
            if (selected) nav.mark = 1;
            drawPane(a, win, buf, theme, nav);
            try testing.expectEqualStrings("a", win.readCell(9, 1).?.char.grapheme);
            try testing.expectEqualStrings("b", win.readCell(13, 1).?.char.grapheme);
            try testing.expectEqualStrings("*", win.readCell(15, 1).?.char.grapheme);
            const cell = win.readCell(9, 1).?;
            try expectComposedForeground(theme, theme.context.fg, cell.style);
            try testing.expectEqual(theme.cursorBg(theme.code_background), cell.style.bg);
            try testing.expect(!cell.style.bold and !cell.style.italic);
            drawReviewCardSearchRange(win, 1, rows[1], .{ .visual_row = 1, .relation = .neutral, .source = .{ .start = 8, .end = 9 }, .row = .{ .start = 0, .end = 1 }, .active = true }, true, theme);
            for (10..13) |col| {
                try testing.expectEqual(theme.search_active, win.readCell(@intCast(col), 1).?.style.bg);
                try expectComposedForeground(theme, theme.context.fg, win.readCell(@intCast(col), 1).?.style);
            }
        }
    };
}

test "M23 acceptance narrow lists tables links and compound emoji retain styles under Selection and search" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card_mod = @import("review_card.zig");
    const raw = "# ***Heading***\n\n> 4. ***[x](url)*** **:woman_technologist::skin-tone-2:**\n>     - ~~gone~~ `a\tb`\n\n| Name | State |\n| --- | --- |\n| ~~Ada~~ | `Ready` |";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const draft: bbr.review.Draft = .{ .local_id = 1, .kind = .comment, .body = raw };
    const body = try card_mod.ReviewBody.parse(a, raw);
    var screen = try vaxis.Screen.init(a, .{ .rows = 128, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    screen.width_method = .unicode;
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    inline for (std.meta.tags(card_mod.CardRole)) |role| {
        const is_draft = switch (role) {
            .draft, .draft_reply, .outcome_unknown, .outcome_unknown_reply => true,
            else => false,
        };
        const rows = try card_mod.project(a, body, .{ .owner = if (is_draft) .{ .draft = 1 } else .{ .comment = 1 }, .source = if (is_draft) .{ .draft = &draft } else .{ .comment = &comment }, .role = role, .header = "Ada", .content_width = 14, .indent = 7, .metrics = terminal_cell_metrics, .collapsed_rows = 0 });
        const buffer_rows = try a.alloc(buffer_mod.Row, rows.len);
        for (rows, buffer_rows) |row, *target| target.* = if (is_draft) .{ .draft = row } else .{ .comment = row };
        for (@import("theme.zig").builtins) |builtin| {
            const theme = builtin.value;
            var nav = Nav.init(rows.len, 128);
            nav.mark = rows.len - 1;
            drawPane(a, win, .{ .rows = buffer_rows, .layout = .unified }, theme, nav);
            var seen = [_]bool{false} ** 5;
            for (rows[1..], 1..) |row, index| {
                const y: u16 = @intCast(index);
                drawReviewCardSearchRange(win, y, row, .{ .visual_row = index, .relation = .neutral, .source = .{ .start = 0, .end = raw.len }, .row = .{ .start = 0, .end = 1 }, .active = true }, true, theme);
                var col: u16 = @intCast(row.contentColumn());
                for (row.segments) |segment| {
                    const width: u16 = @intCast(terminal_cell_metrics.width(segment.text));
                    const cell = win.readCell(col, y).?;
                    if (!segment.authored) {
                        try testing.expect(!std.meta.eql(theme.search_active, cell.style.bg));
                    } else if (std.mem.eql(u8, segment.text, "x")) {
                        seen[0] = true;
                        try testing.expectEqual(theme.markdown_bold, cell.style.fg);
                        try testing.expect(cell.style.bold and cell.style.italic and cell.style.ul_style == .single);
                    } else if (std.mem.eql(u8, segment.text, "👩🏻‍💻")) {
                        seen[1] = true;
                        try testing.expectEqualStrings("👩🏻‍💻", cell.char.grapheme);
                        try testing.expectEqual(theme.markdown_bold, cell.style.fg);
                        try testing.expect(cell.style.bold);
                        for (col..col + width) |emoji_col| try testing.expectEqual(theme.search_active, win.readCell(@intCast(emoji_col), y).?.style.bg);
                    } else if (segment.source.start == std.mem.indexOf(u8, raw, "gone").?) {
                        seen[2] = true;
                        try testing.expect(cell.style.strikethrough);
                    } else if (segment.source.start == std.mem.indexOf(u8, raw, "Ready").?) {
                        seen[3] = true;
                        try expectComposedForeground(theme, theme.markdown_inline_code, cell.style);
                        try testing.expect(!cell.style.bold and !cell.style.italic);
                    } else if (segment.source.start == std.mem.indexOf(u8, raw, "Heading").?) {
                        seen[4] = true;
                        try testing.expect(cell.style.bold and cell.style.italic);
                    }
                    if (segment.authored and segment.source.start < segment.source.end) try testing.expectEqual(theme.search_active, cell.style.bg);
                    col += width;
                }
            }
            for (seen) |found| try testing.expect(found);
        }
    }
}

test "M23 inline system light terminal keeps composed dark surfaces readable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const theme = @import("theme.zig").system;
    // Catppuccin Latte has dark default and ANSI foregrounds.
    const palette = [_]u24{
        0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d,
        0x1e66f5, 0x8839ef, 0x179299, 0xacb0be,
        0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d,
        0x1e66f5, 0x8839ef, 0x179299, 0xbcc0cc,
    };
    var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for ([_]bbr.diff.LineKind{ .context, .added, .removed }) |kind| {
        const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = kind, .text = "abcd" };
        const runs = [_]bbr.highlight.decoration.Run{
            .{ .text = line.text[0..1] },
            .{ .text = line.text[1..2], .emphasis = true },
            .{ .text = line.text[2..3], .capture = bbr.highlight.Capture.init(0, "variable") },
            .{ .text = line.text[3..4], .capture = bbr.highlight.Capture.init(1, "keyword") },
        };
        for ([_]bool{ false, true }) |focused| {
            drawRow(a, win, 0, .unified, null, .{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } }, if (focused) cursorRowTheme(theme) else theme, .{});
            for (0..4) |column| {
                const style = win.readCell(gutter_cols + @as(u16, @intCast(column)), 0).?.style;
                if (kind != .context or focused) try testing.expect(style.bg == .rgb);
                if (style.bg == .rgb) try expectLightTerminalContrast(style, palette);
            }
            if (kind == .context and !focused) try testing.expectEqual(vaxis.Cell.Color.default, win.readCell(gutter_cols, 0).?.style.fg);
            for ([_]bool{ false, true }) |active| {
                paintSearchCells(win, 0, gutter_cols, 4, active, theme);
                for (0..4) |column| try expectLightTerminalContrast(win.readCell(gutter_cols + @as(u16, @intCast(column)), 0).?.style, palette);
            }
        }
    }
    const card_mod = @import("review_card.zig");
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "```text\nabcd\n```" };
    const cards = try card_mod.project(a, try card_mod.ReviewBody.parse(a, comment.body), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 36, .metrics = .bytes, .collapsed_rows = 0 });
    var saw_code = false;
    for (cards) |card| {
        if (card.part != .code_body) continue;
        saw_code = true;
        for ([_]bool{ false, true }) |focused| {
            drawReviewCard(a, win, 0, card, if (focused) cursorRowTheme(theme) else theme, .{});
            const column: u16 = @intCast(card.contentColumn());
            try expectLightTerminalContrast(win.readCell(column, 0).?.style, palette);
            drawReviewCardSyntax(win, 0, card, &.{.{ .source = .{ .start = 8, .end = 12 }, .capture = bbr.highlight.Capture.init(0, "variable") }}, theme);
            try expectLightTerminalContrast(win.readCell(column, 0).?.style, palette);
            paintSearchCells(win, 0, column, 4, true, theme);
            try expectLightTerminalContrast(win.readCell(column, 0).?.style, palette);
        }
    }
    try testing.expect(saw_code);
    const ranges = [_]@import("search.zig").Range{.{ .start = 8, .end = 9 }};
    var result: presentation.ReviewSearchResult = .{
        .kind = "COMMENT",
        .source = "Ada",
        .body = comment.body,
        .scope = .review,
        .scope_state = .current,
        .occurrence = .{ .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 2 } }, .ranges = @constCast(&ranges), .column = 1, .candidate_scalars = 4, .corpus_order = 0, .session_epoch = 1 },
    };
    drawReviewSearchPreview(a, win, result, 0, theme, terminal_cell_metrics);
    try testing.expectEqual(theme.search_active, win.readCell(0, 0).?.style.bg);
    for (0..4) |column| try expectLightTerminalContrast(win.readCell(@intCast(column), 0).?.style, palette);
    const source_ranges = [_]@import("search.zig").Range{.{ .start = 1, .end = 2 }};
    result.occurrence.location = .{ .source = .{ .file_index = 0, .relation = .new, .old_path = "a", .new_path = "a", .new_line = 1 } };
    result.occurrence.ranges = @constCast(&source_ranges);
    win.fill(.{ .style = theme.picker });
    drawReviewSourcePreview(a, win.child(.{ .height = 0 }), win, result, .{
        .old = .absent,
        .new = .{ .content = .{ .blob = "abcd", .highlighting = .{ .ready = .{ .spans = &.{.{ .line = 1, .start = 0, .end = 1, .capture = bbr.highlight.Capture.init(0, "keyword") }} } } } },
    }, 0, 0, theme);
    try testing.expectEqual(theme.search_active, win.readCell(1, 0).?.style.bg);
    for (0..4) |column| try expectLightTerminalContrast(win.readCell(@intCast(column), 0).?.style, palette);
}

fn expectComposedForeground(theme: Theme, foreground: vaxis.Cell.Color, style: vaxis.Style) !void {
    try testing.expectEqual(theme.resolveStyle(.{ .fg = foreground, .bg = style.bg }).fg, style.fg);
}

fn expectLightTerminalContrast(style: vaxis.Style, palette: [16]u24) !void {
    const colors = [_]vaxis.Cell.Color{ style.fg, style.bg };
    var luminance: [2]f64 = undefined;
    for (colors, 0..) |color, i| {
        const channels = switch (color) {
            .default => vaxis.Cell.Color.rgbFromUint(0x4c4f69).rgb,
            .rgb => |channels| channels,
            .index => |index| vaxis.Cell.Color.rgbFromUint(if (index < 16) palette[index] else 0xff8700).rgb,
        };
        luminance[i] = 0;
        for (channels, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
            const srgb = @as(f64, @floatFromInt(channel)) / 255;
            luminance[i] += weight * if (srgb <= 0.04045) srgb / 12.92 else @exp(2.4 * @log((srgb + 0.055) / 1.055));
        }
    }
    try testing.expect((@max(luminance[0], luminance[1]) + 0.05) / (@min(luminance[0], luminance[1]) + 0.05) >= 3);
}

test "M23 inline headless cells retain combined marks under overlapping interaction backgrounds in every Theme and role" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card_mod = @import("review_card.zig");
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "plain ***~~[x](url)~~*** **_`a\tb`_**" };
    const body = try card_mod.ReviewBody.parse(a, comment.body);
    var screen = try vaxis.Screen.init(a, .{ .rows = 4, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);
    for (@import("theme.zig").builtins) |builtin| inline for (std.meta.tags(card_mod.CardRole)) |role| {
        const theme = builtin.value;
        const rows = try card_mod.project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = role, .header = "Ada", .content_width = 76, .metrics = .bytes, .collapsed_rows = 0 });
        try testing.expectEqual(@as(usize, 3), rows.len);
        for ([_]bool{ false, true }) |focused| {
            drawReviewCard(a, win, 0, rows[1], if (focused) cursorRowTheme(theme) else theme, .{});
            try testing.expectEqualStrings("p", win.readCell(2, 0).?.char.grapheme);
            try testing.expect(!win.readCell(2, 0).?.style.bold);
            try testing.expectEqualStrings("x", win.readCell(8, 0).?.char.grapheme);
            try testing.expectEqualStrings("a", win.readCell(16, 0).?.char.grapheme);
            const link = win.readCell(8, 0).?.style;
            try testing.expectEqual(theme.markdown_bold, link.fg);
            try testing.expect(link.bold and link.italic and link.strikethrough and link.ul_style == .single);
            const code = win.readCell(16, 0).?.style;
            try expectComposedForeground(theme, theme.markdown_inline_code, code);
            try testing.expect(code.bold and code.italic and !code.strikethrough);
            for ([_]bool{ false, true }) |active| {
                drawReviewCardSearchRange(win, 0, rows[1], .{ .visual_row = 0, .relation = .neutral, .source = .{ .start = 12, .end = 13 }, .row = .{ .start = 0, .end = 1 }, .active = active }, active, theme);
                const matched = win.readCell(8, 0).?.style;
                try testing.expectEqual(if (active) theme.search_active else theme.search_match, matched.bg);
                try testing.expectEqual(link.fg, matched.fg);
                try testing.expect(matched.bold and matched.italic and matched.strikethrough and matched.ul_style == .single);
            }
        }
    };
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

    _ = view_paint.paint(layouts.PaneSlot, layouts.panes, layouts.Panes{ .sidebar_focused = true }, win, theme_dark);
    drawDiffPaneTitle(arena.allocator(), win, frame, "src/a-very-long-file-name.zig", .whole, theme_dark);

    try testing.expectEqualStrings("h", win.readCell(targets.old.?.x, 0).?.char.grapheme);
    try testing.expectEqualStrings("D", win.readCell(targets.old.?.x + 5, 0).?.char.grapheme);
    try testing.expectEqualStrings("N", win.readCell(targets.new.?.x, 0).?.char.grapheme);
    try testing.expectEqual(theme_dark.accent, win.readCell(targets.old.?.x, 0).?.style.fg);
    try testing.expect(win.readCell(targets.old.?.x, 0).?.style.bold);
    try testing.expect(!std.meta.eql(win.readCell(targets.new.?.x, 0).?.style.fg, theme_dark.accent));
    try testing.expectEqualStrings(" ", win.readCell(targets.old.?.x - 1, 0).?.char.grapheme);
    try testing.expectEqualStrings("─", win.readCell(targets.old.?.x - 2, 0).?.char.grapheme);
    try testing.expectEqualStrings("─", win.readCell(targets.new.?.x - 1, 0).?.char.grapheme);
    try testing.expectEqualStrings(" ", win.readCell(targets.new.?.x + targets.new.?.width, 0).?.char.grapheme);
    try testing.expectEqualStrings("─", win.readCell(targets.new.?.x + targets.new.?.width + 1, 0).?.char.grapheme);
    for ([_]struct { x: u16, text: []const u8 }{
        .{ .x = panes.sidebar.x + 1, .text = "─" },
        .{ .x = panes.sidebar.x + 2, .text = " " },
        .{ .x = panes.sidebar.x + 3, .text = "F" },
        .{ .x = panes.sidebar.x + 8, .text = " " },
        .{ .x = panes.sidebar.x + 9, .text = "─" },
        .{ .x = panes.diff.x + 1, .text = "─" },
        .{ .x = panes.diff.x + 2, .text = " " },
        .{ .x = panes.diff.x + 3, .text = "s" },
    }) |cell| try testing.expectEqualStrings(cell.text, win.readCell(cell.x, 0).?.char.grapheme);
}

test "Selected Version markers stay left of their SideBySide column and off Unified rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a,
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old source that wraps over several rows
        \\+new source that wraps over several rows
    );
    const blobs = [_]bbr.diff.FileBlob{.{ .old = "old source that wraps over several rows\n", .new = "new source that wraps over several rows\n" }};
    for ([_]u16{ 40, 41 }) |width| for ([_]bool{ false, true }) |whole_file| for ([_]buffer_mod.Layout{ .side_by_side, .unified }) |layout| for ([_]buffer_mod.SelectedVersion{ .old, .new }) |version| {
        const buf = try buffer_mod.buildWithComments(a, diff, layout, &.{}, .{ .whole_file = whole_file, .selected_version = version, .blobs = &blobs });
        const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, buf.rows, .bytes, .{ .layout = layout, .width = width });
        var screen = try vaxis.Screen.init(a, .{ .rows = 16, .cols = width, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = headlessWindow(&screen);
        for ([_]bool{ false, true }) |wrapped| {
            win.clear();
            const count = if (wrapped) visual_rows.len else buf.rows.len;
            try testing.expect(count <= win.height);
            const nav = Nav.init(count, win.height);
            if (wrapped) {
                drawVisualPane(a, win, buf, visual_rows, theme_dark, nav);
            } else {
                drawPane(a, win, buf, theme_dark, nav);
            }
            for (0..count) |row| {
                const y: u16 = @intCast(row);
                if (layout == .side_by_side) {
                    const marker_x: u16 = if (version == .old) 0 else width / 2;
                    try testing.expectEqualStrings(if (version == .old) "▐" else "▌", win.readCell(marker_x, y).?.char.grapheme);
                    try testing.expectEqual(theme_dark.accent, win.readCell(marker_x, y).?.style.fg);
                }
                for (0..width) |col| {
                    const glyph = win.readCell(@intCast(col), y).?.char.grapheme;
                    const is_marker = std.mem.eql(u8, glyph, "▐") or std.mem.eql(u8, glyph, "▌");
                    const expected_marker = layout == .side_by_side and col == (if (version == .old) @as(usize, 0) else width / 2);
                    try testing.expectEqual(expected_marker, is_marker);
                }
            }
            if (layout == .side_by_side) {
                const left = win.child(.{ .x_off = 1, .width = width / 2 - 1, .height = win.height });
                const right = win.child(.{ .x_off = width / 2 + 1, .width = width - (width / 2 + 1), .height = win.height });
                try expectScreenText(left, 0, "OLD a.txt");
                try expectScreenText(right, 0, "NEW a.txt");
                if (!whole_file) try expectScreenText(left, 1, "@@ -1 +1 @@");
            }
        }
    };
}

test "SideBySide WholeFile accents only the selected header and left gutter edge" {
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
    try testing.expectEqualStrings("▐", win.readCell(0, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.accent, win.readCell(0, 1).?.style.fg);
    try testing.expectEqualStrings(" ", win.readCell(half, 1).?.char.grapheme);
    try testing.expectEqual(theme_dark.removed.bg, win.readCell(side_gutter, 1).?.style.bg);
    try testing.expectEqual(theme_dark.added.bg, win.readCell(half + 1 + side_gutter, 1).?.style.bg);
}

test "M23 ancestry woven Comment and Suggestion retain distinct markers and styles" {
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
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, threads, .{ .card_width = 51 });

    var screen = try vaxis.Screen.init(a, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = headlessWindow(&screen);

    const nav = Nav.init(buf.rows.len, 24);
    draw(a, win, diff, buf, theme_dark, nav, 0, &.{}, &.{});

    // Pane rows: the root top border, body, and bottom border, then the
    // Suggestion reply top border, semantic label, and literal code body.
    // Fences themselves are structural, not displayed.
    const px = sidebar_width + 1;
    // The root Title "Ada" sits in the top border after "╭─ ".
    try testing.expectEqualStrings("A", win.readCell(px + 4, 4).?.char.grapheme);
    try testing.expectEqual(theme_dark.comment.bg, win.readCell(px + 4, 4).?.style.bg);
    var title: std.ArrayList(u8) = .empty;
    for (px + 5..px + 20) |col| try title.appendSlice(a, win.readCell(@intCast(col), 7).?.char.grapheme);
    try testing.expectEqualStrings("Bo (suggestion)", title.items);
    try testing.expectEqual(theme_dark.comment_reply.bg, win.readCell(px + 5, 7).?.style.bg);
    try testing.expectEqualStrings("s", win.readCell(px + 4, 8).?.char.grapheme);
    try testing.expectEqual(theme_dark.suggestion.bg, win.readCell(px + 4, 8).?.style.bg);
    try testing.expectEqualStrings("r", win.readCell(px + 4, 9).?.char.grapheme);
    try testing.expectEqual(theme_dark.suggestion.bg, win.readCell(px + 4, 9).?.style.bg);
}

const CardTestCursor = enum { plain_line, reply_draft };

const CardTestPane = struct {
    win: vaxis.Window,
    buf: Buffer,
    visual_rows: []const @import("frame.zig").VisualRow,

    fn lineRow(self: CardTestPane, new_no: u32) u16 {
        for (self.visual_rows, 0..) |visual, index| {
            if (visual.owner == .line and visual.owner.line.newNo() == new_no and !visual.continuation) return @intCast(index);
        }
        unreachable;
    }

    /// The first visual row of the `part` of the card that `owner` names.
    fn cardRow(self: CardTestPane, owner: @import("review_card.zig").Owner, part: @import("review_card.zig").Part) u16 {
        for (self.visual_rows, 0..) |visual, index| switch (self.buf.rows[visual.buffer_index]) {
            .comment, .draft => |card| if (std.meta.eql(card.owner, owner) and card.part == part) return @intCast(index),
            else => {},
        };
        unreachable;
    }

    /// The left border column of the card that `owner` names.
    fn cardIndent(self: CardTestPane, owner: @import("review_card.zig").Owner) usize {
        return switch (self.buf.rows[self.visual_rows[self.cardRow(owner, .header)].buffer_index]) {
            .comment, .draft => |card| card.indent,
            else => unreachable,
        };
    }

    fn glyph(self: CardTestPane, col: usize, row: u16) []const u8 {
        return self.win.readCell(@intCast(col), row).?.char.grapheme;
    }

    fn text(self: CardTestPane, a: std.mem.Allocator, row: u16) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        for (0..self.win.width) |col| try result.appendSlice(a, self.glyph(col, row));
        return result.items;
    }

    fn bg(self: CardTestPane, col: usize, row: u16) vaxis.Cell.Color {
        return self.win.readCell(@intCast(col), row).?.style.bg;
    }
};

/// A root Comment on new lines 2 to 4, a Suggestion Reply, and a reply Draft
/// to that Reply, painted through the DiffPane path.
fn paintCardThread(a: std.mem.Allocator, layout: buffer_mod.Layout, width: u16, cursor: CardTestCursor, theme: Theme) !CardTestPane {
    const comments = try a.dupe(bbr.review.Comment, &.{
        .{ .id = 1, .author = "Ada", .body = "one\n\ntwo\n\nthree", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 2, .to = 4 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "```suggestion\nfour!\n```" },
    });
    const drafts = try a.dupe(bbr.review.Draft, &.{
        .{ .local_id = 1, .kind = .comment, .body = "draft reply", .parent = .{ .comment = 2 } },
    });
    return paintCards(a, comments, drafts, layout, width, switch (cursor) {
        .plain_line => .{ .line = 5 },
        .reply_draft => .{ .card = .{ .draft = 1 } },
    }, theme);
}

/// Paint the cards of `comments` and `drafts` on `card_test_diff` through the
/// DiffPane path, with the cursor on a new line or on the first body row of a card.
fn paintCards(a: std.mem.Allocator, comments: []const bbr.review.Comment, drafts: []const bbr.review.Draft, layout: buffer_mod.Layout, width: u16, focus: CardTestFocus, theme: Theme) !CardTestPane {
    return paintCardsOn(a, card_test_diff, comments, drafts, layout, width, focus, theme, &.{});
}

const CardTestFocus = union(enum) { line: u32, card: @import("review_card.zig").Owner };

fn paintCardsOn(a: std.mem.Allocator, diff_text: []const u8, comments: []const bbr.review.Comment, drafts: []const bbr.review.Draft, layout: buffer_mod.Layout, width: u16, focus: CardTestFocus, theme: Theme, expanded_disclosures: []const buffer_mod.DisclosureKey) !CardTestPane {
    const diff = try bbr.diff.parse(a, diff_text);
    const threads = try bbr.review.buildThreads(a, comments);
    const buf = try buffer_mod.buildWithComments(a, diff, layout, threads, .{ .drafts = drafts, .card_width = width, .collapsed_rows = 2, .expanded_disclosures = expanded_disclosures });
    const visual_rows = try @import("frame.zig").buildVisualRowsWithOptions(a, buf.rows, .bytes, .{ .layout = layout, .width = width });
    const screen = try a.create(vaxis.Screen);
    screen.* = try vaxis.Screen.init(a, .{ .rows = @intCast(visual_rows.len), .cols = width, .x_pixel = 0, .y_pixel = 0 });
    var pane: CardTestPane = .{ .win = headlessWindow(screen), .buf = buf, .visual_rows = visual_rows };
    var nav = Nav.init(visual_rows.len, visual_rows.len);
    nav.jumpTo(switch (focus) {
        .line => |line| pane.lineRow(line),
        .card => |owner| pane.cardRow(owner, .body),
    });
    drawVisualPane(a, pane.win, buf, visual_rows, theme, nav);
    return pane;
}

test "M23 ancestry expanded resolved Threads keep their Anchor Indicator" {
    const comments = [_]bbr.review.Comment{
        .{ .id = 4, .author = "Dee", .body = "collapsed root", .resolved = true, .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 4 } } },
        .{ .id = 1, .author = "Ada", .body = "root", .resolved = true, .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 2, .to = 4 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
        .{ .id = 3, .author = "Cy", .body = "other root", .resolved = true, .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 4 } } },
    };
    const drafts = [_]bbr.review.Draft{.{ .local_id = 1, .kind = .comment, .body = "draft reply", .parent = .{ .comment = 2 } }};
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for ([_]CardTestFocus{
        .{ .card = .{ .comment = 1 } },
        .{ .card = .{ .comment = 2 } },
        .{ .card = .{ .draft = 1 } },
        .{ .card = .{ .comment = 3 } },
        .{ .line = 5 },
    }) |focus| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pane = try paintCardsOn(a, card_test_diff, &comments, &drafts, layout, 120, focus, theme_dark, &.{ .{ .resolved_thread = 1 }, .{ .resolved_thread = 3 } });
        if (focus == .line) {
            for (pane.lineRow(2)..pane.cardRow(.{ .comment = 3 }, .bottom) + 1) |row| try testing.expectEqualStrings(" ", pane.glyph(0, @intCast(row)));
            continue;
        }
        const other_root = std.meta.eql(focus.card, @import("review_card.zig").Owner{ .comment = 3 });
        const top = pane.lineRow(if (other_root) 4 else 2);
        const root = pane.cardRow(.{ .comment = if (other_root) 3 else 1 }, .header);
        try testing.expectEqualStrings("╭", pane.glyph(0, top));
        for (top + 1..root) |row| try testing.expectEqualStrings("│", pane.glyph(0, @intCast(row)));
        try testing.expectEqualStrings("╰", pane.glyph(0, root));
        try testing.expectEqualStrings("┬", pane.glyph(1, root));
        if (!other_root) try testing.expectEqualStrings(" ", pane.glyph(0, pane.cardRow(.{ .comment = 3 }, .header)));
    };
}

test "M23 ancestry resolved Thread disclosure names its author in bold green text" {
    const themes = @import("theme.zig");
    for (std.enums.values(ThemeId)) |id| for ([_]bool{ false, true }) |expanded| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const comments = [_]bbr.review.Comment{
            .{ .id = 1, .author = "Ada", .body = "root", .resolved = true },
            .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
        };
        const threads = try bbr.review.buildThreads(a, &comments);
        const buf = try buffer_mod.buildWithComments(a, .{ .files = &.{} }, .unified, threads, .{
            .card_width = 120,
            .expanded_disclosures = if (expanded) &.{.{ .resolved_thread = 1 }} else &.{},
        });
        const theme = themes.value(id);
        var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
        const win = headlessWindow(&screen);
        var found = false;
        for (buf.rows) |row| if (if (buffer_mod.disclosureKey(row)) |key| key == .resolved_thread else false) {
            found = true;
            if (expanded) {
                try testing.expect(row == .comment);
                try testing.expectEqual(@import("review_card.zig").Part.header, row.comment.part);
            }
            drawRow(a, win, 0, .unified, null, row, theme, .{});
        };
        try testing.expect(found);
        const pane: CardTestPane = .{ .win = win, .buf = buf, .visual_rows = &.{} };
        const text = try pane.text(a, 0);
        try testing.expect(std.mem.startsWith(u8, text, if (expanded) " ╭─ ▾ ✓ Resolved · Ada · 1 replies " else " ── ▸ ✓ Resolved · Ada · 1 replies "));
        try testing.expectEqualStrings(if (expanded) "╮" else "─", pane.glyph(win.width - 1, 0));
        try testing.expect(std.mem.indexOf(u8, text, "1 replies") != null);
        const cell = win.readCell(anchor_cols + 3, 0).?;
        try testing.expect(cell.style.bold);
        try testing.expect(!cell.style.dim);
        try testing.expectEqual(theme.status_added, cell.style.fg);
        try testing.expectEqual(theme.context.bg, cell.style.bg);
    };
}

test "M23 ancestry ReviewCards have rounded borders, Titles, an anchor indicator, and no Reply gaps" {
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for ([_]struct { width: u16, reply: usize, nested: usize }{
        .{ .width = 100, .reply = 5, .nested = 9 },
        .{ .width = 60, .reply = 3, .nested = 5 },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pane = try paintCardThread(a, layout, case.width, .reply_draft, theme_dark);
        const right = case.width - 1;

        try testing.expectEqualStrings(" ", pane.glyph(0, pane.lineRow(1)));
        try testing.expectEqualStrings("╭", pane.glyph(0, pane.lineRow(2)));
        try testing.expectEqualStrings("│", pane.glyph(0, pane.lineRow(3)));
        try testing.expectEqualStrings("│", pane.glyph(0, pane.lineRow(4)));
        try testing.expectEqualStrings(" ", pane.glyph(0, pane.lineRow(5)));

        const root = pane.cardRow(.{ .comment = 1 }, .header);
        try testing.expectEqual(pane.lineRow(4) + 1, root);
        try testing.expect(std.mem.startsWith(u8, try pane.text(a, root), "╰┬─ Ada ─"));
        try testing.expectEqualStrings("╮", pane.glyph(right, root));
        try testing.expect(std.mem.startsWith(u8, try pane.text(a, root + 1), " │ one "));
        try testing.expectEqualStrings("│", pane.glyph(right, root + 1));
        const footer = pane.cardRow(.{ .comment = 1 }, .disclosure_footer);
        const footer_text = try pane.text(a, footer);
        try testing.expect(std.mem.startsWith(u8, footer_text, " ╰─"));
        try testing.expect(std.mem.endsWith(u8, footer_text, " ▸ 3 hidden rows · 5 total · enter to expand ─╯"));

        try testing.expectEqualStrings("┬", pane.glyph(case.reply, footer));
        const reply = pane.cardRow(.{ .comment = 2 }, .header);
        try testing.expectEqual(footer + 1, reply);
        try testing.expect(std.mem.startsWith(u8, (try pane.text(a, reply))[case.reply..], "├─ Bob (suggestion) ─"));
        try testing.expectEqualStrings("╮", pane.glyph(right, reply));
        const reply_bottom = pane.cardRow(.{ .comment = 2 }, .bottom);
        try testing.expectEqualStrings("╰", pane.glyph(case.reply, reply_bottom));
        try testing.expectEqualStrings("┬", pane.glyph(case.nested, reply_bottom));
        try testing.expectEqualStrings("╯", pane.glyph(right, reply_bottom));

        const draft = pane.cardRow(.{ .draft = 1 }, .header);
        try testing.expectEqual(reply_bottom + 1, draft);
        try testing.expectEqualStrings("├", pane.glyph(case.nested, draft));
        try testing.expectEqualStrings("✎", pane.glyph(case.nested + 3, draft));
        try testing.expectEqualStrings(" ", pane.glyph(case.nested + 4, draft));
        try testing.expectEqualStrings("d", pane.glyph(case.nested + 5, draft));
        try testing.expectEqualStrings(" ", pane.glyph(case.nested + 10, draft));
        try testing.expectEqualStrings("─", pane.glyph(case.nested + 11, draft));
        try testing.expectEqualStrings("│", pane.glyph(case.nested, draft + 1));
        try testing.expectEqualStrings("d", pane.glyph(case.nested + 2, draft + 1));
        const draft_bottom = pane.cardRow(.{ .draft = 1 }, .bottom);
        try testing.expectEqualStrings("╰", pane.glyph(case.nested, draft_bottom));
        try testing.expectEqualStrings("╯", pane.glyph(right, draft_bottom));
        try testing.expectEqual(pane.lineRow(5), draft_bottom + 1);
    };
}

test "M23 ancestry a Reply joins the border above with ┬ and its own top-left corner with ├" {
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Ada", .body = "root", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 2, .to = 4 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "first" },
        .{ .id = 3, .parent_id = 2, .author = "Cy", .body = "nested" },
        .{ .id = 4, .parent_id = 1, .author = "Dee", .body = "second" },
        .{ .id = 5, .parent_id = 1, .author = "Eve", .body = "third" },
    };
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pane = try paintCards(a, &comments, &.{}, layout, 100, .{ .line = 5 }, theme_dark);
        const reply = pane.cardIndent(.{ .comment = 2 });
        const nested = pane.cardIndent(.{ .comment = 3 });
        try testing.expect(reply > 0 and nested > reply);
        const root_bottom = pane.cardRow(.{ .comment = 1 }, .bottom);
        try testing.expectEqualStrings("╰", pane.glyph(1, root_bottom));
        try testing.expectEqualStrings("┬", pane.glyph(reply, root_bottom));
        try testing.expectEqual(root_bottom + 1, pane.cardRow(.{ .comment = 2 }, .header));
        try testing.expectEqualStrings("├", pane.glyph(reply, pane.cardRow(.{ .comment = 2 }, .header)));

        const first_bottom = pane.cardRow(.{ .comment = 2 }, .bottom);
        try testing.expectEqualStrings("┬", pane.glyph(nested, first_bottom));
        try testing.expectEqualStrings("├", pane.glyph(nested, pane.cardRow(.{ .comment = 3 }, .header)));

        const second_bottom = pane.cardRow(.{ .comment = 4 }, .bottom);
        try testing.expectEqualStrings("├", pane.glyph(reply, second_bottom));
        try testing.expectEqual(second_bottom + 1, pane.cardRow(.{ .comment = 5 }, .header));
        try testing.expectEqualStrings("├", pane.glyph(reply, second_bottom + 1));
        try testing.expectEqualStrings("╰", pane.glyph(reply, pane.cardRow(.{ .comment = 5 }, .bottom)));
    }
}

test "M23 ancestry a Reply with a later sibling keeps its line down to that sibling" {
    const Owner = @import("review_card.zig").Owner;
    const Case = struct {
        comments: []const bbr.review.Comment,
        drafts: []const bbr.review.Draft,
        siblings: []const [2]Owner,
        last: []const Owner,
    };
    const root: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "root", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 2, .to = 4 } } };
    const cases = [_]Case{
        .{
            .comments = &.{ root, .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "first" } },
            .drafts = &.{
                .{ .local_id = 1, .kind = .comment, .body = "nested", .parent = .{ .comment = 2 } },
                .{ .local_id = 2, .kind = .comment, .body = "second", .parent = .{ .comment = 1 } },
            },
            .siblings = &.{.{ .{ .comment = 2 }, .{ .draft = 2 } }},
            .last = &.{ .{ .draft = 1 }, .{ .draft = 2 } },
        },
        .{
            .comments = &.{
                root,
                .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "first" },
                .{ .id = 3, .parent_id = 2, .author = "Cy", .body = "nested one" },
                .{ .id = 4, .parent_id = 2, .author = "Dee", .body = "nested two" },
            },
            .drafts = &.{
                .{ .local_id = 1, .kind = .comment, .body = "deepest", .parent = .{ .comment = 3 } },
                .{ .local_id = 2, .kind = .comment, .body = "second", .parent = .{ .comment = 1 } },
            },
            .siblings = &.{ .{ .{ .comment = 2 }, .{ .draft = 2 } }, .{ .{ .comment = 3 }, .{ .comment = 4 } } },
            .last = &.{ .{ .draft = 1 }, .{ .comment = 4 }, .{ .draft = 2 } },
        },
    };
    for (cases) |case| for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pane = try paintCards(a, case.comments, case.drafts, layout, 100, .{ .line = 5 }, theme_dark);
        for (case.siblings) |pair| {
            const column = pane.cardIndent(pair[0]);
            try testing.expectEqual(column, pane.cardIndent(pair[1]));
            const bottom = pane.cardRow(pair[0], .bottom);
            const next = pane.cardRow(pair[1], .header);
            try testing.expect(next > bottom + 2);
            try testing.expectEqualStrings("├", pane.glyph(column, bottom));
            for (bottom + 1..next) |row| try testing.expectEqualStrings("│", pane.glyph(column, @intCast(row)));
            try testing.expectEqualStrings("├", pane.glyph(column, next));
        }
        for (case.last) |owner| try testing.expectEqualStrings("╰", pane.glyph(pane.cardIndent(owner), pane.cardRow(owner, .bottom)));
    };
}

test "M23 ancestry a Reply join never overwrites the disclosure footer Title" {
    // At depth 6 of 60 columns the footer Title starts at the Reply's column.
    var comments: [8]bbr.review.Comment = undefined;
    for (&comments, 1..) |*comment, id| comment.* = .{
        .id = id,
        .parent_id = if (id > 1) id - 1 else null,
        .author = "Ada",
        .body = if (id == 7) "one\n\ntwo\n\nthree" else "x",
        .scope = if (id == 1) .{ .@"inline" = .{ .path = "a.zig", .start_to = 2, .to = 4 } } else null,
    };
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pane = try paintCards(a, &comments, &.{}, layout, 60, .{ .line = 5 }, theme_dark);
        const footer = pane.cardRow(.{ .comment = 7 }, .disclosure_footer);
        const reply = pane.cardIndent(.{ .comment = 8 });
        try testing.expectEqual(pane.cardIndent(.{ .comment = 7 }) + 2, reply);
        try testing.expectEqualStrings(" ", pane.glyph(reply, footer));
        try testing.expectEqualStrings("▸", pane.glyph(reply + 1, footer));
        try testing.expectEqual(footer + 1, pane.cardRow(.{ .comment = 8 }, .header));
        try testing.expectEqualStrings("├", pane.glyph(reply, footer + 1));
    }
}

test "a ReviewCard paints the Theme base background" {
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Ada", .body = "one\n\ntwo\n\nthree", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 2, .to = 4 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply with `code`" },
        .{ .id = 3, .parent_id = 1, .author = "Cy", .body = "", .deleted = true },
        .{ .id = 4, .author = "Dee", .body = "", .deleted = true, .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 5 } } },
    };
    const drafts = [_]bbr.review.Draft{
        .{ .local_id = 1, .kind = .comment, .body = "draft reply", .parent = .{ .comment = 1 } },
        .{ .local_id = 2, .kind = .comment, .body = "unknown reply", .parent = .{ .comment = 1 }, .state = .outcome_unknown },
        .{ .local_id = 3, .kind = .comment, .body = "root draft", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1 } } },
        .{ .local_id = 4, .kind = .comment, .body = "unknown root", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 1 } }, .state = .outcome_unknown },
    };
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for (@import("theme.zig").builtins) |builtin| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const theme = builtin.value;
        const pane = try paintCards(a, &comments, &drafts, layout, 100, .{ .line = 5 }, theme);
        var roles = std.EnumSet(@import("review_card.zig").CardRole).initEmpty();
        for (pane.visual_rows, 0..) |visual, row| switch (pane.buf.rows[visual.buffer_index]) {
            .comment, .draft => |card| if (!card.part.hasCodeBackground()) {
                roles.insert(card.role);
                for (0..pane.win.width) |col| {
                    errdefer std.debug.print("Theme {s} {t} {t} cell {d},{d}\n", .{ builtin.name, card.role, card.part, col, row });
                    try testing.expectEqual(theme.context.bg, pane.bg(col, @intCast(row)));
                }
            },
            else => {},
        };
        try testing.expectEqual(std.meta.tags(@import("review_card.zig").CardRole).len, roles.count());
    };
}

const card_test_diff =
    \\diff --git a/a.zig b/a.zig
    \\--- a/a.zig
    \\+++ b/a.zig
    \\@@ -1,2 +1,5 @@
    \\ one
    \\+two
    \\+three
    \\+four
    \\ five
    \\
;

test "M23 ancestry the dim band covers only anchored Diff Lines and leaves parent cards unchanged" {
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for (@import("theme.zig").builtins) |builtin| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const theme = builtin.value;
        const width: u16 = 100;
        const body: usize = if (layout == .unified) gutter_cols else width / 2 + 1 + side_gutter;

        const plain = try paintCardThread(a, layout, width, .plain_line, theme);
        try testing.expectEqual(theme.added.bg, plain.bg(body, plain.lineRow(3)));
        try testing.expectEqual(theme.comment.bg, plain.bg(2, plain.cardRow(.{ .comment = 1 }, .body)));

        const pane = try paintCardThread(a, layout, width, .reply_draft, theme);
        for ([_]u32{ 2, 3, 4 }) |line| try testing.expectEqual(theme.ancestryBg(theme.added.bg), pane.bg(body, pane.lineRow(line)));
        try testing.expectEqual(theme.context.bg, pane.bg(body, pane.lineRow(1)));
        try testing.expectEqual(theme.context.bg, pane.bg(body, pane.lineRow(5)));
        const root = pane.cardRow(.{ .comment = 1 }, .header);
        for (root..pane.cardRow(.{ .comment = 1 }, .disclosure_footer) + 1) |row| {
            for ([_]usize{ 0, 2, width - 1 }) |col| try testing.expectEqual(theme.comment.bg, pane.bg(col, @intCast(row)));
        }
        for ([_]u16{ pane.cardRow(.{ .comment = 2 }, .header), pane.cardRow(.{ .comment = 2 }, .bottom) }) |row| {
            try testing.expectEqual(theme.comment_reply.bg, pane.bg(5, row));
        }
        const draft = pane.cardRow(.{ .draft = 1 }, .header);
        try testing.expectEqual(theme.draft_reply.bg, pane.bg(9, draft));
        try testing.expectEqual(theme.cursorBg(theme.draft_reply.bg), pane.bg(10, draft + 1));
        try testing.expectEqual(theme.draft_reply.bg, pane.bg(9, pane.cardRow(.{ .draft = 1 }, .bottom)));

        const drafts = [_]bbr.review.Draft{
            .{ .local_id = 1, .kind = .comment, .body = "parent", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 2 } } },
            .{ .local_id = 2, .kind = .comment, .body = "parent Reply", .parent = .{ .draft = 1 }, .state = .outcome_unknown },
            .{ .local_id = 3, .kind = .comment, .body = "cursor", .parent = .{ .draft = 2 } },
        };
        const draft_pane = try paintCards(a, &.{}, &drafts, layout, width, .{ .card = .{ .draft = 3 } }, theme);
        for ([_]u64{ 1, 2 }) |id| {
            const owner: @import("review_card.zig").Owner = .{ .draft = id };
            const header = draft_pane.cardRow(owner, .header);
            const bottom = draft_pane.cardRow(owner, .bottom);
            for (header..bottom + 1) |row| for (0..width) |col| {
                try testing.expectEqual(theme.context.bg, draft_pane.bg(col, @intCast(row)));
            };
        }
        const cursor = draft_pane.cardRow(.{ .draft = 3 }, .body);
        try testing.expectEqual(theme.cursorBg(theme.draft_reply.bg), draft_pane.bg(10, cursor));
    };
}

const stack_test_diff =
    \\diff --git a/a.zig b/a.zig
    \\--- a/a.zig
    \\+++ b/a.zig
    \\@@ -19,8 +19,8 @@
    \\ l19
    \\ l20
    \\ l21
    \\-old22
    \\+l22
    \\ l23
    \\ l24
    \\ l25
    \\ l26
    \\
;

test "M23 ancestry only the active path shows its Anchor Indicator" {
    const check = struct {
        fn isBoxGlyph(grapheme: []const u8) bool {
            for ([_][]const u8{ "╭", "╮", "╰", "╯", "│", "─", "├", "┤", "┬", "┴", "┼" }) |box| if (std.mem.eql(u8, grapheme, box)) return true;
            return false;
        }

        /// Every border cell and the Title of the card that `owner` names has the
        /// normal or the dim card border foreground. A `┬` right of the left border
        /// joins a Reply, so the caller checks it.
        fn expectCardChrome(pane: CardTestPane, theme: Theme, owner: @import("review_card.zig").Owner, normal: bool) !void {
            var seen = false;
            for (pane.visual_rows, 0..) |visual, row| switch (pane.buf.rows[visual.buffer_index]) {
                .comment, .draft => |card| if (std.meta.eql(card.owner, owner)) {
                    seen = true;
                    const expected = if (normal) theme.reviewCardStyle(card.role, .body, .{}).fg else theme.card_border_dim.fg;
                    for (card.indent..card.rightBorderColumn() + 1) |col| {
                        const cell = pane.win.readCell(@intCast(col), @intCast(row)).?;
                        const title = card.part == .header and col == card.indent + 3;
                        if (!title and !isBoxGlyph(cell.char.grapheme)) continue;
                        if (col > card.indent and std.mem.eql(u8, cell.char.grapheme, "┬")) continue;
                        errdefer std.debug.print("card {any} {t} cell {d},{d} '{s}'\n", .{ owner, card.part, col, row, cell.char.grapheme });
                        try testing.expectEqual(expected, cell.style.fg);
                    }
                },
                else => {},
            };
            try testing.expect(seen);
        }

        /// Column 0 holds `╭` on row `top`, `│` down to the root card's top border,
        /// and `╰` there, which joins the card's top-left corner `┬` in column 1.
        /// Every other Diff Line and card row has a blank column 0.
        fn expectIndicator(pane: CardTestPane, theme: Theme, indicator: ?struct { top: u16, root: u16 }) !void {
            for (pane.visual_rows, 0..) |visual, index| {
                const row: u16 = @intCast(index);
                switch (pane.buf.rows[visual.buffer_index]) {
                    .line, .line_pair, .comment, .draft => {},
                    else => continue,
                }
                const expected = if (indicator) |span|
                    (if (row == span.top) "╭" else if (row > span.top and row < span.root) "│" else if (row == span.root) "╰" else " ")
                else
                    " ";
                errdefer std.debug.print("indicator row {d}\n", .{row});
                try testing.expectEqualStrings(expected, pane.glyph(0, row));
                if (indicator != null and !std.mem.eql(u8, expected, " ")) {
                    try testing.expectEqual(theme.reviewCardStyle(.comment, .body, .{}).fg, pane.win.readCell(0, row).?.style.fg);
                }
            }
            if (indicator) |span| try testing.expectEqualStrings("┬", pane.glyph(1, span.root));
        }
    };
    const Owner = @import("review_card.zig").Owner;
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Ada", .body = "a", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 21, .to = 23 } } },
        .{ .id = 2, .author = "Bob", .body = "b", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 22, .to = 23 } } },
        .{ .id = 3, .author = "Cy", .body = "c", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 23 } } },
        .{ .id = 4, .author = "Dee", .body = "d", .scope = .{ .@"inline" = .{ .path = "a.zig", .start_to = 22, .to = 25 } } },
        .{ .id = 5, .author = "Eve", .body = "e", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 26 } } },
        .{ .id = 6, .parent_id = 5, .author = "Fay", .body = "reply" },
        .{ .id = 7, .parent_id = 6, .author = "Gus", .body = "nested" },
        .{ .id = 8, .parent_id = 5, .author = "Hal", .body = "sibling" },
        .{ .id = 9, .parent_id = 7, .author = "Ivy", .body = "child" },
    };
    const all = [_]Owner{ .{ .comment = 1 }, .{ .comment = 2 }, .{ .comment = 3 }, .{ .comment = 4 }, .{ .comment = 5 }, .{ .comment = 6 }, .{ .comment = 7 }, .{ .comment = 8 }, .{ .comment = 9 } };
    const Case = struct { focus: CardTestFocus, normal: []const u64, top: ?u32 = null };
    const cases = [_]Case{
        .{ .focus = .{ .line = 19 }, .normal = &.{} },
        .{ .focus = .{ .card = .{ .comment = 2 } }, .normal = &.{2}, .top = 22 },
        .{ .focus = .{ .card = .{ .comment = 4 } }, .normal = &.{4}, .top = 22 },
        .{ .focus = .{ .card = .{ .comment = 7 } }, .normal = &.{ 5, 6, 7 }, .top = 26 },
        .{ .focus = .{ .card = .{ .comment = 8 } }, .normal = &.{ 5, 8 }, .top = 26 },
    };
    const theme = theme_dark;
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        errdefer std.debug.print("layout {t} focus {any}\n", .{ layout, case.focus });
        const pane = try paintCardsOn(a, stack_test_diff, &comments, &.{}, layout, 140, case.focus, theme, &.{});
        const root_id: u64 = if (case.normal.len > 0) case.normal[0] else 0;
        try check.expectIndicator(pane, theme, if (case.top) |top| .{ .top = pane.lineRow(top), .root = pane.cardRow(.{ .comment = root_id }, .header) } else null);
        for (all) |owner| try check.expectCardChrome(pane, theme, owner, std.mem.indexOfScalar(u64, case.normal, owner.comment) != null);

        const dim = theme.card_border_dim.fg;
        const reply = pane.cardIndent(.{ .comment = 6 });
        const nested_join = pane.win.readCell(@intCast(pane.cardIndent(.{ .comment = 9 })), pane.cardRow(.{ .comment = 7 }, .bottom)).?;
        try testing.expectEqualStrings("┬", nested_join.char.grapheme);
        // A join cell is part of the border above it, so it takes that card's style.
        try testing.expectEqual(if (std.mem.indexOfScalar(u64, case.normal, 7) != null) theme.comment_reply.fg else dim, nested_join.style.fg);
        const reply_join = pane.win.readCell(@intCast(pane.cardIndent(.{ .comment = 7 })), pane.cardRow(.{ .comment = 6 }, .bottom)).?;
        try testing.expectEqualStrings("┬", reply_join.char.grapheme);
        try testing.expectEqual(if (std.mem.indexOfScalar(u64, case.normal, 6) != null) theme.comment_reply.fg else dim, reply_join.style.fg);
        const rail_fg = if (case.focus == .card and case.focus.card.comment == 8) theme.comment_reply.fg else dim;
        for (pane.cardRow(.{ .comment = 6 }, .bottom) + 1..pane.cardRow(.{ .comment = 8 }, .header) - 1) |row| {
            const rail = pane.win.readCell(@intCast(reply), @intCast(row)).?;
            errdefer std.debug.print("rail row {d}\n", .{row});
            try testing.expectEqualStrings("│", rail.char.grapheme);
            try testing.expectEqual(rail_fg, rail.style.fg);
        }
    };
}

test "sibling rails use the Active Path role past more than one sibling" {
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Root", .body = "x", .scope = .{ .@"inline" = .{ .path = "a.zig", .to = 4 } } },
        .{ .id = 2, .parent_id = 1, .author = "A", .body = "x" },
        .{ .id = 3, .parent_id = 2, .author = "A child", .body = "x" },
        .{ .id = 4, .parent_id = 1, .author = "B", .body = "x" },
        .{ .id = 5, .parent_id = 4, .author = "B child", .body = "x" },
    };
    const drafts = [_]bbr.review.Draft{.{ .local_id = 1, .kind = .comment, .body = "x", .parent = .{ .comment = 1 }, .state = .outcome_unknown }};
    for ([_]buffer_mod.Layout{ .unified, .side_by_side }) |layout| for ([_]u16{ 60, 100 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const pane = try paintCards(arena.allocator(), &comments, &drafts, layout, width, .{ .card = .{ .draft = 1 } }, theme_dark);
        const expected = theme_dark.reviewCardStyle(.outcome_unknown_reply, .body, .{}).fg;
        for ([_][2]@import("review_card.zig").Owner{
            .{ .{ .comment = 2 }, .{ .comment = 4 } },
            .{ .{ .comment = 4 }, .{ .draft = 1 } },
        }) |pair| {
            const column = pane.cardIndent(pair[0]);
            for (pane.cardRow(pair[0], .bottom) + 1..pane.cardRow(pair[1], .header)) |row| {
                const cell = pane.win.readCell(@intCast(column), @intCast(row)).?;
                try testing.expectEqualStrings("│", cell.char.grapheme);
                try testing.expectEqual(expected, cell.style.fg);
            }
        }
    };
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
    const rects = @import("view.zig").solve(layouts.HelpSlot, layouts.help, @max(rows.motions.len, rows.commands.len), .{ .width = 80, .height = 24 });
    const modal = rects.get(.surface).border;
    try testing.expectEqualStrings("╭", win.readCell(modal.x, modal.y).?.char.grapheme);
    try testing.expectEqualStrings("╯", win.readCell(modal.x + modal.width - 1, modal.y + modal.height - 1).?.char.grapheme);
    // Title " Keybindings" begins one cell into the title row.
    const title = rects.get(.title).content;
    try testing.expectEqualStrings("K", win.readCell(title.x + 1, title.y).?.char.grapheme);
    // The first motion binding is `j`/`↓` → down.
    const motions = rects.get(.motions).content;
    try testing.expectEqualStrings("j", win.readCell(motions.x, motions.y).?.char.grapheme);
    const mouse = rects.get(.mouse).content;
    try testing.expectEqualStrings("M", win.readCell(mouse.x + 1, mouse.y).?.char.grapheme);
}

test "Selected Version help names horizontal keys and the absent File version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = buildHelpRows(arena.allocator(), .default, .{ .remote = true, .old_version = false });
    var old_found = false;
    var new_found = false;
    for (rows.commands) |row| {
        if (std.mem.indexOf(u8, row.text, "select old File version") != null) {
            old_found = true;
            try testing.expect(!row.available);
            try testing.expect(std.mem.indexOf(u8, row.text, "h ←") != null);
            try testing.expect(std.mem.indexOf(u8, row.text, "old File version absent") != null);
        }
        if (std.mem.indexOf(u8, row.text, "select new File version") != null) {
            new_found = true;
            try testing.expect(row.available);
            try testing.expect(std.mem.indexOf(u8, row.text, "l →") != null);
        }
    }
    try testing.expect(old_found and new_found);
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
    try testing.expect(!helpRowAvailable(rows.commands, "yank text (old content unavailable)").?);
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
