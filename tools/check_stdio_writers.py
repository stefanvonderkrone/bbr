#!/usr/bin/env python3
"""Fail when Zig source makes a positional writer for stdout or stderr."""

from pathlib import Path
import re
import sys

from source_lines import zig_files

POSITIONAL = re.compile(r"\b(stdout|stderr)\(\)\.writer\(")


def violations(root):
    for relative, lines in zig_files(root, ("src",), literals=False):
        for number, line in enumerate(lines, 1):
            match = POSITIONAL.search(line)
            if match:
                stream = match.group(1)
                yield (
                    f"{relative}:{number}: {stream}().writer writes at absolute file offsets and overwrites a redirected file. "
                    f"Use {stream}().writerStreaming."
                )


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Every stdout and stderr writer streams.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
