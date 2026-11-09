#!/usr/bin/env python3

from pathlib import Path
import re
import sys
from typing import Callable, NamedTuple

import count_baseline
from source_lines import zig_files


SQLITE_RESULT = re.compile(r"\bc\.sqlite3_(?:exec|prepare_v2|step|reset|finalize|bind_\w+)\s*\(")
STANDARD_LOG = re.compile(r"\bstd\s*\.\s*log\s*\.")
# `|name|` may start on the next line.
CAUSE_DROP = re.compile(r"\bcatch\b(?!\s*\|\s*[A-Za-z_]\w*\s*\|)")
CATCH_CAPTURE = re.compile(r"\bcatch\s*\|\s*([A-Za-z_]\w*)\s*\|")
CATCH_BASELINE = "tools/diagnostic_catch_baseline.txt"
# An `errdefer |err|` runs only on an error return, so a record in it always propagates the error.
RECORDING_HANDLER = re.compile(r"\b(?:catch|errdefer)\s*\|\s*([A-Za-z_]\w*)\s*\|")
NESTED_CATCH = re.compile(r"\bcatch\b(?:\s*\|\s*[A-Za-z_]\w*\s*\|)?")
# exitFailure also records, but it never returns.
RECORD = re.compile(r"(?:\.\s*(?:failure|record)|\breportFailure)\s*\(")
RECORD_BASELINE = "tools/diagnostic_record_baseline.txt"
RETURN = re.compile(r"\breturn\b")
NO_NEW_ERROR = re.compile(r"(?:\.|\d|(?:null|true|false|undefined|try)\b|error\.Reported\b|(?!(?:if|switch)\b)[A-Za-z_][\w.]*\s*\()")
# A SQLite result call must be the first argument of a `native` call on any receiver.
NATIVE_WRAPPER = re.compile(r"\b\w+(?:\s*\.\s*\w+)*\s*\.\s*native\s*\(\s*$")
# The client returns each error of this set only through `noted`, so its record never takes stale evidence.
CLIENT = "src/bitbucket/client.zig"
API_ERRORS = "src/bitbucket/types.zig"
OPENS = "([{"
CLOSES = ")]}"


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


def api_error_names(root):
    """The members of `ApiError` in src/bitbucket/types.zig."""
    for _, lines in zig_files(root, (API_ERRORS,), literals=False):
        declaration = re.search(r"\bpub\s+const\s+ApiError\s*=\s*error\s*\{([^}]*)\}", "\n".join(lines))
        if declaration:
            return re.findall(r"[A-Za-z_]\w*", declaration[1])
    return []


def unnoted_client_returns(lines, names):
    """The line of each returned `ApiError` member outside the error argument of `noted`."""
    member = re.compile(r"\berror\s*\.\s*(?:" + "|".join(names) + r")\b")
    text, line_of = joined(lines)
    for returned in RETURN.finditer(text):
        start = returned.end()
        end = handler_end(text, start)
        expression = text[start:end]
        noted_arguments = set()
        for call in re.finditer(r"\bnoted\s*\(", expression):
            depth = 0
            for index in range(call.end(), len(expression)):
                char = expression[index]
                if char in OPENS:
                    depth += 1
                elif char in CLOSES:
                    if depth == 0:
                        break
                    depth -= 1
                elif char == "," and depth == 0:
                    argument = re.match(r"\s*(error\s*\.\s*\w+)\s*(?=,)", expression[index + 1:])
                    if argument:
                        noted_arguments.add(index + 1 + argument.start(1))
                    break
        for found in member.finditer(expression):
            if re.match(r"(?:\s*,\s*error\s*\.\s*\w+)*\s*,?\s*=>", expression[found.end():]):
                continue
            if found.start() not in noted_arguments:
                yield line_of(start + found.start())


def unwrapped_sqlite_results(lines):
    """The line numbers of SQLite result calls that are not the first argument of a `native` call.

    The check reads the production code as one text, so a wrapper that opens on an
    earlier line still counts, and an unrelated `native` call on the same line does not.
    """
    text, line_of = joined(lines)
    for match in SQLITE_RESULT.finditer(text):
        if NATIVE_WRAPPER.search(text[: match.start()]):
            continue
        yield line_of(match.start())


def joined(lines):
    """The `(number, line)` pairs as one text, and a function from an offset in it to its line number."""
    numbers = []
    text = ""
    for number, line in lines:
        numbers.append((len(text), number))
        text += line + "\n"
    return text, lambda offset: max(number for start, number in numbers if start <= offset)


def handler_end(text, start):
    """The index after the handler that begins at `start`."""
    depth = 0
    index = start
    block = text[start:].lstrip().startswith("{")
    while index < len(text):
        char = text[index]
        if char in OPENS:
            depth += 1
        elif char in CLOSES:
            if depth == 0:
                return index
            depth -= 1
            if depth == 0 and block:
                return index + 1
        elif char in ";," and depth == 0:
            return index
        index += 1
    return index


def switch_spans(handler, name):
    """The `(start, end)` of the body of each `switch (name) { ... }` in `handler`."""
    pattern = re.compile(r"\bswitch\s*\(\s*" + re.escape(name) + r"\s*\)\s*\{")
    for match in pattern.finditer(handler):
        depth = 1
        index = match.end()
        while index < len(handler) and depth:
            depth += handler[index] in OPENS
            depth -= handler[index] in CLOSES
            index += 1
        if depth == 0:
            yield match.end(), index - 1


def prongs(body):
    depth = 0
    start = 0
    for index, char in enumerate(body):
        if char in OPENS:
            depth += 1
        elif char in CLOSES:
            depth -= 1
        elif char == "," and depth == 0:
            yield body[start:index]
            start = index + 1
    yield body[start:]


def cause_drops(lines):
    """Each catch that drops its cause, as `(line, kind)`.

    The scan reads the lines as one text, so a handler on the next line stays
    inside the catch.
    """

    def else_drops(body, name):
        for prong in prongs(body):
            head, arrow, rest = prong.partition("=>")
            if not arrow or head.strip() != "else":
                continue
            payload = re.match(r"\s*\|\s*(\w+)\s*\|", rest)
            names = {name}
            used = rest
            if payload:
                names.add(payload[1])
                used = rest[payload.end() :]
            if not any(re.search(r"\b" + re.escape(item) + r"\b", used) for item in names):
                return True
        return False

    text, line_of = joined(lines)
    for match in CAUSE_DROP.finditer(text):
        yield line_of(match.start()), "uncaptured"
    for match in CATCH_CAPTURE.finditer(text):
        name = match[1]
        handler = text[match.end() : handler_end(text, match.end())]
        if re.search(r"\b_\s*=\s*" + re.escape(name) + r"\s*;", handler):
            yield line_of(match.start()), "discarded"
        elif any(else_drops(handler[start:end], name) for start, end in switch_spans(handler, name)):
            # The switch subject is not a use. Any other reference means the cause flows.
            without_subjects = re.sub(r"\bswitch\s*\(\s*" + re.escape(name) + r"\s*\)", "", handler)
            if re.search(r"\b" + re.escape(name) + r"\b", without_subjects) is None:
                yield line_of(match.start()), "unchecked_else"


def returns_error(code):
    """Whether a `return` in `code` can return an error.

    `return;`, a literal, `null`, a function call, `try`, and `error.Reported` return no
    new error. Any other operand, such as the capture, `error.X`, `@as(T, err)`, an
    `if` or a `switch`, or a variable that holds an error, can.
    """
    for match in RETURN.finditer(code):
        operand = code[match.end() : handler_end(code, match.end())].strip()
        if operand and not NO_NEW_ERROR.match(operand):
            return True
    return False


def recorded_returns(lines):
    """The line of each handler that records a failure and then returns an error.

    A handler is the code after `catch |err|` or `errdefer |err|`. The scan leaves out
    the handlers of catches nested inside it, because those concern another failure.
    In a `switch (err)`, a prong that records and another prong that returns are not a
    record before a return. A record in an `errdefer` always comes before the return.
    """
    text, line_of = joined(lines)
    helpers = recording_helpers(text)
    for match in RECORDING_HANDLER.finditer(text):
        record = RECORD
        if helpers:
            record = re.compile(
                RECORD.pattern + r"|\b(?:" + "|".join(map(re.escape, helpers))
                + r")\s*\([^;{}]*\b" + re.escape(match[1]) + r"\b[^;{}]*\)"
            )
        handler = text[match.end() : handler_end(text, match.end())]
        own = ""
        index = 0
        for nested in NESTED_CATCH.finditer(handler):
            if nested.start() >= index:
                own += handler[index : nested.start()]
                index = handler_end(handler, nested.end())
        own += handler[index:]
        if match[0].startswith("errdefer"):
            if record.search(own):
                yield line_of(match.start())
            continue
        spans = []
        for start, end in switch_spans(own, match[1]):
            if not spans or start >= spans[-1][1]:
                spans.append((start, end))
        shared = own
        for start, end in reversed(spans):
            shared = shared[:start] + shared[end:]
        units = [shared + prong for start, end in spans for prong in prongs(own[start:end])] or [shared]
        if any(record.search(unit) and returns_error(unit) for unit in units):
            yield line_of(match.start())


def recording_helpers(text):
    helpers = {}
    for declaration in re.finditer(r"\bfn\s+(\w+)\s*\(", text):
        end = declaration.end()
        depth = 1
        while end < len(text) and depth:
            depth += text[end] in OPENS
            depth -= text[end] in CLOSES
            end += 1
        signature = re.match(r"\s*void\s*\{", text[end:])
        if signature:
            start = end + signature.end() - 1
            helpers[declaration[1]] = text[start:handler_end(text, start)]
    record = RECORD
    pending = dict(helpers)
    while pending:
        found = [name for name, body in pending.items() if record.search(body)]
        if not found:
            break
        record = re.compile(record.pattern + r"|\b(?:" + "|".join(map(re.escape, found)) + r")\s*\(")
        for name in found:
            del pending[name]
    return set(helpers) - set(pending)


class Ratchet(NamedTuple):
    baseline: str
    write_flag: str
    scan: Callable
    finding: str
    fix: str
    header: str


RATCHETS = (
    Ratchet(
        CATCH_BASELINE,
        "--write-catch-baseline",
        cause_drops,
        "`catch` sites drop their cause",
        "Name each dropped error in a switch prong with no `else`, or record the cause through a diagnostics.Handle or Presentation.reportFailure. "
        f"For an expected outcome, raise the count in {CATCH_BASELINE} in the same change and say why in the commit.",
        "Production `catch` sites that drop their cause (uncaptured, discarded, or unchecked `else`), per file. tools/check_diagnostics.py fails when a count changes.",
    ),
    Ratchet(
        RECORD_BASELINE,
        "--write-record-baseline",
        recorded_returns,
        "`catch` or `errdefer` handlers record a failure and then return an error",
        "Return `diagnostic.fail(phase, cause, @src())` on the diagnostics.Handle. It records once and returns error.Reported, which callers propagate with `try`. "
        "Otherwise return the error without recording it, so the boundary records it once.",
        "Production `catch` and `errdefer` handlers that record a failure and then return an error, per file. tools/check_diagnostics.py fails when a count changes.",
    ),
)


def counts(root, scan):
    """The number of findings of `scan` in the production code of each Zig file under src/."""
    found = {}
    for path, lines in zig_files(root, ("src",), literals=False):
        count = sum(1 for _ in scan(production(lines)))
        if count:
            found[str(path)] = count
    return found


def ratchet_changes(root, ratchet):
    """A file may not gain a finding, and a removed finding lowers the baseline."""
    baseline = count_baseline.read(root / ratchet.baseline)
    found_counts = counts(root, ratchet.scan)
    for name in sorted(set(baseline) | set(found_counts)):
        allowed = baseline.get(name, 0)
        found = found_counts.get(name, 0)
        if found > allowed:
            yield f"{name}: {found} {ratchet.finding}, {allowed} allowed. {ratchet.fix}"
        elif found < allowed:
            yield f"{name}: {found} {ratchet.finding}, {allowed} allowed. Lower the count in {ratchet.baseline} to {found}."


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
            cli_site = (
                str(path) in ("src/main.zig", "src/completion.zig")
                or str(path).startswith("src/api/")
                or (str(path) == "src/highlight/user_grammar.zig" and owner in ("validateQuery", "failTranslated"))
            )
            if cli_site:
                for call in re.finditer(r"\.\s*fail\s*\(", line):
                    if not line[:call.start()].endswith("bbr.cli_failure"):
                        yield (
                            f"{path}:{number}: use bbr.cli_failure.fail to record the cause, print its message, "
                            "record a failed stderr write once, and return error.Reported."
                        )
            if declaration and declaration[1].endswith("WithDiagnostics") and declaration[1] != "WithDiagnostics":
                base = declaration[1][: -len("WithDiagnostics")]
                yield (
                    f"{path}:{number}: do not add {declaration[1]} beside {base}. "
                    f"Give {base} a required diagnostics.Handle parameter, so no caller can drop it with a silent `.{{}}`."
                )
            if str(path) == "src/main.zig" and re.search(r"\bstd\.process\.exit\s*\(", line) and owner != "exitFailure":
                yield f"{path}:{number}: use exitFailure with the real cause and @src() before an error exit."
        if str(path) == CLIENT and (root / API_ERRORS).exists():
            names = api_error_names(root)
            if not names:
                yield f"{API_ERRORS}: declare `pub const ApiError = error{{ ... }}`, the client errors that {CLIENT} returns through `noted`."
            for number in unnoted_client_returns(production_lines, names) if names else ():
                yield (
                    f"{path}:{number}: return a client error through `noted(diagnostic, error.X, phase, cause)`. "
                    "It notes fresh evidence, so the boundary record does not take the evidence of an earlier failure."
                )
        if str(path) == "src/persist/sqlite_store.zig":
            for number in unwrapped_sqlite_results(production_lines):
                yield f"{path}:{number}: pass the SQLite result through SqliteStore.native before conversion or disposal."
    for ratchet in RATCHETS:
        yield from ratchet_changes(root, ratchet)
    for path, lines in zig_files(root, ("src",), literals=True):
        for number, line in enumerate(lines, 1):
            if "bbr-submit-response.log" in line:
                yield f"{path}:{number}: remove the unconditional Submission log. Use the opt-in diagnostic Sink."


def main():
    for ratchet in RATCHETS:
        if len(sys.argv) > 1 and sys.argv[1] == ratchet.write_flag:
            root = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parents[1]
            count_baseline.write(root / ratchet.baseline, ratchet.header, counts(root, ratchet.scan))
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
