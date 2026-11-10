#!/usr/bin/env python3
"""Fail when Zig source uses stdout() or stderr() other than through its one allowed form.

Only src/stdout.zig makes a stdout writer. Other code writes stdout through `bbr.stdout`, which
returns error.StdoutClosed when the reader closes the pipe. A stderr writer must be
`.writerStreaming(`. Elsewhere, stdout() and stderr() are allowed only as `.handle` on one side
of `==` or `!=`.

An alias such as `const out = stdout();`, or a File built from `stdout().handle`, could make a
writer out of sight of this check, so every other use fails. `zig fmt`, run by
`zig build test`, removes spaces inside the call chain.
"""

from pathlib import Path
import re
import sys

from source_lines import zig_files

OWNER = "src/stdout.zig"

# The patterns run over the whole file, so `\s` also matches the line breaks that zig fmt keeps
# after `==` and before a field access.
USE = re.compile(r"(?:\bstd\s*\.\s*Io\s*\.\s*File\s*\.\s*)?\b(stdout|stderr)\(\)(\s*\.\s*writerStreaming\(|\s*\.\s*handle\b)?")
COMPARISON_BEFORE = re.compile(r"[=!]=\s*$")
COMPARISON_AFTER = re.compile(r"\s*[=!]=")


def member(match):
    return (match.group(2) or "").replace(" ", "").replace("\n", "")


def handle_comparison(code, match):
    if member(match) != ".handle":
        return False
    return bool(COMPARISON_BEFORE.search(code, 0, match.start()) or COMPARISON_AFTER.match(code, match.end()))


def violations(root):
    for relative, lines in zig_files(root, ("src",), literals=False):
        owner = relative.as_posix() == OWNER
        code = "\n".join(lines)
        for match in USE.finditer(code):
            if handle_comparison(code, match):
                continue
            stream = match.group(1)
            if member(match) == ".writerStreaming(" and (stream == "stderr" or owner):
                continue
            number = code.count("\n", 0, match.start(1)) + 1
            if stream == "stdout" and not owner:
                yield (
                    f"{relative}:{number}: make no stdout writer here. Write stdout through "
                    f"bbr.stdout.write, bbr.stdout.print, or bbr.stdout.writeAll from {OWNER}. "
                    f"They return error.StdoutClosed when the reader closes the pipe, so bbr ends "
                    f"quietly after `bbr ... | head`. Use stdout() elsewhere only as stdout().handle "
                    f"in a == or != comparison."
                )
            else:
                yield (
                    f"{relative}:{number}: use {stream}() only as {stream}().writerStreaming( "
                    f"or as {stream}().handle in a == or != comparison. "
                    f"File.writer writes at absolute file offsets and overwrites a redirected file, "
                    f"and an alias or a File built from the handle hides such a writer from this check."
                )


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print(f"Only {OWNER} makes a stdout writer, and every stderr writer streams.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
