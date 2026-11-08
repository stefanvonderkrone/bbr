"""Run with zig build test-cli. No network access.

Each CLI failure shows the user a message that names it, and the diagnostic file
holds exactly one record of it (docs/adr/0014).
"""

from pathlib import Path
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
credentials = {"BITBUCKET_USERNAME": "record-once-user", "BITBUCKET_TOKEN": "record-once-token", "BITBUCKET_WORKSPACE": "record-once-workspace"}

# (arguments, extra environment, stderr text, operation, cause) of the one record.
cases = (
    (["api", "whoami", "--json"], {}, b"bbr api whoami: MissingCredential (MissingUsername)\nRun `bbr auth login`", "api", "MissingUsername"),
    (["api", "frobnicate"], {}, b"bbr api: bad options (UnknownFlag)\n", "api", "UnknownFlag"),
)


def logs(env):
    return set((Path(env["XDG_STATE_HOME"]) / "bbr/diagnostics").glob("*.log"))


with tempfile.TemporaryDirectory(prefix="bbr-record-once-cli-") as directory:
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
    for args, extra, message, operation, cause in cases:
        before = logs(env)
        result = subprocess.run(
            [binary, *args], capture_output=True, env=dict(env, **extra), cwd=root, timeout=10, stdin=subprocess.DEVNULL,
        )
        records = [line for path in logs(env) - before for line in path.read_text().splitlines()[1:]]
        assert result.returncode == 1, (args, result)
        assert message in result.stderr, (args, result.stderr)
        assert b"error: Reported" not in result.stderr, (args, result.stderr)
        assert len(records) == 1, (args, records)
        assert f" operation={operation} " in records[0] and records[0].endswith(f" error={cause}"), (args, records)

print("Record-once CLI checks passed. Each failure prints its message and has one diagnostic record.")
