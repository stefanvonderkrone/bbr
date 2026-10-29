"""Prepare a tagged version commit without changing the source branch."""

from datetime import datetime, timezone
import os
from pathlib import Path
import re
import subprocess


def git(*args, env=None):
    return subprocess.check_output(["git", *args], text=True, env=env).strip()


def prepare():
    """Create or reuse the release tag for the current source commit."""
    if git("status", "--porcelain=v1", "--untracked-files=all", "--ignored=no"):
        raise ValueError("checkout is dirty")

    source = git("rev-parse", "HEAD")
    epoch = git("show", "-s", "--format=%ct", source)
    date = datetime.fromtimestamp(int(epoch), timezone.utc)
    date_text = f"{date.year}.{date.month}.{date.day}"
    tags = git("tag", "--list", f"v{date_text}-*").splitlines()
    sequences = []
    for tag in tags:
        match = re.fullmatch(rf"v{re.escape(date_text)}-([1-9][0-9]*)", tag)
        if not match:
            raise ValueError(f"malformed release tag: {tag}")
        sequences.append(int(match[1]))
        commit = git("rev-parse", f"{tag}^{{commit}}")
        message = git("show", "-s", "--format=%B", commit)
        if (git("cat-file", "-t", f"refs/tags/{tag}") == "tag"
                and git("show", "-s", "--format=%P", commit) == source
                and message == f"Release {tag}\n\nSource-commit: {source}"):
            git("checkout", "--detach", "--quiet", commit)
            return tag, commit

    if sorted(sequences) != list(range(1, len(sequences) + 1)):
        raise ValueError("release sequence history has a reuse or skip")
    version = f"{date_text}-{len(sequences) + 1}"
    tag = f"v{version}"
    package = Path("build.zig.zon")
    content, count = re.subn(
        r'(?m)^(\s*\.version\s*=\s*")[^"]*(",)',
        lambda match: f"{match[1]}{version}{match[2]}",
        package.read_text(),
    )
    if count != 1:
        raise ValueError("expected one package version in build.zig.zon")

    env = os.environ | {
        "GIT_AUTHOR_NAME": "github-actions[bot]",
        "GIT_AUTHOR_EMAIL": "41898282+github-actions[bot]@users.noreply.github.com",
        "GIT_COMMITTER_NAME": "github-actions[bot]",
        "GIT_COMMITTER_EMAIL": "41898282+github-actions[bot]@users.noreply.github.com",
        "GIT_AUTHOR_DATE": f"@{epoch} +0000",
        "GIT_COMMITTER_DATE": f"@{epoch} +0000",
    }
    git("checkout", "--detach", "--quiet", source)
    package.write_text(content)
    git("add", "--", str(package))
    git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m",
        f"Release {tag}\n\nSource-commit: {source}", env=env)
    git("-c", "tag.gpgsign=false", "tag", "-a", tag, "-m", f"Release {tag}", env=env)
    return tag, git("rev-parse", "HEAD")


if __name__ == "__main__":
    try:
        tag, commit = prepare()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"release preparation: {error}")
    print(f"tag={tag}\ncommit={commit}")
