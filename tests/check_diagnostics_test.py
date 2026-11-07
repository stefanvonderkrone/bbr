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

    def test_a_with_diagnostics_wrapper_is_rejected(self):
        # The pair that let writeTrustQuestion drop its Handle after a merge.
        text = "\n".join((
            "pub fn writeCandidateReport(a: A, w: *W) ![32]u8 {",
            "    return writeCandidateReportWithDiagnostics(a, w, .{});",
            "}",
            "pub fn writeCandidateReportWithDiagnostics(a: A, w: *W, diagnostic: Handle) ![32]u8 {",
            "    return report(a, w, diagnostic);",
            "}",
        ))
        found = self.check("src/highlight/grammar_cli.zig", text)
        self.assertEqual(len(found), 1)
        self.assertIn("required diagnostics.Handle", found[0])
        self.assertEqual(self.check("src/highlight/highlighter.zig", "pub fn withDiagnostics(self: H, d: Handle) H {}"), [])

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

    def test_an_unrelated_native_call_on_the_line_does_not_hide_an_unwrapped_result(self):
        found = self.check("src/persist/sqlite_store.zig", "_ = self.native(rc, .step, @src()); _ = c.sqlite3_finalize(stmt);")
        self.assertEqual(len(found), 1)
        self.assertIn("sqlite_store.zig:1:", found[0])

    def test_a_multiline_wrapper_and_another_receiver_are_accepted(self):
        text = "\n".join((
            "if (self.native(",
            "    c.sqlite3_step(stmt),",
            "    .step,",
            "    @src(),",
            ") != c.SQLITE_DONE) return error.Step;",
            "defer _ = store.native(c.sqlite3_finalize(stmt), .finalize, @src());",
        ))
        self.assertEqual(self.check("src/persist/sqlite_store.zig", text), [])

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
