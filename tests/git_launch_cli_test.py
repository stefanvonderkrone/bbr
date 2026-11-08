"""Run with zig build test-cli. No network access.

A missing git binary on `bbr local` shows the launch error, and the diagnostic
file holds one record of that error. A non-zero git exit still uses the
command failure name.
"""

from pathlib import Path
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())


def logs(env):
    return set((Path(env["XDG_STATE_HOME"]) / "bbr/diagnostics").glob("*.log"))


with tempfile.TemporaryDirectory(prefix="bbr-git-launch-cli-") as directory:
    root = Path(directory)
    home = root / "home"
    empty_path = root / "empty-path"
    home.mkdir()
    empty_path.mkdir()
    env = cli_env(
        HOME=str(home),
        PATH=str(empty_path),
        XDG_CONFIG_HOME=str(root / "config"),
        XDG_STATE_HOME=str(root / "state"),
        XDG_DATA_HOME=str(root / "data"),
    )
    config = root / "config/bbr/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("[logging]\nenabled = true\n")

    before = logs(env)
    result = subprocess.run(
        [binary, "local"],
        capture_output=True,
        env=env,
        cwd=root,
        timeout=10,
        stdin=subprocess.DEVNULL,
    )
    records = [line for path in logs(env) - before for line in path.read_text().splitlines()[1:]]
    assert result.stderr == b"bbr local: cannot determine SourceRef: FileNotFound\n", result.stderr
    assert b"NotAGitRepo" not in result.stderr, result.stderr
    assert len(records) == 1, records
    assert records[0].endswith("cause=zig error=FileNotFound"), records

print("A missing git binary shows FileNotFound once.")
