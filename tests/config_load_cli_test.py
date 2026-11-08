"""Run with zig build test-cli. No network access.

Each command that loads the TUI configuration in runMain shows the user the
configuration failure, and the diagnostic file holds exactly one record of it.
"""

from pathlib import Path
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
commands = (["demo"], ["local"], ["example-repository", "7"])


def logs(env):
    return set((Path(env["XDG_STATE_HOME"]) / "bbr/diagnostics").glob("*.log"))


def run(env, args, cwd):
    before = logs(env)
    result = subprocess.run([binary, *args], capture_output=True, env=env, cwd=cwd, timeout=10, stdin=subprocess.DEVNULL)
    created = logs(env) - before
    records = [line for path in created for line in path.read_text().splitlines()[1:]]
    return result, records


with tempfile.TemporaryDirectory(prefix="bbr-config-load-cli-") as directory:
    root = Path(directory)
    home = root / "home"
    home.mkdir()
    env = cli_env(
        HOME=str(home), XDG_CONFIG_HOME=str(root / "config"),
        XDG_STATE_HOME=str(root / "state"), XDG_DATA_HOME=str(root / "data"),
        BITBUCKET_USERNAME="config-load-user", BITBUCKET_TOKEN="config-load-token",
        BITBUCKET_WORKSPACE="config-load-workspace",
    )
    config = root / "config/bbr/config.toml"
    config.parent.mkdir(parents=True)

    config.write_text("theme = 99\n[logging]\nenabled = true\n")
    for args in commands:
        result, records = run(env, args, root)
        message = f"{config}:1:9: expected a quoted string value\n".encode()
        assert message in result.stderr, (args, result)
        assert len(records) == 1, (args, records)
        assert "operation=configuration " in records[0] and records[0].endswith(" error=ConfigInvalid"), (args, records)

    config.unlink()
    config.mkdir()
    for args in commands:
        result, records = run(env, args, root)
        message = f"bbr: could not read configuration {config}: ConfigNotRegularFile\n".encode()
        assert message in result.stderr, (args, result)
        assert records == [], (args, records)

print("Configuration load CLI checks passed. Each runMain command names the failure and records it once.")
