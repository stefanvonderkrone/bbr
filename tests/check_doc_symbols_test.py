from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "tools/check_doc_symbols.py"


class DocSymbolsTest(unittest.TestCase):
    def check(self, document, source, *, path="AGENTS.md", missing=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src/fixture.zig").write_text(source, encoding="utf-8")
            for required in ("AGENTS.md", "CODING_STANDARDS.md", "docs/rules/fixture.md"):
                if required not in missing:
                    (root / required).parent.mkdir(parents=True, exist_ok=True)
                    (root / required).write_text("", encoding="utf-8")
            doc = root / path
            doc.parent.mkdir(parents=True, exist_ok=True)
            doc.write_text(document, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), str(root)],
                capture_output=True,
                text=True,
                timeout=5,
            )

    def assert_rejected(self, result, name, location="AGENTS.md:1"):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"{location}: `{name}`", result.stderr)
        self.assertIn("rename it to the current symbol, or remove it", result.stderr)

    def test_removed_storage_budget_member_fails(self):
        result = self.check(
            "# Storage\nUse `Storage.far_over_budget_bytes`.\n",
            "const Storage = struct { budget_bytes: usize };\n"
            "// far_over_budget_bytes was removed.\n",
            path="docs/rules/tui-state.md",
        )
        self.assert_rejected(result, "Storage.far_over_budget_bytes", "docs/rules/tui-state.md:2")

    def test_removed_disclosure_member_fails_despite_another_owner(self):
        result = self.check(
            "Use `DisclosureBuild.accepted_active`.\n",
            "const DisclosureBuild = struct { active: bool };\n"
            "const Other = struct { accepted_active: bool };\n",
        )
        self.assert_rejected(result, "DisclosureBuild.accepted_active")

    def test_explicit_type_annotation_keeps_the_member_in_its_owner(self):
        result = self.check(
            "Use `Storage.removed`.\n",
            "const Storage: type = struct { bytes: usize };\nconst removed = 0;\n",
        )
        self.assert_rejected(result, "Storage.removed")

    def test_current_members_and_module_prefixes_pass(self):
        for name in ("Storage.budget_bytes", "tui.Storage.budget_bytes", "bbr.Storage.budget_bytes"):
            with self.subTest(name=name):
                result = self.check(f"Use `{name}`.\n", "const Storage = struct { budget_bytes: usize };\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_current_method_passes(self):
        result = self.check(
            "Call `Storage.clear()`.\n",
            "const Storage = struct { pub fn clear() void {} };\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_external_names_and_file_names_pass(self):
        result = self.check("Use `std.Io.Group.await` and `vaxis.Window.print` in `build.zig`.\n", "")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generic_error_placeholder_passes(self):
        result = self.check("A named prong uses `error.X`.\n", "")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fenced_names_pass_and_the_next_name_fails(self):
        for fence in ("```", "~~~~"):
            with self.subTest(fence=fence):
                result = self.check(f"{fence}zig\n`Missing.member`\n{fence}\n", "")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.check(f"{fence}zig\n`Missing.member`\n{fence}\n`Missing.member`\n", "")
                self.assert_rejected(result, "Missing.member", "AGENTS.md:4")

    def test_comments_and_literals_do_not_supply_member_names(self):
        result = self.check(
            "Use `Storage.removed`.\n",
            "const Storage = struct {\n"
            "// removed: usize,\n"
            'const text = "removed";\n'
            "};\n",
        )
        self.assert_rejected(result, "Storage.removed")

    def test_same_named_container_can_supply_its_own_member(self):
        result = self.check(
            "Use `Storage.budget`.\n",
            "const Storage = struct { bytes: usize };\n"
            "const Nested = struct { const Storage = struct { budget: usize }; };\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_name_in_coding_standards_fails(self):
        result = self.check("Use `Missing.member`.\n", "", path="CODING_STANDARDS.md")
        self.assert_rejected(result, "Missing.member", "CODING_STANDARDS.md:1")

    def test_renamed_enforcement_test_fails(self):
        result = self.check(
            "## Retry\n\n"
            'Enforcement: "M21 kernel Review Search retries a reopened query scan" in `src/fixture.zig` fails.\n',
            'test "Review recovery a Review Search query retry clears its failed scan error" {}\n'
            '// test "M21 kernel Review Search retries a reopened query scan" {}\n'
            'const old = "M21 kernel Review Search retries a reopened query scan";\n',
            path="docs/rules/tui-state.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(
            'docs/rules/tui-state.md:3: src/fixture.zig has no test "M21 kernel Review Search retries a reopened query scan". '
            "Point the Enforcement paragraph at an existing test, or restore the test.",
            result.stderr,
        )

    def test_current_enforcement_tests_pass(self):
        result = self.check(
            '## One\n\nThe rule "quoted" is prose.\n\n'
            'Enforcement: the tests "first" and "second" in `src/fixture.zig`.\n\n'
            'Enforcement: the block in `src/fixture.zig`. The test\n"second" fails.\n\n'
            'Enforcement: the CI step "Lint the tree" runs the tests whose names contain `fir`.\n\n'
            'Enforcement: the libc `extern "c" fn mkfifo` fails in `src/fixture.zig`.\n\n'
            '```\nEnforcement: "missing" in `src/fixture.zig`.\n```\n',
            'test "first" {}\n    test "second" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enforcement_test_takes_the_next_file_and_its_unescaped_name(self):
        result = self.check(
            'Enforcement: the tests in `src/other.zig`, and "\\ No newline marker" and "the wrapped\n'
            'name" in `src/fixture.zig`.\n',
            'test "\\\\ No newline marker" {}\ntest "the wrapped name" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enforcement_file_needs_the_word_in(self):
        result = self.check(
            'Enforcement: the test "first" and the join `src/fixture.zig`.\n',
            'test "first" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('docs/rules/fixture.md:1: the test "first" names no file.', result.stderr)

    def test_wrapped_stale_test_name_fails_at_its_first_line(self):
        result = self.check(
            'Enforcement: the test "the old\nname" in `src/fixture.zig`.\n',
            'test "the new name" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('docs/rules/fixture.md:1: src/fixture.zig has no test "the old name".', result.stderr)

    def test_enforcement_test_without_its_file_fails(self):
        result = self.check(
            'Enforcement: the test "first".\n\nEnforcement: the test\n"first" in `src/missing.zig`.\n',
            'test "first" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('docs/rules/fixture.md:1: the test "first" names no file.', result.stderr)
        self.assertIn('docs/rules/fixture.md:4: the test "first" names the missing file src/missing.zig.', result.stderr)

    def test_step_quote_ends_before_the_next_test_name(self):
        result = self.check(
            'Enforcement: the CI step "Lint" runs "first" in `src/fixture.zig`.\n\n'
            'Enforcement: the CI Step "Lint" runs "old" in `src/fixture.zig`.\n\n'
            'Enforcement: the CI steps "Lint", "Build" and "Test" run "first" in `src/fixture.zig`.\n\n'
            'Enforcement: the CI step "Lint" and "gone" in `src/fixture.zig` fail.\n\n'
            'Enforcement: the tests "parse step" and "first" in `src/fixture.zig` fail.\n',
            'test "first" {}\ntest "parse step" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        message = (
            'docs/rules/fixture.md:{}: src/fixture.zig has no test "{}". '
            "Point the Enforcement paragraph at an existing test, or restore the test. "
            "If the quote is not a test name, write it as a code span."
        )
        self.assertEqual(result.stderr.splitlines(), [message.format(3, "old"), message.format(7, "gone")])

    def test_single_and_curly_quotes_fail(self):
        result = self.check(
            "Enforcement: the agents' test 'first' and \u201cfirst\u201d and \u2018first\u2019 in `src/fixture.zig` don't pass. "
            "The `bbr`'s output and the agents' docs pass.\n",
            'test "first" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        message = (
            "docs/rules/fixture.md:1: the quote {} is not in double quotes. "
            "Write a test name in double quotes. If the quote is not a test name, write it as a code span."
        )
        self.assertEqual(
            result.stderr.splitlines(),
            [message.format("'first'"), message.format("\u201cfirst\u201d"), message.format("\u2018first\u2019")],
        )

    def test_enforcement_file_stays_in_the_sentence_of_the_test(self):
        result = self.check(
            'Enforcement: the test "first" fails. The block in `src/fixture.zig` holds it.\n\n'
            'Enforcement: the block in `src/fixture.zig` holds it. The test "first" fails. The block in `src/other.zig` is other.\n\n'
            'Enforcement: in `src/fixture.zig`, the test "first. And more" fails.\n\n'
            'Enforcement: in `src/fixture.zig`, does the test "first" fail? The block in `src/other.zig` is other.\n\n'
            'Enforcement: the test "first" fails! The block in `src/fixture.zig` is other.\n',
            'test "first" {}\ntest "first. And more" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                'docs/rules/fixture.md:1: the test "first" names no file. '
                'Add "in `<file>.zig`" to its sentence or to a sentence before it. '
                "If the quote is not a test name, write it as a code span.",
                'docs/rules/fixture.md:9: the test "first" names no file. '
                'Add "in `<file>.zig`" to its sentence or to a sentence before it. '
                "If the quote is not a test name, write it as a code span.",
            ],
        )

    def test_missing_file_error_names_the_code_span_fix(self):
        result = self.check(
            'Enforcement: the test "first" in `src/missing.zig`.\n',
            'test "first" {}\n',
            path="docs/rules/fixture.md",
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                'docs/rules/fixture.md:1: the test "first" names the missing file src/missing.zig. '
                "Name the file that holds the test. If the quote is not a test name, write it as a code span."
            ],
        )


    def test_missing_document_fails(self):
        result = self.check("", "", path="docs/rules/fixture.md", missing=("CODING_STANDARDS.md",))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODING_STANDARDS.md: the document is missing.", result.stderr)

    def test_empty_rule_directory_fails(self):
        result = self.check("", "", missing=("docs/rules/fixture.md",))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/rules/*.md: no rule documents found.", result.stderr)


if __name__ == "__main__":
    unittest.main()
