#!/usr/bin/env python3
"""Write THIRD_PARTY_NOTICES with the licence of every vendored component that bbr links.

Usage: third_party_notices.py <repository root> <output file>

The vendored manifests are the source of truth. Every BuiltInGrammar must list one LICENSE file.
A missing licence stops the script and writes no output.
"""

from pathlib import Path
import sys

from check_vendored_grammars import MANIFEST, VENDOR, ZonError, load_manifest, parse_zon

REGEX_MANIFEST = Path("vendors/regex-manifest.zig.zon")
RULE = "=" * 80
HEADER = """Third-party notices for bbr

The bbr binary includes the third-party software below.
Each section names a component, its source, and its licence text.
"""


class NoticeError(Exception):
    pass


def _source(entry):
    revision = entry.get("tag") or entry.get("release")
    commit = entry.get("commit") or entry.get("revision")
    pin = ", ".join(part for part in (revision, f"commit {commit}" if commit else None) if part)
    return f"{entry['repository']} ({pin})" if pin else entry["repository"]


def notices(root):
    """The (component, source, licence path) triples, with paths relative to root."""
    manifest = load_manifest(root)
    regex = parse_zon((root / REGEX_MANIFEST).read_text(encoding="utf-8"))
    found = [
        ("tree-sitter runtime", _source(manifest["runtime"]), VENDOR / "runtime/LICENSE"),
        ("nvim-treesitter queries", _source(manifest["nvim_treesitter"]), VENDOR / "nvim-treesitter/LICENSE"),
        ("RE2", _source(regex["re2"]), Path("vendors/re2/LICENSE")),
        ("Abseil", _source(regex["abseil"]), Path("vendors/abseil/LICENSE")),
    ]
    for key, entry in manifest["grammars"].items():
        licences = [file["path"] for file in entry["files"] if Path(file["path"]).name == "LICENSE"]
        if len(licences) != 1:
            raise NoticeError(f"{MANIFEST}: .{key}.files lists no LICENSE or more than one")
        found.append((f"{entry['name']} Grammar", _source(entry), VENDOR / licences[0]))
    return found


def render(root):
    sections = [HEADER]
    for component, source, path in notices(root):
        try:
            text = (root / path).read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            raise NoticeError(f"{path}: licence file is missing") from None
        sections.append(f"{RULE}\n{component}\nSource: {source}\nFile: {path}\n{RULE}\n\n{text}\n")
    return "\n".join(sections)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: third_party_notices.py <repository root> <output file>")
    root, output = Path(sys.argv[1]), Path(sys.argv[2])
    try:
        text = render(root)
    except (NoticeError, ZonError, KeyError, OSError) as error:
        sys.exit(f"third_party_notices: {error}")
    output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
