#!/usr/bin/env python3
"""Check that opencode.jsonc denies agent commands that start bbr with the real environment."""

from fnmatch import fnmatchcase
import json
from pathlib import Path
import re
import sys

from source_lines import zig_files

# Earlier milestone tickets started bbr this way with the operator's Credential.
DENIED = [
    "zig-out/bin/bbr demo",
    "zig build run -- <repo-slug> <pr-id>",
    "zig build run",
    "./zig-out/bin/bbr --help",
    "/Volumes/Work/t3-code/checkout/zig-out/bin/bbr demo",
    "bbr",
    "bbr api pr list",
    "/opt/homebrew/bin/bbr --help",
    # These build steps read the Credential and call Bitbucket. check-mutation and check-verdict write to it.
    "zig build check -- repo 1",
    "zig build check",
    "zig build check-blobs",
    "zig build check-acquisition",
    "zig build check-mutation -- repo 1",
    "zig build check-verdict",
    "zig build check-external-edit",
    "zig build bench-file-acquisition",
    "zig build -Doptimize=ReleaseSafe check -- repo 1",
    "zig build -Doptimize=ReleaseSafe run",
    "zig build -Doptimize=ReleaseSafe run -- demo",
    "zig run src/main.zig",
    "zig run src/main.zig -- demo",
    "./bbr",
    "~/.local/bin/bbr",
    "timeout 5 zig-out/bin/bbr",
    "timeout 5 bbr",
    "timeout 5 bbr demo",
    "TERM=xterm-kitty zig-out/bin/bbr demo",
    "BBR_M32_PROTOCOL=kitty ./zig-out/bin/bbr demo",
    "TERM=xterm-kitty bbr",
    "TERM=xterm-kitty bbr demo",
    "TERM=xterm-kitty zig build run -- demo",
    "bash -c 'zig-out/bin/bbr'",
    "sh -c 'bbr demo'",
    "bash -c 'zig build check -- repo 1'",
    "zig-out/bin/bbr-file-acquisition-bench",
]
# Hermetic checks and benchmarks stay available.
ALLOWED = [
    "zig build",
    "zig build test --summary all",
    "zig build bench",
    "zig build bench-buffer-search",
    "zig build test-cli",
    "zig build test-user-grammar",
    "zig build -Doptimize=ReleaseSafe test --summary failures",
    "zig fmt --check build.zig src tests",
    "zig fmt src/main.zig",
    "$TMPDIR/rest-m32-env/run.sh zig build test --summary failures",
    "./zig-out/bin/bbr-bench",
    "grep bbr src/main.zig",
    "python3 tests/auth_cli_test.py zig-out/bin/bbr",
    "python3 tools/check_live_run_denial.py",
]
# Steps in build.zig that never read the Credential or call Bitbucket.
# Every other build step must stay denied.
HERMETIC_STEPS = {"bench", "bench-buffer-search"}


def build_steps(root):
    _, lines = next(zig_files(root, ("build.zig",), literals=True))
    return [step for line in lines for step in re.findall(r'b\.step\("([^"]+)"', line)]


def bash_rules(root):
    text = (root / "opencode.jsonc").read_text()
    text = re.sub(r"^\s*//.*$", "", text, flags=re.MULTILINE)
    return json.loads(text).get("permission", {}).get("bash", {})


def decision(rules, command):
    result = "allow"
    for pattern, action in rules.items():
        if fnmatchcase(command, pattern):
            result = action
    return result


def failures(rules):
    errors = [f"opencode.jsonc must deny: {c}" for c in DENIED if decision(rules, c) != "deny"]
    errors += [f"opencode.jsonc must not deny: {c}" for c in ALLOWED if decision(rules, c) == "deny"]
    return errors


def check(root):
    rules = bash_rules(root)
    errors = failures(rules)
    for step in build_steps(root):
        hermetic = step in HERMETIC_STEPS or step == "test" or step.startswith("test-")
        if hermetic and decision(rules, f"zig build {step}") == "deny":
            errors.append(f"opencode.jsonc must not deny the hermetic build step: zig build {step}")
        if not hermetic and decision(rules, f"zig build {step}") != "deny":
            errors.append(
                f"opencode.jsonc must deny the build step: zig build {step}. "
                "If the step never reads the Credential, add it to HERMETIC_STEPS in tools/check_live_run_denial.py."
            )
    if errors:
        return errors
    # A rule that no listed command needs can be deleted with no failing check.
    for pattern in rules:
        rest = {p: a for p, a in rules.items() if p != pattern}
        if not failures(rest):
            errors.append(
                f"opencode.jsonc rule {pattern!r} decides no command in DENIED or ALLOWED. "
                "Add the command it guards to tools/check_live_run_denial.py, or delete the rule."
            )
    return errors


if __name__ == "__main__":
    errors = check(Path(__file__).resolve().parents[1])
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        sys.exit(1)
    print("opencode.jsonc denies live bbr runs.")
