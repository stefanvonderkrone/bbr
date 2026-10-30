# 08: Vendor the configuration Grammars: TOML, Dockerfile, and Make

Status: resolved
Blocked by: 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for TOML, Dockerfile, and Make Files.
Files without an extension, such as `Dockerfile`, `Containerfile`, and `Makefile`, match by exact filename.

## Scope

- Vendor `toml`, `dockerfile`, and `make` with `tools/vendor_grammar.py` at the revisions that the pinned nvim-treesitter commit names.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.

## Acceptance criteria

- [x] `tools/check_vendored_grammars.py` passes for all three Grammars.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.toml`, `Dockerfile`, `Containerfile`, `app.dockerfile`, `Makefile`, `makefile`, `GNUmakefile`, and `.mk` select the right Grammar.
- [x] `docker/Dockerfile` selects Dockerfile, because the exact filename rule uses the basename.
- [x] `Dockerfile.dev` selects no Grammar.
- [x] Each Grammar has a Capture fixture with comment, string, and keyword roles.
- [x] A Make or Dockerfile fixture proves `#set! priority` on a real query.
- [x] Each fixture joins the byte-plane oracle test.

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

- `tools/vendor_grammar.py --update-manifest` vendored TOML, Dockerfile, and Make at the pinned revisions.
- The manifest has three new entries at the end, in the order `toml`, `dockerfile`, `make`.
- `BuiltInGrammar` has the three new tags at the end, in the same order.
- `build.zig` now builds the include path of each Grammar source at build time.
  The old `comptime std.fs.path.dirname` call exceeded the comptime branch quota with 12 BuiltInGrammars.
  This is the only `build.zig` change.
- The existing aliases `docker`, `dockerfile`, `make`, and `makefile` now resolve to the new BuiltInGrammars.
  This applies to a ReviewBody fence and to an Injection name.

### Tests

These tests are in `src/highlight/tree_sitter_highlighter.zig`, under `// M27 ticket 08 fixtures`:

- "M27 grammar GrammarMatch selects TOML, Dockerfile, and Make"
- "M27 grammar TOML fixture has comment, string, keyword, property, and constant roles"
- "M27 grammar Dockerfile fixture has comment, string, keyword, and property roles"
- "M27 grammar Make fixture has comment, string, keyword, and function roles"
- "M27 grammar Make set priority 105 beats a later pattern at default priority"
- "M27 grammar Dockerfile set priority 90 loses to an earlier pattern at default priority"
- "M27 injection docker and make names select the Dockerfile and Make BuiltInGrammars"
- "M27 grammar docker and make ReviewBody fences highlight with the new BuiltInGrammars"

The three fixtures also join "interval merge matches byte planes for every BuiltInGrammar fixture".

A mutation check removed the `#set! priority` predicates from the adapted Make and Dockerfile queries.
Both priority tests failed, and they passed again after the restore.

### Commands and results

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars --summary all`: 44/44 tests passed.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: OK.
- `zig build test --summary all`: 27/27 steps succeeded, 1419/1419 tests passed.
- `python3 tools/check_agent_docs.py`: pass.

### Defaults chosen

- The TOML query has no `@keyword` Capture.
  The TOML fixture asserts the `=` operator, which has the keyword role.
- The ReviewBody fence test checks the alias extension and highlights the fence path, such as `review.dockerfile`.
  It does not call `fencePath`, because that function is in the TUI module.
