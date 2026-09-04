const std = @import("std");
const bbr = @import("bbr");
const builtin = @import("builtin");
const harness = @import("harness.zig");
const synthetic = @import("synthetic.zig");
const diff_parse = @import("diff_parse.zig");
const buffer_projection = @import("buffer_projection.zig");
const intraline = @import("intraline.zig");
const side_by_side_matching = @import("side_by_side_matching.zig");

pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &stdout.interface;

    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const selected = arguments.next();
    if (arguments.next() != null) return error.TooManyArguments;

    const calibrations = try harness.calibrate(init.gpa, init.io);
    try writer.print(
        "host_os={s} host_arch={s} cpu={s} zig={s} mode={s} samples={d} warmups={d} instruction_ceiling={d:.2} memory_ceiling_bytes_per_second={d:.2}\n",
        .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            builtin.cpu.model.name,
            builtin.zig_version_string,
            @tagName(builtin.mode),
            harness.sample_count,
            harness.warmup_count,
            calibrations.instruction_units_per_second,
            calibrations.memory_bytes_per_second,
        },
    );

    const raw = try synthetic.largeDiff(init.gpa);
    defer init.gpa.free(raw);
    var parsed_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer parsed_arena.deinit();
    const parsed = try bbr.diff.parse(parsed_arena.allocator(), raw);
    const projection_context: buffer_projection.Context = .{ .diff = parsed };
    const line_pair = try synthetic.minifiedLinePair(init.gpa, 500);
    defer line_pair.deinit(init.gpa);

    var matched = false;
    if (selected == null or std.mem.eql(u8, selected.?, diff_parse.name)) {
        matched = true;
        try harness.run(writer, init.io, init.gpa, calibrations, diff_parse.name, .memory_bandwidth, raw.len, raw, diff_parse.run, diff_parse.checksum);
    }
    if (selected == null or std.mem.eql(u8, selected.?, buffer_projection.name)) {
        matched = true;
        try harness.run(
            writer,
            init.io,
            init.gpa,
            calibrations,
            buffer_projection.name,
            .memory_bandwidth,
            raw.len,
            &projection_context,
            buffer_projection.run,
            buffer_projection.checksum,
        );
    }
    if (selected == null or std.mem.eql(u8, selected.?, intraline.name)) {
        matched = true;
        try harness.run(
            writer,
            init.io,
            init.gpa,
            calibrations,
            intraline.name,
            .instruction_throughput,
            500 * 500,
            &line_pair,
            intraline.run,
            intraline.checksum,
        );
    }
    for ([_]usize{ 10, 100, 500 }) |line_count| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "side_by_side_matching_{d}x{d}", .{ line_count, line_count });
        if (selected == null or std.mem.eql(u8, selected.?, name)) {
            matched = true;
            const replacement = try synthetic.replacementBlock(init.gpa, line_count);
            defer init.gpa.free(replacement);
            var replacement_arena = std.heap.ArenaAllocator.init(init.gpa);
            defer replacement_arena.deinit();
            const replacement_diff = try bbr.diff.parse(replacement_arena.allocator(), replacement);
            const context: side_by_side_matching.Context = .{ .diff = replacement_diff };
            try harness.run(
                writer,
                init.io,
                init.gpa,
                calibrations,
                name,
                .instruction_throughput,
                line_count * line_count,
                &context,
                side_by_side_matching.run,
                side_by_side_matching.checksum,
            );
        }
    }
    if (!matched) return error.UnknownBenchmark;
    try writer.flush();
}
