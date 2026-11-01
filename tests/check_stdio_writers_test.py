"""Regression checks for the stdio writer validator."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/check_stdio_writers.py"
spec = importlib.util.spec_from_file_location("check_stdio_writers", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class StdioWritersTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        self.source = self.root / "src/main.zig"

    def test_positional_stdout_and_stderr_writers(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                self.source.write_text(f"var w = std.Io.File.{stream}().writer(io, &buf);\n", encoding="utf-8")
                self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_streaming_writers_and_comments_are_allowed(self):
        self.source.write_text(
            "var w = std.Io.File.stdout().writerStreaming(io, &buf);\n"
            "// stdout().writer( writes at offset 0.\n"
            "    /// stderr().writer( is positional.\n"
            "//! stdout().writer( overwrites a redirected file.\n",
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])


if __name__ == "__main__":
    unittest.main()
