# Vendored tree-sitter sources

These files are copied source snapshots, not git submodules.
`zig build` uses no network, and it compiles only the files in this directory.
The build never generates or downloads a Grammar source.

The tree-sitter runtime comes from `tree-sitter/tree-sitter/lib` at tag `v0.26.9`.

## Manifest

`manifest.zig.zon` is the one list of BuiltInGrammars.
`addTreeSitter` in `build.zig` imports it as ZON.
For each entry, the build compiles `.sources` with `-std=c11` and adds the directory of each source as an include path.
The build also embeds `.highlights`, `.injections`, and `.locals` as `<tag>_highlights`, `<tag>_injections`, and `<tag>_locals`.

`src/highlight/grammar_match.zig` imports the same manifest.
The `.matches` of each entry give its GrammarMatch row, and `.name` gives `BuiltInGrammar.name()`.
`src/highlight/tree_sitter_highlighter.zig` declares the language function from `.symbol`.

Each entry has these fields:

| Field | Value |
| --- | --- |
| `.name` | The display name, such as `"Zig"`. |
| `.repository`, `.revision`, `.commit` | The upstream repository, the revision that nvim-treesitter pins, and its commit. A tag revision resolves to a commit. |
| `.location` | The Grammar directory in the repository, or `null`. |
| `.symbol`, `.abi` | The `tree_sitter_<name>` function and the `LANGUAGE_VERSION` value in `parser.c`. |
| `.generated` | `null` for a copied `parser.c`. Otherwise, the CLI version, the command, and the JavaScript runtime that generated it. |
| `.query_source` | `.nvim_treesitter` for an adapted nvim-treesitter query. `.upstream` for the 8 M13 Grammars, which keep their upstream queries. |
| `.sources` | The C files that the build compiles. |
| `.highlights`, `.injections`, `.locals` | The query files, or `null`. |
| `.files` | Every vendored file of the Grammar with its SHA-256, including headers, `LICENSE`, and raw queries. |
| `.matches` | The exact filenames, extensions, and shebang interpreters of the GrammarMatch row. |

The TypeScript and TSX queries extend the JavaScript queries.
`grammarSource` in `tree_sitter_highlighter.zig` joins them, as in M13.

## Layout

A Grammar directory mirrors the repository paths that bbr uses:

```text
<tag>/LICENSE
<tag>/<location>/src/parser.c
<tag>/<location>/src/scanner.c          (when present)
<tag>/<location>/src/tree_sitter/*.h
<tag>/queries/highlights.scm            (adapted)
<tag>/queries/injections.scm            (adapted, Injection hosts only)
```

A Grammar without `location` has no `<location>/` part.
A source can include a file outside `src/`, such as `../../common/scanner.h`.
That file goes to its repository path below `<tag>/`, such as `php/common/scanner.h`.

Two directories hold no Grammar:

- `nvim-treesitter/queries/<name>/<kind>.scm` holds the unchanged nvim-treesitter queries, including inherited bases such as `c` and `html_tags`.
  Several Grammars can share one raw query.
  Each Grammar lists in `.files` every raw query that its adaptation reads.
- `common/scanner.h` belongs to the TypeScript and TSX Grammars, and both list it.

The build compiles the sources and embeds the adapted queries in `<tag>/` only.
It never reads `nvim-treesitter/queries/`.
Only `tools/adapt_queries.py` reads the raw queries.

## Licences

Each Grammar directory keeps the `LICENSE` file of its upstream repository.
`tools/vendor_grammar.py` stops when the Grammar checkout has no `LICENSE` file at the pinned commit.
`.files` lists each `LICENSE` file with its checksum.

The nvim-treesitter queries are Apache-2.0.
`nvim-treesitter/LICENSE` holds that licence.
Each adapted query starts with a comment that names the source path and the commit, and states that bbr changed the query.
This comment meets the Apache-2.0 notice rule for changed files.

Each release archive has a `THIRD_PARTY_NOTICES` file next to `bbr`.
`tools/third_party_notices.py` writes it from the manifests and the `LICENSE` files.
The file holds every Grammar `LICENSE`, `nvim-treesitter/LICENSE`, `runtime/LICENSE`, and the RE2 and Abseil licences.
A Grammar without exactly one `LICENSE` entry in `.files` stops the release.

## Generated parser.c

Swift is the only BuiltInGrammar with a generated `parser.c`.
Its repository has no `src/parser.c` at the pinned commit.
`tools/vendor_grammar.py` generated it once with tree-sitter CLI 0.26.9, the version of the vendored runtime.
The Swift entry records the generation:

```zig
.generated = .{ .cli = "0.26.9", .command = "tree-sitter generate --abi 15", .js_runtime = "node v24.18.0" },
```

The generated `parser.c` and `src/tree_sitter/*.h` are committed and checksummed like every copied file.
Two runs of the tool gave the same `parser.c`.
The M27 brief expected a generated `parser.c` for SQL too.
The pinned `gh-pages` commit contains the upstream-generated file, so the tool copies it.

## Tools

`tools/vendor_grammar.py` vendors one nvim-treesitter Grammar.
It uses no network, so clone both repositories first.
It requires the nvim-treesitter checkout at the manifest commit and the Grammar checkout at the `parsers.lua` revision.
It runs these steps:

1. It reads the `parsers.lua` entry: `url`, `revision`, `location`, and `generate`.
2. It generates `parser.c` with `tree-sitter generate --abi 15` only when the entry has `generate = true` or the commit has no `src/parser.c`.
   The CLI version must equal `.tree_sitter_cli.version`.
   Generation changes only the temporary checkout.
3. It replaces `<tag>/` with `LICENSE`, the sources, `src/tree_sitter/*.h`, and every file that a source includes with quotes.
   An include that leaves the repository stops the tool.
   The tool never edits a vendored source.
4. It copies the raw queries and their bases to `nvim-treesitter/queries/`.
5. It writes the adapted queries with `tools/adapt_queries.py`.
6. It prints the manifest entry. With `--update-manifest`, it also writes the entry into `manifest.zig.zon`.

A rerun with the same checkouts writes the same files and the same entry.
A rerun without `--display-name`, `--filenames`, `--extensions`, `--shebangs`, or `--injections` keeps the manifest values.

`tools/check_vendored_grammars.py .` runs in `zig build test`.
It fails in these cases:

- A file checksum differs from `.files`.
- A file under a Grammar directory is not in the `.files` of that Grammar.
- A file under a shared directory is in no `.files` list.
- An entry uses a source or a query that is not in its `.files`.
- An entry uses a source or a query outside its `<tag>/` directory, such as a raw query in `nvim-treesitter/queries/`.
- An adapted query differs from a new adaptation of the raw queries.
- The raw queries in `.files` differ from the raw queries that the adaptation reads.
- A manifest entry has no directory, or a directory has no manifest entry.
- The runtime `lib.c` checksum differs from `.runtime.lib_c_sha256`.

`tests/check_vendored_grammars_test.py` tests each failure case.

## Add a BuiltInGrammar

The example adds C.
Use the nvim-treesitter name as the tag.

1. Clone the repositories into a temporary directory, with no change to the working tree:

   ```sh
   git clone https://github.com/nvim-treesitter/nvim-treesitter "$TMPDIR/nvim-treesitter"
   git -C "$TMPDIR/nvim-treesitter" checkout a2f694478be07f89c2d03cc17858a8745a400c4b
   git clone https://github.com/tree-sitter/tree-sitter-c "$TMPDIR/tree-sitter-c"
   git -C "$TMPDIR/tree-sitter-c" checkout b780e47fc780ddc8da13afa35a3f4ed5c157823d
   ```

2. Run the tool with the display name and the GrammarMatch row from the spec:

   ```sh
   python3 tools/vendor_grammar.py "$TMPDIR/nvim-treesitter" "$TMPDIR/tree-sitter-c" c \
     --display-name C --extensions .c --update-manifest
   ```

   Add `--injections` for an Injection host.
   Add `--tree-sitter <path to the tree-sitter 0.26.9 CLI>` when `parser.c` needs generation.
   The tool writes the adapted queries to `vendors/tree-sitter/<tag>/queries/`.
   The build compiles that adapted copy, not the raw copy in `vendors/tree-sitter/nvim-treesitter/queries/`.
3. Add the tag as the last tag of `BuiltInGrammar` in `src/highlight/grammar_match.zig`.
   The tags and the manifest entries must have the same order, or the build fails.
4. Add a Capture fixture test named `M27 grammar ...` to `src/highlight/tree_sitter_highlighter.zig`.
   Add the fixture to "interval merge matches byte planes for every BuiltInGrammar fixture".
5. Add GrammarMatch cases that the manifest cannot show, such as `.h` selecting C++.
   "M27 grammar the GrammarMatch table equals the manifest" already tests each filename, extension, and shebang.
6. If the tag is a new fence name or alias, add it to `src/highlight/grammar_name.zig`.
7. Run `python3 tools/check_vendored_grammars.py .`.
   If an adapted injection query of a host differs, rerun the tool for that host with `--injections`.
   A new tag can change which static Injection names the host keeps.
8. Run `zig fmt --check build.zig src`, `zig build`, `zig build test-builtin-grammars`, and `zig build test --summary all`.

No step edits `build.zig`, `grammarSource`, an `extern` declaration, or `BuiltInGrammar.name()`.

## Update an M13 Grammar

The 8 M13 Grammars have `.query_source = .upstream`, so the vendoring tool does not apply.
To update one, replace its files from the upstream repository at the new commit.
Then update `.revision`, `.commit`, and every changed checksum in `.files`, and run the checks above.
