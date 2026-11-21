"""Regression checks for the action error write validator."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_action_errors", TOOLS / "check_action_errors.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

# The clipboard completion before ticket 03 cleared every shown error.
OLD_CLIPBOARD = """pub const Presentation = struct {
    action_error: ?ShownError = null,

    pub fn dispatch(self: *Presentation, input: OwnedInput) !void {
        switch (input) {
            .clipboard_completed => |completed| {
                self.clipboard_status = if (completed.success) .copied else .failed;
                self.action_error = null;
            },
        }
    }
};
"""
HELPERS = """pub const Presentation = struct {
    action_error: ?ShownError = null,

    fn showError(self: *Presentation, origin: ErrorOrigin, err: ActionError) void {
        self.action_error = .{ .err = err, .origin = origin };
    }

    fn clearError(self: *Presentation, origin: ErrorOrigin) void {
        const shown = self.action_error orelse return;
        if (origin == .user or shown.origin == origin) self.action_error = null;
    }

    fn acceptPullRequests(self: *Presentation) void {
        if (self.action_error == null) self.clearError(.picker);
        // self.action_error = null;
        const text = "self.action_error = null";
        _ = text;
    }

    pub fn projection(self: *const Presentation) Projection {
        return .{ .action_error = if (self.action_error) |shown| shown.err else null };
    }
};
"""


class ActionErrorsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src/tui").mkdir(parents=True)

    def check(self, text):
        (self.root / "src/tui/presentation.zig").write_text(text, encoding="utf-8")
        return list(checker.violations(self.root))

    def test_the_old_clipboard_reset_is_rejected(self):
        found = self.check(OLD_CLIPBOARD)
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig:8: writes action_error outside its helpers.", found[0])
        self.assertIn("clearError(origin)", found[0])

    def test_writes_of_a_test_and_after_the_helpers_are_rejected(self):
        found = self.check(
            HELPERS
            + 'test "a fixture" {\n'
            + "    state.action_error = .{ .err = .out_of_memory, .origin = .user };\n"
            + "}\n"
            + "fn reset(presentation: *Presentation) void {\n"
            + "    presentation.*.action_error = null;\n"
            + "}\n"
        )
        self.assertEqual([message.split(":")[1] for message in found], ["25", "28"])

    def test_the_helpers_reads_comments_literals_and_projection_fields_are_allowed(self):
        self.assertEqual(self.check(HELPERS), [])


if __name__ == "__main__":
    unittest.main()
