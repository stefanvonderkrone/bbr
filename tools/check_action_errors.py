#!/usr/bin/env python3
"""Fail when code uses the action error fields of Presentation outside their helpers.

A shown action error records the path that set it. A completion of background
work clears only an error of its own path, and a user action clears any error.
`showErrorFor` and `clearError` apply that rule, and `finishEvent` shows the
failure of a maintenance step when its event ends without a message. A raw
write of `action_error` would skip those rules. All of them read the origin
from `event_origin`. `dispatch` sets it from its input, and `withErrorOrigin`
sets it for one piece of work, so a raw write of `event_origin` would give an
error the wrong origin.

Code in Presentation reads `action_error` only in its writers,
`clearErrorExcept`, and `projection`. A read elsewhere decides whether a message shows, and that
decision belongs to `finishEvent`. Code in Presentation uses
`maintenance_failures` only in `settleMaintenance`, `showMaintenanceError`, and
`finishEvent`, so each failed step goes through `failMaintenance` or
`showMaintenanceError` and only a later run of the same step recovers it.

A `withErrorOrigin` call in Presentation names its origin as an enum literal.
A copied origin, such as the origin of a saved error that the code shows
again, can drop a field of the copy without a compile error.

Each rule reads the code text joined across lines, so a line break inside an
access does not hide it. A struct literal field such as `.action_error = ...`
is not an access of the Presentation field.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

SOURCES = (Path("src/tui/presentation.zig"),)
# A member access: an expression, then `.`, then the field name.
ACCESS = r"[\w)\]*?]\s*\.\s*(?P<name>{field})\b"


def listed(names):
    """The names as an English list, such as `a, b, and c`."""
    if len(names) < 3:
        return " and ".join(names)
    return f"{', '.join(names[:-1])}, and {names[-1]}"


def helper_start(helpers):
    return re.compile(rf"^\s*(?:pub\s+)?fn\s+(?:{'|'.join(helpers)})\(")


# Writes anywhere in the file, the tests included.
WRITES = tuple(
    (
        field,
        helper_start(helpers),
        re.compile(ACCESS.format(field=field) + r"\s*=(?!=)"),
        f"writes {field} outside {listed(helpers)}. {fix}",
    )
    for field, helpers, fix in (
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
)
# Every access inside the Presentation struct body.
ACCESSES = tuple(
    (
        field,
        helper_start(helpers),
        re.compile(ACCESS.format(field=field)),
        f"{verb} {field} outside {listed(helpers)}. {fix}",
    )
    for field, verb, helpers, fix in (
        (
            "action_error",
            "reads",
            ("showErrorFor", "clearError", "clearErrorExcept", "finishEvent", "projection"),
            "To report a failed maintenance step, call failMaintenance(step, operation, err, source) or "
            "showMaintenanceError(step, err). finishEvent shows it when the event ends without a message.",
        ),
        (
            "maintenance_failures",
            "uses",
            ("settleMaintenance", "showMaintenanceError", "finishEvent"),
            "Call failMaintenance(step, operation, err, source) for a failure, or "
            "settleMaintenance(step, operation, outcome, source) when a later run of the step can recover it.",
        ),
    )
)


PRESENTATION = re.compile(r"^pub const Presentation = struct \{")
ORIGIN_CALL = re.compile(r"(?<!fn )withErrorOrigin\((?!\s*\.[A-Za-z_]\w*\s*,)")
ORIGIN_MESSAGE = (
    "passes a withErrorOrigin origin that is not an enum literal. Name the path, such as "
    "withErrorOrigin(.review_search, work, args). To keep a shown error after a failure, "
    "call failMaintenance instead of showing a saved copy again."
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


def literal_origin_violations(relative, lines, span):
    start, end = span
    text = "\n".join(lines[start : end + 1])
    found = []
    for match in ORIGIN_CALL.finditer(text):
        number = start + 1 + text.count("\n", 0, match.start())
        found.append((str(relative), number, f"{relative}:{number}: {ORIGIN_MESSAGE}"))
    return found


def outside_helpers(lines, helpers, span):
    """Each line number outside the bodies of the helper functions.

    A helper is a method of Presentation, so a function of the same name in
    another struct is not one.
    """
    helper_depth = None
    body_open = False
    depth = 0
    for number, line in enumerate(lines, 1):
        method = span[0] < number <= span[1] + 1 and depth == 1
        if helper_depth is None and method and helpers.match(line):
            helper_depth = depth
            body_open = False
        elif helper_depth is None:
            yield number
        depth += line.count("{") - line.count("}")
        if helper_depth is not None:
            # A body on the line of the signature opens and closes there.
            body_open = body_open or depth > helper_depth or "{" in line
            if body_open and depth <= helper_depth:
                helper_depth = None


def matches(lines, helpers, pattern, numbers, span):
    """The line and the column of each match in the text of `numbers` outside the helpers, joined across lines."""
    kept = set(outside_helpers(lines, helpers, span)) & numbers
    text = "\n".join(line if number in kept else "" for number, line in enumerate(lines, 1))
    for match in pattern.finditer(text):
        start = match.start("name")
        yield 1 + text.count("\n", 0, start), start - text.rfind("\n", 0, start)


def violations(root):
    found = []
    for relative, lines in zig_files(root, SOURCES, literals=False):
        span = presentation_span(lines)
        if span is None:
            found.append((str(relative), 1, f"{relative}:1: {MISSING_MESSAGE}"))
            continue
        found.extend(literal_origin_violations(relative, lines, span))
        everywhere = set(range(1, len(lines) + 1))
        written = set()
        for field, helpers, pattern, message in WRITES:
            for place in matches(lines, helpers, pattern, everywhere, span):
                written.add(place)
                found.append((str(relative), place[0], f"{relative}:{place[0]}: {message}"))
        body = set(range(span[0] + 2, span[1] + 2))
        for field, helpers, pattern, message in ACCESSES:
            for place in matches(lines, helpers, pattern, body, span):
                if place not in written:
                    found.append((str(relative), place[0], f"{relative}:{place[0]}: {message}"))
    return [message for _, _, message in sorted(found)]


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = violations(root)
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print(
        "Only showErrorFor, clearError, and finishEvent write action_error, and only they, clearErrorExcept, and projection read it. "
        "Only dispatch and withErrorOrigin write event_origin. "
        "Only settleMaintenance, showMaintenanceError, and finishEvent use maintenance_failures. "
        "Each withErrorOrigin call in Presentation names an enum literal."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
