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

A `withErrorOrigin` call in Presentation names its origin as an enum literal.
A copied origin, such as the origin of a saved error that the code shows
again, can drop a field of the copy without a compile error.

Only `showMaintenanceError` asks whether no action error shows. A failure
that keeps the shown message must go through it, because a later clear of the
same event would otherwise remove the kept message and hide the failure.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

SOURCES = (Path("src/tui/presentation.zig"),)
FIELDS = (
    (
        "action_error",
        ("showErrorFor", "clearError", "finishEvent"),
        "Call showError(err), showErrorFor(err, key), or clearError() instead. All take the origin of the event that runs.",
    ),
    (
        "event_origin",
        ("dispatch", "withErrorOrigin"),
        "Run the work through withErrorOrigin(origin, work, args) instead. It restores the origin of the event.",
    ),
)
def listed(names):
    """The names as an English list, such as `a, b, and c`."""
    if len(names) < 3:
        return " and ".join(names)
    return f"{', '.join(names[:-1])}, and {names[-1]}"


CHECKS = tuple(
    (
        field,
        re.compile(rf"^\s*(?:pub\s+)?fn\s+(?:{'|'.join(helpers)})\("),
        re.compile(rf"[\w)\]*]\.{field}\s*=(?!=)"),
        f"writes {field} outside {listed(helpers)}. {fix}",
    )
    for field, helpers, fix in FIELDS
)


PRESENTATION = re.compile(r"^pub const Presentation = struct \{")
ORIGIN_CALL = re.compile(r"(?<!fn )withErrorOrigin\((?!\s*\.[A-Za-z_]\w*\s*,)")
ORIGIN_MESSAGE = (
    "passes a withErrorOrigin origin that is not an enum literal. Name the path, such as "
    "withErrorOrigin(.review_search, work, args). To keep a shown error after a failure, "
    "call failMaintenance instead of showing a saved copy again."
)
KEEP_HELPER = re.compile(r"^\s*(?:pub\s+)?fn\s+showMaintenanceError\(")
KEEP_TEST = re.compile(r"\.action_error\s*==\s*null")
KEEP_MESSAGE = (
    "decides whether a failure keeps the shown message outside showMaintenanceError. "
    "Call showMaintenanceError(err) instead, so a later clear of the same event shows the failure."
)
MISSING_MESSAGE = (
    "has no line `pub const Presentation = struct {`, so the withErrorOrigin check reads nothing. "
    "Update PRESENTATION in tools/check_action_errors.py to the new name of the struct."
)


def presentation_span(lines):
    """The first and the last line index of the Presentation struct body."""
    for start, line in enumerate(lines):
        if PRESENTATION.match(line):
            depth = 0
            for end in range(start, len(lines)):
                depth += lines[end].count("{") - lines[end].count("}")
                if depth == 0:
                    return start, end
    return None


def literal_origin_violations(relative, lines):
    span = presentation_span(lines)
    if span is None:
        return [(str(relative), 1, f"{relative}:1: {MISSING_MESSAGE}")]
    start, end = span
    text = "\n".join(lines[start : end + 1])
    found = []
    for match in ORIGIN_CALL.finditer(text):
        number = start + 1 + text.count("\n", 0, match.start())
        found.append((str(relative), number, f"{relative}:{number}: {ORIGIN_MESSAGE}"))
    return found


def outside_helpers(lines, helpers):
    """Each line number and line outside the bodies of the helper functions."""
    helper_depth = None
    body_open = False
    depth = 0
    for number, line in enumerate(lines, 1):
        if helper_depth is None and helpers.match(line):
            helper_depth = depth
            body_open = False
        elif helper_depth is None:
            yield number, line
        depth += line.count("{") - line.count("}")
        if helper_depth is not None:
            body_open = body_open or depth > helper_depth
            if body_open and depth <= helper_depth:
                helper_depth = None


def violations(root):
    found = []
    for relative, lines in zig_files(root, SOURCES, literals=False):
        found.extend(literal_origin_violations(relative, lines))
        for _, helpers, write, message in CHECKS:
            for number, line in outside_helpers(lines, helpers):
                if write.search(line):
                    found.append((str(relative), number, f"{relative}:{number}: {message}"))
        span = presentation_span(lines)
        if span is not None:
            for number, line in outside_helpers(lines, KEEP_HELPER):
                if span[0] < number <= span[1] + 1 and KEEP_TEST.search(line):
                    found.append((str(relative), number, f"{relative}:{number}: {KEEP_MESSAGE}"))
    return [message for _, _, message in sorted(found)]


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = violations(root)
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print(
        "Only showErrorFor, clearError, and finishEvent write action_error, only dispatch and withErrorOrigin write event_origin, "
        "each withErrorOrigin call in Presentation names an enum literal, "
        "and only showMaintenanceError asks whether no action error shows."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
