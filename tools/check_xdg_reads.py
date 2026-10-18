#!/usr/bin/env python3
"""Fail when Zig source outside src/xdg.zig reads an XDG base directory variable."""

from pathlib import Path
import re
import sys

OWNER = Path("src/xdg.zig")
VARIABLES = ('"XDG_CONFIG_HOME"', '"XDG_DATA_HOME"', '"XDG_STATE_HOME"')
FIX = {
    '"XDG_CONFIG_HOME"': "xdg.configHome or xdg.configFile",
    '"XDG_DATA_HOME"': "xdg.dataHome",
    '"XDG_STATE_HOME"': "xdg.stateHome",
}
TEST_START = re.compile(r"^test\b.*\{\s*$")


def violations(root):
    for path in sorted((root / "src").rglob("*.zig")):
        relative = path.relative_to(root)
        if relative == OWNER:
            continue
        in_test = False
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if in_test:
                in_test = line != "}"
                continue
            if TEST_START.match(line):
                in_test = True
                continue
            if "env.put(" in line:
                continue
            for variable in VARIABLES:
                if variable in line:
                    yield f"{relative}:{number}: reads {variable}. Use {FIX[variable]} from src/xdg.zig, which ignores an empty or relative base."


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Only src/xdg.zig reads XDG_CONFIG_HOME, XDG_DATA_HOME, and XDG_STATE_HOME.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
