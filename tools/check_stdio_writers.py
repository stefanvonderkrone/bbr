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

# The patterns run over the whole file, so `\s` also matches the line breaks that zig fmt keeps
# after `==` and before a field access.
USE = re.compile(r"(?:\bstd\s*\.\s*Io\s*\.\s*File\s*\.\s*)?\b(stdout|stderr)\(\)(\s*\.\s*writerStreaming\(|\s*\.\s*handle\b)?")
COMPARISON_BEFORE = re.compile(r"[=!]=\s*$")
COMPARISON_AFTER = re.compile(r"\s*[=!]=")


def allowed(code, match):
    member = (match.group(2) or "").replace(" ", "").replace("\n", "")
    if member == ".writerStreaming(":
        return True
    if member == ".handle":
        return bool(COMPARISON_BEFORE.search(code, 0, match.start()) or COMPARISON_AFTER.match(code, match.end()))
    return False


def violations(root):
    for relative, lines in zig_files(root, ("src",), literals=False):
        code = "\n".join(lines)
        for match in USE.finditer(code):
            if allowed(code, match):
                continue
            stream = match.group(1)
            number = code.count("\n", 0, match.start(1)) + 1
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
