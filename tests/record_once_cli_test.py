"""Run with zig build test-cli. No network access.

Each CLI failure shows the user a message that names it, and the diagnostic file
holds exactly one record of it (docs/adr/0014).
"""

from pathlib import Path
import socket
import subprocess
import sys
import tempfile

from cli_env import cli_env


binary = str(Path(sys.argv[1]).resolve())
credentials = {"BITBUCKET_USERNAME": "record-once-user", "BITBUCKET_TOKEN": "record-once-token", "BITBUCKET_WORKSPACE": "record-once-workspace"}

# (arguments, extra environment, stderr text, operation, cause) of the one record.
# A failure whose leaf has more evidence names it in `evidence`, a part of the record.
cases = (
    (["api", "whoami", "--json"], {}, b"bbr api whoami: MissingCredential (MissingUsername)\nRun `bbr auth login`", "api", "MissingUsername"),
    (["api", "frobnicate"], {}, b"bbr api: bad options (UnknownFlag)\n", "api", "UnknownFlag"),
    (["completion", "record-once-shell"], {}, b"bbr completion: unknown shell (bash|zsh|fish)\n", "completion", "UnknownFlag"),
    (["grammar", "record-once-command"], {}, b"bbr grammar: InvalidGrammarCommand\n", "grammar", "InvalidGrammarCommand"),
    (["grammar", "check", "/record-once-missing-bundle"], {}, b"bbr grammar: FileNotFound\n", "grammar", "FileNotFound"),
    (["grammar", "check", "record-once-bad.tar.gz"], {}, b"bbr grammar: InvalidArchive (BadGzipHeader)\n", "grammar", "BadGzipHeader"),
    (["auth", "status"], {}, b"bbr: no credential for profile; run `bbr auth login` (MissingUsername)\n", "auth", "MissingUsername"),
    (["api", "whoami"], dict(credentials, https_proxy="socks5://record-once.invalid"), b"bbr api whoami: InvalidProxyConfiguration\n", "api", "InvalidProxyConfiguration"),
    (["auth", "status"], dict(credentials, https_proxy="socks5://record-once.invalid"), b"bbr: status failed: transport (InvalidProxyConfiguration)\n", "auth", "InvalidProxyConfiguration"),
)
# A proxy on a closed local port refuses the connection, so the transport fails without network access.
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    refused_proxy = dict(credentials, https_proxy=f"http://127.0.0.1:{probe.getsockname()[1]}")
cases += (
    (["api", "whoami"], refused_proxy, b"bbr api whoami: ConnectionRefused\n", "api", "ConnectionRefused"),
    (
        ["api", "set-verdict", "--repository=record-once", "--pull-request-id=1", "--verdict=approved", "--expected-source-commit=abc123"],
        refused_proxy, b"bbr api set-verdict: ConnectionRefused\n", "api", "ConnectionRefused",
    ),
    (["auth", "status"], refused_proxy, b"bbr: status failed: transport (ConnectionRefused)\n", "auth", "ConnectionRefused"),
)
# These run with an invalid auth file in the data home.
invalid_auth_cases = (
    (["completion", "--list-profiles"], {}, b"bbr completion: InvalidAuthFile\n", "completion", "InvalidAuthFile"),
    (["api", "whoami"], {}, b"bbr api whoami: InvalidAuthFile\n", "api", "InvalidAuthFile"),
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
    (root / "record-once-bad.tar.gz").write_bytes(b"\x1f\x8b\x09\x00\x00\x00\x00\x00\x00\x03not-gzip-content")
    def check(args, extra, message, operation, cause, cwd=root, status=1, evidence=""):
        before = logs(env)
        result = subprocess.run(
            [binary, *args], capture_output=True, env=dict(env, **extra), cwd=cwd, timeout=10, stdin=subprocess.DEVNULL,
        )
        records = [line for path in logs(env) - before for line in path.read_text().splitlines()[1:]]
        assert result.returncode == status, (args, result)
        assert message in result.stderr, (args, result.stderr)
        assert b"error: Reported" not in result.stderr, (args, result.stderr)
        assert len(records) == 1, (args, records)
        assert f" operation={operation} " in records[0] and records[0].endswith(f" error={cause}"), (args, records)
        assert evidence in records[0], (args, evidence, records)

    for case in cases:
        check(*case)
    # The transport phase reaches the one record of a refused connection.
    for args in (["api", "whoami"], ["auth", "status"]):
        check(args, refused_proxy, b"ConnectionRefused", "api" if args[0] == "api" else "auth", "ConnectionRefused", evidence=" phase=connect ")
    # These Git failures print their message and end with status 0, as before.
    repository = root / "repository"
    repository.mkdir()
    git = ["git", "-c", "user.name=bbr", "-c", "user.email=bbr@example.invalid", "-c", "commit.gpgsign=false"]
    for command in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "base"]):
        subprocess.run([*git, *command], cwd=repository, env=env, check=True, capture_output=True)
    check(["local", "main", "record-once-missing-source"], {}, b"bbr local: cannot resolve SourceRef 'record-once-missing-source': UnknownRef\n", "session_load", "UnknownRef", cwd=repository, status=0)
    check([], credentials, b"bbr: could not resolve a PR to open: NoRemote\n", "startup", "NoRemote", cwd=repository, status=0)
    # The detect probe lines show a Git error without a record. Startup resolution meets the
    # same error again and fails the command, which records it once.
    check(["detect"], credentials, b"branch: main\nremote: <NoRemote>\nerror: NoRemote\n", "startup", "NoRemote", cwd=repository)
    check(["detect"], credentials, b"branch: <NotAGitRepo>\nremote: <NoRemote>\nerror: NoRemote\n", "startup", "NoRemote")
    check(["detect", "record-once"], credentials, b"branch: <NotAGitRepo>\nremote: <NoRemote>\nerror: NotAGitRepo\n", "startup", "NotAGitRepo")
    auth_file = root / "data/bbr/auth.toml"
    auth_file.parent.mkdir(parents=True, exist_ok=True)
    auth_file.write_text("record-once-invalid")
    auth_file.chmod(0o600)
    for case in invalid_auth_cases:
        check(*case)

print("Record-once CLI checks passed. Each failure prints its message and has one diagnostic record.")
