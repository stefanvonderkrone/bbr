# 02: Adapt nvim-treesitter queries and support their predicates

Status: ready-for-agent
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

- [ ] Each new predicate accepts and rejects a match on a synthetic JavaScript query.
- [ ] `#set! priority` changes the winner between two overlapping patterns.
- [ ] A Capture that starts with `_` produces no Span.
- [ ] Each prefix in the Capture classification table maps to its role.
- [ ] Every Capture name in the 8 M13 queries keeps its role, proved by a golden list.
- [ ] The adaptation resolves nested and optional `; inherits:` lines in order, and a missing required base stops it.
- [ ] The adaptation rewrites `#lua-match?`, `#not-lua-match?`, and `#contains?`, and RE2 compiles each result.
- [ ] The Lua translation handles each listed class, and it rejects `%b`, `%f`, and back references.
- [ ] The adaptation removes `conceal`, `conceal_lines`, `url`, and highlight `#offset!` directives, and `@spell`, `@nospell`, `@conceal`, and `@conceal_lines` Captures, each with a `; bbr:` comment.
- [ ] An unknown predicate stops the adaptation with the file, the line, and the form.
- [ ] Two runs of the adaptation on the same input give the same bytes.
- [ ] UserGrammar validation accepts the new predicates, and the M17 UserGrammar tests pass.

## Tests that prove it

- "M27 grammar" predicate, priority, hidden Capture, and classification tests in `src/highlight/tree_sitter_highlighter.zig`, `src/highlight/query_predicates.zig`, and `src/highlight/highlighter.zig`.
- `tests/adapt_queries_test.py`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tests/adapt_queries_test.py`
- `zig build test --summary all`
