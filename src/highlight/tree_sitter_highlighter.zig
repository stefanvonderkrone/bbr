//! C-backed Highlighter adapter for the vendored BuiltInGrammars.

const std = @import("std");
const bbr = @import("bbr");
const Allocator = std.mem.Allocator;
const predicate_mod = @import("query_predicates.zig");
const grammar_match = @import("grammar_match.zig");
const user_grammar = @import("user_grammar.zig");
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

const Grammar = struct {
    name: []const u8,
    language: *const c.TSLanguage,
    query: []const u8,
    locals_query: []const u8 = "",
};

pub const TreeSitterHighlighter = struct {
    registry: ?*user_grammar.Registry = null,

    pub fn init(registry: *user_grammar.Registry) TreeSitterHighlighter {
        return .{ .registry = registry };
    }

    pub fn highlighter(self: *TreeSitterHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlightImpl };

    fn highlightImpl(ptr: *anyopaque, allocator: Allocator, path: []const u8, content: []const u8) anyerror!bbr.highlight.HighlightResult {
        const self: *TreeSitterHighlighter = @ptrCast(@alignCast(ptr));
        if (self.registry) |registry| {
            if (registry.matchName(path, content) != null) {
                const grammar = registry.grammar(path, content) catch return highlightBuiltIn(allocator, path, content) catch .{ .spans = &.{} };
                if (grammar) |selected| {
                    return highlightWithQuery(allocator, selected.language, selected.query, selected.locals_query, content) catch
                        highlightBuiltIn(allocator, path, content) catch .{ .spans = &.{} };
                }
            }
        }
        return highlightBuiltIn(allocator, path, content);
    }
};

fn highlightBuiltIn(allocator: Allocator, path: []const u8, content: []const u8) !bbr.highlight.HighlightResult {
    const grammar = selectGrammar(path, content) orelse return .{ .spans = &.{} };
    return highlightWith(allocator, grammar, content);
}

fn selectGrammar(path: []const u8, content: []const u8) ?Grammar {
    const selected = grammar_match.selectBuiltIn(path, content) orelse return null;
    return switch (selected) {
        .tsx => .{ .name = selected.name(), .language = tree_sitter_tsx() orelse return null, .query = combined_tsx_query, .locals_query = combined_typescript_locals_query },
        .typescript => .{ .name = selected.name(), .language = tree_sitter_typescript() orelse return null, .query = combined_typescript_query, .locals_query = combined_typescript_locals_query },
        .javascript => .{ .name = selected.name(), .language = tree_sitter_javascript() orelse return null, .query = javascript_query, .locals_query = javascript_locals_query },
        .css => .{ .name = selected.name(), .language = tree_sitter_css() orelse return null, .query = css_query },
        .go => .{ .name = selected.name(), .language = tree_sitter_go() orelse return null, .query = go_query },
        .bash => .{ .name = selected.name(), .language = tree_sitter_bash() orelse return null, .query = bash_query },
        .json => .{ .name = selected.name(), .language = tree_sitter_json() orelse return null, .query = json_query },
        .yaml => .{ .name = selected.name(), .language = tree_sitter_yaml() orelse return null, .query = yaml_query },
    };
}

pub fn builtInGrammarName(path: []const u8, content: []const u8) ?[]const u8 {
    return grammar_match.builtInGrammarName(path, content);
}

fn highlightWith(allocator: Allocator, grammar: Grammar, content: []const u8) !bbr.highlight.HighlightResult {
    return highlightWithQuery(allocator, grammar.language, grammar.query, grammar.locals_query, content);
}

fn highlightWithQuery(allocator: Allocator, grammar_language: *const c.TSLanguage, query_source: []const u8, locals_query_source: []const u8, content: []const u8) !bbr.highlight.HighlightResult {
    return highlightWithQueryLimit(allocator, grammar_language, query_source, locals_query_source, content, null);
}

fn highlightWithQueryLimit(allocator: Allocator, grammar_language: *const c.TSLanguage, query_source: []const u8, locals_query_source: []const u8, content: []const u8, match_limit: ?u32) !bbr.highlight.HighlightResult {
    if (content.len > std.math.maxInt(u32)) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, grammar_language)) return error.IncompatibleGrammar;
    const tree = c.ts_parser_parse_string(parser, null, content.ptr, @intCast(content.len)) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(grammar_language, query_source.ptr, @intCast(query_source.len), &query_error_offset, &query_error_type) orelse return error.InvalidHighlightQuery;
    defer c.ts_query_delete(query);
    var diagnostic: predicate_mod.Diagnostic = undefined;
    const predicates = predicate_mod.Set.validate(allocator, query, query_source, &diagnostic) catch |err| switch (err) {
        error.InvalidPredicate => {
            diagnostic.report();
            return err;
        },
        else => return err,
    };
    defer predicates.deinit(allocator);
    const locals = predicate_mod.Locals.collect(allocator, grammar_language, tree, locals_query_source, content, &diagnostic) catch |err| switch (err) {
        error.InvalidPredicate, error.InvalidLocalsQuery => {
            diagnostic.report();
            return err;
        },
        else => return err,
    };
    defer locals.deinit(allocator);
    const cursor = c.ts_query_cursor_new() orelse return error.QueryCursorInitFailed;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_set_match_limit(cursor, match_limit orelse std.math.maxInt(u32));
    c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));

    // Capture id per byte. Later query matches take precedence; newlines are
    // ignored when the labels are converted into Line-relative Spans.
    const none = std.math.maxInt(u32);
    const labels = try allocator.alloc(u32, content.len);
    defer allocator.free(labels);
    @memset(labels, none);
    const priorities = try allocator.alloc(u32, content.len);
    defer allocator.free(priorities);
    @memset(priorities, 0);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        if (!try predicates.accepts(match.pattern_index, match, content, locals)) continue;
        const captures = match.captures[0..match.capture_count];
        for (captures) |capture| {
            const range = try predicate_mod.checkedRange(c.ts_node_start_byte(capture.node), c.ts_node_end_byte(capture.node), content);
            const start = range.start;
            const end = range.end;
            if (start == end) continue;
            for (start..end) |byte| {
                if (labels[byte] == none or match.pattern_index >= priorities[byte]) {
                    labels[byte] = capture.index;
                    priorities[byte] = match.pattern_index;
                }
            }
        }
    }
    if (c.ts_query_cursor_did_exceed_match_limit(cursor)) return error.QueryMatchLimitExceeded;

    var spans: std.ArrayList(bbr.highlight.Span) = .empty;
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
            if (labels[at] == none) {
                at += 1;
                continue;
            }
            const capture_id = labels[at];
            var end = at + 1;
            while (end < i and labels[end] == capture_id) end += 1;
            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(query, capture_id, &name_len) orelse return error.InvalidCapture;
            const name = try allocator.dupe(u8, name_ptr[0..name_len]);
            try spans.append(allocator, .{
                .line = line,
                .start = at - line_start,
                .end = end - line_start,
                .capture = .{ .name = name },
            });
            at = end;
        }
        if (i == content.len) break;
        i += 1;
        line_start = i;
        line += 1;
    }
    return .{ .spans = try spans.toOwnedSlice(allocator) };
}

const testing = std.testing;

test "BuiltInGrammar selection covers JavaScript TypeScript and TSX" {
    try testing.expect(selectGrammar("src/a.js", "") != null);
    try testing.expect(selectGrammar("src/a.mts", "") != null);
    try testing.expect(selectGrammar("src/a.tsx", "") != null);
    try testing.expect(selectGrammar("src/a.zig", "") == null);
    try testing.expect(selectGrammar("scripts/release", "#!/usr/bin/env bash\n") != null);
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
    var highlighter = TreeSitterHighlighter.init(&registry);

    const built_in = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", "const answer = 1;\n");
    defer freeResult(built_in);
    try testing.expect(built_in.spans.len > 0);
    const plain = try highlighter.highlighter().highlight(testing.allocator, "src/a.fixture", "content\n");
    try testing.expectEqual(@as(usize, 0), plain.spans.len);
}

test "JavaScript tracer produces ordered non-overlapping Captures" {
    var highlighter: TreeSitterHighlighter = .{};
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", "const answer = \"yes\";\n");
    defer {
        for (result.spans) |span| testing.allocator.free(span.capture.name);
        testing.allocator.free(result.spans);
    }
    try testing.expect(result.spans.len > 0);
    for (result.spans, 0..) |span, i| {
        try testing.expect(span.start < span.end);
        if (i > 0 and result.spans[i - 1].line == span.line) try testing.expect(result.spans[i - 1].end <= span.start);
    }
}

test "JavaScript BuiltInGrammar executes conditional Captures" {
    var highlighter: TreeSitterHighlighter = .{};
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
    var highlighter: TreeSitterHighlighter = .{};
    const result = try highlighter.highlighter().highlight(testing.allocator, "src/a.js", source);
    defer freeResult(result);

    const global_console = std.mem.indexOf(u8, source, "console").?;
    const console_parameter = std.mem.indexOfPos(u8, source, global_console + 1, "console").?;
    const local_console = std.mem.indexOfPos(u8, source, console_parameter + 1, "console").?;
    const global_require = std.mem.indexOf(u8, source, "require").?;
    const require_parameter = std.mem.indexOfPos(u8, source, global_require + 1, "require").?;
    const local_require = std.mem.indexOfPos(u8, source, require_parameter + 1, "require").?;
    try expectSpan(result, 1, global_console, global_console + 7, "variable.builtin");
    try expectNoCapture(result, source, local_console, local_console + 7, "variable.builtin");
    try expectSpan(result, 3, 0, 7, "function.builtin");
    try expectNoCapture(result, source, local_require, local_require + 7, "function.builtin");
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
    var highlighter: TreeSitterHighlighter = .{};
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
    var highlighter: TreeSitterHighlighter = .{};
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
    var highlighter: TreeSitterHighlighter = .{};
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
    var highlighter: TreeSitterHighlighter = .{};
    for (cases) |case| {
        const result = try highlighter.highlighter().highlight(testing.allocator, case.path, case.source);
        defer {
            for (result.spans) |span| testing.allocator.free(span.capture.name);
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
    var highlighter: TreeSitterHighlighter = .{};
    for (cases) |case| {
        const result = try highlighter.highlighter().highlight(testing.allocator, case.path, case.source);
        defer {
            for (result.spans) |span| testing.allocator.free(span.capture.name);
            testing.allocator.free(result.spans);
        }
        try testing.expect(result.spans.len > 0);
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
        .{ .query = "((identifier) @x (#set! \"priority\" 100))", .kind = .unsupported_directive },
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

fn freeResult(result: bbr.highlight.HighlightResult) void {
    for (result.spans) |span| testing.allocator.free(span.capture.name);
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
        if (span.line == line and span.start == start and span.end == end and std.mem.eql(u8, span.capture.name, capture)) return;
    }
    return error.ExpectedSpanNotFound;
}

fn expectNoCapture(result: bbr.highlight.HighlightResult, source: []const u8, absolute_start: usize, absolute_end: usize, capture: []const u8) !void {
    for (result.spans) |span| {
        var line: u32 = 1;
        var line_start: usize = 0;
        while (line < span.line) : (line += 1) {
            line_start = std.mem.indexOfScalarPos(u8, source, line_start, '\n').? + 1;
        }
        if (std.mem.eql(u8, span.capture.name, capture) and line_start + span.start == absolute_start and line_start + span.end == absolute_end)
            return error.UnexpectedCaptureFound;
    }
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
