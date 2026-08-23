# Tree-sitter query predicate contract research

## Sources

- [Tree-sitter v0.26.9 predicate and directive documentation](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/queries/3-predicates-and-directives.md)
- [Tree-sitter v0.26.9 C API](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/lib/include/tree_sitter/api.h)
- [Tree-sitter v0.26.9 Rust binding predicate decoder](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/lib/binding_rust/lib.rs)
- [Tree-sitter v0.26.9 highlighter local-variable handling](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/crates/highlight/src/highlight.rs)
- [Upstream JavaScript locals query at the vendored commit](https://github.com/tree-sitter/tree-sitter-javascript/blob/58404d8cf191d69f2674a8fd507bd5776f46cb11/queries/locals.scm)
- [Upstream TypeScript locals query at the vendored commit](https://github.com/tree-sitter/tree-sitter-typescript/blob/75b3874edb2dc714fb1fd77a32013d0f8699989f/queries/locals.scm)
- [`TreeSitterHighlighter`](../../../src/highlight/tree_sitter_highlighter.zig)
- [Vendored runtime API](../../../vendors/tree-sitter/runtime/include/tree_sitter/api.h)
- [Vendored source manifest](../../../vendors/tree-sitter/manifest.zig.zon)
- [Highlighting context](../../../src/highlight/CONTEXT.md)
- [ADR-0009](../../../docs/adr/0009-built-in-grammars-now-user-grammars-later.md)
- [ADR-0010](../../../docs/adr/0010-file-enrichment-transfers-per-side-ownership.md)

## BuiltInGrammar inventory

All eight vendored `highlights.scm` files match their recorded SHA-256 values. Their complete predicate/directive inventory is:

| Query | Predicates | Directives |
| --- | --- | --- |
| JavaScript | three `#match?`; one `#eq?`; two `#is-not? local` | none |
| TypeScript | one `#match?` | none |
| TSX | one `#match?` | none |
| CSS | two `#match?` | none |
| Go | one `#match?` | none |
| Bash | one `#match?` | none |
| JSON | none | none |
| YAML | none | none |

The nine regular expressions are ASCII-only: JavaScript uses `^[A-Z]`, `^[A-Z_][A-Z\\d_]+$`, and `^(arguments|module|console|window|document)$`; TypeScript and TSX each use `^[A-Z]`; CSS uses `^--` twice; Go uses one anchored alternation of built-in function names; Bash uses `^-`. JavaScript uses `#eq? @function.builtin "require"`. Its two `#is-not? local` conditions guard the built-in variable and `require` patterns.

The effective TypeScript and TSX queries concatenate JavaScript with their own query. They therefore execute all six JavaScript predicate instances plus their own `#match?`. JSON and YAML have no conditional patterns.

## Exposed capability and current gap

The repository has no predicate-evaluating Zig binding. Zig imports the vendored C API directly with `@cImport`. The C runtime parses arbitrary predicate/directive S-expressions and exposes them as capture, string, and done steps through `ts_query_predicates_for_pattern`. It also exposes capture names, string values, capture quantifiers, match captures, node byte ranges, query error type/offset, and `ts_query_cursor_did_exceed_match_limit`.

The C runtime does not evaluate text predicates, regular expressions, local-variable properties, or directives. Tree-sitter assigns that work to higher-level consumers. Zig 0.16.0 `std` and this repository have no regular-expression engine. The official Rust binding adds `#eq?`, `#match?`, `#any-of?`, their documented variants, `#is?`, `#is-not?`, and `#set!` above the same C API. Its `#match?` implementation uses a byte regular-expression engine. The official highlighter implements `#is-not? local` only with a separate locals query. It tracks scopes, definitions, and references.

The adapter currently treats any non-empty predicate-step list as false and silently skips the complete match. Thus all 12 conditional patterns are always rejected, including valid matches. The broad tests still pass because they only require some Capture from each Grammar; unconditional fallback patterns hide the loss. The adapter also vendors no locals query, reports no unsupported operator, ignores invalid capture ranges, and does not check cursor match loss.

## Required adapter contract

- One predicate profile applies to BuiltInGrammars and UserGrammars. Provenance cannot change Highlighting behavior.
- At Grammar validation, parse every pattern's steps. Accept only implemented operators and valid signatures. M17's minimum profile is `#eq?` with a capture followed by a capture or string, `#match?` with a capture and string, and `#is-not? local`. Compile every regular expression once during validation.
- Reject a Grammar atomically for an unknown operator, any directive, malformed arguments, invalid regular expression, or unsupported property. Report the Grammar identity, query source, operator, pattern index, source byte, line, and column. Never ignore the step, disable only that pattern, or activate a partially valid query.
- Vendor and checksum the pinned JavaScript locals query and TypeScript locals extension. JavaScript uses the JavaScript query. TypeScript and TSX combine JavaScript locals with the TypeScript extension, as they already combine highlight queries. `#is-not? local` is true only when the data does not resolve the captured identifier as a local definition or reference. Do not approximate it as always true or always false.
- Evaluate all text and property predicates for a match as logical AND before applying any capture from that match. A false predicate is a normal rejected match and produces no diagnostic. A true match applies all public highlight captures. A predicate error fails Highlighting; it does not produce partial Spans.
- Preserve query precedence after filtering: for overlapping bytes, a capture from a later query pattern replaces an earlier fallback Capture. A rejected later pattern leaves the earlier Capture intact. Do not depend on `ts_query_cursor_next_match` discovery order to define this precedence.
- Keep the query cursor unbounded. After iteration, treat `ts_query_cursor_did_exceed_match_limit` as a Highlighting error if it is ever true. Do not permit the runtime's documented silent match-drop path.
- A zero-width capture produces no Span by explicit rule. An out-of-bounds or non-UTF-8-boundary capture is an error, not a skipped capture. Successful output keeps the existing ordered, non-overlapping, half-open UTF-8 Span contract.
- BuiltInGrammar validation failures must fail their fixture tests. At runtime, any unexpected query/predicate failure becomes the side's visible `highlight_failed` outcome while the fetched File content remains usable as plain text, consistent with ADR-0010. UserGrammar install/update must reject the candidate before activation and retain the previous working Grammar.

The profile can later add the documented `not-`, quantified `any-`, `#any-of?`, or directive families. They are not required by the current BuiltInGrammars and must remain rejected until their semantics and tests are implemented.

## Fixture and test contract

- Add an inventory test over every embedded BuiltInGrammar query. Assert the exact operator/signature set above and no directives. A vendored query update that adds a capability must fail this test before captures can disappear.
- Add paired accepted/rejected source fixtures for every conditional role: uppercase/lowercase JavaScript constructor; screaming/non-screaming constant; global/shadowed `console`; global/shadowed `require`; uppercase/lowercase TypeScript and TSX identifier; CSS custom/ordinary property; Go built-in/ordinary call; Bash option/ordinary argument. Assert exact byte range and final Capture, not only non-empty output.
- For every pair, assert fallback preservation: accepted specialized Capture replaces the unconditional Capture on the same bytes; rejected specialized Capture leaves the unconditional Capture unchanged. This detects both silent match drops and predicates applied too broadly.
- Add synthetic query tests for both `#eq?` argument forms, `#match?`, and multiple predicates as AND. Add failure cases for malformed arguments, invalid regex, an unknown predicate, an unsupported property, and each directive spelling. Assert atomic query rejection and the diagnostic location.
- Add local-scope fixtures for parameter, variable, nested scope, and shadowing cases. Assert that `console` and `require` become built-ins only outside a resolved local definition or reference. Run these fixtures for JavaScript, TypeScript, and TSX combined queries.
- Keep one exact-output fixture for JSON and YAML to prove predicate-free queries remain unchanged. Keep a multibyte UTF-8 fixture, an overlap-precedence fixture, a zero-width synthetic capture, and a cursor-loss assertion.
- Make the fixtures reachable from the test root and verify the test count increases. The current 555-test suite passes without this contract and is not evidence of predicate correctness.

## Remaining implementation decision

The runtime supplies no regex engine, and Tree-sitter does not define one cross-binding regex dialect. Before implementation, M17 must choose and pin a byte-oriented regex engine, or explicitly define a restricted syntax. The recommended choice is a pinned, linear-time byte regex engine with behavior fixed by conformance fixtures. An exact-pattern switch would satisfy today's nine expressions but would make ordinary UserGrammar queries fail and is not a credible final M17 contract. Until an engine is selected, UserGrammar `#match?` compatibility remains the only unresolved predicate-design item.
