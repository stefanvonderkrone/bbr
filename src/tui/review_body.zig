//! Pure, width-independent interpretation of authored review Markdown.

const std = @import("std");

pub const SourceRange = struct {
    start: usize,
    end: usize,
};

pub const Marks = packed struct {
    emphasis: bool = false,
    strong: bool = false,
    link_label: bool = false,
    link_destination: bool = false,
};

pub const Span = struct {
    text: []const u8,
    source: SourceRange,
    marks: Marks = .{},
};

pub const BlockKind = union(enum) {
    paragraph,
    heading: u3,
    suggestion,
    literal,
    spacer,
};

pub const Block = struct {
    kind: BlockKind,
    source: SourceRange,
    spans: []const Span = &.{},
};

pub const ReviewBody = struct {
    /// Borrowed, byte-for-byte authored Review storage.
    source: []const u8,
    blocks: []const Block,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ReviewBody {
        if (hasUnclosedSuggestion(source)) {
            const spans = try allocator.alloc(Span, 1);
            spans[0] = .{ .text = source, .source = .{ .start = 0, .end = source.len } };
            const blocks = try allocator.alloc(Block, 1);
            blocks[0] = .{ .kind = .literal, .source = .{ .start = 0, .end = source.len }, .spans = spans };
            return .{ .source = source, .blocks = blocks };
        }

        var blocks: std.ArrayList(Block) = .empty;
        errdefer blocks.deinit(allocator);
        var pos: usize = 0;
        var pending_spacer: ?SourceRange = null;
        while (pos < source.len) {
            const line = nextLine(source, pos);
            if (isBlank(line.text)) {
                if (pending_spacer) |*range| range.end = line.next else pending_spacer = .{ .start = pos, .end = line.next };
                pos = line.next;
                continue;
            }
            if (blocks.items.len > 0) if (pending_spacer) |range| {
                try blocks.append(allocator, .{ .kind = .spacer, .source = range });
            };
            pending_spacer = null;

            if (isSuggestionOpen(line.text)) {
                const start = pos;
                const content_start = line.next;
                var scan = line.next;
                while (scan < source.len) {
                    const candidate = nextLine(source, scan);
                    if (isFenceClose(candidate.text)) {
                        const spans = try allocator.alloc(Span, 1);
                        spans[0] = .{ .text = source[content_start..scan], .source = .{ .start = content_start, .end = scan } };
                        try blocks.append(allocator, .{ .kind = .suggestion, .source = .{ .start = start, .end = candidate.next }, .spans = spans });
                        pos = candidate.next;
                        break;
                    }
                    scan = candidate.next;
                }
                continue;
            }

            const heading = headingPrefix(line.text);
            if (heading) |prefix| {
                const text_start = pos + prefix.bytes;
                const spans = try parseInline(allocator, source, text_start, pos + line.text.len);
                try blocks.append(allocator, .{ .kind = .{ .heading = prefix.level }, .source = .{ .start = pos, .end = line.next }, .spans = spans });
                pos = line.next;
                continue;
            }

            const start = pos;
            var end = pos + line.text.len;
            var next = line.next;
            while (next < source.len) {
                const candidate = nextLine(source, next);
                if (isBlank(candidate.text) or isSuggestionOpen(candidate.text) or headingPrefix(candidate.text) != null) break;
                end = next + candidate.text.len;
                next = candidate.next;
            }
            const spans = try parseInline(allocator, source, start, end);
            try blocks.append(allocator, .{ .kind = .paragraph, .source = .{ .start = start, .end = end }, .spans = spans });
            pos = next;
        }
        return .{ .source = source, .blocks = try blocks.toOwnedSlice(allocator) };
    }
};

const Line = struct { text: []const u8, next: usize };

fn nextLine(source: []const u8, start: usize) Line {
    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    const end = if (newline > start and source[newline - 1] == '\r') newline - 1 else newline;
    return .{ .text = source[start..end], .next = if (newline < source.len) newline + 1 else source.len };
}

fn trimmed(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn isBlank(line: []const u8) bool {
    return trimmed(line).len == 0;
}

fn isSuggestionOpen(line: []const u8) bool {
    return std.mem.eql(u8, trimmed(line), "```suggestion");
}

fn isFenceClose(line: []const u8) bool {
    return std.mem.eql(u8, trimmed(line), "```");
}

fn hasUnclosedSuggestion(source: []const u8) bool {
    var pos: usize = 0;
    while (pos < source.len) {
        const line = nextLine(source, pos);
        if (isSuggestionOpen(line.text)) {
            var scan = line.next;
            while (scan < source.len) {
                const candidate = nextLine(source, scan);
                if (isFenceClose(candidate.text)) break;
                scan = candidate.next;
            }
            if (scan >= source.len) return true;
            pos = nextLine(source, scan).next;
        } else pos = line.next;
    }
    return false;
}

const HeadingPrefix = struct { level: u3, bytes: usize };
fn headingPrefix(line: []const u8) ?HeadingPrefix {
    var count: usize = 0;
    while (count < line.len and count < 6 and line[count] == '#') count += 1;
    if (count == 0 or count >= line.len or (line[count] != ' ' and line[count] != '\t')) return null;
    var bytes = count;
    while (bytes < line.len and (line[bytes] == ' ' or line[bytes] == '\t')) bytes += 1;
    return .{ .level = @intCast(count), .bytes = bytes };
}

fn appendSpan(list: *std.ArrayList(Span), allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, marks: Marks) !void {
    if (end <= start) return;
    try list.append(allocator, .{ .text = source[start..end], .source = .{ .start = start, .end = end }, .marks = marks });
}

fn parseInline(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize) ![]const Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);
    var pos = start;
    var plain = start;
    while (pos < end) {
        if (source[pos] == '\\' and pos + 1 < end and isEscapable(source[pos + 1])) {
            try appendSpan(&spans, allocator, source, plain, pos, .{});
            try appendSpan(&spans, allocator, source, pos + 1, pos + 2, .{});
            pos += 2;
            plain = pos;
            continue;
        }
        if (source[pos] == '[') if (std.mem.indexOfScalarPos(u8, source[0..end], pos + 1, ']')) |close_label| {
            if (close_label + 1 < end and source[close_label + 1] == '(') if (std.mem.indexOfScalarPos(u8, source[0..end], close_label + 2, ')')) |close_dest| {
                try appendSpan(&spans, allocator, source, plain, pos, .{});
                try appendSpan(&spans, allocator, source, pos + 1, close_label, .{ .link_label = true });
                try appendSpan(&spans, allocator, source, close_label + 2, close_dest, .{ .link_destination = true });
                pos = close_dest + 1;
                plain = pos;
                continue;
            };
        };
        const delimiter: ?struct { text: []const u8, marks: Marks } = if (pos + 1 < end and ((source[pos] == '*' and source[pos + 1] == '*') or (source[pos] == '_' and source[pos + 1] == '_')))
            .{ .text = source[pos .. pos + 2], .marks = .{ .strong = true } }
        else if (source[pos] == '*' or source[pos] == '_')
            .{ .text = source[pos .. pos + 1], .marks = .{ .emphasis = true } }
        else
            null;
        if (delimiter) |delim| {
            const close = std.mem.indexOfPos(u8, source[0..end], pos + delim.text.len, delim.text) orelse {
                pos += 1;
                continue;
            };
            if (close > pos + delim.text.len) {
                try appendSpan(&spans, allocator, source, plain, pos, .{});
                const inner = try parseInline(allocator, source, pos + delim.text.len, close);
                defer allocator.free(inner);
                for (inner) |span| {
                    var marked = span;
                    marked.marks.emphasis = marked.marks.emphasis or delim.marks.emphasis;
                    marked.marks.strong = marked.marks.strong or delim.marks.strong;
                    try spans.append(allocator, marked);
                }
                pos = close + delim.text.len;
                plain = pos;
                continue;
            }
        }
        pos += 1;
    }
    try appendSpan(&spans, allocator, source, plain, end, .{});
    return spans.toOwnedSlice(allocator);
}

fn isEscapable(byte: u8) bool {
    return switch (byte) {
        '\\', '*', '_', '[', ']', '(', ')', '#', '`' => true,
        else => false,
    };
}

const testing = std.testing;

test "ReviewBody parses supported structure while retaining authored ranges" {
    const source = "\n# Heading\n\nA **strong and _nested_** [link](https://x).\n\n```suggestion\n*x*\n\n```\n";
    const body = try ReviewBody.parse(testing.allocator, source);
    defer {
        for (body.blocks) |block| if (block.spans.len > 0) testing.allocator.free(block.spans);
        testing.allocator.free(body.blocks);
    }
    try testing.expectEqual(@as(usize, 5), body.blocks.len);
    try testing.expect(body.blocks[0].kind == .heading);
    try testing.expectEqual(@as(u3, 1), body.blocks[0].kind.heading);
    try testing.expect(body.blocks[1].kind == .spacer);
    try testing.expect(body.blocks[2].kind == .paragraph);
    try testing.expect(body.blocks[4].kind == .suggestion);
    try testing.expectEqualStrings("*x*\n\n", body.blocks[4].spans[0].text);
    try testing.expectEqualStrings(source, body.source);
    var saw_nested = false;
    var saw_destination = false;
    for (body.blocks[2].spans) |span| {
        if (span.marks.strong and span.marks.emphasis) saw_nested = true;
        if (span.marks.link_destination and std.mem.eql(u8, span.text, "https://x")) saw_destination = true;
    }
    try testing.expect(saw_nested);
    try testing.expect(saw_destination);
}

test "unclosed Suggestion degrades the complete body to literal authored text" {
    const source = "before\n```suggestion\n**still literal**";
    const body = try ReviewBody.parse(testing.allocator, source);
    defer {
        testing.allocator.free(body.blocks[0].spans);
        testing.allocator.free(body.blocks);
    }
    try testing.expectEqual(@as(usize, 1), body.blocks.len);
    try testing.expect(body.blocks[0].kind == .literal);
    try testing.expectEqualStrings(source, body.blocks[0].spans[0].text);
}
