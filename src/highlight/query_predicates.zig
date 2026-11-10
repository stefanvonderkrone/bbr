const std = @import("std");
const regex_mod = @import("query_regex.zig");
const diagnostics = @import("bbr").diagnostics;
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
    query_kind: QueryKind = .highlight,
    query_error: ?c.TSQueryError = null,

    pub const QueryKind = enum { highlight, locals, injections };

    pub const Kind = enum {
        unknown_operator,
        unsupported_directive,
        malformed_arguments,
        invalid_regex,
        unsupported_property,
        invalid_query,
    };

    pub fn report(self: Diagnostic) void {
        var buffer: [512]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        write(&stderr.file_writer.interface, self) catch |err| switch (err) {
            error.WriteFailed => return,
        };
    }

    pub fn write(writer: *std.Io.Writer, self: Diagnostic) std.Io.Writer.Error!void {
        const query_kind = @tagName(self.query_kind);
        if (self.regex_failure) |failure| {
            try writer.print("error: {s}-query:{d}:{d}: invalid #match? expression for {s}: {s}\n", .{ query_kind, self.line, self.column, regex_mod.engine, @tagName(failure.reason) });
            try writer.print("error: engine-code: {d}; engine-fragment: {s}; dialect: {s}\n", .{ failure.engine_code, failure.fragment(), regex_mod.dialect });
        } else if (self.kind == .invalid_query) {
            try writer.print("error: {s}-query:{d}:{d}: invalid query\n", .{ query_kind, self.line, self.column });
        } else {
            try writer.print("error: {s}-query:{d}:{d}: invalid predicate: {s}\n", .{ query_kind, self.line, self.column, @tagName(self.kind) });
        }
    }

    pub fn record(self: Diagnostic, handle: diagnostics.Handle, comptime source: std.builtin.SourceLocation) void {
        if (self.cause()) |cause_value| _ = handle.failure(.query, cause_value, source);
    }

    /// The Grammar cause, or null when the failure has no code to record.
    pub fn cause(self: Diagnostic) ?diagnostics.Cause {
        if (self.query_error) |code| return .{ .grammar = .{ .rule = .query, .code = code, .offset = self.source_offset } };
        if (self.regex_failure) |failure| return .{ .grammar = .{ .rule = .regex, .code = @bitCast(failure.engine_code), .offset = self.source_offset } };
        return switch (self.kind) {
            .invalid_query, .invalid_regex => null,
            inline .unknown_operator, .unsupported_directive, .malformed_arguments, .unsupported_property => |kind| .{ .grammar = .{ .rule = @field(diagnostics.GrammarRule, @tagName(kind)), .offset = self.source_offset } },
        };
    }
};

/// The precedence of a pattern without `#set! priority`, as in Neovim.
pub const default_priority: u16 = 100;

const Predicate = struct {
    condition: Condition,
    /// A `not-` operator and `#is-not? local` accept a match that the condition rejects.
    negated: bool,
};

const Condition = union(enum) {
    match: struct { capture: u32, regex_index: usize },
    eq_string: struct { capture: u32, value: []const u8 },
    eq_capture: struct { left: u32, right: u32 },
    any_of: struct { capture: u32, values: Range },
    /// `values` are node types. `parent_only` checks only the direct parent.
    ancestor: struct { capture: u32, values: Range, parent_only: bool },
    local,
};

const Range = struct { start: usize, end: usize };

/// The directives of one injection query pattern.
pub const Injection = struct {
    language: ?[]const u8 = null,
    combined: bool = false,
    include_children: bool = false,
    /// Start row, start column, end row, and end column deltas for `@injection.content`.
    offset: ?[4]i32 = null,
};

pub const Locals = struct {
    ranges: []Range,

    pub fn collect(allocator: Allocator, grammar_language: *const c.TSLanguage, tree: *const c.TSTree, query_source: []const u8, content: []const u8, diagnostic: *Diagnostic) !Locals {
        if (query_source.len == 0) return .{ .ranges = &.{} };
        var query_error_offset: u32 = 0;
        var query_error_type: c.TSQueryError = undefined;
        const query = c.ts_query_new(grammar_language, query_source.ptr, @intCast(query_source.len), &query_error_offset, &query_error_type) orelse {
            setDiagnostic(query_source, diagnostic, .invalid_query, null, query_error_offset);
            diagnostic.query_kind = .locals;
            diagnostic.query_error = query_error_type;
            return error.InvalidLocalsQuery;
        };
        defer c.ts_query_delete(query);
        const predicates = Set.validate(allocator, query, query_source, diagnostic) catch |err| {
            diagnostic.query_kind = .locals;
            return err;
        };
        defer predicates.deinit(allocator);
        return collectPrepared(allocator, tree, query, predicates, captureId(query, "local.scope"), captureId(query, "local.definition"), captureId(query, "local.reference"), content);
    }

    pub fn collectPrepared(allocator: Allocator, tree: *const c.TSTree, query: *const c.TSQuery, predicates: Set, scope_id: ?u32, definition_id: ?u32, reference_id: ?u32, content: []const u8) !Locals {
        const cursor = c.ts_query_cursor_new() orelse return error.QueryCursorInitFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_set_match_limit(cursor, std.math.maxInt(u32));
        c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));
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
            if (!try predicates.accepts(match.pattern_index, match, content, .{ .ranges = &.{} })) continue;
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
    /// The `#any-of?` values and the ancestor node types. They point into the query.
    strings: [][]const u8,
    /// One priority for each pattern, from `#set! priority N`.
    priorities: []u16,

    pub fn validate(allocator: Allocator, query: *const c.TSQuery, source: []const u8, diagnostic: *Diagnostic) !Set {
        return validateKind(allocator, query, source, diagnostic, null);
    }

    /// Accepts the injection directives too, and writes them to one `Injection` for each pattern.
    pub fn validateInjections(allocator: Allocator, query: *const c.TSQuery, source: []const u8, diagnostic: *Diagnostic, injections: []Injection) !Set {
        std.debug.assert(injections.len == c.ts_query_pattern_count(query));
        @memset(injections, .{});
        return validateKind(allocator, query, source, diagnostic, injections);
    }

    fn validateKind(allocator: Allocator, query: *const c.TSQuery, source: []const u8, diagnostic: *Diagnostic, injections: ?[]Injection) !Set {
        const pattern_count = c.ts_query_pattern_count(query);
        const ranges = try allocator.alloc(Range, pattern_count);
        errdefer allocator.free(ranges);
        const priorities = try allocator.alloc(u16, pattern_count);
        errdefer allocator.free(priorities);
        @memset(priorities, default_priority);
        var predicates: std.ArrayList(Predicate) = .empty;
        errdefer predicates.deinit(allocator);
        var strings: std.ArrayList([]const u8) = .empty;
        errdefer strings.deinit(allocator);
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
                    const injection = if (injections) |all| &all[pattern_usize] else null;
                    try parsePredicate(allocator, query, source, steps[at..end], predicate_source_offset, &predicates, &regexes, &expressions, &strings, &priorities[pattern_usize], injection, diagnostic);
                    predicate_source_offset += 1;
                    at = end + 1;
                }
            }
            ranges[pattern_usize].end = predicates.items.len;
        }
        const owned_strings = try strings.toOwnedSlice(allocator);
        errdefer allocator.free(owned_strings);
        const owned_predicates = try predicates.toOwnedSlice(allocator);
        errdefer allocator.free(owned_predicates);
        return .{
            .predicates = owned_predicates,
            .ranges = ranges,
            .regexes = try regexes.toOwnedSlice(allocator),
            .strings = owned_strings,
            .priorities = priorities,
        };
    }

    pub fn deinit(self: Set, allocator: Allocator) void {
        for (self.regexes) |regex| regex.deinit();
        allocator.free(self.predicates);
        allocator.free(self.ranges);
        allocator.free(self.regexes);
        allocator.free(self.strings);
        allocator.free(self.priorities);
    }

    pub fn requiresLocals(self: Set) bool {
        for (self.predicates) |predicate| switch (predicate.condition) {
            .local => return true,
            else => {},
        };
        return false;
    }

    pub fn accepts(self: Set, pattern: u32, match: c.TSQueryMatch, content: []const u8, locals: Locals) !bool {
        if (pattern >= self.ranges.len) return error.InvalidPatternIndex;
        const range = self.ranges[pattern];
        for (self.predicates[range.start..range.end]) |predicate| {
            if (try self.holds(predicate.condition, match, content, locals) == predicate.negated) return false;
        }
        return true;
    }

    /// Like Neovim, a condition holds for every node of its Capture, so it holds when the match has none.
    fn holds(self: Set, condition: Condition, match: c.TSQueryMatch, content: []const u8, locals: Locals) !bool {
        const capture_id = switch (condition) {
            .local => return matchIsLocal(match, content, locals),
            .eq_capture => |pair| return matchCaptures(pair.left, pair.right, match, content),
            inline else => |operands| operands.capture,
        };
        for (capturesOf(match)) |capture| {
            if (capture.index == capture_id and !try self.nodeHolds(condition, capture.node, content)) return false;
        }
        return true;
    }

    fn nodeHolds(self: Set, condition: Condition, node: c.TSNode, content: []const u8) !bool {
        switch (condition) {
            .match => |operands| return self.regexes[operands.regex_index].matches(try nodeText(node, content)),
            .eq_string => |operands| return std.mem.eql(u8, try nodeText(node, content), operands.value),
            .any_of => |operands| return containsString(self.strings[operands.values.start..operands.values.end], try nodeText(node, content)),
            .ancestor => |operands| {
                const types = self.strings[operands.values.start..operands.values.end];
                var ancestor = c.ts_node_parent(node);
                while (!c.ts_node_is_null(ancestor)) : (ancestor = c.ts_node_parent(ancestor)) {
                    if (containsString(types, std.mem.span(c.ts_node_type(ancestor)))) return true;
                    if (operands.parent_only) return false;
                }
                return false;
            },
            .eq_capture, .local => unreachable,
        }
    }
};

fn containsString(values: []const []const u8, text: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, text)) return true;
    return false;
}

fn nodeText(node: c.TSNode, content: []const u8) ![]const u8 {
    const range = try nodeRange(node, content);
    return content[range.start..range.end];
}

fn parsePredicate(
    allocator: Allocator,
    query: *const c.TSQuery,
    source: []const u8,
    steps: []const c.TSQueryPredicateStep,
    predicate_source_offset: usize,
    predicates: *std.ArrayList(Predicate),
    regexes: *std.ArrayList(regex_mod.Regex),
    expressions: *std.ArrayList([]const u8),
    strings: *std.ArrayList([]const u8),
    priority: *u16,
    injection: ?*Injection,
    diagnostic: *Diagnostic,
) !void {
    if (steps.len == 0 or steps[0].type != c.TSQueryPredicateStepTypeString)
        return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
    const full_operator = stringValue(query, steps[0].value_id) orelse
        return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
    const negated = std.mem.startsWith(u8, full_operator, "not-");
    const operator = if (negated) full_operator["not-".len..] else full_operator;

    if (std.mem.eql(u8, operator, "match?")) {
        if (steps.len != 3 or steps[1].type != c.TSQueryPredicateStepTypeCapture or steps[2].type != c.TSQueryPredicateStepTypeString)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        const expression = stringValue(query, steps[2].value_id) orelse
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        const regex_index = for (expressions.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, expression)) break index;
        } else switch (regex_mod.Regex.compile(expression)) {
            .regex => |regex| index: {
                try regexes.append(allocator, regex);
                try expressions.append(allocator, expression);
                break :index regexes.items.len - 1;
            },
            .failure => |failure| return failAt(source, diagnostic, .invalid_regex, failure, predicate_source_offset),
        };
        try predicates.append(allocator, .{ .condition = .{ .match = .{ .capture = steps[1].value_id, .regex_index = regex_index } }, .negated = negated });
        return;
    }
    if (std.mem.eql(u8, operator, "eq?")) {
        if (steps.len != 3 or steps[1].type != c.TSQueryPredicateStepTypeCapture)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        if (steps[2].type == c.TSQueryPredicateStepTypeString) {
            const value = stringValue(query, steps[2].value_id) orelse
                return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
            try predicates.append(allocator, .{ .condition = .{ .eq_string = .{ .capture = steps[1].value_id, .value = value } }, .negated = negated });
            return;
        }
        if (steps[2].type == c.TSQueryPredicateStepTypeCapture) {
            try predicates.append(allocator, .{ .condition = .{ .eq_capture = .{ .left = steps[1].value_id, .right = steps[2].value_id } }, .negated = negated });
            return;
        }
        return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
    }
    const list_kind: ?enum { any_of, ancestor, parent } = if (std.mem.eql(u8, operator, "any-of?"))
        .any_of
    else if (std.mem.eql(u8, operator, "has-ancestor?"))
        .ancestor
    else if (std.mem.eql(u8, operator, "has-parent?"))
        .parent
    else
        null;
    if (list_kind) |kind| {
        if (steps.len < 3 or steps[1].type != c.TSQueryPredicateStepTypeCapture)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        const values: Range = .{ .start = strings.items.len, .end = strings.items.len + steps.len - 2 };
        for (steps[2..]) |step| {
            const value = (if (step.type == c.TSQueryPredicateStepTypeString) stringValue(query, step.value_id) else null) orelse
                return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
            try strings.append(allocator, value);
        }
        const capture = steps[1].value_id;
        const condition: Condition = switch (kind) {
            .any_of => .{ .any_of = .{ .capture = capture, .values = values } },
            .ancestor, .parent => .{ .ancestor = .{ .capture = capture, .values = values, .parent_only = kind == .parent } },
        };
        try predicates.append(allocator, .{ .condition = condition, .negated = negated });
        return;
    }
    if (negated) return failAt(source, diagnostic, .unknown_operator, null, predicate_source_offset);
    if (std.mem.eql(u8, operator, "is-not?")) {
        if (steps.len != 2 or steps[1].type != c.TSQueryPredicateStepTypeString)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        const property = stringValue(query, steps[1].value_id) orelse
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        if (!std.mem.eql(u8, property, "local"))
            return failAt(source, diagnostic, .unsupported_property, null, predicate_source_offset);
        try predicates.append(allocator, .{ .condition = .local, .negated = true });
        return;
    }
    if (std.mem.eql(u8, operator, "set!") and steps.len >= 2 and steps[1].type == c.TSQueryPredicateStepTypeString and
        std.mem.eql(u8, stringValue(query, steps[1].value_id) orelse "", "priority"))
    {
        const text = if (steps.len == 3 and steps[2].type == c.TSQueryPredicateStepTypeString) stringValue(query, steps[2].value_id) else null;
        priority.* = std.fmt.parseInt(u16, text orelse "", 10) catch |err| switch (err) {
            error.Overflow, error.InvalidCharacter => return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset),
        };
        return;
    }
    if (injection) |settings| {
        if (try parseInjectionDirective(query, source, steps, operator, predicate_source_offset, settings, diagnostic)) return;
    }
    const kind: Diagnostic.Kind = if (std.mem.endsWith(u8, operator, "!")) .unsupported_directive else .unknown_operator;
    return failAt(source, diagnostic, kind, null, predicate_source_offset);
}

fn parseInjectionDirective(
    query: *const c.TSQuery,
    source: []const u8,
    steps: []const c.TSQueryPredicateStep,
    operator: []const u8,
    predicate_source_offset: usize,
    injection: *Injection,
    diagnostic: *Diagnostic,
) !bool {
    if (std.mem.eql(u8, operator, "offset!")) {
        const content_id = captureId(query, "injection.content") orelse std.math.maxInt(u32);
        if (steps.len != 6 or steps[1].type != c.TSQueryPredicateStepTypeCapture or steps[1].value_id != content_id)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        var offset: [4]i32 = undefined;
        for (steps[2..], &offset) |step, *delta| {
            const text = if (step.type == c.TSQueryPredicateStepTypeString) stringValue(query, step.value_id) else null;
            delta.* = std.fmt.parseInt(i32, text orelse "", 10) catch |err| switch (err) {
                error.Overflow, error.InvalidCharacter => return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset),
            };
        }
        injection.offset = offset;
        return true;
    }
    if (!std.mem.eql(u8, operator, "set!") or steps.len < 2 or steps[1].type != c.TSQueryPredicateStepTypeString) return false;
    const key = stringValue(query, steps[1].value_id) orelse return false;
    if (std.mem.eql(u8, key, "injection.language")) {
        if (steps.len != 3 or steps[2].type != c.TSQueryPredicateStepTypeString)
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        injection.language = stringValue(query, steps[2].value_id) orelse
            return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
        return true;
    }
    const flag = if (std.mem.eql(u8, key, "injection.combined"))
        &injection.combined
    else if (std.mem.eql(u8, key, "injection.include-children"))
        &injection.include_children
    else
        return false;
    if (steps.len != 2) return failAt(source, diagnostic, .malformed_arguments, null, predicate_source_offset);
    flag.* = true;
    return true;
}

fn fail(source: []const u8, query: *const c.TSQuery, pattern: u32, diagnostic: *Diagnostic, kind: Diagnostic.Kind, regex_failure: ?regex_mod.CompileFailure) error{InvalidPredicate} {
    const pattern_start = @min(c.ts_query_start_byte_for_pattern(query, pattern), source.len);
    return failAt(source, diagnostic, kind, regex_failure, pattern_start);
}

fn failAt(source: []const u8, diagnostic: *Diagnostic, kind: Diagnostic.Kind, regex_failure: ?regex_mod.CompileFailure, source_offset: usize) error{InvalidPredicate} {
    setDiagnostic(source, diagnostic, kind, regex_failure, source_offset);
    return error.InvalidPredicate;
}

fn setDiagnostic(source: []const u8, diagnostic: *Diagnostic, kind: Diagnostic.Kind, regex_failure: ?regex_mod.CompileFailure, source_offset: usize) void {
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
}

pub fn setInvalidQueryDiagnostic(source: []const u8, diagnostic: *Diagnostic, source_offset: usize, query_kind: Diagnostic.QueryKind) void {
    setDiagnostic(source, diagnostic, .invalid_query, null, source_offset);
    diagnostic.query_kind = query_kind;
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
    for (capturesOf(match)) |capture| {
        if (capture.index != capture_id) continue;
        return try nodeRange(capture.node, content);
    }
    return null;
}

fn nodeRange(node: c.TSNode, content: []const u8) !Range {
    const start: usize = c.ts_node_start_byte(node);
    const end: usize = c.ts_node_end_byte(node);
    return checkedRange(start, end, content);
}

pub fn checkedRange(start: usize, end: usize, content: []const u8) !Range {
    if (start > end or end > content.len or !utf8Boundary(content, start) or !utf8Boundary(content, end)) return error.InvalidCaptureRange;
    return .{ .start = start, .end = end };
}

pub fn captureId(query: *const c.TSQuery, name: []const u8) ?u32 {
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

fn matchCaptures(left: u32, right: u32, match: c.TSQueryMatch, content: []const u8) !bool {
    const left_text = try captureText(left, match, content) orelse return true;
    const right_text = try captureText(right, match, content) orelse return true;
    return std.mem.eql(u8, left_text, right_text);
}

fn matchIsLocal(match: c.TSQueryMatch, content: []const u8, locals: Locals) !bool {
    for (capturesOf(match)) |capture| {
        if (locals.contains(try nodeRange(capture.node, content))) return true;
    }
    return false;
}

/// The runtime gives a null capture pointer to a match of a pattern without Captures.
pub fn capturesOf(match: c.TSQueryMatch) []const c.TSQueryCapture {
    if (match.capture_count == 0) return &.{};
    return match.captures[0..match.capture_count];
}

pub fn utf8Boundary(content: []const u8, index: usize) bool {
    return index == content.len or index < content.len and content[index] & 0xc0 != 0x80;
}

const testing = std.testing;
extern fn tree_sitter_javascript() callconv(.c) ?*const c.TSLanguage;

fn expectInvalid(source: []const u8, kind: Diagnostic.Kind, injection_query: bool) !void {
    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(tree_sitter_javascript().?, source.ptr, @intCast(source.len), &error_offset, &error_type).?;
    defer c.ts_query_delete(query);
    var injections: [1]Injection = undefined;
    var diagnostic: Diagnostic = undefined;
    const result = if (injection_query)
        Set.validateInjections(testing.allocator, query, source, &diagnostic, &injections)
    else
        Set.validate(testing.allocator, query, source, &diagnostic);
    try testing.expectError(error.InvalidPredicate, result);
    try testing.expectEqual(kind, diagnostic.kind);
}

test "M27 injection directives validate only in an injection query" {
    const source =
        \\((template_string) @injection.content
        \\  (#set! injection.language "css")
        \\  (#set! injection.combined)
        \\  (#set! injection.include-children)
        \\  (#offset! @injection.content 0 1 0 -1))
    ;
    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(tree_sitter_javascript().?, source.ptr, source.len, &error_offset, &error_type).?;
    defer c.ts_query_delete(query);
    var injections: [1]Injection = undefined;
    var diagnostic: Diagnostic = undefined;
    const predicates = try Set.validateInjections(testing.allocator, query, source, &diagnostic, &injections);
    defer predicates.deinit(testing.allocator);
    try testing.expectEqualStrings("css", injections[0].language.?);
    try testing.expect(injections[0].combined and injections[0].include_children);
    try testing.expectEqual([4]i32{ 0, 1, 0, -1 }, injections[0].offset.?);

    for ([_][]const u8{
        "((identifier) @x (#set! injection.language \"css\"))",
        "((identifier) @x (#set! injection.combined))",
        "((identifier) @x (#set! injection.include-children))",
        "((identifier) @injection.content (#offset! @injection.content 0 0 0 0))",
    }) |highlight_source| try expectInvalid(highlight_source, .unsupported_directive, false);
}

test "M27 grammar rejects malformed new predicates and priorities" {
    for ([_][]const u8{
        "((identifier) @x (#set! priority))",
        "((identifier) @x (#set! priority high))",
        "((identifier) @x (#set! priority -1))",
        "((identifier) @x (#set! priority 1 2))",
        "((identifier) @x (#any-of? @x))",
        "((identifier) @x (#any-of? \"a\" @x))",
        "((identifier) @x (#not-has-parent? @x @x))",
        "((identifier) @x (#has-ancestor? @x))",
        "((identifier) @x (#not-match? @x))",
    }) |source| try expectInvalid(source, .malformed_arguments, false);
    try expectInvalid("((identifier) @x (#not-is-not? local))", .unknown_operator, false);
    try expectInvalid("((identifier) @x (#not-contains? @x \"a\"))", .unknown_operator, false);
}

test "M27 grammar RE2 compiles each translated Lua pattern and matches like Lua" {
    const lua_patterns = @import("lua_pattern_cases.zig");
    for (lua_patterns.cases) |case| {
        const regex = switch (regex_mod.Regex.compile(case.re2)) {
            .regex => |regex| regex,
            .failure => |failure| {
                std.debug.print("Lua pattern {s} gives RE2 {s}: {s}\n", .{ case.lua, case.re2, @tagName(failure.reason) });
                return error.TranslatedPatternDoesNotCompile;
            },
        };
        defer regex.deinit();
        for (lua_patterns.samples, case.matches) |sample, lua_match| {
            if (regex.matches(sample) != (lua_match == '1')) {
                std.debug.print("Lua pattern {s} as RE2 {s} on sample {any}: Lua {c}\n", .{ case.lua, case.re2, sample, lua_match });
                return error.TranslatedPatternDiffersFromLua;
            }
        }
    }
}

test "M27 injection query rejects malformed and unknown directives" {
    try expectInvalid("((identifier) @injection.content (#offset! @injection.content 0 x 0 0))", .malformed_arguments, true);
    try expectInvalid("((identifier) @injection.content (#offset! @injection.content 0 0 0))", .malformed_arguments, true);
    try expectInvalid("((identifier) @injection.content @x (#offset! @x 0 0 0 0))", .malformed_arguments, true);
    try expectInvalid("((identifier) @injection.content (#set! injection.language))", .malformed_arguments, true);
    try expectInvalid("((identifier) @injection.content (#set! injection.combined \"yes\"))", .malformed_arguments, true);
    try expectInvalid("((identifier) @injection.content (#set! injection.self))", .unsupported_directive, true);
    try expectInvalid("((identifier) @injection.content (#set! conceal \"\"))", .unsupported_directive, true);
}
