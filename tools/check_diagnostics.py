#!/usr/bin/env python3

from pathlib import Path
import re
import sys

import count_baseline
from source_lines import zig_files


SQLITE_RESULT = re.compile(r"\bc\.sqlite3_(?:exec|prepare_v2|step|reset|finalize|bind_\w+)\s*\(")
STANDARD_LOG = re.compile(r"\bstd\s*\.\s*log\s*\.")
# A `catch` without a named capture drops the cause: `catch {}`, `catch return ...`, `catch |_|`.
CAUSE_DROP = re.compile(r"\bcatch\b(?!\s*\|\s*[A-Za-z]\w*\s*\|)")
CATCH_BASELINE = "tools/diagnostic_catch_baseline.txt"
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


def cause_drop_counts(root):
    """The number of production `catch` sites without a named capture in each Zig file under src/."""
    counts = {}
    for path, lines in zig_files(root, ("src",), literals=False):
        count = sum(len(CAUSE_DROP.findall(line)) for _, line in production(lines))
        if count:
            counts[str(path)] = count
    return counts


def cause_drop_changes(root):
    """A ratchet: a file may not gain a `catch` that drops its cause, and a removed one lowers the baseline."""
    baseline = count_baseline.read(root / CATCH_BASELINE)
    counts = cause_drop_counts(root)
    for name in sorted(set(baseline) | set(counts)):
        allowed = baseline.get(name, 0)
        found = counts.get(name, 0)
        if found > allowed:
            yield (
                f"{name}: {found} `catch` sites drop their cause, {allowed} allowed. "
                "Capture the error with `catch |err|` and record it through a diagnostics.Handle or Presentation.reportFailure. "
                f"For an expected outcome, raise the count in {CATCH_BASELINE} in the same change and say why in the commit."
            )
        elif found < allowed:
            yield f"{name}: {found} `catch` sites drop their cause, {allowed} allowed. Lower the count in {CATCH_BASELINE} to {found}."


def write_baseline(root):
    count_baseline.write(
        root / CATCH_BASELINE,
        "Production `catch` sites without a named capture, per file. tools/check_diagnostics.py fails when a count changes.",
        cause_drop_counts(root),
    )


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
            if declaration and declaration[1].endswith("WithDiagnostics") and declaration[1] != "WithDiagnostics":
                base = declaration[1][: -len("WithDiagnostics")]
                yield (
                    f"{path}:{number}: do not add {declaration[1]} beside {base}. "
                    f"Give {base} a required diagnostics.Handle parameter, so no caller can drop it with a silent `.{{}}`."
                )
            if str(path) == "src/main.zig" and re.search(r"\bstd\.process\.exit\s*\(", line) and owner != "exitFailure":
                yield f"{path}:{number}: use exitFailure with the real cause and @src() before an error exit."
        if str(path) == "src/persist/sqlite_store.zig":
            for number in unwrapped_sqlite_results(production_lines):
                yield f"{path}:{number}: pass the SQLite result through SqliteStore.native before conversion or disposal."
    yield from cause_drop_changes(root)
    for path, lines in zig_files(root, ("src",), literals=True):
        for number, line in enumerate(lines, 1):
            if "bbr-submit-response.log" in line:
                yield f"{path}:{number}: remove the unconditional Submission log. Use the opt-in diagnostic Sink."


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--write-catch-baseline":
        write_baseline(Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parents[1])
        return 0
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
