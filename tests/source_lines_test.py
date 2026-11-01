"""Regression checks for the comment-free source lines that every line checker reads."""

from pathlib import Path
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from source_lines import yaml_code, zig_code, zig_code_without_literals  # noqa: E402


class ZigCodeTest(unittest.TestCase):
    def test_comments_end_the_code(self):
        for line, code in (
            ("// note", ""),
            ("    /// doc", ""),
            ("//! module doc", ""),
            ("const a = 1; // note", "const a = 1;"),
            ("const a = 1;//note", "const a = 1;"),
        ):
            with self.subTest(line=line):
                self.assertEqual(zig_code(line), [code])

    def test_literals_keep_their_comment_markers(self):
        for line in (
            'const url = "https://example.test";',
            'const quote = "\\"//";',
            'const slash = "\\\\"; const url = "a//b";',
            "const quote = '\"'; const url = \"https://example.test\";",
            "const quote = '\\''; const url = \"https://example.test\";",
            "    \\\\ // a multiline string line",
            "const text = \\\\ // a multiline string line",
        ):
            with self.subTest(line=line):
                self.assertEqual(zig_code(line), [line])

    def test_a_comment_after_a_literal(self):
        self.assertEqual(zig_code('const url = "https://example.test"; // the base'), ['const url = "https://example.test";'])

    def test_each_line_stands_alone(self):
        self.assertEqual(zig_code('const open = "a;\n// note\nconst b = 2;'), ['const open = "a;', "", "const b = 2;"])


class ZigCodeWithoutLiteralsTest(unittest.TestCase):
    def test_literals_are_emptied_and_code_stays(self):
        for line, code in (
            ('const help = "stdout().writer(";', 'const help = "";'),
            ("const q = '\\''; f(); // note", "const q = ''; f();"),
            ('const s = "\\"//"; g();', 'const s = ""; g();'),
            ("    \\\\ stdout().writer(", "    \\\\"),
            ("w = stdout().writer(io, \\\\ // text", "w = stdout().writer(io, \\\\"),
        ):
            with self.subTest(line=line):
                self.assertEqual(zig_code_without_literals(line), [code])


class YamlCodeTest(unittest.TestCase):
    def test_comments_end_the_code(self):
        for line, code in (
            ("# note", ""),
            ("    # note", ""),
            ("run: make # note", "run: make"),
            ("run: |  # note", "run: |"),
        ):
            with self.subTest(line=line):
                self.assertEqual(yaml_code(line), [code])

    def test_quotes_and_words_keep_a_hash(self):
        for line in (
            'run: echo "a # not a comment"',
            "run: echo 'a # not a comment'",
            "run: echo 'it''s # quoted'",
            'run: echo "say \\" # quoted"',
            "run: echo ${#items}",
            "url: https://example.test/#anchor",
        ):
            with self.subTest(line=line):
                self.assertEqual(yaml_code(line), [line])


class CheckersTest(unittest.TestCase):
    def test_every_zig_or_yaml_checker_reads_lines_through_source_lines(self):
        for path in sorted(TOOLS.glob("check_*.py")):
            text = path.read_text(encoding="utf-8")
            if ".zig" not in text and ".yml" not in text:
                continue
            with self.subTest(checker=path.name):
                fix = f"tools/{path.name}: read each line with source_lines.zig_code, source_lines.zig_code_without_literals, or source_lines.yaml_code, which drop comments outside literals."
                self.assertTrue("from source_lines import" in text, fix)
                for raw in (".splitlines()", 'startswith("//")', 'startswith("#")'):
                    self.assertFalse(raw in text, fix)


if __name__ == "__main__":
    unittest.main()
