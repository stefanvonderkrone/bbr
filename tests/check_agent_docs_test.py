"""Regression checks for the agent-document validator."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_agent_docs as checker


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

    def test_agents_md_above_the_size_cap_names_the_area_docs(self):
        self.write("docs/rules/cli.md", "# CLI rules\n")
        self.write("AGENTS.md", "x" * (checker.AGENTS_MD_CAP + 1))
        errors = "\n".join(checker.check(self.root))
        self.assertIn("AGENTS.md: 5,001 bytes, above the cap of 5,000", errors)
        self.assertIn("docs/rules/cli.md", errors)
        self.assertIn("CODING_STANDARDS.md", errors)

    def test_agents_md_at_the_size_cap_passes(self):
        self.write("AGENTS.md", "x" * checker.AGENTS_MD_CAP)
        self.assertEqual(checker.check(self.root), [])

    def test_two_adrs_with_one_number_fail(self):
        self.write("docs/adr/0016-first.md", "# First\n")
        self.write("docs/adr/0017-second.md", "# Second\n")
        self.write("docs/adr/0017-third.md", "# Third\n")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("docs/adr/0017-third.md: ADR number 0017 is also used by 0017-second.md", errors)
        self.assertIn("only sees one tree", errors)
        self.assertNotIn("0016", errors)

    def test_two_adrs_with_one_number_and_different_zero_padding_fail(self):
        self.write("docs/adr/0017-first.md", "# First\n")
        self.write("docs/adr/017-second.md", "# Second\n")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("docs/adr/017-second.md: ADR number 017 is also used by 0017-first.md", errors)


    def test_the_old_source_scan_return_type_claim_is_rejected(self):
        self.write("docs/rules/tui-state.md", "## Review Search source scan failures\n\n"
                   "Enforcement: `ScanReviewSource.create` returns no error union, so a fallible step in it does not compile. "
                   "The tests \"M21 kernel Review Search scans a File again after its source scan fails\" in "
                   "`src/tui/presentation.zig`, run by `zig build test`.\n")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("lines 3: 1 Enforcement sentences claim a compile error without a mechanism", errors)
        self.assertIn("Name the `comptime` assertion", errors)

    def test_the_old_session_const_claim_is_rejected(self):
        self.write("docs/rules/tui-state.md", "## Published Session content\n\n"
                   "Enforcement: the `const` types of the Session fields in `src/tui/session.zig` (compile error). "
                   "These are `[]const File`, `[]const Hunk`, and `[]const Line`.\n")
        self.assertTrue(any("claim a compile error without a mechanism" in e for e in checker.check(self.root)))

    def test_compile_claims_with_a_mechanism_pass(self):
        self.write("docs/rules/tui-paint.md", "## Rules\n\n"
                   "Enforcement: the exhaustive switch in `view.walk` (compile error).\n\n"
                   "Enforcement: the `comptime` block after `theme.value`. Its compile error names the Theme.\n\n"
                   "Enforcement: the `@compileError` calls of the `flag_sets` block give a compile error.\n\n"
                   "Enforcement: `tests/read_only_test.py` compiles a write and expects that it does not compile.\n")
        self.assertEqual(checker.check(self.root), [])

    def test_a_fenced_example_is_not_an_enforcement_paragraph(self):
        self.write("docs/rules/tui-state.md", "## Rules\n\n```markdown\n"
                   "Enforcement: `Thing` has no field (compile error).\n```\n")
        self.assertEqual(checker.check(self.root), [])

    def test_a_claim_on_a_continuation_line_is_rejected_at_its_line(self):
        self.write("docs/rules/tui-state.md", "## Rules\n\n"
                   "Enforcement: the test \"x\" in `src/tui/session.zig`.\n"
                   "`Thing` has no field (compile error).\n")
        errors = "\n".join(checker.check(self.root))
        self.assertIn("lines 4: 1 Enforcement sentences claim a compile error without a mechanism", errors)

    def test_a_mechanism_on_a_continuation_line_passes(self):
        self.write("docs/rules/tui-state.md", "## Rules\n\n"
                   "Enforcement: `Thing` gives a compile error through the\n"
                   "`comptime` block after `theme.value`.\n")
        self.assertEqual(checker.check(self.root), [])

    def test_the_baseline_allows_its_count_and_no_more(self):
        claim = "Enforcement: `Thing` has no field (compile error).\n\n"
        self.write("tools/compile_claim_baseline.txt", "# header\n1 docs/rules/tui-state.md\n")
        self.write("docs/rules/tui-state.md", claim)
        self.assertEqual(checker.check(self.root), [])
        self.write("docs/rules/tui-state.md", claim * 2)
        self.assertTrue(any("allows 1" in e for e in checker.check(self.root)))
        self.write("docs/rules/tui-state.md", "Enforcement: the test \"x\".\n")
        self.assertTrue(any("Lower its count" in e for e in checker.check(self.root)))

    def test_enforcement_tests_exist_in_their_files(self):
        self.write("src/a.zig", 'test "first" {}\ntest "second" {}\n')
        self.write("docs/rules/tui-state.md", "## One\n\nThe rule \"quoted\" is prose.\n\n"
                   'Enforcement: the tests "first" and "second" in `src/a.zig`.\n\n'
                   "## Two\n\n"
                   'Enforcement: the block in `src/a.zig`. The test\n"second".\n\n'
                   "## Three\n\n"
                   'Enforcement: the CI step "Lint the tree" runs `src/a.zig`.\n\n'
                   "## Four\n\n"
                   'Enforcement: the libc `extern "c" fn mkfifo` fails `core-linux-tests` in `src/a.zig`.\n')
        self.assertEqual(checker.check(self.root), [])

    def test_enforcement_test_drift_fails(self):
        self.write("src/a.zig", 'test "first" {}\n')
        self.write("docs/rules/tui-paint.md", "## One\n\n"
                   'Enforcement: the test "frist" in `src/a.zig`.\n\n'
                   'Enforcement: the test "first".\n\n'
                   'Enforcement: the test\n"first" in `src/b.zig`.\n')
        errors = "\n".join(checker.check(self.root))
        self.assertIn('docs/rules/tui-paint.md: line 3: src/a.zig has no test "frist"', errors)
        self.assertIn('line 5: test "first" names no file', errors)
        self.assertIn('line 8: test "first" names the missing file src/b.zig', errors)


if __name__ == "__main__":
    unittest.main()
