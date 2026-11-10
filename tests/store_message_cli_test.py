"""Run with zig build test-cli. No network access.

A pending-review store failure on the bbr local path shows the user its message,
and the diagnostic file holds exactly one persistence record of it (docs/adr/0014).
The messages are pinned, so a change to their text fails here.
"""

from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())


def logs(env):
    return set((Path(env["XDG_STATE_HOME"]) / "bbr/diagnostics").glob("*.log"))


def run(env, cwd):
    before = logs(env)
    result = subprocess.run(
        [binary, "local", "main", "main"], capture_output=True, env=env, cwd=cwd, timeout=10, stdin=subprocess.DEVNULL,
    )
    records = [line for path in logs(env) - before for line in path.read_text().splitlines()[1:]]
    return result, [record for record in records if " operation=persistence " in record]


with tempfile.TemporaryDirectory(prefix="bbr-store-message-cli-") as directory:
    root = Path(directory)
    home = root / "home"
    home.mkdir()
    env = cli_env(
        HOME=str(home), XDG_CONFIG_HOME=str(root / "config"),
        XDG_STATE_HOME=str(root / "state"), XDG_DATA_HOME=str(root / "data"),
    )
    config = root / "config/bbr/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("[logging]\nenabled = true\n")
    repository = root / "repository"
    repository.mkdir()
    git = ["git", "-c", "user.name=bbr", "-c", "user.email=bbr@example.invalid", "-c", "commit.gpgsign=false"]
    for command in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "base"]):
        subprocess.run([*git, *command], cwd=repository, env=env, check=True, capture_output=True)
    database = root / "state/bbr/pending.db"
    database.parent.mkdir(parents=True)

    # SQLite cannot open a directory. bbr falls back to an in-memory store and then
    # fails later, without a terminal, so only the store message and record are checked.
    database.mkdir()
    result, records = run(env, repository)
    expected = f"bbr: could not open {database}; drafts won't persist this session\n".encode()
    assert expected in result.stderr, result.stderr
    assert b"Reported" not in result.stderr, result.stderr
    assert len(records) == 1, records
    assert " phase=open " in records[0] and records[0].endswith(" cause=sqlite result=14 extended=14"), records
    database.rmdir()

    # A store at the current schema version without its tables opens, but the
    # repository identity lookup cannot prepare its query.
    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA user_version = 10")
    result, records = run(env, repository)
    assert result.returncode == 0, result
    assert result.stderr == b"bbr local: cannot resolve repository identity\n", result.stderr
    assert len(records) == 1, records
    assert " phase=prepare " in records[0] and records[0].endswith(" cause=sqlite result=1 extended=1"), records

print("Store message CLI checks passed. Each store failure on bbr local prints its message and has one record.")
