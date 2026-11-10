const std = @import("std");
const build_options = @import("build_options");
const file_cache = @import("benchmark/file_cache.zig");
const TreeSitterHighlighter = @import("highlight/tree_sitter_highlighter.zig").TreeSitterHighlighter;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| switch (err) {
        error.StdoutClosed => return 0,
        else => {
            var buffer: [64]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
            stderr.interface.print("error: {t}\n", .{err}) catch |write_err| switch (write_err) {
                error.WriteFailed => {},
            };
            stderr.interface.flush() catch |write_err| switch (write_err) {
                error.WriteFailed => {},
            };
            return file_cache.exitCode(err);
        },
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    var highlighter = try TreeSitterHighlighter.init(init.gpa, null, .{});
    defer highlighter.deinit();
    return file_cache.main(init, highlighter.highlighter(), build_options.version);
}
