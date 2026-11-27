from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "tools/check_doc_symbols.py"


class DocSymbolsTest(unittest.TestCase):
    def check(self, document, source, *, path="AGENTS.md", missing=(), files=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src/fixture.zig").write_text(source, encoding="utf-8")
            for name, text in (files or {}).items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text, encoding="utf-8")
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


    def check_enforcement(self, document, source="", files=None):
        return self.check(document, source, path="docs/rules/fixture.md", files=files)

    def assert_test_name_rejected(self, result, name, line=1):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'docs/rules/fixture.md:{line}: "{name}"', result.stderr)
        self.assertIn("write it as a code span", result.stderr)

    def test_renamed_test_name_in_enforcement_fails(self):
        old = "M21 kernel Review Search retries a reopened query scan that cannot queue at the next event"
        result = self.check_enforcement(
            f'## Rule\n\nEnforcement: the test "{old}" in `src/fixture.zig`.\n',
            'test "Review recovery a Review Search query retry clears its failed scan error" {}\n',
        )
        self.assert_test_name_rejected(result, old, line=3)

    def test_test_name_declared_in_another_file_passes(self):
        for name in ("src/tui/other.zig", "tests/other.zig"):
            with self.subTest(file=name):
                result = self.check_enforcement(
                    'Enforcement: the test "kept test" in `src/fixture.zig`.\n',
                    files={name: 'test "kept test" {\n}\n'},
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_commented_test_declaration_supplies_no_name(self):
        result = self.check_enforcement('Enforcement: the test "kept test".\n', '// test "kept test" {}\n')
        self.assert_test_name_rejected(result, "kept test")

    def test_multiline_string_line_supplies_no_name(self):
        result = self.check_enforcement(
            'Enforcement: the test "kept test".\n',
            'const s =\n    \\\\test "kept test" {}\n;\n',
        )
        self.assert_test_name_rejected(result, "kept test")

    def test_quote_on_a_later_line_of_the_paragraph_names_its_line(self):
        result = self.check_enforcement('Enforcement: the tests\n"missing test" run.\n')
        self.assert_test_name_rejected(result, "missing test", line=2)

    def test_quotes_outside_enforcement_paragraphs_pass(self):
        result = self.check_enforcement(
            'A rule about "anything".\n\nEnforcement: a check.\n\nThe "next" paragraph.\n'
            '```\nEnforcement: the test "fenced example".\n```\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_quotes_in_code_spans_pass(self):
        for span in ('`"Lint"`', '``a `"x"` b``', '```"x" `` y```', "``\"x\"\n\"y\"``"):
            with self.subTest(span=span):
                result = self.check_enforcement(f"Enforcement: the step {span} runs it.\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_quote_after_a_closed_code_span_fails(self):
        result = self.check_enforcement('Enforcement: the step `x` and the test "missing test".\n')
        self.assert_test_name_rejected(result, "missing test")

    def test_unclosed_backtick_run_does_not_hide_a_quote(self):
        result = self.check_enforcement('Enforcement: a `` run and the test "missing test" and ` one.\n')
        self.assert_test_name_rejected(result, "missing test")

    def test_ci_step_name_in_double_quotes_fails(self):
        result = self.check_enforcement('Enforcement: the CI step "Lint" runs it.\n')
        self.assert_test_name_rejected(result, "Lint")

    def test_curly_quote_fails(self):
        for quote in ("\u201ckept test\u201d", "\u201ekept test\u201c"):
            with self.subTest(quote=quote):
                result = self.check_enforcement(f"Enforcement: the test {quote}.\n", 'test "kept test" {}\n')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("docs/rules/fixture.md:1:", result.stderr)
                self.assertIn("the Enforcement paragraph has a curly double quote", result.stderr)
                self.assertIn("use straight double quotes", result.stderr)

    def test_apostrophes_and_single_quotes_pass(self):
        result = self.check_enforcement("Enforcement: the check's run and the 'x' word and the Theme\u2019s role.\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unpaired_double_quote_fails(self):
        result = self.check_enforcement('Enforcement: the test "kept test.\n', 'test "kept test" {}\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("docs/rules/fixture.md:1: the Enforcement paragraph has an unpaired double quote", result.stderr)

    def test_name_wrapped_over_two_lines_passes(self):
        result = self.check_enforcement('Enforcement: the test "kept\ntest" runs.\n', 'test "kept test" {}\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_names_compare_as_raw_zig_text(self):
        source = 'test "\\\\ marker" {}\ntest "a \\"b\\"" {}\n'
        result = self.check_enforcement('Enforcement: the test "\\\\ marker".\n', source)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.check_enforcement('Enforcement: the test "\\ marker".\n', source)
        self.assert_test_name_rejected(result, "\\ marker")

    def test_fence_ends_an_enforcement_paragraph(self):
        result = self.check_enforcement('Enforcement: a check.\n```\ncode\n```\nThe "next" text.\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enforcement_quotes_outside_rule_docs_pass(self):
        for path in ("AGENTS.md", "CODING_STANDARDS.md"):
            with self.subTest(path=path):
                result = self.check('Enforcement: the test "missing test".\n', "", path=path)
                self.assertEqual(result.returncode, 0, result.stderr)

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
