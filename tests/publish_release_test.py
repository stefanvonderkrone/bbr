"""Check release publication without sending requests to GitHub."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "publisher", Path(__file__).resolve().parents[1] / "tools/publish_release.py"
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
TAG = "v2024.3.24-1"


class PublishReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bbr-publish-release-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        original = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, original)
        self.env = patch.dict(os.environ, {"GH_REPO": "example/bbr"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.assets = {}
        for target in ("macos-x86_64", "macos-aarch64", "linux-x86_64", "linux-aarch64"):
            name = f"bbr-{TAG}-{target}.tar.gz"
            self.assets[name] = target.encode()
            (self.root / name).write_bytes(self.assets[name])
        self.assets["SHA256SUMS"] = "".join(
            f"{hashlib.sha256(data).hexdigest()}  {name}\n"
            for name, data in self.assets.items()
        ).encode()
        (self.root / "SHA256SUMS").write_bytes(self.assets["SHA256SUMS"])
        self.release = {"draft": True, "assets": {"SHA256SUMS": b"incomplete"}}
        self.latest = None
        self.commands = []
        self.fail_upload = False
        self.api_error = None
        self.process = patch.object(publisher.subprocess, "run", side_effect=self.gh)
        self.process.start()
        self.addCleanup(self.process.stop)

    def gh(self, command, **kwargs):
        """Model the CLI requests and the draft state that survives a failure."""
        self.commands.append(command)
        if command[1] == "api":
            if self.api_error:
                raise subprocess.CalledProcessError(1, command, stderr=self.api_error)
            data = {"data": {"repository": {
                "release": None if self.release is None else {"isDraft": self.release["draft"]},
                "latestRelease": self.latest,
            }}}
            return subprocess.CompletedProcess(command, 0, json.dumps(data), "")
        action = command[2]
        if action == "create":
            if self.release is not None:
                raise subprocess.CalledProcessError(1, command, stderr="already_exists")
            self.assertIn("--draft", command)
            self.assertIn("--verify-tag", command)
            self.release = {"draft": True, "assets": {}}
        elif action == "upload":
            self.assertTrue(self.release["draft"])
            self.assertIn("--clobber", command)
            paths = [Path(arg) for arg in command[4:] if arg != "--clobber"]
            self.assertEqual(len(paths), len({path.name for path in paths}))
            for path in paths:
                data = path.read_bytes()
                self.assertEqual(data, self.assets[path.name])
                self.release["assets"][path.name] = data
                if self.fail_upload:
                    raise subprocess.CalledProcessError(1, command)
        elif action == "edit":
            self.assertEqual(self.release["assets"], self.assets)
            self.assertIn("--draft=false", command)
            self.release["draft"] = False
        else:
            self.fail(f"unexpected CLI call: {command}")
        return subprocess.CompletedProcess(command, 0, "", "")

    def test_existing_draft_is_completed_with_all_assets(self):
        publisher.publish(TAG)
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.release["assets"], self.assets)
        self.assertFalse(any(command[1:3] == ["release", "create"] for command in self.commands))

    def test_published_release_is_not_changed(self):
        self.release["draft"] = False
        with self.assertRaisesRegex(ValueError, "already published"):
            publisher.publish(TAG)
        self.assertTrue(all(command[1] == "api" for command in self.commands))

    def test_new_release_stays_draft_until_all_assets_are_uploaded(self):
        self.release = None
        publisher.publish(TAG)
        self.assertFalse(self.release["draft"])
        self.assertIn("--latest=true", self.commands[-1])

    def test_interrupted_upload_can_resume(self):
        self.release = None
        self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.publish(TAG)
        self.assertTrue(self.release["draft"])
        self.assertFalse(any(command[1:3] == ["release", "edit"] for command in self.commands))
        self.fail_upload = False
        publisher.publish(TAG)
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.release["assets"], self.assets)

    def test_older_retry_does_not_replace_latest_release(self):
        self.latest = {"tagName": "v2024.3.24-2"}
        publisher.publish(TAG)
        self.assertIn("--latest=false", self.commands[-1])

    def test_latest_comparison_uses_numbers(self):
        self.latest = {"tagName": "v2024.3.9-10"}
        publisher.publish(TAG)
        self.assertIn("--latest=true", self.commands[-1])

    def test_api_failure_does_not_create_or_change_a_release(self):
        self.api_error = "HTTP 503"
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.publish(TAG)
        self.assertTrue(all(command[1] == "api" for command in self.commands))

    def test_missing_checksums_are_rejected_before_publication(self):
        Path("SHA256SUMS").unlink()
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            publisher.publish(TAG)
        self.assertEqual(self.commands, [])

    def test_missing_target_is_rejected_before_api_calls(self):
        name = f"bbr-{TAG}-macos-aarch64.tar.gz"
        Path(name).unlink()
        del self.assets[name]
        with self.assertRaisesRegex(ValueError, "all four"):
            publisher.publish(TAG)
        self.assertEqual(self.commands, [])
        self.assertTrue(self.release["draft"])

    def test_single_surviving_archive_cannot_publish_a_release(self):
        self.release = None
        for name in list(self.assets):
            if name.endswith(".tar.gz") and "linux-x86_64" not in name:
                Path(name).unlink()
                del self.assets[name]
        with self.assertRaisesRegex(ValueError, "all four"):
            publisher.publish(TAG)
        self.assertEqual(self.commands, [])
        self.assertIsNone(self.release)

    def test_unexpected_target_is_rejected_before_api_calls(self):
        name = f"bbr-{TAG}-windows-x86_64.tar.gz"
        self.assets[name] = b"unexpected"
        Path(name).write_bytes(self.assets[name])
        with self.assertRaisesRegex(ValueError, "all four"):
            publisher.publish(TAG)
        self.assertEqual(self.commands, [])
        self.assertTrue(self.release["draft"])

    def test_archive_for_another_tag_is_rejected_before_api_calls(self):
        Path("bbr-v2024.3.24-2-linux-x86_64.tar.gz").write_bytes(b"another tag")
        with self.assertRaisesRegex(ValueError, "all four"):
            publisher.publish(TAG)
        self.assertEqual(self.commands, [])

    def test_directory_cannot_replace_a_target_archive(self):
        archive = Path(f"bbr-{TAG}-linux-aarch64.tar.gz")
        archive.unlink()
        archive.mkdir()
        with self.assertRaisesRegex(ValueError, "all four"):
            publisher.publish(TAG)
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
