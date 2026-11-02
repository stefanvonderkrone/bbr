"""Regression checks for the comment-free source lines that every line checker reads."""

from pathlib import Path
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from source_lines import zig_code, zig_code_without_literals  # noqa: E402


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


NO_ZIG_SOURCE = {
    "check_agent_docs.py": "reads the Markdown agent documents, not Zig source",
    "check_guard_mutations.py": "replaces an exact snippet in a scratch copy of the raw Zig source, so it needs the comments",
    "check_vendored_grammars.py": "hashes the vendored Grammar files and parses the ZON manifest, not Zig code lines",
}
RAW_READS = ("read_text(", "read_bytes(", "open(", ".splitlines()")


def checker_problems(path):
    """Each way the checker at `path` reads source text itself instead of through source_lines.zig_files."""
    text = path.read_text(encoding="utf-8")
    fix = (
        f"tools/{path.name}: read Zig source only with source_lines.zig_files, which drops comments outside literals. "
        f"A checker that reads no Zig source goes in NO_ZIG_SOURCE in tests/source_lines_test.py with its reason."
    )
    problems = [f"{fix} It calls {raw}" for raw in RAW_READS if raw in text]
    if "from source_lines import zig_files" not in text:
        problems.append(f"{fix} It does not import zig_files.")
    return problems


class CheckersTest(unittest.TestCase):
    def test_every_zig_checker_reads_lines_through_source_lines(self):
        for name in NO_ZIG_SOURCE:
            self.assertTrue((TOOLS / name).is_file(), f"NO_ZIG_SOURCE names tools/{name}, which does not exist.")
        for path in sorted(TOOLS.glob("check_*.py")):
            if path.name in NO_ZIG_SOURCE:
                continue
            with self.subTest(checker=path.name):
                self.assertEqual(checker_problems(path), [])


if __name__ == "__main__":
    unittest.main()
