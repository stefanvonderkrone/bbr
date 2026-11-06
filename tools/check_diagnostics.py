#!/usr/bin/env python3

from pathlib import Path
import re
import sys

from source_lines import zig_files


SQLITE_RESULT = re.compile(r"\bc\.sqlite3_(?:exec|prepare_v2|step|reset|finalize|bind_\w+)\s*\(")
STANDARD_LOG = re.compile(r"\bstd\s*\.\s*log\s*\.")
# A SQLite result call must be the first argument of a `native` call on any receiver.
NATIVE_WRAPPER = re.compile(r"\b\w+(?:\s*\.\s*\w+)*\s*\.\s*native\s*\(\s*$")


def production(lines):
    depth = 0
    test_depth = None
    for number, line in enumerate(lines, 1):
        if re.match(r"\s*test\b", line):
            test_depth = depth
        if test_depth is None:
            yield number, line
        depth += line.count("{") - line.count("}")
        if test_depth is not None and depth <= test_depth:
            test_depth = None


def unwrapped_sqlite_results(lines):
    """The line numbers of SQLite result calls that are not the first argument of a `native` call.

    The check reads the production code as one text, so a wrapper that opens on an
    earlier line still counts, and an unrelated `native` call on the same line does not.
    """
    numbers = []
    text = ""
    for number, line in lines:
        numbers.append((len(text), number))
        text += line + "\n"
    for match in SQLITE_RESULT.finditer(text):
        if NATIVE_WRAPPER.search(text[: match.start()]):
            continue
        yield max(number for start, number in numbers if start <= match.start())


def violations(root):
    for path, lines in zig_files(root, ("src",), literals=False):
        owner = None
        production_lines = list(production(lines))
        for number, line in production_lines:
            declaration = re.search(r"\bfn\s+(\w+)\s*\(", line)
            if declaration:
                owner = declaration[1]
            if STANDARD_LOG.search(line):
                yield f"{path}:{number}: use a diagnostic Handle or a pure diagnostic Failure, not std.log."
            if str(path) == "src/main.zig" and re.search(r"\bstd\.process\.exit\s*\(", line) and owner != "exitFailure":
                yield f"{path}:{number}: use exitFailure with the real cause and @src() before an error exit."
        if str(path) == "src/persist/sqlite_store.zig":
            for number in unwrapped_sqlite_results(production_lines):
                yield f"{path}:{number}: pass the SQLite result through SqliteStore.native before conversion or disposal."
    for path, lines in zig_files(root, ("src",), literals=True):
        for number, line in enumerate(lines, 1):
            if "bbr-submit-response.log" in line:
                yield f"{path}:{number}: remove the unconditional Submission log. Use the opt-in diagnostic Sink."


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Diagnostic bypass and SQLite result checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
