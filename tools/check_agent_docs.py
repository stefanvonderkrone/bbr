#!/usr/bin/env python3
"""Check local agent documentation and Markdown tracker metadata."""

from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

import count_baseline


TRIAGE = {"needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix"}
RESOLVED = {"resolved", "done", "completed"}
STATUSES = TRIAGE | RESOLVED | {"open", "claimed"}
TYPES = {"research", "prototype", "grilling", "task", "implementation"}
FIELD = re.compile(r"^(?:\*\*)?([\w ]+):(?:\*\*)?\s*(.*?)\s*$")
LINK = re.compile(r"\[[^\]\n]*\]\(([^)\n]+)\)")
REFERENCE = re.compile(r"^\s{0,3}\[(?!\^)[^\]\n]+\]:\s*(<[^>]+>|\S+)")
AGENTS_MD_CAP = 5000
COMPILE_CLAIM = re.compile(r"compile error|does not compile|do not compile|fails to compile")
# A mechanism that fails on the violation, not a type that only lacks a way to write it.
COMPILE_MECHANISM = re.compile(r"comptime|exhaustive switch|@compileError|tests/\w+_test\.(?:py|sh)")
COMPILE_CLAIM_BASELINE = "tools/compile_claim_baseline.txt"
SENTENCE_END = re.compile(r"(?<=[.)])\s+(?=[A-Z`\"])")


def unbacked_compile_claims(text):
    """The line of each Enforcement sentence that claims a compile error and names no mechanism that fails."""
    lines = []
    for paragraph in enforcement_paragraphs(text):
        starts, joined = [], ""
        for number, line in paragraph:
            starts.append((len(joined), number))
            joined += line.strip() + " "
        sentences = []
        begin = 0
        for boundary in [*SENTENCE_END.finditer(joined), None]:
            end = boundary.start() if boundary else len(joined)
            sentence = joined[begin:end]
            # "Its compile error ..." continues the sentence that names the mechanism.
            if sentences and re.match(r"(?:Its|Their) ", sentence):
                sentences[-1][1] += " " + sentence
            else:
                sentences.append([begin, sentence])
            begin = boundary.end() if boundary else end
        for offset, sentence in sentences:
            if COMPILE_CLAIM.search(sentence) and not COMPILE_MECHANISM.search(sentence):
                lines.append(max(number for start, number in starts if start <= offset))
    return lines


def enforcement_paragraphs(text):
    """Each Enforcement paragraph outside fenced examples, as its numbered lines."""
    paragraph = None
    for number, line in enumerate(prose(text, inline_code=True), 1):
        if not line.strip():
            if paragraph:
                yield paragraph
            paragraph = None
        elif paragraph is not None:
            paragraph.append((number, line))
        elif line.startswith("Enforcement:"):
            paragraph = [(number, line)]
    if paragraph:
        yield paragraph


def prose(text, inline_code=False):
    """Exclude fenced examples, and inline code unless inline_code, from Markdown text."""
    fence = None
    for line in text.splitlines():
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if match:
            marker = match[1]
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            yield ""
        elif fence is None:
            yield line if inline_code else re.sub(r"(`+).*?\1", "", line)
        else:
            yield ""


def metadata(text):
    """Read the header fields before the first level-two heading."""
    fields = {}
    for line in text.splitlines():
        if line.startswith("## "):
            break
        match = FIELD.match(line)
        if match:
            fields[match[1].lower()] = match[2]
    return fields


def blocker_text(text, fields):
    if "blocked by" in fields:
        return fields["blocked by"]
    match = re.search(r"^## Blocked by\s*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match[1].strip() if match else None


def check(root):
    root = root.resolve()
    errors = []

    def error(path, message):
        errors.append(f"{path.relative_to(root)}: {message}")

    agents = root / "AGENTS.md"
    if agents.is_file() and agents.stat().st_size > AGENTS_MD_CAP:
        areas = ", ".join(str(path.relative_to(root)) for path in sorted(root.glob("docs/rules/*.md")))
        error(agents, f"{agents.stat().st_size:,} bytes, above the cap of {AGENTS_MD_CAP:,}. "
              "Every session loads AGENTS.md, so it holds only pointer lines. "
              f"Put the rule in its area doc ({areas or 'docs/rules/'}) or, "
              "when no check enforces it, in CODING_STANDARDS.md")

    baseline = count_baseline.read(root / COMPILE_CLAIM_BASELINE)
    for path in sorted(root.glob("docs/rules/*.md")):
        name = str(path.relative_to(root))
        claims = unbacked_compile_claims(path.read_text())
        allowed = baseline.get(name, 0)
        if len(claims) > allowed:
            error(path, f"lines {', '.join(map(str, claims))}: {len(claims)} Enforcement sentences claim a compile error "
                  f"without a mechanism that fails, and {COMPILE_CLAIM_BASELINE} allows {allowed}. "
                  "A type that lacks a field, an error union, or a mutable pointer stops nothing that a catch, "
                  "a new field, or a cast adds. Name the `comptime` assertion, the exhaustive switch, the @compileError, "
                  "or the tests/*_test.py that compiles the violation, or name the behavior test that fails. "
                  "See docs/agents/rule-areas.md#write-a-rule-section")
        elif len(claims) < allowed:
            error(path, f"{len(claims)} Enforcement sentences claim a compile error without a mechanism. "
                  f"Lower its count in {COMPILE_CLAIM_BASELINE} to {len(claims)}")
    for name in sorted(set(baseline) - {str(path.relative_to(root)) for path in root.glob("docs/rules/*.md")}):
        error(root / COMPILE_CLAIM_BASELINE, f"{name} is not a rule area doc. Remove its line")

    adrs = {}
    for path in sorted(root.glob("docs/adr/*.md")):
        number = re.match(r"(\d+)-", path.name)
        if not number:
            continue
        key = int(number[1])
        if key in adrs:
            error(path, f"ADR number {number[1]} is also used by {adrs[key].name}. "
                  "Give the newer ADR the next free number and update its links. "
                  "This check only sees one tree, so two branches that add the same number "
                  "fail only after the merge")
        else:
            adrs[key] = path

    documents = {root / "AGENTS.md", root / "GLOSSARY-MAP.md", root / "docs/code-navigation.md"}
    for pattern in ("docs/agents/*.md", "docs/rules/*.md", "CODING_STANDARDS.md", "src/**/GLOSSARY.md", "src/**/IMPLEMENTATION.md",
                    ".scratch/**/*.md", ".agents/skills/**/*.md"):
        documents.update(root.glob(pattern))
    for path in sorted(documents):
        if not path.is_file():
            error(path, "missing agent document")
            continue
        for number, line in enumerate(prose(path.read_text()), 1):
            targets = [match[1] for match in LINK.finditer(line)]
            reference = REFERENCE.match(line)
            if reference:
                targets.append(reference[1])
            for target in targets:
                target = target.strip()
                if target.startswith("<"):
                    target = target[1:].split(">", 1)[0]
                else:
                    target = target.split()[0] if target else ""
                url = urlsplit(target)
                if not url.scheme and not url.netloc and url.path:
                    destination = path.parent / unquote(url.path)
                    if not destination.exists():
                        error(path, f"line {number}: broken link {target}")

    tickets = {}
    groups = {}
    for path in sorted(root.glob(".scratch/*/issues/*.md")):
        text = path.read_text()
        fields = metadata(text)
        status = fields.get("status")
        if status not in STATUSES:
            error(path, f"invalid or missing Status: {status!r}")
        kind = fields.get("type")
        if kind is not None and kind not in TYPES:
            error(path, f"invalid Type: {kind!r}")
        match = re.match(r"(\d+)-", path.name)
        if not match:
            error(path, "ticket filename must start with a number and a hyphen")
            continue
        number = int(match[1])
        group = groups.setdefault(path.parent, {})
        if number in group:
            error(path, f"duplicate ticket number {number}")
        group[number] = path
        blockers = blocker_text(text, fields)
        dependencies = []
        if blockers is None or not blockers.strip():
            error(path, "missing Blocked by field or section")
        elif not re.fullmatch(r"none\.?|none\s*(?:[-—:]\s*|\()can start immediately\)?\.?", blockers, re.I):
            # Both comma-separated IDs and semicolon-separated titled IDs occur in the tracker.
            for item in re.split(r"[,;\n]+|\.\s+(?=\[?\d+\b)", blockers):
                item = item.strip().lstrip("-* ")
                if not item:
                    continue
                dependency = re.match(r"\[?(\d+)\b", item)
                if not dependency:
                    error(path, f"invalid blocker: {item!r}")
                else:
                    dependencies.append(int(dependency[1]))
        tickets[path] = (fields, dependencies)

    graph = {}
    for path, (fields, dependencies) in tickets.items():
        group = groups[path.parent]
        graph[path] = []
        for number in dependencies:
            if number not in group:
                error(path, f"missing blocker {number:02}")
            else:
                graph[path].append(group[number])

    visited = set()
    active = set()

    def visit(path):
        if path in active:
            error(path, "dependency cycle")
            return
        if path in visited:
            return
        active.add(path)
        for dependency in graph[path]:
            visit(dependency)
        active.remove(path)
        visited.add(path)

    for path in graph:
        visit(path)

    for pattern in (".scratch/*/SPEC.md", ".scratch/*/PRD.md"):
        for path in sorted(root.glob(pattern)):
            fields = metadata(path.read_text())
            status = fields.get("status")
            if status not in STATUSES:
                error(path, f"invalid or missing Status: {status!r}")
            directory = path.parent / fields.get("implementation directory", ".")
            if not directory.is_dir():
                error(path, "Implementation directory does not exist")
                continue
            implementation = [data for ticket, data in tickets.items()
                              if ticket.parent.resolve() == (directory / "issues").resolve()
                              and data[0].get("type") in (None, "implementation")]
            if implementation:
                complete = all(data[0].get("status") in RESOLVED for data in implementation)
                if complete and status not in RESOLVED | {"claimed"}:
                    error(path, "all implementation tickets resolved, but spec is still open")
                elif not complete and status in RESOLVED:
                    error(path, "resolved spec has unfinished implementation tickets")
    return errors


if __name__ == "__main__":
    failures = check(Path(__file__).resolve().parents[1])
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(1)
    print("Agent documents and tracker metadata pass.")
