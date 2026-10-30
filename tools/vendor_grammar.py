#!/usr/bin/env python3
"""Vendor one nvim-treesitter BuiltInGrammar into vendors/tree-sitter and print its manifest entry.

The tool uses no network. Clone nvim-treesitter at the manifest commit and the Grammar repository
at the revision that parsers.lua names, then pass both checkouts. The tool replaces
vendors/tree-sitter/<name>/, copies the raw queries, writes the adapted queries, and prints the
entry for vendors/tree-sitter/manifest.zig.zon. A rerun with the same inputs writes the same files.
"""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import adapt_queries
import check_vendored_grammars as check

GENERATE = ("generate", "--abi", "15")
MANIFEST_END = "    },\n}\n"
INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
LANGUAGE_VERSION = re.compile(r"^#define LANGUAGE_VERSION (\d+)$", re.M)
LANGUAGE_FUNCTION = re.compile(r"\bconst TSLanguage \*(tree_sitter_\w+)\(void\)\s*\{")


class VendorError(Exception):
    pass


def parsers_entry(nvim_root, name):
    """Return the install_info fields and the requires list of one parsers.lua entry."""
    text = (nvim_root / "lua/nvim-treesitter/parsers.lua").read_text(encoding="utf-8")
    block = re.search(rf"^  {re.escape(name)} = \{{\n(.*?)^  \}},$", text, re.M | re.S)
    if block is None:
        raise VendorError(f"parsers.lua has no entry {name}")
    info = re.search(r"^    install_info = \{\n(.*?)^    \},$", block.group(1), re.M | re.S)
    if info is None:
        raise VendorError(f"parsers.lua entry {name} has no install_info")
    fields = dict(re.findall(r"^      (\w+) = '([^']*)',$", info.group(1), re.M))
    fields.update((key, value == "true") for key, value in re.findall(r"^      (\w+) = (true|false),$", info.group(1), re.M))
    requires = re.search(r"^    requires = \{([^}]*)\},$", block.group(1), re.M)
    fields["requires"] = re.findall(r"'([^']+)'", requires.group(1)) if requires else []
    return fields


def git(checkout, *arguments):
    result = subprocess.run(["git", "-C", str(checkout), *arguments], capture_output=True, text=True)
    if result.returncode != 0:
        raise VendorError(f"git {' '.join(arguments)} in {checkout} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def pinned_commit(checkout, revision):
    """Resolve the revision, a commit or a tag, and require the checkout to be at it."""
    commit = git(checkout, "rev-parse", "--verify", f"{revision}^{{commit}}")
    head = git(checkout, "rev-parse", "HEAD")
    if head != commit:
        raise VendorError(f"{checkout} is at {head}, but the pin {revision} is {commit}")
    return commit


def include_closure(repository, sources, include_dirs):
    """Return the sources and every file that they include with quotes, as repository-relative paths.

    The compiler looks up a quoted include next to the including file, then in each include
    directory. `addTreeSitter` in build.zig adds the directory of each compiled source.
    """
    repository = repository.resolve()
    seen, pending = set(), [source.resolve() for source in sources]
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        for include in INCLUDE.findall(path.read_text(encoding="utf-8", errors="replace")):
            candidates = [(directory / include).resolve() for directory in [path.parent, *include_dirs]]
            target = next((candidate for candidate in candidates if candidate.is_file()), None)
            if target is None:
                raise VendorError(f"{path.relative_to(repository)} includes {include}, which does not exist")
            if not target.is_relative_to(repository):
                raise VendorError(f"{path.relative_to(repository)} includes {include}, which leaves the repository")
            pending.append(target)
    return sorted(path.relative_to(repository) for path in seen)


def generate(grammar_root, cli, cli_version):
    """Run the pinned tree-sitter CLI in a temporary copy of the checkout and return the .generated record."""
    version = subprocess.run([cli, "--version"], capture_output=True, text=True, check=True).stdout.split()
    if version[:2] != ["tree-sitter", cli_version]:
        raise VendorError(f"{cli} is {' '.join(version)}, but the manifest pins tree-sitter {cli_version}")
    node = subprocess.run(["node", "--version"], capture_output=True, text=True, check=True).stdout.strip()
    result = subprocess.run([cli, *GENERATE], cwd=grammar_root, capture_output=True, text=True)
    if result.returncode != 0:
        raise VendorError(f"tree-sitter {' '.join(GENERATE)} failed in a copy of the Grammar checkout. Install its npm packages in the checkout first.\n{result.stderr}")
    return {"cli": cli_version, "command": f"tree-sitter {' '.join(GENERATE)}", "js_runtime": f"node {node}"}


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def vendor(nvim_root, repository, name, repo_root, *, display_name, matches, injections, cli):
    vendor_root = repo_root / check.VENDOR
    manifest = check.load_manifest(repo_root)
    nvim_commit = git(nvim_root, "rev-parse", "HEAD")
    if nvim_commit != manifest["nvim_treesitter"]["commit"]:
        raise VendorError(f"nvim-treesitter is at {nvim_commit}, but the manifest pins {manifest['nvim_treesitter']['commit']}")
    previous = manifest["grammars"].get(name)
    if display_name is None:
        display_name = previous["name"] if previous else None
    if display_name is None:
        raise VendorError(f"{name} is a new BuiltInGrammar, so it needs --display-name")
    if previous is not None:
        matches = {kind: matches[kind] if matches[kind] is not None else previous["matches"][kind] for kind in matches}
    matches = {kind: values or [] for kind, values in matches.items()}
    injections = injections or (previous is not None and previous["injections"] is not None)

    info = parsers_entry(nvim_root, name)
    commit = pinned_commit(repository, info["revision"])
    location = info.get("location")
    grammar_root = repository / location if location else repository
    if not (repository / "LICENSE").is_file():
        raise VendorError(f"{repository} has no LICENSE file at {commit}")
    generated = None
    scratch = tempfile.TemporaryDirectory()
    if info.get("generate") is True or not (grammar_root / "src/parser.c").is_file():
        # Generation writes into src/, so it runs in a copy and leaves the given checkout unchanged.
        copy_root = Path(scratch.name) / "repository"
        shutil.copytree(repository, copy_root, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        repository = copy_root
        grammar_root = repository / location if location else repository
        generated = generate(grammar_root, cli, manifest["tree_sitter_cli"]["version"])
    sources = [grammar_root / "src/parser.c"] + [path for path in [grammar_root / "src/scanner.c"] if path.is_file()]
    copied = include_closure(repository, sources + sorted((grammar_root / "src/tree_sitter").glob("*.h")), [grammar_root / "src"])

    target = vendor_root / name
    if target.exists():
        shutil.rmtree(target)
    copy(repository / "LICENSE", target / "LICENSE")
    for path in copied:
        copy(repository / path, target / path)

    raw_root = vendor_root / check.RAW_QUERIES
    kinds = [adapt_queries.HIGHLIGHTS] + ([adapt_queries.INJECTIONS] if injections else [])
    builtin_names = frozenset(manifest["grammars"]) | {name}
    raw_paths = []
    for kind in kinds:
        for source, _ in adapt_queries.sources(name, kind, nvim_root / "runtime/queries"):
            copy(nvim_root / "runtime/queries" / source / f"{kind}.scm", raw_root / source / f"{kind}.scm")
        raw_paths += check.raw_query_paths(name, kind, raw_root)
        adapted = adapt_queries.adapt(name, kind, raw_root, nvim_commit, builtin_names)
        (target / "queries").mkdir(exist_ok=True)
        (target / "queries" / f"{kind}.scm").write_bytes(adapted.encode("utf-8"))

    parser_text = (target / sources[0].relative_to(repository)).read_text(encoding="utf-8", errors="replace")
    symbol = LANGUAGE_FUNCTION.search(parser_text)
    abi = LANGUAGE_VERSION.search(parser_text)
    if symbol is None or abi is None:
        raise VendorError(f"{sources[0]} has no tree_sitter_* language function or LANGUAGE_VERSION")
    files = sorted(path.relative_to(vendor_root).as_posix() for path in target.rglob("*") if path.is_file())
    files += sorted(set(raw_paths))
    return {
        "name": display_name,
        "repository": info["url"],
        "revision": info["revision"],
        "commit": commit,
        "location": location,
        "symbol": symbol.group(1),
        "abi": int(abi.group(1)),
        "generated": generated,
        "query_source": "nvim_treesitter",
        "sources": [f"{name}/{path.relative_to(repository).as_posix()}" for path in sources],
        "highlights": f"{name}/queries/highlights.scm",
        "injections": f"{name}/queries/injections.scm" if injections else None,
        "locals": None,
        "files": [{"path": path, "sha256": check.sha256(vendor_root / path)} for path in files],
        "matches": matches,
    }


def zon(value):
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, dict):
        return ".{ " + ", ".join(f".{key} = {zon(item)}" for key, item in value.items()) + " }"
    if not value:
        return ".{}"
    if len(value) == 1:
        return ".{" + zon(value[0]) + "}"
    return ".{ " + ", ".join(zon(item) for item in value) + " }"


def render_entry(name, entry):
    """Render one manifest entry at the indentation of .grammars, in the zig fmt layout."""
    lines = [f"        .{name} = .{{"]
    for key, value in entry.items():
        if key == "query_source":
            rendered = f".{value}"
        elif key == "files":
            rendered = ".{\n" + "".join(f"                {zon(file)},\n" for file in value) + "            }"
        else:
            rendered = zon(value)
        lines.append(f"            .{key} = {rendered},")
    lines.append("        },")
    return "\n".join(lines) + "\n"


def update_manifest(repo_root, name, rendered):
    """Replace the entry of name in manifest.zig.zon, or append it as the last entry of .grammars."""
    path = repo_root / check.MANIFEST
    text = path.read_text(encoding="utf-8")
    entry = re.compile(rf"^        \.{re.escape(name)} = \.\{{\n.*?^        \}},\n", re.M | re.S)
    if entry.search(text):
        text = entry.sub(lambda _: rendered, text, count=1)
    elif text.endswith(MANIFEST_END):
        text = text[: -len(MANIFEST_END)] + rendered + MANIFEST_END
    else:
        raise VendorError(f"{path} does not end with the closing lines of .grammars")
    path.write_bytes(text.encode("utf-8"))


def split_list(value):
    return None if value is None else [item for item in value.split(",") if item]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("nvim_treesitter", type=Path, help="nvim-treesitter checkout at the manifest commit")
    parser.add_argument("repository", type=Path, help="Grammar repository checkout at the parsers.lua revision")
    parser.add_argument("name", help="nvim-treesitter name, which is also the BuiltInGrammar enum tag")
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--display-name", help='BuiltInGrammar.name(), such as "Zig". A rerun keeps the manifest value.')
    parser.add_argument("--filenames", help="comma-separated exact filenames. A rerun keeps the manifest value.")
    parser.add_argument("--extensions", help="comma-separated extensions. A rerun keeps the manifest value.")
    parser.add_argument("--shebangs", help="comma-separated shebang interpreters. A rerun keeps the manifest value.")
    parser.add_argument("--injections", action="store_true", help="also vendor and adapt injections.scm (Injection hosts only)")
    parser.add_argument("--tree-sitter", default="tree-sitter", help="tree-sitter CLI, only used when parser.c needs generation")
    parser.add_argument("--update-manifest", action="store_true", help="also write the entry into manifest.zig.zon")
    arguments = parser.parse_args()
    matches = {kind: split_list(getattr(arguments, kind)) for kind in ("filenames", "extensions", "shebangs")}
    try:
        entry = vendor(
            arguments.nvim_treesitter,
            arguments.repository,
            arguments.name,
            arguments.repo_root,
            display_name=arguments.display_name,
            matches=matches,
            injections=arguments.injections,
            cli=arguments.tree_sitter,
        )
        rendered = render_entry(arguments.name, entry)
        if arguments.update_manifest:
            update_manifest(arguments.repo_root, arguments.name, rendered)
    except (VendorError, adapt_queries.AdaptError, check.ZonError) as error:
        print(f"vendor_grammar.py: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
