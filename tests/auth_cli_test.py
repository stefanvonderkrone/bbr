"""Run with python3 tests/auth_cli_test.py zig-out/bin/bbr. No network access."""

import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import termios
import time


binary = str(Path(sys.argv[1]).resolve())


def run_ok(env, args, data=b""):
    result = subprocess.run(
        [binary, *args], input=data, capture_output=True, env=env, timeout=5
    )
    assert result.returncode == 0, result.stderr
    return result.stdout + result.stderr


def run_fail(env, args, expected, data=b""):
    result = subprocess.run(
        [binary, *args], input=data, capture_output=True, env=env, timeout=5
    )
    assert result.returncode != 0, result
    output = result.stdout + result.stderr
    assert expected in output, output
    return output


def check_terminal(env, token_lines, expected):
    master, slave = os.openpty()
    original = termios.tcgetattr(slave)
    original[3] |= termios.ECHO | termios.ECHONL
    termios.tcsetattr(slave, termios.TCSANOW, original)
    process = subprocess.Popen(
        [binary, "auth", "login"], stdin=slave, stdout=slave, stderr=slave, env=env
    )
    transcript = bytearray()

    def until(text):
        deadline = time.monotonic() + 5
        while text not in transcript:
            remaining = deadline - time.monotonic()
            assert remaining > 0, bytes(transcript)
            ready, _, _ = select.select([master], [], [], remaining)
            assert ready, bytes(transcript)
            transcript.extend(os.read(master, 4096))

    try:
        until(b"Email: ")
        os.write(master, b"fake-user@example.com\n")
        until(b"Token: ")
        for index, line in enumerate(token_lines):
            assert termios.tcgetattr(slave)[3] & (termios.ECHO | termios.ECHONL) == 0
            os.write(master, line)
            if index + 1 < len(token_lines):
                until(b"Token: \r\n" * (index + 1) + b"Token: ")
        until(expected)
        assert termios.tcgetattr(slave) == original
        assert b"fake-token" not in transcript
        if expected == b"Workspace: ":
            assert b"Token: \r\nWorkspace: " in transcript
            os.write(master, b"\x04")
            until(b"login aborted (LoginAborted)")
        assert process.wait(timeout=5) == 1
        assert termios.tcgetattr(slave) == original
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        os.close(master)
        os.close(slave)


with tempfile.TemporaryDirectory(prefix="bbr-auth-test-") as data_home:
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("BITBUCKET_") or key == "BBR_PROFILE":
            del env[key]
    env["XDG_DATA_HOME"] = data_home

    # Global Profile errors must fail before an auth command can report success.
    for command in ("login", "status", "logout"):
        for flags, expected in (
            (["--profile", "bad name"], b"invalid profile name"),
            (["--profile=bad name"], b"invalid profile name"),
            (["--profile"], b"--profile needs a value"),
            (["--profile="], b"--profile needs a value"),
        ):
            run_fail(env, ["auth", command, *flags], expected)

    # Logout with no storage succeeds and does not create the auth directory.
    no_home = dict(env)
    no_home.pop("HOME", None)
    no_home.pop("XDG_DATA_HOME", None)
    for logout_env in (no_home, env):
        for args in (["auth", "logout"], ["auth", "logout", "--all"]):
            assert b"Already logged out" in run_ok(logout_env, args)
            assert not (Path(data_home) / "bbr").exists()

    invalid = dict(env, BBR_PROFILE="bad name")
    run_fail(invalid, ["auth", "login"], b"could not select profile: InvalidProfileName")
    for args in (["auth", "login", "work"], ["--profile", "work", "auth", "login"]):
        # An explicit profile overrides the invalid BBR_PROFILE: arg parsing
        # passes and the command reaches piped-input refusal, not profile selection.
        output = run_fail(invalid, args, b"piped input needs --stdin", data=b"\x04")
        assert b"InvalidProfileName" not in output

    for key in ("BITBUCKET_USERNAME", "BITBUCKET_TOKEN", "BITBUCKET_WORKSPACE"):
        env[key] = ""
    assert b"override the file" not in run_ok(env, ["auth", "logout", "--all"])
    for key in ("BITBUCKET_USERNAME", "BITBUCKET_TOKEN", "BITBUCKET_WORKSPACE"):
        assert b"override the file" in run_ok(dict(env, **{key: "fake"}), ["auth", "logout", "--all"])

    # Piped input without --stdin is refused before the first prompt.
    output = run_fail(env, ["auth", "login"], b"piped input needs --stdin", data=b"fake-user@example.com\nfake-token\n")
    assert b"Email:" not in output

    # Unknown options are rejected with a hint that the token never rides as argv.
    output = run_fail(env, ["auth", "login", "--token", "x"], b"token never rides as a CLI argument")
    assert b"fake-token" not in output and b"Email:" not in output

    # --stdin is strict: it needs email+workspace and a clean single token line.
    # Failures name the bad field and never echo the token value.
    run_fail(env, ["auth", "login", "--stdin"], b"missing email", data=b"tok\n")
    run_fail(env, ["auth", "login", "--stdin", "--email", "a@b.c"], b"missing workspace", data=b"tok\n")
    for bad in (b"\n", b"   \t \n", b"fake-token\nunexpected\n", b"fake-token\n\nunexpected", b"fake-token\n" + b"x" * 5000):
        output = run_fail(env, ["auth", "login", "--stdin", "--email", "a@b.c", "--workspace", "w"], b"invalid token", data=bad)
        assert b"fake-token" not in output and b"unexpected" not in output
    # An over-length token is rejected before any network use and never echoed.
    long_secret = b"s3cr3t-" + b"x" * 2000 + b"\n"
    output = run_fail(env, ["auth", "login", "--stdin", "--email", "a@b.c", "--workspace", "w"], b"invalid token", data=long_secret)
    assert b"s3cr3t-" not in output

    # Top-level aliases hint at the auth group.
    run_fail(env, ["login"], b"use `bbr auth login`")
    run_fail(env, ["logout"], b"use `bbr auth logout`")

    # Missing credentials hint at login; status never prints a token.
    output = run_fail(env, ["auth", "status"], b"bbr auth login")
    assert b"fake" not in output
    output = run_fail(env, ["auth", "status", "work"], b"bbr auth login")

    check_terminal(env, [b"fake-token\n"], b"Workspace: ")
    check_terminal(env, [b"\x04"], b"login aborted (LoginAborted)")
    check_terminal(env, [b"\n", b"\n", b"\n"], b"login aborted (LoginAborted)")
    assert not (Path(data_home) / "bbr" / "auth.toml").exists()

    # Logout is idempotent and documents its limits.
    output = run_ok(env, ["auth", "logout", "--all"])
    assert b"does not revoke" in output

    # Local review never reports a credential error, even with broken storage.
    auth_dir = Path(data_home) / "bbr"
    auth_dir.mkdir(exist_ok=True)
    (auth_dir / "auth.toml").write_text("not = [valid\n")
    result = subprocess.run([binary, "local", "bad-base", "bad-source"], capture_output=True, env=env, timeout=5)
    combined = result.stdout + result.stderr
    assert b"credential" not in combined.lower(), combined
    assert b"cannot resolve SourceRef" in combined, combined

print("Auth CLI checks passed. Profile selection, overrides, piped refusal, strict --stdin, and terminal echo restoration.")
