const std = @import("std");

pub const sample_count = 15;
pub const warmup_count = 2;

pub const Ceiling = enum {
    instruction_throughput,
    memory_bandwidth,
};

pub const Calibrations = struct {
    instruction_units_per_second: f64,
    memory_bytes_per_second: f64,
};

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocation_count: usize = 0,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn cast(ptr: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ptr));
    }

    fn addBytes(self: *CountingAllocator, bytes: usize) void {
        self.current_bytes += bytes;
        self.peak_bytes = @max(self.peak_bytes, self.current_bytes);
    }

    fn allocate(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = cast(ptr);
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocation_count += 1;
        self.addBytes(len);
        return result;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = cast(ptr);
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            self.addBytes(new_len - memory.len);
        } else {
            self.current_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = cast(ptr);
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            self.addBytes(new_len - memory.len);
        } else {
            self.current_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = cast(ptr);
        self.current_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

pub fn calibrate(gpa: std.mem.Allocator, io: std.Io) !Calibrations {
    const instruction_iterations = 20_000_000;
    var value: u64 = 0x9e3779b97f4a7c15;
    const instruction_start = std.Io.Clock.awake.now(io);
    for (0..instruction_iterations) |i| {
        value = (value ^ @as(u64, @intCast(i))) *% 0xbf58476d1ce4e5b9;
    }
    std.mem.doNotOptimizeAway(value);
    const instruction_ns = elapsedNanoseconds(instruction_start, io);

    const memory_size = 32 * 1024 * 1024;
    const memory_copies = 4;
    const source = try gpa.alloc(u8, memory_size);
    defer gpa.free(source);
    const destination = try gpa.alloc(u8, memory_size);
    defer gpa.free(destination);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    const memory_start = std.Io.Clock.awake.now(io);
    for (0..memory_copies) |_| @memcpy(destination, source);
    std.mem.doNotOptimizeAway(destination);
    const memory_ns = elapsedNanoseconds(memory_start, io);

    return .{
        .instruction_units_per_second = rate(instruction_iterations, instruction_ns),
        .memory_bytes_per_second = rate(memory_size * memory_copies, memory_ns),
    };
}

pub fn run(
    writer: *std.Io.Writer,
    io: std.Io,
    gpa: std.mem.Allocator,
    calibrations: Calibrations,
    name: []const u8,
    ceiling: Ceiling,
    units_per_sample: usize,
    context: anytype,
    comptime benchmark: anytype,
    comptime checksumOutput: anytype,
) !void {
    for (0..warmup_count) |_| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var counting: CountingAllocator = .{ .backing = arena.allocator() };
        const output = try benchmark(counting.allocator(), context);
        std.mem.doNotOptimizeAway(checksumOutput(output));
    }

    var durations: [sample_count]u64 = undefined;
    var allocations: [sample_count]usize = undefined;
    var peaks: [sample_count]usize = undefined;
    var retained: [sample_count]usize = undefined;
    var expected_checksum: ?u64 = null;

    for (0..sample_count) |sample| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        var counting: CountingAllocator = .{ .backing = arena.allocator() };
        const start = std.Io.Clock.awake.now(io);
        const output = try benchmark(counting.allocator(), context);
        durations[sample] = elapsedNanoseconds(start, io);
        const checksum = checksumOutput(output);
        allocations[sample] = counting.allocation_count;
        peaks[sample] = counting.peak_bytes;
        retained[sample] = arena.queryCapacity();
        arena.deinit();

        if (expected_checksum) |expected| {
            if (checksum != expected) return error.UnstableBenchmarkOutput;
        } else {
            expected_checksum = checksum;
        }
    }

    std.mem.sort(u64, &durations, {}, std.sort.asc(u64));
    std.mem.sort(usize, &allocations, {}, std.sort.asc(usize));
    std.mem.sort(usize, &peaks, {}, std.sort.asc(usize));
    std.mem.sort(usize, &retained, {}, std.sort.asc(usize));
    const median_ns = durations[sample_count / 2];
    const p95_ns = durations[(sample_count * 95 + 99) / 100 - 1];
    const ceiling_rate = switch (ceiling) {
        .instruction_throughput => calibrations.instruction_units_per_second,
        .memory_bandwidth => calibrations.memory_bytes_per_second,
    };
    const measured_rate = rate(units_per_sample, median_ns);
    const gap = if (measured_rate < ceiling_rate) (ceiling_rate - measured_rate) * 100.0 / ceiling_rate else 0;

    try writer.print(
        "benchmark={s} median_ns={d} p95_ns={d} allocations={d} peak_bytes={d} retained_bytes={d} checksum={x} ceiling={s} ceiling_rate={d:.2} measured_rate={d:.2} gap_percent={d:.2}\n",
        .{
            name,
            median_ns,
            p95_ns,
            allocations[sample_count / 2],
            peaks[sample_count / 2],
            retained[sample_count / 2],
            expected_checksum.?,
            @tagName(ceiling),
            ceiling_rate,
            measured_rate,
            gap,
        },
    );
}

pub fn repeat(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    name: []const u8,
    count: usize,
    context: anytype,
    comptime benchmark: anytype,
    comptime checksumOutput: anytype,
) !void {
    var expected_checksum: ?u64 = null;
    for (0..count) |_| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const output = try benchmark(arena.allocator(), context);
        const checksum = checksumOutput(output);
        std.mem.doNotOptimizeAway(checksum);
        if (expected_checksum) |expected| {
            if (checksum != expected) return error.UnstableBenchmarkOutput;
        } else {
            expected_checksum = checksum;
        }
    }
    try writer.print("profile={s} repetitions={d} checksum={x}\n", .{ name, count, expected_checksum.? });
}

fn elapsedNanoseconds(start: std.Io.Timestamp, io: std.Io) u64 {
    return @intCast(start.untilNow(io, .awake).toNanoseconds());
}

fn rate(units: usize, nanoseconds: u64) f64 {
    if (nanoseconds == 0) return 0;
    return @as(f64, @floatFromInt(units)) * @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(nanoseconds));
}
