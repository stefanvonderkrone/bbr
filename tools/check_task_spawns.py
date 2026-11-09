#!/usr/bin/env python3
"""Reject a production task spawn that does not go through `diagnostics`.

A copied `diagnostics.Handle` shares its evidence slot. Two concurrent tasks that note
into one slot overwrite each other's evidence, so the one record of a failure can hold
the evidence of another failure. `diagnostics.concurrent` and
`diagnostics.selectConcurrent` reject a Handle with a slot in the task arguments, so
every production task starts through them. The receiver must be the `diagnostics` module
by a top-level declaration, not only a value with that name.
"""

from pathlib import Path
import re
import sys

from check_diagnostics import joined, production
from source_lines import zig_files

# A call chain can break across lines before each `.`, and zig fmt keeps the break.
SPAWN = re.compile(r"\.\s*(concurrent|async)\s*\(")
RECEIVER = re.compile(r"(?<!\w)[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*\s*$")
OWNER = Path("src/diagnostics.zig")
# Zig rejects a local that shadows a top-level name, so a top-level declaration names the
# receiver in the whole file.
WRAPPER = re.compile(
    r'^const\s+diagnostics\s*=\s*(?:@import\("bbr"\)\s*\.\s*diagnostics|bbr\s*\.\s*diagnostics|@import\("(?:\.\./)*diagnostics\.zig"\))\s*;',
    re.MULTILINE,
)
BBR = re.compile(r'^const\s+bbr\s*=\s*@import\("bbr"\)\s*;', re.MULTILINE)
FIX = (
    "Start the task with diagnostics.concurrent or diagnostics.selectConcurrent, which reject "
    "a Handle with an evidence slot in the task arguments. Give the task its own slot by pointer "
    "and adopt it after the join."
)


def wrappers(lines):
    """The receivers that name the `diagnostics` module in a file with these code lines."""
    text = "\n".join(lines)
    names = set()
    if WRAPPER.search(text):
        names.add("diagnostics")
    if BBR.search(text):
        names.add("bbr.diagnostics")
    return names


def violations(root):
    sources = zip(zig_files(root, ("src",), literals=True), zig_files(root, ("src",), literals=False))
    for (path, literal_lines), (_, lines) in sources:
        if path == OWNER:
            continue
        allowed = wrappers(literal_lines)
        text, line_of = joined(production(lines))
        for match in SPAWN.finditer(text):
            if match[1] == "concurrent" and receiver(text[:match.start()]) in allowed:
                continue
            yield f"{path}:{line_of(match.start(1))}: starts a task with `.{match[1]}(`. {FIX}"


def receiver(before):
    """The whole identifier chain before a `.`, or None when an expression such as a call ends it."""
    chain = RECEIVER.search(before)
    if chain is None or before[:chain.start()].rstrip().endswith("."):
        return None
    return re.sub(r"\s", "", chain[0])


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
