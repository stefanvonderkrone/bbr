"""Run with zig build test-cli. No network access."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
sentinel = "diagnostic-private-sentinel-46c9"


def run(env, args, data=b"", **options):
    return subprocess.run(
        [binary, *args], input=data, capture_output=True, env=env,
        cwd=home, timeout=10, **options,
    )


def logs(env):
    return sorted((Path(env["XDG_STATE_HOME"]) / "bbr/diagnostics").glob("*.log"))


def capture(env, args, data=b""):
    before = set(logs(env))
    result = run(env, args, data)
    created = set(logs(env)) - before
    assert len(created) == 1, (args, created, result.stderr)
    path = created.pop()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    text = path.read_text()
    assert text.startswith("bbr-diagnostics-v1 run=")
    assert sentinel not in text, text
    if env.get("HOME"):
        assert env["HOME"] not in text, text
    records = text.splitlines()[1:]
    run_id = re.fullmatch(r"bbr-diagnostics-v1 run=([0-9a-f]{16})", text.splitlines()[0])[1]
    for sequence, record in enumerate(records, 1):
        assert re.match(r"v=1 time_ns=\d+ run=" + run_id + rf" seq={sequence} ", record), record
        assert re.search(r" source=[^ ]+\.zig:\d+:\d+ ", record), record
    return result, text


def check_failure(env, args, cause, operation, data=b""):
    result, text = capture(env, args, data)
    assert any(
        f"operation={operation} " in line and f"error={cause}" in line
        for line in text.splitlines()
    ), text
    return result


with tempfile.TemporaryDirectory(prefix="bbr-diagnostics-cli-") as directory:
    root = Path(directory)
    home = root / "home"
    home.mkdir()
    env = cli_env(
        HOME=str(home), XDG_CONFIG_HOME=str(root / "config"),
        XDG_STATE_HOME=str(root / "state"), XDG_DATA_HOME=str(root / "data"),
    )
    config = root / "config/bbr/config.toml"
    config.parent.mkdir(parents=True)
    legacy = home / "bbr-submit-response.log"
    legacy.write_text(sentinel)
    legacy.chmod(0)
    legacy_before = legacy.stat()

    invalid_input = ["auth", "login", "--stdin", "--email", sentinel, "--workspace", sentinel]
    baseline = run(env, invalid_input, (sentinel + "\nextra\n").encode())
    assert baseline.returncode == 1
    assert baseline.stderr == b"bbr: invalid token from --stdin; nothing saved\n"
    assert not logs(env)
    assert not (root / "state").exists()

    for setting in ("", "[logging]\nenabled = false\n"):
        config.write_text(setting)
        assert run(env, ["api", "whoami"]).returncode != 0
        assert run(env, ["completion", sentinel]).returncode != 0
        assert not (root / "state").exists()

    config.write_text("[logging]\nenabled = true\n")
    enabled = check_failure(env, invalid_input, "InvalidToken", "auth", (sentinel + "\nextra\n").encode())
    assert (enabled.returncode, enabled.stdout, enabled.stderr) == (
        baseline.returncode, baseline.stdout, baseline.stderr,
    )

    missing = check_failure(env, ["api", "whoami", "--json"], "MissingUsername", "api")
    assert missing.returncode != 0 and missing.stdout == b""
    assert b"bbr api whoami: MissingCredential\n" in missing.stderr
    missing = check_failure(env, ["auth", "status"], "MissingUsername", "auth")
    assert missing.returncode == 1 and missing.stdout == b""

    check_failure(env, ["--profile", sentinel + " bad", "--version"], "InvalidProfileName", "arguments")
    check_failure(env, ["completion", sentinel], "UnknownFlag", "completion")
    check_failure(env, ["grammar", sentinel], "InvalidGrammarCommand", "grammar")
    for args in (["--version"], ["api", "--help"], ["auth", "--help"], ["completion", "bash"], ["grammar", "list"]):
        result, _ = capture(env, args)
        assert result.returncode == 0, result.stderr

    auth_file = root / "data/bbr/auth.toml"
    auth_file.parent.mkdir(parents=True, exist_ok=True)
    auth_file.write_text(sentinel)
    auth_file.chmod(0o600)
    for args, operation in (
        (["api", "whoami"], "api"), (["auth", "status"], "auth"),
        (["auth", "logout"], "auth"), (["completion", "--list-profiles"], "completion"),
    ):
        result = check_failure(env, args, "InvalidAuthFile", operation)
        assert result.returncode != 0 and result.stdout == b""
    auth_file.unlink()
    auth_file.mkdir()
    result = check_failure(env, ["auth", "logout", "--all"], "UnsafeAuthTarget", "auth")
    assert result.returncode == 1
    auth_file.rmdir()

    no_data = dict(env)
    no_data.pop("HOME")
    no_data.pop("XDG_DATA_HOME")
    result = check_failure(no_data, ["auth", "login"], "NoDataHome", "auth")
    assert result.returncode == 1

    credentials = dict(env, BITBUCKET_USERNAME=sentinel, BITBUCKET_TOKEN=sentinel, BITBUCKET_WORKSPACE=sentinel)
    proxy_env = dict(credentials, https_proxy="socks5://" + sentinel + ".invalid")
    for args, operation in ((["api", "whoami"], "api"), (["auth", "status"], "auth")):
        result = check_failure(proxy_env, args, "InvalidProxyConfiguration", operation)
        assert result.returncode != 0
    result = check_failure(proxy_env, invalid_input, "InvalidProxyConfiguration", "auth", (sentinel + "\n").encode())
    assert result.returncode == 1

    config.write_text("theme = 99\n[logging]\nenabled = true\n")
    for args in (["api", "--help"], ["auth", "--help"]):
        result, _ = capture(env, args)
        assert result.returncode == 0
    check_failure(env, ["auth", "status"], "MissingUsername", "auth")
    result = check_failure(env, ["demo"], "ConfigInvalid", "configuration")
    assert result.returncode == 0 and b"expected a quoted string value" in result.stderr, result
    for invalid in (
        "[logging]\nenabled = 'true'\n", "[logging]\nenabled = trueish\n",
        "[logging]\nenabled = true\nenabled = false\n", "[logging]\nenabled = true\nextra = true\n",
        "[logging]\nenabled = true\n[logging]\nenabled = true\n",
    ):
        config.write_text(invalid)
        before = set(logs(env))
        assert run(env, ["api", "--help"]).returncode == 0
        assert run(env, ["auth", "--help"]).returncode == 0
        assert run(env, ["auth", "status"]).returncode == 1
        assert set(logs(env)) == before

    config.write_text("[logging]\nenabled = true\n#" + "x" * (64 * 1024))
    before = set(logs(env))
    assert run(env, ["api", "--help"]).returncode == 0
    assert run(env, ["auth", "--help"]).returncode == 0
    assert set(logs(env)) == before

    config.unlink()
    config.mkdir()
    before = set(logs(env))
    assert run(env, ["--version"]).returncode == 0
    assert run(env, ["api", "--help"]).returncode == 0
    assert set(logs(env)) == before
    config.rmdir()
    config.write_text("[logging]\nenabled = true\n")

    before = set(logs(env))
    with ThreadPoolExecutor(max_workers=10) as pool:
        results = list(pool.map(lambda _: run(env, ["auth", "status"]), range(10)))
    created = set(logs(env)) - before
    assert len(created) == 10
    assert all(result.returncode == 1 for result in results)
    identities = set()
    for path in created:
        lines = path.read_text().splitlines()
        identities.add(lines[0])
        assert len(lines) == 2, lines
        assert "seq=1 operation=auth " in lines[1], lines
        assert "error=MissingUsername" in lines[1], lines
    assert len(identities) == 10

    blocked = root / "blocked"
    blocked.write_text("not a directory")
    unavailable = dict(env, XDG_STATE_HOME=str(blocked))
    for args in (["--version"], ["api", "--help"]):
        assert run(unavailable, args).returncode == 0
    assert run(unavailable, ["auth", "status"]).returncode == 1
    assert blocked.read_text() == "not a directory"

    legacy_after = legacy.stat()
    assert (legacy_after.st_mode, legacy_after.st_ino, legacy_after.st_size, legacy_after.st_mtime_ns) == (
        legacy_before.st_mode, legacy_before.st_ino, legacy_before.st_size, legacy_before.st_mtime_ns,
    )
    legacy.chmod(0o600)
    assert legacy.read_text() == sentinel

print("Diagnostic CLI logging stays opt-in, private, safe, and independent of command output.")
