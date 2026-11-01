#!/usr/bin/env python3
"""Fail when a tests/*_test.py or tests/*_test.sh file runs in no build step or workflow."""

from pathlib import Path
import sys


def runners(root):
    yield root / "build.zig", "//"
    for path in sorted((root / ".github/workflows").glob("*.yml")):
        yield path, "#"


def named(root):
    text = []
    for path, comment in runners(root):
        # A path in a comment runs nothing.
        text.extend(line for line in path.read_text(encoding="utf-8").splitlines()
                    if not line.lstrip().startswith(comment))
    return "\n".join(text)


def violations(root):
    runner_text = named(root)
    for pattern in ("*_test.py", "*_test.sh"):
        for path in sorted((root / "tests").glob(pattern)):
            relative = path.relative_to(root).as_posix()
            if relative not in runner_text:
                yield (f"{relative}: nothing runs this test. Add it to the `test` step in build.zig, "
                       "or to .github/workflows/ci.yml if it needs a TTY, a built binary, or CI-only tools.")


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("build.zig or a workflow names every tests/*_test.py and tests/*_test.sh file.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
