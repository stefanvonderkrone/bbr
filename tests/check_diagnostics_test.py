from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_diagnostics as checker


class DiagnosticsCheckTest(unittest.TestCase):
    def check(self, path, text):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / path
            source.parent.mkdir(parents=True)
            source.write_text(text)
            return list(checker.violations(root))

    def test_old_highlighting_warning_bypasses_the_sink(self):
        found = self.check("src/tui/presentation.zig", 'std.log.warn("code Highlighting failed: {s}", .{@errorName(err)});')
        self.assertEqual(len(found), 1)
        self.assertIn("diagnostic Handle", found[0])

    def test_old_submission_log_is_rejected(self):
        found = self.check("src/http/std_client.zig", 'const path = "bbr-submit-response.log";')
        self.assertEqual(len(found), 1)
        self.assertIn("opt-in diagnostic Sink", found[0])

    def test_old_sqlite_conversion_and_ignored_result_are_rejected(self):
        for text in (
            "if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) return error.Exec;",
            "defer _ = c.sqlite3_finalize(stmt);",
            "switch (c.sqlite3_step(stmt)) {}",
        ):
            with self.subTest(text=text):
                found = self.check("src/persist/sqlite_store.zig", text)
                self.assertEqual(len(found), 1)
                self.assertIn("SqliteStore.native", found[0])

    def test_old_auth_error_exit_must_record_its_cause(self):
        found = self.check("src/main.zig", 'fn statusRun() void {\n std.debug.print("bbr: stored credential is unusable", .{});\n std.process.exit(1);\n}')
        self.assertEqual(len(found), 1)
        self.assertIn("exitFailure", found[0])
        self.assertEqual(self.check("src/main.zig", "fn exitFailure() noreturn {\n std.process.exit(1);\n}"), [])

    def test_captured_results_comments_and_quoted_calls_are_allowed(self):
        text = '\n'.join((
            'const help = "c.sqlite3_step(stmt) std.log.warn";',
            '// std.log.warn("ignored", .{});',
            'if (self.native(c.sqlite3_exec(self.db, sql, null, null, null), .exec, @src()) != c.SQLITE_OK) return error.Exec;',
            'test "native error injection" {',
            '    _ = c.sqlite3_exec(db, "bad SQL", null, null, null);',
            '}',
        ))
        self.assertEqual(self.check("src/persist/sqlite_store.zig", text), [])

    def test_the_checkout_passes(self):
        self.assertEqual(list(checker.violations(ROOT)), [])


if __name__ == "__main__":
    unittest.main()
