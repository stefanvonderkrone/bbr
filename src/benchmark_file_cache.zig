const std = @import("std");
const build_options = @import("build_options");
const file_cache = @import("benchmark/file_cache.zig");
const TreeSitterHighlighter = @import("highlight/tree_sitter_highlighter.zig").TreeSitterHighlighter;

pub fn main(init: std.process.Init) !void {
    var highlighter = try TreeSitterHighlighter.init(init.gpa, null);
    defer highlighter.deinit();
    return file_cache.main(init, highlighter.highlighter(), build_options.version);
}
