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
    link_title: bool = false,
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
    generated: bool = false,
    boundary: bool = false,
    destination_brackets: bool = true,
    /// Reference text retains definition bytes apart from visible-use coordinates.
    definition_source: ?SourceRange = null,
    required_definition: ?SourceRange = null,
};

pub const BlockKind = union(enum) {
    paragraph,
    heading: u3,
    suggestion,
    code,
    literal,
    spacer,
};

pub const Block = struct {
    kind: BlockKind,
    source: SourceRange,
    spans: []const Span = &.{},
    hidden_line: ?SourceRange = null,
    fences: ?[2]SourceRange = null,
    quotes: usize = 0,
    indent: usize = 0,
    outer_indent: usize = 0,
    quote_path: []const u8 = "",
    marker: ?ListMarker = null,
};

pub const ListMarker = union(enum) { bullet, number: usize };

pub const ReviewBody = struct {
    /// Borrowed, byte-for-byte authored Review storage.
    source: []const u8,
    blocks: []const Block,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ReviewBody {
        const first = try parseBlocks(allocator, source, &.{});
        var definitions: std.ArrayList(Definition) = .empty;
        defer definitions.deinit(allocator);
        errdefer freeBlocks(allocator, first.blocks);
        for (first.blocks) |block| {
            if (block.kind != .literal or block.spans.len != 1) continue;
            const span = block.spans[0];
            const line = nextLine(source, span.source.start);
            if (readDefinition(source, span.source.start, span.source.start + line.text.len)) |definition| {
                var value = definition;
                value.line = block.source;
                try definitions.append(allocator, value);
            }
        }
        if (definitions.items.len == 0) return first;
        var references: ReferenceDefinitions = .{ .items = definitions.items };
        defer references.index.deinit(allocator);
        for (references.items, 0..) |definition, ordinal| {
            const entry = try references.index.getOrPut(allocator, definition.name);
            if (!entry.found_existing) entry.value_ptr.* = ordinal;
        }
        const resolved = try parseBlocks(allocator, source, &references);
        freeBlocks(allocator, first.blocks);
        return resolved;
    }

    fn parseBlocks(allocator: std.mem.Allocator, source: []const u8, references: *const ReferenceDefinitions) !ReviewBody {
        var blocks: std.ArrayList(Block) = .empty;
        errdefer {
            for (blocks.items) |block| allocator.free(block.spans);
            blocks.deinit(allocator);
        }
        var pos: usize = 0;
        var pending_spacer: ?SourceRange = null;
        var spacer_quotes: usize = 0;
        var spacer_outer_indent: usize = 0;
        var spacer_quote_path: []const u8 = "";
        var containers: Containers = .{};
        defer containers.lists.deinit(allocator);
        while (pos < source.len) {
            const line = nextLine(source, pos);
            const context = containers.quoteContext(line.text);
            const quote = context.prefix;
            if (isBlank(line.text[quote.bytes..])) {
                if (quote.levels > 0 and blocks.items.len == 0) {
                    try blocks.append(allocator, .{ .kind = .paragraph, .source = .{ .start = pos, .end = line.next }, .quotes = quote.levels, .quote_path = line.text[0..quote.bytes] });
                    pos = line.next;
                    continue;
                }
                if (pending_spacer == null) {
                    spacer_quotes = quote.levels;
                    spacer_quote_path = line.text[0..quote.bytes];
                    const base = context.leading_spaces / 4;
                    spacer_outer_indent = if (base > 0) (base - 1) * 2 + markerWidth(containers.lists.items[base - 1]) else 0;
                }
                if (pending_spacer) |*range| range.end = line.next else pending_spacer = .{ .start = pos, .end = line.next };
                pos = line.next;
                continue;
            }
            const after_blank = pending_spacer != null;
            if (blocks.items.len > 0) if (pending_spacer) |range| {
                try blocks.append(allocator, .{ .kind = .spacer, .source = range, .quotes = spacer_quotes, .outer_indent = spacer_outer_indent, .quote_path = spacer_quote_path });
            };
            pending_spacer = null;

            if (try containers.read(allocator, line.text, after_blank or blocks.items.len == 0)) |container| {
                const block = try containerBlock(allocator, source, pos, container, references);
                errdefer allocator.free(block.spans);
                try blocks.append(allocator, block);
                pos = block.source.end;
                continue;
            }

            if (fenceOpen(line.text)) |fence| {
                const start = pos;
                const content_start = line.next;
                var scan = line.next;
                while (scan < source.len) {
                    const candidate = nextLine(source, scan);
                    if (fence.closes(candidate.text)) {
                        const spans = try codeSpans(allocator, source, content_start, scan, fence.indent);
                        errdefer allocator.free(spans);
                        try blocks.append(allocator, .{ .kind = if (fence.suggestion) .suggestion else .code, .source = .{ .start = start, .end = candidate.next }, .spans = spans, .fences = .{ .{ .start = start, .end = content_start }, .{ .start = scan, .end = candidate.next } } });
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

            if (codeIndent(line.text) != null) {
                const start = pos;
                var end = line.next;
                var scan = line.next;
                while (scan < source.len) {
                    const candidate = nextLine(source, scan);
                    if (!isBlank(candidate.text) and codeIndent(candidate.text) == null) break;
                    if (!isBlank(candidate.text)) end = candidate.next;
                    scan = candidate.next;
                }
                const spans = try codeSpans(allocator, source, start, end, null);
                errdefer allocator.free(spans);
                try blocks.append(allocator, .{ .kind = .code, .source = .{ .start = start, .end = end }, .spans = spans });
                pos = end;
                continue;
            }

            if (readDefinition(source, pos, pos + line.text.len) != null) {
                const spans = try allocator.alloc(Span, 1);
                errdefer allocator.free(spans);
                spans[0] = .{ .text = line.text, .source = .{ .start = pos, .end = pos + line.text.len } };
                try blocks.append(allocator, .{ .kind = .literal, .source = .{ .start = pos, .end = line.next }, .spans = spans });
                pos = line.next;
                continue;
            }
            const heading = headingPrefix(line.text);
            if (heading) |prefix| {
                const text_start = pos + prefix.bytes;
                const spans = try parseInline(allocator, source, text_start, pos + headingEnd(line.text, prefix.bytes), .{ .references = references });
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
                if (quotePrefix(candidate.text).levels > 0) break;
                if (isBlank(candidate.text) or fenceOpen(candidate.text) != null or headingPrefix(candidate.text) != null or readDefinition(source, next, next + candidate.text.len) != null) break;
                if (setextLevel(candidate.text)) |heading_level| {
                    level = heading_level;
                    underline = .{ .start = next, .end = candidate.next };
                    next = candidate.next;
                    break;
                }
                end = next + candidate.text.len;
                next = candidate.next;
            }
            const spans = try parseInline(allocator, source, start, end, .{ .references = references });
            errdefer allocator.free(spans);
            try blocks.append(allocator, .{ .kind = if (level == 0) .paragraph else .{ .heading = level }, .source = .{ .start = start, .end = end }, .spans = spans, .hidden_line = underline });
            pos = next;
        }
        var kept: usize = 0;
        for (blocks.items) |block| {
            var used = false;
            if (block.kind == .literal and block.spans.len == 1) {
                const span = block.spans[0];
                if (readDefinition(source, span.source.start, span.source.end)) |value| if (references.find(value.name)) |definition| {
                    used = definition.used and definition.line.start == block.source.start;
                };
            }
            if (used) allocator.free(block.spans) else {
                blocks.items[kept] = block;
                kept += 1;
            }
        }
        blocks.items.len = kept;
        return .{ .source = source, .blocks = try blocks.toOwnedSlice(allocator) };
    }
};

fn freeBlocks(allocator: std.mem.Allocator, blocks: []const Block) void {
    for (blocks) |block| allocator.free(block.spans);
    allocator.free(blocks);
}

const Line = struct { text: []const u8, next: usize };

const QuotePrefix = struct { bytes: usize = 0, levels: usize = 0 };

fn quotePrefix(text: []const u8) QuotePrefix {
    var result: QuotePrefix = .{};
    while (result.bytes < text.len and text[result.bytes] == '>') {
        result.bytes += 1;
        result.levels += 1;
        if (result.bytes < text.len and text[result.bytes] == ' ') result.bytes += 1;
    }
    return result;
}

const ItemPrefix = struct { bytes: usize, spaces: usize, marker: ListMarker };

fn itemPrefix(text: []const u8) ?ItemPrefix {
    var spaces: usize = 0;
    while (spaces < text.len and text[spaces] == ' ') spaces += 1;
    if (spaces % 4 != 0 or spaces == text.len) return null;
    var end = spaces;
    var marker: ListMarker = .bullet;
    if (text[end] == '-' or text[end] == '*' or text[end] == '+') {
        end += 1;
    } else {
        while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
        if (end == spaces or end >= text.len or text[end] != '.') return null;
        marker = .{ .number = std.fmt.parseInt(usize, text[spaces..end], 10) catch return null };
        end += 1;
    }
    if (end >= text.len or text[end] != ' ') return null;
    return .{ .bytes = end + 1, .spaces = spaces, .marker = marker };
}

const Container = struct {
    quotes: usize,
    bytes: usize,
    continuation: usize,
    indent: usize,
    outer_indent: usize = 0,
    quote_path: []const u8 = "",
    marker: ?ListMarker = null,

    fn strip(self: Container, text: []const u8) ?usize {
        const prefix_bytes = self.structural(text) orelse return null;
        var removed: usize = 0;
        while (removed < self.continuation and prefix_bytes + removed < text.len and text[prefix_bytes + removed] == ' ') removed += 1;
        if (removed < self.continuation and !isBlank(text[prefix_bytes..])) return null;
        return prefix_bytes + removed;
    }

    fn structural(self: Container, text: []const u8) ?usize {
        var pos: usize = 0;
        var expected: usize = 0;
        while (expected < self.quote_path.len) {
            if (pos >= text.len or text[pos] != self.quote_path[expected]) return null;
            const quote = self.quote_path[expected] == '>';
            pos += 1;
            expected += 1;
            if (quote) {
                if (pos < text.len and text[pos] == ' ') pos += 1;
                if (expected < self.quote_path.len and self.quote_path[expected] == ' ') expected += 1;
            }
        }
        return pos;
    }
};

const Containers = struct {
    lists: std.ArrayList(ListMarker) = .empty,
    quotes: usize = 0,
    quote_base: usize = 0,

    fn quoteContext(self: Containers, text: []const u8) struct { prefix: QuotePrefix = .{}, base: usize = 0, leading_spaces: usize = 0 } {
        var pos: usize = 0;
        while (pos < text.len and text[pos] == ' ') pos += 1;
        const leading = pos;
        if (pos == text.len or text[pos] != '>' or leading % 4 != 0 or leading / 4 > self.lists.items.len) return .{};
        var base = leading / 4;
        var levels: usize = 0;
        while (pos < text.len and text[pos] == '>') {
            pos += 1;
            levels += 1;
            if (pos < text.len and text[pos] == ' ') pos += 1;
            var next = pos;
            while (next < text.len and text[next] == ' ') next += 1;
            const spaces = next - pos;
            if (next == text.len or text[next] != '>' or spaces % 4 != 0 or base + spaces / 4 > self.lists.items.len) break;
            base += spaces / 4;
            pos = next;
        }
        return .{ .prefix = .{ .bytes = pos, .levels = levels }, .base = base, .leading_spaces = leading };
    }

    fn read(self: *Containers, allocator: std.mem.Allocator, text: []const u8, boundary: bool) !?Container {
        const context = self.quoteContext(text);
        const quote_indent = context.leading_spaces;
        const quote = context.prefix;
        const base = context.base;
        const changed_quote = quote.levels != self.quotes or base != self.quote_base;
        if (changed_quote) self.lists.items.len = @min(self.lists.items.len, @max(base, @min(self.quote_base, self.lists.items.len)));
        self.quotes = quote.levels;
        self.quote_base = base;
        const leading_base = quote_indent / 4;
        const outer_indent = if (leading_base > 0) (leading_base - 1) * 2 + markerWidth(self.lists.items[leading_base - 1]) else 0;
        const structural = quote.bytes;
        const rest = text[structural..];
        if (itemPrefix(rest)) |item| {
            const level = base + item.spaces / 4;
            const sibling = level < self.lists.items.len;
            const same_type = sibling and ((item.marker == .bullet) == (self.lists.items[level] == .bullet));
            if (level <= self.lists.items.len and (level > base or boundary or sibling or changed_quote) and (!sibling or same_type or boundary)) {
                var marker = item.marker;
                if (same_type and marker == .number) marker = .{ .number = self.lists.items[level].number +| 1 };
                self.lists.items.len = @min(level, self.lists.items.len);
                try self.lists.append(allocator, marker);
                return .{ .quotes = quote.levels, .bytes = structural + item.bytes, .continuation = (level - base + 1) * 4, .indent = (level - base) * 2, .marker = marker, .outer_indent = outer_indent, .quote_path = text[0..structural] };
            }
        }
        var spaces: usize = 0;
        while (spaces < rest.len and rest[spaces] == ' ') spaces += 1;
        while (self.lists.items.len > base and spaces < (self.lists.items.len - base) * 4) self.lists.items.len -= 1;
        if (self.lists.items.len > base) {
            const level = self.lists.items.len - 1;
            const marker = self.lists.items[level];
            return .{ .quotes = quote.levels, .bytes = structural + (self.lists.items.len - base) * 4, .continuation = (self.lists.items.len - base) * 4, .indent = (level - base) * 2 + markerWidth(marker), .outer_indent = outer_indent, .quote_path = text[0..structural] };
        }
        if (quote.levels > 0) return .{ .quotes = quote.levels, .bytes = structural, .continuation = 0, .indent = 0, .outer_indent = outer_indent, .quote_path = text[0..structural] };
        return null;
    }
};

pub fn markerWidth(marker: ListMarker) usize {
    if (marker == .bullet) return 2;
    var number = marker.number;
    var digits: usize = 1;
    while (number >= 10) : (number /= 10) digits += 1;
    return digits + 2;
}

fn containerBlock(allocator: std.mem.Allocator, source: []const u8, start: usize, container: Container, references: *const ReferenceDefinitions) !Block {
    const first = nextLine(source, start);
    const text = first.text[container.bytes..];
    var result: Block = .{ .kind = .paragraph, .source = .{ .start = start, .end = first.next }, .quotes = container.quotes, .indent = container.indent, .outer_indent = container.outer_indent, .quote_path = container.quote_path, .marker = container.marker };
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);
    if (readDefinition(source, start + container.bytes, start + first.text.len) != null) {
        result.kind = .literal;
        try spans.append(allocator, .{ .text = text, .source = .{ .start = start + container.bytes, .end = start + first.text.len } });
        result.spans = try spans.toOwnedSlice(allocator);
        return result;
    }
    const fence = fenceOpen(text);
    const indented = codeIndent(text) != null;
    if (fence != null or indented) {
        var pos = if (fence != null) first.next else start;
        var found_close = false;
        while (pos < source.len) {
            const line = nextLine(source, pos);
            const removed = if (pos == start) container.bytes else container.strip(line.text) orelse break;
            const content = line.text[removed..];
            if (fence) |opening| {
                if (opening.closes(content)) {
                    result.fences = .{ .{ .start = start, .end = first.next }, .{ .start = pos, .end = line.next } };
                    result.source.end = line.next;
                    found_close = true;
                    break;
                }
            } else if (!isBlank(content) and codeIndent(content) == null) break;
            var code_removed: usize = 0;
            if (fence) |opening| {
                while (code_removed < content.len and code_removed < opening.indent and content[code_removed] == ' ') code_removed += 1;
            } else code_removed = codeIndent(content) orelse content.len;
            try spans.append(allocator, .{ .text = source[pos + removed + code_removed .. line.next], .source = .{ .start = pos + removed + code_removed, .end = line.next } });
            if (fence != null or !isBlank(content)) result.source.end = line.next;
            pos = line.next;
        }
        if (fence == null or found_close) {
            while (spans.items.len > 0 and spans.items[spans.items.len - 1].source.end > result.source.end) spans.items.len -= 1;
            result.kind = if (fence != null and fence.?.suggestion) .suggestion else .code;
            result.spans = try spans.toOwnedSlice(allocator);
            return result;
        }
        // An unclosed container fence stays local and literal.
        spans.items.len = 0;
        result.kind = .literal;
        var literal_pos = start;
        while (literal_pos < result.source.end) {
            const line = nextLine(source, literal_pos);
            const removed = if (literal_pos == start) container.bytes else container.strip(line.text).?;
            try spans.append(allocator, .{ .text = source[literal_pos + removed .. line.next], .source = .{ .start = literal_pos + removed, .end = line.next } });
            literal_pos = line.next;
        }
        result.spans = try spans.toOwnedSlice(allocator);
        return result;
    }
    var prefixes: std.ArrayList(SourceRange) = .empty;
    defer prefixes.deinit(allocator);
    const heading = headingPrefix(text);
    if (heading) |prefix| result.kind = .{ .heading = prefix.level };
    const inline_start = start + container.bytes + if (heading) |prefix| prefix.bytes else @as(usize, 0);
    var inline_end = inline_start;
    var pos = start;
    while (pos < source.len) {
        const line = nextLine(source, pos);
        const removed = if (pos == start) container.bytes else container.strip(line.text) orelse break;
        const content = line.text[removed..];
        if (pos != start) {
            if (setextLevel(content)) |level| {
                result.kind = .{ .heading = level };
                result.hidden_line = .{ .start = pos, .end = line.next };
                result.source.end = line.next;
                break;
            }
            if (isBlank(content) or itemPrefix(line.text[container.structural(line.text).?..]) != null or quotePrefix(content).levels > 0 or fenceOpen(content) != null or codeIndent(content) != null or headingPrefix(content) != null or readDefinition(source, pos + removed, pos + line.text.len) != null) break;
            try prefixes.append(allocator, .{ .start = pos, .end = pos + removed });
        }
        inline_end = pos + removed + if (heading) |prefix| headingEnd(content, prefix.bytes) else content.len;
        result.source.end = line.next;
        pos = line.next;
        if (heading != null) break;
    }
    const inline_spans = try parseInline(allocator, source, inline_start, inline_end, .{ .references = references });
    defer allocator.free(inline_spans);
    var prefix_index: usize = 0;
    for (inline_spans) |span| {
        var visible = span;
        while (prefix_index < prefixes.items.len and prefixes.items[prefix_index].end <= span.source.start) prefix_index += 1;
        if (!span.hidden and !span.join and !span.hard_break and prefix_index < prefixes.items.len) {
            const prefix = prefixes.items[prefix_index];
            if (span.source.start >= prefix.start and span.source.start < prefix.end) {
                const removed = @min(prefix.end, span.source.end) - span.source.start;
                visible.text = visible.text[removed..];
                visible.source.start += removed;
            }
        }
        if (visible.hidden or visible.join or visible.hard_break or visible.text.len > 0) try spans.append(allocator, visible);
    }
    result.spans = try spans.toOwnedSlice(allocator);
    return result;
}

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

const Fence = struct {
    character: u8,
    length: usize,
    indent: usize,
    suggestion: bool,

    fn closes(self: Fence, line: []const u8) bool {
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent > 3 or indent == line.len or line[indent] != self.character) return false;
        const length = runLength(line, indent, line.len);
        return length >= self.length and isBlank(line[indent + length ..]);
    }
};

fn fenceOpen(line: []const u8) ?Fence {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') indent += 1;
    if (indent > 3 or indent == line.len or (line[indent] != '`' and line[indent] != '~')) return null;
    const length = runLength(line, indent, line.len);
    if (length < 3) return null;
    const info = trimmed(line[indent + length ..]);
    if (line[indent] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .character = line[indent], .length = length, .indent = indent, .suggestion = std.mem.eql(u8, info, "suggestion") };
}

fn codeIndent(line: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < line.len and pos < 4) : (pos += 1) {
        if (line[pos] == '\t') return pos + 1;
        if (line[pos] != ' ') return null;
    }
    return if (pos == 4) pos else null;
}

fn codeSpans(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, fence_indent: ?usize) ![]const Span {
    if (fence_indent == 0) {
        const spans = try allocator.alloc(Span, 1);
        spans[0] = .{ .text = source[start..end], .source = .{ .start = start, .end = end } };
        return spans;
    }
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);
    var pos = start;
    while (pos < end) {
        const line = nextLine(source, pos);
        var removed: usize = 0;
        if (fence_indent) |indent| {
            while (removed < line.text.len and removed < indent and line.text[removed] == ' ') removed += 1;
        } else removed = codeIndent(line.text) orelse line.text.len;
        try spans.append(allocator, .{ .text = source[pos + removed .. line.next], .source = .{ .start = pos + removed, .end = line.next } });
        pos = line.next;
    }
    return spans.toOwnedSlice(allocator);
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

const InlineContext = struct { references: *const ReferenceDefinitions = &.{}, links: bool = true };

fn parseInline(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, context: InlineContext) ![]const Span {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    var delimiters: std.ArrayList(Delimiter) = .empty;
    defer delimiters.deinit(allocator);
    var url_delimiters = [_]usize{ 0, 0, 0 };
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
        const image = source[pos] == '!' and pos + 1 < end and source[pos + 1] == '[';
        const label_start = pos + @intFromBool(image);
        if (context.links and source[label_start] == '[') if (labelClose(source, label_start + 1, end)) |close_label| {
            const explicit = close_label + 1 < end and source[close_label + 1] == '(';
            if (if (explicit) readDestination(source, close_label + 2, end, true) else readReference(source, label_start + 1, close_label, end, context.references)) |link| {
                try appendSpan(&spans, allocator, source, plain, pos, .{});
                try appendHidden(&spans, allocator, pos, label_start + 1, false);
                spans.items[spans.items.len - 1].boundary = true;
                if (image) try spans.append(allocator, .{ .text = "image: ", .source = .{ .start = pos, .end = pos }, .generated = true });
                const label = try parseInline(allocator, source, label_start + 1, close_label, .{ .links = false });
                defer allocator.free(label);
                for (label) |span| {
                    var marked = span;
                    marked.marks.link_label = true;
                    try spans.append(allocator, marked);
                }
                try appendHidden(&spans, allocator, close_label, if (explicit) close_label + 2 else link.next, false);
                spans.items[spans.items.len - 1].boundary = true;
                const navigation = SourceRange{ .start = close_label, .end = link.next };
                try spans.append(allocator, .{ .text = source[link.destination.start..link.destination.end], .source = if (explicit) link.destination else navigation, .marks = .{ .link_destination = true }, .definition_source = if (explicit) null else link.destination, .required_definition = link.definition });
                if (link.title) |title| try spans.append(allocator, .{ .text = source[title.start..title.end], .source = if (explicit) title else navigation, .marks = .{ .link_title = true }, .boundary = true, .definition_source = if (explicit) null else title, .required_definition = link.definition });
                if (explicit) try appendHidden(&spans, allocator, link.next - 1, link.next, false) else try spans.append(allocator, .{ .text = "", .source = .{ .start = link.next, .end = link.next }, .hidden = true });
                spans.items[spans.items.len - 1].boundary = true;
                pos = link.next;
                plain = pos;
                continue;
            }
            const literal_end = literalLinkEnd(source, close_label, end);
            try appendSpan(&spans, allocator, source, plain, pos, .{});
            try appendSpan(&spans, allocator, source, pos, literal_end, .{});
            pos = literal_end;
            plain = pos;
            continue;
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
        if (if (context.links) bareUrlEnd(source, pos, start, end, url_delimiters) else null) |url_end| {
            try appendSpan(&spans, allocator, source, plain, pos, .{});
            try spans.append(allocator, .{ .text = source[pos..url_end], .source = .{ .start = pos, .end = url_end }, .marks = .{ .link_destination = true }, .boundary = true, .destination_brackets = false });
            pos = url_end;
            plain = pos;
            try spans.append(allocator, .{ .text = "", .source = .{ .start = pos, .end = pos }, .hidden = true, .boundary = true });
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
            const opens = left and (source[pos] != '_' or !right or std.ascii.isPunctuation(before));
            const closes = right and (source[pos] != '_' or !left or std.ascii.isPunctuation(after));
            if (source[pos] != '~' or length == 2) {
                const index: usize = switch (source[pos]) {
                    '*' => 0,
                    '_' => 1,
                    else => 2,
                };
                const consumed = if (closes) @min(url_delimiters[index], length) else 0;
                url_delimiters[index] -= consumed;
                if (opens) url_delimiters[index] += length - consumed;
            }
            try appendSpan(&spans, allocator, source, plain, pos, .{});
            try delimiters.append(allocator, .{
                .index = spans.items.len,
                .byte = source[pos],
                .length = length,
                .open = opens,
                .close = closes,
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

const LinkDestination = struct { destination: SourceRange, title: ?SourceRange = null, next: usize, definition: ?SourceRange = null };

const Definition = struct { name: []const u8, link: LinkDestination, line: SourceRange, used: bool = false };

const ReferenceDefinitions = struct {
    items: []Definition = &.{},
    index: std.HashMapUnmanaged([]const u8, usize, NameContext, std.hash_map.default_max_load_percentage) = .empty,

    fn find(self: *const ReferenceDefinitions, name: []const u8) ?*Definition {
        return &self.items[self.index.get(name) orelse return null];
    }

    const NameContext = struct {
        pub fn hash(_: @This(), name: []const u8) u64 {
            var hasher = std.hash.Wyhash.init(0);
            const view = std.unicode.Utf8View.init(name) catch {
                hasher.update(name);
                return hasher.final();
            };
            var iterator = view.iterator();
            while (iterator.nextCodepoint()) |scalar| {
                const folded: u32 = @import("unicode_case.zig").fold(scalar);
                hasher.update(std.mem.asBytes(&folded));
            }
            return hasher.final();
        }

        pub fn eql(_: @This(), left: []const u8, right: []const u8) bool {
            return @import("unicode_case.zig").eqlIgnoreCase(left, right);
        }
    };
};

fn readDefinition(source: []const u8, start: usize, end: usize) ?Definition {
    var pos = start;
    while (pos < end and source[pos] == ' ' and pos - start < 3) pos += 1;
    if (pos == end or source[pos] != '[') return null;
    const close = labelClose(source, pos + 1, end) orelse return null;
    if (close == pos + 1 or close + 1 >= end or source[close + 1] != ':') return null;
    const link = readDestination(source, close + 2, end, false) orelse return null;
    return .{ .name = source[pos + 1 .. close], .link = link, .line = .{ .start = start, .end = end } };
}

fn readReference(source: []const u8, label_start: usize, close: usize, end: usize, references: *const ReferenceDefinitions) ?LinkDestination {
    var name = source[label_start..close];
    var next = close + 1;
    if (next < end and source[next] == '[') {
        const reference_close = labelClose(source, next + 1, end) orelse return null;
        if (reference_close > next + 1) name = source[next + 1 .. reference_close];
        next = reference_close + 1;
    }
    const definition = references.find(name) orelse return null;
    definition.used = true;
    var link = definition.link;
    link.next = next;
    link.definition = definition.line;
    return link;
}

fn literalLinkEnd(source: []const u8, close: usize, end: usize) usize {
    const next = close + 1;
    if (next == end or (source[next] != '(' and source[next] != '[')) return next;
    const closing: u8 = if (source[next] == '(') ')' else ']';
    var pos = next + 1;
    while (pos < end and source[pos] != '\n' and source[pos] != '\r') : (pos += 1) {
        if (source[pos] == closing) return pos + 1;
        if (source[pos] == '\\' and pos + 1 < end) pos += 1;
    }
    pos = next + 1;
    while (pos < end and !std.ascii.isWhitespace(source[pos])) pos += 1;
    return pos;
}

fn readDestination(source: []const u8, start: usize, end: usize, inline_link: bool) ?LinkDestination {
    var pos = start;
    while (pos < end and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
    const angle = pos < end and source[pos] == '<';
    if (angle) pos += 1;
    const destination_start = pos;
    var depth: usize = 0;
    while (pos < end) : (pos += 1) {
        const byte = source[pos];
        if (byte == '\n' or byte == '\r') return null;
        if (byte == '\\' and pos + 1 < end and isEscapable(source[pos + 1])) {
            pos += 1;
            continue;
        }
        if (angle) {
            if (byte == '>') break;
            if (byte == '<') return null;
        } else {
            if (std.ascii.isWhitespace(byte)) break;
            if (byte == '(') depth += 1;
            if (byte == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
    }
    if (depth != 0 or (angle and (pos == end or source[pos] != '>'))) return null;
    var result: LinkDestination = .{ .destination = .{ .start = destination_start, .end = pos }, .next = pos };
    if (angle) pos += 1;
    const gap_start = pos;
    while (pos < end and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
    if (pos > gap_start and pos < end and (source[pos] == '"' or source[pos] == '\'' or source[pos] == '(')) {
        const title_start = pos;
        const close: u8 = if (source[pos] == '(') ')' else source[pos];
        pos += 1;
        while (pos < end and source[pos] != close) : (pos += 1) {
            if (source[pos] == '\n' or source[pos] == '\r') return null;
            if (source[pos] == '\\' and pos + 1 < end) pos += 1;
        }
        if (pos == end) return null;
        pos += 1;
        result.title = .{ .start = title_start, .end = pos };
        while (pos < end and (source[pos] == ' ' or source[pos] == '\t')) pos += 1;
    }
    if (inline_link) {
        if (pos == end or source[pos] != ')') return null;
        pos += 1;
    } else if (pos != end or result.destination.start == result.destination.end) return null;
    result.next = pos;
    return result;
}

fn bareUrlEnd(source: []const u8, start: usize, region_start: usize, end: usize, delimiters: [3]usize) ?usize {
    if (start > region_start and !std.ascii.isWhitespace(source[start - 1]) and !std.ascii.isPunctuation(source[start - 1])) return null;
    const prefix: usize = if (std.mem.startsWith(u8, source[start..end], "https://")) 8 else if (std.mem.startsWith(u8, source[start..end], "http://")) 7 else return null;
    var pos = start + prefix;
    var balance = [_]isize{ 0, 0, 0 };
    while (pos < end and !std.ascii.isWhitespace(source[pos]) and source[pos] != '<' and source[pos] != '>' and source[pos] != '"' and source[pos] != '`') : (pos += 1) {
        switch (source[pos]) {
            '(' => balance[0] += 1,
            ')' => balance[0] -= 1,
            '[' => balance[1] += 1,
            ']' => balance[1] -= 1,
            '{' => balance[2] += 1,
            '}' => balance[2] -= 1,
            else => {},
        }
    }
    while (pos > start + prefix) {
        const last = source[pos - 1];
        if (last == '*' or last == '_' or last == '~') {
            var run_start = pos - 1;
            while (run_start > start + prefix and source[run_start - 1] == last) run_start -= 1;
            const opener = delimiters[
                switch (last) {
                    '*' => @as(usize, 0),
                    '_' => 1,
                    else => 2,
                }
            ];
            if (opener > 0) {
                pos = run_start;
                continue;
            }
        }
        if (last == ':') {
            var name_start = pos - 1;
            while (name_start > start + prefix) {
                const byte = source[name_start - 1];
                if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '+') break;
                name_start -= 1;
            }
            if (name_start < pos - 1 and name_start > start + prefix and source[name_start - 1] == ':') break;
        }
        if (last == '.' or last == ',' or last == '!' or last == '?' or last == ':' or last == ';' or last == '\'') {
            pos -= 1;
            continue;
        }
        const bracket: usize = switch (last) {
            ')' => 0,
            ']' => 1,
            '}' => 2,
            else => break,
        };
        if (balance[bracket] >= 0) break;
        balance[bracket] += 1;
        pos -= 1;
    }
    return if (pos > start + prefix) pos else null;
}

const testing = std.testing;

test "M23 links handle large definition sets and unmatched URL brackets as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var raw: std.ArrayList(u8) = .empty;
    for (0..2048) |index| try raw.print(a, "[id-{d}]: /path/{d}\n", .{ index, index });
    for (0..2048) |index| try raw.print(a, "[id-{d}] [missing-{d}]\n", .{ index, index });
    try raw.appendSlice(a, "\nhttps://x/path");
    for (0..100_000) |_| try raw.append(a, ')');
    const body = try ReviewBody.parse(a, raw.items);
    var destinations: usize = 0;
    for (body.blocks) |block| for (block.spans) |span| if (span.marks.link_destination) {
        destinations += 1;
        if (span.definition_source == null) try testing.expectEqualStrings("https://x/path", span.text);
    };
    try testing.expectEqual(@as(usize, 2049), destinations);
}

test "M23 links style URL text in labels and enclosing emphasis as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "[**https://x**](/target)", "**https://x**" }) |raw| {
        const body = try ReviewBody.parse(a, raw);
        var styled_url = false;
        for (body.blocks[0].spans) |span| if (std.mem.eql(u8, span.text, "https://x")) {
            try testing.expect(span.marks.strong);
            styled_url = true;
        };
        try testing.expect(styled_url);
        for (body.blocks[0].spans) |span| try testing.expect(std.mem.indexOf(u8, span.text, "**") == null);
    }
}

test "M23 links bare URLs keep destination shortcodes and trim unmatched punctuation as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const examples = [_]struct { raw: []const u8, destination: []const u8 }{
        .{ .raw = "https://x/:mask:", .destination = "https://x/:mask:" },
        .{ .raw = "(http://x/a_(b)).", .destination = "http://x/a_(b)" },
        .{ .raw = "https://x/a[b]]!", .destination = "https://x/a[b]" },
        .{ .raw = "https://x/a{b}},", .destination = "https://x/a{b}" },
        .{ .raw = "https://x/path: ", .destination = "https://x/path" },
        .{ .raw = "_done_ https://x/path_", .destination = "https://x/path_" },
        .{ .raw = "**done** https://x/path*", .destination = "https://x/path*" },
        .{ .raw = "~~done~~ https://x/path~", .destination = "https://x/path~" },
    };
    for (examples) |example| {
        const body = try ReviewBody.parse(a, example.raw);
        var found = false;
        for (body.blocks[0].spans) |span| if (span.marks.link_destination) {
            found = true;
            try testing.expectEqualStrings(example.destination, span.text);
        };
        try testing.expect(found);
    }
}

test "M23 links release both reference parsing passes on allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const body = try ReviewBody.parse(allocator, "[id]: /first \"Title\"\n[ID]: /duplicate\n\n> [**Docs**][ID]\n> ![art][id]\n\n[missing][none]");
            defer {
                for (body.blocks) |block| allocator.free(block.spans);
                allocator.free(body.blocks);
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}

test "M23 links resolve Unicode reference names before their uses and ignore code definitions as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[σ]: /first\n\n> [Σ][Σ]\n>\n> [inner]: /inside\n> [inner]\n\n    [code]: /hidden\n\n[code]";
    const body = try ReviewBody.parse(a, raw);
    var destinations: std.ArrayList([]const u8) = .empty;
    for (body.blocks) |block| for (block.spans) |span| if (span.marks.link_destination) try destinations.append(a, span.text);
    try testing.expectEqual(@as(usize, 2), destinations.items.len);
    try testing.expectEqualStrings("/first", destinations.items[0]);
    try testing.expectEqualStrings("/inside", destinations.items[1]);
}

test "M23 links malformed constructs and missing references stay locally literal as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "[**bad**](https://x \"unclosed)", "![*bad*](a_(b)", "[**missing**][none]", "[**missing**][unclosed" }) |raw| {
        const source = try std.fmt.allocPrint(a, "{s} **valid**", .{raw});
        const body = try ReviewBody.parse(a, source);
        var visible: std.ArrayList(u8) = .empty;
        for (body.blocks[0].spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.source.start < raw.len) try testing.expect(!span.marks.strong and !span.marks.emphasis and !span.marks.link_destination);
        }
        const expected = try std.fmt.allocPrint(a, "{s} valid", .{raw});
        try testing.expectEqualStrings(expected, visible.items);
    }
}

test "M23 links resolve body local references with first definition and literal unused definitions as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[Docs][ID]\n![art][id]\n[id][]\n[id]\n[missing][no]\n\n[id]: ../first \"Title\"\n[ID]: /duplicate\n[unused]: /other\n\n```\n[no]: /code\n```";
    const body = try ReviewBody.parse(a, raw);
    var count: usize = 0;
    var duplicate = false;
    var unused = false;
    var missing = false;
    for (body.blocks) |block| for (block.spans) |span| {
        if (span.marks.link_destination) {
            count += 1;
            try testing.expectEqualStrings("../first", span.text);
            try testing.expect(span.definition_source != null and span.required_definition != null);
            try testing.expectEqualStrings("[id]: ../first \"Title\"\n", raw[span.required_definition.?.start..span.required_definition.?.end]);
            try testing.expect(span.source.start < span.definition_source.?.start);
        }
        duplicate = duplicate or std.mem.indexOf(u8, span.text, "[ID]: /duplicate") != null;
        unused = unused or std.mem.indexOf(u8, span.text, "[unused]: /other") != null;
        missing = missing or std.mem.indexOf(u8, span.text, "[missing][no]") != null;
        try testing.expect(std.mem.indexOf(u8, span.text, "[id]: ../first") == null);
    };
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expect(duplicate and unused and missing);
}

test "M23 links parse image text titles balanced destinations and bare URL punctuation as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[**Docs**](../a_(b)/:mask: \"Guide *literal*\") ![diagram](images/a.png 'Title') https://x/a_(b)). `https://code` ABC-123";
    const body = try ReviewBody.parse(a, raw);
    var destinations: std.ArrayList([]const u8) = .empty;
    var titles: std.ArrayList([]const u8) = .empty;
    var image = false;
    for (body.blocks) |block| for (block.spans) |span| {
        if (span.marks.link_destination) try destinations.append(a, span.text);
        if (span.marks.link_title) try titles.append(a, span.text);
        if (std.mem.eql(u8, span.text, "image: ")) image = span.generated;
        if (std.mem.eql(u8, span.text, "Docs")) try testing.expect(span.marks.strong and span.marks.link_label);
    };
    try testing.expectEqual(@as(usize, 3), destinations.items.len);
    try testing.expectEqualStrings("../a_(b)/:mask:", destinations.items[0]);
    try testing.expectEqualStrings("images/a.png", destinations.items[1]);
    try testing.expectEqualStrings("https://x/a_(b)", destinations.items[2]);
    try testing.expectEqualStrings("\"Guide *literal*\"", titles.items[0]);
    try testing.expectEqualStrings("'Title'", titles.items[1]);
    try testing.expect(image);
}

test "M23 containers project mixed list nesting and quote paragraphs as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try ReviewBody.parse(a, "4. first\n    continuation\n    - child\n        8. grandchild\n1. second\n\n> quoted\n> continuation\n>> deeper\n\n1) literal");
    const expected = [_][]const u8{ "first continuation", "child", "grandchild", "second", "", "quoted continuation", "deeper", "", "1) literal" };
    try testing.expectEqual(expected.len, body.blocks.len);
    for (body.blocks, expected) |block, text| {
        var visible: std.ArrayList(u8) = .empty;
        for (block.spans) |span| try visible.appendSlice(a, span.text);
        try testing.expectEqualStrings(text, visible.items);
    }
}

test "M23 containers keep blank line rules malformed markers and code boundaries as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "prose\n- literal\n\n- item\n1. literal switch\n\n7. ordered\n2. next\n\n> - quoted\n>     ~~~zig\n>     a\tb **literal**\n>     ~~~\n>     continuation\n>\n>         indented\n>\n>     ```\n>     unfinished\n\noutside";
    const body = try ReviewBody.parse(a, raw);
    var codes: usize = 0;
    var literal = false;
    var seven = false;
    var eight = false;
    for (body.blocks) |block| {
        if (block.marker) |marker| if (marker == .number) {
            seven = seven or marker.number == 7;
            eight = eight or marker.number == 8;
        };
        if (block.kind == .code) {
            codes += 1;
            try testing.expectEqual(@as(usize, 1), block.quotes);
            if (codes == 1) {
                try testing.expectEqualStrings("a\tb **literal**\n", block.spans[0].text);
                try testing.expectEqualStrings(">     ~~~zig\n", raw[block.fences.?[0].start..block.fences.?[0].end]);
            } else try testing.expectEqualStrings("indented\n", block.spans[0].text);
        }
        if (block.kind == .literal) {
            literal = true;
            try testing.expectEqualStrings("```\n", block.spans[0].text);
        }
    }
    try testing.expect(seven and eight and literal);
    try testing.expectEqual(@as(usize, 2), codes);
    var first: std.ArrayList(u8) = .empty;
    for (body.blocks[0].spans) |span| try first.appendSlice(a, span.text);
    try testing.expectEqualStrings("prose - literal", first.items);
    try testing.expectEqualStrings("1. literal switch", body.blocks[3].spans[0].text);
}

test "M23 containers keep inline styles across joined authored lines as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try ReviewBody.parse(a, "> - **first\n>     second**\n>\n> Title\n> =====");
    var visible: std.ArrayList(u8) = .empty;
    for (body.blocks[0].spans) |span| if (!span.hidden) {
        try testing.expect(span.marks.strong);
        try visible.appendSlice(a, span.text);
    };
    try testing.expectEqualStrings("first second", visible.items);
    try testing.expect(body.blocks[2].kind == .heading);
    try testing.expect(body.blocks[2].hidden_line != null);
}

test "M23 literal fences hide only valid delimiters and retain code bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try ReviewBody.parse(a, "**before**\n\n  ~~~~zig extra\r\n  \t*x* :mask: <b>  \r\n  ~~~\n  ````\n  ~~~~~ \r\n**after**");
    var visible: std.ArrayList(u8) = .empty;
    for (body.blocks[2].spans) |span| try visible.appendSlice(a, span.text);
    try testing.expectEqualStrings("\t*x* :mask: <b>  \r\n~~~\n````\n", visible.items);
    try testing.expect(body.blocks[3].spans[1].marks.strong);
}

test "M23 literal indented code removes four columns and preserves remaining whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try ReviewBody.parse(a, "\t\tfirst  \r\n  \t  second\n    \tthird\n \t\r\n    fourth\n\n**after**");
    var visible: std.ArrayList(u8) = .empty;
    for (body.blocks[0].spans) |span| try visible.appendSlice(a, span.text);
    try testing.expectEqualStrings("\tfirst  \r\n  second\n\tthird\n\r\nfourth\n", visible.items);
    try testing.expect(body.blocks[0].fences == null);
    try testing.expect(body.blocks[2].spans[1].marks.strong);
    const malformed = try ReviewBody.parse(a, "**before**\n~~~~zig\n**literal**\n```\n~~~");
    try testing.expect(malformed.blocks[0].spans[1].marks.strong);
    try testing.expectEqualStrings("~~~~zig\n**literal**\n```\n~~~", malformed.blocks[1].spans[0].text);
    try testing.expect(malformed.blocks[1].fences == null);
}

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
        .{ .authored = "plain * spaced * and a_b_c", .visible = "plain * spaced * and a_b_c" },
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
            const body = try ReviewBody.parse(allocator, "# *Heading* ##\n\nSetext\n=====\n\nfirst\r\nsecond  \nthird\n\n**_~~[`literal`](url)~~_**\n\n```suggestion\ncode\n```\n\n  ~~~~zig\n  \tcode\n  ~~~~~\n\n    code\n\n    more\n\n> 4. item\n>     **continued**\n>     - child\n>         ~~~zig\n>         code\n>         ~~~\n>         ```\n>         unclosed\n\n```suggestion\nunclosed");
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
