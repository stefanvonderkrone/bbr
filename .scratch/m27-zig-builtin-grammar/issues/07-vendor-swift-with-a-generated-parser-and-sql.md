# 07: Vendor Swift with a generated parser and SQL

Status: ready-for-agent
Blocked by: 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for Swift and SQL Files.
Swift has no committed `parser.c` upstream, so the vendoring run generates it once.
SQL comes from the `gh-pages` branch, which already contains the upstream-generated `parser.c`.
The build never runs the tree-sitter CLI.

## Scope

- Install tree-sitter CLI v0.26.9 outside the repository for the vendoring run.
- Vendor `swift` with `tools/vendor_grammar.py`, which runs `tree-sitter generate --abi 15` in the temporary checkout.
- Record the CLI version, the command, and the JavaScript runtime with its version in the Swift manifest entry.
- Vendor `sql` from the pinned `gh-pages` commit.
  If that commit has no `src/parser.c`, generate it with the same rule as Swift.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.

## Acceptance criteria

- [ ] `tools/check_vendored_grammars.py` passes for both Grammars.
- [ ] The Swift manifest entry records the generation, and the SQL entry records whether generation ran.
- [ ] A second generation run with the same inputs gives the same `parser.c` checksum.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.swift` selects Swift, and `.sql` selects SQL.
- [ ] Each Grammar has a Capture fixture with comment, string, keyword, and function or type roles.
- [ ] Each fixture joins the byte-plane oracle test.
- [ ] `zig build` with no network access and no tree-sitter CLI on `PATH` succeeds.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- The existing load, ABI, and manifest tests from ticket 03.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`
