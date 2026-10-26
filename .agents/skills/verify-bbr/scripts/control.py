#!/usr/bin/env python3
"""Drive a private bbr LocalReview through tmux. Use --help for commands."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[4]


def database_path(scratch):
    return Path(scratch) / "home/.local/state/bbr/pending.db"


COMMAND_TIMEOUT = 60


def run(*args, **kwargs):
    try:
        return subprocess.check_output(args, text=True, timeout=COMMAND_TIMEOUT, **kwargs)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{shlex.join(args)} did not finish within {COMMAND_TIMEOUT} seconds. Run cleanup.") from error


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def tmux(state, *args, **kwargs):
    return run("tmux", "-S", str(Path(state["scratch"]) / "tmux.sock"), *args, **kwargs)


def tmux_server_alive(pid):
    try:
        return "tmux" in run("ps", "-p", str(pid), "-o", "comm=")
    except subprocess.CalledProcessError:
        return False


def stop_server(state):
    """Stop the private tmux server. A server that is gone counts as stopped. Any other failure propagates."""
    socket = Path(state["scratch"]) / "tmux.sock"
    pid = state.get("server_pid")
    if not socket.exists():
        if pid is None or not tmux_server_alive(pid):
            return
        # tmux recreates a deleted socket on SIGUSR1.
        os.kill(pid, signal.SIGUSR1)
        deadline = time.monotonic() + 5
        while not socket.exists():
            if time.monotonic() > deadline:
                raise RuntimeError(f"tmux server {pid} lost its socket and did not recreate it")
            time.sleep(0.05)
    try:
        tmux(state, "kill-server", stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        if "no server running" not in (error.stderr or ""):
            raise


def capture(state):
    return tmux(state, "capture-pane", "-p", "-t", "verify:0.0")


def snapshot(evidence, state, label):
    if not label.replace("-", "").replace("_", "").isalnum():
        raise ValueError("Use letters, digits, hyphens, or underscores for labels")
    text = capture(state)
    (evidence / f"{label}.txt").write_text(text)
    (evidence / f"{label}.ansi").write_text(
        tmux(state, "capture-pane", "-p", "-e", "-t", "verify:0.0")
    )
    return text


def wait_for(state, text):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if text in capture(state):
            return
        time.sleep(0.1)
    raise RuntimeError(f"Screen did not show {text!r} within 15 seconds")


def launch(evidence, state):
    scratch = Path(state["scratch"])
    binary = scratch / "bbr"
    home = scratch / "home"
    command = shlex.join([
        "env", "-i", f"PATH={os.environ['PATH']}", f"HOME={home}",
        f"XDG_CONFIG_HOME={home / '.config'}", f"XDG_DATA_HOME={home / '.local/share'}",
        f"XDG_STATE_HOME={home / '.local/state'}", f"XDG_CACHE_HOME={home / '.cache'}", "TERM=tmux-256color", "LANG=en_US.UTF-8",
        str(binary), "local", "main", "review",
    ])
    state["command"] = command
    # Set remain-on-exit before the pane exists, so a bbr that exits at once keeps its output.
    tmux(state, "-f", "/dev/null", "start-server", ";", "set-option", "-g", "remain-on-exit", "on", ";",
         "new-session", "-d", "-s", "verify", "-x", "140", "-y", "44", "-c", str(scratch / "repo"), command)
    state["server_pid"] = int(tmux(state, "display-message", "-p", "#{pid}"))
    state["pane_pid"] = int(tmux(state, "display-message", "-p", "-t", "verify:0.0", "#{pane_pid}"))
    save(evidence / "instance.json", state)
    wait_for(state, "VERIFY_NEW")
    snapshot(evidence, state, "launch")


def cleanup(evidence, state):
    scratch = Path(state["scratch"])
    if not scratch.exists():
        return
    if (scratch / "owner").read_text() != str(evidence):
        raise RuntimeError("Scratch ownership does not match this evidence directory")
    try:
        if (scratch / "tmux.sock").exists():
            snapshot(evidence, state, "cleanup-screen")
    except (subprocess.CalledProcessError, RuntimeError) as error:
        (evidence / "cleanup-capture-error.txt").write_text(str(error) + "\n")
    finally:
        stop_server(state)
    database = database_path(scratch)
    if database.exists():
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as source:
            with sqlite3.connect(evidence / "pending.db") as target:
                source.backup(target)
    shutil.rmtree(scratch)
    save(evidence / "cleanup.json", {"scratch_removed": not scratch.exists(), "time": time.time()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["launch", "doctor", "keys", "text", "capture", "wait", "restart", "db", "cleanup"])
    parser.add_argument("values", nargs="*")
    args = parser.parse_args()
    if args.command == "launch":
        # A stale zig-out binary would pass a drive that the source fails.
        subprocess.run(["zig", "build"], cwd=ROOT, check=True, stdout=sys.stderr)
        evidence = ROOT / ".scratch/verify-bbr" / (time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6])
        evidence.mkdir(parents=True, mode=0o700)
        scratch = Path(tempfile.mkdtemp(prefix="bbr-"))
        state = {"scratch": str(scratch), "source_binary": str(ROOT / "zig-out/bin/bbr")}
        (scratch / "owner").write_text(str(evidence))
        save(evidence / "instance.json", state)
        try:
            shutil.copy2(state["source_binary"], scratch / "bbr")
            state["sha256"] = digest(scratch / "bbr")
            state["version"] = run(str(scratch / "bbr"), "--version").strip()
            repo = scratch / "repo"
            repo.mkdir()
            (scratch / "home").mkdir()
            git_env = {"PATH": os.environ["PATH"], "HOME": str(scratch / "home"), "GIT_CONFIG_NOSYSTEM": "1"}

            def git(*values):
                return run("git", "-c", "user.name=Verification", "-c", "user.email=verify@example.invalid",
                           "-c", "commit.gpgsign=false", *values, cwd=repo, env=git_env)

            git("init", "-b", "main")
            lines = [f"line {number:02d}\n" for number in range(1, 41)]
            lines[19] = "VERIFY_OLD\n"
            (repo / "sample.txt").write_text("".join(lines))
            git("add", ".")
            git("commit", "-m", "Seed base")
            git("checkout", "-b", "review")
            lines[19] = "VERIFY_NEW\n"
            (repo / "sample.txt").write_text("".join(lines))
            (repo / "notes.txt").write_text("VERIFY_NOTES\n")
            git("add", ".")
            git("commit", "-m", "Seed review")
            (evidence / "fixture.diff").write_text(git("diff", "main", "review"))
            launch(evidence, state)
        except BaseException:
            cleanup(evidence, state)
            raise
        print(evidence)
        return

    evidence = Path(os.environ["BBR_VERIFY_RUN"]).resolve()
    state = json.loads((evidence / "instance.json").read_text())
    with (evidence / "actions.jsonl").open("a") as log:
        log.write(json.dumps({"time": time.time(), "command": args.command, "values": args.values}) + "\n")
    scratch = Path(state["scratch"])
    if args.command == "cleanup":
        cleanup(evidence, state)
    elif args.command == "doctor":
        assert (scratch / "owner").read_text() == str(evidence)
        assert digest(scratch / "bbr") == state["sha256"] == digest(state["source_binary"])
        assert run(str(scratch / "bbr"), "--version").strip() == state["version"]
        info = tmux(state, "display-message", "-p", "-t", "verify:0.0", "#{pane_pid} #{pane_dead}").strip()
        assert info == f"{state['pane_pid']} 0", info
        process = run("ps", "-p", str(state["pane_pid"]), "-o", "command=")
        assert str(scratch / "bbr") in process and "local main review" in process, process
        database = database_path(scratch)
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
            assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        report = {"healthy": True, "version": state["version"], "pane": info, "database": str(database)}
        save(evidence / "doctor.json", report)
        print(json.dumps(report))
    elif args.command in ("keys", "text"):
        if args.command == "text":
            tmux(state, "send-keys", "-t", "verify:0.0", "-l", "--", " ".join(args.values))
        else:
            tmux(state, "send-keys", "-t", "verify:0.0", *args.values)
    elif args.command == "capture":
        print(snapshot(evidence, state, args.values[0]), end="")
    elif args.command == "wait":
        wait_for(state, " ".join(args.values))
    elif args.command == "restart":
        stop_server(state)
        launch(evidence, state)
    elif args.command == "db":
        database = database_path(scratch)
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
            rows = db.execute("SELECT local_id, body, scope_kind, state_kind FROM drafts ORDER BY local_id").fetchall()
        save(evidence / "drafts.json", rows)
        print(json.dumps(rows))


if __name__ == "__main__":
    main()
