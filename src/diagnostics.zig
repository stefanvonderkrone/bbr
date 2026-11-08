const std = @import("std");
const value = @import("diagnostic.zig");
const xdg = @import("xdg.zig");
pub const Failure = value.Failure;
pub const State = value.State;
pub const Context = value.Context;
pub const Cause = value.Cause;
pub const GrammarRule = value.GrammarRule;
pub const Operation = value.Operation;
pub const Phase = value.Phase;

pub const Handle = struct {
    sink: ?*Sink = null,
    operation: Operation = .startup,
    context: Context = .{},

    pub fn forContext(self: Handle, operation: Operation, context: Context) Handle {
        return .{ .sink = self.sink, .operation = operation, .context = context };
    }

    pub fn failure(self: Handle, phase: Phase, cause: Cause, comptime source: std.builtin.SourceLocation) Failure {
        const result = Failure.capture(self.operation, phase, self.context, cause, source);
        self.record(result);
        return result;
    }

    /// Records the Failure and returns `error.Reported`. Callers propagate it with `try`,
    /// and a boundary skips it, so no layer records the same failure again.
    pub fn fail(self: Handle, phase: Phase, cause: Cause, comptime source: std.builtin.SourceLocation) error{Reported} {
        _ = self.failure(phase, cause, source);
        return error.Reported;
    }

    /// Drops a Failure whose cause is `error.Reported`, because the layer that returned it
    /// already recorded the failure. A boundary that forgets its `error.Reported` prong
    /// therefore writes no second record.
    pub fn record(self: Handle, failure_value: Failure) void {
        if (failure_value.reported()) return;
        if (self.sink) |sink| sink.record(failure_value);
    }
};

pub const Sink = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    mutex: std.Io.Mutex = .init,
    actual: State = .off,
    file: ?std.Io.File = null,
    run_id: u64 = 0,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Sink {
        return .{ .allocator = allocator, .io = io, .env = env };
    }

    pub fn handle(self: *Sink, operation: Operation, context: Context) Handle {
        return .{ .sink = self, .operation = operation, .context = context };
    }

    pub fn deinit(self: *Sink) void {
        _ = self.setEnabled(false);
    }

    pub fn state(self: *Sink) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.actual;
    }

    pub fn setEnabled(self: *Sink, enabled: bool) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!enabled) {
            if (self.file) |file| file.close(self.io);
            self.file = null;
            self.actual = .off;
        } else if (self.actual != .on) {
            self.enable() catch |err| self.fail(err, .open);
        }
        return self.actual;
    }

    fn enable(self: *Sink) !void {
        const home = (try xdg.stateHome(self.allocator, self.env)) orelse return error.NoStateLocation;
        defer self.allocator.free(home);
        const path = try std.fs.path.join(self.allocator, &.{ home, "bbr", "diagnostics" });
        defer self.allocator.free(path);
        const cwd = std.Io.Dir.cwd();
        _ = try cwd.createDirPathStatus(self.io, path, .fromMode(0o700));
        var dir = try cwd.openDir(self.io, path, .{ .follow_symlinks = false });
        defer dir.close(self.io);
        if ((try dir.stat(self.io)).permissions.toMode() & 0o077 != 0) return error.InsecureDiagnosticDirectory;
        if (self.run_id == 0) try self.io.randomSecure(std.mem.asBytes(&self.run_id));
        var nonce: u64 = undefined;
        for (0..8) |_| {
            try self.io.randomSecure(std.mem.asBytes(&nonce));
            var name_buffer: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{x:0>16}-{x:0>16}.log", .{ self.run_id, nonce });
            const file = dir.createFile(self.io, name, .{ .exclusive = true, .truncate = false, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer file.close(self.io);
            var header_buffer: [128]u8 = undefined;
            const header = try std.fmt.bufPrint(&header_buffer, "bbr-diagnostics-v1 run={x:0>16}\n", .{self.run_id});
            try file.writeStreamingAll(self.io, header);
            self.file = file;
            self.actual = .on;
            return;
        }
        return error.DiagnosticNameCollision;
    }

    fn fail(self: *Sink, err: anyerror, phase: Phase) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
        self.actual = .{ .unavailable = Failure.capture(.diagnostics, phase, .{}, .{ .zig = err }, @src()) };
    }

    pub fn deliveryFailed(self: *Sink, failure_value: Failure) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.actual != .on) return;
        if (self.file) |file| file.close(self.io);
        self.file = null;
        self.actual = .{ .unavailable = failure_value };
    }

    fn record(self: *Sink, failure_value: Failure) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.actual != .on) return;
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.write(failure_value) catch |err| self.fail(err, .write);
    }

    fn write(self: *Sink, failure_value: Failure) !void {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        self.sequence += 1;
        try writer.print("v=1 time_ns={d} run={x:0>16} seq={d} operation={s} phase={s} source={s}:{d}:{d}", .{
            std.Io.Clock.real.now(self.io).toNanoseconds(), self.run_id,                   self.sequence,
            @tagName(failure_value.operation),              @tagName(failure_value.phase), failure_value.source.file,
            failure_value.source.line,                      failure_value.source.column,
        });
        inline for (@typeInfo(Context).@"struct".fields) |field| {
            if (@field(failure_value.context, field.name)) |number| {
                if (@typeInfo(@TypeOf(number)) == .@"enum") {
                    try writer.print(" {s}={s}", .{ field.name, @tagName(number) });
                } else try writer.print(" {s}={d}", .{ field.name, number });
            }
        }
        switch (failure_value.cause) {
            .zig => |err| try writer.print(" cause=zig error={s}", .{@errorName(err)}),
            .http => |http| try writer.print(" cause=http status={d} classification={s}", .{ http.status, @tagName(http.classification) }),
            .git => |git| try writer.print(" cause=git termination={s} code={d}", .{ @tagName(git.kind), git.code }),
            .sqlite => |sqlite| try writer.print(" cause=sqlite result={d} extended={d}", .{ sqlite.result, sqlite.extended }),
            .grammar => |grammar| try writer.print(" cause=grammar rule={s} code={d} offset={d}", .{ @tagName(grammar.rule), grammar.code, grammar.offset }),
        }
        try writer.writeByte('\n');
        try self.file.?.writeStreamingAll(self.io, writer.buffered());
    }
};

const testing = std.testing;

fn testHome(env: *std.process.Environ.Map, tmp: anytype) !void {
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    try env.put("XDG_STATE_HOME", path);
}

test "diagnostics off creates nothing and unavailable enable never claims success" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    _ = sink.handle(.picker_list, .{}).failure(.read, .{ .zig = error.OriginalPickerFailure }, @src());
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "bbr", .{}));
    try env.put("XDG_STATE_HOME", "relative");
    try testing.expect(sink.setEnabled(true) == .unavailable);
    try testing.expect(sink.setEnabled(false) == .off);
}

test "diagnostics private files retain original safe evidence and disable is a barrier" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    try testing.expect(sink.setEnabled(true) == .on);
    const file = sink.file.?;
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(testing.io)).permissions.toMode() & 0o777);
    _ = sink.handle(.picker_list, .{ .command_id = 17, .work_id = 29 }).failure(.read, .{ .zig = error.OriginalPickerFailure }, @src());
    const before = (try file.stat(testing.io)).size;
    try testing.expect(sink.setEnabled(true) == .on);
    try testing.expectEqual(before, (try file.stat(testing.io)).size);
    try testing.expect(sink.setEnabled(false) == .off);
    _ = sink.handle(.picker_list, .{}).failure(.read, .{ .zig = error.AfterDisable }, @src());
    var dir = try tmp.dir.openDir(testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(testing.io)).?;
    const bytes = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(8192));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(before, bytes.len);
    for ([_][]const u8{ "OriginalPickerFailure", "command_id=17", "work_id=29", "source=diagnostics.zig:" }) |needle|
        try testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "AfterDisable") == null);
    try testing.expect(sink.setEnabled(true) == .on);
    var fresh = dir.iterate();
    _ = try fresh.next(testing.io);
    try testing.expect((try fresh.next(testing.io)) != null);
}

fn failingLeaf(handle: Handle) error{Reported}!void {
    return handle.fail(.read, .{ .zig = error.LeafFailure }, @src());
}

fn propagatingCaller(handle: Handle) error{Reported}!void {
    try failingLeaf(handle);
}

test "diagnostics fail records the leaf cause once and propagates error.Reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    try testing.expect(sink.setEnabled(true) == .on);
    try testing.expectError(error.Reported, propagatingCaller(sink.handle(.grammar, .{})));
    try testing.expectError(error.Reported, propagatingCaller(.{}));
    _ = sink.setEnabled(false);
    var dir = try tmp.dir.openDir(testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(testing.io)).?;
    const bytes = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(8192));
    defer testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    _ = lines.next();
    const only = lines.next().?;
    try testing.expect(lines.next() == null);
    try testing.expect(std.mem.indexOf(u8, only, "operation=grammar phase=read source=diagnostics.zig:") != null);
    try testing.expect(std.mem.endsWith(u8, only, "cause=zig error=LeafFailure"));
}

fn boundaryWithoutReportedProng(handle: Handle) void {
    propagatingCaller(handle) catch |err| {
        _ = handle.failure(.execute, .{ .zig = err }, @src());
    };
}

test "diagnostics a boundary that records error.Reported writes no second record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    try testing.expect(sink.setEnabled(true) == .on);
    boundaryWithoutReportedProng(sink.handle(.grammar, .{}));
    try testing.expectEqual(@as(u64, 1), sink.sequence);
    _ = sink.handle(.grammar, .{}).failure(.execute, .{ .zig = error.Unrecorded }, @src());
    try testing.expectEqual(@as(u64, 2), sink.sequence);
}

fn writeMany(handle: Handle) void {
    for (0..100) |_| _ = handle.failure(.read, .{ .zig = error.ConcurrentFailure }, @src());
}

test "diagnostics concurrent records stay complete and separate sinks own separate files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    var other = Sink.init(testing.allocator, testing.io, &env);
    defer other.deinit();
    try testing.expect(sink.setEnabled(true) == .on);
    try testing.expect(other.setEnabled(true) == .on);
    var first = try testing.io.concurrent(writeMany, .{sink.handle(.picker_list, .{ .work_id = 1 })});
    var second = try testing.io.concurrent(writeMany, .{sink.handle(.picker_list, .{ .work_id = 2 })});
    first.await(testing.io);
    second.await(testing.io);
    try testing.expectEqual(@as(u64, 200), sink.sequence);
    _ = sink.setEnabled(false);
    _ = other.setEnabled(false);
    var dir = try tmp.dir.openDir(testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    var files: usize = 0;
    var total_records: usize = 0;
    while (try iterator.next(testing.io)) |entry| {
        files += 1;
        const bytes = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(128 * 1024));
        defer testing.allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        _ = lines.next();
        var records: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            records += 1;
            try testing.expect(std.mem.startsWith(u8, line, "v=1 "));
            try testing.expect(std.mem.endsWith(u8, line, "error=ConcurrentFailure"));
            try testing.expect((std.mem.indexOf(u8, line, "work_id=1") != null) != (std.mem.indexOf(u8, line, "work_id=2") != null));
        }
        try testing.expect(records == 0 or records == 200);
        total_records += records;
    }
    try testing.expectEqual(@as(usize, 2), files);
    try testing.expectEqual(@as(usize, 200), total_records);
}

test "diagnostics write failure closes the sink and keeps the original sink error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    try testing.expect(sink.setEnabled(true) == .on);
    var failing_writes = testing.io.vtable.*;
    failing_writes.operate = std.Io.failingOperate;
    sink.io.vtable = &failing_writes;
    const handle_before_failure = sink.handle(.persistence, .{});
    _ = handle_before_failure.failure(.write, .{ .zig = error.PrimaryFailure }, @src());
    const unavailable = sink.state();
    try testing.expect(unavailable == .unavailable);
    try testing.expectEqual(error.InputOutput, unavailable.unavailable.cause.zig);
    try testing.expectEqual(Phase.write, unavailable.unavailable.phase);
    try testing.expect(sink.file == null);
    const sequence = sink.sequence;
    _ = handle_before_failure.failure(.write, .{ .zig = error.LaterFailure }, @src());
    try testing.expectEqual(sequence, sink.sequence);
    sink.io = testing.io;
    try testing.expect(sink.setEnabled(true) == .on);
}

test "diagnostics handles created while off follow enablement and concurrent disablement" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    const existing_client = sink.handle(.picker_list, .{ .command_id = 13 });
    _ = existing_client.failure(.read, .{ .zig = error.BeforeEnablement }, @src());
    try testing.expect(sink.setEnabled(true) == .on);
    _ = existing_client.failure(.read, .{ .zig = error.AfterEnablement }, @src());
    var worker = try testing.io.concurrent(writeMany, .{existing_client});
    try testing.expect(sink.setEnabled(false) == .off);
    const at_disable = sink.sequence;
    worker.await(testing.io);
    _ = existing_client.failure(.read, .{ .zig = error.AfterDisablement }, @src());
    try testing.expectEqual(at_disable, sink.sequence);
    var dir = try tmp.dir.openDir(testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    const entry = (try iterator.next(testing.io)).?;
    const bytes = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(128 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "AfterEnablement") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "BeforeEnablement") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "AfterDisablement") == null);
}

test "diagnostics refuses a shared directory and a symbolic link without changing either" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testHome(&env, tmp);
    try tmp.dir.createDirPath(testing.io, "bbr/diagnostics");
    var dir = try tmp.dir.openDir(testing.io, "bbr/diagnostics", .{ .iterate = true });
    defer dir.close(testing.io);
    try dir.setPermissions(testing.io, .fromMode(0o755));
    var sink = Sink.init(testing.allocator, testing.io, &env);
    defer sink.deinit();
    try testing.expect(sink.setEnabled(true) == .unavailable);
    try testing.expectEqual(error.InsecureDiagnosticDirectory, sink.state().unavailable.cause.zig);
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), (try dir.stat(testing.io)).permissions.toMode() & 0o777);
    var iterator = dir.iterate();
    try testing.expect((try iterator.next(testing.io)) == null);
    try tmp.dir.rename("bbr/diagnostics", tmp.dir, "bbr/private-target", testing.io);
    try dir.setPermissions(testing.io, .fromMode(0o700));
    try tmp.dir.symLink(testing.io, "private-target", "bbr/diagnostics", .{ .is_directory = true });
    try testing.expect(sink.setEnabled(true) == .unavailable);
    var fresh = dir.iterate();
    try testing.expect((try fresh.next(testing.io)) == null);
}
