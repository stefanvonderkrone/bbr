"""Regression checks for the stdio writer validator."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_stdio_writers", TOOLS / "check_stdio_writers.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class StdioWritersTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        self.source = self.root / "src/main.zig"
        self.owner = self.root / "src/stdout.zig"

    def test_a_stdout_writer_outside_its_owner_names_the_owner(self):
        for text, line in (
            ("var stdout = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);\n", 1),
            ("const a = 1;\nvar w = std.Io.File.stdout()\n    .writerStreaming(io, &buf);\n", 2),
        ):
            with self.subTest(text=text):
                self.source.write_text(text, encoding="utf-8")
                found = list(checker.violations(self.root))
                self.assertEqual(len(found), 1)
                self.assertIn(f"src/main.zig:{line}:", found[0])
                self.assertIn("bbr.stdout.write", found[0])
                self.assertIn("src/stdout.zig", found[0])

    def test_only_the_owner_makes_the_stdout_writer(self):
        self.owner.write_text("var w = std.Io.File.stdout().writerStreaming(io, &buffer);\n", encoding="utf-8")
        self.assertEqual(list(checker.violations(self.root)), [])
        self.owner.write_text("var w = std.Io.File.stdout().writer(io, &buffer);\n", encoding="utf-8")
        found = list(checker.violations(self.root))
        self.assertEqual(len(found), 1)
        self.assertIn("src/stdout.zig:1: use stdout() only as stdout().writerStreaming(", found[0])

    def test_positional_stdout_and_stderr_writers(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                self.source.write_text(f"var w = std.Io.File.{stream}().writer(io, &buf);\n", encoding="utf-8")
                self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_an_alias_of_stdout_or_stderr_is_rejected(self):
        for line in (
            "const out = std.Io.File.stdout();",
            "var w = std.Io.File.stderr().writer(io, &buf);",
            "const f: std.Io.File = std.Io.File.stdout(); var w = f.writer(io, &buf);",
        ):
            with self.subTest(line=line):
                self.source.write_text(line + "\n", encoding="utf-8")
                self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_a_handle_comparison_is_allowed(self):
        self.source.write_text(
            "const same = file.handle == std.Io.File.stdout().handle;\n"
            "const other = std.Io.File.stderr().handle != file.handle;\n",
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_zig_fmt_line_breaks_keep_a_valid_use_valid(self):
        self.owner.write_text(
            "const same = file.handle ==\n"
            "    std.Io.File.stdout().handle;\n"
            "var w = std.Io.File.stdout()\n"
            "    .writerStreaming(io, &buf);\n"
            "const other = std.Io.File.stderr().handle\n"
            "    != file.handle;\n",
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_zig_fmt_line_breaks_do_not_hide_a_bad_use(self):
        for text, line in (
            ("var w = std.Io.File.stdout()\n    .writer(io, &buf);\n", 1),
            ("const same = file.handle ==\n    std.Io.File.stderr().writer(io, &buf);\n", 2),
            ("const a = 1;\nconst out = std.Io.File.stdout();\n", 2),
        ):
            with self.subTest(text=text):
                self.source.write_text(text, encoding="utf-8")
                found = list(checker.violations(self.root))
                self.assertEqual(len(found), 1)
                self.assertIn(f"src/main.zig:{line}:", found[0])

    def test_a_file_built_from_the_handle_is_rejected(self):
        for line in (
            "const f: std.Io.File = .{ .handle = std.Io.File.stdout().handle, .flags = .{ .nonblocking = false } };",
            "const h = std.Io.File.stderr().handle;",
        ):
            with self.subTest(line=line):
                self.source.write_text(line + "\n", encoding="utf-8")
                self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_streaming_writers_and_comments_are_allowed(self):
        self.owner.write_text(
            "var w = std.Io.File.stdout().writerStreaming(io, &buf);\n"
            "// stdout().writer( writes at offset 0.\n"
            "    /// stderr().writer( is positional.\n"
            "//! stdout().writer( overwrites a redirected file.\n"
            "var e = std.Io.File.stderr().writerStreaming(io, &buf); // not stderr().writer(\n",
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_a_comment_marker_inside_a_literal_hides_no_code(self):
        for line in (
            'const url = "https://example.test"; var w = std.Io.File.stdout().writer(io, &buf);',
            "const quote = '\"'; const url = \"https://example.test\"; var w = std.Io.File.stderr().writer(io, &buf);",
            "var w = std.Io.File.stdout().writer(io, \\\\ // a multiline string, not a comment",
            'const s = "\\"//"; var w = std.Io.File.stdout().writer(io, &buf);',
        ):
            with self.subTest(line=line):
                self.source.write_text(line + "\n", encoding="utf-8")
                self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_a_literal_that_quotes_a_positional_writer_is_text(self):
        for line in (
            'const help = "avoid stdout().writer(";',
            "const help = 's'; const tip = \"stderr().writer( is positional\";",
            "    \\\\ avoid stdout().writer(",
            "const help = \\\\ avoid stderr().writer(",
        ):
            with self.subTest(line=line):
                self.source.write_text(line + "\n", encoding="utf-8")
                self.assertEqual(list(checker.violations(self.root)), [])


if __name__ == "__main__":
    unittest.main()
