"""Publish the archives and checksum file for a validated release tag."""

from pathlib import Path
import json
import os
import subprocess
import sys


def version_key(tag):
    """Return numeric date and sequence fields for release ordering."""
    return tuple(int(part) for part in tag.removeprefix("v").replace("-", ".").split("."))


def publish(tag):
    """Resume a draft, replace its expected assets, and publish only after upload succeeds."""
    archives = sorted(str(path) for path in Path.cwd().glob(f"bbr-{tag}-*.tar.gz"))
    if not archives or not Path("SHA256SUMS").is_file():
        raise ValueError("release archives and SHA256SUMS are required")
    owner, name = os.environ["GH_REPO"].split("/", 1)
    query = """query($owner: String!, $name: String!, $tag: String!) {
      repository(owner: $owner, name: $name) {
        release(tagName: $tag) { isDraft }
        latestRelease { tagName }
      }
    }"""
    response = subprocess.run([
        "gh", "api", "graphql", "-f", f"query={query}",
        "-f", f"owner={owner}", "-f", f"name={name}", "-f", f"tag={tag}",
    ], check=True, text=True, capture_output=True)
    repository = json.loads(response.stdout)["data"]["repository"]
    release = repository["release"]
    if release is not None and not release["isDraft"]:
        raise ValueError(f"release {tag} is already published")
    latest = repository["latestRelease"]
    make_latest = latest is None or version_key(tag) >= version_key(latest["tagName"])
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
