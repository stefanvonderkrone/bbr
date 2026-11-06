"""Run with zig build test-cli. No network access."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
env = cli_env()
commands = (["--version"], ["completion", "zsh"], ["api", "list-workspaces", "--help"])


def run_with_stdout(args, open_stdout):
    """Run bbr with stdout on the descriptor that `open_stdout` returns, and close it after the run."""
    descriptor = open_stdout()
    try:
        return subprocess.run([binary, *args], stdout=descriptor, stderr=subprocess.PIPE, env=env, timeout=5)
    finally:
        os.close(descriptor)


def closed_pipe():
    """Return the write end of a pipe whose reader is already gone, as after `bbr ... | head`."""
    read_end, write_end = os.pipe()
    os.close(read_end)
    return write_end


def read_only_file():
    """Return a descriptor that refuses every write, so a write fails for a reason other than a closed pipe."""
    return os.open(read_only_path, os.O_RDONLY)


with tempfile.NamedTemporaryFile() as read_only:
    read_only_path = read_only.name
    for args in commands:
        normal = subprocess.run([binary, *args], capture_output=True, env=env, timeout=5)
        assert normal.returncode == 0 and normal.stdout and not normal.stderr, (args, normal)

        closed = run_with_stdout(args, closed_pipe)
        assert closed.returncode == 0, (args, closed.returncode, closed.stderr)
        assert closed.stderr == b"", (args, closed.stderr)

        refused = run_with_stdout(args, read_only_file)
        assert refused.returncode != 0, (args, refused.returncode)
        assert b"NotOpenForWriting" in refused.stderr, (args, refused.stderr)

# Login prompts on stdout. With the reader gone, nobody sees the prompt and no Credential is saved, so login must fail.
with tempfile.TemporaryDirectory(prefix="bbr-broken-pipe-") as data_home:
    terminal, terminal_peer = os.openpty()
    stdout = closed_pipe()
    try:
        login = subprocess.run(
            [binary, "auth", "login"], stdin=terminal_peer, stdout=stdout, stderr=subprocess.PIPE,
            env=cli_env(XDG_DATA_HOME=data_home), timeout=5,
        )
    finally:
        for descriptor in (terminal, terminal_peer, stdout):
            os.close(descriptor)
    assert login.returncode == 1, (login.returncode, login.stderr)
    assert login.stderr == b"bbr: login aborted (StdoutClosed)\n", login.stderr
    assert not os.listdir(data_home), os.listdir(data_home)

print("bbr ends quietly with exit 0 when the reader of stdout is gone, fails login without a prompt, and still fails on other write errors.")
