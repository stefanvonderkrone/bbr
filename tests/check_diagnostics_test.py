from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_diagnostics as checker


class DiagnosticsCheckTest(unittest.TestCase):
    def check(self, path, text, baseline=None, record_baseline=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / path
            source.parent.mkdir(parents=True)
            source.write_text(text)
            for name, counts in ((checker.CATCH_BASELINE, baseline), (checker.RECORD_BASELINE, record_baseline)):
                if counts is not None:
                    (root / "tools").mkdir(exist_ok=True)
                    (root / name).write_text(counts)
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
        found = self.check("src/highlight/grammar_cli.zig", text, "")
        self.assertEqual(len(found), 1)
        self.assertIn("required diagnostics.Handle", found[0])
        self.assertEqual(self.check("src/highlight/highlighter.zig", "pub fn withDiagnostics(self: H, d: Handle) H {}", ""), [])

    def test_a_new_catch_that_drops_its_cause_is_rejected(self):
        # The DurableSubmission.begin catch that e32ce2f had to fix.
        text = "const started = DurableSubmission.begin(a) catch {\n    self.action_error = .submission_start_failed;\n    return;\n};"
        found = self.check("src/tui/presentation.zig", text)
        self.assertEqual(len(found), 1)
        self.assertIn("reportFailure", found[0])
        self.assertEqual(self.check("src/tui/presentation.zig", text, "1 src/tui/presentation.zig\n"), [])

    def test_a_named_switch_without_else_is_not_a_drop(self):
        text = "\n".join((
            "x() catch |err| switch (err) { error.OutOfMemory => fallback };",
            "y() catch |err|",
            "    switch (err) {",
            "        error.OutOfMemory => fallback,",
            "    };",
        ))
        self.assertEqual(self.check("src/tui/config.zig", text), [])

    def test_a_discarded_capture_is_a_drop(self):
        found = self.check("src/tui/config.zig", "x() catch |err| { _ = err; return error.WriteFailed; };")
        self.assertEqual(len(found), 1)
        self.assertIn("no `else`", found[0])

    def test_a_discarded_else_payload_is_a_drop(self):
        text = "x() catch |err| switch (err) { else => |e| { _ = e; return error.WriteFailed; } };"
        self.assertEqual(len(self.check("src/example.zig", text)), 1)

    def test_a_named_prong_use_does_not_cover_an_else_drop(self):
        text = "x() catch |err| switch (err) { error.ReadFailed => return err, else => return error.WriteFailed };"
        self.assertEqual(len(self.check("src/example.zig", text)), 1)

    def test_an_else_prong_that_drops_the_cause_is_rejected(self):
        text = "\n".join((
            "    writeAtomically(allocator, io, config_path, next) catch |err| return switch (err) {",
            "        error.OutOfMemory => error.OutOfMemory,",
            "        else => error.WriteFailed,",
            "    };",
        ))
        found = self.check("src/tui/config.zig", text)
        self.assertEqual(len(found), 1)
        self.assertIn("no `else`", found[0])

    def test_a_handler_that_records_the_cause_before_an_else_is_not_a_drop(self):
        text = "\n".join((
            "self.queueCandidateSession(session, replacement.intent, replacement.key) catch |err| {",
            "    self.reportFailure(.session_load, .prepare, err, @src());",
            "    self.failReplacement(replacement, switch (err) {",
            "        error.OutOfMemory => .out_of_memory,",
            "        else => .pending_review_load_failed,",
            "    });",
            "};",
        ))
        self.assertEqual(self.check("src/tui/presentation.zig", text), [])

    def test_an_else_prong_that_keeps_the_cause_is_not_a_drop(self):
        for text in (
            "x() catch |err| switch (err) { else => |e| return e };",
            "x() catch |err| switch (err) { else => return err };",
            "x() catch |err| switch (err) { else => self.reportFailure(.x, .y, err, @src()) };",
        ):
            with self.subTest(text=text):
                self.assertEqual(self.check("src/tui/config.zig", text), [])

    def test_an_uncaptured_handler_on_the_next_line_is_a_drop(self):
        found = self.check("src/tui/config.zig", "x() catch\n    return error.X;")
        self.assertEqual(len(found), 1)
        self.assertIn("drop their cause", found[0])

    def test_a_captured_cause_and_test_blocks_are_allowed_and_a_removed_drop_lowers_the_baseline(self):
        text = "\n".join((
            "x() catch |err| self.reportFailure(.submission, .prepare, err, @src());",
            'test "ignored" {',
            "    x() catch {};",
            "}",
        ))
        self.assertEqual(self.check("src/tui/presentation.zig", text), [])
        found = self.check("src/tui/presentation.zig", text, "2 src/tui/presentation.zig\n")
        self.assertEqual(len(found), 1)
        self.assertIn("Lower the count", found[0])

    def test_a_record_before_returning_the_cause_or_another_error_is_rejected(self):
        # runMain records the config load failure, and main records it again.
        main_117 = "\n".join((
            "            var loaded = config.loadSnapshot(gpa, snapshot) catch |err| {",
            "                _ = diagnostic.forContext(.configuration, .{}).failure(.read, .{ .zig = err }, @src());",
            "                return err;",
            "            };",
        ))
        found = self.check("src/main.zig", main_117)
        self.assertEqual(len(found), 1)
        self.assertIn("diagnostic.fail", found[0])
        self.assertIn("error.Reported", found[0])
        self.assertEqual(self.check("src/main.zig", main_117, record_baseline="1 src/main.zig\n"), [])
        found = self.check("src/main.zig", main_117, record_baseline="2 src/main.zig\n")
        self.assertEqual(len(found), 1)
        self.assertIn(f"Lower the count in {checker.RECORD_BASELINE}", found[0])
        for text in (
            "dlopen(path) catch |err| {\n    _ = diagnostic_handle.failure(.open, .{ .zig = err }, @src());\n    return error.NativeLibraryLoadFailed;\n};",
            "x() catch |err| switch (err) {\n    error.ReadFailed => {\n        _ = diagnostic_handle.failure(.read, .{ .zig = reader.err.? }, @src());\n        return reader.err.?;\n    },\n    else => |other| return other,\n};",
            "x() catch |err| {\n    _ = diagnostic.failure(.read, .{ .zig = err }, @src());\n    return @as(anyerror!void, err);\n};",
            "x() catch |err| {\n    _ = diagnostic.failure(.read, .{ .zig = err }, @src());\n    return switch (err) {\n        error.MissingToken => error.MissingCredential,\n        else => err,\n    };\n};",
            "x() catch |err| {\n    _ = self.diagnostic.failure(.launch, .{ .zig = err }, evidence.source);\n    return on_fail;\n};",
        ):
            with self.subTest(text=text):
                self.assertEqual(len(self.check("src/highlight/user_grammar.zig", text)), 1)

    def test_an_errdefer_that_records_is_rejected(self):
        found = self.check("src/bitbucket/client.zig", "    errdefer |err| _ = diagnostic.failure(.decode, .{ .zig = err }, source);")
        self.assertEqual(len(found), 1)
        self.assertIn("diagnostic.fail", found[0])

    def test_old_highlight_built_in_helper_record_before_plain_return_is_rejected(self):
        text = "\n".join((
            "fn highlightBuiltIn(self: *H, diagnostic: Handle) !Result {",
            "    return highlightWithPackage() catch |err| {",
            "        recordHighlightFailure(diagnostic, err);",
            "        return err;",
            "    };",
            "}",
            "fn recordHighlightFailure(diagnostic: Handle, err: anyerror) void {",
            "    switch (err) {",
            "        error.FileTooLarge, error.InvalidUtf8 => {},",
            "        else => _ = diagnostic.failure(.execute, .{ .zig = err }, @src()),",
            "    }",
            "}",
        ))
        found = self.check("src/highlight/tree_sitter_highlighter.zig", text)
        self.assertEqual(len(found), 1)
        self.assertIn("diagnostic.fail", found[0])
        self.assertIn("boundary records it once", found[0])
        for returned in ("error.Reported", ".{ .spans = &.{} }"):
            with self.subTest(returned=returned):
                self.assertEqual(self.check("src/highlight/tree_sitter_highlighter.zig", text.replace("return err;", f"return {returned};")), [])
        self.assertEqual(self.check("src/highlight/tree_sitter_highlighter.zig", text.replace("        recordHighlightFailure(diagnostic, err);\n", "")), [])

    def test_same_file_recording_helpers_are_transitive_and_errdefer_is_rejected(self):
        helpers = "\n".join((
            "fn outer(diagnostic: Handle, err: anyerror) void { inner(diagnostic, err); }",
            "fn inner(diagnostic: Handle, err: anyerror) void { _ = diagnostic.failure(.execute, .{ .zig = err }, @src()); }",
        ))
        for handler in (
            "x() catch |err| { outer(diagnostic, err); return err; };",
            "errdefer |err| outer(diagnostic, err);",
        ):
            with self.subTest(handler=handler):
                self.assertEqual(len(self.check("src/example.zig", handler + "\n" + helpers)), 1)
        self.assertEqual(self.check("src/example.zig", "x() catch |err| { cleanup(err); return err; };\n" + helpers), [])
        self.assertEqual(self.check("src/example.zig", "x() catch |err| { outer(diagnostic, other); return err; };\n" + helpers), [])

    def test_a_return_through_fail_is_allowed(self):
        for text in (
            "var loaded = config.loadSnapshot(gpa, snapshot) catch |err|\n    return diagnostic.forContext(.configuration, .{}).fail(.read, .{ .zig = err }, @src());",
            "x() catch |err| {\n    _ = diagnostic.failure(.read, .{ .zig = err }, @src());\n    return error.Reported;\n};",
        ):
            with self.subTest(text=text):
                self.assertEqual(self.check("src/main.zig", text), [])

    def test_a_record_without_a_return_is_allowed(self):
        for text in (
            "x() catch |err| self.reportFailure(.submission, .prepare, err, @src());",
            "x() catch |err| {\n    _ = bb.diagnostic.failure(.read, .{ .zig = err }, @src());\n    continue;\n};",
            # exitFailure records and never returns, so the return comes before any record.
            "status() catch |err| {\n    if (err == error.StdoutClosed) return err;\n    exitFailure(diagnostic, err, @src());\n};",
            "x() catch |err| switch (err) {\n    error.ReadFailed => self.reportFailure(.grammar, .read, err, @src()),\n    else => |other| return other,\n};",
            "x() catch |err| {\n    _ = diagnostic.failure(.read, .{ .zig = err }, @src());\n    return .{ .fetch_failed = err };\n};",
            # The nested catch returns OutOfMemory for the await, not for the recorded launch error.
            "\n".join((
                "const pair = start() catch |launch_error| {",
                "    _ = req.diagnostic.failure(.launch, .{ .zig = launch_error }, @src());",
                "    const old = old_future.await(io) catch |err| switch (err) {",
                "        error.OutOfMemory => return error.OutOfMemory,",
                "    };",
                "    return .{ .old = old };",
                "};",
            )),
        ):
            with self.subTest(text=text):
                self.assertEqual(self.check("src/tui/file_enrichment.zig", text), [])

    def test_a_return_without_a_record_is_allowed(self):
        for text in (
            "x() catch |err| return err;",
            "x() catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory };",
            "x() catch |err| {\n    side.destroy();\n    return err;\n};",
        ):
            with self.subTest(text=text):
                self.assertEqual(self.check("src/tui/file_enrichment.zig", text), [])

    def test_a_record_before_a_negative_numeric_fallback_is_allowed(self):
        text = "x() catch |err| { diagnostic.record(err); return -1; };"
        self.assertEqual(self.check("src/example.zig", text), [])

    def test_an_early_error_return_before_a_record_is_allowed(self):
        text = "x() catch |err| { if (skip) return error.Other; diagnostic.record(err); return; };"
        self.assertEqual(self.check("src/example.zig", text), [])

    def test_an_early_switch_return_before_a_record_is_allowed(self):
        text = "x() catch |err| { switch (err) { error.Other => return err, else => {} } diagnostic.record(err); return; };"
        self.assertEqual(self.check("src/example.zig", text), [])

    def test_a_separate_switch_record_does_not_cover_an_unnamed_drop(self):
        text = "x() catch |err| { switch (err) { error.OutOfMemory => diagnostic.record(err), else => {} } return; };"
        self.assertEqual(len(self.check("src/example.zig", text)), 1)

    def test_an_early_error_return_does_not_hide_a_later_record_and_error_return(self):
        text = "x() catch |err| { if (skip) return error.Other; diagnostic.record(err); return err; };"
        self.assertEqual(len(self.check("src/example.zig", text)), 1)

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

    def client(self, text):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "src/bitbucket").mkdir(parents=True)
            (root / "src/bitbucket/types.zig").write_text("pub const ApiError = error{\n    /// 403\n    Forbidden,\n    MalformedResponse,\n};\n")
            (root / checker.CLIENT).write_text(text)
            return list(checker.violations(root))

    def test_a_client_error_return_without_a_note_is_rejected(self):
        # The account UUID check and the author check of client.zig before issue 09.
        for line in (
            "        if (parsed.value.uuid.len == 0) return error.MalformedResponse;",
            "        if (before.author_uuid.len != 0 and std.mem.eql(u8, before.author_uuid, authenticated_account_uuid)) return .{ .api_error = error.Forbidden };",
            "        const author = v.author orelse return error.MalformedResponse;",
        ):
            found = self.client(line)
            self.assertEqual(len(found), 1, line)
            self.assertIn("noted(diagnostic, error.X, phase, cause)", found[0])

    def test_a_multiline_client_error_result_without_a_note_is_rejected(self):
        found = self.client("return .{\n    .api_error = error.Forbidden,\n};")
        self.assertEqual(len(found), 1)
        self.assertIn("client.zig:2:", found[0])

    def test_each_client_error_in_a_conditional_return_needs_its_own_note(self):
        found = self.client("return if (c) noted(diagnostic, error.Forbidden, .validate, null) else error.MalformedResponse;")
        self.assertEqual(len(found), 1)
        self.assertIn("client.zig:1:", found[0])

    def test_a_multiline_noted_client_error_return_is_allowed(self):
        text = "return noted(\n    diagnostic,\n    error.Forbidden,\n    .validate,\n    null,\n);"
        self.assertEqual(self.client(text), [])

    def test_a_note_in_another_argument_does_not_cover_a_client_error(self):
        found = self.client("return other(noted(diagnostic, error.Forbidden, .validate, null), error.MalformedResponse);")
        self.assertEqual(len(found), 1)
        self.assertEqual(len(self.client("return noted(error.Forbidden, err, .validate, null);")), 1)

    def test_a_switch_return_checks_results_not_error_patterns(self):
        text = "return switch (err) {\n    error.Forbidden,\n    error.MalformedResponse,\n    => error.Forbidden,\n};"
        found = self.client(text)
        self.assertEqual(len(found), 1)
        self.assertIn("client.zig:4:", found[0])

    def test_a_return_in_a_switch_prong_ends_before_the_next_prong(self):
        text = "switch (err) {\n    error.Forbidden => return,\n    error.MalformedResponse => {},\n}"
        self.assertEqual(self.client(text), [])

    def test_a_noted_return_and_test_blocks_are_allowed(self):
        text = "\n".join((
            "        if (parsed.value.uuid.len == 0) return noted(self.diagnostic, error.MalformedResponse, .validate, null);",
            "        return .{ .api_error = noted(self.diagnostic, error.Forbidden, .validate, null) };",
            "    return error.OutOfMemory;",
            "    // return error.Forbidden;",
            'test "a rejection" {',
            "    return error.Forbidden;",
            "}",
        ))
        self.assertEqual(self.client(text), [])

    def test_the_checkout_passes(self):
        self.assertEqual(list(checker.violations(ROOT)), [])


if __name__ == "__main__":
    unittest.main()
