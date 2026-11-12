#!/usr/bin/env python3
"""Fail when a benchmark measures cells with CellMetrics.bytes.

CellMetrics.bytes counts one cell per byte. The app measures each grapheme
through vaxis, so a benchmark on bytes misses the cost of the real measurement.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

SOURCES = ("src/benchmark", "src/benchmark_buffer_search.zig")
BYTES_METRICS = re.compile(r"(?:\bCellMetrics|(?<![\w)\]]))\.bytes\b(?!\s*\()")


def violations(root):
    for relative, lines in zig_files(root, SOURCES, literals=False):
        for number, line in enumerate(lines, 1):
            if BYTES_METRICS.search(line):
                yield (
                    f"{relative}:{number}: measures cells with CellMetrics.bytes. "
                    "Use tui.terminal_cell_metrics from src/tui/terminal_cell_metrics.zig, the vaxis measurement the app uses."
                )


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Benchmarks measure cells with the terminal cell metrics.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
