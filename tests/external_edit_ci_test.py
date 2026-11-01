#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess


ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / ".agents/skills/verify-bbr/scripts/control.py"


def main():
    evidence = Path(subprocess.check_output([str(CONTROL), "launch"], cwd=ROOT, text=True).strip())
    env = dict(os.environ, BBR_VERIFY_RUN=str(evidence))

    def control(*args):
        return subprocess.check_output([str(CONTROL), *args], cwd=ROOT, env=env, text=True)

    spec = importlib.util.spec_from_file_location("verify_bbr_control", CONTROL)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    state = json.loads((evidence / "instance.json").read_text())
    failures = []

    def edit(body):
        control("keys", "C-e")
        control("wait", "body.md")
        control("keys", "Escape")
        control("text", "gg0C" + body)
        control("keys", "Escape")
        control("text", ":wq")
        control("keys", "Enter")
        try:
            control("wait", "External Edit accepted")
        except subprocess.CalledProcessError:
            control("capture", "external-edit-no-input-red-" + body.lower())
            failures.append("FAIL External Edit redraws after Neovim exits without more input")
            control("keys", "Right")
            control("wait", "External Edit accepted")
        screen = control("capture", "external-edit-return-" + body.lower())
        assert body in screen, screen

    try:
        control("doctor")
        editor = "nvim -u NONE -i NONE -n"
        command = state["command"].replace("env -i ", "env -i " + shlex.quote("GIT_EDITOR=" + editor) + " ", 1)
        helper.tmux(state, "respawn-pane", "-k", "-t", "verify:0.0", "-c", str(Path(state["scratch"]) / "repo"), command)
        state["command"] = command
        state["pane_pid"] = int(helper.tmux(state, "display-message", "-p", "-t", "verify:0.0", "#{pane_pid}"))
        helper.save(evidence / "instance.json", state)
        control("wait", "VERIFY_NEW")
        control("doctor")
        control("keys", "C")
        control("text", "EXTERNAL_BEFORE")
        control("capture", "external-edit-before")
        edit("EXTERNAL_AFTER")
        control("keys", "C-d")
        control("wait", "✎ draft")
        control("keys", "C")
        control("wait", "New comment")
        screen = control("capture", "external-edit-next-composer")
        if "External Edit accepted" in screen:
            failures.append("FAIL closing Composer clears its External Edit footer")
        control("text", "EXTERNAL_NEXT")
        edit("EXTERNAL_AGAIN")
        control("keys", "Escape")
        control("keys", "C")
        control("wait", "New comment")
        screen = control("capture", "external-edit-after-cancel")
        assert "External Edit accepted" not in screen, screen
        report = failures or [
            "PASS External Edit redraws after Neovim exits without more input",
            "PASS closing Composer clears its External Edit footer",
            "PASS later accepted External Edit shows its footer again",
        ]
        (evidence / "external-edit-result.txt").write_text("\n".join(report) + "\n")
        print("\n".join(report), flush=True)
        print(f"Evidence {evidence}", flush=True)
        if failures:
            raise SystemExit(1)
    finally:
        control("cleanup")


if __name__ == "__main__":
    main()
