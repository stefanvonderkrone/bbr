"""Checks that THIRD_PARTY_NOTICES holds the licence of every vendored component that bbr links."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "third_party_notices.py"
sys.path.insert(0, str(ROOT / "tools"))
import check_vendored_grammars  # noqa: E402

FIXED_LICENSES = (
    "vendors/tree-sitter/runtime/LICENSE",
    "vendors/tree-sitter/nvim-treesitter/LICENSE",
    "vendors/re2/LICENSE",
    "vendors/abseil/LICENSE",
)


def generate(root, output):
    return subprocess.run(
        [sys.executable, str(TOOL), str(root), str(output)],
        capture_output=True,
        text=True,
        check=False,
    )


class RepositoryNoticesTest(unittest.TestCase):
    def test_every_vendored_licence_is_in_the_notices(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "THIRD_PARTY_NOTICES"
            result = generate(ROOT, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            notices = output.read_text(encoding="utf-8")

        grammars = check_vendored_grammars.load_manifest(ROOT)["grammars"]
        licences = [
            f"vendors/tree-sitter/{file['path']}"
            for entry in grammars.values()
            for file in entry["files"]
            if Path(file["path"]).name == "LICENSE"
        ]
        self.assertEqual(len(licences), len(grammars))
        for path in (*FIXED_LICENSES, *licences):
            with self.subTest(path=path):
                self.assertIn(f"File: {path}\n", notices)
                self.assertIn((ROOT / path).read_text(encoding="utf-8").strip(), notices)
        for entry in grammars.values():
            with self.subTest(grammar=entry["name"]):
                self.assertIn(f"\n{entry['name']} Grammar\n", notices)


class FixtureNoticesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in FIXED_LICENSES:
            self.write(path, f"licence of {path}\n")
        self.write("vendors/tree-sitter/demo/LICENSE", "MIT demo\n")
        self.write(
            "vendors/regex-manifest.zig.zon",
            '.{ .re2 = .{ .repository = "https://example.invalid/re2", .commit = "r" },'
            ' .abseil = .{ .repository = "https://example.invalid/abseil", .commit = "a" } }\n',
        )
        self.write_manifest('.{ .path = "demo/LICENSE", .sha256 = "0" }, .{ .path = "demo/src/parser.c", .sha256 = "0" }')

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def write_manifest(self, files):
        self.write(
            "vendors/tree-sitter/manifest.zig.zon",
            '.{ .runtime = .{ .repository = "https://example.invalid/ts", .commit = "t" },'
            ' .nvim_treesitter = .{ .repository = "https://example.invalid/nvim", .commit = "n" },'
            ' .grammars = .{ .demo = .{ .name = "Demo", .repository = "https://example.invalid/demo",'
            f' .commit = "d", .files = .{{ {files} }} }} }} }}\n',
        )

    def assertFails(self, fragment):
        output = self.root / "THIRD_PARTY_NOTICES"
        result = generate(self.root, output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(fragment, result.stderr)
        self.assertFalse(output.exists())

    def test_fixture_notices_list_each_component_once(self):
        output = self.root / "THIRD_PARTY_NOTICES"
        result = generate(self.root, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        notices = output.read_text(encoding="utf-8")
        for text in ("MIT demo", *(f"licence of {path}" for path in FIXED_LICENSES)):
            self.assertEqual(notices.count(text), 1, text)

    def test_missing_grammar_licence_file_fails(self):
        (self.root / "vendors/tree-sitter/demo/LICENSE").unlink()
        self.assertFails("vendors/tree-sitter/demo/LICENSE")

    def test_grammar_without_licence_entry_fails(self):
        self.write_manifest('.{ .path = "demo/src/parser.c", .sha256 = "0" }')
        self.assertFails(".demo.files lists no LICENSE")

    def test_missing_nvim_treesitter_licence_fails(self):
        (self.root / "vendors/tree-sitter/nvim-treesitter/LICENSE").unlink()
        self.assertFails("vendors/tree-sitter/nvim-treesitter/LICENSE")


if __name__ == "__main__":
    unittest.main()
