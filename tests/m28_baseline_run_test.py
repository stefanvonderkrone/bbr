"""Check the PullRequest file rules of tools/m28-baseline-run.sh. No network access and no bbr run."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/m28-baseline-run.sh"


class BaselineRunTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="m28-baseline-run-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "tools").mkdir()
        shutil.copy(SCRIPT, self.root / "tools/m28-baseline-run.sh")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.zig_log = self.root / "zig.log"
        fake_zig = bin_dir / "zig"
        fake_zig.write_text(f'#!/bin/sh\necho "$@" >> "{self.zig_log}"\nexit 1\n')
        fake_zig.chmod(0o755)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("BITBUCKET_") and not key.lower().endswith("_proxy")
                    and key != "M28_PULLREQUESTS_FILE"}
        self.env.update(HOME=str(self.home), PATH=f"{bin_dir}:/usr/bin:/bin")

    def run_script(self, *args, env=None):
        return subprocess.run(["sh", str(self.root / "tools/m28-baseline-run.sh"), *args],
                              capture_output=True, text=True, env=env or self.env, timeout=10)

    def write(self, name, text):
        path = self.root / name
        path.write_text(text)
        return str(path)

    def assert_stops_before_build(self, result, message):
        self.assertEqual(result.returncode, 2, result)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.zig_log.exists(), "the script started a build")

    def test_missing_file_stops_before_build(self):
        result = self.run_script("--pullrequests", str(self.root / "absent.txt"), "run1", "home")
        self.assert_stops_before_build(result, "is missing or unreadable")

    def test_missing_default_file_stops_before_build(self):
        self.assert_stops_before_build(self.run_script("run1", "home"), "home/m28-runs/pullrequests.txt")

    def test_empty_file_stops_before_build(self):
        path = self.write("empty.txt", "# Only a comment\n\n   \n")
        self.assert_stops_before_build(self.run_script("--pullrequests", path, "run1", "home"),
                                       "holds no PullRequest id")

    def test_malformed_file_stops_before_build(self):
        for text in ("12\nabc\n", "12 34\n", "0\n", "-5\n", "#12\n7x\n"):
            with self.subTest(text=text):
                path = self.write("bad.txt", text)
                self.assert_stops_before_build(self.run_script("--pullrequests", path, "run1", "home"),
                                               "malformed id")

    def test_variable_names_the_file(self):
        env = dict(self.env, M28_PULLREQUESTS_FILE=self.write("bad.txt", "x\n"))
        self.assert_stops_before_build(self.run_script("run1", "home", env=env), "malformed id 'x'")

    def test_argument_overrides_variable(self):
        env = dict(self.env, M28_PULLREQUESTS_FILE=self.write("bad.txt", "x\n"))
        good = self.write("good.txt", "# PullRequests\n 12 \n\n34 # comment\n")
        result = self.run_script("--pullrequests", good, "run1", "home", str(self.root / "out"), env=env)
        self.assertEqual(result.returncode, 1, result)
        self.assertEqual(self.zig_log.read_text(), "build install-bench-file-cache\n")

    def test_missing_labels_print_usage(self):
        result = self.run_script("--pullrequests")
        self.assertEqual(result.returncode, 2, result)
        self.assertIn("usage:", result.stderr)
        self.assertFalse(self.zig_log.exists())


if __name__ == "__main__":
    unittest.main()
