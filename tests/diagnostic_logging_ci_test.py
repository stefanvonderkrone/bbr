import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / ".agents/skills/verify-bbr/scripts/control.py"


def verify(phase):
    evidence = Path(subprocess.check_output(["python3", str(CONTROL), "launch"], cwd=ROOT, text=True).strip())
    env = dict(os.environ, BBR_VERIFY_RUN=str(evidence))

    def control(*values):
        return subprocess.check_output(["python3", str(CONTROL), *values], cwd=ROOT, env=env, text=True)

    try:
        state = json.loads((evidence / "instance.json").read_text())
        scratch = Path(state["scratch"])
        home = scratch / "home"
        log_dir = home / ".local/state/bbr/diagnostics"
        secret = "DIAGNOSTIC_SECRET_SENTINEL"
        spec = importlib.util.spec_from_file_location("verify_bbr_control", CONTROL)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)

        def snapshot():
            return {str(path.relative_to(log_dir)): path.read_bytes() for path in log_dir.rglob("*") if path.is_file()} if log_dir.is_dir() else {}

        def toggle(label, expected=None):
            control("keys", "C-p")
            control("text", "Toggle diagnostic logging")
            selection = control("capture", label + "-command")
            assert "Toggle diagnostic logging" in selection, selection
            assert "no matching commands" not in selection, selection
            control("keys", "Enter")
            if expected:
                control("wait", expected)
            return control("capture", label + "-result")

        def fail_external_edit(label):
            control("keys", "C")
            control("text", secret)
            control("keys", "C-e")
            control("wait", "External Edit failed")
            screen = control("capture", label)
            assert secret in screen, "The Composer lost its authored body"
            control("keys", "Escape")

        control("doctor")
        assert not log_dir.exists(), "Default startup created diagnostic storage"
        config_path = home / ".config/bbr/config.toml"
        if phase == "config":
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config_path.write_text("[logging]\nenabled = true\n")
        injected = {"GIT_EDITOR": "vi", "TMPDIR": str(scratch / secret)}
        prefix = "env -i " + " ".join(shlex.quote(key + "=" + value) for key, value in injected.items()) + " "
        command = state["command"].replace("env -i ", prefix, 1)
        helper.tmux(state, "respawn-pane", "-k", "-t", "verify:0.0", "-c", str(scratch / "repo"), command)
        state["command"] = command
        state["pane_pid"] = int(helper.tmux(state, "display-message", "-p", "-t", "verify:0.0", "#{pane_pid}"))
        helper.save(evidence / "instance.json", state)
        control("wait", "VERIFY_NEW")
        control("doctor")

        if phase == "unavailable":
            assert not log_dir.exists()
            log_dir.write_text("owned test obstacle\n")
            screen = toggle("logging-unavailable", "diagnostic logging unavailable")
            assert log_dir.is_file(), "Failed enable changed the test obstacle"
            assert log_dir.read_text() == "owned test obstacle\n"
            assert "diagnostic logging unavailable" in screen, screen
            assert "logging enabled" not in screen.lower(), screen
        else:
            if phase == "palette":
                fail_external_edit("logging-default-off-error")
                assert not log_dir.exists(), "An error created diagnostic storage while logging was off"
                toggle("logging-enable", "diagnostic logging enabled")
            assert snapshot(), "Enablement created no diagnostic file"
            fail_external_edit("logging-enabled-error")
            written = snapshot()
            body = b"\n".join(written.values())
            for field in (b"FileNotFound", b"presentation_adapter.zig:", b"operation=external_edit", b"command_id=", b"session_epoch="):
                assert field in body, "Missing diagnostic field " + repr(field)
            assert secret.encode() not in body, "The log exposed authored content or environment data"
            assert log_dir.stat().st_mode & 0o077 == 0, "The diagnostic directory is not private"
            for relative in written:
                assert (log_dir / relative).stat().st_mode & 0o077 == 0, "A diagnostic file is not private"
            toggle("logging-disable")
            disabled = snapshot()
            fail_external_edit("logging-disabled-error")
            assert snapshot() == disabled, "A disabled logger still wrote an error"
            if phase == "config":
                assert config_path.read_text() == "[logging]\nenabled = true\n", "The palette rewrote config.toml"
            shutil.copytree(log_dir, evidence / "diagnostic-logs")
        (evidence / "logging-proof.json").write_text(json.dumps({"phase": phase, "passed": True}, indent=2) + "\n")
        print("PASS diagnostic logging " + phase + ". Evidence " + str(evidence))
    finally:
        control("cleanup")


if __name__ == "__main__":
    for phase in ("palette", "config", "unavailable"):
        verify(phase)
