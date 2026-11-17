"""Regression checks for the Nav field validator."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_navigation_fields", TOOLS / "check_navigation_fields.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

# The Buffer Search input start and the Escape restore build before ticket 19.
OLD_INPUT = """const BufferSearchInput = struct {
    active: ?usize = null,
    saved_navigation: Nav,
    origin: usize,
};
"""
OLD_BUILD = """pub const DisclosureBuild = struct {
    result_error: ?ActionError = null,
    restore_navigation: ?Nav = null,
};
"""


class NavigationFieldsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src/tui").mkdir(parents=True)

    def check(self, text, path="src/tui/presentation.zig"):
        (self.root / path).write_text(text, encoding="utf-8")
        return list(checker.violations(self.root))

    def test_the_old_input_start_and_restore_build_are_rejected(self):
        found = self.check(OLD_INPUT + OLD_BUILD)
        self.assertEqual(len(found), 2)
        self.assertIn("src/tui/presentation.zig:3: the field `saved_navigation` of `BufferSearchInput`", found[0])
        self.assertIn("src/tui/presentation.zig:8: the field `restore_navigation` of `DisclosureBuild`", found[1])
        self.assertIn("NavigationAnchor", found[0])

    def test_a_nav_in_a_nested_or_namespaced_field_is_rejected(self):
        found = self.check(
            "const Outer = struct {\n"
            "    const Inner = struct {\n"
            "        kept: nav_mod.Nav,\n"
            "    };\n"
            "    saved: []const Nav = &.{},\n"
            "    other: union(enum) {\n"
            "        nav: Nav,\n"
            "    },\n"
            "};\n"
        )
        self.assertEqual(len(found), 3)
        self.assertIn("`kept` of `Inner`", found[0])
        self.assertIn("`saved` of `Outer`", found[1])
        self.assertIn("`nav` of `an anonymous container`", found[2])

    def test_tagged_packed_file_and_multiline_default_fields_are_rejected(self):
        found = self.check(
            "kept: Nav,\n"
            "const Flags = packed struct(u8) {\n"
            "    nav: ?Nav = null,\n"
            "};\n"
            "const Choice = union(enum(u8)) {\n"
            "    nav: Nav,\n"
            "};\n"
            "const Pending = struct {\n"
            "    nav: Nav = .{\n"
            "        .row_count = 0,\n"
            "        .viewport = 1,\n"
            "    },\n"
            "};\n"
        )
        self.assertEqual([message.split(":")[1] for message in found], ["1", "3", "6", "9"])
        self.assertIn("of `the file struct of presentation.zig`", found[0])
        self.assertIn("of `Flags`", found[1])
        self.assertIn("of `Choice`", found[2])
        self.assertIn("of `Pending`", found[3])

    def test_frame_owners_anchors_parameters_and_tests_are_allowed(self):
        found = self.check(
            "pub const Published = struct {\n"
            "    visual_rows: []const VisualRow,\n"
            "    navigation: Nav,\n"
            "};\n"
            "const BufferSearchInput = struct {\n"
            "    start: frame_mod.NavigationAnchor,\n"
            "    index: NavigationIndex,\n"
            "    // saved_navigation: Nav,\n"
            "};\n"
            "fn draw(\n"
            "    nav: Nav,\n"
            ") void {\n"
            "    const restored: Nav = nav;\n"
            "    _ = restored;\n"
            "}\n"
            'test "a fixture" {\n'
            "    const Snapshot = struct {\n"
            "        navigation: Nav,\n"
            "    };\n"
            "}\n"
        )
        self.assertEqual(found, [])

    def test_a_test_inside_a_struct_is_allowed_and_the_fields_after_it_are_checked(self):
        found = self.check(
            "const Holder = struct {\n"
            '    test "a fixture" {\n'
            "        const Snapshot = struct {\n"
            "            navigation: Nav,\n"
            "        };\n"
            "    }\n"
            "    kept: Nav,\n"
            "};\n"
        )
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig:7: the field `kept` of `Holder`", found[0])

    def test_a_test_inside_a_test_keeps_the_outer_test_excluded(self):
        found = self.check(
            'test "outer" {\n'
            "    const Local = struct {\n"
            '        test "inner" {}\n'
            "    };\n"
            "    const Snapshot = struct {\n"
            "        navigation: Nav,\n"
            "    };\n"
            "}\n"
            "const Holder = struct {\n"
            "    kept: Nav,\n"
            "};\n"
        )
        self.assertEqual(len(found), 1)
        self.assertIn("src/tui/presentation.zig:10: the field `kept` of `Holder`", found[0])

    def test_an_owner_name_in_another_file_is_rejected_and_test_files_are_skipped(self):
        frame = "pub const Projection = struct {\n    navigation: Nav,\n};\n"
        self.assertEqual(self.check(frame, "src/tui/frame.zig"), [])
        self.assertEqual(len(self.check(frame, "src/tui/render.zig")), 1)
        (self.root / "src/tui/render.zig").unlink()
        self.assertEqual(self.check(OLD_INPUT.replace("BufferSearchInput", "Snapshot"), "src/tui/hardening_test.zig"), [])


if __name__ == "__main__":
    unittest.main()
