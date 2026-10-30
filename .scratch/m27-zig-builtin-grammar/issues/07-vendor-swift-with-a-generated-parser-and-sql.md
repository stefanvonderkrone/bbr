# 07: Vendor Swift with a generated parser and SQL

Status: resolved
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

- [x] `tools/check_vendored_grammars.py` passes for both Grammars.
- [x] The Swift manifest entry records the generation, and the SQL entry records whether generation ran.
- [x] A second generation run with the same inputs gives the same `parser.c` checksum.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.swift` selects Swift, and `.sql` selects SQL.
- [x] Each Grammar has a Capture fixture with comment, string, keyword, and function or type roles.
- [x] Each fixture joins the byte-plane oracle test.
- [x] `zig build` with no network access and no tree-sitter CLI on `PATH` succeeds.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- The existing load, ABI, and manifest tests from ticket 03.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`

## Completion

### Change summary

- `tools/vendor_grammar.py` now copies the Grammar checkout into a temporary directory before `tree-sitter generate`.
  The given checkout stays unchanged.
  Before this change, generation wrote `src/parser.c`, `src/grammar.json`, and `src/node-types.json` into the given checkout.
- The tool vendored `swift` with `--tree-sitter <CLI 0.26.9>`.
  The Swift manifest entry records `.generated = .{ .cli = "0.26.9", .command = "tree-sitter generate --abi 15", .js_runtime = "node v24.18.0" }`.
- The tool vendored `sql` from the `gh-pages` commit `e038788e5d4daba82dea35676bf49a216629e141` as a plain copy.
  The SQL manifest entry records `.generated = null`.
  The run used `--tree-sitter /nonexistent/tree-sitter`, so a generation attempt would fail.
- `BuiltInGrammar` has the new tags `swift` and `sql` after `zig`, in manifest order.
- `build.zig` computes each include directory with `b.fmt` at build time.
  Before this change, `comptime std.fs.path.dirname` exceeded the default branch quota of 1000 with 11 Grammars.
  This is the only `build.zig` change. It is not a per-Grammar edit.
- `grammar_name.zig` has no change.
  The `sql` alias exists.
  A `swift` fence resolves through the fallback `review.swift`, so it needs no alias.

### Commands and results

- Swift generation, first run and second run: `parser.c` sha256 is `dfb6c75b11e35fb5cb17f8d1c1d8866fcc9a614e39318598015843a66e12cec5` both times.
  After the second run, `git diff` of the staged vendor tree is empty.
  `git status` of the shared Swift checkout is empty after both runs.
- Offline build: `sandbox-exec -p '(version 1)(allow default)(deny network*)' env PATH=/opt/homebrew/Cellar/zig/0.16.0_1/bin:/usr/bin:/bin:/usr/sbin:/sbin zig build --cache-dir <empty directory>` exits 0.
  In the same sandbox, `curl https://github.com` fails with "Could not resolve host".
  With that `PATH`, `command -v tree-sitter` finds nothing.
- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars --summary all`: 39 of 39 tests pass.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: pass.
- `python3 tools/check_agent_docs.py`: pass.
- `zig build test --summary all`: 27 of 27 steps succeed. 1414 of 1414 tests pass.

### Tests

- "M27 grammar Swift fixture has comment, string, keyword, function, and type roles".
- "M27 grammar SQL fixture has comment, string, keyword, function, and type roles".
- "M27 grammar GrammarMatch selects Swift and SQL".
- `App.swift` and `query.sql` join "interval merge matches byte planes for every BuiltInGrammar fixture".

### Defaults chosen

- Neither Grammar is an Injection host, because the spec names no Injection for them.
- The tool copies the checkout without `.git`, because generation needs only the working tree.
