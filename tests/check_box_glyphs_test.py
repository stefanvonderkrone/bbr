"""Regression checks for the terminal border-glyph validator."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/check_box_glyphs.py"
spec = importlib.util.spec_from_file_location("check_box_glyphs", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class BoxGlyphsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src/tui").mkdir(parents=True)
        for path in checker.PAINTERS:
            (self.root / path).write_text("", encoding="utf-8")

    def test_corners_and_junctions_in_each_painter(self):
        for path in checker.PAINTERS:
            for glyph in "┌┐└┘├┤┬┴┼┏┓┗┛┣┫┳┻╋┍┒┡╀╔╗╚╝╠╣╦╩╬╒╖╟╪╭╮╰╯":
                with self.subTest(path=path, glyph=glyph):
                    (self.root / path).write_text(f'const border = "{glyph}";\n', encoding="utf-8")
                    self.assertEqual(len(list(checker.violations(self.root))), 1)
            (self.root / path).write_text("", encoding="utf-8")

    def test_straight_lines_comments_and_test_blocks_are_allowed(self):
        (self.root / checker.PAINTERS[0]).write_text(
            'const lines = "─│━┃═║┄┆╴╵╼╽";\n'
            '// ╔╬\n'
            'test "border fixture" {\n    const border = "╔╬";\n}\n',
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])

    def test_utf8_source_under_ascii_locale(self):
        (self.root / checker.PAINTERS[0]).write_text('const line = "│";\n', encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.root)],
            env={**os.environ, "LC_ALL": "C", "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0"},
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
