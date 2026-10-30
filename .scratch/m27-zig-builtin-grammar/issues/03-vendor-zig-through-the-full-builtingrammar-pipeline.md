# 03: Vendor Zig through the full BuiltInGrammar pipeline

Status: ready-for-agent
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

- [ ] `vendors/tree-sitter/zig/` holds `LICENSE`, the sources, and the adapted `queries/highlights.scm`.
- [ ] `vendors/tree-sitter/nvim-treesitter/queries/zig/highlights.scm` is the unchanged upstream query.
- [ ] The manifest records the repository, the revision, the commit, the symbol, the ABI, and a checksum for every Zig file.
- [ ] `tools/check_vendored_grammars.py` passes, and it fails on a changed checksum, an unlisted file, a missing directory, and a hand-edited adapted query.
- [ ] `.zig` and `.zon` Files select Zig.
- [ ] A Zig fixture asserts comment, string, keyword, function, and type roles.
- [ ] The Zig fixture joins "interval merge matches byte planes for every BuiltInGrammar fixture".
- [ ] Every M13 GrammarMatch case keeps its result, and `#!/bin/sh -e` selects Bash.
- [ ] The GrammarMatch table equals the manifest `.matches` for every BuiltInGrammar.
- [ ] Every BuiltInGrammar ABI is in the runtime range and equals the manifest `.abi`.
- [ ] A UserGrammar for `.zig` takes precedence over the Zig BuiltInGrammar.
- [ ] `bbr grammar check` reports Zig as an affected BuiltInGrammar for a `.zig` UserGrammar.
- [ ] A fenced `zig` block in a ReviewBody gets Zig Spans.

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
