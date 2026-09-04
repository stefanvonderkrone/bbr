const std = @import("std");
const version_identity = @import("build/version.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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
    addSqlite(b, exe_mod);
    addTreeSitter(b, exe_mod);
    addRe2(b, exe_mod, target);

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
    const bench_buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/buffer.zig"),
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
            .{ .name = "benchmark_buffer", .module = bench_buffer_mod },
        },
    });
    const bench_exe = b.addExecutable(.{ .name = "bbr-bench", .root_module = bench_mod });
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    b.getInstallStep().dependOn(&install_bench.step);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run deterministic ReleaseFast benchmarks");
    bench_step.dependOn(&install_bench.step);
    bench_step.dependOn(&run_bench.step);

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
    const version_integration = b.addSystemCommand(&.{ "sh", "tests/version_identity_test.sh" });
    version_integration.setCwd(b.path("."));
    const release_validation = b.addSystemCommand(&.{ "sh", "tests/release_validation_test.sh" });
    release_validation.setCwd(b.path("."));

    const re2_tests = b.addTest(.{
        .name = "re2-wrapper-tests",
        .root_module = exe.root_module,
        .filters = &.{"RE2 wrapper"},
    });
    const run_re2_tests = b.addRunArtifact(re2_tests);
    const re2_test_step = b.step("test-re2", "Run the native RE2 wrapper smoke tests");
    re2_test_step.dependOn(&run_re2_tests.step);

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
    addRe2(b, highlight_runtime, target);
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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_version_tests.step);
    test_step.dependOn(&version_command.step);
    test_step.dependOn(&version_integration.step);
    test_step.dependOn(&release_validation.step);
    test_step.dependOn(&run_lifecycle_test.step);
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

fn addRe2(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
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
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
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
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
        .language = .cpp,
    });
    mod.link_libcpp = true;
    if (target.result.os.tag == .macos) mod.linkFramework("CoreFoundation", .{});
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
