from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "tools/check_doc_symbols.py"


class DocSymbolsTest(unittest.TestCase):
    def check(self, document, source, *, path="AGENTS.md"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src/fixture.zig").write_text(source, encoding="utf-8")
            doc = root / path
            doc.parent.mkdir(parents=True, exist_ok=True)
            doc.write_text(document, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), str(root)],
                capture_output=True,
                text=True,
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


if __name__ == "__main__":
    unittest.main()
