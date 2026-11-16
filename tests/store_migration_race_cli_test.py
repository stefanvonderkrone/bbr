"""Run with zig build test-cli. No network access.

Several bbr processes that start at the same time on a new pending-review store
all open it, and the store reaches the schema version of one bbr alone (ticket 06).
"""

from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
processes = 4
rounds = 10


def version(database):
    with sqlite3.connect(database) as connection:
        return connection.execute("PRAGMA user_version").fetchone()[0]


with tempfile.TemporaryDirectory(prefix="bbr-store-race-cli-") as directory:
    root = Path(directory)
    home = root / "home"
    home.mkdir()
    env = cli_env(HOME=str(home), XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"))
    repository = root / "repository"
    repository.mkdir()
    git = ["git", "-c", "user.name=bbr", "-c", "user.email=bbr@example.invalid", "-c", "commit.gpgsign=false"]
    for command in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "base"]):
        subprocess.run([*git, *command], cwd=repository, env=env, check=True, capture_output=True)

    def start(state):
        return subprocess.Popen(
            [binary, "local", "main", "main"], env=dict(env, XDG_STATE_HOME=str(state)), cwd=repository,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )

    alone = start(root / "alone")
    alone.communicate(timeout=10)
    expected = version(root / "alone/bbr/pending.db")
    assert expected > 0, expected

    failures = []
    for index in range(rounds):
        state = root / f"state-{index}"
        started = [start(state) for _ in range(processes)]
        for process in started:
            _, stderr = process.communicate(timeout=10)
            if b"could not open" in stderr:
                failures.append((index, stderr.decode(errors="replace").strip()))
        reached = version(state / "bbr/pending.db")
        assert reached == expected, f"round {index} ended at version {reached}, not {expected}: {failures}"
    assert not failures, f"{len(failures)} of {rounds * processes} opens failed: {failures[0]}"

print(f"Store migration race CLI checks passed. {processes} bbr processes on each of {rounds} new stores all opened it.")
