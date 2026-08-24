const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The network-free core, exposed as the `bbr` module (no TUI deps → testable).
    const mod = b.addModule("bbr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const zf = b.dependency("zf", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // The vendored SQLite amalgamation is compiled into the executable (it
        // needs libc). The pure `bbr` module stays C-free so its tests run with
        // no C toolchain — the persistence seam is faked there (ADR-0003, 0006).
        .link_libc = true,
        .imports = &.{
            .{ .name = "bbr", .module = mod },
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            .{ .name = "zf", .module = zf.module("zf") },
        },
    });
    addSqlite(b, exe_mod);
    addTreeSitter(b, exe_mod);

    const exe = b.addExecutable(.{ .name = "bbr", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run bbr");
    run_step.dependOn(&run_cmd.step);

    // Live smoke check against real Bitbucket (opt-in; needs BITBUCKET_* env):
    //   zig build check -- <repo-slug> <pr-id>
    const check_cmd = b.addRunArtifact(exe);
    check_cmd.step.dependOn(b.getInstallStep());
    check_cmd.addArg("check");
    if (b.args) |args| check_cmd.addArgs(args);
    const check_step = b.step("check", "Live smoke check against Bitbucket: zig build check -- <repo> <id>");
    check_step.dependOn(&check_cmd.step);

    const blob_check_cmd = b.addRunArtifact(exe);
    blob_check_cmd.step.dependOn(b.getInstallStep());
    blob_check_cmd.addArg("check-blobs");
    if (b.args) |args| blob_check_cmd.addArgs(args);
    const blob_check_step = b.step("check-blobs", "Opt-in Bitbucket file metadata/raw checker");
    blob_check_step.dependOn(&blob_check_cmd.step);

    // Destructive and PTY checks remain explicit opt-in tiers outside tests.
    const mutation_cmd = b.addRunArtifact(exe);
    mutation_cmd.step.dependOn(b.getInstallStep());
    mutation_cmd.addArg("check-mutation");
    if (b.args) |args| mutation_cmd.addArgs(args);
    const mutation_step = b.step("check-mutation", "Destructive Bitbucket Comment lifecycle check (requires opt-in)");
    mutation_step.dependOn(&mutation_cmd.step);

    const external_edit_cmd = b.addRunArtifact(exe);
    external_edit_cmd.step.dependOn(b.getInstallStep());
    external_edit_cmd.addArg("external-edit-smoke");
    const external_edit_step = b.step("check-external-edit", "Interactive External Edit PTY check (requires opt-in)");
    external_edit_step.dependOn(&external_edit_cmd.step);

    // `zig build test` runs the core module's tests and the exe module's tests.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn addTreeSitter(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("javascript_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/javascript/queries/highlights.scm") });
    mod.addAnonymousImport("typescript_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/typescript/queries/highlights.scm") });
    mod.addAnonymousImport("tsx_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/tsx/queries/highlights.scm") });
    mod.addAnonymousImport("css_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/css/queries/highlights.scm") });
    mod.addAnonymousImport("go_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/go/queries/highlights.scm") });
    mod.addAnonymousImport("bash_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/bash/queries/highlights.scm") });
    mod.addAnonymousImport("json_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/json/queries/highlights.scm") });
    mod.addAnonymousImport("yaml_highlights", .{ .root_source_file = b.path("vendors/tree-sitter/yaml/queries/highlights.scm") });
    mod.addIncludePath(b.path("vendors/tree-sitter/runtime/include"));
    mod.addIncludePath(b.path("vendors/tree-sitter/runtime/src"));
    mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/runtime/src/lib.c"), .flags = &.{ "-std=c11", "-fno-sanitize=undefined" } });

    inline for (.{ "javascript", "typescript", "tsx" }) |grammar| {
        mod.addIncludePath(b.path("vendors/tree-sitter/" ++ grammar ++ "/src"));
        mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/" ++ grammar ++ "/src/parser.c"), .flags = &.{"-std=c11"} });
        mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/" ++ grammar ++ "/src/scanner.c"), .flags = &.{"-std=c11"} });
    }
    inline for (.{ "css", "go", "bash", "json", "yaml" }) |grammar| {
        mod.addIncludePath(b.path("vendors/tree-sitter/" ++ grammar ++ "/src"));
        mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/" ++ grammar ++ "/src/parser.c"), .flags = &.{"-std=c11"} });
    }
    inline for (.{ "css", "bash", "yaml" }) |grammar| {
        mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/" ++ grammar ++ "/src/scanner.c"), .flags = &.{"-std=c11"} });
    }
}

/// Compile the vendored SQLite amalgamation into `mod`. Flags harden and trim
/// the build: single-threaded (bbr touches the store only on the main thread,
/// design §10), no double-quoted string literals, no runtime extension loading.
fn addSqlite(b: *std.Build, mod: *std.Build.Module) void {
    const sqlite_flags = [_][]const u8{
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_DQS=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_OMIT_DEPRECATED",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
    };
    mod.addIncludePath(b.path("vendors/sqlite"));
    mod.addCSourceFile(.{ .file = b.path("vendors/sqlite/sqlite3.c"), .flags = &sqlite_flags });
}
