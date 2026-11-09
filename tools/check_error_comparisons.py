#!/usr/bin/env python3
"""Reject comparisons with an error literal in production Zig.

An error comparison compiles against `anyerror`, so the compiler accepts a name
the error set does not contain. A switch prong names that error in the real set.
"""

from pathlib import Path
import re
import sys

from check_diagnostics import joined, production
from source_lines import zig_files

COMPARISON = re.compile(r"(?:==|!=)\s*error\.|\berror\.\w+\s*(?:==|!=)")
FIX = "Replace it with a switch on the error with named prongs and no else that drops a cause."


def violations(root):
    for path, lines in zig_files(root, ("src",), literals=False):
        seen = set()
        text, line_of = joined(production(lines))
        for match in COMPARISON.finditer(text):
            number = line_of(match.start())
            if number in seen:
                continue
            seen.add(number)
            yield f"{path}:{number}: compares an error with `{match.group(0)}`. {FIX}"


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Production Zig does not compare error literals with == or !=.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
