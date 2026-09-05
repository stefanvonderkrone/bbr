const std = @import("std");
const bbr = @import("bbr");
const builtin = @import("builtin");
const harness = @import("harness.zig");
const synthetic = @import("synthetic.zig");
const diff_parse = @import("diff_parse.zig");
const buffer_projection = @import("buffer_projection.zig");
const buffer_navigation = @import("buffer_navigation.zig");
const comment_anchors = @import("comment_anchors.zig");
const intraline = @import("intraline.zig");
const side_by_side_matching = @import("side_by_side_matching.zig");
const span_projection = @import("span_projection.zig");
const highlight = @import("highlight.zig");
const cell_width = @import("cell_width.zig");
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
    const span_raw = try synthetic.highlightedDiff(init.gpa, 5_000);
    defer init.gpa.free(span_raw);
    var span_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer span_arena.deinit();
    const span_diff = try bbr.diff.parse(span_arena.allocator(), span_raw);
    const sparse_spans = try fixtureSpans(span_arena.allocator(), 5_000, 20);
    const dense_spans = try fixtureSpans(span_arena.allocator(), 5_000, 1);
    const sparse_highlights = [_]bbr.highlight.FileHighlights{.{ .old = .{ .spans = sparse_spans }, .new = .{ .spans = sparse_spans } }};
    const dense_highlights = [_]bbr.highlight.FileHighlights{.{ .old = .{ .spans = dense_spans }, .new = .{ .spans = dense_spans } }};
    var navigation_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer navigation_arena.deinit();
    const navigation_context: buffer_navigation.Context = .{
        .buffer = try buffer_projection.run(navigation_arena.allocator(), &projection_context),
    };
    var comment_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer comment_arena.deinit();
    const comment_contexts = try commentAnchorContexts(comment_arena.allocator(), parsed);
    const highlight_content = try javascriptFixture(init.gpa, 100 * 1024);
    defer init.gpa.free(highlight_content);
    const cell_width_content = try asciiFixture(init.gpa, 1024 * 1024);
    defer init.gpa.free(cell_width_content);
    var tree_sitter_highlighter = try TreeSitterHighlighter.init(init.gpa, null);
    defer tree_sitter_highlighter.deinit();
    const highlight_context: highlight.Context = .{ .highlighter = &tree_sitter_highlighter, .content = highlight_content };
    var matched = false;
    if (selected == null or std.mem.eql(u8, selected.?, cell_width.name)) {
        matched = true;
        if (repeat_count) |count| try harness.repeat(
            writer,
            init.gpa,
            cell_width.name,
            count,
            cell_width_content,
            cell_width.run,
            cell_width.checksum,
        ) else try harness.run(
            writer,
            init.io,
            init.gpa,
            calibrations,
            cell_width.name,
            .instruction_throughput,
            cell_width_content.len,
            cell_width_content,
            cell_width.run,
            cell_width.checksum,
        );
    }
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
    for (&comment_contexts) |*context| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "comment_anchors_{d}", .{context.threads.len});
        if (selected == null or std.mem.eql(u8, selected.?, name)) {
            matched = true;
            if (repeat_count) |count| try harness.repeat(
                writer,
                init.gpa,
                name,
                count,
                context,
                comment_anchors.run,
                comment_anchors.checksum,
            ) else try harness.run(
                writer,
                init.io,
                init.gpa,
                calibrations,
                name,
                .instruction_throughput,
                parsed.files.len * (context.threads.len + context.drafts.len),
                context,
                comment_anchors.run,
                comment_anchors.checksum,
            );
        }
    }
    const span_benchmarks = [_]struct { name: []const u8, context: span_projection.Context }{
        .{ .name = "span_projection_unified_sparse", .context = .{ .diff = span_diff, .highlights = &sparse_highlights, .layout = .unified } },
        .{ .name = "span_projection_unified_dense", .context = .{ .diff = span_diff, .highlights = &dense_highlights, .layout = .unified } },
        .{ .name = "span_projection_side_by_side_sparse", .context = .{ .diff = span_diff, .highlights = &sparse_highlights, .layout = .side_by_side } },
        .{ .name = "span_projection_side_by_side_dense", .context = .{ .diff = span_diff, .highlights = &dense_highlights, .layout = .side_by_side } },
    };
    for (&span_benchmarks) |*benchmark| {
        if (selected == null or std.mem.eql(u8, selected.?, benchmark.name)) {
            matched = true;
            if (repeat_count) |count| try harness.repeat(
                writer,
                init.gpa,
                benchmark.name,
                count,
                &benchmark.context,
                span_projection.run,
                span_projection.checksum,
            ) else try harness.run(
                writer,
                init.io,
                init.gpa,
                calibrations,
                benchmark.name,
                .instruction_throughput,
                benchmark.context.highlights[0].new.?.spans.len * 5_000,
                &benchmark.context,
                span_projection.run,
                span_projection.checksum,
            );
        }
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

fn asciiFixture(allocator: std.mem.Allocator, byte_count: usize) ![]u8 {
    const content = try allocator.alloc(u8, byte_count);
    for (content, 0..) |*byte, index| byte.* = "abcdefghijklmnopqrstuvwxyz0123456789"[index % 36];
    return content;
}

fn fixtureSpans(allocator: std.mem.Allocator, line_count: usize, stride: usize) ![]bbr.highlight.Span {
    const spans = try allocator.alloc(bbr.highlight.Span, (line_count + stride - 1) / stride);
    for (spans, 0..) |*span, index| span.* = .{
        .line = @intCast(index * stride + 1),
        .start = 0,
        .end = 5,
        .capture = bbr.highlight.Capture.init(1, "keyword"),
    };
    return spans;
}

fn commentAnchorContexts(allocator: std.mem.Allocator, diff: bbr.diff.Diff) ![3]comment_anchors.Context {
    var contexts: [3]comment_anchors.Context = undefined;
    for ([_]usize{ 0, 100, 2_000 }, 0..) |count, context_index| {
        const comments = try allocator.alloc(bbr.review.Comment, count);
        const threads = try allocator.alloc(bbr.review.Thread, count);
        const drafts = try allocator.alloc(bbr.review.Draft, count);
        const disclosures = try allocator.alloc(comment_anchors.DisclosureKey, count * 2);
        for (0..count) |index| {
            const file = &diff.files[index % diff.files.len];
            const line_count = file.hunks[0].lines.len;
            const line: u32 = @intCast(index % line_count + 1);
            const id: u64 = @intCast(index + 1);
            comments[index] = .{ .id = id, .author = "A", .body = "comment", .anchor = .{ .path = file.new_path, .to = line } };
            threads[index] = .{ .root = &comments[index], .replies = &.{}, .resolved = false };
            drafts[index] = .{ .local_id = id, .kind = .comment, .body = "draft", .anchor = .{ .path = file.new_path, .to = line } };
            disclosures[index * 2] = .{ .review_card = .{ .comment = id } };
            disclosures[index * 2 + 1] = .{ .review_card = .{ .draft = id } };
        }
        contexts[context_index] = .{
            .diff = diff,
            .threads = threads,
            .drafts = drafts,
            .expanded_disclosures = disclosures,
        };
    }
    return contexts;
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
