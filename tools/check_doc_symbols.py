#!/usr/bin/env python3
from pathlib import Path
import re
import sys

from source_lines import zig_files

IDENTIFIER = re.compile(r"[A-Za-z_]\w*")
SYMBOL = re.compile(r"`([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)(?:\(\))?`")
CONTAINER = re.compile(
    r"\b(?:const|var)\s+([A-Za-z_]\w*)\s*(?::\s*type\s*)?=\s*"
    r"(?:(?:extern|packed)\s+)?(?:struct|union|enum)\b[^{]*\{"
)
FILE_EXTENSIONS = {
    "zig", "md", "py", "json", "toml", "zon", "txt", "sh",
    "html", "yml", "yaml", "c", "h", "cc", "scm",
}
EXTERNAL_MODULES = {"std", "vaxis", "zf", "c"}
STEP_QUOTE = r'"[^"\n]*"'
QUOTED = re.compile(
    rf"\b[Ss]tep {STEP_QUOTE}|\b[Ss]teps {STEP_QUOTE}(?:(?:,|,? and|,? or) {STEP_QUOTE})*"
    r'|"([^"\n]+)"'
    r"|((?<!\w)'[^'\n]+'(?!\w)|\u2018[^\u2019\n]+\u2019|\u201c[^\u201d\n]+\u201d)"
)
SENTENCE_END = re.compile(r"[.!?]\s")
ZIG_FILE = re.compile(r"\bin `([^`\n]+\.zig)`")
CODE_SPAN = re.compile(r"`[^`\n]*`")
TEST_DECLARATION = re.compile(r'^\s*test\s+"((?:[^"\\]|\\.)*)"')
ZIG_ESCAPE = re.compile(r"\\(.)")


def source_names(root):
    identifiers = set()
    containers = {}
    for _, lines in zig_files(root, ("src",), literals=False):
        source = "\n".join(lines)
        identifiers.update(IDENTIFIER.findall(source))
        for match in CONTAINER.finditer(source):
            depth = 1
            end = match.end()
            while depth and end < len(source):
                depth += {"{": 1, "}": -1}.get(source[end], 0)
                end += 1
            containers.setdefault(match[1], set()).update(
                IDENTIFIER.findall(source[match.end():end])
            )
    return identifiers, containers


def markdown_lines(path):
    with path.open(encoding="utf-8") as document:
        yield from enumerate(document, 1)


def zig_string(text):
    r"""The Zig string literal body `text` with each `\\` and `\"` escape decoded."""
    return ZIG_ESCAPE.sub(lambda escape: escape[1], text)


def test_names(root, file):
    return {
        zig_string(match[1])
        for _, lines in zig_files(root, (file,), literals=True)
        for line in lines
        if (match := TEST_DECLARATION.match(line))
    }


def enforcement_test_violations(root, path, paragraph, tests):
    """Each quoted test name of an Enforcement paragraph without that test in its named file.

    `tests` caches the test names of each Zig file.
    """
    starts, text = [], ""
    for number, line in paragraph:
        starts.append((len(text), number))
        text += line.strip() + " "
    prose = CODE_SPAN.sub(lambda span: "x" * len(span[0]), text)
    bare = QUOTED.sub(lambda quote: " " * len(quote[0]), prose)
    ends = [end.end() for end in SENTENCE_END.finditer(bare)]
    code_span = "If the quote is not a test name, write it as a code span."
    for match in QUOTED.finditer(prose):
        if match[1] is None and match[2] is None:
            continue
        number = max(line for start, line in starts if start <= match.start())
        location = f"{path.relative_to(root)}:{number}"
        if match[2]:
            yield f"{location}: the quote {text[match.start(2):match.end(2)]} is not in double quotes. Write a test name in double quotes. {code_span}"
            continue
        name = text[match.start(1):match.end(1)]
        sentence_end = min((end for end in ends if end >= match.end()), default=len(text))
        file = ZIG_FILE.search(text, match.end(), sentence_end) or (
            [None] + list(ZIG_FILE.finditer(text, 0, match.start()))
        )[-1]
        if file is None:
            yield f'{location}: the test "{name}" names no file. Add "in `<file>.zig`" to its sentence or to a sentence before it. {code_span}'
            continue
        if not (root / file[1]).is_file():
            yield f'{location}: the test "{name}" names the missing file {file[1]}. Name the file that holds the test. {code_span}'
            continue
        if file[1] not in tests:
            tests[file[1]] = test_names(root, file[1])
        if name not in tests[file[1]]:
            yield (
                f'{location}: {file[1]} has no test "{name}". '
                f"Point the Enforcement paragraph at an existing test, or restore the test. {code_span}"
            )


def violations(root):
    identifiers, containers = source_names(root)
    documents = [root / "AGENTS.md", root / "CODING_STANDARDS.md"]
    rules = sorted((root / "docs/rules").glob("*.md"))
    if not rules:
        yield "docs/rules/*.md: no rule documents found. Restore docs/rules/, or update the document list in tools/check_doc_symbols.py."
    documents.extend(rules)
    tests = {}
    for path in documents:
        if not path.is_file():
            yield f"{path.relative_to(root)}: the document is missing. Restore it, or update the document list in tools/check_doc_symbols.py."
            continue
        fence = None
        paragraph = None
        for number, line in markdown_lines(path):
            marker = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", line)
            if paragraph and not line.strip():
                yield from enforcement_test_violations(root, path, paragraph, tests)
                paragraph = None
            if marker:
                run, rest = marker.groups()
                if fence is None:
                    fence = run
                elif run[0] == fence[0] and len(run) >= len(fence) and not rest.strip():
                    fence = None
                continue
            if fence is not None:
                continue
            if paragraph is not None:
                paragraph.append((number, line))
            elif path in rules and line.startswith("Enforcement:"):
                paragraph = [(number, line)]
            for match in SYMBOL.finditer(line):
                name = match[1]
                parts = name.split(".")
                if name == "error.X":
                    continue
                if parts[-1] in FILE_EXTENSIONS or parts[0] in EXTERNAL_MODULES:
                    continue
                if parts[0] in {"bbr", "tui"}:
                    parts = parts[1:]
                missing = any(part not in identifiers for part in parts)
                if len(parts) >= 2 and parts[-2] in containers:
                    missing |= parts[-1] not in containers[parts[-2]]
                if missing:
                    yield (
                        f"{path.relative_to(root)}:{number}: `{name}` names no current symbol. "
                        "rename it to the current symbol, or remove it."
                    )
        if paragraph:
            yield from enforcement_test_violations(root, path, paragraph, tests)


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Rule document code names match the Zig source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
