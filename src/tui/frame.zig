//! Atomic, terminal-independent Presentation Frame metadata.

const std = @import("std");
const bbr = @import("bbr");
const Nav = @import("nav.zig").Nav;
const buffer_mod = @import("buffer.zig");
const search = @import("search.zig");
pub const file_tree = @import("file_tree.zig");
pub const CellMetrics = @import("cell_metrics.zig").CellMetrics;
const view = @import("view.zig");
const layouts = @import("layouts.zig");
const scroll_marks = @import("scroll_marks.zig");
const KeyLists = @import("key_lists.zig").KeyLists;

pub const Revision = u64;

pub const Geometry = struct {
    cols: u16,
    rows: u16,
};

pub const Rect = view.Rect;

pub const PaneRects = struct {
    sidebar: Rect,
    diff: Rect,
    sidebar_content: Rect,
    /// The DiffPane body, right of the Selected Version marker column.
    diff_content: Rect,
    version_marker: Rect = .{},
    sidebar_track: Rect,
    diff_track: Rect,
};

pub const PaneFocus = enum { sidebar, diff };

pub const SelectedVersion = buffer_mod.SelectedVersion;

pub const VersionTitleTargets = struct {
    old: ?Rect = null,
    new: ?Rect = null,
};

const version_title_segment_width: u16 = 6;

/// Place the Selected Version control inside the DiffPane's top border, with
/// one blank cell on each side as every Title has. The path title receives
/// only the cells before these published rectangles.
pub fn versionTitleTargets(diff: Rect, selected: SelectedVersion) VersionTitleTargets {
    if (diff.height == 0 or diff.width <= 6) return .{};
    const start = diff.x + 3;
    const available = diff.width - 6;
    const full_width = version_title_segment_width * 2 + 1;
    if (available >= full_width) return .{
        .old = .{ .x = start + available - full_width, .y = diff.y, .width = version_title_segment_width, .height = 1 },
        .new = .{ .x = start + available - version_title_segment_width, .y = diff.y, .width = version_title_segment_width, .height = 1 },
    };

    const selected_width = @min(version_title_segment_width, available);
    const other_width = if (available > selected_width + 1)
        @min(version_title_segment_width, available - selected_width - 1)
    else
        0;
    return .{
        .old = if (selected == .old)
            .{ .x = start, .y = diff.y, .width = selected_width, .height = 1 }
        else if (other_width > 0)
            .{ .x = start, .y = diff.y, .width = other_width, .height = 1 }
        else
            null,
        .new = if (selected == .new)
            .{ .x = start + other_width + @intFromBool(other_width > 0), .y = diff.y, .width = selected_width, .height = 1 }
        else if (other_width > 0)
            .{ .x = start + selected_width + 1, .y = diff.y, .width = other_width, .height = 1 }
        else
            null,
    };
}

pub const OverlayKind = enum { list, review_search, help, other };

pub const ReviewSearchGeometry = struct {
    rect: Rect,
    body: Rect,
    list: Rect,
    preview: Rect,
    header: Rect,
    list_track: Rect,
    divider: u16,
    landscape: bool,
};

pub fn reviewSearchGeometry(geometry: Geometry) ?ReviewSearchGeometry {
    const rects = view.solve(layouts.SearchSlot, layouts.reviewSearch, layouts.ReviewSearch{}, area(geometry));
    const rect = rects.get(.surface).border;
    if (rect.isEmpty()) return null;
    const divider = rects.get(.divider).border;
    const landscape = geometry.cols >= geometry.rows;
    return .{
        .rect = rect,
        .body = rects.get(.body).border,
        .list = rects.get(.list).content,
        .preview = rects.get(.preview).content,
        .header = rects.get(.header).content,
        .list_track = rects.get(.list).track,
        .divider = if (landscape) divider.x else divider.y,
        .landscape = landscape,
    };
}

fn area(geometry: Geometry) Rect {
    return .{ .width = geometry.cols, .height = geometry.rows };
}

/// The help lines that the help Overlay shows at once.
pub fn helpBodyRows(geometry: Geometry, params: layouts.Help) u16 {
    return view.solve(layouts.HelpSlot, layouts.help, params, area(geometry)).get(.body).content.height;
}

pub const OverlayTarget = struct {
    kind: OverlayKind,
    rect: Rect,
    /// The rows of a List Overlay's entries, below its query row.
    entries: Rect = .{},
    row_count: usize = 0,
    /// The rows of the Review Search list, from `Published.reviewSearchListTotal`.
    list_total: usize = 0,
    scroll: usize = 0,
    review_search: ?ReviewSearchGeometry = null,
    /// The numbers of the help scroll bar, from `helpOverlayTarget`.
    help: ?ScrollState = null,
};

/// Every scroll bar on screen. A new scroll bar is one arm here, and
/// `scrollState` gives it its numbers.
pub const ScrollBar = enum { sidebar, diff_pane, review_search_list, help };

/// The numbers that paint and hit testing share for one scroll bar.
pub const ScrollState = struct {
    track: Rect,
    total: usize,
    /// The first visible row.
    offset: usize,

    pub fn thumb(self: ScrollState) ?view.Thumb {
        return view.thumb(self.track.height, self.total, self.offset);
    }
};

/// The track, total, and offset of `bar`, or null when `bar` is not on screen.
pub fn scrollState(projection: Projection, bar: ScrollBar) ?ScrollState {
    return switch (bar) {
        .sidebar => .{ .track = projection.panes.sidebar_track, .total = projection.file_tree.entries.len, .offset = projection.file_tree.scroll },
        .diff_pane => .{ .track = projection.panes.diff_track, .total = projection.visual_rows.len, .offset = projection.navigation.scroll },
        .review_search_list => {
            const overlay = projection.overlay orelse return null;
            const geometry = overlay.review_search orelse return null;
            return .{ .track = geometry.list_track, .total = overlay.list_total, .offset = overlay.scroll };
        },
        .help => (projection.overlay orelse return null).help,
    };
}

/// The numbers of `bar` while it takes a press and a Scroll Drag: it shows a
/// thumb, and only its own Overlay covers it. Hit testing and the Scroll Drag
/// share it.
pub fn scrollTarget(projection: Projection, bar: ScrollBar) ?ScrollState {
    const covered = switch (bar) {
        .sidebar, .diff_pane => projection.overlay != null,
        .review_search_list => if (projection.overlay) |overlay| overlay.kind != .review_search else true,
        .help => if (projection.overlay) |overlay| overlay.kind != .help else true,
    };
    if (covered) return null;
    const state = scrollState(projection, bar) orelse return null;
    _ = state.thumb() orelse return null;
    return state;
}

/// A track cell, counted from the top of the track.
pub const ScrollBarHit = struct { bar: ScrollBar, cell: u16 };

fn scrollBarHit(projection: Projection, bar: ScrollBar, col: u16, row: u16) ?ScrollBarHit {
    const state = scrollTarget(projection, bar) orelse return null;
    if (!state.track.contains(col, row)) return null;
    return .{ .bar = bar, .cell = row - state.track.y };
}

pub const HitTarget = union(enum) {
    select_old_version,
    select_new_version,
    scroll_bar: ScrollBarHit,
    sidebar,
    diff,
    sidebar_entry: usize,
    diff_row: usize,
    list_entry: usize,
    review_search_entry: usize,
    review_search_list,
    review_search_preview,
};

/// The identity of a Line row in every Frame of a Session. A Hunk Line lives
/// as long as the Session, so its pointer is the identity. Each Buffer build
/// makes its own Whole File gap Lines, so a gap Line is its File, side, and
/// line number.
pub const LineOwner = union(enum) {
    hunk_line: *const bbr.diff.Line,
    gap: struct { file: *const bbr.diff.File, side: SelectedVersion, number: u32 },

    /// `file` is the File of the row. Only a gap Line reads it, and every gap
    /// Line row follows the header of its File.
    pub fn of(file: ?*const bbr.diff.File, line: *const bbr.diff.Line) LineOwner {
        if (line.in_hunk) return .{ .hunk_line = line };
        std.debug.assert((line.old_no == 0) != (line.new_no == 0));
        return .{ .gap = .{
            .file = file.?,
            .side = if (line.old_no != 0) .old else .new,
            .number = @max(line.old_no, line.new_no),
        } };
    }

    /// The owner of the other half of a SideBySide pair. A pair holds two
    /// Hunk Lines or two gap Lines of one File.
    fn sibling(self: LineOwner, line: *const bbr.diff.Line) LineOwner {
        return of(switch (self) {
            .hunk_line => null,
            .gap => |gap| gap.file,
        }, line);
    }

    pub fn oldNo(self: LineOwner) ?u32 {
        return switch (self) {
            .hunk_line => |line| line.oldNo(),
            .gap => |gap| if (gap.side == .old) gap.number else null,
        };
    }

    pub fn newNo(self: LineOwner) ?u32 {
        return switch (self) {
            .hunk_line => |line| line.newNo(),
            .gap => |gap| if (gap.side == .new) gap.number else null,
        };
    }
};

pub const RowOwner = union(enum) {
    file: *const bbr.diff.File,
    hunk: *const bbr.diff.model.Hunk,
    status_placeholder: struct { file: *const bbr.diff.File, old: bool, new: bool },
    line: LineOwner,
    disclosure: buffer_mod.DisclosureKey,
    comment: struct { id: bbr.review.CommentId, source_offset: usize, part: ?@import("review_card.zig").Part = null },
    draft: struct { id: bbr.review.TempId, source_offset: usize, part: ?@import("review_card.zig").Part = null },
    snapshot: struct { id: bbr.review.TempId, source_offset: usize },
    section: struct { kind: buffer_mod.SectionKind, path: []const u8 },

    pub fn eql(a: RowOwner, b: RowOwner) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .file => |value| value == b.file,
            .hunk => |value| value == b.hunk,
            .status_placeholder => |value| value.file == b.status_placeholder.file and value.old == b.status_placeholder.old and value.new == b.status_placeholder.new,
            .line => |value| std.meta.eql(value, b.line),
            .disclosure => |value| std.meta.eql(value, b.disclosure),
            .comment => |value| value.id == b.comment.id and value.source_offset == b.comment.source_offset and value.part == b.comment.part,
            .draft => |value| value.id == b.draft.id and value.source_offset == b.draft.source_offset and value.part == b.draft.part,
            .snapshot => |value| value.id == b.snapshot.id and value.source_offset == b.snapshot.source_offset,
            .section => |value| value.kind == b.section.kind and std.mem.eql(u8, value.path, b.section.path),
        };
    }
};

/// One geometry-dependent DiffPane row. `buffer_index` resolves the cold Row
/// through the Buffer while the remaining fields describe this projection.
pub const VisualRow = struct {
    buffer_index: usize = 0,
    kind: buffer_mod.RowKind = .line,
    owner: RowOwner,
    source_start: usize = 0,
    source_end: usize = 0,
    continuation: bool = false,
    halves: ?Halves = null,
    yank_candidates: YankCandidates = .{},
};

pub const YankCandidates = struct {
    old: ?*const bbr.diff.Line = null,
    new: ?*const bbr.diff.Line = null,
};

pub fn selectedSource(row: VisualRow, version: SelectedVersion) ?*const bbr.diff.Line {
    return switch (version) {
        .old => row.yank_candidates.old,
        .new => row.yank_candidates.new,
    };
}

pub const VisualHalf = struct {
    line: *const bbr.diff.Line,
    source_start: usize,
    source_end: usize,
    continuation: bool,
};

pub const Halves = struct {
    left: ?VisualHalf = null,
    right: ?VisualHalf = null,
};

pub const VisualRowOptions = struct {
    layout: buffer_mod.Layout,
    width: usize,
};

pub const ProjectedSourceRange = struct {
    visual_row: usize,
    relation: search.VersionRelation,
    source: search.Range,
    row: search.Range,
    active: bool,
    occurrence_index: ?usize = null,
    definition: ?search.Range = null,
};

pub const Projection = struct {
    revision: Revision,
    visual_rows_revision: Revision,
    geometry: Geometry,
    panes: PaneRects,
    overlay: ?OverlayTarget = null,
    visual_rows: []const VisualRow,
    buffer: buffer_mod.Buffer,
    /// The Scroll Marks of `visual_rows`, built with them.
    row_marks: []const scroll_marks.RowMark = &.{},
    navigation: Nav,
    file_tree: file_tree.Projection = .{},
    focus: PaneFocus = .diff,
    selected_version: SelectedVersion = .new,
    version_title_targets: VersionTitleTargets = .{},
    /// Sorted by visual row.
    search_ranges: []const ProjectedSourceRange = &.{},
    buffer_search_active: ?usize = null,
    buffer_search_ranges: bool = false,
    code_highlights: []const @import("code_highlighting.zig").View = &.{},
    code_highlight_retained_bytes: usize = 0,
};

/// Resolve a cell solely against the immutable, already-published Frame. An
/// Overlay captures the complete input surface, even outside its rectangle.
pub fn hitTest(frame: Projection, col: u16, row: u16) ?HitTarget {
    if (frame.overlay) |overlay| {
        if (overlay.kind == .review_search) {
            const geometry = overlay.review_search orelse return null;
            if (scrollBarHit(frame, .review_search_list, col, row)) |hit| return .{ .scroll_bar = hit };
            if (geometry.list.contains(col, row)) {
                const index = overlay.scroll + row - geometry.list.y;
                if (index < overlay.row_count) return .{ .review_search_entry = index };
                return .review_search_list;
            }
            if (geometry.preview.contains(col, row)) return .review_search_preview;
            return null;
        }
        if (overlay.kind == .help) return if (scrollBarHit(frame, .help, col, row)) |hit| .{ .scroll_bar = hit } else null;
        if (overlay.kind != .list or !overlay.entries.contains(col, row)) return null;
        const index = overlay.scroll + row - overlay.entries.y;
        if (index >= overlay.row_count) return null;
        return .{ .list_entry = index };
    }

    if (frame.version_title_targets.old) |rect| if (rect.contains(col, row)) return .select_old_version;
    if (frame.version_title_targets.new) |rect| if (rect.contains(col, row)) return .select_new_version;
    for ([_]ScrollBar{ .sidebar, .diff_pane }) |bar| if (scrollBarHit(frame, bar, col, row)) |hit| return .{ .scroll_bar = hit };

    if (frame.panes.sidebar_content.contains(col, row)) {
        const index = frame.file_tree.scroll + row - frame.panes.sidebar_content.y;
        if (index < frame.file_tree.entries.len) return .{ .sidebar_entry = index };
        return .sidebar;
    }
    if (frame.panes.diff_content.contains(col, row) or frame.panes.version_marker.contains(col, row)) {
        const index = frame.navigation.scroll + row - frame.panes.diff_content.y;
        if (index < frame.visual_rows.len) return .{ .diff_row = index };
        return .diff;
    }
    return null;
}

pub fn paneRects(geometry: Geometry) PaneRects {
    const rects = view.solve(layouts.PaneSlot, layouts.panes, layouts.Panes{}, area(geometry));
    return .{
        .sidebar = rects.get(.sidebar).border,
        .diff = rects.get(.diff).border,
        .sidebar_content = rects.get(.sidebar).content,
        .diff_content = rects.get(.diff_body).content,
        .version_marker = rects.get(.version_marker).content,
        .sidebar_track = rects.get(.sidebar).track,
        .diff_track = rects.get(.diff).track,
    };
}

/// The List Overlay geometry that rendering and input targeting share. A
/// zero-sized Frame has no targetable Overlay.
pub fn listOverlayTarget(geometry: Geometry, box: layouts.Box) ?OverlayTarget {
    const rects = view.solve(layouts.ListSlot, layouts.listOverlay, layouts.ListOverlay{ .box = box }, area(geometry));
    const rect = rects.get(.surface).border;
    if (rect.isEmpty()) return null;
    return .{ .kind = .list, .rect = rect, .entries = rects.get(.entries).content };
}

/// The help Overlay captures the whole Frame. Its scroll bar shows the stored
/// scroll clamped to the last page, as the help scroll keys clamp it.
pub fn helpOverlayTarget(geometry: Geometry, params: layouts.Help) ?OverlayTarget {
    var target = screenOverlayTarget(geometry) orelse return null;
    const track = view.solve(layouts.HelpSlot, layouts.help, params, area(geometry)).get(.body).track;
    target.kind = .help;
    target.help = .{ .track = track, .total = params.scroll.total, .offset = @min(params.scroll.offset, params.scroll.total -| track.height) };
    return target;
}

/// An Overlay without row targets captures the whole Frame.
pub fn screenOverlayTarget(geometry: Geometry) ?OverlayTarget {
    if (geometry.cols == 0 or geometry.rows == 0) return null;
    return .{ .kind = .other, .rect = area(geometry) };
}

pub fn buildVisualRowsWithOptions(
    allocator: std.mem.Allocator,
    rows: []const buffer_mod.Row,
    metrics: CellMetrics,
    options: VisualRowOptions,
) ![]const VisualRow {
    if ((options.layout == .unified and options.width <= unified_gutter_cols) or
        (options.layout == .side_by_side and sideBodyWidths(options.width) == null))
    {
        return buildUnwrappedVisualRows(allocator, rows);
    }

    var visual_rows: std.ArrayList(VisualRow) = .empty;
    errdefer visual_rows.deinit(allocator);
    // SideBySide makes about 1.44 visual rows per Buffer row. The unused tail is never touched.
    try visual_rows.ensureTotalCapacityPrecise(allocator, rows.len + rows.len / 2);
    if (options.layout == .side_by_side) {
        const widths = sideBodyWidths(options.width).?;
        var file: ?*const bbr.diff.File = null;
        for (rows, 0..) |row, buffer_index| switch (row) {
            .line_pair => |pair| try appendWrappedLinePair(allocator, &visual_rows, buffer_index, pair, widths, metrics, file),
            else => {
                if (row == .file_header) file = row.file_header.file;
                try visual_rows.append(allocator, makeVisualRow(row, buffer_index, file));
            },
        };
        return visual_rows.toOwnedSlice(allocator);
    }

    const body_width = options.width - unified_gutter_cols;
    var file: ?*const bbr.diff.File = null;
    for (rows, 0..) |row, buffer_index| switch (row) {
        .line => |line_row| {
            if (line_row.line.text.len == 0) {
                try visual_rows.append(allocator, makeVisualRow(row, buffer_index, file));
                continue;
            }
            const wrap: WrapLine = .init(line_row.line.text, metrics);
            var start: usize = 0;
            while (start < line_row.line.text.len) {
                const end = wrap.end(start, body_width);
                try appendWrappedVisualRow(allocator, &visual_rows, row, buffer_index, start, end, file);
                start = end;
            }
        },
        else => {
            if (row == .file_header) file = row.file_header.file;
            try visual_rows.append(allocator, makeVisualRow(row, buffer_index, file));
        },
    };
    return visual_rows.toOwnedSlice(allocator);
}

const SideBodyWidths = struct { left: usize, right: usize };

/// Column 0 of the DiffPane holds the Anchor Indicator, so each gutter starts
/// after it.
pub const anchor_cols: usize = 1;
pub const side_gutter_cols: usize = anchor_cols + 5;
pub const side_divider_cols: usize = 1;

fn sideBodyWidths(width: usize) ?SideBodyWidths {
    if (width < side_divider_cols) return null;
    const left_half = width / 2;
    const right_half = width - left_half - side_divider_cols;
    if (left_half <= side_gutter_cols or right_half <= side_gutter_cols) return null;
    return .{ .left = left_half - side_gutter_cols, .right = right_half - side_gutter_cols };
}

fn appendWrappedLinePair(
    allocator: std.mem.Allocator,
    visual_rows: *std.ArrayList(VisualRow),
    buffer_index: usize,
    pair: buffer_mod.LinePair,
    widths: SideBodyWidths,
    metrics: CellMetrics,
    file: ?*const bbr.diff.File,
) !void {
    var left_start: usize = 0;
    var right_start: usize = 0;
    var left_done = pair.left == null;
    var right_done = pair.right == null;
    const left_wrap: ?WrapLine = if (pair.left) |half| .init(half.line.text, metrics) else null;
    const right_wrap: ?WrapLine = if (pair.right) |half| .init(half.line.text, metrics) else null;
    while (!left_done or !right_done) {
        const left = if (!left_done) makeVisualHalf(pair.left.?, left_start, widths.left, left_wrap.?) else null;
        const right = if (!right_done) makeVisualHalf(pair.right.?, right_start, widths.right, right_wrap.?) else null;
        const target = right orelse left.?;
        try visual_rows.append(allocator, .{
            .buffer_index = buffer_index,
            .kind = .line_pair,
            .owner = .{ .line = .of(file, target.line) },
            .source_start = target.source_start,
            .source_end = target.source_end,
            .continuation = target.continuation,
            .halves = .{ .left = left, .right = right },
            .yank_candidates = .{
                .old = if (left) |half| half.line else null,
                .new = if (right) |half| half.line else null,
            },
        });
        if (left) |half| {
            left_start = half.source_end;
            left_done = left_start >= half.line.text.len;
        }
        if (right) |half| {
            right_start = half.source_end;
            right_done = right_start >= half.line.text.len;
        }
    }
}

fn makeVisualHalf(line_row: buffer_mod.LineRow, start: usize, width: usize, wrap: WrapLine) VisualHalf {
    const end = if (line_row.line.text.len == 0) 0 else wrap.end(start, width);
    return .{
        .line = line_row.line,
        .source_start = start,
        .source_end = end,
        .continuation = start != 0,
    };
}

fn appendWrappedVisualRow(
    allocator: std.mem.Allocator,
    visual_rows: *std.ArrayList(VisualRow),
    row: buffer_mod.Row,
    buffer_index: usize,
    start: usize,
    end: usize,
    file: ?*const bbr.diff.File,
) !void {
    try visual_rows.append(allocator, .{
        .buffer_index = buffer_index,
        .kind = .line,
        .owner = owner(row, file),
        .source_start = start,
        .source_end = end,
        .continuation = start != 0,
        .yank_candidates = yankCandidates(row),
    });
}

fn buildUnwrappedVisualRows(allocator: std.mem.Allocator, rows: []const buffer_mod.Row) ![]const VisualRow {
    const visual_rows = try allocator.alloc(VisualRow, rows.len);
    var file: ?*const bbr.diff.File = null;
    for (rows, visual_rows, 0..) |row, *visual_row, buffer_index| {
        if (row == .file_header) file = row.file_header.file;
        visual_row.* = makeVisualRow(row, buffer_index, file);
    }
    return visual_rows;
}

fn makeVisualRow(row: buffer_mod.Row, buffer_index: usize, file: ?*const bbr.diff.File) VisualRow {
    return .{
        .buffer_index = buffer_index,
        .kind = std.meta.activeTag(row),
        .owner = owner(row, file),
        .source_start = rowSourceStart(row),
        .source_end = rowSourceEnd(row),
        .yank_candidates = yankCandidates(row),
    };
}

fn yankCandidates(row: buffer_mod.Row) YankCandidates {
    return switch (row) {
        .line => |value| candidatesForLine(value.line),
        .line_pair => |pair| .{
            .old = if (pair.left) |left| left.line else null,
            .new = if (pair.right) |right| right.line else null,
        },
        else => .{},
    };
}

fn candidatesForLine(line: *const bbr.diff.Line) YankCandidates {
    return .{
        .old = if (line.old_no != 0) line else null,
        .new = if (line.new_no != 0) line else null,
    };
}

pub const unified_gutter_cols: usize = anchor_cols + 10;

/// One Line to wrap. `init` checks the Line once for printable ASCII, not
/// once for each visual row.
const WrapLine = struct {
    text: []const u8,
    metrics: CellMetrics,
    narrow_ascii: bool,

    fn init(text: []const u8, metrics: CellMetrics) WrapLine {
        return .{ .text = text, .metrics = metrics, .narrow_ascii = metrics.narrowAscii(text) };
    }

    /// The end of the visual row that starts at `start`. On a printable ASCII
    /// Line each byte is one grapheme of one cell and the space is the only
    /// whitespace, so the end is the one the grapheme loop gives.
    fn end(self: WrapLine, start: usize, width: usize) usize {
        const text = self.text;
        if (self.narrow_ascii) {
            if (text.len - start <= width) return text.len;
            if (std.mem.lastIndexOfScalar(u8, text[start .. start + width], ' ')) |space| return start + space + 1;
            return start + @max(width, 1);
        }
        var pos = start;
        var cells: usize = 0;
        var whitespace_end: ?usize = null;
        while (pos < text.len) {
            const measured = self.metrics.next(text[pos..]);
            if (cells + measured.cell_width > width) {
                if (whitespace_end) |whitespace| if (whitespace > start) return whitespace;
                return if (pos > start) pos else @min(pos + measured.byte_len, text.len);
            }
            pos += measured.byte_len;
            cells += measured.cell_width;
            if (isUnicodeWhitespace(text[pos - measured.byte_len .. pos])) whitespace_end = pos;
        }
        return text.len;
    }
};

fn isUnicodeWhitespace(grapheme: []const u8) bool {
    const first_len = std.unicode.utf8ByteSequenceLength(grapheme[0]) catch |err| switch (err) {
        error.Utf8InvalidStartByte => return false,
    };
    if (first_len > grapheme.len) return false;
    const cp = std.unicode.utf8Decode(grapheme[0..first_len]) catch return false;
    return (cp >= 0x09 and cp <= 0x0d) or cp == 0x20 or cp == 0x85 or cp == 0xa0 or
        cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or
        cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

/// Built with the candidate Frame. Lookup does not allocate or walk the Frame.
pub const NavigationIndex = struct {
    const OwnerContext = struct {
        pub fn hash(_: @This(), key: RowOwner) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, std.meta.activeTag(key));
            switch (key) {
                .section => |value| {
                    std.hash.autoHash(&hasher, value.kind);
                    hasher.update(value.path);
                },
                inline else => |value| std.hash.autoHash(&hasher, value),
            }
            return hasher.final();
        }

        pub fn eql(_: @This(), a: RowOwner, b: RowOwner) bool {
            return a.eql(b);
        }
    };
    const Span = struct { start: usize, end: usize, row: usize, prefix_end: usize = 0 };
    const Owners = std.HashMapUnmanaged(RowOwner, usize, OwnerContext, 80);
    const Spans = KeyLists(RowOwner, Span, OwnerContext);

    /// The first row of each owner that is not a Line. A Line row resolves
    /// through `spans`, because its rows differ by source offset.
    owners: Owners = .empty,
    spans: Spans = .{},

    /// The caller owns all allocations through its Frame arena.
    pub fn build(a: std.mem.Allocator, rows: []const VisualRow) !NavigationIndex {
        var result: NavigationIndex = .{};
        var owner_rows: u32 = 0;
        for (rows) |row| owner_rows += @intFromBool(row.owner != .line);
        try result.owners.ensureTotalCapacity(a, owner_rows);
        for (rows, 0..) |row, index| if (row.owner != .line) {
            var key = row.owner;
            if (key == .section) key.section.path = try a.dupe(u8, key.section.path);
            const exact = try result.owners.getOrPut(a, key);
            if (!exact.found_existing) exact.value_ptr.* = index;
        };
        result.spans = try Spans.build(a, 2 * rows.len, @intCast(rows.len), SpanSource{ .rows = rows });
        var groups = result.spans.lists();
        while (groups.next()) |group| {
            std.mem.sort(Span, group, {}, spanLess);
            var end: usize = 0;
            for (group) |*span| {
                end = @max(end, span.end);
                span.prefix_end = end;
            }
        }
        return result;
    }

    /// Each row adds at most two spans, one for each half.
    const SpanSource = struct {
        rows: []const VisualRow,

        pub fn each(self: SpanSource, sink: anytype) !void {
            for (self.rows, 0..) |row, index| {
                if (row.halves) |halves| {
                    if (halves.right) |half| try sink.add(.{ .line = row.owner.line.sibling(half.line) }, .{ .start = half.source_start, .end = half.source_end, .row = index });
                    if (halves.left) |half| if (halves.right == null or halves.right.?.line != half.line)
                        try sink.add(.{ .line = row.owner.line.sibling(half.line) }, .{ .start = half.source_start, .end = half.source_end, .row = index });
                } else switch (row.owner) {
                    .line => try sink.add(row.owner, .{ .start = row.source_start, .end = row.source_end, .row = index }),
                    .comment => |value| if (value.part != .header) {
                        try sink.add(.{ .comment = .{ .id = value.id, .source_offset = 0 } }, .{ .start = value.source_offset, .end = row.source_end, .row = index });
                    },
                    .draft => |value| if (value.part != .header) {
                        try sink.add(.{ .draft = .{ .id = value.id, .source_offset = 0 } }, .{ .start = value.source_offset, .end = row.source_end, .row = index });
                    },
                    else => {},
                }
            }
        }
    };

    fn spanLess(_: void, a: Span, b: Span) bool {
        return a.start < b.start or a.start == b.start and a.row < b.row;
    }

    pub fn find(self: NavigationIndex, wanted: VisualRow) ?usize {
        if (wanted.owner != .line) if (self.owners.get(wanted.owner)) |row| return row;
        const key: RowOwner = switch (wanted.owner) {
            .line => wanted.owner,
            .comment => |value| .{ .comment = .{ .id = value.id, .source_offset = 0 } },
            .draft => |value| .{ .draft = .{ .id = value.id, .source_offset = 0 } },
            else => return null,
        };
        const offset = switch (wanted.owner) {
            .comment => |value| value.source_offset,
            .draft => |value| value.source_offset,
            else => wanted.source_start,
        };
        const spans = self.spans.get(key);
        if (wanted.owner == .line) {
            var containing_low: usize = 0;
            var containing_high = spans.len;
            while (containing_low < containing_high) {
                const middle = containing_low + (containing_high - containing_low) / 2;
                if (spans[middle].prefix_end <= offset) containing_low = middle + 1 else containing_high = middle;
            }
            if (containing_low < spans.len and spans[containing_low].start <= offset) return spans[containing_low].row;
        }
        var low: usize = 0;
        var high = spans.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (spans[middle].prefix_end <= offset and spans[middle].start < offset) low = middle + 1 else high = middle;
        }
        if (low < spans.len) return spans[low].row;
        return if (wanted.owner == .line and spans.len > 0) spans[spans.len - 1].row else null;
    }
};

pub fn visualIndexForBufferIndex(rows: []const VisualRow, buffer_index: usize) ?usize {
    var low: usize = 0;
    var high = rows.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (rows[middle].buffer_index < buffer_index) low = middle + 1 else high = middle;
    }
    return if (low < rows.len and rows[low].buffer_index == buffer_index) low else null;
}

/// A navigation held by the identity of its rows, so that any later Frame of
/// the same Session can resolve it. State that outlives a Frame stores this,
/// not a `Nav`, because only `resolve` against a Frame yields its row numbers.
pub const NavigationAnchor = struct {
    count: usize,
    /// The rows between the top of the viewport and the cursor.
    cursor_offset: usize,
    cursor: ?VisualRow,
    mark: ?Mark,

    const Mark = struct {
        row: VisualRow,
        /// The mark and cursor rows of the capture Frame. A mark that is not
        /// on a Line keeps only when it resolves to the same range.
        captured_range: [2]usize,
    };

    pub fn capture(navigation: Nav, visual_rows: []const VisualRow) NavigationAnchor {
        const cursor = visualRowAt(visual_rows, navigation.cursor);
        const mark: ?Mark = if (navigation.mark) |mark| if (visualRowAt(visual_rows, mark)) |row| .{
            .row = identity(row),
            .captured_range = .{ @min(mark, navigation.cursor), @max(mark, navigation.cursor) },
        } else null else null;
        return .{
            .count = navigation.count,
            .cursor_offset = navigation.cursor -| navigation.scroll,
            .cursor = if (cursor) |row| identity(row) else null,
            .mark = mark,
        };
    }

    /// The navigation in the Frame of `visual_rows`. A cursor row that the
    /// Frame lost puts the cursor at the top of the Buffer.
    pub fn resolve(self: NavigationAnchor, visual_rows: []const VisualRow, geometry: Geometry, index: NavigationIndex) Nav {
        return self.resolveWith(visual_rows, geometry, index);
    }

    fn resolveWith(self: NavigationAnchor, visual_rows: []const VisualRow, geometry: Geometry, index: ?NavigationIndex) Nav {
        const viewport = paneRects(geometry).diff_content.height;
        var restored = Nav.init(visual_rows.len, viewport);
        restored.count = self.count;
        const cursor_row = self.cursor orelse return restored;
        const cursor = findRow(visual_rows, index, cursor_row) orelse return restored;
        restored.jumpTo(cursor);
        restored.count = self.count;
        restored.scroll = cursor -| self.cursor_offset;
        restored.setViewport(viewport);

        const mark = self.mark orelse return restored;
        const restored_mark = findRow(visual_rows, index, mark.row) orelse return restored;
        const range = [2]usize{ @min(restored_mark, cursor), @max(restored_mark, cursor) };
        if ((mark.row.owner == .line and cursor_row.owner == .line) or std.meta.eql(mark.captured_range, range)) restored.mark = restored_mark;
        return restored;
    }

    fn findRow(visual_rows: []const VisualRow, index: ?NavigationIndex, row: VisualRow) ?usize {
        return if (index) |lookup| lookup.find(row) else findVisualRow(visual_rows, row);
    }

    /// Row lookup reads only the owner and the source start. The other fields,
    /// such as `buffer_index`, are positions in the capture Frame.
    fn identity(row: VisualRow) VisualRow {
        return .{ .owner = row.owner, .source_start = row.source_start };
    }
};

pub fn restoreNavigationIndexed(previous: Projection, visual_rows: []const VisualRow, geometry: Geometry, index: NavigationIndex) Nav {
    return NavigationAnchor.capture(previous.navigation, previous.visual_rows).resolve(visual_rows, geometry, index);
}

/// Linear benchmark control and reference for indexed restoration.
pub fn restoreNavigation(previous: Projection, visual_rows: []const VisualRow, geometry: Geometry) Nav {
    return NavigationAnchor.capture(previous.navigation, previous.visual_rows).resolveWith(visual_rows, geometry, null);
}

pub fn resizeViewports(navigation: *Nav, tree: *file_tree.Projection, geometry: Geometry) void {
    const panes = paneRects(geometry);
    navigation.setViewport(panes.diff_content.height);
    tree.viewport = panes.sidebar_content.height;
    tree.scroll = @min(tree.scroll, tree.entries.len -| tree.viewport);
    if (tree.cursor < tree.scroll) tree.scroll = tree.cursor;
    if (tree.viewport > 0 and tree.cursor >= tree.scroll + tree.viewport) {
        tree.scroll = tree.cursor + 1 - tree.viewport;
    }
}

fn findVisualRow(visual_rows: []const VisualRow, wanted: VisualRow) ?usize {
    if (wanted.owner != .line) return findOwner(visual_rows, wanted.owner);
    var following: ?usize = null;
    var final: ?usize = null;
    for (visual_rows, 0..) |visual_row, index| {
        const range = lineRangeForOwner(visual_row, wanted.owner.line) orelse continue;
        final = index;
        if (range.start <= wanted.source_start and wanted.source_start < range.end) return index;
        if (following == null and range.start >= wanted.source_start) following = index;
    }
    return following orelse final;
}

const SourceRange = struct { start: usize, end: usize };

fn lineRangeForOwner(visual_row: VisualRow, line: LineOwner) ?SourceRange {
    if (visual_row.halves) |halves| {
        const row_line = visual_row.owner.line;
        if (halves.right) |half| if (std.meta.eql(row_line.sibling(half.line), line)) return .{ .start = half.source_start, .end = half.source_end };
        if (halves.left) |half| if (std.meta.eql(row_line.sibling(half.line), line)) return .{ .start = half.source_start, .end = half.source_end };
        return null;
    }
    if (!visual_row.owner.eql(.{ .line = line })) return null;
    return .{ .start = visual_row.source_start, .end = visual_row.source_end };
}

fn findOwner(visual_rows: []const VisualRow, wanted: RowOwner) ?usize {
    for (visual_rows, 0..) |visual_row, index| if (visual_row.owner.eql(wanted)) return index;
    // Width changes alter projected row starts. Restore a ReviewCard to the
    // same source offset's containing row, or the nearest following row. A
    // collapsed card's footer uses the body-end offset, so hidden content lands
    // on that disclosure instead of another item.
    var nearest: ?usize = null;
    var nearest_offset: usize = std.math.maxInt(usize);
    for (visual_rows, 0..) |visual_row, index| switch (wanted) {
        .comment => |value| if (visual_row.owner == .comment and visual_row.owner.comment.id == value.id and visual_row.owner.comment.part != .header and ((visual_row.owner.comment.source_offset <= value.source_offset and value.source_offset < visual_row.source_end) or visual_row.owner.comment.source_offset >= value.source_offset) and visual_row.owner.comment.source_offset < nearest_offset) {
            nearest = index;
            nearest_offset = visual_row.owner.comment.source_offset;
        },
        .draft => |value| if (visual_row.owner == .draft and visual_row.owner.draft.id == value.id and visual_row.owner.draft.part != .header and ((visual_row.owner.draft.source_offset <= value.source_offset and value.source_offset < visual_row.source_end) or visual_row.owner.draft.source_offset >= value.source_offset) and visual_row.owner.draft.source_offset < nearest_offset) {
            nearest = index;
            nearest_offset = visual_row.owner.draft.source_offset;
        },
        else => {},
    };
    if (nearest) |index| return index;
    return null;
}

fn visualRowAt(visual_rows: []const VisualRow, index: usize) ?VisualRow {
    if (index >= visual_rows.len) return null;
    return visual_rows[index];
}

fn owner(row: buffer_mod.Row, file: ?*const bbr.diff.File) RowOwner {
    if (buffer_mod.disclosureKey(row)) |key| if (key == .resolved_thread) return .{ .disclosure = key };
    return switch (row) {
        .file_header => |header| .{ .file = header.file },
        .hunk_header => |hunk| .{ .hunk = hunk },
        .status_placeholder => |value| .{ .status_placeholder = .{ .file = value.file, .old = value.old != null, .new = value.new != null } },
        .line => |line| .{ .line = .of(file, line.line) },
        .line_pair => |pair| .{ .line = .of(file, if (pair.right) |right| right.line else pair.left.?.line) },
        .disclosure => |value| .{ .disclosure = value.key },
        .comment => |card| switch (card.owner) {
            .comment => |id| .{ .comment = .{ .id = id, .source_offset = card.source_range.start, .part = anchorPart(card.part) } },
            else => unreachable,
        },
        .draft => |card| switch (card.owner) {
            .draft => |id| .{ .draft = .{ .id = id, .source_offset = card.source_range.start, .part = anchorPart(card.part) } },
            else => unreachable,
        },
        .snapshot => |snapshot| .{ .snapshot = .{ .id = snapshot.draft.local_id, .source_offset = if (snapshot.draft.snapshot) |value| sourceOffset(value.text, snapshot.line) else 0 } },
        .section => |section| .{ .section = .{ .kind = section.kind, .path = section.path } },
    };
}

fn anchorPart(part: @import("review_card.zig").Part) ?@import("review_card.zig").Part {
    return switch (part) {
        .header, .disclosure_footer, .bottom => part,
        .body, .code_body, .suggestion_label, .suggestion_body => null,
    };
}

fn rowSourceEnd(row: buffer_mod.Row) usize {
    return switch (row) {
        .line => |line| line.line.text.len,
        .line_pair => |pair| if (pair.right) |right| right.line.text.len else if (pair.left) |left| left.line.text.len else 0,
        .comment => |card| card.source_range.end,
        .draft => |card| card.source_range.end,
        else => 0,
    };
}

fn rowSourceStart(row: buffer_mod.Row) usize {
    return switch (row) {
        .comment => |card| card.source_range.start,
        .draft => |card| card.source_range.start,
        else => 0,
    };
}

fn sourceOffset(source: []const u8, part: []const u8) usize {
    const source_start = @intFromPtr(source.ptr);
    const part_start = @intFromPtr(part.ptr);
    if (part_start < source_start or part_start > source_start + source.len) return 0;
    return part_start - source_start;
}

const testing = std.testing;

test "zero-width non-source visual rows skip CellMetrics" {
    const Metrics = struct {
        calls: usize = 0,

        fn next(ptr: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ptr)));
            self.calls += 1;
            return .{ .byte_len = if (text.len == 0) 0 else 1, .cell_width = if (text.len > 0 and text[0] == 'w') 2 else 1 };
        }
    };
    const vtable: CellMetrics.VTable = .{ .next = Metrics.next };
    var metrics_context: Metrics = .{};
    const metrics: CellMetrics = .{ .ptr = &metrics_context, .vtable = &vtable };
    const rows = [_]buffer_mod.Row{.{ .section = .{ .kind = .outdated, .count = 1, .path = "w\x7fde" } }};

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, metrics, .{ .layout = .unified, .width = 0 });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(@as(usize, 0), metrics_context.calls);
}

test "Presentation Frame projects Diff Lines as complete visual rows" {
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "const answer = 42" };
    const old_line: bbr.diff.Line = .{ .old_no = 1, .new_no = 0, .kind = .removed, .text = "const answer = 41" };
    const runs = [_]bbr.highlight.decoration.Run{
        .{ .text = line.text[0..5], .capture = bbr.highlight.Capture.init(0, "keyword") },
        .{ .text = line.text[5..], .emphasis = true },
    };
    const rows = [_]buffer_mod.Row{
        .{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } },
        .{ .line_pair = .{
            .left = .{ .line = &old_line, .decoration = .{ .runs = &.{.{ .text = old_line.text }} } },
            .right = .{ .line = &line, .decoration = .{ .runs = &runs } },
        } },
        .{ .section = .{ .kind = .pending, .count = 1 } },
    };

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, .bytes, .{ .layout = .unified, .width = 0 });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(rows.len, visual_rows.len);
    try testing.expect(visual_rows[0].owner.eql(.{ .line = .{ .hunk_line = &line } }));
    try testing.expectEqual(@as(usize, 0), visual_rows[0].source_start);
    try testing.expectEqual(line.text.len, visual_rows[0].source_end);
    try testing.expectEqual(@as(usize, 0), visual_rows[0].buffer_index);
    try testing.expect(visual_rows[1].owner.eql(.{ .line = .{ .hunk_line = &line } }));
    try testing.expectEqual(line.text.len, visual_rows[1].source_end);
    try testing.expectEqual(@as(usize, 1), visual_rows[1].buffer_index);
    try testing.expectEqual(@as(usize, 2), visual_rows[2].buffer_index);
}

test "semantic row ownership exposes old and new yank candidates without changing Line identity" {
    const old_line: bbr.diff.Line = .{ .old_no = 1, .new_no = 0, .kind = .removed, .text = "old" };
    const new_line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "new" };
    const context: bbr.diff.Line = .{ .old_no = 2, .new_no = 2, .kind = .context, .text = "same" };
    const rows = [_]buffer_mod.Row{
        .{ .line_pair = .{ .left = .{ .line = &old_line, .decoration = .{ .runs = &.{} } }, .right = .{ .line = &new_line, .decoration = .{ .runs = &.{} } } } },
        .{ .line = .{ .line = &context, .decoration = .{ .runs = &.{} } } },
    };

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, .bytes, .{ .layout = .side_by_side, .width = 80 });
    defer testing.allocator.free(visual_rows);

    try testing.expect(visual_rows[0].owner.eql(.{ .line = .{ .hunk_line = &new_line } }));
    try testing.expectEqual(&old_line, visual_rows[0].yank_candidates.old.?);
    try testing.expectEqual(&new_line, visual_rows[0].yank_candidates.new.?);
    try testing.expect(visual_rows[1].owner.eql(.{ .line = .{ .hunk_line = &context } }));
    try testing.expectEqual(&context, visual_rows[1].yank_candidates.old.?);
    try testing.expectEqual(&context, visual_rows[1].yank_candidates.new.?);
}

test "Diff visual-row allocation fails before a partial projection escapes" {
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "same" };
    const rows = [_]buffer_mod.Row{.{ .line = .{
        .line = &line,
        .decoration = .{ .runs = &.{.{ .text = line.text }} },
    } }};
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, buildVisualRowsWithOptions(failing.allocator(), &rows, .bytes, .{ .layout = .unified, .width = 0 }));
    try testing.expect(failing.has_induced_failure);
}

test "Unified visual rows prefer whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "alpha beta" };
    const runs = [_]bbr.highlight.decoration.Run{
        .{ .text = line.text[0..3], .capture = bbr.highlight.Capture.init(0, "keyword") },
        .{ .text = line.text[3..8], .emphasis = true },
        .{ .text = line.text[8..] },
    };
    const rows = [_]buffer_mod.Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } }};

    const visual_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, .bytes, .{
        .layout = .unified,
        .width = unified_gutter_cols + 6,
    });
    try testing.expectEqual(@as(usize, 2), visual_rows.len);
    try testing.expectEqual(@as(usize, 0), visual_rows[0].source_start);
    try testing.expectEqual(@as(usize, 6), visual_rows[0].source_end);
    try testing.expectEqual(@as(usize, 6), visual_rows[1].source_start);
    try testing.expectEqual(line.text.len, visual_rows[1].source_end);
    try testing.expect(!visual_rows[0].continuation);
    try testing.expect(visual_rows[1].continuation);
    try testing.expectEqualStrings("alpha ", line.text[visual_rows[0].source_start..visual_rows[0].source_end]);
    try testing.expectEqualStrings("beta", line.text[visual_rows[1].source_start..visual_rows[1].source_end]);
}

test "Unified hard wrapping keeps wide and combining graphemes complete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Metrics = struct {
        fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            if (std.mem.startsWith(u8, text, "e\xcc\x81")) return .{ .byte_len = 3, .cell_width = 1 };
            if (std.mem.startsWith(u8, text, "界")) return .{ .byte_len = 3, .cell_width = 2 };
            return .{ .byte_len = 1, .cell_width = 1 };
        }
    };
    const context: u8 = 0;
    const vtable: CellMetrics.VTable = .{ .next = Metrics.next };
    const metrics: CellMetrics = .{ .ptr = &context, .vtable = &vtable };
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "e\xcc\x81界" };
    const rows = [_]buffer_mod.Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &.{.{ .text = line.text }} } } }};

    const visual_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, metrics, .{
        .layout = .unified,
        .width = unified_gutter_cols + 2,
    });
    try testing.expectEqual(@as(usize, 2), visual_rows.len);
    try testing.expectEqual(@as(usize, 3), visual_rows[0].source_end);
    try testing.expectEqual(@as(usize, 6), visual_rows[1].source_end);
    try testing.expectEqualStrings("e\xcc\x81", line.text[visual_rows[0].source_start..visual_rows[0].source_end]);
    try testing.expectEqualStrings("界", line.text[visual_rows[1].source_start..visual_rows[1].source_end]);
}

test "a printable ASCII Line wraps at the same positions as the grapheme loop" {
    const terminal = @import("terminal_cell_metrics.zig").metrics;
    const cases = [_][]const u8{
        "short",
        "abcdef",
        "abcdefghijklmnopqrstuvwxyz",
        "abcdef ghi",
        "abc def ghi jkl ",
        "trailing space ",
        "  leading and  double  spaces  ",
        "ascii then e\xcc\x81 combining",
        "ascii then \xe7\x95\x8c\xe9\x9d\xa2 wide",
        "abcde\xcc\x81",
        "emoji \xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb and flag \xf0\x9f\x87\xac\xf0\x9f\x87\xa7 here",
        "\tindented with a tab",
        "a\tb\tc d\te",
        "bell\x07 escape\x1b[0m nul\x00 del\x7f",
        "carriage return\r",
        "cr lf\r\n",
        "~!@#$%^&*()_+{}|:\"<>? `-=[]\\;',./",
    };
    var prng = std.Random.DefaultPrng.init(0x7405);
    const random = prng.random();
    const ascii_parts = [_][]const u8{ "a", "Z", "0", "~", " ", "  ", "abc", "(x)" };
    const mixed_parts = ascii_parts ++ [_][]const u8{ "\t", "\r", "\x01", "e\xcc\x81", "\xe7\x95\x8c", "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb", "\xc2\xa0" };
    var generated: [400][64]u8 = undefined;
    var generated_lens: [400]usize = undefined;
    for (&generated, &generated_lens, 0..) |*storage, *len, index| {
        const parts: []const []const u8 = if (index % 2 == 0) &ascii_parts else &mixed_parts;
        len.* = 0;
        while (true) {
            const part = parts[random.uintLessThan(usize, parts.len)];
            if (len.* + part.len > storage.len) break;
            @memcpy(storage[len.*..][0..part.len], part);
            len.* += part.len;
            if (random.uintLessThan(u8, 8) == 0) break;
        }
    }

    var texts: [cases.len + generated.len][]const u8 = undefined;
    for (cases, 0..) |text, index| texts[index] = text;
    for (&generated, generated_lens, cases.len..) |*storage, len, index| texts[index] = storage[0..len];
    var ascii_texts: usize = 0;
    for (texts) |text| {
        if (terminal.narrowAscii(text)) ascii_texts += 1;
    }
    try testing.expect(ascii_texts > 200);

    const short: bbr.diff.Line = .{ .old_no = 2, .new_no = 2, .kind = .context, .text = "x y" };
    const short_row: buffer_mod.LineRow = .{ .line = &short, .decoration = .{ .runs = &.{} } };
    for ([_]CellMetrics{ terminal, .bytes }) |metrics| {
        var grapheme_loop = metrics;
        grapheme_loop.ascii_is_narrow = false;
        for (texts) |text| {
            const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = text };
            const line_row: buffer_mod.LineRow = .{ .line = &line, .decoration = .{ .runs = &.{} } };
            const unified = [_]buffer_mod.Row{.{ .line = line_row }};
            const side_by_side = [_]buffer_mod.Row{
                .{ .line_pair = .{ .left = line_row, .right = line_row } },
                .{ .line_pair = .{ .left = line_row } },
                .{ .line_pair = .{ .right = line_row } },
                .{ .line_pair = .{ .left = short_row, .right = line_row } },
            };
            for (1..text.len + 3) |body_width| {
                try expectSameVisualRows(&unified, metrics, grapheme_loop, .{ .layout = .unified, .width = unified_gutter_cols + body_width });
                const side_width = 2 * (side_gutter_cols + body_width) + side_divider_cols;
                try expectSameVisualRows(&side_by_side, metrics, grapheme_loop, .{ .layout = .side_by_side, .width = side_width });
                try expectSameVisualRows(&side_by_side, metrics, grapheme_loop, .{ .layout = .side_by_side, .width = side_width + 1 });
            }
        }
    }
}

test "a printable ASCII Line wraps after the last space that fits" {
    const terminal = @import("terminal_cell_metrics.zig").metrics;
    const expectations = [_]struct { text: []const u8, width: usize, rows: []const []const u8 }{
        .{ .text = "abcdef", .width = 6, .rows = &.{"abcdef"} },
        .{ .text = "abcdefg", .width = 6, .rows = &.{ "abcdef", "g" } },
        .{ .text = "abcdef ghi", .width = 6, .rows = &.{ "abcdef", " ghi" } },
        .{ .text = "abcde fghi", .width = 6, .rows = &.{ "abcde ", "fghi" } },
        .{ .text = "ab cd ef gh", .width = 6, .rows = &.{ "ab cd ", "ef gh" } },
        .{ .text = "abc   ", .width = 4, .rows = &.{ "abc ", "  " } },
    };
    for (expectations) |expected| {
        const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = expected.text };
        const rows = [_]buffer_mod.Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &.{} } } }};
        const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, terminal, .{ .layout = .unified, .width = unified_gutter_cols + expected.width });
        defer testing.allocator.free(visual_rows);
        try testing.expectEqual(expected.rows.len, visual_rows.len);
        for (expected.rows, visual_rows) |text, visual_row| try testing.expectEqualStrings(text, line.text[visual_row.source_start..visual_row.source_end]);
    }
}

fn expectSameVisualRows(rows: []const buffer_mod.Row, fast: CellMetrics, grapheme_loop: CellMetrics, options: VisualRowOptions) !void {
    const expected = try buildVisualRowsWithOptions(testing.allocator, rows, grapheme_loop, options);
    defer testing.allocator.free(expected);
    const actual = try buildVisualRowsWithOptions(testing.allocator, rows, fast, options);
    defer testing.allocator.free(actual);
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try testing.expectEqual(want.buffer_index, got.buffer_index);
        try testing.expectEqual(want.source_start, got.source_start);
        try testing.expectEqual(want.source_end, got.source_end);
        try testing.expectEqual(want.continuation, got.continuation);
        try testing.expectEqual(want.halves, got.halves);
    }
}

fn exerciseVisualRowCapacityHint(allocator: std.mem.Allocator) !void {
    const line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "abcdefghij" };
    const rows = [_]buffer_mod.Row{.{ .line = .{
        .line = &line,
        .decoration = .{ .runs = &.{.{ .text = line.text }} },
    } }};
    const visual = try buildVisualRowsWithOptions(allocator, &rows, .bytes, .{
        .layout = .unified,
        .width = unified_gutter_cols + 2,
    });
    defer allocator.free(visual);
    try testing.expectEqual(@as(usize, 5), visual.len);
    try testing.expect(visual.len > rows.len + rows.len / 2);
    for (visual, 0..) |row, index| {
        try testing.expectEqual(@as(usize, 0), row.buffer_index);
        try testing.expectEqual(index * 2, row.source_start);
        try testing.expectEqual(index * 2 + 2, row.source_end);
    }
}

test "a narrow Unified Line grows beyond the visual row capacity hint without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseVisualRowCapacityHint, .{});
}

/// Counts what a build asks of its arena. A failed remap is a growth that
/// copies the list into new memory.
const GrowthCount = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    failed_remaps: usize = 0,
    frees: usize = 0,

    fn allocator(self: *GrowthCount) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *GrowthCount = @ptrCast(@alignCast(ptr));
        self.allocations += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *GrowthCount = @ptrCast(@alignCast(ptr));
        const resized = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (!resized and new_len > memory.len) self.failed_remaps += 1;
        return resized;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *GrowthCount = @ptrCast(@alignCast(ptr));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (result == null and new_len > memory.len) self.failed_remaps += 1;
        return result;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *GrowthCount = @ptrCast(@alignCast(ptr));
        self.frees += 1;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "visual rows build in one allocation without a growth copy in both Layouts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const count = 4096;
    const lines = try a.alloc(bbr.diff.Line, 2 * count);
    const rows = try a.alloc(buffer_mod.Row, count);
    for (rows, 0..) |*row, index| {
        const text = if (index % 8 < 2) "alpha beta gamma delta epsilon zeta" else "short";
        lines[2 * index] = .{ .old_no = @intCast(index + 1), .new_no = 0, .kind = .removed, .text = text };
        lines[2 * index + 1] = .{ .old_no = 0, .new_no = @intCast(index + 1), .kind = .added, .text = text };
        row.* = if (index % 2 == 0)
            .{ .line = .{ .line = &lines[2 * index + 1], .decoration = .{ .runs = &.{} } } }
        else
            .{ .line_pair = .{
                .left = .{ .line = &lines[2 * index], .decoration = .{ .runs = &.{} } },
                .right = .{ .line = &lines[2 * index + 1], .decoration = .{ .runs = &.{} } },
            } };
    }
    for ([_]VisualRowOptions{
        .{ .layout = .unified, .width = unified_gutter_cols + 12 },
        .{ .layout = .side_by_side, .width = 2 * (side_gutter_cols + 12) + side_divider_cols },
    }) |options| {
        var growth: GrowthCount = .{ .child = a };
        const visual_rows = try buildVisualRowsWithOptions(growth.allocator(), rows, .bytes, options);
        try testing.expect(visual_rows.len > rows.len);
        try testing.expectEqual(@as(usize, 1), growth.allocations);
        try testing.expectEqual(@as(usize, 0), growth.failed_remaps);
    }
}

test "a NavigationIndex whose keys each have one span grows nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const count = 4096;
    const lines = try a.alloc(bbr.diff.Line, count);
    const rows = try a.alloc(buffer_mod.Row, count);
    for (rows, lines, 0..) |*row, *line, index| {
        line.* = .{ .old_no = 0, .new_no = @intCast(index + 1), .kind = .added, .text = "short" };
        row.* = .{ .line = .{ .line = line, .decoration = .{ .runs = &.{} } } };
    }
    const visual_rows = try buildVisualRowsWithOptions(a, rows, .bytes, .{ .layout = .unified, .width = unified_gutter_cols + 12 });
    var growth: GrowthCount = .{ .child = a };
    const index = try NavigationIndex.build(growth.allocator(), visual_rows);
    try testing.expectEqual(@as(usize, 0), growth.failed_remaps);
    // The two frees are the scratch key numbers and cursors of `KeyLists`. A
    // hash table that grows frees its old table too.
    try testing.expectEqual(@as(usize, 2), growth.frees);
    // No reader asks `owners` for a Line, so Line rows add no entry.
    try testing.expectEqual(@as(u32, 0), index.owners.count());
    for (visual_rows, 0..) |row, expected| try testing.expectEqual(@as(?usize, expected), index.find(row));
}

fn sideBySideIndexGrowth(a: std.mem.Allocator, count: usize) !GrowthCount {
    const lines = try a.alloc(bbr.diff.Line, 2 * count);
    const rows = try a.alloc(buffer_mod.Row, count);
    for (rows, 0..) |*row, index| {
        const text = "alpha beta gamma delta epsilon zeta";
        lines[2 * index] = .{ .old_no = @intCast(index + 1), .new_no = 0, .kind = .removed, .text = text };
        lines[2 * index + 1] = .{ .old_no = 0, .new_no = @intCast(index + 1), .kind = .added, .text = text };
        row.* = .{ .line_pair = .{
            .left = .{ .line = &lines[2 * index], .decoration = .{ .runs = &.{} } },
            .right = .{ .line = &lines[2 * index + 1], .decoration = .{ .runs = &.{} } },
        } };
    }
    const visual_rows = try buildVisualRowsWithOptions(a, rows, .bytes, .{ .layout = .side_by_side, .width = 2 * (side_gutter_cols + 12) + side_divider_cols });
    try testing.expect(visual_rows.len >= 2 * count);
    var growth: GrowthCount = .{ .child = a };
    const index = try NavigationIndex.build(growth.allocator(), visual_rows);
    for (visual_rows, 0..) |row, expected| try testing.expectEqual(@as(?usize, expected), index.find(row));
    return growth;
}

test "a NavigationIndex build allocates the same for any key count and grows no key list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Each SideBySide half wraps, so each key has two spans.
    const small = try sideBySideIndexGrowth(arena.allocator(), 512);
    const large = try sideBySideIndexGrowth(arena.allocator(), 4096);
    try testing.expectEqual(small.allocations, large.allocations);
    try testing.expectEqual(@as(usize, 0), large.failed_remaps);
}

test "Unified wrapping keeps non-Line rows atomic when the body has no cells" {
    const file: bbr.diff.File = .{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = &.{} };
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "long source" };
    const rows = [_]buffer_mod.Row{
        .{ .file_header = .{ .file = &file, .path = file.new_path } },
        .{ .status_placeholder = .{ .file = &file, .new = .{ .binary = 12 } } },
        .{ .disclosure = .{ .key = .{ .fold = &line }, .kind = .fold, .expanded = false, .count = 20 } },
        .{ .line = .{ .line = &line, .decoration = .{ .runs = &.{.{ .text = line.text }} } } },
    };

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, .bytes, .{
        .layout = .unified,
        .width = unified_gutter_cols,
    });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(rows.len, visual_rows.len);
    for (visual_rows, 0..) |visual_row, index| try testing.expectEqual(index, visual_row.buffer_index);
}

test "SideBySide halves wrap independently and align absent continuations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const left: bbr.diff.Line = .{ .old_no = 7, .new_no = 0, .kind = .removed, .text = "old one two" };
    const right: bbr.diff.Line = .{ .old_no = 0, .new_no = 9, .kind = .added, .text = "new" };
    const rows = [_]buffer_mod.Row{.{ .line_pair = .{
        .left = .{ .line = &left, .decoration = .{ .runs = &.{.{ .text = left.text, .emphasis = true }} } },
        .right = .{ .line = &right, .decoration = .{ .runs = &.{.{ .text = right.text, .capture = bbr.highlight.Capture.init(0, "keyword") }} } },
    } }};

    const visual_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, .bytes, .{
        .layout = .side_by_side,
        .width = 2 * (side_gutter_cols + 8) + side_divider_cols,
    });

    try testing.expectEqual(@as(usize, 2), visual_rows.len);
    const first_left = visual_rows[0].halves.?.left.?;
    const first_right = visual_rows[0].halves.?.right.?;
    try testing.expectEqualStrings("old one ", left.text[first_left.source_start..first_left.source_end]);
    try testing.expectEqualStrings("new", right.text[first_right.source_start..first_right.source_end]);
    try testing.expect(visual_rows[1].halves.?.left.?.continuation);
    try testing.expect(visual_rows[1].halves.?.right == null);
    try testing.expect(visual_rows[1].owner.eql(.{ .line = .{ .hunk_line = &left } }));
    try testing.expectEqual(@as(usize, 8), visual_rows[1].source_start);
}

test "SideBySide wrapping keeps pairs atomic when halves have no body cells" {
    const left: bbr.diff.Line = .{ .old_no = 1, .new_no = 0, .kind = .removed, .text = "long old source" };
    const rows = [_]buffer_mod.Row{.{ .line_pair = .{ .left = .{
        .line = &left,
        .decoration = .{ .runs = &.{.{ .text = left.text }} },
    } } }};

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, .bytes, .{
        .layout = .side_by_side,
        .width = 11,
    });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(@as(usize, 1), visual_rows.len);
    try testing.expect(visual_rows[0].halves == null);
}

test "SideBySide resize restores an old-only continuation by source offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const left: bbr.diff.Line = .{ .old_no = 7, .new_no = 0, .kind = .removed, .text = "old one two" };
    const right: bbr.diff.Line = .{ .old_no = 0, .new_no = 9, .kind = .added, .text = "new" };
    const rows = [_]buffer_mod.Row{.{ .line_pair = .{
        .left = .{ .line = &left, .decoration = .{ .runs = &.{.{ .text = left.text }} } },
        .right = .{ .line = &right, .decoration = .{ .runs = &.{.{ .text = right.text }} } },
    } }};
    const old_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, .bytes, .{ .layout = .side_by_side, .width = 27 });
    const new_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, .bytes, .{ .layout = .side_by_side, .width = 35 });
    var navigation = Nav.init(old_rows.len, 2);
    navigation.cursor = 1;
    const previous: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 27, .rows = 5 },
        .panes = paneRects(.{ .cols = 27, .rows = 5 }),
        .visual_rows = old_rows,
        .buffer = .{ .rows = &rows, .layout = .side_by_side },
        .navigation = navigation,
    };

    try testing.expectEqual(@as(usize, 0), restoreNavigation(previous, new_rows, .{ .cols = 35, .rows = 5 }).cursor);
}

test "framed Pane geometry is bounded at zero narrow ordinary and wide sizes" {
    for ([_]Geometry{ .{ .cols = 0, .rows = 0 }, .{ .cols = 5, .rows = 2 }, .{ .cols = 80, .rows = 24 }, .{ .cols = 160, .rows = 40 } }) |geometry| {
        const panes = paneRects(geometry);
        try testing.expect(panes.sidebar.x + panes.sidebar.width <= geometry.cols);
        try testing.expect(panes.diff.x + panes.diff.width <= geometry.cols);
        try testing.expect(panes.sidebar_content.x + panes.sidebar_content.width <= geometry.cols);
        try testing.expect(panes.diff_content.y + panes.diff_content.height <= geometry.rows);
    }
    for ([_]u16{ 40, 80 }) |cols| try testing.expectEqual(paneRects(.{ .cols = cols, .rows = 24 }).sidebar.width, paneRects(.{ .cols = cols, .rows = 24 }).diff.x);
}

fn expectSameCells(expected: Rect, actual: Rect) !void {
    if (expected.isEmpty()) return testing.expect(actual.isEmpty());
    try testing.expectEqual(expected, actual);
}

test "View Pane geometry keeps the cells of the previous formulas" {
    const legacy = struct {
        fn content(rect: Rect) Rect {
            return .{ .x = rect.x +| @min(rect.width, 1), .y = rect.y +| @min(rect.height, 1), .width = rect.width -| 2, .height = rect.height -| 2 };
        }
        fn panes(geometry: Geometry) PaneRects {
            const sidebar_width: u16 = if (geometry.cols < 6) geometry.cols / 2 else @min(28, geometry.cols - 3);
            const diff_x: u16 = @min(sidebar_width, geometry.cols);
            const sidebar: Rect = .{ .x = 0, .y = 0, .width = sidebar_width, .height = geometry.rows };
            const diff: Rect = .{ .x = diff_x, .y = 0, .width = geometry.cols - diff_x, .height = geometry.rows };
            const inner = content(diff);
            const marker_width = @min(inner.width, 1);
            return .{
                .sidebar = sidebar,
                .diff = diff,
                .sidebar_content = content(sidebar),
                .diff_content = .{ .x = inner.x + marker_width, .y = inner.y, .width = inner.width - marker_width, .height = inner.height },
                .version_marker = .{ .x = inner.x, .y = inner.y, .width = marker_width, .height = inner.height },
                .sidebar_track = .{},
                .diff_track = .{},
            };
        }
    };
    var cols: u16 = 5;
    while (cols <= 320) : (cols += 1) {
        var rows: u16 = 0;
        while (rows <= 60) : (rows += 1) {
            const geometry: Geometry = .{ .cols = cols, .rows = rows };
            const expected = legacy.panes(geometry);
            const actual = paneRects(geometry);
            try expectSameCells(expected.sidebar, actual.sidebar);
            try expectSameCells(expected.diff, actual.diff);
            try expectSameCells(expected.sidebar_content, actual.sidebar_content);
            try expectSameCells(expected.diff_content, actual.diff_content);
            try expectSameCells(expected.version_marker, actual.version_marker);
        }
    }
}

test "List Overlay geometry is centered, bordered, and clipped to the published Frame" {
    const wide = listOverlayTarget(.{ .cols = 80, .rows = 24 }, .{ .width = 60, .height = 16 }).?;
    try testing.expectEqual(Rect{ .x = 9, .y = 2, .width = 62, .height = 20 }, wide.rect);
    try testing.expectEqual(Rect{ .x = 10, .y = 6, .width = 60, .height = 15 }, wide.entries);
    const clipped = listOverlayTarget(.{ .cols = 20, .rows = 8 }, .{ .width = 60, .height = 16 }).?;
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 20, .height = 8 }, clipped.rect);
    try testing.expectEqual(Rect{ .x = 1, .y = 4, .width = 18, .height = 3 }, clipped.entries);
    try testing.expect(listOverlayTarget(.{ .cols = 0, .rows = 8 }, .{ .width = 60, .height = 16 }) == null);
}

test "Review Search geometry keeps bordered content and pointer targets aligned" {
    const wide = reviewSearchGeometry(.{ .cols = 100, .rows = 40 }).?;
    try testing.expectEqual(Rect{ .x = 10, .y = 4, .width = 80, .height = 32 }, wide.rect);
    try testing.expect(wide.landscape);
    try testing.expectEqual(wide.body.x + wide.body.width - 1, wide.preview.x + wide.preview.width);
    try testing.expectEqual(wide.divider + 1, wide.preview.x);
    try testing.expectEqual(wide.body.y + 3, wide.preview.y);

    const portrait = reviewSearchGeometry(.{ .cols = 40, .rows = 100 }).?;
    try testing.expectEqual(Rect{ .x = 0, .y = 10, .width = 40, .height = 80 }, portrait.rect);
    try testing.expect(!portrait.landscape);
    try testing.expectEqual(portrait.divider + 3, portrait.preview.y);
    try testing.expectEqual(portrait.divider - 1, portrait.list.y + portrait.list.height - 1);

    const small = reviewSearchGeometry(.{ .cols = 40, .rows = 10 }).?;
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 40, .height = 10 }, small.rect);
    try testing.expectEqual(Rect{ .x = 8, .y = 2, .width = 64, .height = 19 }, reviewSearchGeometry(.{ .cols = 80, .rows = 24 }).?.rect);
    try testing.expect(reviewSearchGeometry(.{ .cols = 0, .rows = 10 }) == null);

    const frame: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 100, .rows = 40 },
        .panes = paneRects(.{ .cols = 100, .rows = 40 }),
        .visual_rows = &.{},
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(0, 40),
        .overlay = .{ .kind = .review_search, .rect = wide.rect, .review_search = wide, .row_count = 2 },
    };
    try testing.expectEqual(HitTarget{ .review_search_entry = 0 }, hitTest(frame, wide.list.x, wide.list.y).?);
    try testing.expectEqual(HitTarget.review_search_preview, hitTest(frame, wide.preview.x, wide.preview.y).?);
    try testing.expect(hitTest(frame, wide.divider, wide.list.y) == null);
    try testing.expect(hitTest(frame, wide.rect.x + 1, wide.rect.y + 1) == null);
}

test "published Frame hit testing gives Overlay rows precedence and clips blank rows" {
    const entries = [_]file_tree.Entry{.{
        .identity = .{ .file = 0 },
        .parent = null,
        .depth = 0,
        .label = "a.zig",
    }};
    var projection: Projection = .{
        .revision = 7,
        .visual_rows_revision = 7,
        .geometry = .{ .cols = 20, .rows = 8 },
        .panes = paneRects(.{ .cols = 20, .rows = 8 }),
        .visual_rows = &.{},
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(0, 5),
        .file_tree = .{ .entries = &entries, .viewport = 5 },
        .overlay = .{ .kind = .list, .rect = .{ .x = 5, .y = 0, .width = 10, .height = 6 }, .entries = .{ .x = 6, .y = 2, .width = 8, .height = 3 }, .row_count = 2 },
    };

    try testing.expectEqual(HitTarget{ .list_entry = 0 }, hitTest(projection, 6, 2).?);
    try testing.expectEqual(HitTarget{ .list_entry = 1 }, hitTest(projection, 6, 3).?);
    try testing.expect(hitTest(projection, 6, 4) == null);
    try testing.expect(hitTest(projection, 1, 1) == null); // Overlay capture prevents Pane pass-through.

    projection.overlay = null;
    try testing.expectEqual(HitTarget{ .sidebar_entry = 0 }, hitTest(projection, 1, 1).?);
    try testing.expectEqual(HitTarget.sidebar, hitTest(projection, 1, 2).?);
    try testing.expect(hitTest(projection, 0, 1) == null); // Pane border.
}

test "Presentation Frame metadata exposes exact version title targets" {
    const targets = versionTitleTargets(.{ .x = 29, .y = 0, .width = 51, .height = 8 }, .old);
    try testing.expectEqual(Rect{ .x = 64, .y = 0, .width = 6, .height = 1 }, targets.old.?);
    try testing.expectEqual(Rect{ .x = 71, .y = 0, .width = 6, .height = 1 }, targets.new.?);

    var projection: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 80, .rows = 8 },
        .panes = paneRects(.{ .cols = 80, .rows = 8 }),
        .visual_rows = &.{},
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(0, 5),
        .selected_version = .old,
        .version_title_targets = .{
            .old = .{ .x = 31, .y = 0, .width = 6, .height = 1 },
            .new = .{ .x = 38, .y = 0, .width = 6, .height = 1 },
        },
    };

    try testing.expectEqual(HitTarget.select_old_version, hitTest(projection, 31, 0).?);
    try testing.expectEqual(HitTarget.select_new_version, hitTest(projection, 43, 0).?);
    projection.overlay = .{ .kind = .other, .rect = .{ .x = 0, .y = 0, .width = 80, .height = 8 } };
    try testing.expect(hitTest(projection, 31, 0) == null);

    const clipped = versionTitleTargets(.{ .x = 3, .y = 0, .width = 9, .height = 4 }, .old);
    try testing.expectEqual(Rect{ .x = 6, .y = 0, .width = 3, .height = 1 }, clipped.old.?);
    try testing.expect(clipped.new == null);
}

test "M20 hardening keeps the default new title segment visible when clipped" {
    const targets = versionTitleTargets(.{ .x = 3, .y = 0, .width = 9, .height = 4 }, .new);

    try testing.expect(targets.new != null);
    try testing.expectEqual(@as(u16, 3), targets.new.?.width);
}

test "navigation restoration follows stable owners and clears a shifted Selection" {
    const old_targets = [_]VisualRow{
        .{ .owner = .{ .section = .{ .kind = .pr_comments, .path = "" } } },
        .{ .owner = .{ .section = .{ .kind = .outdated, .path = "a.zig" } } },
    };
    const new_targets = [_]VisualRow{
        .{ .owner = .{ .section = .{ .kind = .pending, .path = "" } } },
        old_targets[0],
        old_targets[1],
    };
    var navigation = Nav.init(old_targets.len, 4);
    navigation.cursor = 1;
    navigation.mark = 0;
    navigation.count = 7;
    const previous: Projection = .{
        .revision = 4,
        .visual_rows_revision = 4,
        .geometry = .{ .cols = 80, .rows = 4 },
        .panes = paneRects(.{ .cols = 80, .rows = 4 }),
        .visual_rows = &old_targets,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = navigation,
    };

    const restored = restoreNavigation(previous, &new_targets, .{ .cols = 60, .rows = 3 });

    try testing.expectEqual(@as(usize, 2), restored.cursor);
    try testing.expectEqual(@as(usize, 7), restored.count);
    try testing.expectEqual(@as(usize, 1), restored.viewport);
    try testing.expect(restored.mark == null);
}

test "ReviewCard restoration follows containing source offset and collapsed footer" {
    const old_targets = [_]VisualRow{
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } } },
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 8 } }, .source_end = 18 },
    };
    var navigation = Nav.init(old_targets.len, 3);
    navigation.cursor = 1;
    const previous: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 40, .rows = 3 },
        .panes = paneRects(.{ .cols = 40, .rows = 3 }),
        .visual_rows = &old_targets,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = navigation,
    };
    const resized = [_]VisualRow{
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } } },
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 4 } }, .source_end = 14 },
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 14 } }, .source_end = 18 },
    };
    try testing.expectEqual(@as(usize, 1), restoreNavigation(previous, &resized, .{ .cols = 60, .rows = 3 }).cursor);

    const collapsed = [_]VisualRow{
        resized[0],
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 18, .part = .disclosure_footer } }, .source_end = 18 },
    };
    try testing.expectEqual(@as(usize, 1), restoreNavigation(previous, &collapsed, .{ .cols = 30, .rows = 3 }).cursor);
}

test "M21 kernel navigation index matches linear restoration across wrapping and typed owners" {
    const old_line: bbr.diff.Line = .{ .old_no = 1, .new_no = 0, .kind = .removed, .text = "old text that wraps across several rows and continues" };
    const new_line: bbr.diff.Line = .{ .old_no = 0, .new_no = 1, .kind = .added, .text = "new text with a different wrap boundary" };
    const context: bbr.diff.Line = .{ .old_no = 2, .new_no = 2, .kind = .context, .text = "" };
    const source = [_]buffer_mod.Row{
        .{ .line_pair = .{ .left = .{ .line = &old_line, .decoration = .{ .runs = &.{} } }, .right = .{ .line = &new_line, .decoration = .{ .runs = &.{} } } } },
        .{ .line = .{ .line = &context, .decoration = .{ .runs = &.{} } } },
    };
    for ([_]usize{ 24, 45, 100 }) |width| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(VisualRow) = .empty;
        try rows.appendSlice(a, try buildVisualRowsWithOptions(a, &source, .bytes, .{ .layout = .side_by_side, .width = width }));
        try rows.appendSlice(a, &.{
            .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } } },
            .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 0 } }, .source_end = 10 },
            .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 10 } }, .source_end = 30 },
            .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 15 } }, .source_end = 20 },
            .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 50, .part = .disclosure_footer } }, .source_end = 50 },
            .{ .owner = .{ .draft = .{ .id = 7, .source_offset = 0, .part = .header } } },
            .{ .owner = .{ .draft = .{ .id = 7, .source_offset = 5 } }, .source_end = 12 },
            .{ .owner = .{ .draft = .{ .id = 7, .source_offset = 40, .part = .disclosure_footer } }, .source_end = 40 },
            .{ .owner = .{ .snapshot = .{ .id = 7, .source_offset = 0 } } },
            .{ .owner = .{ .disclosure = .{ .fold = &context } } },
            .{ .owner = .{ .section = .{ .kind = .pending, .path = "src" } } },
        });
        const index = try NavigationIndex.build(a, rows.items);
        for (rows.items) |row| for (0..65) |offset| {
            var wanted = row;
            wanted.source_start = offset;
            switch (wanted.owner) {
                .comment => |*value| value.source_offset = offset,
                .draft => |*value| value.source_offset = offset,
                else => {},
            }
            try testing.expectEqual(findVisualRow(rows.items, wanted), index.find(wanted));
        };
        try testing.expectEqual(@as(?usize, null), index.find(.{ .owner = .{ .draft = .{ .id = 8, .source_offset = 0 } } }));
        const copied_path = try a.dupe(u8, "src");
        try testing.expectEqual(findVisualRow(rows.items, .{ .owner = .{ .section = .{ .kind = .pending, .path = copied_path } } }), index.find(.{ .owner = .{ .section = .{ .kind = .pending, .path = copied_path } } }));
    }
}

test "M21 kernel indexed navigation preserves Selection Count and viewport after width changes" {
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "alpha beta gamma delta epsilon zeta" };
    const source = [_]buffer_mod.Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &.{} } } }};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const old_rows = try buildVisualRowsWithOptions(arena.allocator(), &source, .bytes, .{ .layout = .unified, .width = 18 });
    const new_rows = try buildVisualRowsWithOptions(arena.allocator(), &source, .bytes, .{ .layout = .unified, .width = 26 });
    const index = try NavigationIndex.build(arena.allocator(), new_rows);
    var previous: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 18, .rows = 8 },
        .panes = paneRects(.{ .cols = 18, .rows = 8 }),
        .visual_rows = old_rows,
        .buffer = .{ .rows = &source, .layout = .unified },
        .navigation = Nav.init(old_rows.len, 5),
    };
    for (old_rows, 0..) |_, cursor| for (old_rows, 0..) |_, mark| {
        previous.navigation.cursor = cursor;
        previous.navigation.mark = mark;
        previous.navigation.scroll = cursor -| 2;
        previous.navigation.count = 999;
        try testing.expectEqual(restoreNavigation(previous, new_rows, .{ .cols = 26, .rows = 6 }), restoreNavigationIndexed(previous, new_rows, .{ .cols = 26, .rows = 6 }, index));
    };
    try testing.expectEqual(@as(?usize, 0), visualIndexForBufferIndex(new_rows, 0));
    try testing.expectEqual(@as(?usize, null), visualIndexForBufferIndex(new_rows, 1));
    try testing.expectEqual(@as(?usize, null), visualIndexForBufferIndex(&.{}, 0));
}

test "M30 scrollbar every track is as tall as the content of its View at every size" {
    var cols: u16 = 5;
    while (cols <= 320) : (cols += 1) {
        var rows: u16 = 3;
        while (rows <= 120) : (rows += 1) {
            const geometry: Geometry = .{ .cols = cols, .rows = rows };
            const panes = paneRects(geometry);
            try testing.expectEqual(panes.sidebar_content.height, panes.sidebar_track.height);
            try testing.expectEqual(panes.diff_content.height, panes.diff_track.height);
            try testing.expectEqual(panes.sidebar.x + panes.sidebar.width -| 1, panes.sidebar_track.x);
            try testing.expectEqual(panes.diff.x + panes.diff.width -| 1, panes.diff_track.x);
            for ([_]bool{ false, true }) |query| {
                const params: layouts.Help = .{ .rows = 200, .query = query, .scroll = .{ .total = 200 } };
                try testing.expectEqual(helpBodyRows(geometry, params), helpOverlayTarget(geometry, params).?.help.?.track.height);
            }
            const review_search = reviewSearchGeometry(geometry) orelse continue;
            try testing.expectEqual(review_search.list.height, review_search.list_track.height);
            if (review_search.list_track.height > 0) try testing.expectEqual(review_search.list.x + review_search.list.width, review_search.list_track.x);
        }
    }
}

test "M30 scrollbar the Sidebar track is the Sidebar border and the next column is the DiffPane border" {
    const geometry: Geometry = .{ .cols = 80, .rows = 10 };
    const panes = paneRects(geometry);
    try testing.expectEqual(panes.sidebar.x + panes.sidebar.width - 1, panes.sidebar_track.x);
    try testing.expectEqual(panes.sidebar_track.x + 1, panes.diff.x);
    try testing.expectEqual(panes.sidebar_content.y, panes.sidebar_track.y);
    const entries = [_]file_tree.Entry{.{ .identity = .{ .file = 0 }, .parent = null, .depth = 0, .label = "a.zig" }} ** 30;
    const frame: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = geometry,
        .panes = panes,
        .visual_rows = &.{},
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(0, panes.diff_content.height),
        .file_tree = .{ .entries = &entries, .viewport = panes.sidebar_content.height },
    };
    try testing.expect(scrollState(frame, .sidebar).?.thumb() != null);
    try testing.expect(scrollState(frame, .diff_pane).?.thumb() == null);
    try testing.expect(scrollState(frame, .review_search_list) == null);
    for (panes.diff_track.y..panes.diff_track.y + panes.diff_track.height) |row| {
        const cell: u16 = @intCast(row - panes.sidebar_track.y);
        try testing.expectEqual(HitTarget{ .scroll_bar = .{ .bar = .sidebar, .cell = cell } }, hitTest(frame, panes.sidebar_track.x, @intCast(row)).?);
        try testing.expect(hitTest(frame, panes.diff.x, @intCast(row)) == null);
        try testing.expect(hitTest(frame, panes.diff_track.x, @intCast(row)) == null);
    }
}

test "M30 scrollbar a track without a thumb or under an Overlay has no scroll bar target" {
    const geometry: Geometry = .{ .cols = 80, .rows = 10 };
    const panes = paneRects(geometry);
    const entries = [_]file_tree.Entry{.{ .identity = .{ .file = 0 }, .parent = null, .depth = 0, .label = "a.zig" }} ** 30;
    const rows = [_]VisualRow{.{ .owner = .{ .section = .{ .kind = .pr_comments, .path = "" } } }} ** 30;
    var frame: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = geometry,
        .panes = panes,
        .visual_rows = &rows,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(rows.len, panes.diff_content.height),
        .file_tree = .{ .entries = &entries, .viewport = panes.sidebar_content.height },
    };
    for (0..panes.diff_track.height) |cell| {
        const row: u16 = @intCast(panes.diff_track.y + cell);
        try testing.expectEqual(HitTarget{ .scroll_bar = .{ .bar = .diff_pane, .cell = @intCast(cell) } }, hitTest(frame, panes.diff_track.x, row).?);
    }

    var fits = frame;
    fits.file_tree.entries = entries[0..panes.sidebar_track.height];
    fits.visual_rows = rows[0..panes.diff_track.height];
    for ([_]ScrollBar{ .sidebar, .diff_pane }) |bar| try testing.expect(scrollTarget(fits, bar) == null);
    for (0..panes.diff_track.height) |cell| {
        try testing.expect(hitTest(fits, panes.sidebar_track.x, @intCast(panes.sidebar_track.y + cell)) == null);
        try testing.expect(hitTest(fits, panes.diff_track.x, @intCast(panes.diff_track.y + cell)) == null);
    }

    frame.overlay = screenOverlayTarget(geometry);
    for ([_]ScrollBar{ .sidebar, .diff_pane }) |bar| {
        try testing.expect(scrollState(frame, bar).?.thumb() != null);
        try testing.expect(scrollTarget(frame, bar) == null);
    }
    try testing.expect(hitTest(frame, panes.sidebar_track.x, panes.sidebar_track.y) == null);
    try testing.expect(hitTest(frame, panes.diff_track.x, panes.diff_track.y) == null);
}

test "M30 scrollbar the Review Search list track takes a press before the list while it shows a thumb" {
    for ([_]Geometry{ .{ .cols = 100, .rows = 40 }, .{ .cols = 40, .rows = 100 } }) |geometry| {
        const surface = reviewSearchGeometry(geometry).?;
        const track = surface.list_track;
        try testing.expect(track.height > 1);
        const panes = paneRects(geometry);
        const entries = [_]file_tree.Entry{.{ .identity = .{ .file = 0 }, .parent = null, .depth = 0, .label = "a.zig" }} ** 200;
        const rows = [_]VisualRow{.{ .owner = .{ .section = .{ .kind = .pr_comments, .path = "" } } }} ** 200;
        var frame: Projection = .{
            .revision = 1,
            .visual_rows_revision = 1,
            .geometry = geometry,
            .panes = panes,
            .visual_rows = &rows,
            .buffer = .{ .rows = &.{}, .layout = .unified },
            .navigation = Nav.init(rows.len, panes.diff_content.height),
            .file_tree = .{ .entries = &entries, .viewport = panes.sidebar_content.height },
        };
        try testing.expect(scrollTarget(frame, .review_search_list) == null);

        frame.overlay = .{ .kind = .review_search, .rect = surface.rect, .review_search = surface, .row_count = 200, .list_total = 200, .scroll = 7 };
        for (0..track.height) |index| {
            const cell: u16 = @intCast(index);
            try testing.expectEqual(HitTarget{ .scroll_bar = .{ .bar = .review_search_list, .cell = cell } }, hitTest(frame, track.x, track.y + cell).?);
        }
        try testing.expectEqual(HitTarget{ .review_search_entry = 7 }, hitTest(frame, surface.list.x, surface.list.y).?);
        try testing.expectEqual(HitTarget{ .review_search_entry = 7 }, hitTest(frame, track.x - 1, track.y).?);
        try testing.expectEqual(HitTarget.review_search_preview, hitTest(frame, surface.preview.x, surface.preview.y).?);
        for ([_]ScrollBar{ .sidebar, .diff_pane }) |bar| {
            try testing.expect(scrollState(frame, bar).?.thumb() != null);
            try testing.expect(scrollTarget(frame, bar) == null);
        }
        try testing.expect(hitTest(frame, panes.diff_track.x, panes.diff_track.y) == null);

        var fits = frame;
        fits.overlay.?.list_total = track.height;
        fits.overlay.?.scroll = 0;
        try testing.expect(scrollTarget(fits, .review_search_list) == null);
        for (0..track.height) |index| {
            const hit = hitTest(fits, track.x, @intCast(track.y + index));
            try testing.expect(hit == null or hit.? != .scroll_bar);
        }

        var covered = frame;
        covered.overlay.?.kind = .other;
        try testing.expect(scrollTarget(covered, .review_search_list) == null);
    }
}

/// Counts the Views that declare a scroll bar.
const ScrollBarCount = struct {
    count: usize = 0,

    pub fn visit(self: *ScrollBarCount, node: anytype, _: view.Placed) void {
        self.count += @intFromBool(node.scrollbar != null);
    }
};

/// A public `fn (params, area, visitor) void` in layouts.zig is a View tree.
fn isLayoutTree(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"fn") return false;
    const params = info.@"fn".params;
    return params.len == 3 and params[0].type != null and params[1].type == Rect and params[2].type == null;
}

test "M30 scrollbar every layout scroll bar is one arm of frame.ScrollBar" {
    var counter: ScrollBarCount = .{};
    var trees: usize = 0;
    inline for (@typeInfo(layouts).@"struct".decls) |decl| {
        const tree = @field(layouts, decl.name);
        if (comptime isLayoutTree(@TypeOf(tree))) {
            tree(std.mem.zeroes(@typeInfo(@TypeOf(tree)).@"fn".params[0].type.?), .{ .width = 80, .height = 24 }, &counter);
            trees += 1;
        }
    }
    try testing.expect(trees >= 8);
    try testing.expectEqual(std.meta.tags(ScrollBar).len, counter.count);
}
