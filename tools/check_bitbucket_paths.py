#!/usr/bin/env python3
"""Fail when Zig source builds a Bitbucket Repository or Workspace URL outside appendPath."""

from pathlib import Path
import re
import sys

ROOTS = ('"/repositories"', '"/workspaces"')
BUILDERS = ("pathUrl(", "appendPath(", "repositoryEndpoint(")
# A literal whose Workspace or Repository segment comes from outside it: a
# `{s}` placeholder, a trailing slash, or the bare root.
LITERAL = re.compile(r'"(?:\{s\}|https://api\.bitbucket\.org/2\.0)?/(?:repositories|workspaces)(?:/\{s\}[^"]*|/|)"')
TEST_START = re.compile(r"^test\b.*\{\s*$")
FIX = "Use repositoryEndpoint, pathUrl, or appendPath in src/bitbucket/client.zig, which percent-encode each segment and refuse a dot segment."


def violations(root):
    for path in sorted((root / "src").rglob("*.zig")):
        relative = path.relative_to(root)
        in_test = False
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if in_test:
                in_test = line != "}"
                continue
            if TEST_START.match(line):
                in_test = True
                continue
            for literal in LITERAL.findall(line):
                if literal in ROOTS and any(builder in line for builder in BUILDERS):
                    continue
                yield f"{relative}:{number}: builds a Bitbucket URL from {literal}. {FIX}"


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Every Bitbucket Repository and Workspace URL goes through appendPath.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
