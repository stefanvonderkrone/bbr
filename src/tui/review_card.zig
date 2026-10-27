//! Pure width projection for bounded ReviewCards.

const std = @import("std");
const bbr = @import("bbr");
const body_mod = @import("review_body.zig");
const CellMetrics = @import("cell_metrics.zig").CellMetrics;

pub const ReviewBody = body_mod.ReviewBody;
pub const SourceRange = body_mod.SourceRange;
pub const Marks = body_mod.Marks;
pub const BlockKind = body_mod.BlockKind;

pub const Owner = union(enum) {
    comment: bbr.review.CommentId,
    draft: bbr.review.TempId,
};

pub const Source = union(enum) {
    comment: *const bbr.review.Comment,
    draft: *const bbr.review.Draft,

    pub fn body(self: Source) []const u8 {
        return switch (self) {
            .comment => |value| value.body,
            .draft => |value| value.body,
        };
    }
};

pub const CardRole = enum { comment, comment_reply, deleted_comment, deleted_reply, draft, draft_reply, outcome_unknown, outcome_unknown_reply };
/// The rows of a ReviewCard from top to bottom. A Reply starts with a gap row.
/// The header is the top border with the Title. The disclosure footer or the
/// bottom part is the bottom border.
pub const Part = enum {
    gap,
    header,
    body,
    code_body,
    suggestion_label,
    suggestion_body,
    disclosure_footer,
    bottom,

    /// A code or Suggestion row. Its code area keeps its own background. Every
    /// other row paints the Theme base background.
    pub fn hasCodeBackground(self: Part) bool {
        return switch (self) {
            .code_body, .suggestion_label, .suggestion_body => true,
            .gap, .header, .body, .disclosure_footer, .bottom => false,
        };
    }

    /// A border row or the gap row. It carries no ReviewBody text.
    pub fn isBorder(self: Part) bool {
        return switch (self) {
            .gap, .header, .disclosure_footer, .bottom => true,
            .body, .code_body, .suggestion_label, .suggestion_body => false,
        };
    }
};

pub const Segment = struct {
    text: []const u8,
    source: SourceRange,
    marks: Marks = .{},
    link: ?body_mod.LinkTarget = null,
    /// False for terminal markers and generated spacing, even with a source range.
    authored: bool = true,
    atomic: bool = false,
    definition_source: ?SourceRange = null,
    required_definition: ?SourceRange = null,
};

pub const RowRange = struct { start: usize, end: usize };

/// Buffer-owned geometry shared by every row of one ReviewCard. Subtrees are
/// contiguous, so membership in the Active Path needs no parent or body scan.
pub const Card = struct {
    rows: RowRange,
    subtree_end: usize,
    parent: ?*const Card,
    root: *const Card,
    depth: usize,
    role: CardRole,
    anchored: RowRange,
    next_sibling: ?*const Card = null,
};

/// A shared ancestor rail and its next sibling. Each chain has distinct
/// columns. The shallowest rail wins when indentation reaches its limit.
pub const Rail = struct { column: usize, target: *const Card, next: ?*const Rail };

pub const ReviewCardRow = struct {
    owner: Owner,
    source: Source,
    scope: bbr.review.CommentScope = .review,
    role: CardRole,
    part: Part,
    block_ordinal: usize,
    block_kind: BlockKind,
    source_range: SourceRange,
    segments: []const Segment,
    hidden_rows: usize = 0,
    total_rows: usize = 0,
    depth: usize = 0,
    /// The column of the left border.
    indent: usize = 0,
    /// The lines of the ancestor cards that run past this row down to a
    /// later sibling.
    rails: ?*const Rail = null,
    card: ?*const Card = null,
    /// The bottom row of a card that a later sibling follows. Its line runs
    /// down from the bottom-left corner to that sibling.
    sibling_below: bool = false,
    /// The cells between the padding inside the left and right borders.
    content_width: usize = 0,
    /// Only the first authored blank line represented by an empty row.
    blank_source: ?usize = null,
    hidden_line: ?SourceRange = null,
    fences: ?[2]SourceRange = null,
    plain_label: ?[]const u8 = null,
    /// Code-block rectangle relative to this row's content column.
    code_area: ?struct { column: usize, width: usize } = null,

    /// The first content cell: the left border, then one padding cell.
    pub fn contentColumn(self: ReviewCardRow) usize {
        return self.indent + 2;
    }

    /// The right border, after the content and one padding cell.
    pub fn rightBorderColumn(self: ReviewCardRow) usize {
        return self.contentColumn() + @max(self.content_width, 1) + 1;
    }
    pub fn text(self: ReviewCardRow) []const u8 {
        return if (self.segments.len == 1) self.segments[0].text else "";
    }

    pub fn commentItem(self: ReviewCardRow) *const bbr.review.Comment {
        return switch (self.source) {
            .comment => |value| value,
            else => unreachable,
        };
    }

    pub fn draftItem(self: ReviewCardRow) *const bbr.review.Draft {
        return switch (self.source) {
            .draft => |value| value,
            else => unreachable,
        };
    }

    pub fn isReply(self: ReviewCardRow) bool {
        return switch (self.role) {
            .comment_reply, .deleted_reply, .draft_reply, .outcome_unknown_reply => true,
            else => false,
        };
    }
};

pub const Options = struct {
    owner: Owner,
    source: Source,
    scope: bbr.review.CommentScope = .review,
    role: CardRole,
    header: []const u8,
    plain_header: ?[]const u8 = null,
    content_width: usize,
    metrics: CellMetrics,
    collapsed_rows: usize = 6,
    expanded: bool = false,
    depth: usize = 0,
    indent: usize = 0,
};

pub fn projectPreview(allocator: std.mem.Allocator, body: ReviewBody, options: Options, scroll: usize, height: usize) ![]const ReviewCardRow {
    var start: usize = 0;
    var logical_line: usize = 0;
    while (logical_line < scroll and start < body.source.len) : (logical_line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, body.source, start, '\n') orelse body.source.len;
        start = newline + @intFromBool(newline < body.source.len);
    }
    var sink = RowCollector{ .allocator = allocator, .preview_start = start, .height = height };
    defer sink.rows.deinit(allocator);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    try projectInto(allocator, scratch.allocator(), body, options, &sink);
    return sink.rows.toOwnedSlice(allocator);
}

pub fn project(allocator: std.mem.Allocator, body: ReviewBody, options: Options) ![]const ReviewCardRow {
    var sink = RowCollector{ .allocator = allocator };
    defer sink.rows.deinit(allocator);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    try projectInto(allocator, scratch.allocator(), body, options, &sink);
    return sink.rows.toOwnedSlice(allocator);
}

const RowCollector = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(ReviewCardRow) = .empty,
    preview_start: ?usize = null,
    height: usize = std.math.maxInt(usize),

    pub fn append(self: *RowCollector, row: ReviewCardRow) !void {
        if (self.preview_start) |start| {
            if (row.part.isBorder()) return;
            if (start > 0 and row.source_range.end <= start) return;
        }
        if (self.rows.items.len < self.height) try self.rows.append(self.allocator, row);
    }
};

/// Append normalized rows to the sink. Result storage owns Segments and generated text.
/// Scratch storage holds only temporary arrays and can be released after this call.
/// A sink failure can leave partial output. The caller must discard that output.
pub fn projectInto(allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, body: ReviewBody, options: Options, sink: anytype) !void {
    std.debug.assert(std.meta.eql(options.owner, ownerForSource(options.source)));
    std.debug.assert(options.source.body().ptr == body.source.ptr and options.source.body().len == body.source.len);

    var body_rows: std.ArrayList(ReviewCardRow) = .empty;
    defer body_rows.deinit(scratch_allocator);
    var writer = Writer{
        .allocator = allocator,
        .row_allocator = scratch_allocator,
        .rows = &body_rows,
        .options = options,
        .width = @max(options.content_width, 1),
    };
    defer writer.current.deinit(allocator);
    var table_header: ?body_mod.Block = null;
    var columns: []usize = &.{};
    defer scratch_allocator.free(columns);
    for (body.blocks, 0..) |block, ordinal| {
        if (block.kind == .table) {
            if (table_header == null or table_header.?.source.start != block.kind.table.header.start) {
                table_header = block;
                scratch_allocator.free(columns);
                columns = &.{};
                columns = try scratch_allocator.alloc(usize, block.kind.table.cells.len);
                @memset(columns, 0);
                for (body.blocks[ordinal..]) |row| {
                    if (row.kind != .table) {
                        if (row.kind == .literal) continue;
                        break;
                    }
                    if (row.kind.table.header.start != block.source.start) break;
                    for (row.kind.table.cells, 0..) |cell, index| {
                        const segments = try writer.cellSegments(row, cell);
                        defer allocator.free(segments);
                        var width: usize = 0;
                        for (segments) |segment| width += measuredWidth(options.metrics, segment.text);
                        columns[index] = @max(columns[index], width);
                    }
                }
                fitTableColumns(columns, writer.width);
            }
            try writer.table(block, ordinal, table_header.?, columns);
        } else try writer.block(block, ordinal);
    }

    var start: usize = 0;
    while (start < body_rows.items.len) {
        const area = body_rows.items[start].code_area orelse {
            start += 1;
            continue;
        };
        var end = start + 1;
        var width = area.width;
        while (end < body_rows.items.len and body_rows.items[end].block_ordinal == body_rows.items[start].block_ordinal) : (end += 1) {
            const next = body_rows.items[end].code_area orelse break;
            width = @max(width, next.width);
        }
        for (body_rows.items[start..end]) |*row| row.code_area.?.width = @min(width, writer.width -| row.code_area.?.column);
        start = end;
    }
    const collapsible = options.collapsed_rows > 0 and body_rows.items.len > options.collapsed_rows;
    const visible_count = if (collapsible and !options.expanded) options.collapsed_rows else body_rows.items.len;
    if (options.depth > 0) try sink.append(makeRow(options, .gap, 0, .literal, .{ .start = 0, .end = 0 }, &.{}));
    var header = makeRow(options, .header, 0, .literal, .{ .start = 0, .end = 0 }, try oneSegment(allocator, .{
        .text = options.header,
        .source = .{ .start = 0, .end = 0 },
    }));
    header.plain_label = options.plain_header;
    try sink.append(header);
    for (body_rows.items[0..visible_count]) |row| try sink.append(row);
    const body_end: SourceRange = .{ .start = body.source.len, .end = body.source.len };
    if (!collapsible) {
        try sink.append(makeRow(options, .bottom, body_rows.items.len, .literal, body_end, &.{}));
    } else {
        const hidden = body_rows.items.len - visible_count;
        const footer = if (options.expanded)
            try std.fmt.allocPrint(allocator, "▾ {d} total rows · enter to collapse", .{body_rows.items.len})
        else
            try std.fmt.allocPrint(allocator, "▸ {d} hidden rows · {d} total · enter to expand", .{ hidden, body_rows.items.len });
        var footer_row = makeRow(options, .disclosure_footer, body_rows.items.len, .literal, body_end, try oneSegment(allocator, .{
            .text = footer,
            .source = body_end,
        }));
        footer_row.hidden_rows = hidden;
        footer_row.total_rows = body_rows.items.len;
        try sink.append(footer_row);
    }
}

fn ownerForSource(source: Source) Owner {
    return switch (source) {
        .comment => |value| .{ .comment = value.id },
        .draft => |value| .{ .draft = value.local_id },
    };
}

fn fitTableColumns(columns: []usize, width: usize) void {
    const separators = (columns.len - 1) * 3;
    var natural = separators;
    for (columns) |column| natural +|= column;
    if (natural <= width) return;
    const available = width -| separators;
    var low: usize = 0;
    var high = available;
    while (low < high) {
        const cap = low + (high - low + 1) / 2;
        var used: usize = 0;
        for (columns) |column| used +|= @min(column, cap);
        if (used <= available) low = cap else high = cap - 1;
    }
    // Below 16 cells per reduced column, keep the header-labelled projection.
    if (low < 16) return;
    for (columns) |*column| column.* = @min(column.*, low);
}

fn oneSegment(allocator: std.mem.Allocator, segment: Segment) ![]const Segment {
    const result = try allocator.alloc(Segment, 1);
    result[0] = segment;
    return result;
}

fn makeRow(options: Options, part: Part, ordinal: usize, kind: BlockKind, range: SourceRange, segments: []const Segment) ReviewCardRow {
    return .{
        .owner = options.owner,
        .source = options.source,
        .scope = options.scope,
        .role = options.role,
        .part = part,
        .block_ordinal = ordinal,
        .block_kind = kind,
        .source_range = range,
        .segments = segments,
        .depth = options.depth,
        .indent = options.indent,
        .content_width = options.content_width,
    };
}

const Writer = struct {
    allocator: std.mem.Allocator,
    row_allocator: std.mem.Allocator,
    rows: *std.ArrayList(ReviewCardRow),
    options: Options,
    width: usize,
    current: std.ArrayList(Segment) = .empty,
    current_width: usize = 0,
    current_range: ?SourceRange = null,
    ordinal: usize = 0,
    kind: BlockKind = .paragraph,
    part: Part = .body,
    hidden_line: ?SourceRange = null,
    fences: ?[2]SourceRange = null,
    container: body_mod.Block = .{ .kind = .paragraph, .source = .{ .start = 0, .end = 0 } },
    first_row: bool = true,
    prefix_width: usize = 0,
    reference: ?body_mod.Span = null,
    link: ?body_mod.LinkTarget = null,

    fn block(self: *Writer, value: body_mod.Block, ordinal: usize) !void {
        self.container = value;
        self.first_row = true;
        self.ordinal = ordinal;
        self.kind = value.kind;
        self.part = .body;
        self.hidden_line = value.hidden_line;
        self.fences = value.fences;
        switch (value.kind) {
            .table => unreachable,
            .spacer => try self.emitEmpty(value.source),
            .suggestion => {
                try self.emitSegments(&.{.{
                    .text = "suggestion",
                    .source = .{ .start = value.source.start, .end = value.source.start },
                    .marks = .{ .strong = true },
                    .authored = false,
                }}, .suggestion_label);
                self.part = .suggestion_body;
                for (value.spans) |span| try self.addToken(span.text, span.source, .{}, true);
                try self.flush();
            },
            .heading => |level| {
                self.part = .body;
                const markers = [_][]const u8{ "# ", "## ", "### ", "#### ", "##### ", "###### " };
                try self.addToken(markers[level - 1], .{ .start = value.source.start, .end = value.source.start }, .{ .heading_marker = true }, false);
                for (value.spans) |span| try self.addSpan(span, true);
                try self.flush();
            },
            .code, .literal => {
                if (value.kind == .code) self.part = .code_body;
                for (value.spans) |span| try self.addToken(span.text, span.source, .{}, true);
                try self.flush();
            },
            .paragraph => {
                for (value.spans) |span| try self.addSpan(span, false);
                if (value.spans.len == 0) try self.addPrefix(0);
                try self.flush();
            },
        }
    }

    fn cellSegments(self: *Writer, block_value: body_mod.Block, cell: body_mod.TableCell) ![]const Segment {
        const rows = try self.cellRows(block_value, cell, std.math.maxInt(usize));
        defer {
            for (rows) |row| self.allocator.free(row.segments);
            self.row_allocator.free(rows);
        }
        // Inline code can contain a hard break. Keep its complete content when measuring the cell.
        var segments: std.ArrayList(Segment) = .empty;
        errdefer segments.deinit(self.allocator);
        for (rows) |row| try segments.appendSlice(self.allocator, row.segments);
        return segments.toOwnedSlice(self.allocator);
    }

    fn cellRows(self: *Writer, value: body_mod.Block, cell: body_mod.TableCell, width: usize) ![]const ReviewCardRow {
        var rows: std.ArrayList(ReviewCardRow) = .empty;
        errdefer {
            for (rows.items) |row| self.allocator.free(row.segments);
            rows.deinit(self.row_allocator);
        }
        var cell_writer = Writer{ .allocator = self.allocator, .row_allocator = self.row_allocator, .rows = &rows, .options = self.options, .width = @max(width, 1) };
        defer cell_writer.current.deinit(self.allocator);
        for (value.spans[cell.spans.start..cell.spans.end]) |span| try cell_writer.addSpan(span, false);
        try cell_writer.flush();
        return rows.toOwnedSlice(self.row_allocator);
    }

    fn table(self: *Writer, value: body_mod.Block, ordinal: usize, header: body_mod.Block, columns: []const usize) !void {
        self.container = value;
        self.ordinal = ordinal;
        self.kind = value.kind;
        self.part = .body;
        self.hidden_line = value.hidden_line;
        self.fences = null;
        var complete_width: usize = (columns.len - 1) * 3;
        for (columns) |width| complete_width += width;
        const wide = complete_width <= self.width;
        if (wide) {
            const cells = try self.row_allocator.alloc([]const ReviewCardRow, columns.len);
            @memset(cells, &.{});
            defer {
                for (cells) |rows| {
                    for (rows) |row| self.allocator.free(row.segments);
                    self.row_allocator.free(rows);
                }
                self.row_allocator.free(cells);
            }
            var height: usize = 1;
            for (value.kind.table.cells, 0..) |cell, index| {
                cells[index] = try self.cellRows(value, cell, columns[index]);
                height = @max(height, cells[index].len);
            }
            for (0..height) |line| {
                for (value.kind.table.cells, 0..) |cell, index| {
                    const segments: []const Segment = if (line < cells[index].len) cells[index][line].segments else &.{};
                    var cell_width: usize = 0;
                    for (segments) |segment| cell_width += measuredWidth(self.options.metrics, segment.text);
                    const padding = columns[index] - cell_width;
                    const before = switch (cell.alignment) {
                        .left => @as(usize, 0),
                        .center => padding / 2,
                        .right => padding,
                    };
                    try self.tablePadding(before);
                    for (segments) |segment| try self.append(segment, measuredWidth(self.options.metrics, segment.text));
                    try self.tablePadding(padding - before);
                    if (index + 1 < columns.len) try self.append(.{ .text = " │ ", .source = .{ .start = value.source.start, .end = value.source.start }, .marks = .{ .divider = true }, .authored = false }, 3);
                }
                try self.flush();
            }
            if (value.source.start == header.source.start) {
                self.hidden_line = null;
                for (columns, 0..) |width, index| {
                    for (0..width) |_| try self.append(.{
                        .text = "─",
                        .source = .{ .start = value.source.start, .end = value.source.start },
                        .marks = .{ .divider = true },
                        .authored = false,
                    }, 1);
                    if (index + 1 < columns.len) try self.append(.{
                        .text = "─┼─",
                        .source = .{ .start = value.source.start, .end = value.source.start },
                        .marks = .{ .divider = true },
                        .authored = false,
                    }, 3);
                }
                try self.flush();
            }
            return;
        }
        for (value.kind.table.cells, 0..) |cell, index| {
            // These labels are decoration. Only the actual header row owns header text.
            if (value.source.start != header.source.start) {
                const label = try self.cellSegments(header, header.kind.table.cells[index]);
                defer self.allocator.free(label);
                for (label) |segment| {
                    self.link = segment.link;
                    defer self.link = null;
                    try self.addToken(segment.text, .{ .start = value.source.start, .end = value.source.start }, segment.marks, false);
                }
                try self.addToken(": ", .{ .start = value.source.start, .end = value.source.start }, .{}, false);
            }
            for (value.spans[cell.spans.start..cell.spans.end]) |span| try self.addSpan(span, false);
            try self.flush();
        }
    }

    fn tablePadding(self: *Writer, count: usize) !void {
        for (0..count) |_| try self.append(.{ .text = " ", .source = .{ .start = self.container.source.start, .end = self.container.source.start }, .authored = false }, 1);
    }

    fn addSpan(self: *Writer, span: body_mod.Span, force_strong: bool) !void {
        self.link = span.link;
        defer self.link = null;
        if (span.hard_break) {
            if (span.marks.inline_code and self.current.items.len == 0) try self.emitEmpty(span.source) else try self.flush();
            return;
        }
        if (span.hidden) {
            if (span.strike_delimiter and !self.options.metrics.strikethrough_supported) {
                try self.addToken(self.options.source.body()[span.source.start..span.source.end], span.source, .{}, true);
            }
            return;
        }
        var marks = span.marks;
        marks.strikethrough = marks.strikethrough and self.options.metrics.strikethrough_supported;
        marks.strong = marks.strong or force_strong;
        self.reference = if (span.definition_source != null) span else null;
        defer self.reference = null;
        if (span.emoji.len > 0) {
            const cells = self.options.metrics.width(span.text);
            try self.addPrefix(cells);
            if (self.current_width > self.prefix_width and self.current_width + cells > self.width) {
                try self.flush();
                try self.addPrefix(cells);
            }
            try self.append(.{ .text = span.text, .source = span.source, .marks = marks, .atomic = true }, cells);
            if (self.current_width >= self.width) try self.flush();
            return;
        }
        if (span.generated) {
            try self.addToken(span.text, span.source, marks, false);
            return;
        }
        if (span.join) {
            if (self.current.items.len > 0 and self.current_width < self.width) {
                try self.append(.{ .text = " ", .source = span.source, .marks = marks }, 1);
            } else if (self.rows.items.len > 0) {
                const previous = &self.rows.items[self.rows.items.len - 1];
                if (previous.block_ordinal == self.ordinal) previous.source_range.end = span.source.end;
            }
            return;
        }
        if (marks.inline_code) {
            try self.addToken(span.text, span.source, marks, true);
            return;
        }
        if (marks.link_destination and span.destination_brackets) {
            const before = SourceRange{ .start = span.source.start, .end = span.source.start };
            const after = SourceRange{ .start = span.source.end, .end = span.source.end };
            try self.addToken(" ", before, .{}, false);
            try self.addToken("‹", before, marks, false);
            try self.addToken(span.text, span.source, marks, true);
            try self.addToken("›", after, marks, false);
        } else if (marks.link_title) {
            try self.addToken(" ", .{ .start = span.source.start, .end = span.source.start }, .{}, false);
            try self.addToken(span.text, span.source, marks, true);
        } else if (marks.link_destination) {
            try self.addToken(span.text, span.source, marks, true);
        } else try self.addWords(span.text, span.source, marks);
    }

    fn addWords(self: *Writer, text: []const u8, range: SourceRange, marks: Marks) !void {
        var pos: usize = 0;
        while (pos < text.len) {
            if (std.ascii.isWhitespace(text[pos])) {
                const start = pos;
                while (pos < text.len and std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
                if (self.current.items.len > 0 and self.current_width < self.width) try self.append(.{ .text = " ", .source = .{ .start = range.start + start, .end = range.start + pos }, .marks = marks }, 1);
                continue;
            }
            const start = pos;
            while (pos < text.len and !std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
            const token_range = SourceRange{ .start = range.start + start, .end = range.start + pos };
            const token_width = measuredWidth(self.options.metrics, text[start..pos]);
            try self.addPrefix(validMeasurement(self.options.metrics, text[start..pos]).cell_width);
            if (self.current_width > self.prefix_width and self.current_width + token_width > self.width) try self.flush();
            try self.addToken(text[start..pos], token_range, marks, true);
        }
    }

    fn addToken(self: *Writer, text: []const u8, range: SourceRange, marks: Marks, authored: bool) !void {
        var pos: usize = 0;
        var code_column: usize = 0;
        const literal = marks.inline_code or self.kind == .code or self.kind == .suggestion or self.kind == .literal;
        while (pos < text.len) {
            if (literal and (text[pos] == '\n' or (text[pos] == '\r' and pos + 1 < text.len and text[pos + 1] == '\n'))) {
                const newline_length: usize = if (text[pos] == '\r') 2 else 1;
                if (self.current.items.len == 0 and code_column == 0) {
                    try self.emitEmpty(.{ .start = range.start + pos, .end = range.start + pos + newline_length });
                } else try self.flush();
                pos += newline_length;
                code_column = 0;
                continue;
            }
            if (literal and text[pos] == '\t') {
                const spaces = 4 - code_column % 4;
                for (0..spaces) |_| {
                    try self.addPrefix(1);
                    if (self.current_width >= self.width) try self.flush();
                    try self.append(.{ .text = " ", .source = .{ .start = range.start + pos, .end = range.start + pos + 1 }, .marks = marks, .authored = authored }, 1);
                    if (self.current_width >= self.width) try self.flush();
                }
                code_column += spaces;
                pos += 1;
                continue;
            }
            const measured = validMeasurement(self.options.metrics, text[pos..]);
            const display = if (measured.valid) text[pos .. pos + measured.byte_len] else "�";
            try self.addPrefix(measured.cell_width);
            if (self.current_width > self.prefix_width and self.current_width + measured.cell_width > self.width) {
                try self.flush();
                try self.addPrefix(measured.cell_width);
            }
            try self.append(.{
                .text = display,
                .source = if (authored and self.reference == null) .{ .start = range.start + pos, .end = @min(range.start + pos + measured.byte_len, range.end) } else range,
                .marks = marks,
                .authored = authored,
                .definition_source = if (authored and self.reference != null) .{ .start = self.reference.?.definition_source.?.start + pos, .end = self.reference.?.definition_source.?.start + pos + measured.byte_len } else null,
                .required_definition = if (authored and self.reference != null) self.reference.?.required_definition else null,
            }, measured.cell_width);
            pos += measured.byte_len;
            code_column += measured.cell_width;
            if (self.current_width >= self.width) try self.flush();
        }
    }

    fn addPrefix(self: *Writer, reserved_cells: usize) !void {
        if (self.current.items.len > 0) return;
        if (self.container.quotes == 0 and self.container.indent == 0 and self.container.outer_indent == 0 and self.container.marker == null) return;
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(self.allocator);
        for (0..self.container.outer_indent) |_| try prefix.appendSlice(self.allocator, " ");
        var quote_pos: usize = 0;
        const quote_path = self.container.quote_path;
        while (quote_pos < quote_path.len and quote_path[quote_pos] == ' ') quote_pos += 1;
        while (quote_pos < quote_path.len) {
            if (quote_path[quote_pos] == '>') {
                try prefix.appendSlice(self.allocator, "│ ");
                quote_pos += 1;
                if (quote_pos < quote_path.len and quote_path[quote_pos] == ' ') quote_pos += 1;
            } else {
                const start = quote_pos;
                while (quote_pos < quote_path.len and quote_path[quote_pos] == ' ') quote_pos += 1;
                for (0..(quote_pos - start) / 2) |_| try prefix.appendSlice(self.allocator, " ");
            }
        }
        for (0..self.container.indent) |_| try prefix.appendSlice(self.allocator, " ");
        if (self.container.marker) |marker| {
            for (0..self.container.marker_padding) |_| try prefix.appendSlice(self.allocator, " ");
            if (self.first_row) {
                switch (marker) {
                    .bullet => try prefix.appendSlice(self.allocator, "• "),
                    .number => |number| try prefix.print(self.allocator, "{d}. ", .{number}),
                }
            } else for (0..body_mod.markerWidth(marker)) |_| try prefix.appendSlice(self.allocator, " ");
        }
        const text = try prefix.toOwnedSlice(self.allocator);
        var pos: usize = 0;
        self.prefix_width = 0;
        const available = self.width -| reserved_cells;
        while (pos < text.len and self.current_width < available) {
            const measured = validMeasurement(self.options.metrics, text[pos..]);
            if (self.current_width + measured.cell_width > available) break;
            try self.append(.{ .text = text[pos .. pos + measured.byte_len], .source = .{ .start = self.container.source.start, .end = self.container.source.start }, .authored = false }, measured.cell_width);
            self.prefix_width += measured.cell_width;
            pos += measured.byte_len;
        }
    }

    fn append(self: *Writer, segment: Segment, cells: usize) !void {
        var linked = segment;
        if (segment.marks.link_label or segment.marks.link_destination) linked.link = segment.link orelse self.link;
        try self.current.append(self.allocator, linked);
        self.current_width += cells;
        if (!segment.authored) return;
        if (self.current_range) |*range| {
            range.start = @min(range.start, segment.source.start);
            range.end = @max(range.end, segment.source.end);
        } else self.current_range = segment.source;
    }

    fn emitSegments(self: *Writer, segments: []const Segment, part: Part) !void {
        self.part = part;
        for (segments) |segment| try self.addToken(segment.text, segment.source, segment.marks, segment.authored);
        try self.flush();
    }

    fn emitEmpty(self: *Writer, range: SourceRange) !void {
        try self.addPrefix(0);
        try self.emitRow(range, if (self.kind == .spacer and self.container.quotes > 0) null else range.start);
    }

    fn flush(self: *Writer) !void {
        if (self.current.items.len == 0) return;
        try self.emitRow(self.current_range orelse .{ .start = self.container.source.start, .end = self.container.source.start }, null);
    }

    fn emitRow(self: *Writer, range: SourceRange, blank_source: ?usize) !void {
        const segments = try self.current.toOwnedSlice(self.allocator);
        var row = makeRow(self.options, self.part, self.ordinal, self.kind, range, segments);
        row.blank_source = blank_source;
        row.hidden_line = self.hidden_line;
        row.fences = self.fences;
        if (self.part == .code_body or self.part == .suggestion_body or self.part == .suggestion_label) {
            row.code_area = .{ .column = self.prefix_width, .width = self.current_width - self.prefix_width };
        }
        try self.rows.append(self.row_allocator, row);
        self.current = .empty;
        self.current_width = 0;
        self.current_range = null;
        self.first_row = false;
        self.prefix_width = 0;
    }
};

const ValidMeasurement = struct { byte_len: usize, cell_width: usize, valid: bool };
fn validMeasurement(metrics: CellMetrics, text: []const u8) ValidMeasurement {
    const expected = std.unicode.utf8ByteSequenceLength(text[0]) catch return .{ .byte_len = 1, .cell_width = 1, .valid = false };
    const expected_len: usize = expected;
    if (expected_len > text.len or !std.unicode.utf8ValidateSlice(text[0..expected_len])) return .{ .byte_len = 1, .cell_width = 1, .valid = false };
    const measured = metrics.next(text);
    if (measured.byte_len > text.len or !std.unicode.utf8ValidateSlice(text[0..measured.byte_len])) return .{ .byte_len = expected_len, .cell_width = 1, .valid = true };
    return .{ .byte_len = measured.byte_len, .cell_width = @max(measured.cell_width, 1), .valid = true };
}

fn measuredWidth(metrics: CellMetrics, text: []const u8) usize {
    var width: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const measured = validMeasurement(metrics, text[pos..]);
        width += measured.cell_width;
        pos += measured.byte_len;
    }
    return width;
}

const testing = std.testing;

test "sink projection survives scratch destruction and matches projection and preview rows" {
    var result = std.heap.ArenaAllocator.init(testing.allocator);
    defer result.deinit();
    const a = result.allocator();
    const bodies = [_][]const u8{
        "one **two**\nthree four five\n\nsix",
        "> 12. wrapped list item with generated prefixes\n>     another line",
        "```zig\n\tconst x = 1;\nlonger code line\n```",
        "First | Second\n--- | ---\n**abcdefghijklmnopqrstuvwxyz0123456789** | [docs](https://example.invalid/link)",
    };
    for (bodies) |raw| {
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        const body = try ReviewBody.parse(a, raw);
        for ([_]usize{ 8, 35, 120 }) |width| for ([_]bool{ false, true }) |expanded| {
            const options: Options = .{
                .owner = .{ .comment = 1 },
                .source = .{ .comment = &comment },
                .role = .comment_reply,
                .header = "Ada",
                .plain_header = "Ada plain",
                .content_width = width,
                .metrics = TestMetrics.value,
                .collapsed_rows = 2,
                .expanded = expanded,
                .depth = 1,
            };
            const expected = try project(a, body, options);
            var sink = RowCollector{ .allocator = testing.allocator };
            defer sink.rows.deinit(testing.allocator);
            {
                var scratch = std.heap.ArenaAllocator.init(testing.allocator);
                defer scratch.deinit();
                try projectInto(a, scratch.allocator(), body, options, &sink);
            }
            try testing.expectEqualDeep(expected, sink.rows.items);
            for ([_]usize{ 0, 1, 20 }) |scroll| for ([_]usize{ 0, 1, 4 }) |height| {
                const preview = try projectPreview(a, body, options, scroll, height);
                var start: usize = 0;
                for (0..scroll) |_| {
                    if (start >= raw.len) break;
                    const newline = std.mem.indexOfScalarPos(u8, raw, start, '\n') orelse raw.len;
                    start = newline + @intFromBool(newline < raw.len);
                }
                var index: usize = 0;
                for (expected) |row| {
                    if (row.part.isBorder() or (start > 0 and row.source_range.end <= start)) continue;
                    if (index == height) break;
                    try testing.expectEqualDeep(row, preview[index]);
                    index += 1;
                }
                try testing.expectEqual(index, preview.len);
            };
        };
    }
}

test "sink projection releases scratch rows after allocation and sink failures" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(backing: std.mem.Allocator) !void {
            var result = std.heap.ArenaAllocator.init(backing);
            defer result.deinit();
            const a = result.allocator();
            const raw = "First | Second\n--- | ---\n**long first cell** | second cell\n\n> 1. wrapped text\n\n```zig\nlong code line\n```";
            const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
            const body = try ReviewBody.parse(a, raw);
            for ([_]usize{ 8, 40 }) |width| {
                var sink = RowCollector{ .allocator = backing };
                defer sink.rows.deinit(backing);
                try projectInto(a, backing, body, .{
                    .owner = .{ .comment = 1 },
                    .source = .{ .comment = &comment },
                    .role = .comment_reply,
                    .header = "Ada",
                    .content_width = width,
                    .metrics = TestMetrics.value,
                    .collapsed_rows = 2,
                    .depth = 1,
                }, &sink);
                try testing.expectEqual(Part.disclosure_footer, sink.rows.items[sink.rows.items.len - 1].part);
            }
        }
    }.run, .{});
}

test "M23 emoji projection preserves compounds with adapter supplied terminal widths" {
    const Metrics = struct {
        fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            return .{ .byte_len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1, .cell_width = 1 };
        }
        fn width(ptr: *const anyopaque, text: []const u8) usize {
            const cells: *const usize = @ptrCast(@alignCast(ptr));
            return if (std.mem.eql(u8, text, "👩🏻‍💻")) cells.* else text.len;
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "ab :woman_technologist::skin-tone-2: z";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const body = try ReviewBody.parse(a, raw);
    for ([_]usize{ 3, 5 }) |cells| for ([_]usize{ 1, 4, 8 }) |width| {
        const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = width, .metrics = .{ .ptr = &cells, .vtable = &.{ .next = Metrics.next, .width = Metrics.width } }, .collapsed_rows = 0 });
        var count: usize = 0;
        for (rows) |row| for (row.segments) |segment| if (segment.atomic) {
            count += 1;
            try testing.expectEqualStrings("👩🏻‍💻", segment.text);
            try testing.expectEqualStrings(":woman_technologist::skin-tone-2:", raw[segment.source.start..segment.source.end]);
            if (width == 8) try testing.expectEqual(@as(usize, 0), row.source_range.start);
        };
        try testing.expectEqual(@as(usize, 1), count);
    };
}

test "M23 tables project aligned columns and wrapped generated labels as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "| Name | State |\n| :--- | ---: |\n| **Ada** | `Ready` |\n| Bo | Waiting |";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const body = try ReviewBody.parse(a, raw);
    for ([_]usize{ 40, 8, 1 }) |width| {
        const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
        var ada: std.ArrayList(u8) = .empty;
        var authored: std.ArrayList(u8) = .empty;
        for (rows[1..]) |row| {
            var cells: usize = 0;
            for (row.segments) |segment| {
                cells += measuredWidth(TestMetrics.value, segment.text);
                if (row.block_ordinal == 1) try ada.appendSlice(a, segment.text);
                if (segment.authored) try authored.appendSlice(a, segment.text);
                if (segment.source.start >= 33 and segment.source.end <= 36 and segment.authored) try testing.expect(segment.marks.strong);
            }
            try testing.expect(cells <= width);
        }
        try testing.expectEqualStrings("NameStateAdaReadyBoWaiting", authored.items);
        if (width == 40) try testing.expectEqualStrings("Ada  │   Ready", ada.items) else try testing.expectEqualStrings("Name: AdaState: Ready", ada.items);
    }
}

test "M23 tables wrap columns at the readability threshold without losing styles links or source ownership" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "First | Second\n--- | ---\n**abcdefghijklmnopqrstuvwxyz0123456789** | [docs](https://example.invalid/responsive/link)";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const body = try ReviewBody.parse(a, raw);
    for ([_]usize{ 120, 35, 34, 20, 1, 35 }) |width| {
        const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
        var authored: std.ArrayList(u8) = .empty;
        var first: std.ArrayList(u8) = .empty;
        var second: std.ArrayList(u8) = .empty;
        var separators: usize = 0;
        var dividers: usize = 0;
        for (rows[1..]) |row| {
            var cells: usize = 0;
            var divider = false;
            for (row.segments) |segment| {
                cells += measuredWidth(TestMetrics.value, segment.text);
                if (!segment.authored) {
                    try testing.expectEqual(segment.source.start, segment.source.end);
                    if (std.mem.eql(u8, segment.text, " │ ")) separators += 1;
                    if (segment.marks.divider and !std.mem.eql(u8, segment.text, " │ ")) divider = true;
                    continue;
                }
                // Wrapped cells are interleaved by displayed row. Recover authored cell order.
                if (row.block_ordinal == 0) try authored.appendSlice(a, segment.text) else if (segment.marks.strong) {
                    try first.appendSlice(a, segment.text);
                } else try second.appendSlice(a, segment.text);
                if (segment.marks.link_label or segment.marks.link_destination) {
                    try testing.expectEqualStrings("https://example.invalid/responsive/link", segment.link.?.destination);
                }
            }
            try testing.expect(cells <= width);
            try testing.expectEqual(@as(u64, 1), row.owner.comment);
            if (divider) {
                try testing.expect(row.hidden_line == null and row.blank_source == null);
                try testing.expectEqual(row.source_range.start, row.source_range.end);
                dividers += 1;
            }
        }
        try authored.appendSlice(a, first.items);
        try authored.appendSlice(a, second.items);
        try testing.expectEqualStrings("FirstSecondabcdefghijklmnopqrstuvwxyz0123456789docshttps://example.invalid/responsive/link", authored.items);
        try testing.expectEqual(width >= 35, separators > 0);
        try testing.expectEqual(@as(usize, if (width >= 35) 1 else 0), dividers);
    }
    var uneven = [_]usize{ 100, 3, 3 };
    fitTableColumns(&uneven, 50);
    try testing.expectEqualSlices(usize, &.{ 38, 3, 3 }, &uneven);
    try testing.expectEqualStrings(raw, body.source);
}

test "M23 tables choose complete width with alignment links empty cells and literal fallback as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "A | B | C\n:--- | :---: | ---:\nlong | wide | full\nx | y | z\nm |\nextra | row | has | cells\n\n[**docs**](/path)";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const body = try ReviewBody.parse(a, raw);
    for ([_]usize{ 18, 17 }) |width| {
        const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
        var short: std.ArrayList(u8) = .empty;
        for (rows[1..]) |row| if (row.block_ordinal == 2) {
            for (row.segments) |segment| try short.appendSlice(a, segment.text);
        };
        try testing.expectEqualStrings(if (width == 18) "x    │  y   │    z" else "A: xB: yC: z", short.items);
    }
    const links = "| Item | State |\n| --- | --- |\n| [**docs**](/path) | *ready* |\n| empty |";
    const linked: bbr.review.Comment = .{ .id = 2, .author = "Ada", .body = links };
    const parsed = try ReviewBody.parse(a, links);
    try testing.expectEqual(parsed.blocks[2].kind.table.cells[1].spans.start, parsed.blocks[2].kind.table.cells[1].spans.end);
    for ([_]usize{ 40, 6 }) |width| {
        const rows = try project(a, parsed, .{ .owner = .{ .comment = 2 }, .source = .{ .comment = &linked }, .role = .comment, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
        var destination: std.ArrayList(u8) = .empty;
        for (rows[1..]) |row| for (row.segments) |segment| {
            if (segment.marks.link_destination and segment.authored) try destination.appendSlice(a, segment.text);
            if (segment.marks.link_label and segment.authored) try testing.expect(segment.marks.strong);
            if (segment.marks.emphasis) try testing.expectEqual(@as(usize, 1), row.block_ordinal);
        };
        try testing.expectEqualStrings("/path", destination.items);
    }
}

test "M23 links wrap complete destinations and literal titles in ReviewCards as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "![**diagram**](<images/a  b_(c)/:mask:> \"Guide *literal*\")";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    for ([_]usize{ 80, 7, 1 }) |width| {
        const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
        var destination: std.ArrayList(u8) = .empty;
        var title: std.ArrayList(u8) = .empty;
        var visible: std.ArrayList(u8) = .empty;
        for (rows[1..]) |row| for (row.segments) |segment| {
            try visible.appendSlice(a, segment.text);
            if (segment.marks.link_destination and segment.authored) try destination.appendSlice(a, segment.text);
            if (segment.marks.link_title and segment.authored) try title.appendSlice(a, segment.text);
            if (segment.marks.link_label) try testing.expect(segment.marks.strong);
        };
        try testing.expectEqualStrings("images/a  b_(c)/:mask:", destination.items);
        try testing.expectEqualStrings("\"Guide *literal*\"", title.items);
        if (width == 80) try testing.expectEqualStrings("image: diagram ‹images/a  b_(c)/:mask:› \"Guide *literal*\"", visible.items);
    }
}

test "M23 containers align wrapped item text and mixed quote nesting as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "4. first words\n    more\n    - child\n        8. grandchild\n1. second\n\n> quoted\n> continuation\n>> deeper";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = 16, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const expected = [_][]const u8{ "Ada", "4. first words ", "   more", "  • child", "    8. grandchil", "       d", "5. second", "", "│ quoted ", "│ continuation", "│ │ deeper", "" };
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |row, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (row.segments) |segment| try visible.appendSlice(a, segment.text);
        try testing.expectEqualStrings(text, visible.items);
    }
}

test "M23 containers keep code tab stops and authored ranges in narrow Replies as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "> - item\n>     ```zig\n>     a\tb\n>     ```", "- item\n    - child\n        ~~~\n        a\tb\n        ~~~", "> - item\n>         a\tb\n" }) |raw| {
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        for ([_]usize{ 30, 8, 2, 1 }) |width| {
            const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0, .indent = 7 });
            var code: std.ArrayList(u8) = .empty;
            for (rows) |row| {
                if (row.part != .code_body) continue;
                for (row.segments) |segment| if (segment.authored) {
                    try code.appendSlice(a, segment.text);
                    try testing.expect(segment.source.start >= row.source_range.start);
                    try testing.expect(segment.source.end <= row.source_range.end);
                };
            }
            try testing.expectEqualStrings("a   b", code.items);
        }
    }
    const empty: bbr.review.Comment = .{ .id = 2, .author = "Ada", .body = "- " };
    const rows = try project(a, try ReviewBody.parse(a, empty.body), .{ .owner = .{ .comment = 2 }, .source = .{ .comment = &empty }, .role = .comment, .header = "Ada", .content_width = 8, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows[1].segments) |segment| try testing.expect(!segment.authored);
    try testing.expect(rows[1].blank_source == null);
}

test "M23 containers reserve complete wide graphemes within narrow body widths as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "> 界", ">     界", "- 界", "> - 界" }) |raw| {
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        for ([_]usize{ 2, 3, 4 }) |width| {
            const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
            var saw_wide = false;
            for (rows[1..]) |row| {
                var cells: usize = 0;
                for (row.segments) |segment| {
                    cells += measuredWidth(TestMetrics.value, segment.text);
                    if (std.mem.eql(u8, segment.text, "界")) saw_wide = true;
                }
                try testing.expect(cells <= width);
            }
            try testing.expect(saw_wide);
        }
    }
}

test "M23 containers align ordered dots across digit growth and retain independent list widths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "9. first\n    > quote\n    >\n    after\n    99. child\n    1. child\n1. second\n\nreset\n\n1. separate\n\n> 9. quoted\n> 1. quoted";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const body = try ReviewBody.parse(a, raw);
    const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = 40, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const expected = [_][]const u8{ "Ada", " 9. first", "    │ quote", "    │ ", "    after", "   99. child", "  100. child", "10. second", "", "reset", "", "1. separate", "", "│  9. quoted", "│ 10. quoted", "" };
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |row, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (row.segments) |segment| {
            try visible.appendSlice(a, segment.text);
            if (!segment.authored) try testing.expectEqual(segment.source.start, segment.source.end);
        }
        try testing.expectEqualStrings(text, visible.items);
    }
    const wrapped: bbr.review.Comment = .{ .id = 2, .author = "Ada", .body = "9. abcdefghijkl\n1. x" };
    const narrow = try project(a, try ReviewBody.parse(a, wrapped.body), .{ .owner = .{ .comment = 2 }, .source = .{ .comment = &wrapped }, .role = .comment_reply, .header = "Ada", .content_width = 10, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const wrapped_expected = [_][]const u8{ "Ada", " 9. abcdef", "    ghijkl", "10. x", "" };
    try testing.expectEqual(wrapped_expected.len, narrow.len);
    for (narrow, wrapped_expected) |row, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (row.segments) |segment| try visible.appendSlice(a, segment.text);
        try testing.expectEqualStrings(text, visible.items);
    }
    try testing.expectEqualStrings(raw, body.source);
}

test "M23 containers show quotes and quote code inside list items as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "- parent\n    > quoted\n    > continuation\n    >\n    > - child\n    >     ```\n    >     a\tb\n    >     ```\n    after\n- sibling";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 40, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const expected = [_][]const u8{ "Ada", "• parent", "  │ quoted continuation", "  │ ", "  │ • child", "  │   a   b", "  after", "• sibling", "" };
    for (expected, 0..) |text, index| {
        var visible: std.ArrayList(u8) = .empty;
        for (rows[index].segments) |segment| try visible.appendSlice(a, segment.text);
        try testing.expectEqualStrings(text, visible.items);
    }
    try testing.expectEqual(expected.len, rows.len);
}

test "M23 containers show alternating quote and list nesting as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "> - parent\n>     > quoted\n>     > continuation\n>     > ~~~\n>     > a\tb\n>     > ~~~\n>     after\n> - sibling";
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
    const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 40, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const expected = [_][]const u8{ "Ada", "│ • parent", "│   │ quoted continuation", "│   │ a   b", "│   after", "│ • sibling", "" };
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |row, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (row.segments) |segment| try visible.appendSlice(a, segment.text);
        try testing.expectEqualStrings(text, visible.items);
    }
}

test "M23 literal code wraps complete whitespace from its own tab origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "```zig\r\na\tb  \r\n\n  *x* :mask: <b>\n```", "~~~suggestion\r\na\tb  \r\n\n  *x* :mask: <b>\n~~~", "    a\tb  \r\n\n      *x* :mask: <b>\n" }) |raw| {
        const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = raw };
        for ([_]usize{ 80, 3, 1 }) |width| for ([_]usize{ 0, 7 }) |indent| {
            const rows = try project(a, try ReviewBody.parse(a, raw), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0, .indent = indent });
            var visible: std.ArrayList(u8) = .empty;
            var blanks: usize = 0;
            for (rows) |row| {
                if (row.part.isBorder() or row.part == .suggestion_label) continue;
                if (row.segments.len == 0) blanks += 1;
                for (row.segments) |segment| {
                    try testing.expect(!segment.marks.inline_code and !segment.marks.strong);
                    try visible.appendSlice(a, segment.text);
                }
            }
            try testing.expectEqualStrings("a   b    *x* :mask: <b>", visible.items);
            try testing.expectEqual(@as(usize, 1), blanks);
        };
    }
}

test "M23 inline heading levels and paragraph rows hide syntax with exact source ownership" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "# One #\n## *Two*\n### `Three`\n#### Four\n##### Five\n###### Six\nSetext\n---\n\nfirst\nsecond\n\nthird  \nfourth" };
    const body = try ReviewBody.parse(a, comment.body);
    const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "header", .content_width = 80, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const expected = [_][]const u8{ "header", "# One", "## Two", "### Three", "#### Four", "##### Five", "###### Six", "## Setext", "", "first second", "", "third", "fourth", "" };
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |row, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (row.segments) |segment| try visible.appendSlice(a, segment.text);
        try testing.expectEqualStrings(text, visible.items);
        if (row.block_kind == .heading) for (row.segments) |segment| {
            try testing.expect(segment.marks.heading_marker or segment.marks.strong);
            if (!segment.authored) try testing.expectEqual(segment.source.start, segment.source.end);
        };
    }
    try testing.expect(rows[7].hidden_line != null);
    const malformed = try ReviewBody.parse(a, "####### literal\n#nospace\n    # indented\n\nnot heading\n= = =\n\nTitle\n\t===");
    for (malformed.blocks) |block| try testing.expect(block.kind != .heading);
}

test "M23 inline wrapped paragraph join retains the authored line ending for search navigation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "first\nsecond" };
    const rows = try project(a, try ReviewBody.parse(a, comment.body), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "header", .content_width = 5, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    try testing.expectEqual(SourceRange{ .start = 0, .end = 6 }, rows[1].source_range);
}

test "M23 inline code keeps leading empty authored rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "`\nfirst`" };
    const rows = try project(a, try ReviewBody.parse(a, comment.body), .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "header", .content_width = 80, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual(@as(?usize, 1), rows[1].blank_source);
    try testing.expectEqual(@as(usize, 0), rows[1].segments.len);
    try testing.expectEqual(SourceRange{ .start = 2, .end = 7 }, rows[2].source_range);
}

const TestMetrics = struct {
    fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
        if (std.mem.startsWith(u8, text, "e\xcc\x81")) return .{ .byte_len = 3, .cell_width = 1 };
        if (std.mem.startsWith(u8, text, "界")) return .{ .byte_len = 3, .cell_width = 2 };
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        return .{ .byte_len = @min(@as(usize, len), text.len), .cell_width = 1 };
    }
    const context: u8 = 0;
    const vtable: CellMetrics.VTable = .{ .next = next };
    const value: CellMetrics = .{ .ptr = &context, .vtable = &vtable };
};

test "ReviewCard wraps only at complete graphemes and keeps links visible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const comment: bbr.review.Comment = .{ .id = 9, .author = "Ada", .body = "e\xcc\x81界 [docs](https://x)" };
    const parsed = try ReviewBody.parse(allocator, comment.body);
    const rows = try project(allocator, parsed, .{
        .owner = .{ .comment = comment.id },
        .source = .{ .comment = &comment },
        .role = .comment,
        .header = "Ada",
        .content_width = 4,
        .metrics = TestMetrics.value,
        .collapsed_rows = 0,
    });
    try testing.expect(rows.len >= 3);
    try testing.expect(rows[0].part == .header);
    var saw_destination = false;
    for (rows[1..]) |row| for (row.segments) |segment| {
        if (segment.marks.link_destination) saw_destination = true;
    };
    try testing.expect(saw_destination);
}

test "collapsed row budget is hard across Suggestions and spacers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const draft: bbr.review.Draft = .{ .local_id = 4, .kind = .suggestion, .body = "one two three\n\n```suggestion\na\nb\nc\n```" };
    const parsed = try ReviewBody.parse(allocator, draft.body);
    const rows = try project(allocator, parsed, .{
        .owner = .{ .draft = draft.local_id },
        .source = .{ .draft = &draft },
        .role = .draft,
        .header = "✎ draft (suggestion)",
        .content_width = 5,
        .metrics = TestMetrics.value,
        .collapsed_rows = 3,
    });
    try testing.expectEqual(@as(usize, 5), rows.len); // header + 3 body + footer
    try testing.expect(rows[4].part == .disclosure_footer);
    try testing.expect(rows[4].hidden_rows > 0);
    try testing.expect(rows[4].total_rows > 3);
    for (rows) |row| switch (row.owner) {
        .draft => |id| try testing.expectEqual(draft.local_id, id),
        else => return error.WrongOwner,
    };
}

test "zero and narrow widths preserve invalid bytes and complete graphemes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const authored = [_]u8{ 0xff, ' ', 'e', 0xcc, 0x81, 0xe7, 0x95, 0x8c };
    const before = authored;
    const comment: bbr.review.Comment = .{ .id = 12, .author = "Ada", .body = &authored };
    const parsed = try ReviewBody.parse(allocator, comment.body);
    const rows = try project(allocator, parsed, .{
        .owner = .{ .comment = 12 },
        .source = .{ .comment = &comment },
        .role = .comment,
        .header = "Ada",
        .content_width = 0,
        .metrics = TestMetrics.value,
        .collapsed_rows = 0,
    });
    var saw_replacement = false;
    var saw_combining_cluster = false;
    for (rows[1..]) |row| for (row.segments) |segment| {
        if (std.mem.eql(u8, segment.text, "�")) saw_replacement = true;
        if (std.mem.eql(u8, segment.text, "e\xcc\x81")) saw_combining_cluster = true;
    };
    try testing.expect(saw_replacement and saw_combining_cluster);
    try testing.expectEqualSlices(u8, &before, &authored);
    try testing.expect(comment.body.ptr == parsed.source.ptr);
}

test "Comment Reply and Draft share identical body projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = "## Title\nA *nested **strong*** body";
    const comment: bbr.review.Comment = .{ .id = 1, .parent_id = 9, .author = "Ada", .body = text };
    const draft: bbr.review.Draft = .{ .local_id = 2, .kind = .comment, .parent = .{ .comment = 9 }, .body = text };
    const parsed = try ReviewBody.parse(allocator, text);
    const comment_rows = try project(allocator, parsed, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "Ada", .content_width = 12, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const draft_rows = try project(allocator, parsed, .{ .owner = .{ .draft = 2 }, .source = .{ .draft = &draft }, .role = .draft_reply, .header = "✎ draft", .content_width = 12, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    try testing.expectEqual(comment_rows.len, draft_rows.len);
    for (comment_rows[1..], draft_rows[1..]) |left, right| {
        try testing.expectEqual(left.part, right.part);
        try testing.expectEqual(left.source_range.start, right.source_range.start);
        try testing.expectEqual(left.source_range.end, right.source_range.end);
        try testing.expectEqual(left.segments.len, right.segments.len);
        for (left.segments, right.segments) |lseg, rseg| {
            try testing.expectEqualStrings(lseg.text, rseg.text);
            try testing.expectEqual(lseg.marks, rseg.marks);
        }
    }
}

test "M23 inline code preserves whitespace and source ownership through narrow wraps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "**`  *literal* :mask: <tag>  `**" };
    const body = try ReviewBody.parse(a, comment.body);
    for ([_]usize{ 80, 5 }) |width| {
        const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = width, .metrics = TestMetrics.value, .collapsed_rows = 0 });
        var visible: std.ArrayList(u8) = .empty;
        for (rows[1..]) |row| for (row.segments) |segment| {
            try visible.appendSlice(a, segment.text);
            try testing.expect(segment.authored);
            try testing.expect(segment.marks.strong);
            try testing.expectEqualStrings(comment.body[segment.source.start..segment.source.end], segment.text);
        };
        try testing.expectEqualStrings("  *literal* :mask: <tag>  ", visible.items);
    }
}

test "M23 inline terminal fallback keeps strike delimiters and maps expanded code tabs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comment: bbr.review.Comment = .{ .id = 1, .author = "Ada", .body = "~~**gone**~~ `a\tb`" };
    const body = try ReviewBody.parse(a, comment.body);
    for ([_]bool{ true, false }) |supported| {
        var metrics = TestMetrics.value;
        metrics.strikethrough_supported = supported;
        const rows = try project(a, body, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment, .header = "Ada", .content_width = 80, .metrics = metrics, .collapsed_rows = 0 });
        var visible: std.ArrayList(u8) = .empty;
        var tab_cells: usize = 0;
        for (rows[1..]) |row| for (row.segments) |segment| {
            try visible.appendSlice(a, segment.text);
            if (std.mem.eql(u8, comment.body[segment.source.start..segment.source.end], "\t")) {
                try testing.expect(segment.authored);
                tab_cells += segment.text.len;
            }
            if (std.mem.eql(u8, segment.text, "g")) try testing.expectEqual(supported, segment.marks.strikethrough);
        };
        try testing.expectEqual(@as(usize, 3), tab_cells);
        try testing.expectEqualStrings(if (supported) "gone a   b" else "~~gone~~ a   b", visible.items);
    }
}

test "M23 inline code keeps authored line breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const multiline: bbr.review.Comment = .{ .id = 2, .author = "Ada", .body = "`first\r\n  last  `" };
    const body = try ReviewBody.parse(a, multiline.body);
    const rows = try project(a, body, .{ .owner = .{ .comment = 2 }, .source = .{ .comment = &multiline }, .role = .comment, .header = "Ada", .content_width = 80, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    try testing.expectEqual(@as(usize, 4), rows.len);
    var last: std.ArrayList(u8) = .empty;
    for (rows[2].segments) |segment| try last.appendSlice(a, segment.text);
    try testing.expectEqualStrings("  last  ", last.items);
}
