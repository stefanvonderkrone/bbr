"""Run with zig build test-cli. No network access."""

from pathlib import Path
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())


with tempfile.TemporaryDirectory(prefix="bbr-completion-test-") as data_home:
    env = cli_env(XDG_DATA_HOME=data_home)

    for shell, marker, flags in (
        ("bash", b"complete -F _bbr", (b"--pull-request-id", b"--profile", b"--concurrency")),
        ("zsh", b"#compdef bbr", (b"--pull-request-id", b"--profile", b"--concurrency")),
        ("fish", b"complete -c bbr", (b"-l pull-request-id", b"-l profile", b"-l concurrency")),
    ):
        result = subprocess.run([binary, "completion", shell], capture_output=True, env=env, timeout=5)
        assert result.returncode == 0, result
        assert result.stderr == b"", result.stderr
        assert len(result.stdout) > 0, result
        assert marker in result.stdout, result
        for flag in flags:
            assert flag in result.stdout, (shell, flag)
        for expected in (
            b"list-pull-requests", b"set-verdict", b"completion --list-profiles",
            b"create-branch", b"list-branches", b"get-branch",
            b"create-pull-request", b"update-pull-request", b"decline-pull-request",
            b"list-commit-pull-requests",
            b"list-workspace-members", b"search-workspace-members",
            b"auth", b"login status logout",
        ):
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
