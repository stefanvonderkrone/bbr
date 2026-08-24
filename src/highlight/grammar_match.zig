const std = @import("std");

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
