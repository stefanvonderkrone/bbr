"""Run with python3 tests/completion_cli_test.py zig-out/bin/bbr. No network access."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())


def clean_env(data_home):
    """Return an environment without Credential or proxy overrides, using the test data directory."""
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("BITBUCKET_") or key == "BBR_PROFILE" or key.lower().endswith("_proxy"):
            del env[key]
    env["XDG_DATA_HOME"] = data_home
    return env


with tempfile.TemporaryDirectory(prefix="bbr-completion-test-") as data_home:
    env = clean_env(data_home)

    for shell, marker, flags in (
        ("bash", b"complete -F _bbr", (b"--pull-request-id", b"--profile")),
        ("zsh", b"#compdef bbr", (b"--pull-request-id", b"--profile")),
        ("fish", b"complete -c bbr", (b"-l pull-request-id", b"-l profile")),
    ):
        result = subprocess.run([binary, "completion", shell], capture_output=True, env=env, timeout=5)
        assert result.returncode == 0, result
        assert result.stderr == b"", result.stderr
        assert len(result.stdout) > 0, result
        assert marker in result.stdout, result
        for flag in flags:
            assert flag in result.stdout, (shell, flag)
        for expected in (b"list-pull-requests", b"set-verdict", b"completion --list-profiles"):
            assert expected in result.stdout, (shell, expected)

    result = subprocess.run([binary, "completion", "--help"], capture_output=True, env=env, timeout=5)
    assert result.returncode == 0, result
    assert b"bash|zsh|fish" in result.stdout, result
    assert result.stderr == b"", result.stderr

    result = subprocess.run([binary, "completion", "--list-profiles"],
                            capture_output=True, env=env, timeout=5)
    assert result.returncode == 0, result
    assert result.stdout == b"", result.stdout

    auth_dir = Path(data_home) / "bbr"
    auth_dir.mkdir()
    (auth_dir / "auth.toml").write_text(
        'active_profile = "personal"\n'
        '[profiles.personal]\nusername = "u"\ntoken = "t"\nworkspace = "w"\n'
        '[profiles.work]\nusername = "wu"\ntoken = "wt"\nworkspace = "ww"\n'
    )
    result = subprocess.run([binary, "completion", "--list-profiles"],
                            capture_output=True, env=env, timeout=5)
    assert result.returncode == 0, result
    assert result.stdout == b"personal\nwork\n", result

    for args in (["completion", "bogus"], ["completion"], ["completion", "bash", "--list-profiles"]):
        result = subprocess.run([binary, *args], capture_output=True, env=env, timeout=5)
        assert result.returncode != 0, result
        assert result.stdout == b"", result.stdout
        assert b"bbr completion" in result.stderr, result.stderr

print("Completion CLI checks passed. Scripts, help, profiles, and errors.")
