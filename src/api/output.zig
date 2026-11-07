//! Output helpers for `bbr api`: human lines by default, JSON with `--json`.
//! Human output goes to stdout (scriptable); errors go to stderr via
//! `std.debug.print` at call sites. stdout writes go through `bbr.stdout`.

const std = @import("std");
const bbr = @import("bbr");

/// Return the text before the first CR or LF.
pub fn firstLine(text: []const u8) []const u8 {
    for (text, 0..) |byte, i| {
        if (byte == '\r' or byte == '\n') return text[0..i];
    }
    return text;
}

/// Print a value as JSON to stdout. `init.io` drives the writer.
pub fn printJson(init: std.process.Init, value: anytype) !void {
    try printJsonFile(init, value, "", null);
}

/// Write optional raw file output before printing the JSON result to stdout.
pub fn printJsonFile(init: std.process.Init, value: anytype, raw: []const u8, out_path: ?[]const u8) !void {
    try bbr.stdout.write(init.io, writeJsonFile, .{ init.io, init.gpa, value, raw, out_path });
}

fn writeJsonFile(writer: *std.Io.Writer, io: std.Io, gpa: std.mem.Allocator, value: anytype, raw: []const u8, out_path: ?[]const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, value, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(body);
    if (out_path) |path| try writeFile(io, raw, path);
    try writer.writeAll(body);
    try writer.writeAll("\n");
}

/// Print one line of text to stdout.
pub fn printLine(init: std.process.Init, comptime fmt: []const u8, args: anytype) !void {
    try bbr.stdout.print(init.io, fmt ++ "\n", args);
}

/// Print one `bbr api VERB: warning:` line to stderr. A warning does not stop the command.
pub fn printWarning(io: std.Io, verb: []const u8, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    try stderr.interface.print("bbr api {s}: warning: ", .{verb});
    try stderr.interface.print(fmt ++ "\n", args);
    try stderr.interface.flush();
}

/// Write raw bytes (diff/blob/patch) to the optional file, then print them to stdout.
/// The file comes first, so a reader that closes stdout early cannot stop the file.
pub fn printRaw(
    init: std.process.Init,
    raw: []const u8,
    out_path: ?[]const u8,
) !void {
    if (out_path) |path| try writeFile(init.io, raw, path);
    try bbr.stdout.writeAll(init.io, raw);
}

/// Write raw bytes to a file without writing to stdout.
pub fn writeFile(io: std.Io, raw: []const u8, path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = raw });
}

/// Read up to 1 MiB for text-file options. Caller frees.
pub fn readFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    // The reader fails when it reaches the limit. One extra byte permits an
    // exact 1 MiB file and still rejects every larger file.
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024 + 1));
}

test "JSON file output keeps binary bytes out of stdout and truncates empty files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blob", .{tmp.sub_path});
    defer a.free(path);

    for ([_][]const u8{ "\x00\xff\nraw", "" }) |raw| {
        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writeJsonFile(&writer, io, a, .{ .size = raw.len }, raw, path);
        const expected = try std.fmt.allocPrint(a, "{{\"size\":{d}}}\n", .{raw.len});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, writer.buffered());
        const saved = try tmp.dir.readFileAlloc(io, "blob", a, .limited(1024));
        defer a.free(saved);
        try std.testing.expectEqualSlices(u8, raw, saved);
    }
}

test "JSON file creation failure emits no success result" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/missing/blob", .{tmp.sub_path});
    defer a.free(path);
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(error.FileNotFound, writeJsonFile(&writer, std.testing.io, a, .{ .size = @as(usize, 3) }, "raw", path));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "firstLine stops at the first CR or LF" {
    for ([_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "", .expected = "" },
        .{ .text = "one line", .expected = "one line" },
        .{ .text = "first\nsecond", .expected = "first" },
        .{ .text = "first\rsecond", .expected = "first" },
        .{ .text = "first\r\nsecond", .expected = "first" },
        .{ .text = "first\nsecond\rthird", .expected = "first" },
        .{ .text = "\rfirst", .expected = "" },
        .{ .text = "\nfirst", .expected = "" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, firstLine(case.text));
    }
}
