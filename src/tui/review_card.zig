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
pub const Part = enum { header, body, code_body, suggestion_label, suggestion_body, disclosure_footer };

pub const Segment = struct {
    text: []const u8,
    source: SourceRange,
    marks: Marks = .{},
    /// False for terminal markers and generated spacing, even with a source range.
    authored: bool = true,
};

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
    indent: usize = 0,
    /// Only the first authored blank line represented by an empty row.
    blank_source: ?usize = null,
    hidden_line: ?SourceRange = null,
    fences: ?[2]SourceRange = null,
    plain_label: ?[]const u8 = null,

    pub fn contentColumn(self: ReviewCardRow) usize {
        return self.indent + if (self.part == .header) @as(usize, 2) else 4;
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

pub fn project(allocator: std.mem.Allocator, body: ReviewBody, options: Options) ![]const ReviewCardRow {
    std.debug.assert(std.meta.eql(options.owner, ownerForSource(options.source)));
    std.debug.assert(options.source.body().ptr == body.source.ptr and options.source.body().len == body.source.len);

    var body_rows: std.ArrayList(ReviewCardRow) = .empty;
    errdefer body_rows.deinit(allocator);
    var writer = Writer{
        .allocator = allocator,
        .rows = &body_rows,
        .options = options,
        .width = @max(options.content_width, 1),
    };
    for (body.blocks, 0..) |block, ordinal| try writer.block(block, ordinal);

    const collapsible = options.collapsed_rows > 0 and body_rows.items.len > options.collapsed_rows;
    const visible_count = if (collapsible and !options.expanded) options.collapsed_rows else body_rows.items.len;
    const footer_count: usize = if (collapsible) 1 else 0;
    const rows = try allocator.alloc(ReviewCardRow, 1 + visible_count + footer_count);
    rows[0] = makeRow(options, .header, 0, .literal, .{ .start = 0, .end = 0 }, try oneSegment(allocator, .{
        .text = options.header,
        .source = .{ .start = 0, .end = 0 },
    }));
    rows[0].plain_label = options.plain_header;
    @memcpy(rows[1 .. 1 + visible_count], body_rows.items[0..visible_count]);
    if (collapsible) {
        const hidden = body_rows.items.len - visible_count;
        const footer = if (options.expanded)
            try std.fmt.allocPrint(allocator, "▾ {d} total rows · enter to collapse", .{body_rows.items.len})
        else
            try std.fmt.allocPrint(allocator, "▸ {d} hidden rows · {d} total · enter to expand", .{ hidden, body_rows.items.len });
        rows[rows.len - 1] = makeRow(options, .disclosure_footer, body_rows.items.len, .literal, .{ .start = body.source.len, .end = body.source.len }, try oneSegment(allocator, .{
            .text = footer,
            .source = .{ .start = body.source.len, .end = body.source.len },
        }));
        rows[rows.len - 1].hidden_rows = hidden;
        rows[rows.len - 1].total_rows = body_rows.items.len;
    }
    body_rows.deinit(allocator);
    return rows;
}

fn ownerForSource(source: Source) Owner {
    return switch (source) {
        .comment => |value| .{ .comment = value.id },
        .draft => |value| .{ .draft = value.local_id },
    };
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
    };
}

const Writer = struct {
    allocator: std.mem.Allocator,
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

    fn block(self: *Writer, value: body_mod.Block, ordinal: usize) !void {
        self.ordinal = ordinal;
        self.kind = value.kind;
        self.part = .body;
        self.hidden_line = value.hidden_line;
        self.fences = value.fences;
        switch (value.kind) {
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
                const markers = [_][]const u8{ "§1 ", "§2 ", "§3 ", "§4 ", "§5 ", "§6 " };
                try self.addToken(markers[level - 1], .{ .start = value.source.start, .end = value.source.start }, .{ .strong = true }, false);
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
                try self.flush();
            },
        }
    }

    fn addSpan(self: *Writer, span: body_mod.Span, force_strong: bool) !void {
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
        if (marks.link_destination) {
            const before = SourceRange{ .start = span.source.start, .end = span.source.start };
            const after = SourceRange{ .start = span.source.end, .end = span.source.end };
            if (self.current.items.len > 0) try self.addToken(" ", before, .{}, false);
            try self.addToken("‹", before, marks, false);
            try self.addWords(span.text, span.source, marks);
            try self.addToken("›", after, marks, false);
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
            if (self.current.items.len > 0 and self.current_width + token_width > self.width) try self.flush();
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
            if (self.current.items.len > 0 and self.current_width + measured.cell_width > self.width) try self.flush();
            try self.append(.{
                .text = display,
                .source = if (authored) .{ .start = range.start + pos, .end = @min(range.start + pos + measured.byte_len, range.end) } else range,
                .marks = marks,
                .authored = authored,
            }, measured.cell_width);
            pos += measured.byte_len;
            code_column += measured.cell_width;
            if (self.current_width >= self.width) try self.flush();
        }
    }

    fn append(self: *Writer, segment: Segment, cells: usize) !void {
        try self.current.append(self.allocator, segment);
        self.current_width += cells;
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
        var row = makeRow(self.options, self.part, self.ordinal, self.kind, range, &.{});
        row.blank_source = range.start;
        row.hidden_line = self.hidden_line;
        row.fences = self.fences;
        try self.rows.append(self.allocator, row);
    }

    fn flush(self: *Writer) !void {
        if (self.current.items.len == 0) return;
        const segments = try self.current.toOwnedSlice(self.allocator);
        var row = makeRow(self.options, self.part, self.ordinal, self.kind, self.current_range.?, segments);
        row.hidden_line = self.hidden_line;
        row.fences = self.fences;
        try self.rows.append(self.allocator, row);
        self.current = .empty;
        self.current_width = 0;
        self.current_range = null;
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
            for (rows[1..]) |row| {
                if (row.part == .suggestion_label) continue;
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
    const expected = [_][]const u8{ "header", "§1 One", "§2 Two", "§3 Three", "§4 Four", "§5 Five", "§6 Six", "§2 Setext", "", "first second", "", "third", "fourth" };
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |row, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (row.segments) |segment| try visible.appendSlice(a, segment.text);
        try testing.expectEqualStrings(text, visible.items);
        if (row.block_kind == .heading) for (row.segments) |segment| {
            try testing.expect(segment.marks.strong);
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
    try testing.expectEqual(@as(usize, 3), rows.len);
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
        .header = "▸ Ada",
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
        .header = "± draft",
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
        .header = "▸ Ada",
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
    const comment_rows = try project(allocator, parsed, .{ .owner = .{ .comment = 1 }, .source = .{ .comment = &comment }, .role = .comment_reply, .header = "↳ Ada", .content_width = 12, .metrics = TestMetrics.value, .collapsed_rows = 0 });
    const draft_rows = try project(allocator, parsed, .{ .owner = .{ .draft = 2 }, .source = .{ .draft = &draft }, .role = .draft_reply, .header = "↳ draft", .content_width = 12, .metrics = TestMetrics.value, .collapsed_rows = 0 });
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
    try testing.expectEqual(@as(usize, 3), rows.len);
    var last: std.ArrayList(u8) = .empty;
    for (rows[2].segments) |segment| try last.appendSlice(a, segment.text);
    try testing.expectEqualStrings("  last  ", last.items);
}
