//! Output helpers for `bbr api`: human lines by default, JSON with `--json`.
//! Human output goes to stdout (scriptable); errors go to stderr via
//! `std.debug.print` at call sites. stdout writes use the
//! `stdout.writer(io, &buf).interface` pattern from `main.zig --version`.

const std = @import("std");

/// Print a value as JSON to stdout. `init.io` drives the writer.
pub fn printJson(init: std.process.Init, value: anytype) !void {
    const gpa = init.gpa;
    const body = try std.json.Stringify.valueAlloc(gpa, value, .{
        .emit_null_optional_fields = false,
    });
    defer gpa.free(body);
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try stdout.interface.writeAll(body);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
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
    if (out_path) |path| {
        var f = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer f.close(init.io);
        try f.writeStreamingAll(init.io, raw);
    }
}

/// Read a whole file (for `--body-file` / `--content-file`). Caller frees.
pub fn readFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
}
