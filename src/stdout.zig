//! The only owner of the stdout writer. `tools/check_stdio_writers.py` fails on a stdout
//! writer in any other file.
//!
//! A failed write returns its cause, not the generic `error.WriteFailed` of `std.Io.Writer`.
//! When the reader closed the pipe, as `head` does after enough lines, the cause is
//! `error.StdoutClosed`. `main` ends with exit 0 and no message on that error. Every other
//! cause, such as `error.NoSpaceLeft`, stays a failure.

const std = @import("std");

/// Run `body` with a buffered stdout writer as its first argument, then flush the writer.
/// `args` holds the other arguments of `body`.
pub fn write(io: std.Io, comptime body: anytype, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    @call(.auto, body, .{&file_writer.interface} ++ args) catch |err| return cause(&file_writer, err);
    file_writer.interface.flush() catch |err| return cause(&file_writer, err);
}

/// Write formatted text to stdout.
pub fn print(io: std.Io, comptime format: []const u8, args: anytype) !void {
    return write(io, std.Io.Writer.print, .{ format, args });
}

/// Write bytes to stdout.
pub fn writeAll(io: std.Io, bytes: []const u8) !void {
    return write(io, std.Io.Writer.writeAll, .{bytes});
}

fn cause(file_writer: *const std.Io.File.Writer, err: anytype) (@TypeOf(err) || std.Io.File.Writer.Error || error{StdoutClosed}) {
    // A body can return only `error.WriteFailed`, a wider set, or a set that
    // does not contain it. Each shape needs its own switch so a prong is neither
    // missing nor unreachable.
    if (comptime !errorSetHas(@TypeOf(err), "WriteFailed")) return err;
    if (comptime errorSetOnly(@TypeOf(err), "WriteFailed")) {
        return switch (err) {
            error.WriteFailed => writeFailure(file_writer, err),
        };
    }
    return switch (err) {
        error.WriteFailed => writeFailure(file_writer, err),
        else => err,
    };
}

fn writeFailure(file_writer: *const std.Io.File.Writer, err: anytype) (@TypeOf(err) || std.Io.File.Writer.Error || error{StdoutClosed}) {
    return switch (file_writer.err orelse return err) {
        error.BrokenPipe => error.StdoutClosed,
        else => |failure| failure,
    };
}

fn errorSetHas(comptime Set: type, comptime name: []const u8) bool {
    const set = @typeInfo(Set).error_set orelse return true;
    for (set) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}

fn errorSetOnly(comptime Set: type, comptime name: []const u8) bool {
    const set = @typeInfo(Set).error_set orelse return false;
    return set.len == 1 and std.mem.eql(u8, set[0].name, name);
}

const FailingStdout = struct {
    failure: std.Io.Operation.FileWriteStreaming.Error,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.operate = operate;
        break :blk table;
    };

    fn io(self: *FailingStdout) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self: *FailingStdout = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(operation == .file_write_streaming);
        return .{ .file_write_streaming = self.failure };
    }
};

fn failWithoutWriting(_: *std.Io.Writer) error{InvalidGrammarCommand}!void {
    return error.InvalidGrammarCommand;
}

test "a closed stdout pipe is error.StdoutClosed and every other failure keeps its cause" {
    var closed: FailingStdout = .{ .failure = error.BrokenPipe };
    try std.testing.expectError(error.StdoutClosed, print(closed.io(), "bbr {s}\n", .{"version"}));

    var full: FailingStdout = .{ .failure = error.NoSpaceLeft };
    const larger_than_the_buffer = [_]u8{'x'} ** 5000;
    try std.testing.expectError(error.NoSpaceLeft, writeAll(full.io(), &larger_than_the_buffer));

    try std.testing.expectError(error.InvalidGrammarCommand, write(closed.io(), failWithoutWriting, .{}));
}
