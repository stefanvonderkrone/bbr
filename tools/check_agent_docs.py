#!/usr/bin/env python3
"""Check local agent documentation and Markdown tracker metadata."""

from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


TRIAGE = {"needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix"}
RESOLVED = {"resolved", "done", "completed"}
STATUSES = TRIAGE | RESOLVED | {"open", "claimed"}
TYPES = {"research", "prototype", "grilling", "task", "implementation"}
FIELD = re.compile(r"^(?:\*\*)?([\w ]+):(?:\*\*)?\s*(.*?)\s*$")
LINK = re.compile(r"\[[^\]\n]*\]\(([^)\n]+)\)")
REFERENCE = re.compile(r"^\s{0,3}\[(?!\^)[^\]\n]+\]:\s*(<[^>]+>|\S+)")
PULL_REQUEST = re.compile(r"(?<![\w&/#])#(\d+)\b|pull-?requests/(\d+)", re.I)
# Commands and file names often sit in code, so these forms count in code too.
PULL_REQUEST_COMMAND = re.compile(r"pr-webapp`?\s+#?(\d+)\b|\bremote\s+[\w.-]+\s+(\d+)\b")
# Public PullRequest ids that a .scratch file may name, with the reason.
PUBLIC_PULL_REQUESTS = {
    (".scratch/m23-comment-thread-markdown-presentation-implementation", "2425"):
        "the agreed M23 test PullRequest for published evidence",
    (".scratch/m26-credential-login-logout/issues/13-docs-and-completion-evidence.md", "12"):
        "a pull request of the public bbr GitHub repository",
    (".scratch/error-handling-discipline", "19"):
        "a pull request of the public bbr GitHub repository",
    (".scratch/error-handling-discipline", "22"):
        "a pull request of the public bbr GitHub repository",
    (".scratch/error-handling-discipline", "2647"):
        "an issue of the public Zig repository",
    ("docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md", "2647"):
        "an issue of the public Zig repository",
}


def prose(text):
    """Exclude fenced examples and inline code from link checks."""
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
            yield re.sub(r"(`+).*?\1", "", line)
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

    documents = {root / "AGENTS.md", root / "GLOSSARY-MAP.md", root / "docs/code-navigation.md"}
    for pattern in ("docs/agents/*.md", "docs/adr/*.md", "src/**/GLOSSARY.md", "src/**/IMPLEMENTATION.md",
                    ".scratch/**/*.md", ".agents/skills/**/*.md"):
        documents.update(root.glob(pattern))
    for path in sorted(documents):
        if not path.is_file():
            error(path, "missing agent document")
            continue
        text = path.read_text()
        # An ADR records benchmark evidence, so it gets the same check as the tracker.
        if path.is_relative_to(root / ".scratch") or path.is_relative_to(root / "docs/adr"):
            for number, (line, raw) in enumerate(zip(prose(text), text.splitlines()), 1):
                matches = [*PULL_REQUEST.finditer(line), *PULL_REQUEST_COMMAND.finditer(raw)]
                for match in matches:
                    if not any(path.is_relative_to(root / prefix) and (match[1] or match[2]) == public
                               for prefix, public in PUBLIC_PULL_REQUESTS):
                        error(path, f"line {number}: names the live PullRequest {match[0]}. "
                              "Keep live PullRequest ids and their statistics in a local file "
                              "outside the repository, such as pullrequests.txt next to the repository checkout")
        for number, line in enumerate(prose(text), 1):
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
