#!/usr/bin/env python3
"""Reject a production task spawn that does not go through `diagnostics`.

A copied `diagnostics.Handle` shares its evidence slot. Two concurrent tasks that note
into one slot overwrite each other's evidence, so the one record of a failure can hold
the evidence of another failure. `diagnostics.concurrent` and
`diagnostics.selectConcurrent` reject a Handle with a slot in the task arguments, so
every production task starts through them.
"""

from pathlib import Path
import re
import sys

from check_diagnostics import production
from source_lines import zig_files

SPAWN = re.compile(r"(?<!diagnostics)\.(concurrent|async)\(")
OWNER = Path("src/diagnostics.zig")
FIX = (
    "Start the task with diagnostics.concurrent or diagnostics.selectConcurrent, which reject "
    "a Handle with an evidence slot in the task arguments. Give the task its own slot by pointer "
    "and adopt it after the join."
)


def violations(root):
    for path, lines in zig_files(root, ("src",), literals=False):
        if path == OWNER:
            continue
        for number, line in production(lines):
            match = SPAWN.search(line)
            if match is None:
                continue
            yield f"{path}:{number}: starts a task with `.{match.group(1)}(`. {FIX}"


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Production tasks start through diagnostics.concurrent and diagnostics.selectConcurrent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
