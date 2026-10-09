//! Output helpers for `bbr api`: human lines by default, JSON with `--json`.
//! Human output goes to stdout (scriptable); errors go to stderr via
//! `std.debug.print` at call sites. stdout writes use the
//! `stdout.writer(io, &buf).interface` pattern from `main.zig --version`.

const std = @import("std");

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
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try writeJsonFile(init.io, init.gpa, &stdout.interface, value, raw, out_path);
}

fn writeJsonFile(io: std.Io, gpa: std.mem.Allocator, writer: *std.Io.Writer, value: anytype, raw: []const u8, out_path: ?[]const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, value, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(body);
    if (out_path) |path| try writeFile(io, raw, path);
    try writer.writeAll(body);
    try writer.writeAll("\n");
    try writer.flush();
}

/// Print one line of text to stdout.
pub fn printLine(init: std.process.Init, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try stdout.interface.print(fmt ++ "\n", args);
    try stdout.interface.flush();
}

/// Print raw bytes (diff/blob/patch) to stdout, optionally tee-ing to a file.
pub fn printRaw(
    init: std.process.Init,
    raw: []const u8,
    out_path: ?[]const u8,
) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try stdout.interface.writeAll(raw);
    try stdout.interface.flush();
    if (out_path) |path| try writeFile(init.io, raw, path);
}

/// Write raw bytes to a file without writing to stdout.
pub fn writeFile(io: std.Io, raw: []const u8, path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = raw });
}

/// Read a whole file (for `--body-file` / `--content-file`). Caller frees.
pub fn readFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
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
        try writeJsonFile(io, a, &writer, .{ .size = raw.len }, raw, path);
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
    try std.testing.expectError(error.FileNotFound, writeJsonFile(std.testing.io, a, &writer, .{ .size = @as(usize, 3) }, "raw", path));
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
