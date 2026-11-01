//! C-backed Highlighter adapter for the vendored BuiltInGrammars.

const std = @import("std");
const bbr = @import("bbr");
const Allocator = std.mem.Allocator;
const predicate_mod = @import("query_predicates.zig");
const grammar_match = @import("grammar_match.zig");
const user_grammar = @import("user_grammar.zig");
const RuntimePackage = @import("runtime_package.zig").RuntimePackage;
const InjectionQuery = @import("runtime_package.zig").InjectionQuery;
const c = predicate_mod.c;

const BuiltInGrammar = grammar_match.BuiltInGrammar;

/// `addTreeSitter` in `build.zig` compiles `.sources` and embeds `<tag>_highlights`,
/// `<tag>_injections`, and `<tag>_locals` for every manifest entry.
inline fn embeddedQuery(comptime grammar: BuiltInGrammar, comptime kind: []const u8) []const u8 {
    const path: ?[]const u8 = comptime @field(grammar.entry(), kind);
    return if (path == null) "" else @embedFile(@tagName(grammar) ++ "_" ++ kind);
}

fn language(comptime grammar: BuiltInGrammar) ?*const c.TSLanguage {
    const function = @extern(*const fn () callconv(.c) ?*const c.TSLanguage, .{ .name = grammar.entry().symbol });
    return function();
}

const javascript_query = embeddedQuery(.javascript, "highlights");
const javascript_locals_query = embeddedQuery(.javascript, "locals");
const combined_typescript_locals_query = javascript_locals_query ++ "\n" ++ embeddedQuery(.typescript, "locals");

const GrammarSource = struct {
    language: *const c.TSLanguage,
    query: []const u8,
    locals_query: []const u8 = "",
    injections_query: []const u8 = "",
};

const BuiltInPackages = [std.meta.tags(grammar_match.BuiltInGrammar).len]RuntimePackage;
const max_injection_depth = 4;
const default_priority = predicate_mod.default_priority;

pub const TreeSitterHighlighter = struct {
    registry: ?*user_grammar.Registry = null,
    packages: BuiltInPackages = undefined,
    package_count: usize = 0,

    pub fn init(allocator: Allocator, registry: ?*user_grammar.Registry) !TreeSitterHighlighter {
        var self: TreeSitterHighlighter = .{ .registry = registry };
        errdefer self.deinit();
        inline for (std.meta.tags(grammar_match.BuiltInGrammar)) |grammar| {
            const source = grammarSource(grammar) orelse return error.MissingBuiltInGrammar;
            var diagnostic: predicate_mod.Diagnostic = undefined;
            self.packages[self.package_count] = RuntimePackage.init(allocator, source.language, source.query, source.locals_query, source.injections_query, &diagnostic) catch |err| {
                if (err == error.InvalidHighlightQuery or err == error.InvalidLocalsQuery or err == error.InvalidInjectionQuery or err == error.InvalidPredicate) diagnostic.report();
                return err;
            };
            self.package_count += 1;
        }
        return self;
    }

    pub fn deinit(self: *TreeSitterHighlighter) void {
        for (self.packages[0..self.package_count]) |*package| package.deinit();
        self.* = undefined;
    }

    pub fn highlighter(self: *TreeSitterHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlightImpl };

    fn highlightImpl(ptr: *anyopaque, result_allocator: Allocator, scratch_allocator: Allocator, path: []const u8, content: []const u8) anyerror!bbr.highlight.HighlightResult {
        const self: *TreeSitterHighlighter = @ptrCast(@alignCast(ptr));
        if (self.registry) |registry| {
            if (registry.matchName(path, content) != null) {
                const grammar = registry.grammar(path, content) catch return self.highlightBuiltIn(result_allocator, scratch_allocator, path, content) catch .{ .spans = &.{} };
                if (grammar) |selected| {
                    return highlightWithPackage(result_allocator, scratch_allocator, selected.package, null, content, null) catch
                        self.highlightBuiltIn(result_allocator, scratch_allocator, path, content) catch .{ .spans = &.{} };
                }
            }
        }
        return self.highlightBuiltIn(result_allocator, scratch_allocator, path, content);
    }

    fn highlightBuiltIn(self: *TreeSitterHighlighter, result_allocator: Allocator, scratch_allocator: Allocator, path: []const u8, content: []const u8) !bbr.highlight.HighlightResult {
        const selected = grammar_match.selectBuiltIn(path, content) orelse return .{ .spans = &.{} };
        return highlightWithPackage(result_allocator, scratch_allocator, &self.packages[@intFromEnum(selected)], &self.packages, content, null);
    }
};

fn grammarSource(selected: BuiltInGrammar) ?GrammarSource {
    return switch (selected) {
        // The upstream TypeScript and TSX queries extend the JavaScript queries.
        inline .tsx, .typescript => |grammar| .{
            .language = language(grammar) orelse return null,
            .query = javascript_query ++ "\n" ++ embeddedQuery(grammar, "highlights"),
            .locals_query = combined_typescript_locals_query,
        },
        inline else => |grammar| .{
            .language = language(grammar) orelse return null,
            .query = embeddedQuery(grammar, "highlights"),
            .locals_query = embeddedQuery(grammar, "locals"),
            .injections_query = embeddedQuery(grammar, "injections"),
        },
    };
}

pub fn builtInGrammarName(path: []const u8, content: []const u8) ?[]const u8 {
    return grammar_match.builtInGrammarName(path, content);
}

fn highlightWithQuery(allocator: Allocator, grammar_language: *const c.TSLanguage, query_source: []const u8, locals_query_source: []const u8, content: []const u8) !bbr.highlight.HighlightResult {
    return highlightWithQueryLimit(allocator, grammar_language, query_source, locals_query_source, content, null);
}

fn highlightWithQueryLimit(allocator: Allocator, grammar_language: *const c.TSLanguage, query_source: []const u8, locals_query_source: []const u8, content: []const u8, match_limit: ?u32) !bbr.highlight.HighlightResult {
    var diagnostic: predicate_mod.Diagnostic = undefined;
    var package = try RuntimePackage.init(allocator, grammar_language, query_source, locals_query_source, "", &diagnostic);
    defer package.deinit();
    return highlightWithPackage(allocator, allocator, &package, null, content, match_limit);
}

fn highlightWithPackage(result_allocator: Allocator, scratch_allocator: Allocator, package: *const RuntimePackage, built_ins: ?*const BuiltInPackages, content: []const u8, match_limit: ?u32) !bbr.highlight.HighlightResult {
    const intervals = try collectCaptureIntervals(scratch_allocator, package, built_ins, content, match_limit);
    defer scratch_allocator.free(intervals);
    const spans = try mergeCaptureIntervals(scratch_allocator, content, intervals);
    defer scratch_allocator.free(spans);
    return .{ .spans = try result_allocator.dupe(bbr.highlight.Span, spans) };
}

const CaptureInterval = struct {
    start: u32,
    end: u32,
    capture: bbr.highlight.Capture,
    priority: u16,
    /// The Injection layer depth. The host layer has depth 0.
    depth: u8,
    pattern_index: u32,
    order: usize,
};

/// One parse of the content. A layer with no ranges parses the full content.
const Layer = struct {
    package: *const RuntimePackage,
    ranges: []c.TSRange,
    depth: u8,
};

/// `built_ins` is null for a UserGrammar, so it never hosts an Injection.
fn collectCaptureIntervals(allocator: Allocator, package: *const RuntimePackage, built_ins: ?*const BuiltInPackages, content: []const u8, match_limit: ?u32) ![]CaptureInterval {
    if (content.len > std.math.maxInt(u32)) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
    defer c.ts_parser_delete(parser);

    const lines: LineStarts = if (built_ins != null and package.injection != null) try .init(allocator, content) else .{ .starts = &.{} };
    defer allocator.free(lines.starts);
    var layers: std.ArrayList(Layer) = .empty;
    defer {
        for (layers.items) |layer| allocator.free(layer.ranges);
        layers.deinit(allocator);
    }
    try layers.append(allocator, .{ .package = package, .ranges = &.{}, .depth = 0 });
    var intervals: std.ArrayList(CaptureInterval) = .empty;
    errdefer intervals.deinit(allocator);
    var index: usize = 0;
    while (index < layers.items.len) : (index += 1) {
        const layer = layers.items[index];
        if (!c.ts_parser_set_language(parser, layer.package.language)) return error.IncompatibleGrammar;
        if (!c.ts_parser_set_included_ranges(parser, layer.ranges.ptr, @intCast(layer.ranges.len))) return error.InvalidInjectionRanges;
        const tree = c.ts_parser_parse_string(parser, null, content.ptr, @intCast(content.len)) orelse return error.ParseFailed;
        defer c.ts_tree_delete(tree);
        try collectLayerIntervals(allocator, &intervals, layer, tree, content, match_limit);
        const packages = built_ins orelse continue;
        const injection = layer.package.injection orelse continue;
        if (layer.depth == max_injection_depth) continue;
        try collectInjectionLayers(allocator, &layers, packages, injection, layer, tree, content, lines, match_limit);
    }
    return intervals.toOwnedSlice(allocator);
}

fn collectLayerIntervals(allocator: Allocator, intervals: *std.ArrayList(CaptureInterval), layer: Layer, tree: *c.TSTree, content: []const u8, match_limit: ?u32) !void {
    const package = layer.package;
    const locals = if (package.locals) |locals_query| try predicate_mod.Locals.collectPrepared(
        allocator,
        tree,
        locals_query.query,
        locals_query.predicates,
        package.local_scope_id,
        package.local_definition_id,
        package.local_reference_id,
        content,
    ) else predicate_mod.Locals{ .ranges = &.{} };
    defer locals.deinit(allocator);
    const cursor = c.ts_query_cursor_new() orelse return error.QueryCursorInitFailed;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_set_match_limit(cursor, match_limit orelse std.math.maxInt(u32));
    c.ts_query_cursor_exec(cursor, package.highlight.query, c.ts_tree_root_node(tree));

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        if (!try package.highlight.predicates.accepts(match.pattern_index, match, content, locals)) continue;
        const captures = predicate_mod.capturesOf(match);
        for (captures) |capture| {
            const range = try predicate_mod.checkedRange(c.ts_node_start_byte(capture.node), c.ts_node_end_byte(capture.node), content);
            if (range.start == range.end) continue;
            if (capture.index >= package.captures.len) return error.InvalidCapture;
            var interval: CaptureInterval = .{
                .start = @intCast(range.start),
                .end = @intCast(range.end),
                .capture = package.captures[capture.index] orelse continue,
                .priority = package.highlight.predicates.priorities[match.pattern_index],
                .depth = layer.depth,
                .pattern_index = match.pattern_index,
                .order = 0,
            };
            if (layer.ranges.len == 0) {
                interval.order = intervals.items.len;
                try intervals.append(allocator, interval);
                continue;
            }
            for (overlappingRanges(layer.ranges, interval.start, interval.end)) |included| {
                const start = @max(interval.start, included.start_byte);
                const end = @min(interval.end, included.end_byte);
                var clipped = interval;
                clipped.start = start;
                clipped.end = end;
                clipped.order = intervals.items.len;
                try intervals.append(allocator, clipped);
            }
        }
    }
    if (c.ts_query_cursor_did_exceed_match_limit(cursor)) return error.QueryMatchLimitExceeded;
}

const CombinedRanges = struct {
    grammar: grammar_match.BuiltInGrammar,
    ranges: std.ArrayList(c.TSRange) = .empty,
};

fn collectInjectionLayers(
    allocator: Allocator,
    layers: *std.ArrayList(Layer),
    packages: *const BuiltInPackages,
    injection: InjectionQuery,
    parent: Layer,
    tree: *c.TSTree,
    content: []const u8,
    lines: LineStarts,
    match_limit: ?u32,
) !void {
    const cursor = c.ts_query_cursor_new() orelse return error.QueryCursorInitFailed;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_set_match_limit(cursor, match_limit orelse std.math.maxInt(u32));
    c.ts_query_cursor_exec(cursor, injection.prepared.query, c.ts_tree_root_node(tree));
    var combined: std.ArrayList(CombinedRanges) = .empty;
    defer {
        for (combined.items) |*group| group.ranges.deinit(allocator);
        combined.deinit(allocator);
    }
    var ranges: std.ArrayList(c.TSRange) = .empty;
    defer ranges.deinit(allocator);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        if (!try injection.prepared.predicates.accepts(match.pattern_index, match, content, .{ .ranges = &.{} })) continue;
        const settings = injection.prepared.injections[match.pattern_index];
        var content_node: ?c.TSNode = null;
        var name = settings.language;
        for (predicate_mod.capturesOf(match)) |capture| {
            if (capture.index == injection.content_id) {
                content_node = capture.node;
            } else if (injection.language_id != null and capture.index == injection.language_id.?) {
                const range = try predicate_mod.checkedRange(c.ts_node_start_byte(capture.node), c.ts_node_end_byte(capture.node), content);
                name = content[range.start..range.end];
            }
        }
        const node = content_node orelse continue;
        const grammar = grammar_match.selectInjection(name orelse continue) orelse continue;
        if (settings.combined) {
            const group = for (combined.items) |*group| {
                if (group.grammar == grammar) break group;
            } else new: {
                try combined.append(allocator, .{ .grammar = grammar });
                break :new &combined.items[combined.items.len - 1];
            };
            try appendContentRanges(allocator, &group.ranges, node, settings, parent, content, lines);
        } else {
            ranges.clearRetainingCapacity();
            try appendContentRanges(allocator, &ranges, node, settings, parent, content, lines);
            try appendLayer(allocator, layers, &packages[@intFromEnum(grammar)], ranges.items, parent.depth + 1);
        }
    }
    if (c.ts_query_cursor_did_exceed_match_limit(cursor)) return error.QueryMatchLimitExceeded;
    for (combined.items) |group| try appendLayer(allocator, layers, &packages[@intFromEnum(group.grammar)], group.ranges.items, parent.depth + 1);
}

/// Sorts and joins the ranges, because a combined layer can collect them out of order.
fn appendLayer(allocator: Allocator, layers: *std.ArrayList(Layer), package: *const RuntimePackage, ranges: []c.TSRange, depth: u8) !void {
    if (ranges.len == 0) return;
    std.mem.sort(c.TSRange, ranges, {}, rangeLessThan);
    var count: usize = 1;
    for (ranges[1..]) |range| {
        const last = &ranges[count - 1];
        if (range.start_byte <= last.end_byte) {
            if (range.end_byte > last.end_byte) {
                last.end_byte = range.end_byte;
                last.end_point = range.end_point;
            }
        } else {
            ranges[count] = range;
            count += 1;
        }
    }
    const owned = try allocator.dupe(c.TSRange, ranges[0..count]);
    errdefer allocator.free(owned);
    try layers.append(allocator, .{ .package = package, .ranges = owned, .depth = depth });
}

fn rangeLessThan(_: void, a: c.TSRange, b: c.TSRange) bool {
    return a.start_byte < b.start_byte;
}

/// Appends the content ranges of one match, clipped to the parent layer ranges.
fn appendContentRanges(
    allocator: Allocator,
    ranges: *std.ArrayList(c.TSRange),
    node: c.TSNode,
    settings: predicate_mod.Injection,
    parent: Layer,
    content: []const u8,
    lines: LineStarts,
) !void {
    var start: u32 = c.ts_node_start_byte(node);
    var end: u32 = c.ts_node_end_byte(node);
    if (settings.offset) |offset| {
        start = lines.offsetByte(content, c.ts_node_start_point(node), offset[0], offset[1]) orelse return;
        end = lines.offsetByte(content, c.ts_node_end_point(node), offset[2], offset[3]) orelse return;
        if (start >= end or !predicate_mod.utf8Boundary(content, start) or !predicate_mod.utf8Boundary(content, end)) return;
    }
    if (settings.include_children) return appendClipped(allocator, ranges, start, end, parent, lines);
    var at = start;
    for (0..c.ts_node_named_child_count(node)) |child_index| {
        const child = c.ts_node_named_child(node, @intCast(child_index));
        const child_start = c.ts_node_start_byte(child);
        const child_end = c.ts_node_end_byte(child);
        if (child_start >= end) break;
        if (child_start > at) try appendClipped(allocator, ranges, at, child_start, parent, lines);
        at = @max(at, child_end);
    }
    if (at < end) try appendClipped(allocator, ranges, at, end, parent, lines);
}

fn appendClipped(allocator: Allocator, ranges: *std.ArrayList(c.TSRange), start: u32, end: u32, parent: Layer, lines: LineStarts) !void {
    if (parent.ranges.len == 0) return ranges.append(allocator, lines.range(start, end));
    for (overlappingRanges(parent.ranges, start, end)) |included| {
        try ranges.append(allocator, lines.range(@max(start, included.start_byte), @min(end, included.end_byte)));
    }
}

/// The ranges that overlap `start..end`, from ranges that are sorted and disjoint.
fn overlappingRanges(ranges: []const c.TSRange, start: u32, end: u32) []const c.TSRange {
    const first = std.sort.partitionPoint(c.TSRange, ranges, start, rangeEndsAtOrBefore);
    const limit = first + std.sort.partitionPoint(c.TSRange, ranges[first..], end, rangeStartsBefore);
    return ranges[first..limit];
}

fn rangeEndsAtOrBefore(byte: u32, range: c.TSRange) bool {
    return range.end_byte <= byte;
}

fn rangeStartsBefore(byte: u32, range: c.TSRange) bool {
    return range.start_byte < byte;
}

/// The byte offset of each line start, for the row and column points of a range.
const LineStarts = struct {
    starts: []u32,

    fn init(allocator: Allocator, content: []const u8) !LineStarts {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);
        for (content, 0..) |byte, index| if (byte == '\n') try starts.append(allocator, @intCast(index + 1));
        return .{ .starts = try starts.toOwnedSlice(allocator) };
    }

    fn point(self: LineStarts, byte: u32) c.TSPoint {
        const row = std.sort.upperBound(u32, self.starts, byte, orderU32) - 1;
        return .{ .row = @intCast(row), .column = byte - self.starts[row] };
    }

    fn range(self: LineStarts, start: u32, end: u32) c.TSRange {
        return .{ .start_point = self.point(start), .end_point = self.point(end), .start_byte = start, .end_byte = end };
    }

    /// Moves a point by rows and byte columns. A point outside its line gives null.
    fn offsetByte(self: LineStarts, content: []const u8, at: c.TSPoint, rows: i32, columns: i32) ?u32 {
        const row = std.math.cast(usize, @as(i64, at.row) + rows) orelse return null;
        const column = std.math.cast(u32, @as(i64, at.column) + columns) orelse return null;
        if (row >= self.starts.len) return null;
        const line_end = if (row + 1 < self.starts.len) self.starts[row + 1] - 1 else content.len;
        if (column > line_end - self.starts[row]) return null;
        return self.starts[row] + column;
    }

    fn orderU32(key: u32, item: u32) std.math.Order {
        return std.math.order(key, item);
    }
};

fn mergeCaptureIntervals(allocator: Allocator, content: []const u8, intervals: []CaptureInterval) ![]bbr.highlight.Span {
    if (!std.sort.isSorted(CaptureInterval, intervals, {}, intervalLessThan)) {
        std.mem.sort(CaptureInterval, intervals, {}, intervalLessThan);
    }
    var spans: std.ArrayList(bbr.highlight.Span) = .empty;
    errdefer spans.deinit(allocator);
    var line_state: LineState = .{};
    var open: std.PriorityQueue(CaptureInterval, void, higherPrecedence) = .empty;
    defer open.deinit(allocator);
    var next: usize = 0;
    var position: u32 = 0;
    while (true) {
        while (next < intervals.len and intervals[next].start <= position) : (next += 1) {
            try open.push(allocator, intervals[next]);
        }
        while (open.peek()) |top| {
            if (top.end > position) break;
            _ = open.pop();
        }
        const next_start = if (next < intervals.len) intervals[next].start else null;
        const winner = open.peek() orelse {
            position = next_start orelse break;
            continue;
        };
        const end = if (next_start) |start| @min(winner.end, start) else winner.end;
        try appendIntervalSpans(allocator, &spans, content, &line_state, position, end, winner.capture);
        position = end;
    }
    return spans.toOwnedSlice(allocator);
}

const LineState = struct {
    line: u32 = 1,
    line_start: usize = 0,
    scanned_to: usize = 0,
};

fn appendIntervalSpans(
    allocator: Allocator,
    spans: *std.ArrayList(bbr.highlight.Span),
    content: []const u8,
    state: *LineState,
    absolute_start: u32,
    absolute_end: u32,
    capture: bbr.highlight.Capture,
) !void {
    const start: usize = absolute_start;
    const end: usize = absolute_end;
    while (std.mem.indexOfScalarPos(u8, content, state.scanned_to, '\n')) |newline| {
        if (newline >= start) break;
        state.line += 1;
        state.line_start = newline + 1;
        state.scanned_to = newline + 1;
    }

    var at = start;
    while (at < end) {
        const newline = std.mem.indexOfScalarPos(u8, content, at, '\n');
        const part_end = @min(end, newline orelse end);
        if (at < part_end) {
            const relative_start = at - state.line_start;
            const relative_end = part_end - state.line_start;
            if (spans.items.len != 0) {
                const previous = &spans.items[spans.items.len - 1];
                if (previous.line == state.line and previous.end == relative_start and std.meta.eql(previous.capture, capture)) {
                    previous.end = @intCast(relative_end);
                } else {
                    try spans.append(allocator, .{ .line = state.line, .start = @intCast(relative_start), .end = @intCast(relative_end), .capture = capture });
                }
            } else {
                try spans.append(allocator, .{ .line = state.line, .start = @intCast(relative_start), .end = @intCast(relative_end), .capture = capture });
            }
        }
        if (newline == null or newline.? >= end) break;
        at = newline.? + 1;
        state.line += 1;
        state.line_start = at;
        state.scanned_to = at;
    }
    state.scanned_to = @max(state.scanned_to, end);
}

fn intervalLessThan(_: void, a: CaptureInterval, b: CaptureInterval) bool {
    return a.start < b.start or (a.start == b.start and a.order < b.order);
}

fn higherPrecedence(_: void, a: CaptureInterval, b: CaptureInterval) std.math.Order {
    if (a.priority != b.priority) return std.math.order(b.priority, a.priority);
    if (a.depth != b.depth) return std.math.order(b.depth, a.depth);
    if (a.pattern_index != b.pattern_index) return std.math.order(b.pattern_index, a.pattern_index);
    return std.math.order(b.order, a.order);
}

const testing = std.testing;

test "BuiltInGrammar selection covers JavaScript TypeScript and TSX" {
    try testing.expect(grammar_match.selectBuiltIn("src/a.js", "") != null);
    try testing.expect(grammar_match.selectBuiltIn("src/a.mts", "") != null);
    try testing.expect(grammar_match.selectBuiltIn("src/a.tsx", "") != null);
    try testing.expectEqual(BuiltInGrammar.zig, grammar_match.selectBuiltIn("src/a.zig", "").?);
    try testing.expect(grammar_match.selectBuiltIn("scripts/release", "#!/usr/bin/env bash\n") != null);
}

test "UserGrammar runtime failure restores BuiltInGrammar or plain text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "fixture", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/payload", .data = "not a library" });
    const payload_digest = digestHex("not a library");
    const manifest = try std.fmt.allocPrint(testing.allocator,
        \\name = "fixture"
        \\version = "1.0.0"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_fixture"
        \\library = "payload"
        \\highlight_query = "payload"
        \\[[payload]]
        \\path = "payload"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = [".js", ".fixture"]
        \\
    , .{ @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch), payload_digest });
    defer testing.allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/grammar.toml", .data = manifest });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/fixture", .{&tmp.sub_path});
    defer testing.allocator.free(path);
    var inspection = try user_grammar.inspect(testing.allocator, io, path);
    const digest = inspection.report.digest;
    inspection.deinit();
    const entries = [_]user_grammar.RegistryEntry{.{
        .name = "fixture",
        .path = path,
        .enabled = true,
        .trusted_digest = digest,
        .receipt = .{ .bundle_digest = digest, .bbr_identity = "test-build", .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION },
    }};
    var registry = try user_grammar.Registry.init(testing.allocator, io, &entries, &.{}, "test-build");
    defer registry.deinit();
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, &registry);
    defer highlighter.deinit();

    const built_in = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", "const answer = 1;\n");
    defer freeResult(built_in);
    try testing.expect(built_in.spans.len > 0);
    const plain = try highlighter.highlighter().highlight(testing.allocator, "src/a.fixture", "content\n");
    try testing.expectEqual(@as(usize, 0), plain.spans.len);
}

test "JavaScript tracer produces ordered non-overlapping Captures" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", "const answer = \"yes\";\n");
    defer {
        testing.allocator.free(result.spans);
    }
    try testing.expect(result.spans.len > 0);
    for (result.spans, 0..) |span, i| {
        try testing.expect(span.start < span.end);
        if (i > 0 and result.spans[i - 1].line == span.line) try testing.expect(result.spans[i - 1].end <= span.start);
    }
}

test "JavaScript BuiltInGrammar executes conditional Captures" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", "Widget widget SCREAM console require other\n");
    defer freeResult(result);

    try expectSpan(result, 1, 0, 6, "constructor");
    try expectSpan(result, 1, 7, 13, "variable");
    try expectSpan(result, 1, 14, 20, "constant");
    try expectSpan(result, 1, 21, 28, "variable.builtin");
    try expectSpan(result, 1, 29, 36, "function.builtin");
    try expectSpan(result, 1, 37, 42, "variable");
}

test "JavaScript BuiltInGrammar rejects built-in Captures for local bindings" {
    const source =
        \\console.log(1);
        \\function f(console) { console.log(2); }
        \\require("x");
        \\function g(require) { require("y"); }
    ;
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    const global_console = std.mem.indexOf(u8, source, "console").?;
    const console_parameter = std.mem.indexOfPos(u8, source, global_console + 1, "console").?;
    const local_console = std.mem.indexOfPos(u8, source, console_parameter + 1, "console").?;
    const global_require = std.mem.indexOf(u8, source, "require").?;
    const require_parameter = std.mem.indexOfPos(u8, source, global_require + 1, "require").?;
    const local_require = std.mem.indexOfPos(u8, source, require_parameter + 1, "require").?;
    try expectSpan(result, 1, global_console, global_console + 7, "variable.builtin");
    try expectNoCapture(result, source, local_console, local_console + 7, captureAt(result, source, global_console, global_console + 7).?);
    try expectSpan(result, 3, 0, 7, "function.builtin");
    try expectNoCapture(result, source, local_require, local_require + 7, captureAt(result, source, global_require, global_require + 7).?);
}

test "JavaScript and TypeScript BuiltInGrammars track inherited and shadowed locals" {
    const source =
        \\console; require();
        \\function outer(console) {
        \\  console; require();
        \\  {
        \\    const require = () => {};
        \\    console; require();
        \\  }
        \\  console; require();
        \\}
        \\console; require();
    ;
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for ([_][]const u8{ "src/a.js", "src/a.ts", "src/a.tsx" }) |path| {
        const result = try highlighter.highlighter().highlight(testing.allocator, path, source);
        defer freeResult(result);

        try expectSpan(result, 1, 0, 7, "variable.builtin");
        try expectSpan(result, 1, 9, 16, "function.builtin");
        try expectSpan(result, 2, 15, 22, if (std.mem.endsWith(u8, path, ".js")) "variable" else "variable.parameter");
        try expectSpan(result, 3, 2, 9, "variable");
        try expectSpan(result, 3, 11, 18, "function.builtin");
        try expectSpan(result, 6, 4, 11, "variable");
        try expectSpan(result, 6, 13, 20, "function");
        try expectSpan(result, 8, 2, 9, "variable");
        try expectSpan(result, 8, 11, 18, "function.builtin");
        try expectSpan(result, 10, 0, 7, "variable.builtin");
        try expectSpan(result, 10, 9, 16, "function.builtin");
    }
}

test "TypeScript BuiltInGrammars track optional parameter locals" {
    const source = "function f(console?: unknown) { console; }\nconsole;\n";
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for ([_][]const u8{ "src/a.ts", "src/a.tsx" }) |path| {
        const result = try highlighter.highlighter().highlight(testing.allocator, path, source);
        defer freeResult(result);

        try expectSpan(result, 1, 11, 18, "variable.parameter");
        try expectSpan(result, 1, 32, 39, "variable");
        try expectSpan(result, 2, 0, 7, "variable.builtin");
    }
}

test "local filtering keeps UTF-8 byte offsets" {
    const source = "function f(console) { const π = 0; console; }\nconsole;\n";
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    const parameter = std.mem.indexOf(u8, source, "console").?;
    const reference = std.mem.indexOfPos(u8, source, parameter + 7, "console").?;
    try expectSpan(result, 1, reference, reference + 7, "variable");
    try expectSpan(result, 2, 0, 7, "variable.builtin");
}

test "TypeScript and TSX BuiltInGrammars load their queries" {
    const cases = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = "src/a.ts", .source = "interface User { name: string }\n" },
        .{ .path = "src/a.tsx", .source = "const App = () => <main>Hello</main>;\n" },
    };
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for (cases) |case| {
        const result = try highlighter.highlighter().highlight(testing.allocator, case.path, case.source);
        defer {
            testing.allocator.free(result.spans);
        }
        try testing.expect(result.spans.len > 0);
    }
}

test "remaining BuiltInGrammars load their queries and produce Captures" {
    const cases = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = "style.css", .source = ".card { color: red; }\n" },
        .{ .path = "main.go", .source = "package main\nfunc main() {}\n" },
        .{ .path = "run.sh", .source = "#!/bin/bash\necho hello\n" },
        .{ .path = "data.json", .source = "{\"ready\": true}\n" },
        .{ .path = "config.yaml", .source = "ready: true\n" },
    };
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for (cases) |case| {
        const result = try highlighter.highlighter().highlight(testing.allocator, case.path, case.source);
        defer {
            testing.allocator.free(result.spans);
        }
        try testing.expect(result.spans.len > 0);
    }
}

test "interval merge matches byte planes for every BuiltInGrammar fixture" {
    const cases = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = "valid.js", .source = "const answer = value ?? 42;\nconsole.log(answer);\n" },
        .{ .path = "invalid.js", .source = "function broken( { return console.\n" },
        .{ .path = "minified.js", .source = "const f=(x)=>x?{value:x}:null;console.log(f(1));\n" },
        .{ .path = "predicates.js", .source = "Widget widget SCREAM console require other\n" },
        .{ .path = "nested.ts", .source = "interface Box<T> { value: T }\nconst box: Box<string> = { value: 'x' };\n" },
        .{ .path = "component.tsx", .source = "const App = ({name}: {name: string}) => <main className=\"card\">{name}</main>;\n" },
        .{ .path = "style.css", .source = ".card:hover { color: rgb(1, 2, 3); }\n" },
        .{ .path = "main.go", .source = "package main\nfunc main() { println(\"hello\") }\n" },
        .{ .path = "run.sh", .source = "#!/bin/bash\nname=world\necho \"hello ${name}\"\n" },
        .{ .path = "data.json", .source = "{\"nested\": {\"ready\": true}, \"items\": [1, 2]}\n" },
        .{ .path = "config.yaml", .source = "service:\n  enabled: true\n  ports: [80, 443]\n" },
        .{ .path = "main.zig", .source = zig_fixture },
        .{ .path = "point.c", .source = c_fixture },
        .{ .path = "box.cpp", .source = cpp_fixture },
        .{ .path = "point.h", .source = c_header_fixture },
        .{ .path = "main.rs", .source = rust_fixture },
        .{ .path = "main.odin", .source = odin_fixture },
        .{ .path = "Greeter.java", .source = java_fixture },
        .{ .path = "Greeter.kt", .source = kotlin_fixture },
        .{ .path = "build.gradle", .source = groovy_fixture },
        .{ .path = "Greeter.cs", .source = c_sharp_fixture },
        .{ .path = "scripts/run", .source = python_fixture },
        .{ .path = "lib/add.rb", .source = ruby_fixture },
        .{ .path = "App.swift", .source = swift_fixture },
        .{ .path = "query.sql", .source = sql_fixture },
        .{ .path = "Cargo.toml", .source = toml_fixture },
        .{ .path = "docker/Dockerfile", .source = dockerfile_fixture },
        .{ .path = "Makefile", .source = make_fixture },
        .{ .path = "index.html", .source = html_fixture },
        .{ .path = "logo.svg", .source = xml_fixture },
        .{ .path = "README.md", .source = markdown_fixture },
        .{ .path = "index.php", .source = php_fixture },
        .{ .path = "page.php", .source = php_heredoc_fixture },
        .{ .path = "link.php", .source = php_split_tag_fixture },
    };
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for (cases) |case| {
        const grammar = grammar_match.selectBuiltIn(case.path, case.source).?;
        const package = &highlighter.packages[@intFromEnum(grammar)];
        const intervals = try collectCaptureIntervals(testing.allocator, package, &highlighter.packages, case.source, null);
        defer testing.allocator.free(intervals);
        const expected = try spansFromBytePlanes(testing.allocator, case.source, intervals);
        defer testing.allocator.free(expected);
        const actual = try mergeCaptureIntervals(testing.allocator, case.source, intervals);
        defer testing.allocator.free(actual);
        try testing.expectEqualDeep(expected, actual);
    }
}

test "M27 grammar every BuiltInGrammar loads its queries" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try testing.expectEqual(std.meta.tags(BuiltInGrammar).len, highlighter.package_count);
    inline for (comptime std.meta.tags(BuiltInGrammar)) |grammar| {
        const package = &highlighter.packages[@intFromEnum(grammar)];
        try testing.expect(c.ts_query_pattern_count(package.highlight.query) > 0);
        const injections: ?[]const u8 = grammar.entry().injections;
        try testing.expectEqual(injections != null, package.injection != null);
    }
}

test "M27 grammar every BuiltInGrammar ABI is compatible with the vendored runtime" {
    inline for (comptime std.meta.tags(BuiltInGrammar)) |grammar| {
        const abi = c.ts_language_abi_version(language(grammar).?);
        try testing.expect(abi >= c.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION and abi <= c.TREE_SITTER_LANGUAGE_VERSION);
        try testing.expectEqual(@as(u32, grammar.entry().abi), abi);
    }
}

test "M27 grammar the GrammarMatch table equals the manifest" {
    const fields = comptime std.meta.fields(@TypeOf(grammar_match.manifest.grammars));
    try testing.expectEqual(fields.len, grammar_match.table.len);
    inline for (fields, grammar_match.table) |field, row| {
        const grammar = @field(BuiltInGrammar, field.name);
        const matches = @field(grammar_match.manifest.grammars, field.name).matches;
        try testing.expectEqual(grammar, row.grammar);
        inline for (.{ "filenames", "extensions", "shebangs" }) |kind| {
            const expected: []const []const u8 = &@field(matches, kind);
            try testing.expectEqual(expected.len, @field(row, kind).len);
            for (expected, @field(row, kind)) |want, have| try testing.expectEqualStrings(want, have);
        }
        inline for (matches.filenames) |filename| try testing.expectEqual(grammar, grammar_match.selectBuiltIn("dir/" ++ filename, "").?);
        inline for (matches.extensions) |extension| try testing.expectEqual(grammar, grammar_match.selectBuiltIn("src/a" ++ extension, "").?);
        inline for (matches.shebangs) |shebang| {
            try testing.expectEqual(grammar, grammar_match.selectBuiltIn("scripts/run", "#!/usr/bin/env " ++ shebang ++ "\n").?);
            try testing.expectEqual(grammar, grammar_match.selectBuiltIn("scripts/run", "#!/usr/bin/" ++ shebang ++ " -e\n").?);
        }
    }
}

test "M27 grammar GrammarMatch keeps every M13 case and selects Zig and Bash" {
    const cases = [_]struct { path: []const u8, content: []const u8 = "", grammar: ?BuiltInGrammar }{
        .{ .path = "src/a.tsx", .grammar = .tsx },
        .{ .path = "src/a.ts", .grammar = .typescript },
        .{ .path = "src/a.mts", .grammar = .typescript },
        .{ .path = "src/a.cts", .grammar = .typescript },
        .{ .path = "src/a.js", .grammar = .javascript },
        .{ .path = "src/a.jsx", .grammar = .javascript },
        .{ .path = "src/a.mjs", .grammar = .javascript },
        .{ .path = "src/a.cjs", .grammar = .javascript },
        .{ .path = "src/a.css", .grammar = .css },
        .{ .path = "main.go", .grammar = .go },
        .{ .path = "data.json", .grammar = .json },
        .{ .path = "config.yaml", .grammar = .yaml },
        .{ .path = "config.yml", .grammar = .yaml },
        .{ .path = "run.sh", .grammar = .bash },
        .{ .path = "run.bash", .grammar = .bash },
        .{ .path = "home/.bashrc", .grammar = .bash },
        .{ .path = "Bashfile", .grammar = .bash },
        .{ .path = "scripts/release", .content = "#!/usr/bin/env bash\n", .grammar = .bash },
        .{ .path = "scripts/release", .content = "#!/bin/bash\n", .grammar = .bash },
        .{ .path = "scripts/release", .content = "#!/bin/sh\n", .grammar = .bash },
        .{ .path = "scripts/release", .content = "#!/bin/sh -e\n", .grammar = .bash },
        .{ .path = "scripts/release", .content = "#!/usr/bin/env -S bash -eu\n", .grammar = .bash },
        .{ .path = "scripts/release", .content = "#!/usr/bin/env zsh\n", .grammar = null },
        .{ .path = "notes/a.json.txt", .content = "#!/usr/bin/env node\n", .grammar = null },
        .{ .path = "README", .grammar = null },
        .{ .path = "SRC/A.JS", .grammar = null },
        .{ .path = "src/a.zig", .grammar = .zig },
        .{ .path = "build.zig.zon", .grammar = .zig },
        .{ .path = "src/a.ziggy", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, case.content));
}

const zig_fixture =
    \\// Adds one.
    \\const Point = struct { x: u32 };
    \\fn add(a: u32) u32 {
    \\    return a + 1;
    \\}
    \\const name = "zig";
    \\
;

test "M27 grammar Zig fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/main.zig", zig_fixture);
    defer freeResult(result);

    try expectRoleAt(result, zig_fixture, "// Adds one.", .comment);
    try expectRoleAt(result, zig_fixture, "\"zig\"", .string);
    try expectRoleAt(result, zig_fixture, "const", .keyword);
    try expectRoleAt(result, zig_fixture, "return", .keyword);
    try expectRoleAt(result, zig_fixture, "add", .function);
    try expectRoleAt(result, zig_fixture, "Point", .type);
    try expectRoleAt(result, zig_fixture, "u32", .type);
}

test "match predicate filters one match and preserves fallback Capture" {
    const query =
        \\(identifier) @variable
        \\((identifier) @constructor (#match? @constructor "^[A-Z]"))
    ;
    const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", "lower Upper\n");
    defer freeResult(result);

    try expectSpan(result, 1, 0, 5, "variable");
    try expectSpan(result, 1, 6, 11, "constructor");
}

test "eq predicate filters one match and preserves later-pattern precedence" {
    const query =
        \\(identifier) @variable
        \\((identifier) @function.builtin (#eq? @function.builtin "require"))
    ;
    const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", "require other\n");
    defer freeResult(result);

    try expectSpan(result, 1, 0, 7, "function.builtin");
    try expectSpan(result, 1, 8, 13, "variable");
}

test "Grammar validation atomically rejects unsupported predicate forms" {
    const cases = [_]struct { query: []const u8, kind: predicate_mod.Diagnostic.Kind }{
        .{ .query = "((identifier) @x (#unknown? @x \"x\"))", .kind = .unknown_operator },
        .{ .query = "((identifier) @x (#set! conceal \"\"))", .kind = .unsupported_directive },
        .{ .query = "((identifier) @x (#match? \"x\" @x))", .kind = .malformed_arguments },
        .{ .query = "((identifier) @x (#match? @x \"(?=x)\"))", .kind = .invalid_regex },
        .{ .query = "((identifier) @x (#is-not? unsupported))", .kind = .unsupported_property },
    };
    for (cases) |case| {
        var query_error_offset: u32 = 0;
        var query_error_type: c.TSQueryError = undefined;
        const grammar_language = language(.javascript).?;
        const query = c.ts_query_new(grammar_language, case.query.ptr, @intCast(case.query.len), &query_error_offset, &query_error_type).?;
        defer c.ts_query_delete(query);
        var diagnostic: predicate_mod.Diagnostic = undefined;
        try testing.expectError(error.InvalidPredicate, predicate_mod.Set.validate(testing.allocator, query, case.query, &diagnostic));
        try testing.expectEqual(case.kind, diagnostic.kind);
        try testing.expectEqual(@as(u32, 1), diagnostic.line);
        try testing.expect(diagnostic.column > 1);
    }
}

test "Grammar validation rejects malformed locals predicates" {
    const locals_query = "((identifier) @local.reference (#unknown? @local.reference \"x\"))";
    try expectInvalidLocalsQuery(locals_query, error.InvalidPredicate, .unknown_operator);
}

test "Grammar validation rejects malformed locals query syntax" {
    try expectInvalidLocalsQuery("(identifier", error.InvalidLocalsQuery, .invalid_query);
}

test "zero-width Capture produces no Span" {
    const query = "(function_declaration name: (identifier) @zero)";
    const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", "function () {}\n");
    defer freeResult(result);

    try testing.expectEqual(@as(usize, 0), result.spans.len);
}

test "invalid Capture ranges fail Highlighting" {
    try testing.expectError(error.InvalidCaptureRange, predicate_mod.checkedRange(2, 1, "abc"));
    try testing.expectError(error.InvalidCaptureRange, predicate_mod.checkedRange(0, 4, "abc"));
    try testing.expectError(error.InvalidCaptureRange, predicate_mod.checkedRange(1, 2, "π"));
}

test "query cursor match loss fails Highlighting" {
    try testing.expectError(error.QueryMatchLimitExceeded, highlightWithQueryLimit(
        testing.allocator,
        language(.javascript).?,
        "(identifier) @variable",
        "",
        "one two\n",
        0,
    ));
}

test "invalid regex diagnostic points to the expression" {
    const source = "((identifier) @x (#match? @x \"(?=x)\"))";
    var query_error_offset: u32 = 0;
    var query_error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(language(.javascript).?, source.ptr, @intCast(source.len), &query_error_offset, &query_error_type).?;
    defer c.ts_query_delete(query);
    var diagnostic: predicate_mod.Diagnostic = undefined;
    try testing.expectError(error.InvalidPredicate, predicate_mod.Set.validate(testing.allocator, query, source, &diagnostic));
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "(?=x)").?)), diagnostic.source_offset);
    try testing.expectEqual(.invalid_pattern, diagnostic.regex_failure.?.reason);
    try testing.expect(diagnostic.regex_failure.?.engine_code != 0);
    try testing.expect(diagnostic.regex_failure.?.fragment().len != 0);
}

test "validation locates later predicates and compiles duplicate expressions once" {
    const invalid_source = "((identifier) @x (#eq? @x \"#not-a-predicate\") (#match? @x \"(?=x)\"))";
    var query_error_offset: u32 = 0;
    var query_error_type: c.TSQueryError = undefined;
    const invalid_query = c.ts_query_new(language(.javascript).?, invalid_source.ptr, @intCast(invalid_source.len), &query_error_offset, &query_error_type).?;
    defer c.ts_query_delete(invalid_query);
    var diagnostic: predicate_mod.Diagnostic = undefined;
    try testing.expectError(error.InvalidPredicate, predicate_mod.Set.validate(testing.allocator, invalid_query, invalid_source, &diagnostic));
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, invalid_source, "(?=x)").?)), diagnostic.source_offset);

    const duplicate_source =
        \\((identifier) @x (#match? @x "^x"))
        \\((identifier) @y (#match? @y "^x"))
    ;
    const duplicate_query = c.ts_query_new(language(.javascript).?, duplicate_source.ptr, @intCast(duplicate_source.len), &query_error_offset, &query_error_type).?;
    defer c.ts_query_delete(duplicate_query);
    const predicates = try predicate_mod.Set.validate(testing.allocator, duplicate_query, duplicate_source, &diagnostic);
    defer predicates.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), predicates.regexes.len);
}

test "eq predicate accepts Capture comparison" {
    const query =
        \\(identifier) @variable
        \\((binary_expression left: (identifier) @same right: (identifier) @right) (#eq? @same @right))
    ;
    const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", "a === a; b === c;\n");
    defer freeResult(result);

    try expectSpan(result, 1, 0, 1, "same");
    try expectSpan(result, 1, 6, 7, "right");
    try expectSpan(result, 1, 9, 10, "variable");
    try expectSpan(result, 1, 15, 16, "variable");
}

test "M27 grammar each new predicate accepts and rejects a match" {
    const cases = [_]struct { predicate: []const u8, source: []const u8, accepted: []const u8, rejected: []const u8 }{
        .{ .predicate = "(#not-eq? @keyword \"alpha\")", .source = "alpha; beta;\n", .accepted = "beta", .rejected = "alpha" },
        .{ .predicate = "(#not-match? @keyword \"^a\")", .source = "alpha; beta;\n", .accepted = "beta", .rejected = "alpha" },
        .{ .predicate = "(#any-of? @keyword \"gamma\" \"beta\")", .source = "alpha; beta;\n", .accepted = "beta", .rejected = "alpha" },
        .{ .predicate = "(#not-any-of? @keyword \"alpha\" \"gamma\")", .source = "alpha; beta;\n", .accepted = "beta", .rejected = "alpha" },
        .{ .predicate = "(#has-ancestor? @keyword class_declaration function_declaration)", .source = "alpha;\nfunction f() { beta; }\n", .accepted = "beta", .rejected = "alpha" },
        .{ .predicate = "(#not-has-ancestor? @keyword function_declaration)", .source = "alpha;\nfunction f() { beta; }\n", .accepted = "alpha", .rejected = "beta" },
        .{ .predicate = "(#has-parent? @keyword call_expression)", .source = "alpha(beta);\n", .accepted = "alpha", .rejected = "beta" },
        .{ .predicate = "(#not-has-parent? @keyword call_expression)", .source = "alpha(beta);\n", .accepted = "beta", .rejected = "alpha" },
    };
    for (cases) |case| {
        const query = try std.fmt.allocPrint(testing.allocator, "((identifier) @keyword {s})", .{case.predicate});
        defer testing.allocator.free(query);
        const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", case.source);
        defer freeResult(result);
        expectRoleAt(result, case.source, case.accepted, .keyword) catch |err| {
            std.debug.print("{s} rejects {s}\n", .{ case.predicate, case.accepted });
            return err;
        };
        if (captureOver(result, case.source, std.mem.indexOf(u8, case.source, case.rejected).?) != null) {
            std.debug.print("{s} accepts {s}\n", .{ case.predicate, case.rejected });
            return error.UnexpectedSpan;
        }
    }
}

test "M27 grammar set priority changes the winner between overlapping patterns" {
    const source = "alpha;\n";
    const later_wins = try highlightWithQuery(testing.allocator, language(.javascript).?, "(identifier) @keyword\n(identifier) @variable", "", source);
    defer freeResult(later_wins);
    try expectRoleAt(later_wins, source, "alpha", .variable);

    for ([_][]const u8{
        "((identifier) @keyword (#set! priority 101))\n(identifier) @variable",
        "((identifier) @keyword (#set! \"priority\" 101))\n(identifier) @variable",
        "(identifier) @keyword\n((identifier) @variable (#set! priority 99))",
    }) |query| {
        const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", source);
        defer freeResult(result);
        try expectRoleAt(result, source, "alpha", .keyword);
    }
}

test "M27 grammar a hidden Capture produces no Span and still filters" {
    const hidden_only = try highlightWithQuery(testing.allocator, language(.javascript).?, "(identifier) @_name", "", "alpha;\n");
    defer freeResult(hidden_only);
    try testing.expectEqual(@as(usize, 0), hidden_only.spans.len);

    const query =
        \\(call_expression
        \\  function: (identifier) @_callee
        \\  arguments: (arguments (identifier) @keyword)
        \\  (#eq? @_callee "alpha"))
    ;
    const source = "alpha(beta); gamma(delta);\n";
    const result = try highlightWithQuery(testing.allocator, language(.javascript).?, query, "", source);
    defer freeResult(result);
    try testing.expectEqual(@as(usize, 1), result.spans.len);
    try expectRoleAt(result, source, "beta", .keyword);
}

test "M27 grammar a predicate on an absent optional Capture behaves like Neovim" {
    const source = "alpha(); beta(y); gamma(x);\n";
    const positive = try highlightWithQuery(testing.allocator, language(.javascript).?,
        \\(call_expression function: (identifier) @keyword arguments: (arguments (identifier)? @_arg) (#eq? @_arg "x"))
    , "", source);
    defer freeResult(positive);
    try expectRoleAt(positive, source, "alpha", .keyword);
    try testing.expectEqual(null, captureOver(positive, source, std.mem.indexOf(u8, source, "beta").?));
    try expectRoleAt(positive, source, "gamma", .keyword);

    const negated = try highlightWithQuery(testing.allocator, language(.javascript).?,
        \\(call_expression function: (identifier) @keyword arguments: (arguments (identifier)? @_arg) (#not-eq? @_arg "x"))
    , "", source);
    defer freeResult(negated);
    try testing.expectEqual(null, captureOver(negated, source, std.mem.indexOf(u8, source, "alpha").?));
    try expectRoleAt(negated, source, "beta", .keyword);
    try testing.expectEqual(null, captureOver(negated, source, std.mem.indexOf(u8, source, "gamma").?));
}

test "M27 grammar every Capture name in the M13 queries keeps its role" {
    // Generated from `Capture.init` before the M27 prefix rules.
    const golden = [_]struct { []const u8, bbr.highlight.CaptureRole }{
        .{ "attribute", .property },
        .{ "boolean", .constant },
        .{ "comment", .comment },
        .{ "constant", .constant },
        .{ "constant.builtin", .constant },
        .{ "constructor", .function },
        .{ "embedded", .unknown },
        .{ "escape", .unknown },
        .{ "function", .function },
        .{ "function.builtin", .function },
        .{ "function.method", .function },
        .{ "keyword", .keyword },
        .{ "label", .variable },
        .{ "number", .constant },
        .{ "operator", .keyword },
        .{ "property", .property },
        .{ "punctuation.bracket", .punctuation },
        .{ "punctuation.delimiter", .punctuation },
        .{ "punctuation.special", .punctuation },
        .{ "string", .string },
        .{ "string.special", .string },
        .{ "string.special.key", .string },
        .{ "tag", .tag },
        .{ "type", .type },
        .{ "type.builtin", .type },
        .{ "variable", .variable },
        .{ "variable.builtin", .variable },
        .{ "variable.parameter", .variable },
    };
    var seen = [_]bool{false} ** golden.len;
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for ([_]grammar_match.BuiltInGrammar{ .javascript, .typescript, .tsx, .css, .go, .bash, .json, .yaml }) |grammar| {
        const package = &highlighter.packages[@intFromEnum(grammar)];
        next_name: for (package.capture_names, package.captures) |name, capture| {
            for (golden, &seen) |entry, *found| {
                const golden_name, const role = entry;
                if (!std.mem.eql(u8, name, golden_name)) continue;
                found.* = true;
                testing.expectEqual(role, capture.?.role) catch |err| {
                    std.debug.print("{s} Capture {s}\n", .{ @tagName(grammar), name });
                    return err;
                };
                continue :next_name;
            }
            std.debug.print("{s} Capture {s} is not in the golden list\n", .{ @tagName(grammar), name });
            return error.MissingGoldenCapture;
        }
    }
    for (golden, seen) |entry, found| {
        if (!found) {
            std.debug.print("golden Capture {s} is in no M13 query\n", .{entry[0]});
            return error.StaleGoldenCapture;
        }
    }
}

fn freeResult(result: bbr.highlight.HighlightResult) void {
    testing.allocator.free(result.spans);
}

fn digestHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var result: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{digest}) catch unreachable;
    return result;
}

fn expectSpan(result: bbr.highlight.HighlightResult, line: u32, start: usize, end: usize, capture: []const u8) !void {
    for (result.spans) |span| {
        if (span.line == line and span.start == start and span.end == end and span.capture.role == bbr.highlight.Capture.init(0, capture).role) return;
    }
    return error.ExpectedSpanNotFound;
}

fn captureAt(result: bbr.highlight.HighlightResult, source: []const u8, absolute_start: usize, absolute_end: usize) ?bbr.highlight.Capture {
    for (result.spans) |span| {
        var line: u32 = 1;
        var line_start: usize = 0;
        while (line < span.line) : (line += 1) {
            line_start = std.mem.indexOfScalarPos(u8, source, line_start, '\n').? + 1;
        }
        if (line_start + span.start == absolute_start and line_start + span.end == absolute_end) return span.capture;
    }
    return null;
}

fn expectNoCapture(result: bbr.highlight.HighlightResult, source: []const u8, absolute_start: usize, absolute_end: usize, capture: bbr.highlight.Capture) !void {
    if (captureAt(result, source, absolute_start, absolute_end)) |found| {
        if (found.id == capture.id) return error.UnexpectedCaptureFound;
    }
}

/// The precedence of each byte from its own plane: priority, then depth, then pattern, then order.
fn spansFromBytePlanes(allocator: Allocator, content: []const u8, intervals: []const CaptureInterval) ![]bbr.highlight.Span {
    const winners = try allocator.alloc(?bbr.highlight.Capture, content.len);
    defer allocator.free(winners);
    @memset(winners, null);
    const keys = try allocator.alloc(u128, content.len);
    defer allocator.free(keys);
    @memset(keys, 0);

    for (intervals) |interval| {
        const key = @as(u128, interval.priority) << 112 | @as(u128, interval.depth) << 104 | @as(u128, interval.pattern_index) << 64 | interval.order;
        for (interval.start..interval.end) |byte| {
            if (winners[byte] == null or key > keys[byte]) {
                winners[byte] = interval.capture;
                keys[byte] = key;
            }
        }
    }

    var spans: std.ArrayList(bbr.highlight.Span) = .empty;
    errdefer spans.deinit(allocator);
    var line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) {
        if (i < content.len and content[i] != '\n') {
            i += 1;
            continue;
        }
        var at = line_start;
        while (at < i) {
            const capture = winners[at] orelse {
                at += 1;
                continue;
            };
            var end = at + 1;
            while (end < i and winners[end] != null and std.meta.eql(winners[end].?, capture)) end += 1;
            try spans.append(allocator, .{
                .line = line,
                .start = @intCast(at - line_start),
                .end = @intCast(end - line_start),
                .capture = capture,
            });
            at = end;
        }
        if (i == content.len) break;
        i += 1;
        line_start = i;
        line += 1;
    }
    return spans.toOwnedSlice(allocator);
}

fn expectInvalidLocalsQuery(locals_query: []const u8, expected_error: anyerror, expected_kind: predicate_mod.Diagnostic.Kind) !void {
    const javascript = language(.javascript).?;
    const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, javascript)) return error.IncompatibleGrammar;
    const source = "x\n";
    const tree = c.ts_parser_parse_string(parser, null, source.ptr, source.len) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var diagnostic: predicate_mod.Diagnostic = undefined;
    try testing.expectError(expected_error, predicate_mod.Locals.collect(testing.allocator, javascript, tree, locals_query, source, &diagnostic));
    try testing.expectEqual(.locals, diagnostic.query_kind);
    try testing.expectEqual(expected_kind, diagnostic.kind);
    try testing.expectEqual(@as(u32, 1), diagnostic.line);
    try testing.expect(diagnostic.column > 1);
}

const template_css_injection =
    \\((template_string (string_fragment) @injection.content) (#set! injection.language "css"))
;
const template_javascript_injection =
    \\((template_string (string_fragment) @injection.content) (#set! injection.language "javascript"))
;
const argument_name_injection =
    \\((arguments (string (string_fragment) @injection.language) (template_string (string_fragment) @injection.content)))
;

test "M27 injection highlights CSS in a JavaScript template string" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, template_css_injection);
    const source = "const s = `a { color: red; }`;\n";
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    try expectRoleAt(result, source, "a {", .tag);
    try expectRoleAt(result, source, "color", .property);
    try expectRoleAt(result, source, "`", .string);
    try expectRoleAt(result, source, "const", .keyword);
}

test "M27 injection combined ranges form one injected tree" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const source = "[`a`, `{}`];\n";

    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query,
        \\((template_string (string_fragment) @injection.content) (#set! injection.language "css") (#set! injection.combined))
    );
    const combined = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(combined);
    try expectRoleAt(combined, source, "a", .tag);

    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, template_css_injection);
    const separate = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(separate);
    try expectRoleAt(separate, source, "a", .string);
}

test "M27 injection without include-children leaves child node ranges to the host" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const host_number = packageCapture(&highlighter.packages[@intFromEnum(grammar_match.BuiltInGrammar.javascript)], "number");
    const json_number = packageCapture(&highlighter.packages[@intFromEnum(grammar_match.BuiltInGrammar.json)], "number");
    try testing.expect(!std.meta.eql(host_number, json_number));
    const source = "const a = [1];\n";
    const array_injection =
        \\((array) @injection.content (#set! injection.language "json"))
    ;

    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, array_injection);
    const without_children = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(without_children);
    try testing.expectEqual(host_number, captureOver(without_children, source, std.mem.indexOf(u8, source, "1").?).?);

    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, array_injection[0 .. array_injection.len - 1] ++ " (#set! injection.include-children))");
    const with_children = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(with_children);
    try testing.expectEqual(json_number, captureOver(with_children, source, std.mem.indexOf(u8, source, "1").?).?);
}

test "M27 injection offset moves the range and an invalid offset drops only its Injection" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query,
        \\((string) @injection.content (#set! injection.language "css") (#set! injection.include-children) (#offset! @injection.content 0 1 0 -1))
        \\((template_string) @injection.content (#set! injection.language "css") (#set! injection.include-children) (#offset! @injection.content 0 2 0 -1))
        \\((call_expression) @injection.content (#set! injection.language "css") (#set! injection.include-children) (#offset! @injection.content 0 0 3 0))
    );
    const source = "f(\"a { color: red; }\", \"\", `éb`);\n";
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    try expectRoleAt(result, source, "color", .property);
    try expectRoleAt(result, source, "\"a", .string);
    try expectRoleAt(result, source, "b`", .string);
    try expectRoleAt(result, source, "f(", .function);
}

test "M27 injection an offset that ends inside a UTF-8 sequence drops its Injection" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const source = "<a title=\"${x}é\">t</a>\n";
    const value_start = std.mem.indexOf(u8, source, "${").?;
    const value_end = std.mem.indexOf(u8, source, "\">").?;
    const html = &highlighter.packages[@intFromEnum(BuiltInGrammar.html)];
    const intervals = try collectCaptureIntervals(testing.allocator, html, &highlighter.packages, source, null);
    defer testing.allocator.free(intervals);
    for (intervals) |interval| {
        if (interval.depth > 0) try testing.expect(interval.end <= value_start or interval.start >= value_end);
    }

    const result = try highlighter.highlighter().highlight(testing.allocator, "a.html", source);
    defer freeResult(result);
    try testing.expect(result.spans.len > 0);
    for (result.spans) |span| {
        try testing.expectEqual(@as(u32, 1), span.line);
        try testing.expect(predicate_mod.utf8Boundary(source, span.start));
        try testing.expect(predicate_mod.utf8Boundary(source, span.end));
    }
}

test "M27 injection depth stops at 4 for a self-injecting query" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter,
        \\(program (expression_statement (parenthesized_expression "(" @keyword)))
    , "",
        \\((program (expression_statement (parenthesized_expression) @injection.content))
        \\  (#set! injection.language "javascript")
        \\  (#set! injection.include-children)
        \\  (#offset! @injection.content 0 1 0 -1))
    );
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", "((((((x))))))\n");
    defer freeResult(result);

    try testing.expectEqual(@as(usize, 1), result.spans.len);
    try testing.expectEqual(@as(u32, 0), result.spans[0].start);
    try testing.expectEqual(@as(u32, 5), result.spans[0].end);
    try testing.expectEqual(bbr.highlight.CaptureRole.keyword, result.spans[0].capture.role);
}

test "M27 injection a deeper layer wins at equal priority" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter,
        \\(identifier) @variable
        \\(template_string) @string
    , "", template_javascript_injection);
    const source = "`x`;\n";
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    try expectRoleAt(result, source, "x", .variable);
    try expectRoleAt(result, source, "`", .string);
}

test "M27 injection a higher host priority wins over a deeper layer" {
    const host: bbr.highlight.Capture = .init(0, "keyword");
    const injected: bbr.highlight.Capture = .init(0, "variable");
    var intervals = [_]CaptureInterval{
        .{ .start = 0, .end = 3, .capture = host, .priority = default_priority + 1, .depth = 0, .pattern_index = 0, .order = 0 },
        .{ .start = 1, .end = 2, .capture = injected, .priority = default_priority, .depth = 1, .pattern_index = 9, .order = 1 },
        .{ .start = 4, .end = 7, .capture = host, .priority = default_priority, .depth = 0, .pattern_index = 9, .order = 2 },
        .{ .start = 5, .end = 6, .capture = injected, .priority = default_priority, .depth = 1, .pattern_index = 0, .order = 3 },
    };
    const source = "abc def\n";
    const expected = try spansFromBytePlanes(testing.allocator, source, &intervals);
    defer testing.allocator.free(expected);
    const actual = try mergeCaptureIntervals(testing.allocator, source, &intervals);
    defer testing.allocator.free(actual);
    try testing.expectEqualDeep(expected, actual);
    try testing.expectEqualDeep(&[_]bbr.highlight.Span{
        .{ .line = 1, .start = 0, .end = 3, .capture = host },
        .{ .line = 1, .start = 4, .end = 5, .capture = host },
        .{ .line = 1, .start = 5, .end = 6, .capture = injected },
        .{ .line = 1, .start = 6, .end = 7, .capture = host },
    }, actual);
}

/// The fastest of three runs, so one slow run on a busy host does not count.
fn highlightNanoseconds(highlighter: *TreeSitterHighlighter, path: []const u8, source: []const u8) !u64 {
    var fastest: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        const start = std.Io.Timestamp.now(testing.io, .awake);
        const result = try highlighter.highlighter().highlight(testing.allocator, path, source);
        fastest = @min(fastest, @as(u64, @intCast(start.untilNow(testing.io, .awake).toNanoseconds())));
        freeResult(result);
    }
    return fastest;
}

test "M27 injection a large fenced Zig block costs about as much as the same Zig File" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    var markdown: std.ArrayList(u8) = .empty;
    defer markdown.deinit(testing.allocator);
    try markdown.appendSlice(testing.allocator, "```zig\n");
    for (0..4000) |_| try markdown.appendSlice(testing.allocator, "const a = b + c;\n");
    try markdown.appendSlice(testing.allocator, "```\n");
    const zig_source = markdown.items["```zig\n".len .. markdown.items.len - "```\n".len];

    const zig_ns = try highlightNanoseconds(&highlighter, "src/a.zig", zig_source);
    const markdown_ns = try highlightNanoseconds(&highlighter, "doc/a.md", markdown.items);
    if (markdown_ns > 10 * zig_ns) {
        std.debug.print("Markdown took {d} ms, the Zig File took {d} ms\n", .{ markdown_ns / std.time.ns_per_ms, zig_ns / std.time.ns_per_ms });
        return error.FencedBlockTooSlow;
    }
}

test "M27 injection a combined PHP text layer costs about as much as the same HTML File" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..12000) |_| try source.appendSlice(testing.allocator, "<b>x</b><?php $a; ?>\n");

    const html_ns = try highlightNanoseconds(&highlighter, "src/a.html", source.items);
    const php_ns = try highlightNanoseconds(&highlighter, "src/a.php", source.items);
    if (php_ns > 5 * html_ns) {
        std.debug.print("PHP took {d} ms, the HTML File took {d} ms\n", .{ php_ns / std.time.ns_per_ms, html_ns / std.time.ns_per_ms });
        return error.CombinedLayerTooSlow;
    }
}

test "M27 injection merged Spans match the byte planes for random overlapping intervals" {
    var prng: std.Random.DefaultPrng = .init(27);
    const random = prng.random();
    const content = "abcdefghij\nklmnopqrst\nuvwxyzabcd\n";
    var intervals: [24]CaptureInterval = undefined;
    for (0..200) |_| {
        for (&intervals, 0..) |*interval, order| {
            const start = random.uintLessThan(u32, content.len);
            interval.* = .{
                .start = start,
                .end = random.intRangeAtMost(u32, start + 1, content.len),
                .capture = .init(random.uintLessThan(u16, 3), "keyword"),
                .priority = default_priority + random.uintLessThan(u16, 2),
                .depth = random.uintLessThan(u8, 3),
                .pattern_index = random.uintLessThan(u32, 3),
                .order = order,
            };
        }
        const expected = try spansFromBytePlanes(testing.allocator, content, &intervals);
        defer testing.allocator.free(expected);
        const actual = try mergeCaptureIntervals(testing.allocator, content, &intervals);
        defer testing.allocator.free(actual);
        try testing.expectEqualDeep(expected, actual);
    }
}

test "M27 injection resolves a captured Grammar name" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, argument_name_injection);
    const source = "f(\"text/javascript\", `x(1)`);\n";
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    try expectRoleAt(result, source, "x(", .function);
}

test "M27 injection an unknown Grammar name gives no Injection and no failure" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const source = "f(\"nope\", `a { color: red; }`);\nconst s = `b { }`;\n";
    const plain = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(plain);

    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, argument_name_injection ++
        \\
        \\((template_string (string_fragment) @injection.content) (#set! injection.language "unknown"))
    );
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);
    try testing.expectEqualDeep(plain.spans, result.spans);
}

test "M27 injection ignores UserGrammars" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "fixture", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/payload", .data = "not a library" });
    const manifest = try std.fmt.allocPrint(testing.allocator,
        \\name = "fixture"
        \\version = "1.0.0"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_fixture"
        \\library = "payload"
        \\highlight_query = "payload"
        \\[[payload]]
        \\path = "payload"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = [".css"]
        \\
    , .{ @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch), digestHex("not a library") });
    defer testing.allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/grammar.toml", .data = manifest });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/fixture", .{&tmp.sub_path});
    defer testing.allocator.free(path);
    var inspection = try user_grammar.inspect(testing.allocator, io, path);
    const digest = inspection.report.digest;
    inspection.deinit();
    const entries = [_]user_grammar.RegistryEntry{.{
        .name = "fixture",
        .path = path,
        .enabled = true,
        .trusted_digest = digest,
        .receipt = .{ .bundle_digest = digest, .bbr_identity = "test-build", .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION },
    }};
    var registry = try user_grammar.Registry.init(testing.allocator, io, &entries, &.{}, "test-build");
    defer registry.deinit();
    try testing.expectEqualStrings("fixture", registry.matchName("injection.css", "").?);
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, &registry);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, template_css_injection);

    const source = "const s = `a { color: red; }`;\n";
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);
    try expectRoleAt(result, source, "color", .property);
    try testing.expectEqual(
        packageCapture(&highlighter.packages[@intFromEnum(grammar_match.BuiltInGrammar.css)], "property"),
        captureOver(result, source, std.mem.indexOf(u8, source, "color").?).?,
    );
}

test "M27 injection Spans stay ordered and inside their layer ranges" {
    const cases = [_]struct { injections: []const u8, source: []const u8 }{
        .{ .injections = template_css_injection, .source = "const s = `\n.é { color: red; }\nb { }`;\nconst t = `p {}`;\n" },
        .{ .injections = template_javascript_injection ++ "\n((template_string (string_fragment) @injection.content) (#set! injection.language \"css\") (#set! injection.combined))", .source = "[`a`, `{}`];\n[`é`, `y\n{ color: red }`];\n" },
        .{ .injections = "((template_string) @injection.content (#set! injection.language \"css\") (#set! injection.include-children) (#offset! @injection.content 0 1 0 -1))", .source = "f(`a { color: red; }`, `é {}`);\n" },
    };
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    for (cases) |case| {
        try useJavaScriptQueries(&highlighter, javascript_query, javascript_locals_query, case.injections);
        const package = &highlighter.packages[@intFromEnum(grammar_match.BuiltInGrammar.javascript)];
        const intervals = try collectCaptureIntervals(testing.allocator, package, &highlighter.packages, case.source, null);
        defer testing.allocator.free(intervals);
        var injected: usize = 0;
        for (intervals) |interval| {
            if (interval.depth == 0) continue;
            injected += 1;
            try testing.expect(insideTemplateString(case.source, interval.start, interval.end));
        }
        try testing.expect(injected > 0);

        const expected = try spansFromBytePlanes(testing.allocator, case.source, intervals);
        defer testing.allocator.free(expected);
        const actual = try mergeCaptureIntervals(testing.allocator, case.source, intervals);
        defer testing.allocator.free(actual);
        try testing.expectEqualDeep(expected, actual);

        const line_starts = try LineStarts.init(testing.allocator, case.source);
        defer testing.allocator.free(line_starts.starts);
        for (actual, 0..) |span, index| {
            try testing.expect(span.start < span.end);
            const line_start = line_starts.starts[span.line - 1];
            const line_end = std.mem.indexOfScalarPos(u8, case.source, line_start, '\n') orelse case.source.len;
            try testing.expect(line_start + span.end <= line_end);
            try testing.expect(predicate_mod.utf8Boundary(case.source, line_start + span.start));
            try testing.expect(predicate_mod.utf8Boundary(case.source, line_start + span.end));
            if (index == 0) continue;
            const previous = actual[index - 1];
            try testing.expect(previous.line < span.line or previous.end <= span.start);
        }
    }
}

fn useJavaScriptQueries(highlighter: *TreeSitterHighlighter, highlight_query: []const u8, locals_query: []const u8, injections_query: []const u8) !void {
    var diagnostic: predicate_mod.Diagnostic = undefined;
    const replacement = try RuntimePackage.init(testing.allocator, language(.javascript).?, highlight_query, locals_query, injections_query, &diagnostic);
    const package = &highlighter.packages[@intFromEnum(grammar_match.BuiltInGrammar.javascript)];
    package.deinit();
    package.* = replacement;
}

fn packageCapture(package: *const RuntimePackage, name: []const u8) bbr.highlight.Capture {
    for (package.capture_names, package.captures) |capture_name, capture| {
        if (std.mem.eql(u8, capture_name, name)) return capture.?;
    }
    unreachable;
}

fn captureOver(result: bbr.highlight.HighlightResult, source: []const u8, byte: usize) ?bbr.highlight.Capture {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..byte], 0..) |character, index| if (character == '\n') {
        line += 1;
        line_start = index + 1;
    };
    for (result.spans) |span| {
        if (span.line == line and line_start + span.start <= byte and byte < line_start + span.end) return span.capture;
    }
    return null;
}

fn expectRoleAt(result: bbr.highlight.HighlightResult, source: []const u8, needle: []const u8, role: bbr.highlight.CaptureRole) !void {
    const capture = captureOver(result, source, std.mem.indexOf(u8, source, needle).?) orelse return error.ExpectedSpanNotFound;
    try testing.expectEqual(role, capture.role);
}

fn insideTemplateString(source: []const u8, start: usize, end: usize) bool {
    var open: ?usize = null;
    for (source, 0..) |byte, index| {
        if (byte != '`') continue;
        if (open) |first| {
            if (start > first and end <= index) return true;
            open = null;
        } else open = index;
    }
    return false;
}

// M27 ticket 04 fixtures

const c_fixture =
    \\// Adds one.
    \\#include <stdio.h>
    \\struct Point { int x; int (*cb)(int); int run(int); };
    \\static int add(int a) {
    \\    return a + 1;
    \\}
    \\const char *name = "c";
    \\
;

const cpp_fixture =
    \\// Adds one.
    \\#include <vector>
    \\namespace demo {
    \\class Box {
    \\public:
    \\    int value;
    \\};
    \\auto add(int a) -> int { return a + 1; }
    \\}
    \\const char *name = "cpp";
    \\
;

const c_header_fixture =
    \\#ifndef POINT_H
    \\#define POINT_H
    \\/* A point. */
    \\typedef struct { int x; } Point;
    \\int add(int a);
    \\#endif
    \\
;

const rust_fixture =
    \\// Adds one.
    \\struct Point { x: u32 }
    \\fn add(a: u32) -> u32 {
    \\    a + 1
    \\}
    \\const NAME: &str = "rust";
    \\
;

const odin_fixture =
    \\// Adds one.
    \\package main
    \\Point :: struct { x: int }
    \\add :: proc(a: int) -> int {
    \\    return a + 1
    \\}
    \\name := "odin"
    \\
;

test "M27 grammar GrammarMatch selects C for .c and C++ for headers" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "src/point.c", .grammar = .c },
        .{ .path = "include/point.h", .grammar = .cpp },
        .{ .path = "src/point.cpp", .grammar = .cpp },
        .{ .path = "src/point.cc", .grammar = .cpp },
        .{ .path = "src/point.cxx", .grammar = .cpp },
        .{ .path = "include/point.hpp", .grammar = .cpp },
        .{ .path = "include/point.hh", .grammar = .cpp },
        .{ .path = "include/point.hxx", .grammar = .cpp },
        .{ .path = "src/main.rs", .grammar = .rust },
        .{ .path = "src/main.odin", .grammar = .odin },
        .{ .path = "SRC/POINT.C", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
}

test "M27 grammar C fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/point.c", c_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 12, "comment");
    try expectSpan(result, 2, 0, 8, "keyword.import");
    try expectSpan(result, 2, 9, 18, "string.special.path");
    try expectSpan(result, 3, 0, 6, "keyword.type");
    try expectSpan(result, 3, 7, 12, "type");
    try expectSpan(result, 4, 0, 6, "keyword.modifier");
    try expectSpan(result, 4, 7, 10, "type.builtin");
    try expectSpan(result, 4, 11, 14, "function");
    try expectSpan(result, 5, 4, 10, "keyword.return");
    try expectSpan(result, 7, 19, 22, "string");
}

test "M27 grammar C field declaration proves has-ancestor and not-has-ancestor" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/point.c", c_fixture);
    defer freeResult(result);

    try expectSpan(result, 3, 19, 20, "property");
    try expectSpan(result, 3, 28, 30, "function");
    try testing.expectEqualStrings("run", c_fixture[74..77]);
    try testing.expectEqual(@as(?bbr.highlight.Capture, null), captureOver(result, c_fixture, 74));
}

test "M27 grammar C++ fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/box.cpp", cpp_fixture);
    defer freeResult(result);

    try expectSpan(result, 3, 0, 9, "keyword");
    try expectSpan(result, 4, 0, 5, "keyword.type");
    try expectSpan(result, 4, 6, 9, "type");
    try expectSpan(result, 6, 8, 13, "property");
    try expectSpan(result, 8, 5, 8, "function");
    try expectSpan(result, 8, 25, 31, "keyword.return");
    try expectSpan(result, 10, 19, 24, "string");
}

test "M27 grammar C++ gets the include and comment Captures from the inherited C query" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/box.cpp", cpp_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 12, "comment");
    try expectSpan(result, 2, 0, 8, "keyword.import");
    try expectSpan(result, 2, 9, 17, "string.special.path");
}

test "M27 grammar C++ gives a pure C header the roles that C gives a .c File" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const header = try highlighter.highlighter().highlight(testing.allocator, "include/point.h", c_header_fixture);
    defer freeResult(header);
    const source = try highlighter.highlighter().highlight(testing.allocator, "src/point.c", c_header_fixture);
    defer freeResult(source);

    const expected = [_]struct { u32, usize, usize, bbr.highlight.CaptureRole }{
        .{ 1, 0, 7, .keyword },       .{ 1, 8, 15, .constant },     .{ 2, 0, 7, .keyword },       .{ 2, 8, 15, .constant },
        .{ 3, 0, 14, .comment },      .{ 4, 0, 7, .keyword },       .{ 4, 8, 14, .keyword },      .{ 4, 15, 16, .punctuation },
        .{ 4, 17, 20, .type },        .{ 4, 21, 22, .property },    .{ 4, 22, 23, .punctuation }, .{ 4, 24, 25, .punctuation },
        .{ 4, 26, 31, .type },        .{ 4, 31, 32, .punctuation }, .{ 5, 0, 3, .type },          .{ 5, 4, 7, .function },
        .{ 5, 7, 8, .punctuation },   .{ 5, 8, 11, .type },         .{ 5, 12, 13, .variable },    .{ 5, 13, 14, .punctuation },
        .{ 5, 14, 15, .punctuation }, .{ 6, 0, 6, .keyword },
    };
    for ([_]bbr.highlight.HighlightResult{ header, source }) |result| {
        try testing.expectEqual(expected.len, result.spans.len);
        for (expected, result.spans) |want, span| {
            try testing.expectEqual(want[0], span.line);
            try testing.expectEqual(want[1], span.start);
            try testing.expectEqual(want[2], span.end);
            try testing.expectEqual(want[3], span.capture.role);
        }
    }
}

test "M27 grammar Rust fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/main.rs", rust_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 12, "comment");
    try expectSpan(result, 2, 0, 6, "keyword.type");
    try expectSpan(result, 2, 7, 12, "type");
    try expectSpan(result, 3, 0, 2, "keyword.function");
    try expectSpan(result, 3, 3, 6, "function");
    try expectSpan(result, 3, 10, 13, "type.builtin");
    try expectSpan(result, 6, 19, 25, "string");
}

test "M27 grammar Odin fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/main.odin", odin_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 12, "comment");
    try expectSpan(result, 3, 0, 5, "type");
    try expectSpan(result, 3, 9, 15, "keyword.type");
    try expectSpan(result, 4, 0, 3, "function");
    try expectSpan(result, 4, 7, 11, "keyword.function");
    try expectSpan(result, 5, 4, 10, "keyword.return");
    try expectSpan(result, 7, 8, 14, "string");
}

// M27 ticket 05 fixtures

test "M27 grammar GrammarMatch selects Java, Kotlin, Groovy, and C#" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "src/Main.java", .grammar = .java },
        .{ .path = "src/Main.kt", .grammar = .kotlin },
        .{ .path = "build.gradle.kts", .grammar = .kotlin },
        .{ .path = "settings.gradle.kts", .grammar = .kotlin },
        .{ .path = "build.gradle", .grammar = .groovy },
        .{ .path = "src/Main.groovy", .grammar = .groovy },
        .{ .path = "Jenkinsfile", .grammar = .groovy },
        .{ .path = "ci/Jenkinsfile", .grammar = .groovy },
        .{ .path = "Jenkinsfile.bak", .grammar = null },
        .{ .path = "src/Program.cs", .grammar = .c_sharp },
        .{ .path = "src/Program.csx", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
}

test "M27 grammar fence names resolve to Java, Kotlin, Groovy, and C#" {
    const cases = [_]struct { name: []const u8, grammar: BuiltInGrammar }{
        .{ .name = "java", .grammar = .java },
        .{ .name = "kotlin", .grammar = .kotlin },
        .{ .name = "kt", .grammar = .kotlin },
        .{ .name = "groovy", .grammar = .groovy },
        .{ .name = "gradle", .grammar = .groovy },
        .{ .name = "cs", .grammar = .c_sharp },
        .{ .name = "csharp", .grammar = .c_sharp },
        .{ .name = "c#", .grammar = .c_sharp },
        .{ .name = "C#", .grammar = .c_sharp },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectInjection(case.name).?);
}

const java_fixture =
    \\// Greets a user.
    \\package demo;
    \\public class Greeter {
    \\    String greet(String name) {
    \\        return "hi " + name;
    \\    }
    \\}
    \\
;

test "M27 grammar Java fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/Greeter.java", java_fixture);
    defer freeResult(result);

    try expectRoleAt(result, java_fixture, "// Greets a user.", .comment);
    try expectRoleAt(result, java_fixture, "\"hi \"", .string);
    try expectRoleAt(result, java_fixture, "package", .keyword);
    try expectRoleAt(result, java_fixture, "class", .keyword);
    try expectRoleAt(result, java_fixture, "return", .keyword);
    try expectRoleAt(result, java_fixture, "greet(", .function);
    try expectRoleAt(result, java_fixture, "Greeter", .type);
    try expectRoleAt(result, java_fixture, "String", .type);
}

const kotlin_fixture =
    \\// Greets a user.
    \\class Greeter {
    \\    fun greet(name: String): String {
    \\        return "hi " + name
    \\    }
    \\}
    \\
;

test "M27 grammar Kotlin fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/Greeter.kt", kotlin_fixture);
    defer freeResult(result);

    try expectRoleAt(result, kotlin_fixture, "// Greets a user.", .comment);
    try expectRoleAt(result, kotlin_fixture, "\"hi \"", .string);
    try expectRoleAt(result, kotlin_fixture, "class", .keyword);
    try expectRoleAt(result, kotlin_fixture, "fun", .keyword);
    try expectRoleAt(result, kotlin_fixture, "return", .keyword);
    try expectRoleAt(result, kotlin_fixture, "greet(", .function);
    try expectRoleAt(result, kotlin_fixture, "Greeter", .type);
    try expectRoleAt(result, kotlin_fixture, "String", .type);
}

const groovy_fixture =
    \\// Greets a user.
    \\class Greeter {
    \\    String greet(String name) {
    \\        return "hi " + name
    \\    }
    \\}
    \\println(new Greeter().greet("you"))
    \\
;

test "M27 grammar Groovy fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "build.gradle", groovy_fixture);
    defer freeResult(result);

    try expectRoleAt(result, groovy_fixture, "// Greets a user.", .comment);
    try expectRoleAt(result, groovy_fixture, "\"hi \"", .string);
    try expectRoleAt(result, groovy_fixture, "class", .keyword);
    try expectRoleAt(result, groovy_fixture, "return", .keyword);
    try expectRoleAt(result, groovy_fixture, "greet(", .function);
    try expectRoleAt(result, groovy_fixture, "Greeter", .type);
    try expectRoleAt(result, groovy_fixture, "String", .type);
}

const c_sharp_fixture =
    \\// Greets a user.
    \\namespace Demo {
    \\    public class Greeter {
    \\        public string Greet(string name) {
    \\            return "hi " + name;
    \\        }
    \\    }
    \\}
    \\
;

test "M27 grammar C# fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/Greeter.cs", c_sharp_fixture);
    defer freeResult(result);

    try expectRoleAt(result, c_sharp_fixture, "// Greets a user.", .comment);
    try expectRoleAt(result, c_sharp_fixture, "\"hi \"", .string);
    try expectRoleAt(result, c_sharp_fixture, "namespace", .keyword);
    try expectRoleAt(result, c_sharp_fixture, "class", .keyword);
    try expectRoleAt(result, c_sharp_fixture, "return", .keyword);
    try expectRoleAt(result, c_sharp_fixture, "Greet(", .function);
    try expectRoleAt(result, c_sharp_fixture, "Greeter", .type);
    try expectRoleAt(result, c_sharp_fixture, "string", .type);
}

test "M27 grammar C# namespace module Capture has the type role" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/Greeter.cs", c_sharp_fixture);
    defer freeResult(result);

    try expectSpan(result, 2, 10, 14, "module");
}

// M27 ticket 06 fixtures

test "M27 grammar GrammarMatch selects Python and Ruby by name, extension, and shebang" {
    const cases = [_]struct { path: []const u8, content: []const u8 = "", grammar: ?BuiltInGrammar }{
        .{ .path = "src/a.py", .grammar = .python },
        .{ .path = "stubs/a.pyi", .grammar = .python },
        .{ .path = "lib/a.rb", .grammar = .ruby },
        .{ .path = "bbr.gemspec", .grammar = .ruby },
        .{ .path = "Gemfile", .grammar = .ruby },
        .{ .path = "app/Rakefile", .grammar = .ruby },
        .{ .path = "scripts/run", .content = "#!/usr/bin/env python3\n", .grammar = .python },
        .{ .path = "scripts/run", .content = "#!/usr/bin/python3.12\n", .grammar = .python },
        .{ .path = "scripts/run", .content = "#!/usr/bin/env -S python3 -u\n", .grammar = .python },
        .{ .path = "scripts/run", .content = "#!/usr/bin/ruby\n", .grammar = .ruby },
        .{ .path = "Gemfile.lock", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, case.content));
}

test "M27 grammar Python and Ruby fence and Injection names select their BuiltInGrammars" {
    const cases = [_]struct { []const u8, BuiltInGrammar }{
        .{ "python", .python }, .{ "py", .python }, .{ "python3", .python },
        .{ "Python", .python }, .{ "ruby", .ruby }, .{ "rb", .ruby },
    };
    for (cases) |case| try testing.expectEqual(case[1], grammar_match.selectInjection(case[0]).?);
}

const python_fixture =
    \\#!/usr/bin/env python3
    \\# Adds one.
    \\def add(a):
    \\    return a + MAX
    \\name = "py"
    \\flag = None
    \\
;

test "M27 grammar Python fixture has shebang, comment, string, keyword, function, and constant roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "scripts/run", python_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 22, "keyword");
    try expectSpan(result, 2, 0, 11, "comment");
    try expectSpan(result, 3, 0, 3, "keyword");
    try expectSpan(result, 3, 4, 7, "function");
    try expectSpan(result, 4, 4, 10, "keyword");
    try expectSpan(result, 4, 15, 18, "constant");
    try expectSpan(result, 5, 7, 11, "string");
    try expectSpan(result, 6, 7, 11, "constant");
}

const ruby_fixture =
    \\#!/usr/bin/ruby
    \\# Adds one.
    \\def add(a)
    \\  a + MAX
    \\end
    \\name = "rb"
    \\flag = nil
    \\
;

test "M27 grammar Ruby fixture has comment, string, keyword, function, and constant roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "lib/add.rb", ruby_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 15, "keyword");
    try expectSpan(result, 2, 0, 11, "comment");
    try expectSpan(result, 3, 0, 3, "keyword");
    try expectSpan(result, 3, 4, 7, "function");
    try expectSpan(result, 4, 6, 9, "constant");
    try expectSpan(result, 5, 0, 3, "keyword");
    try expectSpan(result, 6, 7, 11, "string");
    try expectSpan(result, 7, 7, 10, "constant");
}

// M27 ticket 07 fixtures

const swift_fixture =
    \\// Greets a user.
    \\struct Point { let x: Int }
    \\func greet(name: String) -> String {
    \\    return "hello"
    \\}
    \\
;

test "M27 grammar Swift fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "Sources/App.swift", swift_fixture);
    defer freeResult(result);

    try expectRoleAt(result, swift_fixture, "// Greets a user.", .comment);
    try expectRoleAt(result, swift_fixture, "\"hello\"", .string);
    try expectRoleAt(result, swift_fixture, "struct", .keyword);
    try expectRoleAt(result, swift_fixture, "func", .keyword);
    try expectRoleAt(result, swift_fixture, "return", .keyword);
    try expectRoleAt(result, swift_fixture, "greet", .function);
    try expectRoleAt(result, swift_fixture, "Point", .type);
    try expectRoleAt(result, swift_fixture, "String", .type);
}

const sql_fixture =
    \\-- Lists active users.
    \\CREATE TABLE users (id INT);
    \\SELECT count(id) FROM users WHERE name = 'bob';
    \\
;

test "M27 grammar SQL fixture has comment, string, keyword, function, and type roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "db/migrations/001_users.sql", sql_fixture);
    defer freeResult(result);

    try expectRoleAt(result, sql_fixture, "-- Lists active users.", .comment);
    try expectRoleAt(result, sql_fixture, "'bob'", .string);
    try expectRoleAt(result, sql_fixture, "CREATE", .keyword);
    try expectRoleAt(result, sql_fixture, "SELECT", .keyword);
    try expectRoleAt(result, sql_fixture, "WHERE", .keyword);
    try expectRoleAt(result, sql_fixture, "count", .function);
    try expectRoleAt(result, sql_fixture, "INT", .type);
}

test "M27 grammar GrammarMatch selects Swift and SQL" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "Sources/App/App.swift", .grammar = .swift },
        .{ .path = "Package.swift", .grammar = .swift },
        .{ .path = "db/migrations/001_users.sql", .grammar = .sql },
        .{ .path = "db/schema.SQL", .grammar = null },
        .{ .path = "notes/a.swiftinterface", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
}

// M27 ticket 08 fixtures

const toml_fixture =
    \\# Settings.
    \\[package]
    \\name = "bbr"
    \\ready = true
    \\
;

const dockerfile_fixture =
    \\# Base image.
    \\FROM alpine:3.20 AS build
    \\ENV MODE="release"
    \\RUN <<EOF
    \\echo ${MODE}
    \\EOF
    \\
;

const make_fixture = "# Build all.\ninclude rules.mk\nCC := gcc\nall: main.o\n\t@$(CC) -o $@ $^\n";

test "M27 grammar GrammarMatch selects TOML, Dockerfile, and Make" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "Cargo.toml", .grammar = .toml },
        .{ .path = "Dockerfile", .grammar = .dockerfile },
        .{ .path = "Containerfile", .grammar = .dockerfile },
        .{ .path = "app.dockerfile", .grammar = .dockerfile },
        .{ .path = "docker/Dockerfile", .grammar = .dockerfile },
        .{ .path = "Dockerfile.dev", .grammar = null },
        .{ .path = "dockerfile", .grammar = null },
        .{ .path = "Makefile", .grammar = .make },
        .{ .path = "makefile", .grammar = .make },
        .{ .path = "GNUmakefile", .grammar = .make },
        .{ .path = "build/rules.mk", .grammar = .make },
        .{ .path = "Makefile.am", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
}

test "M27 grammar TOML fixture has comment, string, keyword, property, and constant roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "Cargo.toml", toml_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 11, "comment");
    try expectSpan(result, 3, 7, 12, "string");
    try expectSpan(result, 3, 5, 6, "operator");
    try expectSpan(result, 3, 0, 4, "property");
    try expectSpan(result, 4, 8, 12, "boolean");
}

test "M27 grammar Dockerfile fixture has comment, string, keyword, and property roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "Dockerfile", dockerfile_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 13, "comment");
    try expectSpan(result, 2, 0, 4, "keyword");
    try expectSpan(result, 2, 17, 19, "keyword");
    try expectSpan(result, 3, 0, 3, "keyword");
    try expectSpan(result, 3, 4, 8, "property");
    try expectSpan(result, 3, 9, 18, "string");
    try expectSpan(result, 5, 0, 12, "string");
}

test "M27 grammar Make fixture has comment, string, keyword, and function roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "Makefile", make_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 12, "comment");
    try expectSpan(result, 2, 0, 7, "keyword");
    try expectSpan(result, 2, 8, 16, "string");
    try expectSpan(result, 3, 0, 2, "string");
    try expectSpan(result, 4, 0, 3, "function");
    try expectSpan(result, 5, 11, 12, "operator");
    try expectSpan(result, 5, 12, 13, "string");
}

test "M27 grammar Make set priority 105 beats a later pattern at default priority" {
    const query = embeddedQuery(.make, "highlights") ++ "\n[(automatic_variable) (variable_reference)] @variable\n";
    const result = try highlightWithQuery(testing.allocator, language(.make).?, query, "", make_fixture);
    defer freeResult(result);

    try expectRoleAt(result, make_fixture, "$(CC)", .variable);
    try expectSpan(result, 5, 11, 12, "operator");
}

test "M27 grammar Dockerfile set priority 90 loses to an earlier pattern at default priority" {
    const query = "[(heredoc_line) (double_quoted_string)] @comment\n" ++ embeddedQuery(.dockerfile, "highlights");
    const result = try highlightWithQuery(testing.allocator, language(.dockerfile).?, query, "", dockerfile_fixture);
    defer freeResult(result);

    try expectSpan(result, 3, 9, 18, "string");
    try expectSpan(result, 5, 0, 12, "comment");
}

test "M27 injection docker and make names select the Dockerfile and Make BuiltInGrammars" {
    const cases = [_]struct { name: []const u8, grammar: BuiltInGrammar }{
        .{ .name = "docker", .grammar = .dockerfile },
        .{ .name = "dockerfile", .grammar = .dockerfile },
        .{ .name = "Dockerfile", .grammar = .dockerfile },
        .{ .name = "make", .grammar = .make },
        .{ .name = "makefile", .grammar = .make },
        .{ .name = "toml", .grammar = .toml },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectInjection(case.name).?);
}

test "M27 grammar docker and make ReviewBody fences highlight with the new BuiltInGrammars" {
    const cases = [_]struct { fence: []const u8, path: []const u8 }{
        .{ .fence = "docker", .path = "review.dockerfile" },
        .{ .fence = "dockerfile", .path = "review.dockerfile" },
        .{ .fence = "make", .path = "review.mk" },
        .{ .fence = "makefile", .path = "review.mk" },
    };
    for (cases) |case| try testing.expectEqualStrings(case.path["review.".len..], bbr.highlight.grammar_name.extension(case.fence).?);

    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const dockerfile = try highlighter.highlighter().highlight(testing.allocator, "review.dockerfile", dockerfile_fixture);
    defer freeResult(dockerfile);
    try expectSpan(dockerfile, 2, 0, 4, "keyword");
    const make = try highlighter.highlighter().highlight(testing.allocator, "review.mk", make_fixture);
    defer freeResult(make);
    try expectSpan(make, 4, 0, 3, "function");
    const toml = try highlighter.highlighter().highlight(testing.allocator, "review.toml", toml_fixture);
    defer freeResult(toml);
    try expectSpan(toml, 3, 7, 12, "string");
}

// M27 ticket 09 fixtures
const html_fixture =
    \\<!-- note -->
    \\<a href="x" style="color: red">hi</a>
    \\<script>let n = 1;</script>
    \\<style>p { color: blue; }</style>
    \\
;

const xml_fixture =
    \\<?xml version="1.0"?>
    \\<!-- note -->
    \\<svg width="10"><rect/></svg>
    \\
;

test "M27 grammar GrammarMatch selects HTML and XML" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "web/index.html", .grammar = .html },
        .{ .path = "web/index.htm", .grammar = .html },
        .{ .path = "data/feed.xml", .grammar = .xml },
        .{ .path = "assets/logo.svg", .grammar = .xml },
        .{ .path = "web/index.xhtml", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
}

test "M27 grammar HTML fixture has tag, property, string, and comment roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.html", html_fixture);
    defer freeResult(result);

    try expectSpan(result, 1, 0, 13, "comment");
    try expectSpan(result, 2, 1, 2, "tag");
    try expectSpan(result, 2, 3, 7, "tag.attribute");
    try expectSpan(result, 2, 8, 9, "string");
    try expectSpan(result, 2, 9, 10, "string.special.url");
    try expectSpan(result, 2, 35, 36, "tag");
}

test "M27 grammar XML fixture has tag, property, string, and comment roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "assets/logo.svg", xml_fixture);
    defer freeResult(result);

    try expectSpan(result, 2, 0, 13, "comment");
    try expectSpan(result, 3, 1, 4, "tag");
    try expectSpan(result, 3, 5, 10, "tag.attribute");
    try expectSpan(result, 3, 12, 14, "string");
    try expectSpan(result, 3, 17, 21, "tag");
}

test "M27 injection HTML script and style content get JavaScript and CSS Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.html", html_fixture);
    defer freeResult(result);
    const javascript = &highlighter.packages[@intFromEnum(BuiltInGrammar.javascript)];
    const css = &highlighter.packages[@intFromEnum(BuiltInGrammar.css)];

    try expectSpan(result, 3, 8, 11, "keyword");
    try testing.expectEqual(packageCapture(javascript, "keyword"), captureOver(result, html_fixture, std.mem.indexOf(u8, html_fixture, "let").?).?);
    try expectSpan(result, 4, 7, 8, "tag");
    try expectSpan(result, 4, 11, 16, "property");
    try testing.expectEqual(packageCapture(css, "property"), captureOver(result, html_fixture, std.mem.indexOf(u8, html_fixture, "color: blue").?).?);
}

test "M27 injection HTML style attribute value gets CSS Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.html", html_fixture);
    defer freeResult(result);
    const css = &highlighter.packages[@intFromEnum(BuiltInGrammar.css)];

    // tree-sitter-css parses a bare declaration as a selector, so `color` gets the CSS tag Capture, as in Neovim.
    try expectSpan(result, 2, 19, 24, "tag");
    try testing.expectEqual(packageCapture(css, "tag"), captureOver(result, html_fixture, std.mem.indexOf(u8, html_fixture, "color: red").?).?);
}

test "M27 injection HTML script type selects JavaScript or JSON" {
    const source =
        \\<script type="text/javascript">let a = 1;</script>
        \\<script type="module">let b = 2;</script>
        \\<script type="importmap">{"imports": {}}</script>
        \\
    ;
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.html", source);
    defer freeResult(result);
    const javascript = &highlighter.packages[@intFromEnum(BuiltInGrammar.javascript)];
    const json = &highlighter.packages[@intFromEnum(BuiltInGrammar.json)];

    try expectSpan(result, 1, 31, 34, "keyword");
    try testing.expectEqual(packageCapture(javascript, "keyword"), captureOver(result, source, std.mem.indexOf(u8, source, "let a").?).?);
    try expectSpan(result, 2, 22, 25, "keyword");
    try testing.expectEqual(packageCapture(javascript, "keyword"), captureOver(result, source, std.mem.indexOf(u8, source, "let b").?).?);
    try testing.expect(!std.meta.eql(packageCapture(json, "string"), packageCapture(javascript, "string")));
    try expectSpan(result, 3, 26, 35, "string");
    try testing.expectEqual(packageCapture(json, "string"), captureOver(result, source, std.mem.indexOf(u8, source, "\"imports\"").?).?);
}

test "M27 grammar a highlight pattern without Captures produces no Span and no failure" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    try useJavaScriptQueries(&highlighter, "(identifier)\n(number) @number", "", "");
    const source = "let n = 1;\n";
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    try testing.expectEqual(@as(usize, 1), result.spans.len);
    try expectSpan(result, 1, 8, 9, "number");
}

// M27 ticket 10 fixtures
const markdown_fixture =
    \\---
    \\title: x
    \\---
    \\# Title
    \\
    \\Use `code` and [link](https://a.b) and *em*.
    \\
    \\- item
    \\
    \\```zig
    \\const a = 1;
    \\```
    \\
    \\```js
    \\let b = 2;
    \\```
    \\
    \\```nope
    \\let c = 3;
    \\```
    \\
    \\> ```zig
    \\> const d = 4;
    \\> ```
    \\
    \\<div class="x">
    \\</div>
    \\
    \\Text <b>bold</b> end.
    \\
    \\| h |
    \\| --- |
    \\| `b` |
    \\
;

fn markdownCaptureAt(result: bbr.highlight.HighlightResult, line: u32, column: usize) ?bbr.highlight.Capture {
    var line_start: usize = 0;
    for (1..line) |_| line_start = std.mem.indexOfScalarPos(u8, markdown_fixture, line_start, '\n').? + 1;
    return captureOver(result, markdown_fixture, line_start + column);
}

test "M27 grammar GrammarMatch selects Markdown and no path selects Markdown inline" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "README.md", .grammar = .markdown },
        .{ .path = "docs/guide.markdown", .grammar = .markdown },
        .{ .path = "docs/inline.markdown_inline", .grammar = null },
        .{ .path = "markdown_inline", .grammar = null },
        .{ .path = "docs/page.mdx", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
    try testing.expectEqual(@as(?BuiltInGrammar, null), grammar_match.selectBuiltIn("notes", "#!/usr/bin/env markdown_inline\n"));
}

test "M27 grammar Markdown fixture has keyword, punctuation, and string roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const markdown = &highlighter.packages[@intFromEnum(BuiltInGrammar.markdown)];

    try expectSpan(result, 4, 0, 7, "keyword");
    try testing.expectEqual(packageCapture(markdown, "markup.heading.1"), markdownCaptureAt(result, 4, 0).?);
    try expectSpan(result, 8, 0, 2, "punctuation");
    try testing.expectEqual(packageCapture(markdown, "markup.list"), markdownCaptureAt(result, 8, 0).?);
    try expectSpan(result, 10, 0, 3, "string");
    try expectSpan(result, 22, 0, 2, "punctuation");
    try expectSpan(result, 32, 0, 1, "punctuation");
}

test "M27 injection Markdown inline gives inline code and links the string role and keeps emphasis default" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const inline_package = &highlighter.packages[@intFromEnum(BuiltInGrammar.markdown_inline)];

    try expectSpan(result, 6, 4, 10, "string");
    try testing.expectEqual(packageCapture(inline_package, "markup.raw"), markdownCaptureAt(result, 6, 4).?);
    try expectSpan(result, 6, 16, 20, "string");
    try testing.expectEqual(packageCapture(inline_package, "markup.link.label"), markdownCaptureAt(result, 6, 16).?);
    try expectSpan(result, 6, 22, 33, "string");
    try testing.expectEqual(packageCapture(inline_package, "markup.link.url"), markdownCaptureAt(result, 6, 22).?);
    try expectSpan(result, 6, 39, 43, "markup.italic");
    try testing.expectEqual(bbr.highlight.CaptureRole.unknown, markdownCaptureAt(result, 6, 39).?.role);
}

test "M27 injection Markdown pipe table cells get Markdown inline Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const inline_package = &highlighter.packages[@intFromEnum(BuiltInGrammar.markdown_inline)];

    try expectSpan(result, 33, 2, 5, "string");
    try testing.expectEqual(packageCapture(inline_package, "markup.raw"), markdownCaptureAt(result, 33, 2).?);
}

test "M27 injection Markdown fenced zig and js blocks get Zig and JavaScript Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const zig = &highlighter.packages[@intFromEnum(BuiltInGrammar.zig)];
    const javascript = &highlighter.packages[@intFromEnum(BuiltInGrammar.javascript)];

    try expectSpan(result, 11, 0, 5, "keyword");
    try testing.expectEqual(packageCapture(zig, "keyword"), markdownCaptureAt(result, 11, 0).?);
    try expectSpan(result, 15, 0, 3, "keyword");
    try testing.expectEqual(packageCapture(javascript, "keyword"), markdownCaptureAt(result, 15, 0).?);
}

test "M27 injection Markdown fenced block with an unknown info string has no injected Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const markdown = &highlighter.packages[@intFromEnum(BuiltInGrammar.markdown)];

    var line_spans: usize = 0;
    for (result.spans) |span| if (span.line == 19) {
        line_spans += 1;
        try testing.expectEqual(@as(u32, 0), span.start);
        try testing.expectEqual(@as(u32, 10), span.end);
        try testing.expectEqual(packageCapture(markdown, "markup.raw.block"), span.capture);
    };
    try testing.expectEqual(@as(usize, 1), line_spans);
}

test "M27 injection Markdown fenced block in a block quote has no injected Span on the quote marker" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const markdown = &highlighter.packages[@intFromEnum(BuiltInGrammar.markdown)];
    const zig = &highlighter.packages[@intFromEnum(BuiltInGrammar.zig)];

    try expectSpan(result, 23, 0, 2, "punctuation");
    try testing.expectEqual(packageCapture(markdown, "punctuation.special"), markdownCaptureAt(result, 23, 0).?);
    try testing.expectEqual(packageCapture(markdown, "punctuation.special"), markdownCaptureAt(result, 23, 1).?);
    try expectSpan(result, 23, 2, 7, "keyword");
    try testing.expectEqual(packageCapture(zig, "keyword"), markdownCaptureAt(result, 23, 2).?);
}

test "M27 injection Markdown HTML block and inline HTML get HTML Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const html = &highlighter.packages[@intFromEnum(BuiltInGrammar.html)];

    try expectSpan(result, 26, 1, 4, "tag");
    try testing.expectEqual(packageCapture(html, "tag"), markdownCaptureAt(result, 26, 1).?);
    try expectSpan(result, 26, 5, 10, "property");
    try expectSpan(result, 29, 6, 7, "tag");
    try testing.expectEqual(packageCapture(html, "tag"), markdownCaptureAt(result, 29, 6).?);
    try expectSpan(result, 29, 14, 15, "tag");
}

test "M27 injection Markdown YAML and TOML front matter get YAML and TOML Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const yaml_result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(yaml_result);
    const yaml = &highlighter.packages[@intFromEnum(BuiltInGrammar.yaml)];
    const toml = &highlighter.packages[@intFromEnum(BuiltInGrammar.toml)];

    try expectSpan(yaml_result, 2, 0, 5, "property");
    try testing.expectEqual(packageCapture(yaml, "property"), markdownCaptureAt(yaml_result, 2, 0).?);

    const toml_source = "+++\ntitle = \"x\"\n+++\n# Title\n";
    const toml_result = try highlighter.highlighter().highlight(testing.allocator, "README.md", toml_source);
    defer freeResult(toml_result);
    try expectSpan(toml_result, 2, 0, 5, "property");
    try testing.expectEqual(packageCapture(toml, "property"), captureOver(toml_result, toml_source, 4).?);
    try expectSpan(toml_result, 2, 8, 11, "string");
}

test "M27 injection Markdown fenced js block uses the JavaScript BuiltInGrammar when a UserGrammar claims .js" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "fixture", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/payload", .data = "not a library" });
    const manifest = try std.fmt.allocPrint(testing.allocator,
        \\name = "fixture"
        \\version = "1.0.0"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_fixture"
        \\library = "payload"
        \\highlight_query = "payload"
        \\[[payload]]
        \\path = "payload"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = [".js"]
        \\
    , .{ @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch), digestHex("not a library") });
    defer testing.allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/grammar.toml", .data = manifest });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/fixture", .{&tmp.sub_path});
    defer testing.allocator.free(path);
    var inspection = try user_grammar.inspect(testing.allocator, io, path);
    const digest = inspection.report.digest;
    inspection.deinit();
    const entries = [_]user_grammar.RegistryEntry{.{
        .name = "fixture",
        .path = path,
        .enabled = true,
        .trusted_digest = digest,
        .receipt = .{ .bundle_digest = digest, .bbr_identity = "test-build", .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION },
    }};
    var registry = try user_grammar.Registry.init(testing.allocator, io, &entries, &.{}, "test-build");
    defer registry.deinit();
    try testing.expectEqualStrings("fixture", registry.matchName("injection.js", "").?);
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, &registry);
    defer highlighter.deinit();

    const result = try highlighter.highlighter().highlight(testing.allocator, "README.md", markdown_fixture);
    defer freeResult(result);
    const javascript = &highlighter.packages[@intFromEnum(BuiltInGrammar.javascript)];
    try expectSpan(result, 15, 0, 3, "keyword");
    try testing.expectEqual(packageCapture(javascript, "keyword"), markdownCaptureAt(result, 15, 0).?);
}

// M27 ticket 11 fixtures

const php_fixture =
    \\<div class="greeting">
    \\<?php
    \\// Greets a name.
    \\function greet($name) {
    \\    return "<b>Hello</b> " . $name;
    \\}
    \\?>
    \\<p>Done</p>
    \\<script>let a = 1;</script>
    \\
;

const php_heredoc_fixture =
    \\<?php
    \\$page = <<<HTML
    \\<em class="note">Hi</em>
    \\HTML;
    \\
;

const php_split_tag_fixture =
    \\<a href="<?php echo $url; ?>">Go</a>
    \\
;

test "M27 grammar GrammarMatch selects PHP" {
    const cases = [_]struct { path: []const u8, grammar: ?BuiltInGrammar }{
        .{ .path = "web/index.php", .grammar = .php },
        .{ .path = "web/INDEX.PHP", .grammar = null },
        .{ .path = "web/index.phtml", .grammar = null },
    };
    for (cases) |case| try testing.expectEqual(case.grammar, grammar_match.selectBuiltIn(case.path, ""));
}

test "M27 grammar PHP fixture has comment, string, keyword, function, and variable roles" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.php", php_fixture);
    defer freeResult(result);

    try expectSpan(result, 3, 0, 17, "comment");
    try expectSpan(result, 4, 0, 8, "keyword");
    try expectSpan(result, 4, 9, 14, "function");
    try expectSpan(result, 4, 15, 20, "variable");
    try expectSpan(result, 5, 4, 10, "keyword");
    try expectSpan(result, 5, 11, 26, "string");
    try expectSpan(result, 5, 29, 34, "variable");
}

test "M27 injection PHP text around the PHP code gets HTML Spans and the PHP code gets none" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.php", php_fixture);
    defer freeResult(result);
    const html = &highlighter.packages[@intFromEnum(BuiltInGrammar.html)];
    const php = &highlighter.packages[@intFromEnum(BuiltInGrammar.php)];

    try expectSpan(result, 1, 1, 4, "tag");
    try testing.expectEqual(packageCapture(html, "tag"), captureOver(result, php_fixture, std.mem.indexOf(u8, php_fixture, "div").?).?);
    try expectSpan(result, 8, 1, 2, "tag");
    try testing.expectEqual(packageCapture(html, "tag"), captureOver(result, php_fixture, std.mem.indexOf(u8, php_fixture, "p>Done").?).?);
    try expectSpan(result, 5, 11, 26, "string");
    try testing.expectEqual(packageCapture(php, "string"), captureOver(result, php_fixture, std.mem.indexOf(u8, php_fixture, "<b>").?).?);
    for (result.spans) |span| {
        if (span.line >= 2 and span.line <= 7) try testing.expect(span.capture.role != .tag);
    }
}

test "M27 injection PHP script reaches JavaScript through the HTML Injection" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.php", php_fixture);
    defer freeResult(result);
    const javascript = &highlighter.packages[@intFromEnum(BuiltInGrammar.javascript)];

    try expectSpan(result, 9, 8, 11, "keyword");
    try testing.expectEqual(packageCapture(javascript, "keyword"), captureOver(result, php_fixture, std.mem.indexOf(u8, php_fixture, "let").?).?);
}

test "M27 injection PHP heredoc with the closing name HTML gets HTML Spans" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.php", php_heredoc_fixture);
    defer freeResult(result);
    const html = &highlighter.packages[@intFromEnum(BuiltInGrammar.html)];

    try expectSpan(result, 3, 1, 3, "tag");
    try testing.expectEqual(packageCapture(html, "tag"), captureOver(result, php_heredoc_fixture, std.mem.indexOf(u8, php_heredoc_fixture, "em").?).?);
    try expectSpan(result, 3, 4, 9, "tag.attribute");
    try testing.expectEqual(packageCapture(html, "tag.attribute"), captureOver(result, php_heredoc_fixture, std.mem.indexOf(u8, php_heredoc_fixture, "class").?).?);
}

test "M27 injection PHP joins the HTML text around PHP code into one combined HTML tree" {
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null);
    defer highlighter.deinit();
    const result = try highlighter.highlighter().highlight(testing.allocator, "web/index.php", php_split_tag_fixture);
    defer freeResult(result);
    const html = &highlighter.packages[@intFromEnum(BuiltInGrammar.html)];

    try expectSpan(result, 1, 15, 19, "keyword");
    try expectSpan(result, 1, 28, 29, "string");
    try testing.expectEqual(packageCapture(html, "string"), captureOver(result, php_split_tag_fixture, 28).?);
    try expectSpan(result, 1, 34, 35, "tag");
    try testing.expectEqual(packageCapture(html, "tag"), captureOver(result, php_split_tag_fixture, 34).?);
}
