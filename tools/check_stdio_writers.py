#!/usr/bin/env python3
"""Fail when Zig source uses stdout() or stderr() other than for a streaming writer or a handle comparison.

An alias such as `const out = stdout();`, or a File built from `stdout().handle`, could make a
positional writer out of sight of this check. So every use must be `.writerStreaming(`, or
`.handle` as one side of `==` or `!=`. `zig fmt`, run by `zig build test`, removes spaces inside
the call chain.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

USE = re.compile(r"(?:\bstd\.Io\.File\.)?\b(stdout|stderr)\(\)(\.writerStreaming\(|\.handle\b)?")
COMPARISON_BEFORE = re.compile(r"[=!]=\s*$")
COMPARISON_AFTER = re.compile(r"^\s*[=!]=")


def allowed(line, match):
    if match.group(2) == ".writerStreaming(":
        return True
    if match.group(2) == ".handle":
        return bool(COMPARISON_BEFORE.search(line[: match.start()]) or COMPARISON_AFTER.match(line[match.end() :]))
    return False


def violations(root):
    for relative, lines in zig_files(root, ("src",), literals=False):
        for number, line in enumerate(lines, 1):
            for match in USE.finditer(line):
                if allowed(line, match):
                    continue
                stream = match.group(1)
                yield (
                    f"{relative}:{number}: use {stream}() only as {stream}().writerStreaming( "
                    f"or as {stream}().handle in a == or != comparison. "
                    f"File.writer writes at absolute file offsets and overwrites a redirected file, "
                    f"and an alias or a File built from the handle hides such a writer from this check."
                )


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Every stdout() and stderr() use is a streaming writer or a handle comparison.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
