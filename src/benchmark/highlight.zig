const std = @import("std");
const bbr = @import("bbr");
const TreeSitterHighlighter = @import("benchmark_highlight").TreeSitterHighlighter;

pub const name = "highlight_javascript_100k";

pub const Context = struct {
    highlighter: *TreeSitterHighlighter,
    path: []const u8,
    content: []const u8,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !bbr.highlight.HighlightResult {
    return context.highlighter.highlighter().highlight(allocator, context.path, context.content);
}

pub fn runSplit(result_allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, context: *const Context) !bbr.highlight.HighlightResult {
    return context.highlighter.highlighter().highlightWithScratch(result_allocator, scratch_allocator, context.path, context.content);
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

pub const Pair = struct {
    first: bbr.highlight.HighlightResult,
    second: bbr.highlight.HighlightResult,
};

pub fn runEqualPair(allocator: std.mem.Allocator, context: *const Context) !Pair {
    return .{
        .first = try run(allocator, context),
        .second = try run(allocator, context),
    };
}

pub fn pairChecksum(pair: Pair) u64 {
    return checksum(pair.first) ^ std.math.rotl(u64, checksum(pair.second), 1);
}
