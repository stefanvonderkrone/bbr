"""Regression checks for the action error and event origin write validator."""

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

    fn showError(self: *Presentation, err: ActionError) void {
        self.showErrorFor(err, null);
    }

    fn showErrorFor(self: *Presentation, err: ActionError, key: ?OwnedRemoteReviewIdentity) void {
        self.action_error = .{ .err = err, .origin = self.errorOrigin(), .key = key };
    }

    fn clearError(self: *Presentation) void {
        const shown = self.action_error orelse return;
        const origin = self.errorOrigin();
        if (origin == .user or shown.origin == origin) self.action_error = null;
    }

    fn acceptPullRequests(self: *Presentation) void {
        if (self.action_error == null) self.clearError();
        // self.action_error = null;
        const text = "self.action_error = null";
        _ = text;
    }

    pub fn projection(self: *const Presentation) Projection {
        return .{ .action_error = if (self.action_error) |shown| shown.err else null };
    }
};
"""


# showError before the PullRequest key, when it wrote the field itself.
OLD_SHOW_ERROR = """pub const Presentation = struct {
    action_error: ?ShownError = null,

    fn showError(self: *Presentation, err: ActionError) void {
        self.action_error = .{ .err = err, .origin = self.errorOrigin() };
    }
};
"""


# A retry inside a key event that sets the origin by hand and never restores it.
HAND_ORIGIN = """pub const Presentation = struct {
    event_origin: ?ErrorOrigin = null,

    fn openReviewSearch(self: *Presentation) void {
        self.event_origin = .review_search;
        self.replaceReviewSearchQuery(text);
    }
};
"""
ORIGIN_HELPERS = """pub const Presentation = struct {
    event_origin: ?ErrorOrigin = null,

    pub fn dispatch(self: *Presentation, input: OwnedInput) !void {
        const outer_origin = self.event_origin;
        self.event_origin = input.errorOrigin();
        defer self.event_origin = outer_origin;
        if (self.event_origin == .user) self.applyKey(input.key);
    }

    fn withErrorOrigin(self: *Presentation, origin: ErrorOrigin, comptime work: anytype, args: anytype) void {
        const outer = self.event_origin;
        self.event_origin = origin;
        defer self.event_origin = outer;
        @call(.auto, work, args);
    }

    fn openReviewSearch(self: *Presentation) void {
        // self.event_origin = .review_search;
        self.withErrorOrigin(.review_search, replaceReviewSearchQuery, .{ self, text });
    }
};
"""
# The query retry of ticket 06 before main added the PullRequest key.
COPIED_ORIGIN = """pub const Presentation = struct {
    fn retryReviewSearchQuery(self: *Presentation) void {
        const shown = self.action_error;
        self.replaceReviewSearchQuery(text);
        if (state.needs_scan) if (shown) |kept| self.withErrorOrigin(kept.origin, showError, .{ self, kept.err });
        self.withErrorOrigin(
            kept.origin,
            showErrorFor,
            .{ self, kept.err, kept.key },
        );
    }
};

fn showTestError(state: *Presentation, origin: ErrorOrigin, err: ActionError) void {
    state.withErrorOrigin(origin, Presentation.showError, .{ state, err });
}
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
        self.assertIn("src/tui/presentation.zig:8: writes action_error outside showErrorFor and clearError.", found[0])
        self.assertIn("clearError()", found[0])

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
        self.assertEqual([message.split(":")[1] for message in found], ["30", "33"])

    def test_show_error_may_not_write_the_field_itself(self):
        found = self.check(OLD_SHOW_ERROR)
        self.assertEqual(len(found), 1, found)
        self.assertIn("src/tui/presentation.zig:5: writes action_error outside showErrorFor and clearError.", found[0])

    def test_the_helpers_reads_comments_literals_and_projection_fields_are_allowed(self):
        self.assertEqual(self.check(HELPERS), [])

    def test_a_hand_set_event_origin_is_rejected(self):
        found = self.check(HAND_ORIGIN)
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig:5: writes event_origin outside dispatch and withErrorOrigin.", found[0])
        self.assertIn("withErrorOrigin(origin, work, args)", found[0])

    def test_a_multiline_helper_signature_keeps_its_exemption(self):
        found = self.check(
            "    fn withErrorOrigin(\n"
            "        self: *Presentation,\n"
            "        origin: ErrorOrigin,\n"
            "    ) void {\n"
            "        self.event_origin = origin;\n"
            "    }\n"
            "    fn other(self: *Presentation) void {\n"
            "        self.event_origin = null;\n"
            "    }\n"
        )
        self.assertEqual(len(found), 1, found)
        self.assertIn("src/tui/presentation.zig:8: writes event_origin outside", found[0])

    def test_dispatch_and_the_override_helper_may_set_the_event_origin(self):
        self.assertEqual(self.check(ORIGIN_HELPERS), [])

    def test_a_copied_origin_in_presentation_is_rejected(self):
        found = self.check(COPIED_ORIGIN)
        self.assertEqual([message.split(":")[1] for message in found], ["5", "6"])
        self.assertIn("is not an enum literal", found[0])
        self.assertIn("failMaintenance", found[0])

    def test_a_file_without_the_presentation_struct_is_rejected(self):
        found = self.check(COPIED_ORIGIN.replace("pub const Presentation = struct {", "pub const Renamed = struct {"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("src/tui/presentation.zig:1: has no line `pub const Presentation = struct {`", found[0])


if __name__ == "__main__":
    unittest.main()
