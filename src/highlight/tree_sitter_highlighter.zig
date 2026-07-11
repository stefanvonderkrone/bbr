//! C-backed Highlighter adapter for the vendored BuiltInGrammars.

const std = @import("std");
const bbr = @import("bbr");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

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
const combined_typescript_query = javascript_query ++ "\n" ++ typescript_query;
const combined_tsx_query = javascript_query ++ "\n" ++ tsx_query;

const Grammar = struct {
    language: *const c.TSLanguage,
    query: []const u8,
};

pub const TreeSitterHighlighter = struct {
    pub fn highlighter(self: *TreeSitterHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlightImpl };

    fn highlightImpl(_: *anyopaque, allocator: Allocator, path: []const u8, content: []const u8) anyerror!bbr.highlight.HighlightResult {
        const grammar = selectGrammar(path, content) orelse return .{ .spans = &.{} };
        return highlightWith(allocator, grammar, content);
    }
};

fn selectGrammar(path: []const u8, content: []const u8) ?Grammar {
    if (hasAnySuffix(path, &.{".tsx"})) return .{ .language = tree_sitter_tsx() orelse return null, .query = combined_tsx_query };
    if (hasAnySuffix(path, &.{ ".ts", ".mts", ".cts" })) return .{ .language = tree_sitter_typescript() orelse return null, .query = combined_typescript_query };
    if (hasAnySuffix(path, &.{ ".js", ".jsx", ".mjs", ".cjs" })) return .{ .language = tree_sitter_javascript() orelse return null, .query = javascript_query };
    if (hasAnySuffix(path, &.{".css"})) return .{ .language = tree_sitter_css() orelse return null, .query = css_query };
    if (hasAnySuffix(path, &.{".go"})) return .{ .language = tree_sitter_go() orelse return null, .query = go_query };
    if (hasAnySuffix(path, &.{ ".sh", ".bash" })) return .{ .language = tree_sitter_bash() orelse return null, .query = bash_query };
    if (hasAnySuffix(path, &.{".json"})) return .{ .language = tree_sitter_json() orelse return null, .query = json_query };
    if (hasAnySuffix(path, &.{ ".yaml", ".yml" })) return .{ .language = tree_sitter_yaml() orelse return null, .query = yaml_query };
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, ".bashrc") or std.mem.eql(u8, basename, "Bashfile") or bashShebang(content))
        return .{ .language = tree_sitter_bash() orelse return null, .query = bash_query };
    return null;
}

fn bashShebang(content: []const u8) bool {
    const first_line = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    if (!std.mem.startsWith(u8, first_line, "#!")) return false;
    return std.mem.indexOf(u8, first_line, "bash") != null or std.mem.endsWith(u8, first_line, "/sh");
}

fn hasAnySuffix(path: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| if (std.mem.endsWith(u8, path, suffix)) return true;
    return false;
}

fn highlightWith(allocator: Allocator, grammar: Grammar, content: []const u8) !bbr.highlight.HighlightResult {
    if (content.len > std.math.maxInt(u32)) return error.FileTooLarge;
    const parser = c.ts_parser_new() orelse return error.ParserInitFailed;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, grammar.language)) return error.IncompatibleGrammar;
    const tree = c.ts_parser_parse_string(parser, null, content.ptr, @intCast(content.len)) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var query_error_offset: u32 = 0;
    var query_error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(grammar.language, grammar.query.ptr, @intCast(grammar.query.len), &query_error_offset, &query_error_type) orelse return error.InvalidHighlightQuery;
    defer c.ts_query_delete(query);
    const cursor = c.ts_query_cursor_new() orelse return error.QueryCursorInitFailed;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));

    // Capture id per byte. Later query matches take precedence; newlines are
    // ignored when the labels are converted into Line-relative Spans.
    const none = std.math.maxInt(u32);
    const labels = try allocator.alloc(u32, content.len);
    defer allocator.free(labels);
    @memset(labels, none);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        // Predicate evaluation belongs to tree-sitter's higher-level highlight
        // engine. Until bbr implements it, conservatively skip conditional
        // patterns instead of applying them too broadly.
        var predicate_steps: u32 = 0;
        _ = c.ts_query_predicates_for_pattern(query, match.pattern_index, &predicate_steps);
        if (predicate_steps != 0) continue;
        const captures = match.captures[0..match.capture_count];
        for (captures) |capture| {
            const start: usize = c.ts_node_start_byte(capture.node);
            const end: usize = c.ts_node_end_byte(capture.node);
            if (start >= end or end > content.len) continue;
            @memset(labels[start..end], capture.index);
        }
    }

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
