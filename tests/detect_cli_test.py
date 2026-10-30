"""Run with python3 tests/detect_cli_test.py zig-out/bin/bbr. No network access."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())


def detect(env, cwd, args):
    result = subprocess.run(
        [binary, "detect", *args], capture_output=True, env=env, cwd=cwd, timeout=10
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    return output


with tempfile.TemporaryDirectory(prefix="bbr-detect-test-") as root:
    work = Path(root) / "work"
    work.mkdir()
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("BITBUCKET_") or key.startswith("GIT_") or key == "BBR_PROFILE":
            del env[key]
    env["XDG_DATA_HOME"] = str(Path(root) / "data")
    env["XDG_STATE_HOME"] = str(Path(root) / "state")
    env["GIT_CEILING_DIRECTORIES"] = root
    env["BITBUCKET_USERNAME"] = "fake-user@example.com"
    env["BITBUCKET_TOKEN"] = "fake-token"
    env["BITBUCKET_WORKSPACE"] = "check24"
    # A request would fail at this proxy, so a plain Browser proves no network use.
    for key in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"):
        env[key] = "http://127.0.0.1:9"

    # Outside Git, Startup Detection gives the plain Browser.
    output = detect(env, work, [])
    assert b"branch: <NotAGitRepo>" in output, output
    assert b"remote: <" in output, output
    assert output.endswith(b"resolved: browser\n"), output
    assert b"reason:" not in output, output

    # A named Repository outside Git stays expanded.
    output = detect(env, work, ["pr-webapp"])
    assert output.endswith(b"resolved: browser pr-webapp expanded\n"), output

    # `bbr detect` never reads or writes the Summary Cache.
    assert not (Path(root) / "state").exists()
    assert b"fake-token" not in output
