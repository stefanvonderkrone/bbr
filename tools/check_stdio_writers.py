#!/usr/bin/env python3
"""Fail when Zig source uses stdout() or stderr() other than for a streaming writer or a handle.

An alias such as `const out = stdout();` could make a positional writer out of sight of this check,
so every use must be `.writerStreaming(` or `.handle`. `zig fmt`, run by `zig build test`, removes
spaces inside the call chain.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

OTHER_USE = re.compile(r"\b(stdout|stderr)\(\)(?!\.writerStreaming\(|\.handle\b)")


def violations(root):
    for relative, lines in zig_files(root, ("src",), literals=False):
        for number, line in enumerate(lines, 1):
            for match in OTHER_USE.finditer(line):
                stream = match.group(1)
                yield (
                    f"{relative}:{number}: use {stream}() only as {stream}().writerStreaming( or {stream}().handle. "
                    f"File.writer writes at absolute file offsets and overwrites a redirected file, "
                    f"and an alias of {stream}() hides such a writer from this check."
                )


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Every stdout() and stderr() use is a streaming writer or a handle.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
