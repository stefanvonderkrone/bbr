"""Publish the archives and checksum file for a validated release tag."""

from datetime import date
from pathlib import Path
import json
import os
import re
import subprocess
import sys


TARGETS = ("macos-x86_64", "macos-aarch64", "linux-x86_64", "linux-aarch64")


def version_key(tag):
    """Return date and sequence fields for a canonical release tag, or None."""
    match = re.fullmatch(
        r"v([0-9]{4})\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])-([1-9][0-9]*)", tag
    )
    if match is None:
        return None
    try:
        key = tuple(int(part) for part in match.groups())
        date(*key[:3])
    except ValueError:
        return None
    return key


def publish(tag):
    """Resume a draft, replace its expected assets, and publish only after upload succeeds."""
    key = version_key(tag)
    if key is None:
        raise ValueError(f"malformed release tag: {tag}")
    archives = sorted(str(path) for path in Path.cwd().glob("*.tar.gz") if path.is_file())
    expected = {f"bbr-{tag}-{target}.tar.gz" for target in TARGETS}
    if {Path(archive).name for archive in archives} != expected or not Path("SHA256SUMS").is_file():
        raise ValueError("all four release archives and SHA256SUMS are required")
    owner, name = os.environ["GH_REPO"].split("/", 1)
    query = """query($owner: String!, $name: String!, $tag: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        release(tagName: $tag) {
          isDraft
          releaseAssets(first: 100, after: $endCursor) {
            nodes { name }
            pageInfo { hasNextPage endCursor }
          }
        }
        latestRelease { tagName }
      }
    }"""
    response = subprocess.run([
        "gh", "api", "graphql", "--paginate", "--slurp", "-f", f"query={query}",
        "-f", f"owner={owner}", "-f", f"name={name}", "-f", f"tag={tag}",
    ], check=True, text=True, capture_output=True)
    repositories = [page["data"]["repository"] for page in json.loads(response.stdout)]
    repository = repositories[0]
    release = repository["release"]
    if release is not None and not release["isDraft"]:
        raise ValueError(f"release {tag} is already published")
    if release is not None:
        remote_assets = {
            asset["name"]
            for page in repositories
            for asset in page["release"]["releaseAssets"]["nodes"]
        }
        unexpected = remote_assets - (expected | {"SHA256SUMS"})
        if unexpected:
            raise ValueError(f"release {tag} has unexpected assets: {', '.join(sorted(unexpected))}")
    latest = repository["latestRelease"]
    latest_key = version_key(latest["tagName"]) if latest is not None else None
    if latest is None:
        make_latest = True
    elif latest_key is None:
        make_latest = False
    else:
        make_latest = key >= latest_key
    if release is None:
        subprocess.run([
            "gh", "release", "create", tag, "--draft", "--verify-tag",
            "--generate-notes", "--title", f"bbr {tag}",
        ], check=True)
    subprocess.run([
        "gh", "release", "upload", tag, *archives, "SHA256SUMS", "--clobber",
    ], check=True)
    subprocess.run([
        "gh", "release", "edit", tag, "--draft=false", f"--latest={str(make_latest).lower()}",
    ], check=True)


if __name__ == "__main__":
    try:
        publish(sys.argv[1])
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"release publication: {error}")
