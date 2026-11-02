"""Regression checks for the XDG read validator."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_xdg_reads", TOOLS / "check_xdg_reads.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class XdgReadsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        self.source = self.root / "src/main.zig"

    def test_a_read_outside_src_xdg_zig(self):
        for variable in checker.VARIABLES:
            with self.subTest(variable=variable):
                self.source.write_text(f"const base = env.get({variable});\n", encoding="utf-8")
                self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_owner_comments_test_blocks_and_fixtures_are_allowed(self):
        (self.root / checker.OWNER).write_text('const base = env.get("XDG_CONFIG_HOME");\n', encoding="utf-8")
        self.source.write_text(
            '// xdg.configHome reads "XDG_CONFIG_HOME".\n'
            'const base = xdg.configHome(env); // not env.get("XDG_DATA_HOME")\n'
            'try env.put("XDG_STATE_HOME", "/tmp/state");\n'
            'test "a relative base" {\n    const base = env.get("XDG_CONFIG_HOME");\n}\n',
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])


if __name__ == "__main__":
    unittest.main()
