#!/usr/bin/env python3
"""Fail when a struct field outside a Frame owner holds a `Nav`.

A `Nav` holds visual row numbers, and a row number is valid only in the
Presentation Frame where it was taken. State that outlives a Frame stores a
`frame.NavigationAnchor`, which holds the rows by identity, and resolves it
against the Frame that reads it. Only the containers in `FRAME_OWNERS` hold a
`Nav` beside the rows of its own Frame. Test blocks and `*_test.zig` files
are not production state. A field whose type spans lines is not checked.
"""

from pathlib import Path
import re
import sys

from check_diagnostics import production
from source_lines import zig_files

SOURCES = (Path("src"),)
FRAME_OWNERS = {
    # The Frame itself: `navigation` beside `visual_rows`.
    (Path("src/tui/frame.zig"), "Projection"),
    # The published Frame: `navigation` beside `visual_rows`, replaced together at each admission.
    (Path("src/tui/presentation.zig"), "Published"),
    # A value snapshot of one Frame: `navigation` beside `buffer` and `frame`.
    (Path("src/tui/presentation.zig"), "ReviewProjection"),
}
FIELD = re.compile(r"^\s*(?:pub\s+)?([A-Za-z_]\w*)\s*:\s*([^=]+?)\s*(?:=.*|,\s*)$")
NAV = re.compile(r"\bNav\b")
CONTAINER = re.compile(r"\b(?:struct|union|opaque)(?:\((?:[^()]|\([^()]*\))*\))?\s*$")
NAME = re.compile(r"\bconst\s+([A-Za-z_]\w*)\s*=\s*(?:extern\s+|packed\s+)?(?:struct|union)\b")
FIX = (
    "A Nav holds row numbers of one Frame. Store a frame.NavigationAnchor "
    "(NavigationAnchor.capture) and resolve it against the Frame that reads it."
)


def violations(root):
    for relative, lines in zig_files(root, SOURCES, literals=False):
        if relative.name.endswith("_test.zig"):
            continue
        stack = [f"the file struct of {relative.name}"]
        for number, line in production(lines):
            field = FIELD.match(line)
            if field and stack and stack[-1] is not None and stack[-1] != "(" and NAV.search(field.group(2)):
                container = stack[-1]
                if (relative, container) not in FRAME_OWNERS:
                    yield f"{relative}:{number}: the field `{field.group(1)}` of `{container}` holds a `Nav`. {FIX}"
            name = NAME.search(line)
            for index, char in enumerate(line):
                if char in "([":
                    stack.append("(")
                elif char == "{":
                    stack.append((name.group(1) if name else "an anonymous container") if CONTAINER.search(line[:index]) else None)
                elif char in ")]}" and stack:
                    stack.pop()


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Only a Frame owner holds a Nav field.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
