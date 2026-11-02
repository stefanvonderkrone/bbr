#!/usr/bin/env python3

import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / ".agents/skills/verify-bbr/scripts/control.py"


def main():
    evidence = Path(subprocess.check_output([str(CONTROL), "launch"], cwd=ROOT, text=True).strip())
    env = dict(os.environ, BBR_VERIFY_RUN=str(evidence))

    def control(*args):
        return subprocess.check_output([str(CONTROL), *args], cwd=ROOT, env=env, text=True)

    state = json.loads((evidence / "instance.json").read_text())
    repo = Path(state["scratch"]) / "repo"

    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo, text=True)

    def commit():
        git("add", "notes.txt", "sample.txt")
        git("commit", "-qm", "Change reload fixture")

    def position(screen):
        return tuple(map(int, re.search(r"Local review.*?([0-9]+)/([0-9]+)", screen).groups()))

    try:
        control("doctor")
        control("keys", "]", "j", "j")
        before = control("capture", "reload-source-before")
        assert "sample.txt · Changes" in before, before
        old_cursor, old_total = position(before)
        (repo / "notes.txt").write_text("VERIFY_NOTES\nVERIFY_RELOAD\n")
        commit()
        control("keys", "R")
        control("wait", "VERIFY_RELOAD")
        after = control("capture", "reload-source-after")
        assert "sample.txt · Changes" in after, after
        assert position(after) == (old_cursor + 1, old_total + 1), after
        print("PASS reload retains the source Line after another File changes", flush=True)

        original = git("show", "main:sample.txt")
        (repo / "sample.txt").write_text(original)
        (repo / "notes.txt").write_text("VERIFY_NOTES\nVERIFY_FILE_REMOVED\n")
        commit()
        control("keys", "R")
        control("wait", "VERIFY_FILE_REMOVED")
        missing_file = control("capture", "reload-missing-file")
        assert "notes.txt · Changes" in missing_file, missing_file
        assert "sample.txt" not in missing_file, missing_file
        assert position(missing_file)[0] == 1, missing_file
        print("PASS a missing File keeps the existing reset behavior", flush=True)
        print(f"Evidence {evidence}", flush=True)
    finally:
        control("cleanup")


if __name__ == "__main__":
    main()
