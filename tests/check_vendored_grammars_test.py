"""Regression checks for the vendored Grammar check."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_vendored_grammars", TOOLS / "check_vendored_grammars.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
import adapt_queries  # noqa: E402
import vendor_grammar  # noqa: E402

COMMIT = "a2f694478be07f89c2d03cc17858a8745a400c4b"
RAW_BASE = "; Base\n(identifier) @variable\n"
RAW_DEMO = "; inherits: base\n(comment) @comment @spell\n"


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class VendoredGrammarsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.vendor = self.root / checker.VENDOR
        self.write("runtime/src/lib.c", "// runtime\n")
        self.write("nvim-treesitter/LICENSE", "Apache-2.0\n")
        self.write("README.md", "# Vendored\n")
        self.write("nvim-treesitter/queries/base/highlights.scm", RAW_BASE)
        self.write("nvim-treesitter/queries/demo/highlights.scm", RAW_DEMO)
        self.write("demo/LICENSE", "MIT\n")
        self.write("demo/src/parser.c", "#define LANGUAGE_VERSION 15\n")
        adapted = adapt_queries.adapt("demo", "highlights", self.vendor / checker.RAW_QUERIES, COMMIT, frozenset({"demo"}))
        self.write("demo/queries/highlights.scm", adapted)
        self.files = [
            "demo/LICENSE",
            "demo/queries/highlights.scm",
            "demo/src/parser.c",
            "nvim-treesitter/queries/base/highlights.scm",
            "nvim-treesitter/queries/demo/highlights.scm",
        ]
        self.write_manifest()

    def write(self, path, text):
        target = self.vendor / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))

    def write_manifest(self, extra_entry=""):
        files = "".join(
            f'.{{ .path = "{path}", .sha256 = "{hashlib.sha256((self.vendor / path).read_bytes()).hexdigest()}" }},\n'
            for path in self.files
        )
        self.write(
            "manifest.zig.zon",
            f""".{{
    .runtime = .{{ .lib_c_sha256 = "{digest('// runtime' + chr(10))}" }},
    .nvim_treesitter = .{{ .repository = "https://example.invalid", .commit = "{COMMIT}" }},
    .tree_sitter_cli = .{{ .version = "0.26.9" }},
    .grammars = .{{
        .demo = .{{
            .name = "Demo",
            .location = null,
            .symbol = "tree_sitter_demo",
            .abi = 15,
            .generated = null,
            .query_source = .nvim_treesitter,
            .sources = .{{"demo/src/parser.c"}},
            .highlights = "demo/queries/highlights.scm",
            .injections = null,
            .locals = null,
            .files = .{{
                {files}
            }},
            .matches = .{{ .filenames = .{{}}, .extensions = .{{".demo"}}, .shebangs = .{{}} }},
        }},
        {extra_entry}
    }},
}}
""",
        )

    def violations(self):
        return list(checker.violations(self.root))

    def assertOneViolation(self, fragment):
        found = self.violations()
        self.assertEqual(len(found), 1, found)
        self.assertIn(fragment, found[0])

    def test_clean_tree_passes(self):
        self.assertEqual(self.violations(), [])

    def test_changed_checksum(self):
        self.write("demo/src/parser.c", "#define LANGUAGE_VERSION 14\n")
        self.assertOneViolation("demo/src/parser.c: checksum differs")

    def test_unlisted_file_in_grammar_directory(self):
        self.write("demo/src/scanner.c", "// scanner\n")
        self.assertOneViolation("demo/src/scanner.c: file is not in .demo.files")

    def test_unlisted_shared_raw_query(self):
        self.write("nvim-treesitter/queries/other/highlights.scm", RAW_BASE)
        self.assertOneViolation("other/highlights.scm: shared file is in no .files list")

    def test_inherited_raw_query_must_be_listed(self):
        self.files.remove("nvim-treesitter/queries/base/highlights.scm")
        self.write_manifest()
        found = self.violations()
        self.assertTrue(any("does not list the raw query nvim-treesitter/queries/base/highlights.scm" in item for item in found), found)

    def test_manifest_entry_without_directory(self):
        self.write_manifest(extra_entry='.missing = .{ .name = "Missing", .files = .{}, .sources = .{}, .highlights = "missing/q.scm", .injections = null, .locals = null, .query_source = .upstream },')
        self.assertOneViolation("manifest entry .missing has no directory")

    def test_directory_without_manifest_entry(self):
        self.write("stray/LICENSE", "MIT\n")
        found = self.violations()
        self.assertIn(f"{checker.VENDOR}/stray: directory has no manifest entry", found)

    def test_hand_edited_adapted_query(self):
        path = self.vendor / "demo/queries/highlights.scm"
        path.write_bytes(path.read_bytes() + b"(string) @string\n")
        self.write_manifest()
        self.assertOneViolation("adapted query differs from a new adaptation")

    def test_the_build_uses_no_raw_query(self):
        manifest = self.vendor / "manifest.zig.zon"
        text = manifest.read_text(encoding="utf-8")
        manifest.write_text(text.replace('.highlights = "demo/queries/highlights.scm"', '.highlights = "nvim-treesitter/queries/demo/highlights.scm"'), encoding="utf-8")
        found = self.violations()
        self.assertIn(f"{checker.MANIFEST}: .demo uses nvim-treesitter/queries/demo/highlights.scm, but the build compiles only files under demo/", found)

    def test_command_exit_status(self):
        script = TOOLS / "check_vendored_grammars.py"
        clean = subprocess.run([sys.executable, script, self.root], capture_output=True, text=True)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.write("demo/src/parser.c", "changed\n")
        changed = subprocess.run([sys.executable, script, self.root], capture_output=True, text=True)
        self.assertEqual(changed.returncode, 1)
        self.assertIn("checksum differs", changed.stderr)

    def test_zon_parser_reads_the_repository_manifest(self):
        manifest = checker.load_manifest(TOOLS.parent)
        self.assertEqual(manifest["grammars"]["zig"]["matches"]["extensions"], [".zig", ".zon"])
        self.assertEqual(manifest["grammars"]["bash"]["query_source"], "upstream")
        self.assertIsNone(manifest["grammars"]["zig"]["location"])


class VendorGrammarManifestTest(unittest.TestCase):
    ENTRY = {
        "name": "Demo",
        "repository": "https://example.invalid/tree-sitter-demo",
        "revision": "v1.0.0",
        "commit": "0" * 40,
        "location": "demo",
        "symbol": "tree_sitter_demo",
        "abi": 15,
        "generated": {"cli": "0.26.9", "command": "tree-sitter generate --abi 15", "js_runtime": "node v24.0.0"},
        "query_source": "nvim_treesitter",
        "sources": ["demo/demo/src/parser.c"],
        "highlights": "demo/queries/highlights.scm",
        "injections": None,
        "locals": None,
        "files": [{"path": "demo/LICENSE", "sha256": "1" * 64}],
        "matches": {"filenames": ["Demofile"], "extensions": [".demo", ".dm"], "shebangs": []},
    }

    def test_rendered_entry_parses_back(self):
        text = ".{\n    .grammars = .{\n" + vendor_grammar.render_entry("demo", self.ENTRY) + vendor_grammar.MANIFEST_END
        self.assertEqual(checker.parse_zon(text)["grammars"]["demo"], self.ENTRY)

    def test_update_manifest_replaces_or_appends_one_entry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = root / checker.MANIFEST
            manifest.parent.mkdir(parents=True)
            manifest.write_text(".{\n    .grammars = .{\n" + vendor_grammar.render_entry("first", {"name": "First"}) + vendor_grammar.MANIFEST_END)
            vendor_grammar.update_manifest(root, "demo", vendor_grammar.render_entry("demo", {"name": "Old"}))
            vendor_grammar.update_manifest(root, "demo", vendor_grammar.render_entry("demo", {"name": "New"}))
            grammars = checker.load_manifest(root)["grammars"]
            self.assertEqual(list(grammars), ["first", "demo"])
            self.assertEqual(grammars["demo"], {"name": "New"})

    def test_parsers_entry_reads_install_info_and_requires(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "lua/nvim-treesitter").mkdir(parents=True)
            (root / "lua/nvim-treesitter/parsers.lua").write_text(
                "return {\n"
                "  demo = {\n    install_info = {\n      generate = true,\n      location = 'demo',\n"
                "      revision = 'v1.0.0',\n      url = 'https://example.invalid/demo',\n    },\n"
                "    requires = { 'demo_only' },\n    tier = 2,\n  },\n}\n"
            )
            entry = vendor_grammar.parsers_entry(root, "demo")
            self.assertEqual(entry, {"generate": True, "location": "demo", "revision": "v1.0.0", "url": "https://example.invalid/demo", "requires": ["demo_only"]})
            with self.assertRaises(vendor_grammar.VendorError):
                vendor_grammar.parsers_entry(root, "missing")


if __name__ == "__main__":
    unittest.main()
