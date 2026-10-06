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


def run(env, args, data=b""):
    result = subprocess.run(
        [binary, *args], input=data, capture_output=True, env=env, timeout=5
    )
    assert result.returncode == 0, result.stderr
    return result.stdout + result.stderr


def check_terminal(env, token_lines, expected):
    master, slave = os.openpty()
    original = termios.tcgetattr(slave)
    original[3] |= termios.ECHO | termios.ECHONL
    termios.tcsetattr(slave, termios.TCSANOW, original)
    process = subprocess.Popen(
        [binary, "login"], stdin=slave, stdout=slave, stderr=slave, env=env
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
        assert process.wait(timeout=5) == 0
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

    invalid = dict(env, BBR_PROFILE="bad name")
    output = run(invalid, ["login"])
    assert b"could not select profile: InvalidProfileName" in output
    assert b"Email:" not in output
    for args in (["login", "work"], ["--profile", "work", "login"]):
        assert b"Email:" in run(invalid, args)

    for key in ("BITBUCKET_USERNAME", "BITBUCKET_TOKEN", "BITBUCKET_WORKSPACE"):
        env[key] = ""
    assert b"override the file" not in run(env, ["logout", "--all"])
    for key in ("BITBUCKET_USERNAME", "BITBUCKET_TOKEN", "BITBUCKET_WORKSPACE"):
        assert b"override the file" in run(dict(env, **{key: "fake"}), ["logout", "--all"])

    output = run(env, ["login"], b"fake-user@example.com\nfake-token\n")
    assert b"Email: Token: Workspace: " in output
    assert b"login aborted (LoginAborted)" in output
    check_terminal(env, [b"fake-token\n"], b"Workspace: ")
    check_terminal(env, [b"\x04"], b"login aborted (LoginAborted)")
    check_terminal(env, [b"\n", b"\n", b"\n"], b"login aborted (LoginAborted)")
    assert not (Path(data_home) / "bbr" / "auth.toml").exists()

print("Auth CLI checks passed. Profile selection, overrides, piped input, and terminal echo restoration.")
