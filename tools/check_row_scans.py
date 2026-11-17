#!/usr/bin/env python3
"""Count each `fileIndexForRow` call inside a loop over all rows in production Zig.

A loop over every Buffer row or visual row that asks each row for its File
answers a question about Files with a binary search per row. The Buffer build
already knows each File's rows, so a question about one File reads the rows
that the Buffer records for it. The count of each file must equal its line in
the baseline, so a new loop fails and a removed loop lowers the baseline.
"""

from pathlib import Path
import re
import sys

import count_baseline
from check_diagnostics import CLOSES, OPENS, handler_end, joined, production
from source_lines import zig_files

BASELINE = "tools/row_scan_baseline.txt"
FOR = re.compile(r"\bfor\s*\(")
WHOLE_ROWS = re.compile(r"^(?:0\s*\.\.\s*)?(?:[\w.]+\.)?(?:rows|visual_rows)(?:\.len)?$")
CALL = re.compile(r"\bfileIndexForRow\s*\(")
FIX = (
    "Ask the Buffer about one File instead of each row: `Buffer.statusPlaceholders`, "
    "`Buffer.fileHeaderRow`, or a `FileRow` field that `buildWithComments` records "
    "in src/tui/buffer.zig. A build that must visit every row walks the `file_rows` "
    "boundaries in order."
)


def closing(text, start):
    """The index of the bracket that closes the one before `start`."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] in OPENS:
            depth += 1
        elif text[index] in CLOSES:
            if depth == 0:
                return index
            depth -= 1
    return len(text)


def operands(header):
    parts, depth, current = [], 0, ""
    for char in header:
        if char in OPENS:
            depth += 1
        elif char in CLOSES:
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += char
    return parts + [current.strip()]


def scans(lines):
    """The line of each `fileIndexForRow` call in the body of a loop over all rows."""
    text, line_of = joined(production(lines))
    found = []
    for loop in FOR.finditer(text):
        end = closing(text, loop.end())
        if not any(WHOLE_ROWS.match(operand) for operand in operands(text[loop.end():end])):
            continue
        captures = re.match(r"\s*\|[^|]*\|", text[end + 1:])
        body_start = end + 1 + (captures.end() if captures else 0)
        body = text[body_start:handler_end(text, body_start)]
        for call in CALL.finditer(body):
            found.append(line_of(body_start + call.start()))
    return found


def counts(root):
    result = {}
    for path, lines in zig_files(root, ("src",), literals=False):
        found = scans(lines)
        if found:
            result[str(path)] = found
    return result


def violations(root):
    baseline = count_baseline.read(root / BASELINE)
    found = counts(root)
    for name in sorted(set(baseline) | set(found)):
        lines = found.get(name, [])
        expected = baseline.get(name, 0)
        if len(lines) > expected:
            places = ", ".join(str(line) for line in lines)
            yield f"{name}: {len(lines)} `fileIndexForRow` calls inside loops over all rows (lines {places}), baseline {expected}. {FIX}"
        elif len(lines) < expected:
            yield f"{name}: {len(lines)} `fileIndexForRow` calls inside loops over all rows, baseline {expected}. Lower {BASELINE} with --write-baseline."


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parent.parent
    if "--write-baseline" in sys.argv:
        count_baseline.write(root / BASELINE, "fileIndexForRow calls inside loops over all rows, per file. Lower only.", {name: len(lines) for name, lines in counts(root).items()})
        return 0
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("No new fileIndexForRow call inside a loop over all rows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
