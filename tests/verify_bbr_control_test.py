"""Regression checks for failed verification launches."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "verify_bbr_control",
    Path(__file__).resolve().parents[1] / ".agents/skills/verify-bbr/scripts/control.py",
)
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class VerifyBbrControlTest(unittest.TestCase):
    def test_build_failure_and_timeout_retain_run_and_remove_scratch(self):
        for error in (
            subprocess.CalledProcessError(1, ["zig", "build"]),
            subprocess.TimeoutExpired(["zig", "build"], control.COMMAND_TIMEOUT),
        ):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)

                def fail_build(*args, **kwargs):
                    records = list(root.glob(".scratch/verify-bbr/*/instance.json"))
                    self.assertEqual(len(records), 1)
                    state = json.loads(records[0].read_text(encoding="utf-8"))
                    self.assertEqual((Path(state["scratch"]) / "owner").read_text(), str(records[0].parent))
                    self.assertEqual(args[0], ["zig", "build"])
                    self.assertEqual(kwargs["timeout"], control.COMMAND_TIMEOUT)
                    self.assertEqual(kwargs["cwd"], root)
                    raise error

                with patch.object(control, "ROOT", root), patch.object(control.sys, "argv", ["control.py", "launch"]):
                    with patch.object(control.subprocess, "run", side_effect=fail_build):
                        with self.assertRaises(type(error)):
                            control.main()

                record, = root.glob(".scratch/verify-bbr/*/instance.json")
                state = json.loads(record.read_text(encoding="utf-8"))
                self.assertFalse(Path(state["scratch"]).exists())
                cleanup = json.loads((record.parent / "cleanup.json").read_text(encoding="utf-8"))
                self.assertTrue(cleanup["scratch_removed"])


if __name__ == "__main__":
    unittest.main()
