# 11: Vendor PHP with embedded HTML Injection

Status: resolved
Blocked by: 09
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for PHP Files.
The PHP code has PHP highlighting.
The HTML around the PHP code has HTML highlighting through one combined Injection.
A `<script>` inside the HTML has JavaScript highlighting.

## Scope

- Vendor `php` with `tools/vendor_grammar.py` at the revision that the pinned nvim-treesitter commit names.
- Keep the `php` `location` layout, and copy `common/scanner.h` below `vendors/tree-sitter/php/`.
- Copy the raw `php_only` queries for inheritance.
  Do not compile the `php_only` source.
- Adapt and embed the PHP highlight query and injection query.
- Add the manifest entry, the enum tag, the name, the `extern` symbol, the `grammarSource` arm, and the GrammarMatch row from the spec.

## Acceptance criteria

- [x] `tools/check_vendored_grammars.py` passes for PHP.
- [x] `vendors/tree-sitter/common/scanner.h` keeps its checksum.
- [x] Every query loads, and the ABI is in the runtime range.
- [x] `.php` selects PHP.
- [x] A PHP fixture has comment, string, keyword, function, and variable roles.
- [x] HTML before and after `<?php ... ?>` has HTML Spans, and no HTML Span covers PHP code.
- [x] A `<script>` in the HTML part has JavaScript Spans.
- [x] A heredoc with the closing name `HTML` has HTML Spans.
- [x] The adapted injection query records the removed `phpdoc` and `regex` patterns with `; bbr:` comments.
- [x] Each fixture joins the byte-plane oracle test.

## Tests that prove it

- "M27 grammar" Capture fixture and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- "M27 injection" PHP tests in `src/highlight/tree_sitter_highlighter.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`

## Completion

### Change summary

- `tools/vendor_grammar.py` vendors `php` at `58d5643086ae60e93a3746cca648363ee97c8761` with `--injections` and `--update-manifest`.
- The tool copies `common/scanner.h` to `vendors/tree-sitter/php/common/scanner.h`.
- `vendors/tree-sitter/common/scanner.h` keeps the SHA-256 `da66ef2bd14a3f7ea743e25ba068c6c9aae2c3509db200ff80c4a0e6116e564c`.
- The build compiles only `php/php/src/parser.c` and `php/php/src/scanner.c`. The `php_only` queries are raw copies for inheritance.
- The adapted injection query keeps `(text)` to `html` as a combined Injection, the heredoc and nowdoc patterns, and the `bash` patterns.
- The adapted injection query removes the `phpdoc` and `regex` patterns with `; bbr:` comments.
- `BuiltInGrammar` gets the last tag `php`.
- The tool made no adapter change and no `tree_sitter_highlighter.zig` Injection fix.

### Tests

- "M27 grammar GrammarMatch selects PHP"
- "M27 grammar PHP fixture has comment, string, keyword, function, and variable roles"
- "M27 injection PHP text around the PHP code gets HTML Spans and the PHP code gets none"
- "M27 injection PHP script reaches JavaScript through the HTML Injection"
- "M27 injection PHP heredoc with the closing name HTML gets HTML Spans"
- "M27 injection PHP joins the HTML text around PHP code into one combined HTML tree"
- "interval merge matches byte planes for every BuiltInGrammar fixture" has three new PHP cases.

The combined test fails when the adapted query has no `injection.combined`.
A local mutation run proved this. The query is unchanged after the run.

### Commands and results

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars`: pass.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: 24 tests, OK.
- `zig build test --summary all`: 27/27 steps succeeded, 1455/1455 tests passed.
- `python3 tools/check_agent_docs.py`: pass.

### Defaults chosen

- Only `.php` selects PHP, as the spec GrammarMatch row says. `.phtml` selects no BuiltInGrammar.
- In a heredoc, the PHP `@string` Capture at default priority 100 wins over the HTML attribute `@string` at priority 99. Priority comes before depth, as the spec says. Both Captures have the string role, so the reviewer sees no difference.
