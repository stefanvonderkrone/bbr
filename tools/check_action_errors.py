#!/usr/bin/env python3
"""Fail when code in Presentation writes `action_error` or `event_origin` outside their helpers.

A shown action error records the path that set it. A completion of background
work clears only an error of its own path, and a user action clears any error.
`showErrorFor` and `clearError` apply that rule, so a raw write of `action_error`
would skip it. Both read the origin from `event_origin`. `dispatch` sets it
from its input, and `withErrorOrigin` sets it for one piece of work, so a raw
write of `event_origin` would give an error the wrong origin.
A struct literal field such as `.action_error = ...` in the Projection is not
a write of the Presentation field.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

SOURCES = (Path("src/tui/presentation.zig"),)
FIELDS = (
    (
        "action_error",
        ("showErrorFor", "clearError"),
        "Call showError(err), showErrorFor(err, key), or clearError() instead. All take the origin of the event that runs.",
    ),
    (
        "event_origin",
        ("dispatch", "withErrorOrigin"),
        "Run the work through withErrorOrigin(origin, work, args) instead. It restores the origin of the event.",
    ),
)
CHECKS = tuple(
    (
        field,
        re.compile(rf"^\s*(?:pub\s+)?fn\s+(?:{'|'.join(helpers)})\("),
        re.compile(rf"[\w)\]*]\.{field}\s*=(?!=)"),
        f"writes {field} outside {' and '.join(helpers)}. {fix}",
    )
    for field, helpers, fix in FIELDS
)


def violations(root):
    found = []
    for relative, lines in zig_files(root, SOURCES, literals=False):
        for _, helpers, write, message in CHECKS:
            helper_depth = None
            body_open = False
            depth = 0
            for number, line in enumerate(lines, 1):
                if helper_depth is None and helpers.match(line):
                    helper_depth = depth
                    body_open = False
                elif helper_depth is None and write.search(line):
                    found.append((str(relative), number, f"{relative}:{number}: {message}"))
                depth += line.count("{") - line.count("}")
                if helper_depth is not None:
                    body_open = body_open or depth > helper_depth
                    if body_open and depth <= helper_depth:
                        helper_depth = None
    return [message for _, _, message in sorted(found)]


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = violations(root)
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Only showErrorFor and clearError write action_error, and only dispatch and withErrorOrigin write event_origin.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
