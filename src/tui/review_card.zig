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

pub const CardRole = enum { comment, comment_reply, draft, draft_reply, outcome_unknown, outcome_unknown_reply };
pub const Part = enum { header, body, suggestion_label, suggestion_body, disclosure_footer };

pub const Segment = struct {
    text: []const u8,
    source: SourceRange,
    marks: Marks = .{},
};

pub const ReviewCardRow = struct {
    owner: Owner,
    source: Source,
    role: CardRole,
    part: Part,
    block_ordinal: usize,
    block_kind: BlockKind,
    source_range: SourceRange,
    segments: []const Segment,
    hidden_rows: usize = 0,
    total_rows: usize = 0,
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
            .comment_reply, .draft_reply, .outcome_unknown_reply => true,
            else => false,
        };
    }
};

pub const Options = struct {
    owner: Owner,
    source: Source,
    role: CardRole,
    header: []const u8,
    content_width: usize,
    metrics: CellMetrics,
    collapsed_rows: usize = 6,
    expanded: bool = false,
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
        .role = options.role,
        .part = part,
        .block_ordinal = ordinal,
        .block_kind = kind,
        .source_range = range,
        .segments = segments,
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

    fn block(self: *Writer, value: body_mod.Block, ordinal: usize) !void {
        self.ordinal = ordinal;
        self.kind = value.kind;
        self.part = .body;
        switch (value.kind) {
            .spacer => try self.emitEmpty(value.source),
            .suggestion => {
                try self.emitSegments(&.{.{
                    .text = "suggestion",
                    .source = value.source,
                    .marks = .{ .strong = true },
                }}, .suggestion_label);
                self.part = .suggestion_body;
                const content = value.spans[0];
                var pos: usize = 0;
                while (pos < content.text.len) {
                    const newline = std.mem.indexOfScalarPos(u8, content.text, pos, '\n') orelse content.text.len;
                    const line_range: SourceRange = .{ .start = content.source.start + pos, .end = content.source.start + newline };
                    if (newline == pos) {
                        try self.emitEmpty(line_range);
                    } else {
                        try self.addToken(content.text[pos..newline], line_range, .{});
                        try self.flush();
                    }
                    pos = if (newline < content.text.len) newline + 1 else content.text.len;
                }
            },
            .heading => {
                self.part = .body;
                try self.addToken("§", value.source, .{ .strong = true });
                for (value.spans) |span| try self.addSpan(span, true);
                try self.flush();
            },
            .paragraph, .literal => {
                for (value.spans) |span| try self.addSpan(span, false);
                try self.flush();
            },
        }
    }

    fn addSpan(self: *Writer, span: body_mod.Span, force_strong: bool) !void {
        var marks = span.marks;
        marks.strong = marks.strong or force_strong;
        if (marks.link_destination) {
            try self.addToken("‹", span.source, marks);
            try self.addWords(span.text, span.source, marks);
            try self.addToken("›", span.source, marks);
        } else try self.addWords(span.text, span.source, marks);
    }

    fn addWords(self: *Writer, text: []const u8, range: SourceRange, marks: Marks) !void {
        var pos: usize = 0;
        var needs_space = false;
        while (pos < text.len) {
            while (pos < text.len and std.ascii.isWhitespace(text[pos])) : (pos += 1) needs_space = true;
            if (pos >= text.len) break;
            const start = pos;
            while (pos < text.len and !std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
            const token_range = SourceRange{ .start = range.start + start, .end = range.start + pos };
            const token_width = measuredWidth(self.options.metrics, text[start..pos]);
            if (needs_space and self.current.items.len > 0 and self.current_width + 1 + token_width <= self.width) {
                try self.append(.{ .text = " ", .source = token_range, .marks = marks }, 1);
            } else if (self.current.items.len > 0 and self.current_width + token_width > self.width) try self.flush();
            try self.addToken(text[start..pos], token_range, marks);
            needs_space = true;
        }
    }

    fn addToken(self: *Writer, text: []const u8, range: SourceRange, marks: Marks) !void {
        var pos: usize = 0;
        while (pos < text.len) {
            const measured = validMeasurement(self.options.metrics, text[pos..]);
            const display = if (measured.valid) text[pos .. pos + measured.byte_len] else "�";
            if (self.current.items.len > 0 and self.current_width + measured.cell_width > self.width) try self.flush();
            try self.append(.{
                .text = display,
                .source = .{ .start = range.start + pos, .end = @min(range.start + pos + measured.byte_len, range.end) },
                .marks = marks,
            }, measured.cell_width);
            pos += measured.byte_len;
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
        for (segments) |segment| try self.addToken(segment.text, segment.source, segment.marks);
        try self.flush();
    }

    fn emitEmpty(self: *Writer, range: SourceRange) !void {
        try self.rows.append(self.allocator, makeRow(self.options, self.part, self.ordinal, self.kind, range, &.{}));
    }

    fn flush(self: *Writer) !void {
        if (self.current.items.len == 0) return;
        const segments = try self.current.toOwnedSlice(self.allocator);
        try self.rows.append(self.allocator, makeRow(self.options, self.part, self.ordinal, self.kind, self.current_range.?, segments));
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
