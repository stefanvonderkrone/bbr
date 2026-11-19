from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def compile_test(body, module, path):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root.zig"
        root.write_text(f'const std = @import("std");\nconst {module} = @import("{module}");\ntest {{\n{body}\n}}\n')
        return subprocess.run(
            [os.environ.get("ZIG", "zig"), "test", "--test-no-exec", "--dep", module, f"-Mroot={root}", f"-M{module}={ROOT / path}"],
            capture_output=True, text=True, timeout=120)


class PublishedMentionNamesTest(unittest.TestCase):
    """A write through Session.mention_names, a *const MentionNames, does not compile."""

    declaration = '    const names: *const review_body.MentionNames = &.{};\n'

    def test_a_read_compiles(self):
        result = compile_test(self.declaration + '    _ = names.get("id");', "review_body", "src/tui/review_body.zig")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_write_is_a_compile_error(self):
        for write in ('names.getPtr("id").?.* = "@New";', 'names.kvs.values[0] = "@New";', 'names.values()[0] = "@New";'):
            with self.subTest(write=write):
                result = compile_test(self.declaration + f"    {write}", "review_body", "src/tui/review_body.zig")
                self.assertNotEqual(result.returncode, 0, f"{write} compiles, so a published Session can change its mention names")
                self.assertIn("error:", result.stderr)


class ReadOnlyAssertTest(unittest.TestCase):
    """read_only.assert names each mutable pointer that a value can reach."""

    def test_each_reachable_mutable_pointer_is_a_compile_error(self):
        for name, declaration in {
            "the old MentionNames type": "*const std.StringHashMapUnmanaged([]const u8)",
            "a field": "struct { items: []u8 }",
            "a function pointer": "*const fn () *u8",
            "a vector": "@Vector(2, *u8)",
            "a method return": "struct { pub fn at(_: @This()) *u8 { unreachable; } }",
            "an enum method return": "enum { a, pub fn at(_: @This()) *u8 { unreachable; } }",
        }.items():
            with self.subTest(name=name):
                result = compile_test(f'    read_only.assert({declaration}, "value");', "read_only", "src/tui/read_only.zig")
                self.assertNotEqual(result.returncode, 0, f"read_only.assert accepts {name}")
                self.assertIn("so a write through it compiles", result.stderr)

    def test_a_const_type_passes(self):
        result = compile_test('    read_only.assert(*const std.StaticStringMap([]const u8), "value");', "read_only", "src/tui/read_only.zig")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
