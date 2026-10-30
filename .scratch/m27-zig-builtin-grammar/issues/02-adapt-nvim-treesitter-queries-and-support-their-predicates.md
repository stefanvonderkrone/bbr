# 02: Adapt nvim-treesitter queries and support their predicates

Status: resolved
Blocked by: none
Spec: [M27 spec](../SPEC.md)

## What to build

bbr can load an nvim-treesitter highlight query after a deterministic adaptation.
The adaptation resolves `; inherits:` lines and rewrites or removes Neovim-only forms.
Every removal leaves a `; bbr:` comment, and an unknown predicate stops the adaptation.
The runtime supports the remaining predicates, pattern priority, hidden Captures, and the new Capture classification.
This slice adds no Grammar.

## Scope

- Pin one nvim-treesitter commit on `main`.
  Use `a2f694478be07f89c2d03cc17858a8745a400c4b` or record the reason for a later commit.
- Add `vendors/tree-sitter/nvim-treesitter/LICENSE` from that commit.
- Add `tools/adapt_queries.py` as the "Query adaptation" section of the spec describes.
  It reads S-expression forms with string and comment awareness.
  It writes the source header comment that the "Licences" section of the spec requires.
- Add `tests/adapt_queries_test.py` with inline query text.
- In `src/highlight/query_predicates.zig`, add `#not-eq?`, `#not-match?`, `#any-of?`, `#not-any-of?`, `#has-ancestor?`, `#not-has-ancestor?`, `#has-parent?`, `#not-has-parent?`, and `#set! priority N`.
  Accept both a bare and a quoted `priority` key.
- In `src/highlight/runtime_package.zig`, mark Captures that start with `_` hidden and store the priority of each pattern.
- In `src/highlight/tree_sitter_highlighter.zig`, skip hidden Captures and compare priority first in `higherPrecedence`.
- In `src/highlight/highlighter.zig`, add the dotted-prefix rules from the "Capture classification" table of the spec to `Capture.init`.
- Run `tests/adapt_queries_test.py` in `zig build test`.

## Acceptance criteria

- [x] Each new predicate accepts and rejects a match on a synthetic JavaScript query.
- [x] `#set! priority` changes the winner between two overlapping patterns.
- [x] A Capture that starts with `_` produces no Span.
- [x] Each prefix in the Capture classification table maps to its role.
- [x] Every Capture name in the 8 M13 queries keeps its role, proved by a golden list.
- [x] The adaptation resolves nested and optional `; inherits:` lines in order, and a missing required base stops it.
- [x] The adaptation rewrites `#lua-match?`, `#not-lua-match?`, and `#contains?`, and RE2 compiles each result.
- [x] The Lua translation handles each listed class, and it rejects `%b`, `%f`, and back references.
- [x] The adaptation removes `conceal`, `conceal_lines`, `url`, and highlight `#offset!` directives, and `@spell`, `@nospell`, `@conceal`, and `@conceal_lines` Captures, each with a `; bbr:` comment.
- [x] An unknown predicate stops the adaptation with the file, the line, and the form.
- [x] Two runs of the adaptation on the same input give the same bytes.
- [x] UserGrammar validation accepts the new predicates, and the M17 UserGrammar tests pass.

## Tests that prove it

- "M27 grammar" predicate, priority, hidden Capture, and classification tests in `src/highlight/tree_sitter_highlighter.zig`, `src/highlight/query_predicates.zig`, and `src/highlight/highlighter.zig`.
- `tests/adapt_queries_test.py`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tests/adapt_queries_test.py`
- `zig build test --summary all`

## Completion

The changes are uncommitted.
The runner reviews and commits them.
The code review is the runner's review.

### Change summary

- `tools/adapt_queries.py`, `tests/adapt_queries_test.py`, and `vendors/tree-sitter/nvim-treesitter/LICENSE` come from the adapter helper.
  The pinned commit is `a2f694478be07f89c2d03cc17858a8745a400c4b`.
- `src/highlight/query_predicates.zig` adds `#not-eq?`, `#not-match?`, `#any-of?`, `#not-any-of?`, `#has-ancestor?`, `#not-has-ancestor?`, `#has-parent?`, and `#not-has-parent?`.
  A `Predicate` is a `Condition` and a `negated` flag.
  `#is-not? local` is the negated `local` Condition.
  `Set.strings` holds the `#any-of?` values and the ancestor node types.
- `#set! priority N` and `#set! "priority" N` set the pattern priority.
  `Set.priorities` holds one `u16` for each pattern, and the default is `default_priority`, 100.
  A missing, non-integer, negative, or extra value fails with `malformed_arguments`.
- `RuntimePackage.captures` is `[]const ?Capture`.
  A Capture whose name starts with `_` is null, so it is hidden.
  `collectLayerIntervals` skips a hidden Capture and takes the priority of the match pattern.
- `Capture.init` in `src/highlight/highlighter.zig` checks the dotted-prefix table of the spec before the root rules.
  A prefix matches only the full name or the name up to a dot, so `variable.membership` stays `variable`.
  The longest prefix wins.
- `tools/generate_lua_pattern_cases.py` writes `src/highlight/lua_pattern_cases.zig`.
  It takes every `#lua-match?` and `#not-lua-match?` pattern of the M27 queries and their bases at the pinned commit.
  It adds 24 patterns for the classes, complements, sets, escapes, anchors, and the lazy quantifier.
  LuaJIT, the Lua of Neovim, gives the `string.find` result for each of 52 samples.
- `zig build test` runs `python3 tests/adapt_queries_test.py`.

### Defaults chosen

- A predicate holds for every node of its Capture, as in Neovim.
  So a predicate on an absent optional Capture holds, and its `not-` form rejects the match.
  Before this ticket, an absent Capture failed the Highlighting of the File with `MissingPredicateCapture`.
  No M13 query uses an optional or quantified Capture in a predicate, so the M13 Spans do not change.
- `#has-ancestor?` and `#has-parent?` compare the `ts_node_type` text of each ancestor, as in Neovim.
- An injection query and a locals query also accept `#set! priority`.
  Only the highlight query uses the priority.
- A `not-` form of any other operator fails with `unknown_operator`.
- The ticket says to wire the Python test like `tests/check_box_glyphs_test.py`.
  `build.zig` does not run that test.
  So `tests/adapt_queries_test.py` runs as a system command, like `tools/check_box_glyphs.py`.

### Tests

- `src/highlight/tree_sitter_highlighter.zig`:
  "M27 grammar each new predicate accepts and rejects a match",
  "M27 grammar set priority changes the winner between overlapping patterns",
  "M27 grammar a hidden Capture produces no Span and still filters",
  "M27 grammar a predicate on an absent optional Capture behaves like Neovim", and
  "M27 grammar every Capture name in the M13 queries keeps its role".
- `src/highlight/query_predicates.zig`:
  "M27 grammar rejects malformed new predicates and priorities" and
  "M27 grammar RE2 compiles each translated Lua pattern and matches like Lua".
- `src/highlight/highlighter.zig`:
  "M27 grammar dotted prefixes map nvim-treesitter Captures to their roles".
- `src/highlight/user_grammar.zig`:
  "M27 grammar UserGrammar validation accepts the new predicates and priority".
- `tests/adapt_queries_test.py`:
  `test_the_lua_pattern_cases_hold_the_current_translation` fails when `lua_to_re2` changes and the cases are not generated again.

The golden list holds the 28 Capture names of the 8 M13 highlight queries.
A program ran the `Capture.init` of HEAD on each name before the change.
The test fails on a name that is not in the list, and on a list name that no query has.

Three mutations prove that the tests detect faults.
A `Set.accepts` that ignores `negated` fails 3 M27 grammar tests.
A priority that is always 100 fails the priority test.
The RE2 form `^a.*?b$` for the Lua pattern `^a.-b$` fails the Lua comparison on `a\nb` and the Python drift test.

### Checks

| Command | Result |
| --- | --- |
| `zig fmt --check build.zig src` | Pass. |
| `zig build` | Pass. |
| `zig build test-builtin-grammars --summary all` | Pass. 27 of 27 tests. |
| `python3 tests/adapt_queries_test.py` | Pass. 24 tests. |
| `zig build test --summary all` | Pass. 25 of 25 steps and 1402 of 1402 tests. The count was 1393 before this ticket. |

The native target is `aarch64-macos`.

### Changed paths

- `build.zig`
- `src/highlight/highlighter.zig`
- `src/highlight/query_predicates.zig`
- `src/highlight/runtime_package.zig`
- `src/highlight/tree_sitter_highlighter.zig`
- `src/highlight/user_grammar.zig`
- `src/highlight/lua_pattern_cases.zig` (new, generated)
- `tools/adapt_queries.py` (new)
- `tools/generate_lua_pattern_cases.py` (new)
- `tests/adapt_queries_test.py` (new)
- `vendors/tree-sitter/nvim-treesitter/LICENSE` (new)
