const std = @import("std");
const version_identity = @import("build/version.zig");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    if (target.query.os_tag == null and
        target.query.os_version_min == null and
        target.result.os.tag == .macos and
        target.result.os.version_range.semver.min.major >= 26)
    {
        // Zig 0.16 cannot build its bundled libc++ for a macOS 26 minimum.
        target.query.os_tag = .macos;
        target.query.os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(target.query);
    }
    const macos_sdk = if (target.query.os_tag == .macos and b.graph.host.result.os.tag == .macos)
        std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), "\r\n")
    else
        null;
    const optimize = b.standardOptimizeOption(.{});
    const version = resolveVersion(b);

    // The network-free core, exposed as the `bbr` module (no TUI deps → testable).
    const mod = b.addModule("bbr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe_mod.addOptions("build_options", build_options);
    exe_mod.addAnonymousImport("bbr_verbs_md", .{ .root_source_file = b.path("skills/bbr/VERBS.md") });
    addSqlite(b, exe_mod);
    addTreeSitter(b, exe_mod);
    addRe2(b, exe_mod, target, macos_sdk);

    const exe = b.addExecutable(.{ .name = "bbr", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run bbr");
    run_step.dependOn(&run_cmd.step);

    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const bench_core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/benchmark.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{ .name = "bbr", .module = bench_core_mod }},
    });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark/main.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "bbr", .module = bench_core_mod },
            .{ .name = "benchmark_tui", .module = bench_tui_mod },
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });
    const bench_highlight_mod = b.createModule(.{
        .root_source_file = b.path("src/highlight/tree_sitter_highlighter.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "bbr", .module = bench_core_mod }},
    });
    addTreeSitter(b, bench_highlight_mod);
    addRe2(b, bench_highlight_mod, target, macos_sdk);
    bench_mod.addImport("benchmark_highlight", bench_highlight_mod);
    const bench_exe = b.addExecutable(.{ .name = "bbr-bench", .root_module = bench_mod });
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    b.getInstallStep().dependOn(&install_bench.step);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run deterministic ReleaseFast benchmarks");
    bench_step.dependOn(&install_bench.step);
    bench_step.dependOn(&run_bench.step);

    const file_enrichment_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/file_enrichment.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{ .name = "bbr", .module = bench_core_mod }},
    });
    const file_acquisition_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark/file_acquisition.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "bbr", .module = bench_core_mod },
            .{ .name = "file_enrichment", .module = file_enrichment_bench_mod },
        },
    });
    const file_acquisition_bench = b.addExecutable(.{ .name = "bbr-file-acquisition-bench", .root_module = file_acquisition_bench_mod });
    const run_file_acquisition_bench = b.addRunArtifact(file_acquisition_bench);
    if (b.args) |args| run_file_acquisition_bench.addArgs(args);
    const file_acquisition_bench_step = b.step("bench-file-acquisition", "Run the opt-in File Enrichment concurrency benchmark");
    file_acquisition_bench_step.dependOn(&run_file_acquisition_bench.step);

    const buffer_search_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark_buffer_search.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "bbr", .module = bench_core_mod },
            .{ .name = "zf", .module = zf.module("zf") },
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });
    const buffer_search_bench = b.addExecutable(.{ .name = "bbr-buffer-search-bench", .root_module = buffer_search_bench_mod });
    const buffer_search_bench_step = b.step("bench-buffer-search", "Run the deterministic large Buffer Search benchmark");
    const run_buffer_search_bench = b.addRunArtifact(buffer_search_bench);
    if (b.args) |args| run_buffer_search_bench.addArgs(args);
    buffer_search_bench_step.dependOn(&run_buffer_search_bench.step);

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

    const acquisition_check_cmd = b.addRunArtifact(exe);
    acquisition_check_cmd.step.dependOn(b.getInstallStep());
    acquisition_check_cmd.addArg("check-acquisition");
    const acquisition_check_step = b.step("check-acquisition", "Opt-in Candidate Session acquisition gate");
    acquisition_check_step.dependOn(&acquisition_check_cmd.step);

    // Destructive and PTY checks remain explicit opt-in tiers outside tests.
    const mutation_cmd = b.addRunArtifact(exe);
    mutation_cmd.step.dependOn(b.getInstallStep());
    mutation_cmd.addArg("check-mutation");
    if (b.args) |args| mutation_cmd.addArgs(args);
    const mutation_step = b.step("check-mutation", "Destructive Bitbucket Comment lifecycle check (requires opt-in)");
    mutation_step.dependOn(&mutation_cmd.step);

    const verdict_cmd = b.addRunArtifact(exe);
    verdict_cmd.step.dependOn(b.getInstallStep());
    verdict_cmd.addArg("check-verdict");
    if (b.args) |args| verdict_cmd.addArgs(args);
    const verdict_step = b.step("check-verdict", "Destructive Bitbucket Reviewer Verdict check (requires opt-in)");
    verdict_step.dependOn(&verdict_cmd.step);

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
    const review_recovery_tests = b.addTest(.{
        .name = "review-recovery-tests",
        .root_module = exe.root_module,
        .filters = &.{"Review recovery"},
    });
    const run_review_recovery_tests = b.addRunArtifact(review_recovery_tests);
    const review_recovery_step = b.step("test-review-recovery", "Run Review recovery regression tests");
    review_recovery_step.dependOn(&run_review_recovery_tests.step);
    const version_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/version.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_version_tests = b.addRunArtifact(version_tests);
    const version_command = b.addRunArtifact(exe);
    version_command.addArg("--version");
    inline for (.{ "BITBUCKET_USERNAME", "BITBUCKET_TOKEN", "BITBUCKET_WORKSPACE", "HOME", "XDG_CONFIG_HOME" }) |name| {
        version_command.removeEnvironmentVariable(name);
    }
    version_command.expectStdOutEqual(b.fmt("bbr {s}\n", .{version}));
    const xdg_reads = b.addSystemCommand(&.{"python3"});
    xdg_reads.addFileArg(b.path("tools/check_xdg_reads.py"));
    xdg_reads.addDirectoryArg(b.path("."));
    const box_glyphs = b.addSystemCommand(&.{"python3"});
    box_glyphs.addFileArg(b.path("tools/check_box_glyphs.py"));
    box_glyphs.addDirectoryArg(b.path("."));
    const stdio_writers = b.addSystemCommand(&.{"python3"});
    stdio_writers.addFileArg(b.path("tools/check_stdio_writers.py"));
    stdio_writers.addDirectoryArg(b.path("."));
    const test_step = b.step("test", "Run tests");
    // The core module is C-free. A macOS build links libc implicitly, so a libc call in
    // core compiles there and fails only in the Linux CI jobs. Every host also compiles
    // the core tests for Linux, so that mistake fails in a local `zig build test`.
    const core_linux_tests = b.addTest(.{ .name = "core-linux-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
        .optimize = optimize,
    }) });
    test_step.dependOn(&core_linux_tests.step);
    const diagnostic_check = b.addSystemCommand(&.{"python3"});
    diagnostic_check.addFileArg(b.path("tools/check_diagnostics.py"));
    diagnostic_check.addDirectoryArg(b.path("."));
    test_step.dependOn(&diagnostic_check.step);
    const error_comparisons = b.addSystemCommand(&.{"python3"});
    error_comparisons.addFileArg(b.path("tools/check_error_comparisons.py"));
    error_comparisons.addDirectoryArg(b.path("."));
    test_step.dependOn(&error_comparisons.step);
    const task_spawns = b.addSystemCommand(&.{"python3"});
    task_spawns.addFileArg(b.path("tools/check_task_spawns.py"));
    task_spawns.addDirectoryArg(b.path("."));
    test_step.dependOn(&task_spawns.step);
    const diagnostic_tests = b.addTest(.{ .root_module = exe.root_module, .filters = &.{"diagnostics"} });
    const diagnostic_core_tests = b.addTest(.{ .root_module = mod, .filters = &.{"diagnostics"} });
    const diagnostic_step = b.step("test-diagnostics", "Run diagnostic logging checks");
    diagnostic_step.dependOn(&diagnostic_check.step);
    diagnostic_step.dependOn(&b.addRunArtifact(diagnostic_tests).step);
    diagnostic_step.dependOn(&b.addRunArtifact(diagnostic_core_tests).step);
    for ([_][]const u8{ "tests/check_diagnostics_test.py", "tests/diagnostic_types_test.py" }) |path| {
        const run = b.addSystemCommand(&.{"python3"});
        run.addFileArg(b.path(path));
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
        diagnostic_step.dependOn(&run.step);
    }
    const cli_test_step = b.step("test-cli", "Run hermetic Python CLI checks (requires python3)");
    addTestScripts(b, exe, test_step, cli_test_step);

    const re2_tests = b.addTest(.{
        .name = "re2-wrapper-tests",
        .root_module = exe.root_module,
        .filters = &.{"RE2 wrapper"},
    });
    const run_re2_tests = b.addRunArtifact(re2_tests);
    const re2_test_step = b.step("test-re2", "Run the native RE2 wrapper smoke tests");
    re2_test_step.dependOn(&run_re2_tests.step);

    const selected_version_hardening_tests = b.addTest(.{
        .name = "selected-version-hardening-tests",
        .root_module = exe.root_module,
        .filters = &.{"M20 hardening"},
    });
    const run_selected_version_hardening_tests = b.addRunArtifact(selected_version_hardening_tests);
    const selected_version_hardening_test_step = b.step("test-selected-version-hardening", "Run Selected Version hardening tests");
    selected_version_hardening_test_step.dependOn(&run_selected_version_hardening_tests.step);

    const search_kernel_tests = b.addTest(.{
        .name = "search-kernel-tests",
        .root_module = exe.root_module,
        .filters = &.{"M21 kernel"},
    });
    const run_search_kernel_tests = b.addRunArtifact(search_kernel_tests);
    const search_kernel_test_step = b.step("test-search-kernel", "Run M21 search kernel and reachable-source tests");
    search_kernel_test_step.dependOn(&run_search_kernel_tests.step);

    // The fingerprint and the fake live in the `bbr` module, Presentation and SQLite in the executable.
    const file_read_step = b.step("test-file-read", "Run M22 File read state tests");
    for ([_]*std.Build.Module{ mod, exe.root_module }) |root_module| {
        const file_read_tests = b.addTest(.{ .name = "file-read-tests", .root_module = root_module, .filters = &.{"M22 read"} });
        file_read_step.dependOn(&b.addRunArtifact(file_read_tests).step);
    }

    const authored_search_tests = b.addTest(.{
        .name = "authored-search-tests",
        .root_module = exe.root_module,
        .filters = &.{"M21 authored"},
    });
    const authored_search_step = b.step("test-authored-search", "Run authored Review Search tests");
    authored_search_step.dependOn(&b.addRunArtifact(authored_search_tests).step);

    const reply_ancestry_tests = b.addTest(.{
        .name = "reply-ancestry-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 ancestry"},
    });
    const reply_ancestry_step = b.step("test-reply-ancestry", "Run Reply ancestry presentation tests");
    reply_ancestry_step.dependOn(&b.addRunArtifact(reply_ancestry_tests).step);

    const yank_tests = b.addTest(.{
        .name = "yank-tests",
        .root_module = exe.root_module,
        .filters = &.{"yank"},
    });
    const yank_step = b.step("test-yank", "Run Presentation yank tests");
    yank_step.dependOn(&b.addRunArtifact(yank_tests).step);

    const external_edit_tests = b.addTest(.{
        .name = "external-edit-tests",
        .root_module = exe.root_module,
        .filters = &.{"External Edit"},
    });
    const external_edit_test_step = b.step("test-external-edit", "Run External Edit lifecycle tests");
    external_edit_test_step.dependOn(&b.addRunArtifact(external_edit_tests).step);

    const inline_tests = b.addTest(.{
        .name = "inline-markdown-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 inline"},
    });
    const inline_step = b.step("test-inline-markdown", "Run inline Markdown presentation tests");
    inline_step.dependOn(&b.addRunArtifact(inline_tests).step);

    const literal_tests = b.addTest(.{
        .name = "literal-code-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 literal"},
    });
    const literal_step = b.step("test-literal-code", "Run literal code presentation tests");
    literal_step.dependOn(&b.addRunArtifact(literal_tests).step);

    const code_tests = b.addTest(.{ .name = "code-highlighting-tests", .root_module = exe.root_module, .filters = &.{"M23 highlighting"} });
    const code_step = b.step("test-code-highlighting", "Run fenced-code Highlighting tests");
    code_step.dependOn(&b.addRunArtifact(code_tests).step);

    const container_tests = b.addTest(.{
        .name = "container-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 containers"},
    });
    const container_step = b.step("test-containers", "Run list and quote presentation tests");
    container_step.dependOn(&b.addRunArtifact(container_tests).step);

    const link_tests = b.addTest(.{
        .name = "link-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 links"},
    });
    const link_step = b.step("test-links", "Run link and reference presentation tests");
    link_step.dependOn(&b.addRunArtifact(link_tests).step);

    const table_tests = b.addTest(.{
        .name = "table-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 tables"},
    });
    const table_step = b.step("test-tables", "Run table presentation tests");
    table_step.dependOn(&b.addRunArtifact(table_tests).step);

    const emoji_tests = b.addTest(.{
        .name = "emoji-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 emoji"},
    });
    const emoji_step = b.step("test-emoji", "Run emoji conversion and search tests");
    emoji_step.dependOn(&b.addRunArtifact(emoji_tests).step);

    const acceptance_tests = b.addTest(.{
        .name = "m23-acceptance-tests",
        .root_module = exe.root_module,
        .filters = &.{"M23 acceptance"},
    });
    const acceptance_step = b.step("test-m23-acceptance", "Run combined M23 acceptance tests");
    acceptance_step.dependOn(&b.addRunArtifact(acceptance_tests).step);

    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("tests/user_grammar_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fixture_mod.addIncludePath(b.path("vendors/tree-sitter/runtime/include"));
    fixture_mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/javascript/src/parser.c"), .flags = &.{"-std=c11"} });
    fixture_mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/javascript/src/scanner.c"), .flags = &.{"-std=c11"} });
    const grammar_fixture = b.addLibrary(.{ .name = "bbr-user-grammar-fixture", .linkage = .dynamic, .root_module = fixture_mod });

    const lifecycle_mod = b.createModule(.{
        .root_source_file = b.path("tests/grammar_cli_integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const highlight_runtime = b.createModule(.{
        .root_source_file = b.path("src/highlight/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "bbr", .module = mod }},
    });
    addTreeSitter(b, highlight_runtime);
    addRe2(b, highlight_runtime, target, macos_sdk);
    lifecycle_mod.addImport("highlight_runtime", highlight_runtime);
    const lifecycle_test = b.addExecutable(.{ .name = "grammar-cli-integration", .root_module = lifecycle_mod });
    const run_user_grammar_load_test = b.addRunArtifact(lifecycle_test);
    run_user_grammar_load_test.addArtifactArg(exe);
    run_user_grammar_load_test.addArtifactArg(grammar_fixture);
    run_user_grammar_load_test.addArtifactArg(lifecycle_test);
    run_user_grammar_load_test.addArg("load-smoke");
    const user_grammar_load_test_step = b.step("test-user-grammar-load", "Run the native UserGrammar fixture load smoke test");
    user_grammar_load_test_step.dependOn(&run_user_grammar_load_test.step);
    const run_lifecycle_test = b.addRunArtifact(lifecycle_test);
    run_lifecycle_test.addArtifactArg(exe);
    run_lifecycle_test.addArtifactArg(grammar_fixture);
    run_lifecycle_test.addArtifactArg(lifecycle_test);
    const user_grammar_test_step = b.step("test-user-grammar", "Run the native UserGrammar load and CLI lifecycle fixture");
    user_grammar_test_step.dependOn(&run_lifecycle_test.step);

    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_version_tests.step);
    test_step.dependOn(&version_command.step);
    test_step.dependOn(&xdg_reads.step);
    test_step.dependOn(&box_glyphs.step);
    test_step.dependOn(&stdio_writers.step);
    test_step.dependOn(&b.addFmt(.{ .paths = &.{ "build.zig", "src", "tests" }, .check = true }).step);
    test_step.dependOn(&run_lifecycle_test.step);
    test_step.dependOn(cli_test_step);
}

const TestScript = enum { python, shell, cli, ci };

/// The first suffix that ends a tests/ file name decides where the file runs.
const test_script_suffixes = [_]struct { []const u8, TestScript }{
    .{ "_cli_test.py", .cli },
    .{ "_ci_test.py", .ci },
    .{ "_test.py", .python },
    .{ "_test.sh", .shell },
};

/// Files in tests/ that tests use and that run in no step of their own.
const test_support_files = [_][]const u8{
    "cli_env.py",
    "validate_release.sh",
    "grammar_cli_integration.zig",
    "user_grammar_fixture.zig",
};

/// Runs each tests/ script by the suffix of its name, so a new test needs no registration.
/// The `test` step fails on a file that fits no suffix and is not a support file.
fn addTestScripts(b: *std.Build, exe: *std.Build.Step.Compile, test_step: *std.Build.Step, cli_test_step: *std.Build.Step) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "tests", .{ .iterate = true }) catch |err|
        std.process.fatal("cannot open tests/: {s}", .{@errorName(err)});
    defer dir.close(io);
    var entries = dir.iterate();
    files: while (entries.next(io) catch |err| std.process.fatal("cannot list tests/: {s}", .{@errorName(err)})) |entry| {
        if (entry.kind != .file or entry.name[0] == '.') continue;
        for (test_support_files) |name| {
            if (std.mem.eql(u8, entry.name, name)) continue :files;
        }
        const path = b.fmt("tests/{s}", .{entry.name});
        const script = for (test_script_suffixes) |suffix| {
            if (std.mem.endsWith(u8, entry.name, suffix[0])) break suffix[1];
        } else {
            test_step.dependOn(&b.addFail(b.fmt(
                "{s} runs in no step. Name a test *_test.py or *_test.sh for `zig build test`, *_cli_test.py for `zig build test-cli`, or *_ci_test.py for CI, or add a support file to test_support_files in build.zig.",
                .{path},
            )).step);
            continue;
        };
        const run = switch (script) {
            .ci => continue,
            .python, .cli => b.addSystemCommand(&.{"python3"}),
            .shell => b.addSystemCommand(&.{"sh"}),
        };
        run.addFileArg(b.path(path));
        run.setCwd(b.path("."));
        if (script != .cli) {
            // A test that compiles Zig uses the compiler of this build, also when PATH has none.
            run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
            test_step.dependOn(&run.step);
            continue;
        }
        run.addArtifactArg(exe);
        // A developer's saved Profile or Credential variables would let a check pass only on that machine.
        run.clearEnvironment();
        if (b.graph.environ_map.get("PATH")) |env_path| run.setEnvironmentVariable("PATH", env_path);
        run.setEnvironmentVariable("BBR_TEST_CLI", "1");
        cli_test_step.dependOn(&run.step);
    }
}

fn resolveVersion(b: *std.Build) []const u8 {
    const environment = &b.graph.environ_map;
    const explicit: version_identity.Explicit = .{
        .epoch = environment.get("SOURCE_DATE_EPOCH"),
        .commit = environment.get("BBR_VERSION_COMMIT"),
        .sequence = environment.get("BBR_VERSION_SEQUENCE"),
        .dirty = environment.get("BBR_VERSION_DIRTY"),
    };
    const git: version_identity.Git = if (explicit.active()) .{} else .{
        .epoch = runGit(b, &.{ "log", "-1", "--format=%ct", "HEAD" }),
        .commit = runGit(b, &.{ "rev-parse", "HEAD" }),
        .tags = runGit(b, &.{ "for-each-ref", "--points-at=HEAD", "--format=%(refname:short)%09%(objecttype)", "refs/tags" }),
        .status = runGit(b, &.{
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignored=no",
            "--",
            "build.zig",
            "build.zig.zon",
            "build",
            "src",
            "tests",
            "vendors",
            ".github/workflows",
        }),
    };
    return version_identity.resolve(b.allocator, explicit, git) catch |err| switch (err) {
        error.IncompleteExplicitMetadata => std.process.fatal(
            "explicit version metadata requires SOURCE_DATE_EPOCH, BBR_VERSION_COMMIT, BBR_VERSION_SEQUENCE, and BBR_VERSION_DIRTY together",
            .{},
        ),
        error.MissingGitMetadata => std.process.fatal(
            "Git metadata is unavailable; set SOURCE_DATE_EPOCH, BBR_VERSION_COMMIT, BBR_VERSION_SEQUENCE, and BBR_VERSION_DIRTY together",
            .{},
        ),
        else => std.process.fatal("cannot determine bbr version: {s}", .{@errorName(err)}),
    };
}

fn runGit(b: *std.Build, arguments: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "git", "-C", b.build_root.path orelse "." }) catch @panic("OOM");
    argv.appendSlice(b.allocator, arguments) catch @panic("OOM");
    var exit_code: u8 = 0;
    return b.runAllowFail(argv.items, &exit_code, .ignore) catch null;
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
    mod.addAnonymousImport("javascript_locals", .{ .root_source_file = b.path("vendors/tree-sitter/javascript/queries/locals.scm") });
    mod.addAnonymousImport("typescript_locals", .{ .root_source_file = b.path("vendors/tree-sitter/typescript/queries/locals.scm") });
    mod.addIncludePath(b.path("vendors/tree-sitter/runtime/include"));
    mod.addIncludePath(b.path("vendors/tree-sitter/runtime/src"));
    mod.addCSourceFile(.{ .file = b.path("vendors/tree-sitter/runtime/src/lib.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-fno-sanitize=undefined" } });

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

fn addRe2(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, macos_sdk: ?[]const u8) void {
    const cpp_flags: []const []const u8 = if (macos_sdk != null)
        &.{ "-std=c++17", "-fno-sanitize=undefined", "-Wno-elaborated-enum-base" }
    else
        &.{ "-std=c++17", "-fno-sanitize=undefined" };
    const sources = [_][]const u8{
        "bbr_re2.cc",
        "re2/bitmap256.cc",
        "re2/bitstate.cc",
        "re2/compile.cc",
        "re2/dfa.cc",
        "re2/filtered_re2.cc",
        "re2/mimics_pcre.cc",
        "re2/nfa.cc",
        "re2/onepass.cc",
        "re2/parse.cc",
        "re2/perl_groups.cc",
        "re2/prefilter.cc",
        "re2/prefilter_tree.cc",
        "re2/prog.cc",
        "re2/re2.cc",
        "re2/regexp.cc",
        "re2/set.cc",
        "re2/simplify.cc",
        "re2/tostring.cc",
        "re2/unicode_casefold.cc",
        "re2/unicode_groups.cc",
        "util/rune.cc",
        "util/strutil.cc",
    };
    mod.addIncludePath(b.path("vendors/re2"));
    mod.addIncludePath(b.path("vendors/abseil"));
    mod.addCSourceFiles(.{
        .root = b.path("vendors/re2"),
        .files = &sources,
        .flags = cpp_flags,
        .language = .cpp,
    });
    const abseil_sources = [_][]const u8{
        "absl/base/internal/cycleclock.cc",
        "absl/base/internal/low_level_alloc.cc",
        "absl/base/internal/raw_logging.cc",
        "absl/base/internal/spinlock.cc",
        "absl/base/internal/spinlock_wait.cc",
        "absl/base/internal/strerror.cc",
        "absl/base/internal/sysinfo.cc",
        "absl/base/internal/thread_identity.cc",
        "absl/base/internal/throw_delegate.cc",
        "absl/base/internal/unscaledcycleclock.cc",
        "absl/base/log_severity.cc",
        "absl/container/internal/raw_hash_set.cc",
        "absl/container/internal/hashtablez_sampler.cc",
        "absl/container/internal/hashtablez_sampler_force_weak_definition.cc",
        "absl/debugging/internal/demangle.cc",
        "absl/debugging/internal/demangle_rust.cc",
        "absl/debugging/internal/decode_rust_punycode.cc",
        "absl/debugging/internal/elf_mem_image.cc",
        "absl/debugging/internal/utf8_for_code_point.cc",
        "absl/debugging/internal/address_is_readable.cc",
        "absl/debugging/internal/examine_stack.cc",
        "absl/debugging/internal/vdso_support.cc",
        "absl/debugging/stacktrace.cc",
        "absl/debugging/symbolize.cc",
        "absl/debugging/leak_check.cc",
        "absl/hash/internal/city.cc",
        "absl/hash/internal/hash.cc",
        "absl/hash/internal/low_level_hash.cc",
        "absl/log/globals.cc",
        "absl/log/log_sink.cc",
        "absl/log/internal/check_op.cc",
        "absl/log/internal/globals.cc",
        "absl/log/internal/log_format.cc",
        "absl/log/internal/log_message.cc",
        "absl/log/internal/log_sink_set.cc",
        "absl/log/internal/nullguard.cc",
        "absl/log/internal/proto.cc",
        "absl/log/internal/structured_proto.cc",
        "absl/numeric/int128.cc",
        "absl/strings/ascii.cc",
        "absl/strings/charconv.cc",
        "absl/strings/match.cc",
        "absl/strings/numbers.cc",
        "absl/strings/str_cat.cc",
        "absl/strings/internal/charconv_bigint.cc",
        "absl/strings/internal/charconv_parse.cc",
        "absl/strings/internal/memutil.cc",
        "absl/strings/internal/utf8.cc",
        "absl/strings/internal/str_format/arg.cc",
        "absl/strings/internal/str_format/bind.cc",
        "absl/strings/internal/str_format/extension.cc",
        "absl/strings/internal/str_format/float_conversion.cc",
        "absl/strings/internal/str_format/output.cc",
        "absl/strings/internal/str_format/parser.cc",
        "absl/synchronization/internal/create_thread_identity.cc",
        "absl/synchronization/internal/futex_waiter.cc",
        "absl/synchronization/internal/graphcycles.cc",
        "absl/synchronization/internal/kernel_timeout.cc",
        "absl/synchronization/internal/per_thread_sem.cc",
        "absl/synchronization/internal/pthread_waiter.cc",
        "absl/synchronization/internal/waiter_base.cc",
        "absl/synchronization/mutex.cc",
        "absl/time/clock.cc",
        "absl/time/duration.cc",
        "absl/time/time.cc",
        "absl/time/internal/cctz/src/civil_time_detail.cc",
        "absl/time/internal/cctz/src/time_zone_fixed.cc",
        "absl/time/internal/cctz/src/time_zone_format.cc",
        "absl/time/internal/cctz/src/time_zone_if.cc",
        "absl/time/internal/cctz/src/time_zone_impl.cc",
        "absl/time/internal/cctz/src/time_zone_info.cc",
        "absl/time/internal/cctz/src/time_zone_libc.cc",
        "absl/time/internal/cctz/src/time_zone_lookup.cc",
        "absl/time/internal/cctz/src/time_zone_posix.cc",
        "absl/time/internal/cctz/src/zone_info_source.cc",
    };
    mod.addCSourceFiles(.{
        .root = b.path("vendors/abseil"),
        .files = &abseil_sources,
        .flags = cpp_flags,
        .language = .cpp,
    });
    mod.link_libcpp = true;
    if (target.result.os.tag == .macos) {
        if (macos_sdk) |sdk| {
            mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
        mod.linkFramework("CoreFoundation", .{});
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
