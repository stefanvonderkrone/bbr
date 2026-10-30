# 03: Vendor Zig through the full BuiltInGrammar pipeline

Status: resolved
Blocked by: 02
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer opens a `.zig` File or a `build.zig.zon` File and sees Zig highlighting.
Zig is the tracer for the shared vendoring pipeline.
This slice builds the vendoring tool, the check, the new manifest schema, the table-driven build, and the GrammarMatch table.
Later Grammar tickets only add entries to these tables.

## Scope

- Add `tools/vendor_grammar.py` as the "Vendoring procedure" section of the spec describes.
  It uses no network, and it never edits a vendored source.
- Add `tools/check_vendored_grammars.py` and run it in `zig build test`.
- Move `vendors/tree-sitter/manifest.zig.zon` to the schema in the "Manifest" section of the spec.
  Convert the 8 M13 entries without a change to their files.
  Add the Bash filenames and shebangs to the Bash entry.
- Make `addTreeSitter` in `build.zig` table-driven, as the "Build" section of the spec describes.
  Use the `zig` skill to verify the ZON import API.
- Replace the `if` chain in `grammar_match.selectBuiltIn` with the GrammarMatch table and the shebang rule from the spec.
- Vendor Zig with the tool at the revision that the pinned nvim-treesitter commit names.
  Add the `zig` enum tag, its name "Zig", its `extern` symbol, and its `grammarSource` arm.
- Change the `src/a.zig` case in "BuiltInGrammar selection covers JavaScript TypeScript and TSX" to expect Zig.
- Update `vendors/tree-sitter/README.md` with the procedure and the two tools.

## Acceptance criteria

- [x] `vendors/tree-sitter/zig/` holds `LICENSE`, the sources, and the adapted `queries/highlights.scm`.
- [x] `vendors/tree-sitter/nvim-treesitter/queries/zig/highlights.scm` is the unchanged upstream query.
- [x] The manifest records the repository, the revision, the commit, the symbol, the ABI, and a checksum for every Zig file.
- [x] `tools/check_vendored_grammars.py` passes, and it fails on a changed checksum, an unlisted file, a missing directory, and a hand-edited adapted query.
- [x] `.zig` and `.zon` Files select Zig.
- [x] A Zig fixture asserts comment, string, keyword, function, and type roles.
- [x] The Zig fixture joins "interval merge matches byte planes for every BuiltInGrammar fixture".
- [x] Every M13 GrammarMatch case keeps its result, and `#!/bin/sh -e` selects Bash.
- [x] The GrammarMatch table equals the manifest `.matches` for every BuiltInGrammar.
- [x] Every BuiltInGrammar ABI is in the runtime range and equals the manifest `.abi`.
- [x] A UserGrammar for `.zig` takes precedence over the Zig BuiltInGrammar.
- [x] `bbr grammar check` reports Zig as an affected BuiltInGrammar for a `.zig` UserGrammar.
- [x] A fenced `zig` block in a ReviewBody gets Zig Spans.

## Tests that prove it

- "M27 grammar every BuiltInGrammar loads its queries", "M27 grammar every BuiltInGrammar ABI is compatible with the vendored runtime", and "M27 grammar the GrammarMatch table equals the manifest" in `src/highlight/tree_sitter_highlighter.zig`.
- A Zig Capture fixture and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- A UserGrammar precedence test in `src/highlight/user_grammar.zig`.
- `tools/check_vendored_grammars.py` and its failure cases in a Python test.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`

## Completion

The changes are uncommitted.
The runner reviews and commits them.
The code review is the runner's review.

### Change summary

- `vendors/tree-sitter/manifest.zig.zon` has the spec schema.
  It also has `.locals`, because JavaScript and TypeScript keep their M13 locals queries.
  A conversion script moved the 8 M13 entries.
  The script asserted that each old `parser_sha256` and `query_sha256` equals the new checksum of the same file.
- `build.zig` imports the manifest as ZON.
  `addTreeSitter` compiles each `.sources` file and embeds each query as `<tag>_highlights`, `<tag>_injections`, or `<tag>_locals`.
  `addTreeSitter` also gives the manifest to the module as the anonymous import `builtin_grammar_manifest`.
- `src/highlight/grammar_match.zig` keeps a hand-written `BuiltInGrammar` enum.
  A `comptime` block fails the build when the tags and the manifest entries differ in name or order.
  `BuiltInGrammar.name()` returns the manifest `.name`.
  The GrammarMatch `table` comes from the manifest `.matches` at compile time.
  `selectBuiltIn` checks all filenames, then all extensions, then all shebangs, and the first match wins.
  `shebangInterpreter` applies the spec rule.
- `src/highlight/tree_sitter_highlighter.zig` declares each language function with `@extern` and the manifest `.symbol`.
  `grammarSource` is an exhaustive switch.
  TSX and TypeScript keep their arm, because their queries extend the JavaScript queries.
  The `inline else` arm takes the language and the queries of every other tag from the manifest.
- `tools/vendor_grammar.py` runs the vendoring procedure for one Grammar and prints the manifest entry.
  With `--update-manifest`, it also writes the entry into the manifest.
  A quoted include resolves next to the including file, then in the `src/` directory, as the compiler does.
- `tools/check_vendored_grammars.py` holds a reader for the ZON subset of the manifest.
  `zig build test` runs the check and `tests/check_vendored_grammars_test.py`.
- The tool vendored Zig at `6479aa13f32f701c383083d8b28360ebd682fb7d`.
  The raw query `vendors/tree-sitter/nvim-treesitter/queries/zig/highlights.scm` equals the upstream file.
  The adaptation removes one `@spell`.
- `vendors/tree-sitter/README.md` describes the manifest, the layout, the two tools, and the steps to add a BuiltInGrammar.

### Tests

- `src/highlight/tree_sitter_highlighter.zig`: "M27 grammar every BuiltInGrammar loads its queries", "M27 grammar every BuiltInGrammar ABI is compatible with the vendored runtime", "M27 grammar the GrammarMatch table equals the manifest", "M27 grammar GrammarMatch keeps every M13 case and selects Zig and Bash", and "M27 grammar Zig fixture has comment, string, keyword, function, and type roles".
- The Zig fixture is in "interval merge matches byte planes for every BuiltInGrammar fixture".
- "BuiltInGrammar selection covers JavaScript TypeScript and TSX" expects Zig for `src/a.zig`.
- `src/highlight/grammar_match.zig`: "M27 grammar shebang interpreter drops the path, env flags, and version".
- `src/highlight/user_grammar.zig`: "M27 grammar a UserGrammar for .zig takes precedence over the Zig BuiltInGrammar".
- `src/highlight/grammar_cli.zig`: "M27 grammar bbr grammar check reports Zig as an affected BuiltInGrammar".
- `src/tui/presentation.zig`: "M27 grammar a fenced zig block in a ReviewBody gets Zig Spans".
- `tests/check_vendored_grammars_test.py` has 13 tests.
  They cover a changed checksum, an unlisted Grammar file, an unlisted shared raw query, an unlisted inherited raw query, an entry without a directory, a directory without an entry, a hand-edited adapted query, and the exit status.
  They also cover the manifest reader, the entry renderer, `--update-manifest`, and the `parsers.lua` reader.

### Checks

| Command | Result |
| --- | --- |
| `zig fmt --check build.zig src` | Pass. |
| `zig fmt --check vendors/tree-sitter/manifest.zig.zon` | Pass. |
| `zig build` | Pass. |
| `zig build test-builtin-grammars --summary all` | 7/7 steps succeeded. 36/36 tests passed. |
| `python3 tools/check_vendored_grammars.py .` | Pass. |
| `python3 tests/check_vendored_grammars_test.py` | 13 tests pass. |
| `zig build test --summary all` | 27/27 steps succeeded. 1411/1411 tests passed. Before this ticket, 1402 tests passed. |

### Tool evidence

- Two runs of the tool for Zig gave the same entry and the same files.
- A scratch repository root received all 20 M27 Grammars from the tool, including Swift with `parser.c` generation.
  The generated Swift `parser.c` has the SHA-256 that the runner recorded, `dfb6c75b...`.
  The check passed on the scratch root after a rerun of the four Injection hosts.
  A second rerun left the manifest unchanged, and `zig fmt --check` accepted it.
  This proves that the tool handles `location`, tag revisions, `../../common/scanner.h`, `requires` bases, and generation.

### Defaults chosen

- The `BuiltInGrammar` enum stays hand-written, so a reader and the editor see every tag.
  The `comptime` block makes the enum and the manifest agree.
- The GrammarMatch table comes from the manifest, so a new Grammar adds no table row.
  So the test "M27 grammar the GrammarMatch table equals the manifest" checks behavior.
  For each manifest filename, extension, and shebang, `selectBuiltIn` must select that Grammar.
  This also catches a rule that an earlier row shadows.
- Ticket 12 must reword the planned AGENTS.md rule "A new BuiltInGrammar is one arm of `grammarSource` and one row of the GrammarMatch table".
  After this ticket, a new BuiltInGrammar is one enum tag and one manifest entry.
  The `comptime` block in `grammar_match.zig` enforces it.
- A raw query that several Grammars read, such as `c` for `cpp`, is in the `.files` of each of these Grammars.
  A shared file must be in at least one `.files` list.
  The raw queries in `.files` must equal the raw queries that the adaptation reads.
- `common/scanner.h` is in the `.files` of TypeScript and TSX.
- The manifest has no per-Grammar C flag field, because no Grammar needs one.
- The tool does not run `npm install`.
  If generation fails, it tells the caller to install the npm packages in the checkout.
  Swift generates with no npm packages.
- The tool adapts an injection query with the manifest tags and the new tag as the BuiltInGrammar names.
  A new tag can change an adapted host query, so the check then asks for a rerun of the host.
- The tool does not check the remote URL of the Grammar checkout, because the remote can differ.
  It checks the commit.
- The UserGrammar precedence test has no native library.
  It puts a JavaScript package in the loaded slot of the Registry installation.

### Changed paths

`build.zig`, `src/highlight/grammar_match.zig`, `src/highlight/tree_sitter_highlighter.zig`, `src/highlight/user_grammar.zig`, `src/highlight/grammar_cli.zig`, `src/tui/presentation.zig`, `tools/vendor_grammar.py`, `tools/check_vendored_grammars.py`, `tests/check_vendored_grammars_test.py`, `vendors/tree-sitter/manifest.zig.zon`, `vendors/tree-sitter/README.md`, `vendors/tree-sitter/zig/`, and `vendors/tree-sitter/nvim-treesitter/queries/zig/`.
