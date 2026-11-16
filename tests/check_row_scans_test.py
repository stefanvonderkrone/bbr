from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_row_scans as checker

# src/tui/presentation.zig at 6236c4c: every event on a File header ran this scan.
OLD_AVAILABILITY_SCAN = """fn selectedVersionUnavailableForFile(buffer: buffer_mod.Buffer, file_index: usize, selected: SelectedVersion) bool {
    for (buffer.rows, 0..) |row, index| {
        if (buffer.fileIndexForRow(index) != file_index or row != .status_placeholder) continue;
        const state = if (selected == .old) row.status_placeholder.old else row.status_placeholder.new;
        switch (state orelse continue) {
            .empty => {},
            else => return true,
        }
    }
    return false;
}
"""


class RowScanCheckTest(unittest.TestCase):
    def check(self, text, baseline=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "tui" / "presentation.zig"
            source.parent.mkdir(parents=True)
            source.write_text(text)
            if baseline is not None:
                (root / "tools").mkdir()
                (root / checker.BASELINE).write_text(baseline)
            return list(checker.violations(root))

    def test_the_old_availability_scan_is_rejected(self):
        found = self.check(OLD_AVAILABILITY_SCAN)
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig: 1 `fileIndexForRow` calls inside loops over all rows (lines 3)", found[0])
        self.assertIn("Buffer.statusPlaceholders", found[0])

    def test_a_single_statement_loop_over_visual_rows_is_rejected(self):
        text = "fn f(p: P) void {\n    for (p.frame.visual_rows) |v| if (p.buffer.fileIndexForRow(v.buffer_index) == 1) count(v);\n}\n"
        self.assertEqual(len(self.check(text)), 1)

    def test_a_loop_over_the_indexes_of_all_rows_is_rejected(self):
        text = "fn f(buffer: Buffer) void {\n    for (0..buffer.rows.len) |i| _ = buffer.fileIndexForRow(i);\n}\n"
        self.assertEqual(len(self.check(text)), 1)

    def test_a_loop_over_a_slice_of_rows_or_without_the_call_is_allowed(self):
        text = "\n".join((
            "fn f(buffer: Buffer, range: R) void {",
            "    for (buffer.rows[range.start..range.end]) |row| _ = buffer.fileIndexForRow(row);",
            "    for (buffer.rows) |row| use(row);",
            "    const file = buffer.fileIndexForRow(0);",
            "}",
        ))
        self.assertEqual(self.check(text), [])

    def test_a_scan_inside_a_test_block_is_allowed(self):
        text = "fn prod() void {}\ntest \"fixture\" {\n" + OLD_AVAILABILITY_SCAN.split("\n", 1)[1]
        self.assertEqual(self.check(text), [])

    def test_the_baseline_allows_existing_scans_and_must_go_down(self):
        self.assertEqual(self.check(OLD_AVAILABILITY_SCAN, "1 src/tui/presentation.zig\n"), [])
        found = self.check("fn f() void {}\n", "1 src/tui/presentation.zig\n")
        self.assertEqual(len(found), 1)
        self.assertIn("--write-baseline", found[0])

    def test_the_checkout_passes(self):
        self.assertEqual(list(checker.violations(ROOT)), [])


if __name__ == "__main__":
    unittest.main()
