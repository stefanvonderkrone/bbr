const std = @import("std");
const bbr = @import("bbr");
const TreeSitterHighlighter = @import("highlight/tree_sitter_highlighter.zig").TreeSitterHighlighter;
const grammar_match = @import("highlight/grammar_match.zig");
const enrichment = @import("tui/file_enrichment.zig");
const testing = std.testing;

test "diagnostics a failed BuiltInGrammar keeps its error and has one File Enrichment record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    try env.put("XDG_STATE_HOME", home);
    var sink = bbr.diagnostics.Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    try testing.expect(sink.setEnabled(true) == .on);
    var highlighter = try TreeSitterHighlighter.init(testing.allocator, null, sink.handle(.highlighting, .{}));
    defer highlighter.deinit();
    const package = &highlighter.packages[@intFromEnum(grammar_match.BuiltInGrammar.javascript)];
    const captures = package.captures;
    package.captures = captures[0..0];
    defer package.captures = captures;
    const Fixture = struct {
        fn read(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: bbr.diagnostics.Handle) anyerror![]u8 {
            return allocator.dupe(u8, "const private_source = 1;\n");
        }
    };
    var result = try enrichment.enrichFrom(testing.allocator, .{ .ptr = &highlighter, .read_fn = Fixture.read }, highlighter.highlighter(), .{
        .diagnostic = sink.handle(.file_enrichment, .{ .file_index = 7 }),
        .repo = "private_repo",
        .status = .added,
        .source_commit = "private_commit",
        .destination_commit = "",
        .old_path = "",
        .new_path = "private_path.js",
        .max_file_bytes = 0,
    });
    defer result.deinit();
    try testing.expectEqual(error.InvalidCapture, result.view().new.content.highlighting.failed);
    try testing.expectEqualStrings("const private_source = 1;\n", result.view().new.content.blob);
    var dir = try tmp.dir.openDir(testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(testing.io)).?;
    const bytes = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "error=InvalidCapture"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\n") - 1);
    try testing.expect(std.mem.indexOf(u8, bytes, "operation=highlighting phase=execute source=tui/file_enrichment.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "file_index=7 side=new") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "private_") == null);
}
