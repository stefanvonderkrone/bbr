const std = @import("std");
const diagnostics = @import("diagnostics.zig");

/// Records the cause before its message. A failed message gets its own record, and
/// callers receive only Reported, so no boundary prints or records either failure again.
pub fn fail(
    io: std.Io,
    diagnostic: diagnostics.Handle,
    phase: diagnostics.Phase,
    cause: diagnostics.Cause,
    comptime source: std.builtin.SourceLocation,
    comptime body: anytype,
    args: anytype,
) error{Reported} {
    const reported = diagnostic.fail(phase, cause, source);
    write(io, body, args) catch |err| {
        _ = diagnostic.failure(.write, .{ .zig = err }, source);
        switch (err) {
            error.Canceled => io.recancel(),
            else => {},
        }
    };
    return reported;
}

fn write(io: std.Io, comptime body: anytype, args: anytype) !void {
    var buffer: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    @call(.auto, body, .{&stderr.interface} ++ args) catch |err| return stderr.err orelse err;
    stderr.interface.flush() catch |err| return stderr.err orelse err;
}
