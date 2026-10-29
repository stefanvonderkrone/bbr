"""Check release publication without sending requests to GitHub."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
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
        self.api_error_page = None
        self.process = patch.object(publisher.subprocess, "run", side_effect=self.gh)
        self.process.start()
        self.addCleanup(self.process.stop)

    def gh(self, command, **kwargs):
        """Model the CLI requests and the draft state that survives a failure."""
        self.commands.append(command)
        if command[1] == "api":
            if self.api_error:
                raise subprocess.CalledProcessError(1, command, stderr=self.api_error)
            query = next(arg.removeprefix("query=") for arg in command if arg.startswith("query="))
            names = list(self.release["assets"]) if self.release else []
            asset_query = re.search(r"releaseAssets\s*\(\s*first:\s*(\d+)", query)
            page_size = int(asset_query[1]) if asset_query else max(1, len(names))
            offsets = range(0, max(1, len(names)), page_size)
            follows_cursors = all(field in query for field in (
                "$endCursor: String", "after: $endCursor", "pageInfo", "hasNextPage", "endCursor",
            ))
            if "--paginate" not in command or not follows_cursors:
                offsets = [0]
            pages = []
            for index, offset in enumerate(offsets, 1):
                if self.api_error_page == index:
                    raise subprocess.CalledProcessError(
                        1, command, output=json.dumps(pages), stderr="HTTP 503"
                    )
                release = None if self.release is None else {"isDraft": self.release["draft"]}
                if release is not None and asset_query:
                    release["releaseAssets"] = {
                        "nodes": [{"name": name} for name in names[offset:offset + page_size]],
                        "pageInfo": {
                            "hasNextPage": offset + page_size < len(names),
                            "endCursor": str(offset + page_size),
                        },
                    }
                pages.append({"data": {"repository": {"release": release, "latestRelease": self.latest}}})
            output = json.dumps(pages) if "--slurp" in command else "\n".join(map(json.dumps, pages))
            return subprocess.CompletedProcess(command, 0, output, "")
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

    def test_unexpected_remote_asset_is_rejected_without_writes(self):
        self.release["assets"]["private-notes.txt"] = b"must stay private"
        original_assets = self.release["assets"].copy()
        with self.assertRaisesRegex(ValueError, "private-notes.txt"):
            publisher.publish(TAG)
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.release["assets"], original_assets)
        self.assertTrue(all(command[1] == "api" for command in self.commands))

    def test_remote_asset_names_after_the_first_hundred_are_checked(self):
        self.release["assets"].update({f"unexpected-{index:03}.txt": b"private" for index in range(101)})
        original_assets = self.release["assets"].copy()
        with self.assertRaisesRegex(ValueError, "unexpected-100.txt"):
            publisher.publish(TAG)
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.release["assets"], original_assets)
        self.assertTrue(all(command[1] == "api" for command in self.commands))

    def test_asset_pagination_failure_does_not_change_a_release(self):
        self.release["assets"].update({f"unexpected-{index:03}.txt": b"private" for index in range(101)})
        self.api_error_page = 2
        original_assets = self.release["assets"].copy()
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.publish(TAG)
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.release["assets"], original_assets)
        self.assertTrue(all(command[1] == "api" for command in self.commands))

    def test_empty_existing_draft_is_recoverable(self):
        self.release["assets"] = {}
        publisher.publish(TAG)
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.release["assets"], self.assets)

    def test_complete_existing_draft_assets_are_replaced(self):
        self.release["assets"] = {name: b"old bytes" for name in self.assets}
        publisher.publish(TAG)
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.release["assets"], self.assets)

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

    def test_uncomparable_latest_does_not_block_or_replace_a_release(self):
        for existing_draft in (False, True):
            for latest_tag in (
                "v1.2.0-rc1", "v1.2.0", "nightly", "v2024.2.30-1",
                "v2024.03.9-1", "v2024.3.9-01", "v2024.3.9-0",
            ):
                with self.subTest(existing_draft=existing_draft, latest_tag=latest_tag):
                    self.release = {"draft": True, "assets": {}} if existing_draft else None
                    self.latest = {"tagName": latest_tag}
                    self.commands = []
                    publisher.publish(TAG)
                    self.assertFalse(self.release["draft"])
                    self.assertEqual(self.release["assets"], self.assets)
                    self.assertIn("--latest=false", self.commands[-1])
                    self.assertEqual(
                        any(command[1:3] == ["release", "create"] for command in self.commands),
                        not existing_draft,
                    )

    def test_valid_dated_latest_keeps_calendar_and_sequence_order(self):
        for latest_tag, make_latest in (
            ("v2023.12.31-10", True),
            ("v2024.2.29-10", True),
            (TAG, True),
            ("v2024.3.24-10", False),
            ("v2024.4.1-1", False),
        ):
            with self.subTest(latest_tag=latest_tag):
                self.release = {"draft": True, "assets": {}}
                self.latest = {"tagName": latest_tag}
                self.commands = []
                publisher.publish(TAG)
                self.assertFalse(self.release["draft"])
                self.assertEqual(self.release["assets"], self.assets)
                self.assertIn(f"--latest={str(make_latest).lower()}", self.commands[-1])

    def test_malformed_incoming_tag_is_rejected_before_api_calls(self):
        current_tag = TAG
        for tag in (
            "v1.2.0-rc1", "v1.2.0", "v2023.2.29-1", "v2024.03.24-1",
            "v2024.3.024-1", "v2024.3.24-01", "v2024.3.24-0", "2024.3.24-1",
        ):
            with self.subTest(tag=tag):
                for name in list(self.assets):
                    if name.endswith(".tar.gz"):
                        renamed = name.replace(current_tag, tag)
                        Path(name).rename(renamed)
                        self.assets[renamed] = self.assets.pop(name)
                current_tag = tag
                self.release = {"draft": True, "assets": {}}
                self.commands = []
                with self.assertRaisesRegex(ValueError, "malformed release tag"):
                    publisher.publish(tag)
                self.assertEqual(self.commands, [])
                self.assertEqual(self.release, {"draft": True, "assets": {}})

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
