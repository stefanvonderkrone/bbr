"""Run with zig build test-cli. No network access.

Several bbr processes that start at the same time on one pending-review store
all open it (ticket 06). The store reaches the schema version and the step names
of one bbr alone, also from the old M22 shape without `schema_steps` (ticket 08).
"""

from pathlib import Path
import shutil
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


def names(database):
    with sqlite3.connect(database) as connection:
        return [row[0] for row in connection.execute("SELECT name FROM schema_steps ORDER BY name")]


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
    reference = root / "alone/bbr/pending.db"
    expected = version(reference)
    expected_names = names(reference)
    assert expected > 0, expected
    assert expected_names, "bbr recorded no reference migration names"

    failures = []
    for shape in ("new", "old-m22"):
        for index in range(rounds):
            state = root / f"{shape}-{index}"
            database = state / "bbr/pending.db"
            if shape == "old-m22":
                database.parent.mkdir(parents=True)
                shutil.copyfile(reference, database)
                with sqlite3.connect(database) as connection:
                    connection.executescript("DROP TABLE schema_steps; DROP TABLE posted_drafts; PRAGMA user_version = 10;")
            started = [start(state) for _ in range(processes)]
            for process in started:
                _, stderr = process.communicate(timeout=10)
                if b"could not open" in stderr:
                    failures.append((shape, index, stderr.decode(errors="replace").strip()))
            reached = version(database)
            assert reached == expected, f"{shape} round {index} ended at version {reached}, not {expected}: {failures}"
            assert names(database) == expected_names, f"{shape} round {index} has wrong migration names"
    assert not failures, f"{len(failures)} of {2 * rounds * processes} opens failed: {failures[0]}"

print(f"Store migration race CLI checks passed. {processes} bbr processes opened each of {rounds} new and {rounds} old M22 stores.")
