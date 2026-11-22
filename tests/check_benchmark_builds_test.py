"""Check that a benchmark cannot skip compilation in the test step."""

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
            'const bench = builder.addExecutable(.{ .name = "new-bench", .root_module = bench_mod });',
            'const bench = b.addExecutable(options);',
        ):
            with self.subTest(source=source):
                self.source.write_text(source, encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, str(TOOLS / "check_benchmark_builds.py"), str(self.root)],
                    capture_output=True, text=True,
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
            'fn addBenchmark() void { if (true) { const exe = b.addExecutable(options); } }\n'
            'fn other() void { const exe = b.addExecutable(options); }\n',
            encoding="utf-8",
        )
        found = list(checker.violations(self.root))
        self.assertTrue(any("build.zig:2:" in message for message in found))

    def test_missing_compile_dependency_and_runtime_dependency_fail(self):
        for body in (
            "return exe;",
            "test_step.dependOn(&b.addRunArtifact(exe).step); return exe;",
        ):
            with self.subTest(body=body):
                self.source.write_text(
                    "fn addBenchmark() void {\n"
                    "const exe = b.addExecutable(.{ .name = name, .root_module = root_module });\n"
                    + body + "\n}\n",
                    encoding="utf-8",
                )
                self.assertTrue(any("compilation only" in message for message in checker.violations(self.root)))

    def test_another_step_cannot_replace_the_test_step(self):
        self.source.write_text(
            'const bench = addBenchmark(b, bench_step, "new-bench", bench_mod);\n',
            encoding="utf-8",
        )
        self.assertTrue(any("so test compiles" in message for message in checker.violations(self.root)))

    def test_app_name_does_not_hide_another_call_on_the_same_line(self):
        self.source.write_text(
            'const exe = b.addExecutable(.{ .name = "bbr", .root_module = exe_mod }); b.addExecutable(options);\n',
            encoding="utf-8",
        )
        self.assertEqual(sum("executable bypasses" in message for message in checker.violations(self.root)), 2)


if __name__ == "__main__":
    unittest.main()
