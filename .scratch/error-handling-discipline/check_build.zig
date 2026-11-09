//! Analyze every Zig artifact of build.zig without code generation.
//! convert_drops.py copies this file to the repository root, because a build file's
//! directory is its build root, and runs `zig build --build-file <copy> analyze`.
const std = @import("std");
const project = @import("build.zig");

pub fn build(b: *std.Build) void {
    project.build(b);
    const analyze = b.step("analyze", "Analyze every unfiltered Zig artifact with -fno-emit-bin");
    var seen: std.AutoArrayHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (b.top_level_steps.values()) |top| visit(b, analyze, &seen, &top.step);
}

fn visit(
    b: *std.Build,
    analyze: *std.Build.Step,
    seen: *std.AutoArrayHashMapUnmanaged(*std.Build.Step, void),
    step: *std.Build.Step,
) void {
    if (step == analyze) return;
    if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    for (step.dependencies.items) |dependency| visit(b, analyze, seen, dependency);
    const compile = step.cast(std.Build.Step.Compile) orelse return;
    // A filtered test binary analyzes a subset of its unfiltered twin.
    if (compile.filters.len != 0 or compile.root_module.root_source_file == null) return;
    const name = b.fmt("{s}-analyze", .{compile.name});
    // No getEmittedBin call, so the copy passes -fno-emit-bin.
    const copy = switch (compile.kind) {
        .exe => b.addExecutable(.{ .name = name, .root_module = compile.root_module }),
        .@"test" => b.addTest(.{ .name = name, .root_module = compile.root_module }),
        else => return,
    };
    analyze.dependOn(&copy.step);
}
