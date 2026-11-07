from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DiagnosticTypesTest(unittest.TestCase):
    def test_context_and_cause_reject_untrusted_strings(self):
        source = (ROOT / "src/diagnostic.zig").read_text()
        for declaration in ("Context = struct", "Cause = union(enum)"):
            with self.subTest(declaration=declaration), tempfile.TemporaryDirectory() as temporary:
                broken = source.replace(f"pub const {declaration} {{", f"pub const {declaration} {{\n    untrusted: []const u8,", 1)
                self.assertNotEqual(source, broken)
                file = Path(temporary) / "diagnostic.zig"
                file.write_text(broken)
                result = subprocess.run([os.environ.get("ZIG", "zig"), "test", str(file)], capture_output=True, text=True, timeout=60)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("diagnostic evidence must contain only closed causes and numeric identities", result.stderr)


if __name__ == "__main__":
    unittest.main()
