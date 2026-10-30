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

extern fn tree_sitter_javascript() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_typescript() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_tsx() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_css() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_go() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_bash() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_json() callconv(.c) ?*const c.TSLanguage;
extern fn tree_sitter_yaml() callconv(.c) ?*const c.TSLanguage;

const javascript_query = @embedFile("javascript_highlights");
const typescript_query = @embedFile("typescript_highlights");
const tsx_query = @embedFile("tsx_highlights");
const css_query = @embedFile("css_highlights");
const go_query = @embedFile("go_highlights");
const bash_query = @embedFile("bash_highlights");
const json_query = @embedFile("json_highlights");
const yaml_query = @embedFile("yaml_highlights");
const javascript_locals_query = @embedFile("javascript_locals");
const typescript_locals_query = @embedFile("typescript_locals");
const combined_typescript_query = javascript_query ++ "\n" ++ typescript_query;
const combined_tsx_query = javascript_query ++ "\n" ++ tsx_query;
const combined_typescript_locals_query = javascript_locals_query ++ "\n" ++ typescript_locals_query;

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

fn grammarSource(selected: grammar_match.BuiltInGrammar) ?GrammarSource {
    return switch (selected) {
        .tsx => .{ .language = tree_sitter_tsx() orelse return null, .query = combined_tsx_query, .locals_query = combined_typescript_locals_query },
        .typescript => .{ .language = tree_sitter_typescript() orelse return null, .query = combined_typescript_query, .locals_query = combined_typescript_locals_query },
        .javascript => .{ .language = tree_sitter_javascript() orelse return null, .query = javascript_query, .locals_query = javascript_locals_query },
        .css => .{ .language = tree_sitter_css() orelse return null, .query = css_query },
        .go => .{ .language = tree_sitter_go() orelse return null, .query = go_query },
        .bash => .{ .language = tree_sitter_bash() orelse return null, .query = bash_query },
        .json => .{ .language = tree_sitter_json() orelse return null, .query = json_query },
        .yaml => .{ .language = tree_sitter_yaml() orelse return null, .query = yaml_query },
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
        const captures = match.captures[0..match.capture_count];
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
            for (layer.ranges) |included| {
                const start = @max(interval.start, included.start_byte);
                const end = @min(interval.end, included.end_byte);
                if (start >= end) continue;
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
        for (match.captures[0..match.capture_count]) |capture| {
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
    for (parent.ranges) |included| {
        const clipped_start = @max(start, included.start_byte);
        const clipped_end = @min(end, included.end_byte);
        if (clipped_start < clipped_end) try ranges.append(allocator, lines.range(clipped_start, clipped_end));
    }
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
    var cluster_start: usize = 0;
    // ponytail: Grammar overlap is shallow; use a priority heap if profiles show deep overlap.
    while (cluster_start < intervals.len) {
        var cluster_end = intervals[cluster_start].end;
        var cluster_limit = cluster_start + 1;
        while (cluster_limit < intervals.len and intervals[cluster_limit].start < cluster_end) : (cluster_limit += 1) {
            cluster_end = @max(cluster_end, intervals[cluster_limit].end);
        }
        const cluster = intervals[cluster_start..cluster_limit];
        var position = cluster[0].start;
        while (position < cluster_end) {
            var winner: ?CaptureInterval = null;
            var next_start = cluster_end;
            for (cluster) |interval| {
                if (interval.start > position) {
                    next_start = @min(next_start, interval.start);
                } else if (interval.end > position and (winner == null or higherPrecedence({}, interval, winner.?) == .lt)) {
                    winner = interval;
                }
            }
            if (winner) |selected| {
                const end = @min(selected.end, next_start);
                try appendIntervalSpans(allocator, &spans, content, &line_state, position, end, selected.capture);
                position = end;
            } else {
                position = next_start;
            }
        }
        cluster_start = cluster_limit;
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
    try testing.expect(grammar_match.selectBuiltIn("src/a.zig", "") == null);
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

test "match predicate filters one match and preserves fallback Capture" {
    const query =
        \\(identifier) @variable
        \\((identifier) @constructor (#match? @constructor "^[A-Z]"))
    ;
    const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", "lower Upper\n");
    defer freeResult(result);

    try expectSpan(result, 1, 0, 5, "variable");
    try expectSpan(result, 1, 6, 11, "constructor");
}

test "eq predicate filters one match and preserves later-pattern precedence" {
    const query =
        \\(identifier) @variable
        \\((identifier) @function.builtin (#eq? @function.builtin "require"))
    ;
    const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", "require other\n");
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
        const grammar_language = tree_sitter_javascript().?;
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
    const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", "function () {}\n");
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
        tree_sitter_javascript().?,
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
    const query = c.ts_query_new(tree_sitter_javascript().?, source.ptr, @intCast(source.len), &query_error_offset, &query_error_type).?;
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
    const invalid_query = c.ts_query_new(tree_sitter_javascript().?, invalid_source.ptr, @intCast(invalid_source.len), &query_error_offset, &query_error_type).?;
    defer c.ts_query_delete(invalid_query);
    var diagnostic: predicate_mod.Diagnostic = undefined;
    try testing.expectError(error.InvalidPredicate, predicate_mod.Set.validate(testing.allocator, invalid_query, invalid_source, &diagnostic));
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, invalid_source, "(?=x)").?)), diagnostic.source_offset);

    const duplicate_source =
        \\((identifier) @x (#match? @x "^x"))
        \\((identifier) @y (#match? @y "^x"))
    ;
    const duplicate_query = c.ts_query_new(tree_sitter_javascript().?, duplicate_source.ptr, @intCast(duplicate_source.len), &query_error_offset, &query_error_type).?;
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
    const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", "a === a; b === c;\n");
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
        const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", case.source);
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
    const later_wins = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, "(identifier) @keyword\n(identifier) @variable", "", source);
    defer freeResult(later_wins);
    try expectRoleAt(later_wins, source, "alpha", .variable);

    for ([_][]const u8{
        "((identifier) @keyword (#set! priority 101))\n(identifier) @variable",
        "((identifier) @keyword (#set! \"priority\" 101))\n(identifier) @variable",
        "(identifier) @keyword\n((identifier) @variable (#set! priority 99))",
    }) |query| {
        const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", source);
        defer freeResult(result);
        try expectRoleAt(result, source, "alpha", .keyword);
    }
}

test "M27 grammar a hidden Capture produces no Span and still filters" {
    const hidden_only = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, "(identifier) @_name", "", "alpha;\n");
    defer freeResult(hidden_only);
    try testing.expectEqual(@as(usize, 0), hidden_only.spans.len);

    const query =
        \\(call_expression
        \\  function: (identifier) @_callee
        \\  arguments: (arguments (identifier) @keyword)
        \\  (#eq? @_callee "alpha"))
    ;
    const source = "alpha(beta); gamma(delta);\n";
    const result = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?, query, "", source);
    defer freeResult(result);
    try testing.expectEqual(@as(usize, 1), result.spans.len);
    try expectRoleAt(result, source, "beta", .keyword);
}

test "M27 grammar a predicate on an absent optional Capture behaves like Neovim" {
    const source = "alpha(); beta(y); gamma(x);\n";
    const positive = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?,
        \\(call_expression function: (identifier) @keyword arguments: (arguments (identifier)? @_arg) (#eq? @_arg "x"))
    , "", source);
    defer freeResult(positive);
    try expectRoleAt(positive, source, "alpha", .keyword);
    try testing.expectEqual(null, captureOver(positive, source, std.mem.indexOf(u8, source, "beta").?));
    try expectRoleAt(positive, source, "gamma", .keyword);

    const negated = try highlightWithQuery(testing.allocator, tree_sitter_javascript().?,
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
    const language = tree_sitter_javascript().?;
    const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, language)) return error.IncompatibleGrammar;
    const source = "x\n";
    const tree = c.ts_parser_parse_string(parser, null, source.ptr, source.len) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var diagnostic: predicate_mod.Diagnostic = undefined;
    try testing.expectError(expected_error, predicate_mod.Locals.collect(testing.allocator, language, tree, locals_query, source, &diagnostic));
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
    const replacement = try RuntimePackage.init(testing.allocator, tree_sitter_javascript().?, highlight_query, locals_query, injections_query, &diagnostic);
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
