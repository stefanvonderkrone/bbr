# 01: Add Injection to TreeSitterHighlighter

Status: ready-for-agent
Blocked by: none
Spec: [M27 spec](../SPEC.md)

## What to build

`TreeSitterHighlighter` can highlight a region of a File with a second BuiltInGrammar.
This slice proves Injection with the existing JavaScript, CSS, and JSON BuiltInGrammars and synthetic injection queries.
No existing BuiltInGrammar gets an injection query in this slice, so production output does not change.
The `Highlighter` seam does not change.

## Scope

- Add `QueryKind.injections` to `Diagnostic` in `src/highlight/query_predicates.zig`.
  Accept the injection directives from the "Supported injection query forms" table of the spec only in an injection query.
  A highlight query with an injection directive still fails with `unsupported_directive`.
- Give `RuntimePackage` in `src/highlight/runtime_package.zig` an optional prepared injection query, the `injection.content` and `injection.language` ids, and the per-pattern injection settings.
- Add `src/highlight/grammar_name.zig` with the alias table from `code_highlighting.fencePath`, and export it as `bbr.highlight.grammar_name`.
  Make `fencePath` in `src/tui/code_highlighting.zig` use it.
  Add the aliases that the "Grammar name resolution" section of the spec lists.
- Add the Grammar name resolution to `src/highlight/grammar_match.zig`.
- Implement the algorithm from the "Algorithm" section of the spec in `src/highlight/tree_sitter_highlighter.zig`.
  Carry the resolved `Capture`, the priority, and the layer depth in `CaptureInterval`.
  Use a default priority of 100 until ticket 02 reads `#set! priority`.
  Compare layer depth before pattern index in `higherPrecedence`.
  Join two adjacent Spans only when their Captures are equal.
- Never resolve a UserGrammar as a host or as an injected Grammar.
- Extend `spansFromBytePlanes` so that the oracle respects layer depth and priority.
- Add the `test-builtin-grammars` build step with the filter `M27`.

## Acceptance criteria

- [ ] A synthetic JavaScript injection query injects CSS into a template string, and the Spans have CSS roles.
- [ ] A combined injection forms one injected tree from two separate ranges.
- [ ] Without `include-children`, a child node range gets no injected Span.
- [ ] `#offset!` moves the range, and an invalid offset drops only that Injection.
- [ ] Depth stops at 4 for a self-injecting synthetic query.
- [ ] A deeper layer wins at equal priority.
- [ ] An unknown Grammar name gives no Injection and no failure.
- [ ] `text/javascript` resolves to JavaScript.
- [ ] The alias table maps `kotlin` to `kt`, `make` to `mk`, `docker` to `dockerfile`, `md` to `md`, and `c_sharp` to `cs`.
- [ ] A UserGrammar that claims `.css` does not become the injected Grammar for CSS.
- [ ] Injected Spans are ordered, line-relative, and inside their layer ranges, and they equal the byte-plane oracle.
- [ ] A highlight query with `#set! injection.language` fails with `unsupported_directive`.
- [ ] All M13 and M23 highlighting tests pass without change.
  The only exception is the `kOtLiN` fence alias case, which now expects `review.kt`.

## Tests that prove it

- "M27 injection" tests in `src/highlight/tree_sitter_highlighter.zig`, including "M27 injection Spans stay ordered and inside their layer ranges" and "M27 injection ignores UserGrammars".
- Validation tests in `src/highlight/query_predicates.zig` for injection directives in both query kinds.
- "M23 highlighting approved fence aliases and invalid identifiers" in `src/tui/code_highlighting.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `zig build test-code-highlighting`
- `zig build test --summary all`
