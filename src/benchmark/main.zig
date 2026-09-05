const std = @import("std");
const bbr = @import("bbr");
const builtin = @import("builtin");
const harness = @import("harness.zig");
const synthetic = @import("synthetic.zig");
const diff_parse = @import("diff_parse.zig");
const buffer_projection = @import("buffer_projection.zig");
const buffer_navigation = @import("buffer_navigation.zig");
const intraline = @import("intraline.zig");
const side_by_side_matching = @import("side_by_side_matching.zig");
const highlight = @import("highlight.zig");
const TreeSitterHighlighter = @import("benchmark_highlight").TreeSitterHighlighter;

pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &stdout.interface;

    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    var selected = arguments.next();
    var repeat_count: ?usize = null;
    if (selected != null and std.mem.eql(u8, selected.?, "--repeat")) {
        repeat_count = try std.fmt.parseInt(usize, arguments.next() orelse return error.MissingRepeatCount, 10);
        if (repeat_count.? == 0) return error.InvalidRepeatCount;
        selected = arguments.next() orelse return error.MissingBenchmark;
    }
    if (arguments.next() != null) return error.TooManyArguments;

    const calibrations = try harness.calibrate(init.gpa, init.io);
    const host_cpu = try hostCpu(init.gpa, init.io);
    defer init.gpa.free(host_cpu);
    try writer.print(
        "host_os={s} host_arch={s} host_cpu={s} target_cpu={s} zig={s} mode={s} samples={d} warmups={d} instruction_ceiling={d:.2} memory_ceiling_bytes_per_second={d:.2}\n",
        .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            host_cpu,
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
    var navigation_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer navigation_arena.deinit();
    const navigation_context: buffer_navigation.Context = .{
        .buffer = try buffer_projection.run(navigation_arena.allocator(), &projection_context),
    };
    const highlight_content = try javascriptFixture(init.gpa, 100 * 1024);
    defer init.gpa.free(highlight_content);
    var tree_sitter_highlighter = try TreeSitterHighlighter.init(init.gpa, null);
    defer tree_sitter_highlighter.deinit();
    const highlight_context: highlight.Context = .{ .highlighter = &tree_sitter_highlighter, .content = highlight_content };
    var matched = false;
    if (selected == null or std.mem.eql(u8, selected.?, highlight.name)) {
        matched = true;
        if (repeat_count) |count| try harness.repeat(
            writer,
            init.gpa,
            highlight.name,
            count,
            &highlight_context,
            highlight.run,
            highlight.checksum,
        ) else try harness.run(
            writer,
            init.io,
            init.gpa,
            calibrations,
            highlight.name,
            .instruction_throughput,
            highlight_content.len,
            &highlight_context,
            highlight.run,
            highlight.checksum,
        );
    }
    if (selected == null or std.mem.eql(u8, selected.?, diff_parse.name)) {
        matched = true;
        if (repeat_count) |count|
            try harness.repeat(writer, init.gpa, diff_parse.name, count, raw, diff_parse.run, diff_parse.checksum)
        else
            try harness.run(writer, init.io, init.gpa, calibrations, diff_parse.name, .memory_bandwidth, raw.len, raw, diff_parse.run, diff_parse.checksum);
    }
    if (selected == null or std.mem.eql(u8, selected.?, buffer_projection.name)) {
        matched = true;
        if (repeat_count) |count| try harness.repeat(
            writer,
            init.gpa,
            buffer_projection.name,
            count,
            &projection_context,
            buffer_projection.run,
            buffer_projection.checksum,
        ) else try harness.run(
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
    if (selected == null or std.mem.eql(u8, selected.?, buffer_navigation.name)) {
        matched = true;
        if (repeat_count) |count| try harness.repeat(
            writer,
            init.gpa,
            buffer_navigation.name,
            count,
            &navigation_context,
            buffer_navigation.run,
            buffer_navigation.checksum,
        ) else try harness.run(
            writer,
            init.io,
            init.gpa,
            calibrations,
            buffer_navigation.name,
            .instruction_throughput,
            1_000,
            &navigation_context,
            buffer_navigation.run,
            buffer_navigation.checksum,
        );
    }
    for ([_]usize{ 10, 100, 250, 500, 550, 575, 600, 1_000, 2_000, 4_000 }) |part_count| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "intraline_{d}_parts", .{part_count});
        if (selected == null or std.mem.eql(u8, selected.?, name)) {
            matched = true;
            const line_pair = try synthetic.minifiedLinePair(init.gpa, part_count);
            defer line_pair.deinit(init.gpa);
            if (repeat_count) |count| try harness.repeat(
                writer,
                init.gpa,
                name,
                count,
                &line_pair,
                intraline.run,
                intraline.checksum,
            ) else try harness.run(
                writer,
                init.io,
                init.gpa,
                calibrations,
                name,
                .instruction_throughput,
                part_count * part_count,
                &line_pair,
                intraline.run,
                intraline.checksum,
            );
        }
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
            if (repeat_count) |count| try harness.repeat(
                writer,
                init.gpa,
                name,
                count,
                &context,
                side_by_side_matching.run,
                side_by_side_matching.checksum,
            ) else try harness.run(
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

fn javascriptFixture(allocator: std.mem.Allocator, minimum_bytes: usize) ![]u8 {
    const line = "export function calculate(value) { return value + 1; }\n";
    const line_count = (minimum_bytes + line.len - 1) / line.len;
    const content = try allocator.alloc(u8, line_count * line.len);
    for (0..line_count) |index| @memcpy(content[index * line.len ..][0..line.len], line);
    return content;
}

fn hostCpu(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (builtin.os.tag != .macos) return allocator.dupe(u8, "unknown");
    const result = std.process.run(allocator, io, .{ .argv = &.{ "sysctl", "-n", "machdep.cpu.brand_string" } }) catch
        return allocator.dupe(u8, "unknown");
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return allocator.dupe(u8, "unknown");
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}
