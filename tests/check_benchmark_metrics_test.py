"""Regression checks for the benchmark cell metrics validator."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_benchmark_metrics", TOOLS / "check_benchmark_metrics.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class BenchmarkMetricsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src/benchmark").mkdir(parents=True)
        (self.root / "src/benchmark_buffer_search.zig").write_text("", encoding="utf-8")
        self.source = self.root / "src/benchmark/p1_actions.zig"

    def test_the_old_visual_row_and_file_tree_lines_are_rejected(self):
        self.source.write_text(
            "    return tui.frame.buildVisualRowsWithOptions(allocator, context.rows, .bytes, .{\n"
            "        0,\n"
            "        .bytes,\n"
            "    );\n",
            encoding="utf-8",
        )
        found = list(checker.violations(self.root))
        self.assertEqual([message.split(":")[1] for message in found], ["1", "3"])
        self.assertIn("tui.terminal_cell_metrics", found[0])

    def test_a_named_bytes_metrics_is_rejected(self):
        self.source.write_text("const metrics = tui.cell_metrics.CellMetrics.bytes;\n", encoding="utf-8")
        self.assertEqual(len(list(checker.violations(self.root))), 1)

    def test_terminal_metrics_fields_calls_comments_and_strings_are_allowed(self):
        self.source.write_text(
            "    return tui.frame.buildVisualRowsWithOptions(allocator, context.rows, tui.terminal_cell_metrics, .{\n"
            "const size = blob.bytes.len; // not .bytes\n"
            "const text = grapheme.bytes(source);\n"
            "const label = \".bytes\";\n",
            encoding="utf-8",
        )
        self.assertEqual(list(checker.violations(self.root)), [])


if __name__ == "__main__":
    unittest.main()
