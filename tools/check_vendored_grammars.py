#!/usr/bin/env python3
"""Fail when vendors/tree-sitter differs from vendors/tree-sitter/manifest.zig.zon.

Every vendored Grammar file must have its manifest checksum, and every adapted query must equal a
new adaptation of the raw nvim-treesitter queries.
"""

import hashlib
from pathlib import Path
import re
import sys

import adapt_queries

VENDOR = Path("vendors/tree-sitter")
MANIFEST = VENDOR / "manifest.zig.zon"
RAW_QUERIES = "nvim-treesitter/queries"
# Directories that hold no Grammar. Files in a shared directory belong to one or more Grammars.
RUNTIME = "runtime"
SHARED = ("nvim-treesitter", "common")
UNLISTED = frozenset({"README.md", "manifest.zig.zon", "nvim-treesitter/LICENSE"})


class ZonError(Exception):
    pass


class EnumLiteral(str):
    """A ZON enum literal, such as `.upstream`, kept apart from a string."""


_ZON_TOKEN = re.compile(
    r'\s+|//[^\n]*|(?P<string>"(?:[^"\\\n]|\\.)*")|(?P<number>-?\d+)|(?P<word>[A-Za-z_][A-Za-z0-9_]*)|(?P<punct>\.\{|[.{}=,])'
)


def _zon_tokens(text):
    position = 0
    while position < len(text):
        match = _ZON_TOKEN.match(text, position)
        if match is None:
            raise ZonError(f"unexpected ZON text at byte {position}: {text[position:position + 20]!r}")
        position = match.end()
        for kind in ("string", "number", "word", "punct"):
            if match.group(kind) is not None:
                yield kind, match.group(kind)


_ZON_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\"}


def _zon_string(literal):
    return re.sub(
        r"\\(x[0-9a-fA-F]{2}|.)",
        lambda m: chr(int(m.group(1)[1:], 16)) if len(m.group(1)) == 3 else _ZON_ESCAPES[m.group(1)],
        literal[1:-1],
    )


def parse_zon(text):
    """Parse the ZON subset of the manifest: anonymous structs, tuples, strings, integers, null, and enum literals.

    A struct becomes a dict, a tuple becomes a list, and an empty `.{}` becomes an empty list.
    """
    tokens = list(_zon_tokens(text))
    position = 0

    def take(expected=None):
        nonlocal position
        if position >= len(tokens):
            raise ZonError("unexpected end of ZON")
        token = tokens[position]
        if expected is not None and token[1] != expected:
            raise ZonError(f"expected {expected!r}, found {token[1]!r}")
        position += 1
        return token

    def value():
        kind, text = take()
        if kind == "string":
            return _zon_string(text)
        if kind == "number":
            return int(text)
        if kind == "word" and text in ("null", "true", "false"):
            return {"null": None, "true": True, "false": False}[text]
        if text == ".{":
            return aggregate()
        if text == ".":
            return EnumLiteral(take()[1])
        raise ZonError(f"unexpected ZON token {text!r}")

    def aggregate():
        nonlocal position
        fields, items = {}, []
        while tokens[position][1] != "}":
            if tokens[position][1] == "." and tokens[position + 2][1] == "=":
                name = tokens[position + 1][1]
                position += 3
                if name in fields:
                    raise ZonError(f"duplicate ZON field .{name}")
                fields[name] = value()
            else:
                items.append(value())
            if tokens[position][1] != "}":
                take(",")
        take("}")
        if fields and items:
            raise ZonError("a ZON value mixes fields and tuple items")
        return fields if fields else items

    result = value()
    if position != len(tokens):
        raise ZonError("trailing ZON text")
    return result


def load_manifest(root):
    return parse_zon((root / MANIFEST).read_text(encoding="utf-8"))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def query_kinds(entry):
    return [kind for kind in adapt_queries.KINDS if entry[kind] is not None]


def raw_query_paths(name, kind, raw_root):
    """The raw query files that the adaptation of name/kind reads, relative to vendors/tree-sitter."""
    return [f"{RAW_QUERIES}/{source}/{kind}.scm" for source, _ in adapt_queries.sources(name, kind, raw_root)]


def violations(root):
    vendor = root / VENDOR
    manifest = load_manifest(root)
    grammars = manifest["grammars"]
    runtime = manifest["runtime"]
    if sha256(vendor / RUNTIME / "src/lib.c") != runtime["lib_c_sha256"]:
        yield f"{VENDOR}/{RUNTIME}/src/lib.c: checksum differs from .runtime.lib_c_sha256"

    for directory in sorted(path.name for path in vendor.iterdir() if path.is_dir()):
        if directory not in grammars and directory not in SHARED and directory != RUNTIME:
            yield f"{VENDOR}/{directory}: directory has no manifest entry"

    listed = {}
    for name, entry in grammars.items():
        if not (vendor / name).is_dir():
            yield f"{VENDOR}/{name}: manifest entry .{name} has no directory"
            continue
        paths = [file["path"] for file in entry["files"]]
        if len(paths) != len(set(paths)):
            yield f"{MANIFEST}: .{name}.files lists a path twice"
        for file in entry["files"]:
            path = file["path"]
            listed.setdefault(path, []).append(name)
            if not (path.startswith(f"{name}/") or path.split("/", 1)[0] in SHARED):
                yield f"{MANIFEST}: .{name}.files path {path} is outside {name}/ and the shared directories"
            elif not (vendor / path).is_file():
                yield f"{VENDOR}/{path}: file in .{name}.files is missing"
            elif sha256(vendor / path) != file["sha256"]:
                yield f"{VENDOR}/{path}: checksum differs from .{name}.files"
        for path in [*entry["sources"], *(entry[field] for field in ("highlights", "injections", "locals") if entry[field] is not None)]:
            if path not in paths:
                yield f"{MANIFEST}: .{name} uses {path}, which is not in .{name}.files"
        if entry["query_source"] == "nvim_treesitter":
            yield from adapted_query_violations(vendor, manifest, name, entry, paths)

    for path in sorted(p.relative_to(vendor).as_posix() for p in vendor.rglob("*") if p.is_file()):
        top = path.split("/", 1)[0]
        if top == RUNTIME or path in UNLISTED:
            continue
        owners = listed.get(path, [])
        if top in grammars and top not in owners:
            yield f"{VENDOR}/{path}: file is not in .{top}.files"
        elif top in SHARED and not owners:
            yield f"{VENDOR}/{path}: shared file is in no .files list"


def adapted_query_violations(vendor, manifest, name, entry, paths):
    raw_root = vendor / RAW_QUERIES
    commit = manifest["nvim_treesitter"]["commit"]
    builtin_names = frozenset(manifest["grammars"])
    expected_raw = set()
    for kind in query_kinds(entry):
        target = vendor / entry[kind]
        try:
            expected_raw.update(raw_query_paths(name, kind, raw_root))
            adapted = adapt_queries.adapt(name, kind, raw_root, commit, builtin_names)
        except adapt_queries.AdaptError as error:
            yield f"{VENDOR}/{entry[kind]}: adaptation fails: {error}"
            continue
        if target.is_file() and target.read_bytes() != adapted.encode("utf-8"):
            yield f"{VENDOR}/{entry[kind]}: adapted query differs from a new adaptation, rerun tools/vendor_grammar.py"
    listed_raw = {path for path in paths if path.startswith(f"{RAW_QUERIES}/")}
    for path in sorted(expected_raw - listed_raw):
        yield f"{MANIFEST}: .{name}.files does not list the raw query {path}"
    for path in sorted(listed_raw - expected_raw):
        yield f"{MANIFEST}: .{name}.files lists the raw query {path}, which its adaptation does not read"


def main():
    if len(sys.argv) != 2:
        print("usage: check_vendored_grammars.py REPOSITORY_ROOT", file=sys.stderr)
        return 2
    try:
        found = list(violations(Path(sys.argv[1])))
    except (OSError, KeyError, ZonError) as error:
        found = [f"{MANIFEST}: cannot check the manifest: {error!r}"]
    for violation in found:
        print(violation, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
