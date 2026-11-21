#!/usr/bin/env python3
"""Fail when code in Presentation writes `action_error` outside its two helpers.

A shown action error records the path that set it. A completion of background
work clears only an error of its own path, and a user action clears any error.
`showError` and `clearError` apply that rule, so a raw write would skip it.
A struct literal field such as `.action_error = ...` in the Projection is not
a write of the Presentation field.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

SOURCES = (Path("src/tui/presentation.zig"),)
HELPERS = re.compile(r"^\s*(?:pub\s+)?fn\s+(?:showError|clearError)\(")
WRITE = re.compile(r"[\w)\]*]\.action_error\s*=(?!=)")
FIX = (
    "Call showError(origin, err) or clearError(origin) instead. A completion passes "
    "the ErrorOrigin of its own path, and a key, mouse, or Overlay handler passes .user."
)


def violations(root):
    for relative, lines in zig_files(root, SOURCES, literals=False):
        helper_depth = None
        depth = 0
        for number, line in enumerate(lines, 1):
            if helper_depth is None and HELPERS.match(line):
                helper_depth = depth
            elif helper_depth is None and WRITE.search(line):
                yield f"{relative}:{number}: writes action_error outside its helpers. {FIX}"
            depth += line.count("{") - line.count("}")
            if helper_depth is not None and depth <= helper_depth:
                helper_depth = None


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Only showError and clearError write action_error.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
