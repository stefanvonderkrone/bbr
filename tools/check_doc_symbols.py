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


def violations(root):
    identifiers, containers = source_names(root)
    documents = [root / "AGENTS.md", root / "CODING_STANDARDS.md"]
    rules = sorted((root / "docs/rules").glob("*.md"))
    if not rules:
        yield "docs/rules/*.md: no rule documents found. Restore docs/rules/, or update the document list in tools/check_doc_symbols.py."
    documents.extend(rules)
    for path in documents:
        if not path.is_file():
            yield f"{path.relative_to(root)}: the document is missing. Restore it, or update the document list in tools/check_doc_symbols.py."
            continue
        fence = None
        for number, line in markdown_lines(path):
            marker = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", line)
            if marker:
                run, rest = marker.groups()
                if fence is None:
                    fence = run
                elif run[0] == fence[0] and len(run) >= len(fence) and not rest.strip():
                    fence = None
                continue
            if fence is not None:
                continue
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
