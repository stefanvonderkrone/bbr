"""Run with zig build test-cli. No network access."""

from pathlib import Path
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
data_home = tempfile.TemporaryDirectory()
env = cli_env(XDG_DATA_HOME=data_home.name, BITBUCKET_USERNAME="user", BITBUCKET_TOKEN="token", BITBUCKET_WORKSPACE="workspace")
prefix = b"written before bbr\n"


def run_into_file(args, stdout_to_file, stderr_to_file):
    """Run bbr with stdout and stderr on one file whose offset is already past earlier output."""
    with tempfile.TemporaryFile() as output:
        output.write(prefix)
        output.flush()
        subprocess.run(
            [binary, *args],
            stdout=output if stdout_to_file else subprocess.DEVNULL,
            stderr=output if stderr_to_file else subprocess.DEVNULL,
            env=env,
            timeout=5,
        )
        output.seek(0)
        return output.read()


text = run_into_file(["api", "list-pull-requests", "--repository", "x", "--pagelen", "51"], False, True)
assert text.startswith(prefix), text
assert b"bbr api list-pull-requests: bad options (InvalidNumber)\n" in text, text
assert b"usage: bbr api list-pull-requests --repository SLUG" in text, text

text = run_into_file(["--version"], True, True)
assert text.startswith(prefix + b"bbr "), text

print("bbr appends stdout and stderr to a file at its current offset.")
