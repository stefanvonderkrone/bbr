from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ConvertDropsTest(unittest.TestCase):
    def test_list_reads_the_current_checker_findings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / ".scratch/error-handling-discipline/convert_drops.py"
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / script.relative_to(root), script)
            shutil.copytree(ROOT / "tools", root / "tools", ignore=shutil.ignore_patterns("__pycache__"))
            (root / "src").mkdir()
            (root / "src/example.zig").write_text("fn f() void { x() catch {}; }\n")
            result = subprocess.run(
                [sys.executable, str(script), "--list"],
                cwd=root, text=True, capture_output=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("src/example.zig:1", result.stdout)


if __name__ == "__main__":
    unittest.main()
