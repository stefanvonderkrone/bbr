import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_benchmark_builds", TOOLS / "check_benchmark_builds.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class BenchmarkBuildsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "build.zig"

    def test_direct_benchmark_creation_fails_with_the_fix(self):
        for source in (
            'const bench = b.addExecutable(.{ .name = "bbr-buffer-search-bench", .root_module = bench_mod });',
            'const bench = b\n .addExecutable(\n .{ .name = "new-bench", .root_module = bench_mod });',
            'const bench = b.addExecutable(.{\n .name = "new-bench",\n .root_module = bench_mod,\n });',
            'const bench = builder.addExecutable(.{ .name = "new-bench", .root_module = bench_mod });',
            'const bench = b.addExecutable(options);',
        ):
            with self.subTest(source=source):
                self.source.write_text(source, encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, str(TOOLS / "check_benchmark_builds.py"), str(self.root)],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("build.zig:", result.stderr)
                self.assertIn("Use addBenchmark(b, test_step, name, root_module)", result.stderr)

    def test_helper_app_fixture_comments_and_strings_pass(self):
        self.source.write_text(
            'const exe = b.addExecutable(.{ .name = "bbr", .root_module = exe_mod });\n'
            'const fixture = b.addExecutable(.{ .name = "grammar-cli-integration", .root_module = lifecycle_mod });\n'
            'const bench = addBenchmark(b, test_step, "new-bench", bench_mod);\n'
            '// b.addExecutable(.{});\n'
            'const label = "b.addExecutable(.{})";\n'
            'fn addBenchmark(b: *std.Build, test_step: *std.Build.Step, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {\n'
            '    const exe = b.addExecutable(.{ .name = name, .root_module = root_module });\n'
            '    test_step.dependOn(&exe.step);\n'
            '    return exe;\n'
            '}\n',
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_exemption_ends_at_the_helper_body(self):
        self.source.write_text(
            'fn addBenchmark() void {\n'
            '    if (true) { const exe = b.addExecutable(.{ .name = name }); }\n'
            '    test_step.dependOn(&exe.step);\n'
            '}\n'
            'fn other() void { const exe = b.addExecutable(.{ .name = name }); }\n',
            encoding="utf-8",
        )
        found = list(checker.violations(self.root))
        self.assertEqual(len(found), 1)
        self.assertIn("build.zig:5:", found[0])

    def test_missing_compile_dependency_and_runtime_dependency_fail(self):
        for body in (
            "return exe;",
            "test_step.dependOn(&b.addRunArtifact(exe).step); return exe;",
            "test_step.dependOn(&exe.step); b.addRunArtifact(exe); return exe;",
        ):
            with self.subTest(body=body):
                self.source.write_text(
                    "fn addBenchmark() void {\n"
                    "const exe = b.addExecutable(.{ .name = name, .root_module = root_module });\n"
                    + body + "\n}\n",
                    encoding="utf-8",
                )
                self.assertTrue(any("compilation only" in message for message in checker.violations(self.root)))

    def test_reflowed_declarations_and_helper_pass(self):
        self.source.write_text(
            'const exe: *std.Build.Step.Compile = b.addExecutable(.{\n'
            '    .name = "bbr",\n'
            '    .root_module = exe_mod,\n'
            '    .use_llvm = true,\n'
            '});\n'
            'const fixture = b.addExecutable(.{\n'
            '    .name = "grammar-cli-integration",\n'
            '    .root_module = lifecycle_mod,\n'
            '});\n'
            'fn addBenchmark(\n'
            '    b: *std.Build,\n'
            '    test_step: *std.Build.Step,\n'
            '    name: []const u8,\n'
            '    root_module: *std.Build.Module,\n'
            ') *std.Build.Step.Compile {\n'
            '    const benchmark: *std.Build.Step.Compile = b.addExecutable(.{\n'
            '        .name = name,\n'
            '        .root_module = root_module,\n'
            '        .use_llvm = true,\n'
            '    });\n'
            '    // b.addRunArtifact(benchmark);\n'
            '    const label = "b.addRunArtifact(benchmark)";\n'
            '    test_step\n'
            '        .dependOn(&benchmark.step);\n'
            '    return benchmark;\n'
            '}\n',
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_compile_dependency_elsewhere_does_not_replace_helper_dependency(self):
        self.source.write_text(
            'fn addBenchmark() void {\n'
            '    return exe;\n'
            '}\n'
            'fn other() void { test_step.dependOn(&exe.step); }\n',
            encoding="utf-8",
        )
        self.assertTrue(any("compilation only" in message for message in checker.violations(self.root)))

    def test_nested_module_before_executable_name_passes(self):
        self.source.write_text(
            'const exe = b.addExecutable(.{\n'
            '    .root_module = b.createModule(.{\n'
            '        .imports = &.{.{ .name = "core", .module = core }},\n'
            '        .root_source_file = b.path("braces { } and .name = fake.zig"),\n'
            '    }),\n'
            '    .name = "bbr",\n'
            '});\n'
            'fn addBenchmark() void {\n'
            '    test_step.dependOn(&exe.step);\n'
            '}\n',
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_app_name_does_not_hide_another_call_on_the_same_line(self):
        self.source.write_text(
            'const exe = b.addExecutable(.{ .name = "bbr", .root_module = exe_mod }); b.addExecutable(options);\n',
            encoding="utf-8",
        )
        self.assertEqual(sum("executable bypasses" in message for message in checker.violations(self.root)), 1)


if __name__ == "__main__":
    unittest.main()
