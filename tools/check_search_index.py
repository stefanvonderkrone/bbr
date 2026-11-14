#!/usr/bin/env python3
"""Reject a new nearest-index mapping of a search occurrence.

A search occurrence index maps into a newer batch by one of two rules.
`sameSearchIndex`, `sameProjectedSearchIndex`, and `sameEditedSearchIndex` keep
the same occurrence and give null when the batch lost it. A rebuild uses them,
because a rebuild does not move the cursor. This includes the accepted Buffer
Search occurrence and the Buffer Search input preview. The nearest rule
(`nearestSearchIndex`) falls back to the nearest index. Only a move that the
user asked for and a list selection use it.

The check matches a call of any function whose name starts with `nearest` and
ends with `Index`. So a new nearest helper under another name also fails. Each
production function that calls one is in NEAREST with its reason. A new use
fails until a reviewer adds it there.
"""

from pathlib import Path
import re
import sys

from check_diagnostics import production
from source_lines import zig_files

NEAREST = {
    ("src/tui/presentation.zig", "acceptReviewSourceScanned"):
        "the Review Search list selection moves to the nearest entry",
    ("src/tui/presentation.zig", "acceptReviewSearchScanned"):
        "the Review Search list selection moves to the nearest entry",
    ("src/tui/presentation.zig", "retryAcceptedDisclosure"):
        "the retry of a move that the user asked for",
    ("src/tui/presentation.zig", "expectReviewSourcePublication"):
        "a test helper that computes the Review Search list selection",
}
CALL = re.compile(r"\b(nearest\w*Index)\s*\(")
FUNCTION = re.compile(r"^\s*(?:pub\s+)?fn\s+(\w+)\s*\(")
FIX = (
    "A rebuild uses sameSearchIndex or sameProjectedSearchIndex, which give null when the batch lost the occurrence. "
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
                key = (path.as_posix(), function)
                seen[key] = seen.get(key, 0) + 1
                if key not in NEAREST or seen[key] > 1:
                    yield f"{path}:{number}: {function} maps an occurrence with {call.group(1)}. {FIX}"
        for key in NEAREST:
            if key[0] == path.as_posix() and key not in seen:
                yield f"{path}: {key[1]} no longer calls the nearest rule. Remove its entry from NEAREST in tools/check_search_index.py."


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
