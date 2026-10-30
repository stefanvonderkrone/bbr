const std = @import("std");
const grammar_name = @import("bbr").highlight.grammar_name;
/// `vendors/tree-sitter/manifest.zig.zon`, imported by `addTreeSitter` in `build.zig`.
pub const manifest = @import("builtin_grammar_manifest");

/// Each tag is an nvim-treesitter name and a key of the manifest `.grammars`, in the same order.
pub const BuiltInGrammar = enum {
    tsx,
    typescript,
    javascript,
    css,
    go,
    bash,
    json,
    yaml,
    zig,
    c,
    cpp,
    rust,
    odin,
    java,
    kotlin,
    groovy,
    c_sharp,
    python,
    ruby,
    swift,
    sql,
    toml,
    dockerfile,
    make,
    html,
    xml,
    markdown_inline,
    markdown,

    pub fn name(self: BuiltInGrammar) []const u8 {
        return switch (self) {
            inline else => |grammar| entry(grammar).name,
        };
    }

    pub fn entry(comptime self: BuiltInGrammar) @TypeOf(@field(manifest.grammars, @tagName(self))) {
        return @field(manifest.grammars, @tagName(self));
    }
};

comptime {
    const entries = std.meta.fields(@TypeOf(manifest.grammars));
    const tags = std.meta.tags(BuiltInGrammar);
    if (entries.len != tags.len) @compileError("BuiltInGrammar and the manifest .grammars must have the same entries");
    for (entries, tags) |manifest_entry, tag| {
        if (!std.mem.eql(u8, manifest_entry.name, @tagName(tag))) {
            @compileError("BuiltInGrammar ." ++ @tagName(tag) ++ " is where the manifest has ." ++ manifest_entry.name ++ ". Keep both in the same order.");
        }
    }
}

/// One GrammarMatch row. Filenames compare with the basename, extensions with the path end,
/// and shebangs with the interpreter that `shebangInterpreter` finds.
pub const Row = struct {
    grammar: BuiltInGrammar,
    filenames: []const []const u8,
    extensions: []const []const u8,
    shebangs: []const []const u8,
};

/// The GrammarMatch table. Each row is the manifest `.matches` of its BuiltInGrammar.
pub const table: [std.meta.tags(BuiltInGrammar).len]Row = rows: {
    var rows: [std.meta.tags(BuiltInGrammar).len]Row = undefined;
    for (std.meta.tags(BuiltInGrammar), &rows) |grammar, *row| {
        const matches = grammar.entry().matches;
        row.* = .{ .grammar = grammar, .filenames = &matches.filenames, .extensions = &matches.extensions, .shebangs = &matches.shebangs };
    }
    break :rows rows;
};

/// Checks all exact filenames first, then extensions, then shebangs. The first match wins.
pub fn selectBuiltIn(path: []const u8, content: []const u8) ?BuiltInGrammar {
    const basename = std.fs.path.basename(path);
    for (table) |row| for (row.filenames) |filename| if (std.mem.eql(u8, basename, filename)) return row.grammar;
    for (table) |row| for (row.extensions) |extension| if (std.mem.endsWith(u8, path, extension)) return row.grammar;
    const interpreter = shebangInterpreter(content) orelse return null;
    for (table) |row| for (row.shebangs) |shebang| if (std.mem.eql(u8, interpreter, shebang)) return row.grammar;
    return null;
}

/// The basename of the first word after `#!`, or for `env` its first argument without a leading
/// `-`. Trailing digits and dots go, so `python3.12` is `python`.
fn shebangInterpreter(content: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, "#!")) return null;
    const line = content[2 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    var command = words.next() orelse return null;
    if (std.mem.eql(u8, std.fs.path.basename(command), "env")) {
        command = while (words.next()) |argument| {
            if (!std.mem.startsWith(u8, argument, "-")) break argument;
        } else return null;
    }
    const interpreter = std.mem.trimEnd(u8, std.fs.path.basename(command), "0123456789.");
    return if (interpreter.len == 0) null else interpreter;
}

pub fn builtInGrammarName(path: []const u8, content: []const u8) ?[]const u8 {
    return (selectBuiltIn(path, content) orelse return null).name();
}

/// Resolves an Injection Grammar name. An Injection never selects a UserGrammar.
pub fn selectInjection(name: []const u8) ?BuiltInGrammar {
    var lower_buffer: [64]u8 = undefined;
    if (name.len > lower_buffer.len) return null;
    const lower = std.ascii.lowerString(&lower_buffer, name);
    const base = lower[if (std.mem.lastIndexOfScalar(u8, lower, '/')) |slash| slash + 1 else 0..];
    if (std.meta.stringToEnum(BuiltInGrammar, base)) |grammar| return grammar;
    var path_buffer: [lower_buffer.len + "injection.".len]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "injection.{s}", .{grammar_name.extension(base) orelse base}) catch unreachable;
    return selectBuiltIn(path, "");
}

test "M27 injection Grammar names resolve through tags, aliases, and GrammarMatch" {
    const cases = [_]struct { name: []const u8, grammar: ?BuiltInGrammar }{
        .{ .name = "css", .grammar = .css },
        .{ .name = "JavaScript", .grammar = .javascript },
        .{ .name = "text/javascript", .grammar = .javascript },
        .{ .name = "js", .grammar = .javascript },
        .{ .name = "shell", .grammar = .bash },
        .{ .name = "yml", .grammar = .yaml },
        .{ .name = "mts", .grammar = .typescript },
        .{ .name = "unknown", .grammar = null },
        .{ .name = "", .grammar = null },
        .{ .name = "text/", .grammar = null },
    };
    for (cases) |case| try std.testing.expectEqual(case.grammar, selectInjection(case.name));
    try std.testing.expectEqual(@as(?BuiltInGrammar, null), selectInjection("j" ** 65));
}

test "M27 grammar shebang interpreter drops the path, env flags, and version" {
    const cases = [_]struct { content: []const u8, interpreter: ?[]const u8 }{
        .{ .content = "#!/usr/bin/env python3.12\nprint()\n", .interpreter = "python" },
        .{ .content = "#!/usr/bin/env -S python3 -u\n", .interpreter = "python" },
        .{ .content = "#!/bin/sh -e\n", .interpreter = "sh" },
        .{ .content = "#! /usr/local/bin/bash5.2\r\n", .interpreter = "bash" },
        .{ .content = "#!/usr/bin/ruby", .interpreter = "ruby" },
        .{ .content = "#!/usr/bin/env\n", .interpreter = null },
        .{ .content = "#!/usr/bin/env -S\n", .interpreter = null },
        .{ .content = "#!/opt/1.2\n", .interpreter = null },
        .{ .content = "#!\n", .interpreter = null },
        .{ .content = "echo #!/bin/bash\n", .interpreter = null },
    };
    for (cases) |case| {
        const interpreter = shebangInterpreter(case.content);
        if (case.interpreter) |expected| try std.testing.expectEqualStrings(expected, interpreter.?) else try std.testing.expectEqual(@as(?[]const u8, null), interpreter);
    }
}

test "M27 injection alias table maps the new Grammar names" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "kotlin", "kt" }, .{ "make", "mk" },               .{ "makefile", "mk" }, .{ "docker", "dockerfile" },
        .{ "md", "md" },     .{ "dockerfile", "dockerfile" }, .{ "markdown", "md" }, .{ "c_sharp", "cs" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], grammar_name.extension(case[0]).?);
}
