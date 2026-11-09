from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_error_comparisons as checker

OLD_PRESENTATION_LINE = (
    "            self.failure = if (err == error.OutOfMemory) .out_of_memory else .buffer_build_failed;"
)


class ErrorComparisonCheckTest(unittest.TestCase):
    def check(self, text):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "tui" / "presentation.zig"
            source.parent.mkdir(parents=True)
            source.write_text(text)
            return list(checker.violations(root))

    def test_the_old_presentation_line_is_rejected(self):
        # src/tui/presentation.zig compared OutOfMemory with == before this change.
        found = self.check("fn build(self: *PrepareSession) void {\n" + OLD_PRESENTATION_LINE + "\n}\n")
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig:2:", found[0])
        self.assertIn("switch on the error with named prongs and no else that drops a cause", found[0])

    def test_an_inequality_comparison_is_rejected(self):
        found = self.check("fn cause(err: anytype) void {\n    if (err != error.WriteFailed) return err;\n}\n")
        self.assertEqual(len(found), 1)
        self.assertIn("`!= error.`", found[0])

    def test_a_comparison_inside_a_test_block_is_allowed(self):
        text = "\n".join((
            "fn prod() void {}",
            'test "a fixture may compare an error" {',
            "    if (err == error.OutOfMemory) return;",
            "}",
        ))
        self.assertEqual(self.check(text), [])

    def test_a_comparison_inside_a_string_or_a_comment_is_allowed(self):
        text = "\n".join((
            'const sample = "if (err == error.OutOfMemory) .out_of_memory else .buffer_build_failed";',
            "// if (err != error.WriteFailed) return err;",
            "const kept = 1; // err == error.OutOfMemory",
        ))
        self.assertEqual(self.check(text), [])

    def test_the_checkout_passes(self):
        self.assertEqual(list(checker.violations(ROOT)), [])


if __name__ == "__main__":
    unittest.main()
