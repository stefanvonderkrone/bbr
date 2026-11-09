from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_task_spawns as checker

# The page spawn of listPagesConcurrent at commit 2c8dbf0. Every page task got the
# coordinator's Client and so the boundary's slot.
OLD_PAGE_SPAWN = "                    if (select.concurrent(.page, Lists.Slot.fetch, .{ self, slot, index })) |_| {"


class TaskSpawnCheckTest(unittest.TestCase):
    def check(self, text, path="src/bitbucket/client.zig"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / path
            source.parent.mkdir(parents=True)
            source.write_text(text)
            return list(checker.violations(root))

    def test_the_old_page_spawn_is_rejected(self):
        found = self.check("fn list(self: Client) void {\n" + OLD_PAGE_SPAWN + "\n}\n")
        self.assertEqual(len(found), 1)
        self.assertIn("src/bitbucket/client.zig:2: starts a task with `.concurrent(`", found[0])
        self.assertIn("diagnostics.concurrent or diagnostics.selectConcurrent", found[0])

    def test_an_io_spawn_and_an_async_spawn_are_rejected(self):
        text = "\n".join((
            "fn start(io: std.Io) void {",
            "    var future = try io.concurrent(work, .{});",
            "    group.async(io, work, .{});",
            "}",
        ))
        found = self.check(text)
        self.assertEqual(len(found), 2)
        self.assertIn("`.async(`", found[1])

    def test_a_spawn_through_diagnostics_is_allowed(self):
        text = "\n".join((
            'const bbr = @import("bbr");',
            'const diagnostics = @import("../diagnostics.zig");',
            "fn start(io: std.Io) void {",
            "    var future = try bbr.diagnostics.concurrent(io, work, .{});",
            "    try diagnostics.selectConcurrent(&select, .page, fetch, .{});",
            "}",
        ))
        self.assertEqual(self.check(text), [])

    def test_the_owner_test_blocks_strings_and_comments_are_allowed(self):
        self.assertEqual(self.check("    return io.concurrent(function, args);\n", "src/diagnostics.zig"), [])
        text = "\n".join((
            'test "a fixture may spawn directly" {',
            "    var future = try io.concurrent(work, .{});",
            "}",
            'const sample = "io.concurrent(work, .{})";',
            "// select.concurrent(.page, fetch, .{ self })",
        ))
        self.assertEqual(self.check(text), [])

    def test_the_checkout_passes(self):
        self.assertEqual(list(checker.violations(ROOT)), [])

    def test_a_receiver_with_a_diagnostics_suffix_is_rejected(self):
        found = self.check("fn f() void { task_diagnostics.concurrent(work, .{}); }")
        self.assertEqual(len(found), 1)

    def test_an_allowed_wrapper_does_not_hide_another_spawn_on_its_line(self):
        text = 'const bbr = @import("bbr");\nfn f() void { bbr.diagnostics.concurrent(io, work, .{}); task_diagnostics.concurrent(work, .{}); }'
        self.assertEqual(len(self.check(text)), 1)

    def test_a_wrapper_call_split_across_lines_is_allowed(self):
        # zig fmt keeps a chain that the author breaks before its `.concurrent(`.
        text = "\n".join((
            'const bbr = @import("bbr");',
            'const diagnostics = bbr.diagnostics;',
            "fn start(io: std.Io) void {",
            "    var a = try diagnostics",
            "        .concurrent(io, work, .{});",
            "    var b = try bbr",
            "        .diagnostics",
            "        .concurrent(io, work, .{});",
            "}",
        ))
        self.assertEqual(self.check(text), [])

    def test_a_spawn_split_across_lines_is_rejected(self):
        text = "fn start(io: std.Io) void {\n    var future = try io\n        .concurrent(work, .{});\n}\n"
        found = self.check(text)
        self.assertEqual(len(found), 1)
        self.assertIn("src/bitbucket/client.zig:3:", found[0])

    def test_a_receiver_named_diagnostics_that_is_not_the_wrapper_is_rejected(self):
        for declaration in ("", "const diagnostics = std.Io;", 'const bbr = @import("other");'):
            text = declaration + "\nfn start(diagnostics: std.Io) void {\n    _ = diagnostics.concurrent(work, .{});\n    _ = bbr.diagnostics.concurrent(io, work, .{});\n}\n"
            self.assertEqual(len(self.check(text)), 2, declaration)

    def test_a_local_named_diagnostics_beside_no_wrapper_import_is_rejected(self):
        text = "fn start(io: std.Io) void {\n    const diagnostics = io;\n    _ = diagnostics.concurrent(work, .{});\n}\n"
        self.assertEqual(len(self.check(text)), 1)


if __name__ == "__main__":
    unittest.main()
