#!/usr/bin/env python3
"""Fail when a tests/*_test.py or tests/*_test.sh file runs in no build step or workflow."""

from pathlib import Path
import re
import sys

from source_lines import yaml_code, zig_code

PATH_TOKEN = re.compile(r"[\w./-]+")
RUN_KEY = re.compile(r"^(\s*)(?:-\s+)?run:\s*(.*)$")
BLOCK_SCALAR = re.compile(r"^[|>][-+0-9]*$")


def run_lines(lines):
    """The commands of each `run` step: a one-line value or the lines of its block scalar."""
    block_indent = None
    for line in lines:
        if block_indent is not None:
            if not line.strip() or len(line) - len(line.lstrip()) > block_indent:
                yield line
                continue
            block_indent = None
        match = RUN_KEY.match(line)
        if not match:
            continue
        if BLOCK_SCALAR.match(match.group(2)):
            block_indent = len(match.group(1))
        else:
            yield match.group(2)


def named_paths(root):
    """Every path token that build.zig code or a workflow `run` step names, without a leading `./`."""
    lines = zig_code((root / "build.zig").read_text(encoding="utf-8"))
    for path in sorted((root / ".github/workflows").glob("*.yml")):
        lines.extend(run_lines(yaml_code(path.read_text(encoding="utf-8"))))
    return {token.removeprefix("./") for line in lines for token in PATH_TOKEN.findall(line)}


def violations(root):
    paths = named_paths(root)
    for pattern in ("*_test.py", "*_test.sh"):
        for path in sorted((root / "tests").glob(pattern)):
            relative = path.relative_to(root).as_posix()
            if relative not in paths:
                yield (f"{relative}: nothing runs this test. Add it to the `test` step in build.zig, "
                       "or to a `run` step in .github/workflows/ci.yml if it needs a TTY, a built binary, or CI-only tools.")


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("build.zig or a workflow run step names every tests/*_test.py and tests/*_test.sh file.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
