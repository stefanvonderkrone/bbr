"""Regression checks for the agent-document validator."""

from pathlib import Path
import importlib.util
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "check_agent_docs", Path(__file__).resolve().parents[1] / "tools/check_agent_docs.py"
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class AgentDocsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("AGENTS.md", "GLOSSARY-MAP.md", "docs/code-navigation.md"):
            self.write(name, "# Documentation\n")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def ticket(self, number, status="ready-for-agent", blockers="none", kind=""):
        self.write(f".scratch/feature/issues/{number:02}-ticket.md",
                   f"# Ticket\n\n**Status:** {status}\n{kind}**Blocked by:** {blockers}\n")

    def test_valid_links_and_historical_metadata(self):
        self.ticket(1, status="done")
        self.ticket(2, status="completed", blockers="01 - First ticket")
        self.write(".scratch/feature/SPEC.md", "Status: resolved\n")
        self.write("AGENTS.md", "[Navigation](docs/code-navigation.md#entry-points)\n"
                   "[Web](https://example.com/absent)\n`[Example](absent.md)`\n"
                   "```md\n[Example](absent.md)\n```\n")
        self.assertEqual(checker.check(self.root), [])

    def test_broken_link_and_invalid_status(self):
        self.write("AGENTS.md", "[Missing](missing.md)\n")
        self.ticket(1, status="typo")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("broken link missing.md", errors)
        self.assertIn("invalid or missing Status: 'typo'", errors)

    def test_missing_blocker_and_cycle(self):
        self.ticket(1, blockers="02; 03 - Missing ticket")
        self.ticket(2, blockers="01")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("missing blocker 03", errors)
        self.assertIn("dependency cycle", errors)

    def test_stale_open_spec(self):
        self.ticket(1, status="resolved")
        self.write(".scratch/feature/SPEC.md", "Status: ready-for-agent\n")
        self.assertTrue(any("spec is still open" in e for e in checker.check(self.root)))

    def test_integrated_acceptance_can_keep_spec_claimed(self):
        self.ticket(1, status="resolved")
        self.write(".scratch/feature/SPEC.md", "Status: claimed\n")
        self.assertEqual(checker.check(self.root), [])

    def test_premature_spec_closure(self):
        self.ticket(1)
        self.write(".scratch/feature/SPEC.md", "Status: resolved\n")
        self.assertTrue(any("unfinished implementation" in e for e in checker.check(self.root)))

    def test_decisions_do_not_close_spec(self):
        self.ticket(1, status="resolved", kind="Type: grilling\n")
        self.write(".scratch/feature/SPEC.md", "Status: ready-for-agent\n")
        self.assertEqual(checker.check(self.root), [])

    def test_separate_implementation_directory(self):
        self.ticket(1, status="resolved")
        self.write(".scratch/decisions/SPEC.md",
                   "Status: resolved\nImplementation directory: ../feature\n")
        self.assertEqual(checker.check(self.root), [])

    def test_section_blockers(self):
        self.ticket(1, status="resolved")
        self.write(".scratch/feature/issues/02-ticket.md",
                   "Status: ready-for-agent\n\n## Blocked by\n\n- 01 - First ticket\n")
        self.assertEqual(checker.check(self.root), [])

    def test_linked_blockers_and_paths_with_spaces(self):
        self.ticket(1, status="resolved")
        self.ticket(2, blockers="[01 - First ticket](01-ticket.md)")
        self.write("docs/space name.md", "# Reference\n")
        self.write("AGENTS.md", '[Reference](<docs/space name.md> "Title")\n')
        self.assertEqual(checker.check(self.root), [])

    def test_period_separated_blockers(self):
        self.ticket(1, blockers="02 - First. 03 - Second.")
        self.ticket(2, status="resolved")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("missing blocker 03", errors)

    def test_empty_or_mixed_none_blockers_fail(self):
        self.ticket(1, blockers="")
        self.ticket(2, blockers="none, 99")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("missing Blocked by", errors)
        self.assertIn("invalid blocker: 'none'", errors)
        self.assertIn("missing blocker 99", errors)

    def test_reference_style_links(self):
        self.write("AGENTS.md", "[Missing][ref]\n\n[ref]: absent.md\n")
        self.assertTrue(any("broken link absent.md" in e for e in checker.check(self.root)))

    def test_footnote_text_is_not_a_reference_destination(self):
        self.write("AGENTS.md", "Text[^note].\n\n[^note]: [Reference](docs/code-navigation.md)\n")
        self.assertEqual(checker.check(self.root), [])


if __name__ == "__main__":
    unittest.main()
