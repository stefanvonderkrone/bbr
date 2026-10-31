#!/usr/bin/env python3
"""Check that opencode.jsonc denies agent commands that start bbr with the real environment."""

from fnmatch import fnmatchcase
import json
from pathlib import Path
import re
import sys

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
]
# Hermetic checks and benchmarks stay available.
ALLOWED = [
    "zig build",
    "zig build test --summary all",
    "zig build bench",
    "./zig-out/bin/bbr-bench",
    "grep bbr src/main.zig",
    "python3 tests/auth_cli_test.py zig-out/bin/bbr",
]


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


def check(root):
    rules = bash_rules(root)
    errors = [f"opencode.jsonc must deny: {c}" for c in DENIED if decision(rules, c) != "deny"]
    errors += [f"opencode.jsonc must not deny: {c}" for c in ALLOWED if decision(rules, c) == "deny"]
    return errors


if __name__ == "__main__":
    failures = check(Path(__file__).resolve().parents[1])
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(1)
    print("opencode.jsonc denies live bbr runs.")
