const std = @import("std");
const bbr = @import("bbr");
const TreeSitterHighlighter = @import("benchmark_highlight").TreeSitterHighlighter;

pub const name = "highlight_javascript_100k";

pub const Context = struct {
    highlighter: *TreeSitterHighlighter,
    content: []const u8,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !bbr.highlight.HighlightResult {
    return context.highlighter.highlighter().highlight(allocator, "benchmark.js", context.content);
}

pub fn checksum(result: bbr.highlight.HighlightResult) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (result.spans) |span| {
        hash.update(std.mem.asBytes(&span.line));
        hash.update(std.mem.asBytes(&span.start));
        hash.update(std.mem.asBytes(&span.end));
        hash.update(std.mem.asBytes(&span.capture));
    }
    return hash.final();
}
