const std = @import("std");
const regex_mod = @import("query_regex.zig");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Diagnostic = struct {
    kind: Kind,
    source_offset: u32,
    line: u32,
    column: u32,
    regex_failure: ?regex_mod.CompileFailure = null,

    pub const Kind = enum {
        unknown_operator,
        unsupported_directive,
        malformed_arguments,
        invalid_regex,
        unsupported_property,
    };

    pub fn report(self: Diagnostic) void {
        if (self.regex_failure) |failure| {
            std.log.err("highlight-query:{d}:{d}: invalid #match? expression for {s}: {s}", .{ self.line, self.column, regex_mod.engine, @tagName(failure.reason) });
            std.log.err("engine-code: {d}; engine-fragment: {s}; dialect: {s}", .{ failure.engine_code, failure.fragment(), regex_mod.dialect });
        } else {
            std.log.err("highlight-query:{d}:{d}: invalid predicate: {s}", .{ self.line, self.column, @tagName(self.kind) });
        }
    }
};

const Predicate = union(enum) {
    match: struct { capture: u32, regex_index: usize },
    eq_string: struct { capture: u32, value: []const u8 },
    eq_capture: struct { left: u32, right: u32 },
    local,
};

const Range = struct { start: usize, end: usize };

pub const Locals = struct {
    ranges: []Range,

    pub fn collect(allocator: Allocator, grammar_language: *const c.TSLanguage, tree: *const c.TSTree, query_source: []const u8, content: []const u8) !Locals {
        if (query_source.len == 0) return .{ .ranges = &.{} };
        var query_error_offset: u32 = 0;
        var query_error_type: c.TSQueryError = undefined;
        const query = c.ts_query_new(grammar_language, query_source.ptr, @intCast(query_source.len), &query_error_offset, &query_error_type) orelse return error.InvalidLocalsQuery;
        defer c.ts_query_delete(query);
        const cursor = c.ts_query_cursor_new() orelse return error.QueryCursorInitFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));

        const scope_id = captureId(query, "local.scope");
        const definition_id = captureId(query, "local.definition");
        const reference_id = captureId(query, "local.reference");
        var scopes: std.ArrayList(Scope) = .empty;
        defer {
            for (scopes.items) |*scope| scope.definitions.deinit(allocator);
            scopes.deinit(allocator);
        }
        try scopes.append(allocator, .{ .end = content.len });
        var ranges: std.ArrayList(Range) = .empty;
        errdefer ranges.deinit(allocator);

        var match: c.TSQueryMatch = undefined;
        var capture_index: u32 = 0;
        while (c.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
            const capture = match.captures[capture_index];
            const range = try nodeRange(capture.node, content);
            while (scopes.items.len > 1 and range.start > scopes.items[scopes.items.len - 1].end) {
                var scope = scopes.pop().?;
                scope.definitions.deinit(allocator);
            }
            if (scope_id != null and capture.index == scope_id.?) {
                try scopes.append(allocator, .{ .end = range.end });
            } else if (definition_id != null and capture.index == definition_id.?) {
                try scopes.items[scopes.items.len - 1].definitions.append(allocator, .{ .name = content[range.start..range.end], .end = range.end });
                try appendUniqueRange(allocator, &ranges, range);
            } else if (reference_id != null and capture.index == reference_id.?) {
                const name = content[range.start..range.end];
                var scope_index = scopes.items.len;
                while (scope_index > 0) {
                    scope_index -= 1;
                    const definitions = scopes.items[scope_index].definitions.items;
                    var definition_index = definitions.len;
                    while (definition_index > 0) {
                        definition_index -= 1;
                        const definition = definitions[definition_index];
                        if (range.start >= definition.end and std.mem.eql(u8, name, definition.name)) {
                            try appendUniqueRange(allocator, &ranges, range);
                            scope_index = 0;
                            break;
                        }
                    }
                }
            }
        }
        if (c.ts_query_cursor_did_exceed_match_limit(cursor)) return error.QueryMatchLimitExceeded;
        return .{ .ranges = try ranges.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: Locals, allocator: Allocator) void {
        if (self.ranges.len != 0) allocator.free(self.ranges);
    }

    fn contains(self: Locals, range: Range) bool {
        for (self.ranges) |local| if (local.start == range.start and local.end == range.end) return true;
        return false;
    }
};

const Definition = struct { name: []const u8, end: usize };
const Scope = struct {
    end: usize,
    definitions: std.ArrayList(Definition) = .empty,
};

pub const Set = struct {
    predicates: []Predicate,
    ranges: []Range,
    regexes: []regex_mod.Regex,

    pub fn validate(allocator: Allocator, query: *const c.TSQuery, source: []const u8, diagnostic: *Diagnostic) !Set {
        const pattern_count = c.ts_query_pattern_count(query);
        const ranges = try allocator.alloc(Range, pattern_count);
        errdefer allocator.free(ranges);
        var predicates: std.ArrayList(Predicate) = .empty;
        errdefer predicates.deinit(allocator);
        var regexes: std.ArrayList(regex_mod.Regex) = .empty;
        errdefer {
            for (regexes.items) |regex| regex.deinit();
            regexes.deinit(allocator);
        }
        var expressions: std.ArrayList([]const u8) = .empty;
        defer expressions.deinit(allocator);

        for (0..pattern_count) |pattern_usize| {
            const pattern: u32 = @intCast(pattern_usize);
            ranges[pattern_usize].start = predicates.items.len;
            var step_count: u32 = 0;
            const steps_ptr = c.ts_query_predicates_for_pattern(query, pattern, &step_count);
            if (step_count != 0) {
                const steps = steps_ptr[0..step_count];
                var at: usize = 0;
                var predicate_source_offset: usize = c.ts_query_start_byte_for_pattern(query, pattern);
                while (at < steps.len) {
                    var end = at;
                    while (end < steps.len and steps[end].type != c.TSQueryPredicateStepTypeDone) : (end += 1) {}
                    if (end == steps.len) return fail(source, query, pattern, diagnostic, .malformed_arguments, null);
                    const pattern_end = @min(c.ts_query_end_byte_for_pattern(query, pattern), source.len);
                    predicate_source_offset = findPredicateOffset(source, predicate_source_offset, pattern_end) orelse predicate_source_offset;
                    try parsePredicate(allocator, query, source, steps[at..end], predicate_source_offset, &predicates, &regexes, &expressions, diagnostic);
                    predicate_source_offset += 1;
                    at = end + 1;
                }
            }
            ranges[pattern_usize].end = predicates.items.len;
        }
        const owned_predicates = try predicates.toOwnedSlice(allocator);
        errdefer allocator.free(owned_predicates);
        return .{ .predicates = owned_predicates, .ranges = ranges, .regexes = try regexes.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: Set, allocator: Allocator) void {
        for (self.regexes) |regex| regex.deinit();
        allocator.free(self.predicates);
        allocator.free(self.ranges);
        allocator.free(self.regexes);
    }

    pub fn accepts(self: Set, pattern: u32, match: c.TSQueryMatch, content: []const u8, locals: Locals) !bool {
        if (pattern >= self.ranges.len) return error.InvalidPatternIndex;
        const range = self.ranges[pattern];
        for (self.predicates[range.start..range.end]) |predicate| {
            const accepted = switch (predicate) {
                .match => |condition| try matchRegex(condition.capture, self.regexes[condition.regex_index], match, content),
                .eq_string => |condition| try matchString(condition.capture, condition.value, match, content),
                .eq_capture => |condition| try matchCaptures(condition.left, condition.right, match, content),
                .local => !try matchIsLocal(match, content, locals),
            };
            if (!accepted) return false;
        }
        return true;
    }
};

fn parsePredicate(
    allocator: Allocator,
    query: *const c.TSQuery,
    source: []const u8,
    steps: []const c.TSQueryPredicateStep,
    predicate_source_offset: usize,
    predicates: *std.ArrayList(Predicate),
    regexes: *std.ArrayList(regex_mod.Regex),
    expressions: *std.ArrayList([]const u8),
    diagnostic: *Diagnostic,
) !void {
    if (steps.len == 0 or steps[0].type != c.TSQueryPredicateStepTypeString)
        return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
    const operator = stringValue(query, steps[0].value_id) orelse
        return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);

    if (std.mem.eql(u8, operator, "match?")) {
        if (steps.len != 3 or steps[1].type != c.TSQueryPredicateStepTypeCapture or steps[2].type != c.TSQueryPredicateStepTypeString)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        const expression = stringValue(query, steps[2].value_id) orelse
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        for (expressions.items, 0..) |existing, regex_index| {
            if (std.mem.eql(u8, existing, expression)) {
                try predicates.append(allocator, .{ .match = .{ .capture = steps[1].value_id, .regex_index = regex_index } });
                return;
            }
        }
        switch (regex_mod.Regex.compile(expression)) {
            .regex => |regex| {
                try regexes.append(allocator, regex);
                try expressions.append(allocator, expression);
                try predicates.append(allocator, .{ .match = .{ .capture = steps[1].value_id, .regex_index = regexes.items.len - 1 } });
            },
            .failure => |failure| return failAt(source, diagnostic, .invalid_regex, failure, predicate_source_offset),
        }
        return;
    }
    if (std.mem.eql(u8, operator, "eq?")) {
        if (steps.len != 3 or steps[1].type != c.TSQueryPredicateStepTypeCapture)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        if (steps[2].type == c.TSQueryPredicateStepTypeString) {
            const value = stringValue(query, steps[2].value_id) orelse
                return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
            try predicates.append(allocator, .{ .eq_string = .{ .capture = steps[1].value_id, .value = value } });
            return;
        }
        if (steps[2].type == c.TSQueryPredicateStepTypeCapture) {
            try predicates.append(allocator, .{ .eq_capture = .{ .left = steps[1].value_id, .right = steps[2].value_id } });
            return;
        }
        return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
    }
    if (std.mem.eql(u8, operator, "is-not?")) {
        if (steps.len != 2 or steps[1].type != c.TSQueryPredicateStepTypeString)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        const property = stringValue(query, steps[1].value_id) orelse
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        if (!std.mem.eql(u8, property, "local"))
            return failAt(source, diagnostic, .unsupported_property, null, predicate_source_offset);
        try predicates.append(allocator, .local);
        return;
    }
    const kind: Diagnostic.Kind = if (std.mem.endsWith(u8, operator, "!")) .unsupported_directive else .unknown_operator;
    return failAt(source, diagnostic, kind, null, predicate_source_offset);
}

fn fail(source: []const u8, query: *const c.TSQuery, pattern: u32, diagnostic: *Diagnostic, kind: Diagnostic.Kind, regex_failure: ?regex_mod.CompileFailure) error{InvalidPredicate} {
    const pattern_start = @min(c.ts_query_start_byte_for_pattern(query, pattern), source.len);
    return failAt(source, diagnostic, kind, regex_failure, pattern_start);
}

fn failAt(source: []const u8, diagnostic: *Diagnostic, kind: Diagnostic.Kind, regex_failure: ?regex_mod.CompileFailure, source_offset: usize) error{InvalidPredicate} {
    var offset = @min(source_offset, source.len);
    if (regex_failure != null) {
        if (std.mem.indexOfScalarPos(u8, source, offset, '"')) |quote| offset = quote + 1;
    }
    var line: u32 = 1;
    var column: u32 = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    diagnostic.* = .{ .kind = kind, .source_offset = @intCast(offset), .line = line, .column = column, .regex_failure = regex_failure };
    return error.InvalidPredicate;
}

fn stringValue(query: *const c.TSQuery, id: u32) ?[]const u8 {
    var len: u32 = 0;
    const ptr = c.ts_query_string_value_for_id(query, id, &len) orelse return null;
    return ptr[0..len];
}

fn captureText(capture_id: u32, match: c.TSQueryMatch, content: []const u8) !?[]const u8 {
    const range = try captureRange(capture_id, match, content) orelse return null;
    return content[range.start..range.end];
}

fn captureRange(capture_id: u32, match: c.TSQueryMatch, content: []const u8) !?Range {
    for (match.captures[0..match.capture_count]) |capture| {
        if (capture.index != capture_id) continue;
        return try nodeRange(capture.node, content);
    }
    return null;
}

fn nodeRange(node: c.TSNode, content: []const u8) !Range {
    const start: usize = c.ts_node_start_byte(node);
    const end: usize = c.ts_node_end_byte(node);
    if (start > end or end > content.len or !utf8Boundary(content, start) or !utf8Boundary(content, end)) return error.InvalidCaptureRange;
    return .{ .start = start, .end = end };
}

fn captureId(query: *const c.TSQuery, name: []const u8) ?u32 {
    const count = c.ts_query_capture_count(query);
    for (0..count) |id_usize| {
        const id: u32 = @intCast(id_usize);
        var len: u32 = 0;
        const value = c.ts_query_capture_name_for_id(query, id, &len) orelse continue;
        if (std.mem.eql(u8, value[0..len], name)) return id;
    }
    return null;
}

fn appendUniqueRange(allocator: Allocator, ranges: *std.ArrayList(Range), range: Range) !void {
    for (ranges.items) |existing| if (existing.start == range.start and existing.end == range.end) return;
    try ranges.append(allocator, range);
}

fn findPredicateOffset(source: []const u8, start: usize, end: usize) ?usize {
    var in_string = false;
    var escaped = false;
    for (source[start..end], start..) |byte, offset| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == '#') {
            return offset;
        }
    }
    return null;
}

fn matchRegex(capture_id: u32, regex: regex_mod.Regex, match: c.TSQueryMatch, content: []const u8) !bool {
    const text = try captureText(capture_id, match, content) orelse return error.MissingPredicateCapture;
    return regex.matches(text);
}

fn matchString(capture_id: u32, value: []const u8, match: c.TSQueryMatch, content: []const u8) !bool {
    const text = try captureText(capture_id, match, content) orelse return error.MissingPredicateCapture;
    return std.mem.eql(u8, text, value);
}

fn matchCaptures(left: u32, right: u32, match: c.TSQueryMatch, content: []const u8) !bool {
    const left_text = try captureText(left, match, content) orelse return error.MissingPredicateCapture;
    const right_text = try captureText(right, match, content) orelse return error.MissingPredicateCapture;
    return std.mem.eql(u8, left_text, right_text);
}

fn matchIsLocal(match: c.TSQueryMatch, content: []const u8, locals: Locals) !bool {
    for (match.captures[0..match.capture_count]) |capture| {
        if (locals.contains(try nodeRange(capture.node, content))) return true;
    }
    return false;
}

pub fn utf8Boundary(content: []const u8, index: usize) bool {
    return index == content.len or index < content.len and content[index] & 0xc0 != 0x80;
}
