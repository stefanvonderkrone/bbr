#!/usr/bin/env python3
"""Fail when a terminal painter other than src/tui/view_paint.zig writes a border corner or junction glyph."""

from pathlib import Path
import re
import sys

PAINTERS = (Path("src/tui/render.zig"), Path("src/tui/app.zig"))
GLYPHS = re.compile("[┌┐└┘├┤┬┴┼╭╮╰╯]")
TEST_START = re.compile(r"^test\b.*\{\s*$")
FIX = (
    "Declare a border, a rule, or a Title on a View in src/tui/layouts.zig and paint it with view_paint.paint. "
    "To join a content row into a border, call view_paint.join."
)


def violations(root):
    for relative in PAINTERS:
        in_test = False
        for number, line in enumerate((root / relative).read_text().splitlines(), 1):
            if in_test:
                in_test = line != "}"
                continue
            if TEST_START.match(line):
                in_test = True
                continue
            if line.lstrip().startswith("//"):
                continue
            match = GLYPHS.search(line)
            if match:
                yield f"{relative}:{number}: writes the box glyph {match.group()}. {FIX}"


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Only src/tui/view_paint.zig paints border corners and junctions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
