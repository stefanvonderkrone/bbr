//! Pure, width-independent interpretation of authored review Markdown.

const std = @import("std");

pub const SourceRange = struct {
    start: usize,
    end: usize,
};

pub const Marks = packed struct {
    emphasis: bool = false,
    strong: bool = false,
    inline_code: bool = false,
    strikethrough: bool = false,
    link_label: bool = false,
    link_destination: bool = false,
};

pub const Span = struct {
    text: []const u8,
    source: SourceRange,
    marks: Marks = .{},
    /// Hidden syntax keeps exact authored ownership but supplies no semantic text.
    hidden: bool = false,
    /// Strikethrough syntax can be restored by a terminal without that attribute.
    strike_delimiter: bool = false,
    hard_break: bool = false,
    join: bool = false,
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
    hidden_line: ?SourceRange = null,
};

pub const ReviewBody = struct {
    /// Borrowed, byte-for-byte authored Review storage.
    source: []const u8,
    blocks: []const Block,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ReviewBody {
        var blocks: std.ArrayList(Block) = .empty;
        errdefer {
            for (blocks.items) |block| allocator.free(block.spans);
            blocks.deinit(allocator);
        }
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
                        errdefer allocator.free(spans);
                        spans[0] = .{ .text = source[content_start..scan], .source = .{ .start = content_start, .end = scan } };
                        try blocks.append(allocator, .{ .kind = .suggestion, .source = .{ .start = start, .end = candidate.next }, .spans = spans });
                        pos = candidate.next;
                        break;
                    }
                    scan = candidate.next;
                }
                if (scan >= source.len) {
                    const spans = try allocator.alloc(Span, 1);
                    errdefer allocator.free(spans);
                    spans[0] = .{ .text = source[start..], .source = .{ .start = start, .end = source.len } };
                    try blocks.append(allocator, .{ .kind = .literal, .source = .{ .start = start, .end = source.len }, .spans = spans });
                    pos = source.len;
                }
                continue;
            }

            const heading = headingPrefix(line.text);
            if (heading) |prefix| {
                const text_start = pos + prefix.bytes;
                const spans = try parseInline(allocator, source, text_start, pos + headingEnd(line.text, prefix.bytes));
                errdefer allocator.free(spans);
                try blocks.append(allocator, .{ .kind = .{ .heading = prefix.level }, .source = .{ .start = pos, .end = line.next }, .spans = spans });
                pos = line.next;
                continue;
            }

            const start = pos;
            var end = pos + line.text.len;
            var next = line.next;
            var underline: ?SourceRange = null;
            var level: u3 = 0;
            while (next < source.len) {
                const candidate = nextLine(source, next);
                if (isBlank(candidate.text) or isSuggestionOpen(candidate.text) or headingPrefix(candidate.text) != null) break;
                if (setextLevel(candidate.text)) |heading_level| {
                    level = heading_level;
                    underline = .{ .start = next, .end = candidate.next };
                    next = candidate.next;
                    break;
                }
                end = next + candidate.text.len;
                next = candidate.next;
            }
            const spans = try parseInline(allocator, source, start, end);
            errdefer allocator.free(spans);
            try blocks.append(allocator, .{ .kind = if (level == 0) .paragraph else .{ .heading = level }, .source = .{ .start = start, .end = end }, .spans = spans, .hidden_line = underline });
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

const HeadingPrefix = struct { level: u3, bytes: usize };
fn headingPrefix(line: []const u8) ?HeadingPrefix {
    var indent: usize = 0;
    while (indent < line.len and indent < 3 and line[indent] == ' ') indent += 1;
    var bytes = indent;
    while (bytes < line.len and bytes - indent < 6 and line[bytes] == '#') bytes += 1;
    const count = bytes - indent;
    if (count == 0 or (bytes < line.len and line[bytes] != ' ' and line[bytes] != '\t')) return null;
    while (bytes < line.len and (line[bytes] == ' ' or line[bytes] == '\t')) bytes += 1;
    return .{ .level = @intCast(count), .bytes = bytes };
}

fn headingEnd(line: []const u8, start: usize) usize {
    var end = line.len;
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    var hashes = end;
    while (hashes > start and line[hashes - 1] == '#') hashes -= 1;
    if (hashes < end and (hashes == start or line[hashes - 1] == ' ' or line[hashes - 1] == '\t')) {
        end = hashes;
        while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    }
    return end;
}

fn setextLevel(line: []const u8) ?u3 {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') indent += 1;
    if (indent > 3 or (indent < line.len and line[indent] == '\t')) return null;
    const text = trimmed(line[indent..]);
    if (text.len == 0 or (text[0] != '=' and text[0] != '-')) return null;
    for (text) |byte| if (byte != text[0]) return null;
    return if (text[0] == '=') 1 else 2;
}

fn appendSpan(list: *std.ArrayList(Span), allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, marks: Marks) !void {
    if (end <= start) return;
    var pos = start;
    while (pos < end) {
        const newline = std.mem.indexOfScalarPos(u8, source[0..end], pos, '\n') orelse end;
        const content_end = if (newline > pos and source[newline - 1] == '\r') newline - 1 else newline;
        const hard = !marks.inline_code and newline < end and content_end >= pos + 2 and std.mem.endsWith(u8, source[pos..content_end], "  ");
        const text_end = if (hard) content_end - 2 else content_end;
        if (text_end > pos) try list.append(allocator, .{ .text = source[pos..text_end], .source = .{ .start = pos, .end = text_end }, .marks = marks });
        if (newline < end) try list.append(allocator, .{ .text = if (hard or marks.inline_code) "" else " ", .source = .{ .start = text_end, .end = newline + 1 }, .marks = marks, .hard_break = hard or marks.inline_code, .join = !hard and !marks.inline_code });
        pos = if (newline < end) newline + 1 else end;
    }
}

fn parseInline(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize) ![]const Span {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    var delimiters: std.ArrayList(Delimiter) = .empty;
    defer delimiters.deinit(allocator);
    var pos = start;
    var plain = start;
    while (pos < end) {
        if (source[pos] == '\\' and pos + 1 < end and isEscapable(source[pos + 1])) {
            try appendSpan(&spans, allocator, source, plain, pos, .{});
            try appendHidden(&spans, allocator, pos, pos + 1, false);
            try appendSpan(&spans, allocator, source, pos + 1, pos + 2, .{});
            pos += 2;
            plain = pos;
            continue;
        }
        if (source[pos] == '[') if (labelClose(source, pos + 1, end)) |close_label| {
            if (close_label + 1 < end and source[close_label + 1] == '(') if (std.mem.indexOfScalarPos(u8, source[0..end], close_label + 2, ')')) |close_dest| {
                try appendSpan(&spans, allocator, source, plain, pos, .{});
                try appendHidden(&spans, allocator, pos, pos + 1, false);
                const label = try parseInline(allocator, source, pos + 1, close_label);
                defer allocator.free(label);
                for (label) |span| {
                    var marked = span;
                    marked.marks.link_label = true;
                    try spans.append(allocator, marked);
                }
                try appendHidden(&spans, allocator, close_label, close_label + 2, false);
                try appendSpan(&spans, allocator, source, close_label + 2, close_dest, .{ .link_destination = true });
                try appendHidden(&spans, allocator, close_dest, close_dest + 1, false);
                pos = close_dest + 1;
                plain = pos;
                continue;
            };
        };
        if (source[pos] == '`') {
            const length = runLength(source, pos, end);
            if (codeClose(source, pos + length, end, length)) |close| {
                try appendSpan(&spans, allocator, source, plain, pos, .{});
                try appendHidden(&spans, allocator, pos, pos + length, false);
                try appendSpan(&spans, allocator, source, pos + length, close, .{ .inline_code = true });
                try appendHidden(&spans, allocator, close, close + length, false);
                pos = close + length;
                plain = pos;
                continue;
            }
            pos += length;
            continue;
        }
        // HTML stays authored text, including punctuation inside its tags.
        if (source[pos] == '<') if (std.mem.indexOfScalarPos(u8, source[0..end], pos + 1, '>')) |close| {
            pos = close + 1;
            continue;
        };
        if (source[pos] == '*' or source[pos] == '_' or source[pos] == '~') {
            const length = runLength(source, pos, end);
            const before: u8 = if (pos > start) source[pos - 1] else ' ';
            const after: u8 = if (pos + length < end) source[pos + length] else ' ';
            const left = !std.ascii.isWhitespace(after) and (!std.ascii.isPunctuation(after) or std.ascii.isWhitespace(before) or std.ascii.isPunctuation(before));
            const right = !std.ascii.isWhitespace(before) and (!std.ascii.isPunctuation(before) or std.ascii.isWhitespace(after) or std.ascii.isPunctuation(after));
            try appendSpan(&spans, allocator, source, plain, pos, .{});
            try delimiters.append(allocator, .{
                .index = spans.items.len,
                .byte = source[pos],
                .length = length,
                .open = left and (source[pos] != '_' or !right or std.ascii.isPunctuation(before)),
                .close = right and (source[pos] != '_' or !left or std.ascii.isPunctuation(after)),
            });
            try appendSpan(&spans, allocator, source, pos, pos + length, .{});
            pos += length;
            plain = pos;
            continue;
        }
        pos += 1;
    }
    try appendSpan(&spans, allocator, source, plain, end, .{});
    for (delimiters.items, 0..) |*closer, close_index| {
        while (closer.close and closer.remaining() >= closer.minimum()) {
            var open_index = close_index;
            var matched = false;
            while (open_index > 0) {
                open_index -= 1;
                const opener = &delimiters.items[open_index];
                if (!opener.open or opener.byte != closer.byte or opener.remaining() < opener.minimum()) continue;
                if (opener.byte == '~' and (opener.length != 2 or closer.length != 2)) continue;
                if (opener.byte != '~' and (opener.close or closer.open) and (opener.remaining() + closer.remaining()) % 3 == 0 and (opener.remaining() % 3 != 0 or closer.remaining() % 3 != 0)) continue;
                const used: usize = if (opener.remaining() >= 2 and closer.remaining() >= 2) 2 else 1;
                opener.hidden_end += used;
                closer.hidden_start += used;
                for (spans.items[opener.index + 1 .. closer.index]) |*span| {
                    if (opener.byte == '~') span.marks.strikethrough = true else if (used == 2) span.marks.strong = true else span.marks.emphasis = true;
                }
                // A paired closer cannot also open a crossing construct.
                for (delimiters.items[open_index + 1 .. close_index]) |*inner| inner.open = false;
                matched = true;
                break;
            }
            if (!matched) break;
        }
    }
    var result: std.ArrayList(Span) = .empty;
    errdefer result.deinit(allocator);
    var delimiter_index: usize = 0;
    for (spans.items, 0..) |span, index| {
        if (delimiter_index < delimiters.items.len and delimiters.items[delimiter_index].index == index) {
            const delimiter = delimiters.items[delimiter_index];
            const visible_start = span.source.start + delimiter.hidden_start;
            const visible_end = span.source.end - delimiter.hidden_end;
            try appendHidden(&result, allocator, span.source.start, visible_start, delimiter.byte == '~');
            try appendSpan(&result, allocator, source, visible_start, visible_end, span.marks);
            try appendHidden(&result, allocator, visible_end, span.source.end, delimiter.byte == '~');
            delimiter_index += 1;
        } else try result.append(allocator, span);
    }
    return result.toOwnedSlice(allocator);
}

const Delimiter = struct {
    index: usize,
    byte: u8,
    length: usize,
    open: bool,
    close: bool,
    hidden_start: usize = 0,
    hidden_end: usize = 0,

    fn remaining(self: Delimiter) usize {
        return self.length - self.hidden_start - self.hidden_end;
    }
    fn minimum(self: Delimiter) usize {
        return if (self.byte == '~') 2 else 1;
    }
};

fn appendHidden(spans: *std.ArrayList(Span), allocator: std.mem.Allocator, start: usize, end: usize, strike: bool) !void {
    if (start == end) return;
    try spans.append(allocator, .{ .text = "", .source = .{ .start = start, .end = end }, .hidden = true, .strike_delimiter = strike });
}

fn runLength(source: []const u8, start: usize, end: usize) usize {
    var pos = start;
    while (pos < end and source[pos] == source[start]) : (pos += 1) {}
    return pos - start;
}

fn codeClose(source: []const u8, start: usize, end: usize, length: usize) ?usize {
    var pos = start;
    while (pos < end) {
        if (source[pos] == '`') {
            const run = runLength(source, pos, end);
            if (run == length) return pos;
            pos += run;
        } else pos += 1;
    }
    return null;
}

fn labelClose(source: []const u8, start: usize, end: usize) ?usize {
    var pos = start;
    var depth: usize = 0;
    while (pos < end) {
        if (source[pos] == '\\' and pos + 1 < end and isEscapable(source[pos + 1])) {
            pos += 2;
            continue;
        }
        if (source[pos] == '`') {
            const length = runLength(source, pos, end);
            if (codeClose(source, pos + length, end, length)) |close| {
                pos = close + length;
                continue;
            }
        }
        if (source[pos] == '[') depth += 1;
        if (source[pos] == ']') {
            if (depth == 0) return pos;
            depth -= 1;
        }
        pos += 1;
    }
    return null;
}

fn isEscapable(byte: u8) bool {
    return std.ascii.isPunctuation(byte);
}

const testing = std.testing;

test "M23 inline emphasis respects delimiter runs, escapes, and intraword underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const examples = [_]struct { authored: []const u8, visible: []const u8, combined: []const u8 = "" }{
        .{ .authored = "snake_case_name __bold__ _italic_", .visible = "snake_case_name bold italic" },
        .{ .authored = "*outer **both** end*", .visible = "outer both end", .combined = "both" },
        .{ .authored = "**outer *both* end**", .visible = "outer both end", .combined = "both" },
        .{ .authored = "***both***", .visible = "both", .combined = "both" },
        .{ .authored = "\\*literal\\* **valid** *broken", .visible = "*literal* valid *broken" },
        .{ .authored = "* spaced * and a_b_c", .visible = "* spaced * and a_b_c" },
        .{ .authored = "\\:mask: <tag> &amp; ABC-123 {color:red}", .visible = ":mask: <tag> &amp; ABC-123 {color:red}" },
        .{ .authored = "[**a\\]b**](url)", .visible = "a]burl" },
        .{ .authored = "[`a]b`](url)", .visible = "a]burl" },
    };
    for (examples) |example| {
        const body = try ReviewBody.parse(a, example.authored);
        var visible: std.ArrayList(u8) = .empty;
        var combined = example.combined.len == 0;
        for (body.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.text, example.combined) and span.marks.strong and span.marks.emphasis) combined = true;
        };
        try testing.expectEqualStrings(example.visible, visible.items);
        try testing.expect(combined);
        try testing.expectEqualStrings(example.authored, body.source);
    }
}

test "M23 inline code and styled links keep literal text and complete authored ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "**_~~[`  *literal* <b> &amp; :mask:  `](https://x)~~_**";
    const body = try ReviewBody.parse(a, source);
    var visible: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    var saw_code = false;
    for (body.blocks[0].spans) |span| {
        try testing.expectEqual(offset, span.source.start);
        offset = span.source.end;
        try visible.appendSlice(a, span.text);
        if (span.marks.inline_code) {
            try testing.expect(span.marks.strong and span.marks.emphasis and span.marks.strikethrough and span.marks.link_label);
            try testing.expectEqualStrings("  *literal* <b> &amp; :mask:  ", span.text);
            saw_code = true;
        }
    }
    try testing.expectEqual(source.len, offset);
    try testing.expect(saw_code);
    try testing.expectEqualStrings("  *literal* <b> &amp; :mask:  https://x", visible.items);
    const malformed = try ReviewBody.parse(a, "``with `tick` inside`` **valid** `unclosed");
    var text: std.ArrayList(u8) = .empty;
    for (malformed.blocks[0].spans) |span| try text.appendSlice(a, span.text);
    try testing.expectEqualStrings("with `tick` inside valid `unclosed", text.items);
}

test "M23 inline parsing releases partial bodies after allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const body = try ReviewBody.parse(allocator, "# *Heading* ##\n\nSetext\n=====\n\nfirst\r\nsecond  \nthird\n\n**_~~[`literal`](url)~~_**\n\n```suggestion\ncode\n```\n\n```suggestion\nunclosed");
            defer {
                for (body.blocks) |block| allocator.free(block.spans);
                allocator.free(body.blocks);
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}

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

test "M23 inline unclosed Suggestion keeps earlier formatting and local literal content" {
    const source = "**before**\n```suggestion\n**still literal**";
    const body = try ReviewBody.parse(testing.allocator, source);
    defer {
        for (body.blocks) |block| testing.allocator.free(block.spans);
        testing.allocator.free(body.blocks);
    }
    try testing.expectEqual(@as(usize, 2), body.blocks.len);
    try testing.expect(body.blocks[0].kind == .paragraph);
    try testing.expect(body.blocks[0].spans[1].marks.strong);
    try testing.expect(body.blocks[1].kind == .literal);
    try testing.expectEqualStrings("```suggestion\n**still literal**", body.blocks[1].spans[0].text);
}
