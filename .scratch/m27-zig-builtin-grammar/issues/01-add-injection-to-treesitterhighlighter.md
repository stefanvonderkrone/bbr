# 01: Add Injection to TreeSitterHighlighter

Status: resolved
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

- [x] A synthetic JavaScript injection query injects CSS into a template string, and the Spans have CSS roles.
- [x] A combined injection forms one injected tree from two separate ranges.
- [x] Without `include-children`, a child node range gets no injected Span.
- [x] `#offset!` moves the range, and an invalid offset drops only that Injection.
- [x] Depth stops at 4 for a self-injecting synthetic query.
- [x] A deeper layer wins at equal priority.
- [x] An unknown Grammar name gives no Injection and no failure.
- [x] `text/javascript` resolves to JavaScript.
- [x] The alias table maps `kotlin` to `kt`, `make` to `mk`, `docker` to `dockerfile`, `md` to `md`, and `c_sharp` to `cs`.
- [x] A UserGrammar that claims `.css` does not become the injected Grammar for CSS.
- [x] Injected Spans are ordered, line-relative, and inside their layer ranges, and they equal the byte-plane oracle.
- [x] A highlight query with `#set! injection.language` fails with `unsupported_directive`.
- [x] All M13 and M23 highlighting tests pass without change.
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

## Completion

The changes are uncommitted.
The runner reviews and commits them.
The code review is the runner's review.

### Change summary

- `src/highlight/grammar_name.zig` is new and C-free.
  It holds the alias table, and `bbr.highlight.grammar_name` exports it.
  The table adds `kotlin`, `make`, `makefile`, `docker`, `dockerfile`, `markdown`, `md`, and `c_sharp`.
- `fencePath` in `src/tui/code_highlighting.zig` uses the shared table.
  The `kOtLiN` case now expects `review.kt`.
- `grammar_match.selectInjection` resolves an Injection Grammar name in the order of the spec.
  It returns only a BuiltInGrammar.
- `Diagnostic.QueryKind` has `.injections`.
  `Set.validateInjections` accepts `#set! injection.language`, `#set! injection.combined`, `#set! injection.include-children`, and `#offset!`.
  `Set.validate` still rejects them with `unsupported_directive`.
- `RuntimePackage.init` takes an injection query source.
  `RuntimePackage.injection` holds the prepared query, the per-pattern `Injection` settings, and the `injection.content` and `injection.language` ids.
  A UserGrammar and every production BuiltInGrammar pass an empty source, so they have no injection query.
- `collectCaptureIntervals` in `src/highlight/tree_sitter_highlighter.zig` parses a queue of layers.
  Each layer has a package, sorted `TSRange` values, and a depth.
  The host layer has depth 0, and a layer at depth 4 runs no injection query.
- `CaptureInterval` carries the resolved `Capture`, the priority, and the depth.
  The priority is 100 until ticket 02.
  `higherPrecedence` compares the priority, then the depth, then the pattern index, then the order.
  Two adjacent Spans join only when their Captures are equal.
- `spansFromBytePlanes` gives each byte the interval with the highest priority, depth, pattern index, and order.
- `build.zig` has the `test-builtin-grammars` step with the filter `M27`.

### Defaults chosen

- An injected range is clipped to the ranges of its parent layer.
  So an Injection never covers a byte that its host layer excludes.
- A captured `@injection.language` name takes precedence over a static `#set! injection.language` name.
- `#offset!` must name `@injection.content`.
  Any other capture fails with `malformed_arguments`.
- An offset point is dropped when its row is not in the File or its column is past the end of its line.
- A Grammar name longer than 64 bytes resolves to no BuiltInGrammar.
- An injection query without an `@injection.content` capture fails with `InvalidInjectionQuery`.
- An injection query predicate sees no locals.
  So `#is-not? local` always accepts in an injection query.

### Tests

- `src/highlight/tree_sitter_highlighter.zig`:
  "M27 injection highlights CSS in a JavaScript template string",
  "M27 injection combined ranges form one injected tree",
  "M27 injection without include-children leaves child node ranges to the host",
  "M27 injection offset moves the range and an invalid offset drops only its Injection",
  "M27 injection depth stops at 4 for a self-injecting query",
  "M27 injection a deeper layer wins at equal priority",
  "M27 injection a higher host priority wins over a deeper layer",
  "M27 injection resolves a captured Grammar name",
  "M27 injection an unknown Grammar name gives no Injection and no failure",
  "M27 injection ignores UserGrammars", and
  "M27 injection Spans stay ordered and inside their layer ranges".
- `src/highlight/query_predicates.zig`:
  "M27 injection directives validate only in an injection query" and
  "M27 injection query rejects malformed and unknown directives".
- `src/highlight/grammar_match.zig`:
  "M27 injection Grammar names resolve through tags, aliases, and GrammarMatch" and
  "M27 injection alias table maps the new Grammar names".

The M13 test "interval merge matches byte planes for every BuiltInGrammar fixture" has new call arguments only.
`collectCaptureIntervals`, `mergeCaptureIntervals`, and `spansFromBytePlanes` changed their parameters.
Its fixtures and its assertion did not change.

Two mutations prove that the tests detect faults.
A maximum depth of 5 fails the depth test.
A `higherPrecedence` without the depth comparison fails 7 M27 tests.

### Checks

| Command | Result |
| --- | --- |
| `zig fmt --check build.zig src` | Pass. |
| `zig build` | Pass. |
| `zig build test-builtin-grammars --summary all` | Pass. 19 of 19 tests. |
| `zig build test-code-highlighting --summary all` | Pass. 29 of 29 tests. |
| `zig build test --summary all` | Pass. 24 of 24 steps and 1393 of 1393 tests. The count was 1378 before this ticket. |

The native target is `aarch64-macos`.

### Changed paths

- `build.zig`
- `src/root.zig`
- `src/highlight/grammar_name.zig` (new)
- `src/highlight/grammar_match.zig`
- `src/highlight/query_predicates.zig`
- `src/highlight/runtime_package.zig`
- `src/highlight/tree_sitter_highlighter.zig`
- `src/highlight/user_grammar.zig`
- `src/tui/code_highlighting.zig`
