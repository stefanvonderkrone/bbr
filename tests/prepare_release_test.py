"""Check automatic release preparation in isolated Git repositories."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/prepare_release.py"
EPOCH = "1711283696"


class PrepareReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bbr-release-prepare-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ | {
            "GIT_AUTHOR_NAME": "bbr",
            "GIT_AUTHOR_EMAIL": "bbr@example.invalid",
            "GIT_COMMITTER_NAME": "bbr",
            "GIT_COMMITTER_EMAIL": "bbr@example.invalid",
            "GIT_AUTHOR_DATE": f"@{EPOCH} +0000",
            "GIT_COMMITTER_DATE": f"@{EPOCH} +0000",
        }
        self.git("init", "-q", "-b", "main")
        self.package = self.root / "build.zig.zon"
        self.package.write_text('.{\n    .name = .bbr,\n    .version = "0.0.0",\n}\n')
        (self.root / "source.txt").write_text("source\n")
        self.git("add", "--all")
        self.git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "source")
        self.source = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.root, env=self.env, text=True,
            stderr=subprocess.PIPE,
        ).strip()

    def prepare(self):
        result = subprocess.run(
            ["python3", str(SCRIPT)], cwd=self.root, env=self.env,
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def reject(self):
        result = subprocess.run(
            ["python3", str(SCRIPT)], cwd=self.root, env=self.env,
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.source)
        return result.stderr

    def test_release_commit_preserves_source_and_date(self):
        output = self.prepare()
        self.assertEqual(output["tag"], "v2024.3.24-1")
        self.assertEqual(output["commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(self.git("rev-parse", "HEAD^"), self.source)
        self.assertEqual(self.git("rev-parse", "main"), self.source)
        self.assertEqual(self.git("show", "-s", "--format=%ct"), EPOCH)
        self.assertEqual(self.git("cat-file", "-t", output["tag"]), "tag")
        self.assertEqual(self.git("diff", "--name-only", self.source), "build.zig.zon")
        self.assertIn('.version = "2024.3.24-1"', self.package.read_text())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_next_merge_increments_sequence(self):
        first = self.prepare()
        self.git("checkout", "main")
        self.git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "next merge")
        source = self.git("rev-parse", "HEAD")
        second = self.prepare()
        self.assertEqual(second["tag"], "v2024.3.24-2")
        self.assertNotEqual(second["commit"], first["commit"])
        self.assertEqual(self.git("rev-parse", "HEAD^"), source)

    def test_retry_reuses_release_tag(self):
        first = self.prepare()
        self.git("checkout", "--detach", self.source)
        self.assertEqual(self.prepare(), first)
        self.assertEqual(self.git("tag", "--list"), first["tag"])

    def test_sequence_resets_on_next_commit_date(self):
        self.prepare()
        self.git("checkout", "main")
        self.env["GIT_AUTHOR_DATE"] = "@1711370096 +0000"
        self.env["GIT_COMMITTER_DATE"] = "@1711370096 +0000"
        self.git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "next day")
        self.assertEqual(self.prepare()["tag"], "v2024.3.25-1")

    def test_dirty_checkout_is_rejected(self):
        (self.root / "source.txt").write_text("changed\n")
        self.assertIn("checkout is dirty", self.reject())

    def test_malformed_history_is_rejected(self):
        self.git("tag", "v2024.3.24-01")
        self.assertIn("malformed release tag", self.reject())

    def test_skipped_history_is_rejected(self):
        self.git("tag", "v2024.3.24-2")
        self.assertIn("release sequence history", self.reject())

    def test_missing_package_version_is_rejected(self):
        self.package.write_text('.{ .name = .bbr }\n')
        self.git("add", "--", "build.zig.zon")
        self.git("-c", "commit.gpgsign=false", "commit", "-m", "invalid package")
        self.source = self.git("rev-parse", "HEAD")
        self.assertIn("expected one package version", self.reject())


if __name__ == "__main__":
    unittest.main()
