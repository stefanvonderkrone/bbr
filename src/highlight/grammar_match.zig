const std = @import("std");
const grammar_name = @import("bbr").highlight.grammar_name;

pub const BuiltInGrammar = enum {
    tsx,
    typescript,
    javascript,
    css,
    go,
    bash,
    json,
    yaml,

    pub fn name(self: BuiltInGrammar) []const u8 {
        return switch (self) {
            .tsx => "TSX",
            .typescript => "TypeScript",
            .javascript => "JavaScript",
            .css => "CSS",
            .go => "Go",
            .bash => "Bash",
            .json => "JSON",
            .yaml => "YAML",
        };
    }
};

pub fn selectBuiltIn(path: []const u8, content: []const u8) ?BuiltInGrammar {
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or std.mem.endsWith(u8, path, ".cts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx") or std.mem.endsWith(u8, path, ".mjs") or std.mem.endsWith(u8, path, ".cjs")) return .javascript;
    if (std.mem.endsWith(u8, path, ".css")) return .css;
    if (std.mem.endsWith(u8, path, ".go")) return .go;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .yaml;
    const basename = std.fs.path.basename(path);
    const first_line = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash") or
        std.mem.eql(u8, basename, ".bashrc") or std.mem.eql(u8, basename, "Bashfile") or
        std.mem.startsWith(u8, first_line, "#!") and (std.mem.indexOf(u8, first_line, "bash") != null or std.mem.endsWith(u8, first_line, "/sh"))) return .bash;
    return null;
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

test "M27 injection alias table maps the new Grammar names" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "kotlin", "kt" }, .{ "make", "mk" },               .{ "makefile", "mk" }, .{ "docker", "dockerfile" },
        .{ "md", "md" },     .{ "dockerfile", "dockerfile" }, .{ "markdown", "md" }, .{ "c_sharp", "cs" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], grammar_name.extension(case[0]).?);
}
