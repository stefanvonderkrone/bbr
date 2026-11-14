from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_search_index as checker

# The acceptViewBuild line of commit 7e1930b, with retainedSearchIndex under its new name.
OLD_ADMISSION_LINE = (
    "        const active = if (job.rebuilt_batch) |rebuilt| nearestSearchIndex(published.buffer_search.accepted_batch, "
    "published.buffer_search.active, rebuilt) else published.buffer_search.active;"
)
INPUT_LINE = "            const next_active = nearestProjectedSearchIndex(input.batch, input.active, batch, rows);"
RETRY = "\n".join((
    "    fn retryAcceptedDisclosure(self: *Presentation) void {",
    "        const destination = nearestSearchIndex(job.accepted_snapshot, job.destination_active, current);",
    "    }",
))


class SearchIndexCheckTest(unittest.TestCase):
    def check(self, text, nearest=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "tui" / "presentation.zig"
            source.parent.mkdir(parents=True)
            source.write_text(text)
            entries = nearest if nearest is not None else {
                ("src/tui/presentation.zig", "acceptViewBuild", "nearestProjectedSearchIndex"): "input",
                ("src/tui/presentation.zig", "retryAcceptedDisclosure", "nearestSearchIndex"): "move",
            }
            saved = checker.NEAREST
            checker.NEAREST = entries
            try:
                return list(checker.violations(root))
            finally:
                checker.NEAREST = saved

    def admission(self, *lines):
        return "\n".join(("    fn acceptViewBuild(self: *Presentation) void {", *lines, "    }")) + "\n" + RETRY + "\n"

    def test_the_old_admission_line_is_rejected(self):
        found = self.check(self.admission(OLD_ADMISSION_LINE, INPUT_LINE))
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig:2: acceptViewBuild maps an occurrence with nearestSearchIndex", found[0])
        self.assertIn("uses sameSearchIndex", found[0])

    def test_the_fixed_admission_is_allowed(self):
        fixed = OLD_ADMISSION_LINE.replace("nearestSearchIndex", "sameSearchIndex")
        self.assertEqual(self.check(self.admission(fixed, INPUT_LINE)), [])

    def test_a_second_nearest_call_in_a_listed_function_is_rejected(self):
        found = self.check(self.admission(INPUT_LINE, INPUT_LINE))
        self.assertEqual(len(found), 1)
        self.assertIn(":3: acceptViewBuild", found[0])

    def test_a_listed_function_that_no_longer_calls_the_nearest_rule_is_rejected(self):
        found = self.check(self.admission("        const active = null;"))
        self.assertEqual(len(found), 1)
        self.assertIn("acceptViewBuild no longer calls nearestProjectedSearchIndex", found[0])

    def test_tests_comments_strings_and_the_definition_are_allowed(self):
        text = "\n".join((
            "fn nearestSearchIndex(previous: ?usize) ?usize {",
            "    return previous;",
            "}",
            "// nearestSearchIndex(a, b, c)",
            'const sample = "nearestSearchIndex(a, b, c)";',
            'test "a test may compare both rules" {',
            "    _ = nearestSearchIndex(a, b, c);",
            "}",
        ))
        self.assertEqual(self.check(text, nearest={}), [])

    def test_the_checkout_passes(self):
        self.assertEqual(list(checker.violations(ROOT)), [])


if __name__ == "__main__":
    unittest.main()
