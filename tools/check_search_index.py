#!/usr/bin/env python3
"""Reject a new nearest-index mapping of a search occurrence.

A search occurrence index maps into a newer batch by one of two rules.
`sameSearchIndex` keeps the same occurrence and gives null when the batch lost
it. A rebuild uses it, because a rebuild does not move the cursor. The nearest
rule (`nearestSearchIndex`, `nearestProjectedSearchIndex`) falls back to the
nearest index. A move the user asked for, a list selection, and the Buffer
Search input preview use it.

Each production function that uses the nearest rule is in NEAREST with its
reason. A new use fails until a reviewer adds it there.
"""

from pathlib import Path
import re
import sys

from check_diagnostics import production
from source_lines import zig_files

NEAREST = {
    ("src/tui/presentation.zig", "prepareBufferControlForFile", "nearestSearchIndex"):
        "the Buffer Search input preview, like acceptViewBuild. Ticket 18 of enrichment-rebuild-cascade decides its rule.",
    ("src/tui/presentation.zig", "acceptReviewSourceScanned", "nearestSearchIndex"):
        "the Review Search list selection moves to the nearest entry",
    ("src/tui/presentation.zig", "acceptReviewSearchScanned", "nearestSearchIndex"):
        "the Review Search list selection moves to the nearest entry",
    ("src/tui/presentation.zig", "acceptViewBuild", "nearestProjectedSearchIndex"):
        "the Buffer Search input preview. Ticket 18 of enrichment-rebuild-cascade decides its rule.",
    ("src/tui/presentation.zig", "retryAcceptedDisclosure", "nearestSearchIndex"):
        "the retry of a move that the user asked for",
    ("src/tui/presentation.zig", "expectReviewSourcePublication", "nearestSearchIndex"):
        "a test helper that computes the Review Search list selection",
}
CALL = re.compile(r"\b(nearestSearchIndex|nearestProjectedSearchIndex)\s*\(")
FUNCTION = re.compile(r"^\s*(?:pub\s+)?fn\s+(\w+)\s*\(")
FIX = (
    "A rebuild that keeps an occurrence uses sameSearchIndex, which gives null when the batch lost it. "
    "Use the nearest rule only for a move the user asked for or a list selection, "
    "and add the function to NEAREST in tools/check_search_index.py with its reason."
)


def violations(root):
    for path, lines in zig_files(root, ("src",), literals=False):
        function = None
        seen = {}
        for number, line in production(lines):
            declared = FUNCTION.match(line)
            if declared:
                function = declared.group(1)
            for call in CALL.finditer(line):
                if declared and declared.group(1) == call.group(1):
                    continue
                key = (path.as_posix(), function, call.group(1))
                seen[key] = seen.get(key, 0) + 1
                if key not in NEAREST or seen[key] > 1:
                    yield f"{path}:{number}: {function} maps an occurrence with {call.group(1)}. {FIX}"
        for key in NEAREST:
            if key[0] == path.as_posix() and key not in seen:
                yield f"{path}: {key[1]} no longer calls {key[2]}. Remove its entry from NEAREST in tools/check_search_index.py."


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Only the functions in NEAREST map a search occurrence to the nearest index.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
