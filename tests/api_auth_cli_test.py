"""Run with python3 tests/api_auth_cli_test.py zig-out/bin/bbr. No network access."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())


def run(env, args, expected):
    """Check that the command fails with the expected error and hides Credential values."""
    result = subprocess.run([binary, *args], capture_output=True, env=env, timeout=5)
    assert result.returncode != 0, result
    assert result.stdout == b"", result.stdout
    assert expected in result.stderr, result.stderr
    for value in (b"private-user", b"private-token", b"private-workspace"):
        assert value not in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="bbr-api-auth-test-") as data_home:
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("BITBUCKET_") or key == "BBR_PROFILE" or key.lower().endswith("_proxy"):
            del env[key]
    env["XDG_DATA_HOME"] = data_home
    # A rejected proxy proves that credentials resolved without sending a request.
    env["https_proxy"] = "socks5://unused.invalid"
    resolved = b"bbr api whoami: InvalidProxyConfiguration"
    missing = b"bbr api whoami: MissingCredential"
    run(env, ["api", "whoami", "--json"], missing)

    auth_dir = Path(data_home) / "bbr"
    auth_dir.mkdir()
    auth_file = auth_dir / "auth.toml"
    auth_file.write_text(
        'active_profile = "personal"\n'
        '[profiles.personal]\nusername = "private-user"\ntoken = "private-token"\nworkspace = "private-workspace"\n'
        '[profiles.work]\nusername = "work-user"\ntoken = "work-token"\n'
        '[profiles.partial]\nusername = "partial-user"\n'
    )
    run(env, ["api", "whoami", "--json"], resolved)
    work = dict(env, BBR_PROFILE="work")
    run(work, ["api", "whoami", "--json"], missing)
    for args in (
        ["--profile", "personal", "api", "whoami", "--json"],
        ["api", "--profile", "personal", "whoami", "--json"],
        ["api", "whoami", "--json", "--profile=personal"],
        ["--profile=work", "api", "whoami", "--profile", "personal", "--json"],
    ):
        run(work, args, resolved)
    for args in (
        ["api", "--workspace", "flag-workspace", "whoami", "--json"],
        ["api", "whoami", "--json", "--workspace=flag-workspace"],
    ):
        run(work, args, resolved)
    run(dict(work, BITBUCKET_WORKSPACE="env-workspace"), ["api", "whoami"], resolved)
    run(dict(env, BITBUCKET_TOKEN="", BITBUCKET_WORKSPACE=""), ["api", "whoami"], resolved)
    run(dict(env, BBR_PROFILE="partial", BITBUCKET_TOKEN="env-token", BITBUCKET_WORKSPACE="env-workspace"),
        ["api", "whoami"], resolved)

    for args in (["api", "whoami", "--profile"], ["api", "whoami", "--profile="]):
        run(env, args, b"bad options (MissingValue)")
    run(env, ["api", "whoami", "--profile", "bad name"], b"bad options (InvalidProfileName)")
    direct = dict(env)
    del direct["https_proxy"]
    run(direct, ["api", "create-comment", "--body", "--profile", "--repository", "sample"],
        b"bbr api create-comment: bad options (MissingRequired)")
    run(direct, ["api", "create-comment", "--body", "--profile=work", "--repository", "sample"],
        b"bbr api create-comment: bad options (MissingRequired)")

    auth_file.write_text('[profiles.personal]\ntoken = "private-token"oops"\n')
    run(env, ["api", "whoami", "--json"], b"InvalidAuthFile")
    result = subprocess.run([binary, "api", "whoami", "--help"], capture_output=True, env=env, timeout=5)
    assert result.returncode == 0, result.stderr
    assert b"--profile NAME" in result.stdout
    assert result.stderr == b"", result.stderr

print("API auth CLI checks passed. Saved Profiles, overrides, flag values, errors, and help.")
