# 11: Vendor PHP with embedded HTML Injection

Status: ready-for-agent
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

- [ ] `tools/check_vendored_grammars.py` passes for PHP.
- [ ] `vendors/tree-sitter/common/scanner.h` keeps its checksum.
- [ ] Every query loads, and the ABI is in the runtime range.
- [ ] `.php` selects PHP.
- [ ] A PHP fixture has comment, string, keyword, function, and variable roles.
- [ ] HTML before and after `<?php ... ?>` has HTML Spans, and no HTML Span covers PHP code.
- [ ] A `<script>` in the HTML part has JavaScript Spans.
- [ ] A heredoc with the closing name `HTML` has HTML Spans.
- [ ] The adapted injection query records the removed `phpdoc` and `regex` patterns with `; bbr:` comments.
- [ ] Each fixture joins the byte-plane oracle test.

## Tests that prove it

- "M27 grammar" Capture fixture and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- "M27 injection" PHP tests in `src/highlight/tree_sitter_highlighter.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`
