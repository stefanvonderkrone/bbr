# 10: Vendor Markdown with inline and fenced code Injection

Status: resolved
Blocked by: 08, 09
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for Markdown Files.
Headings, lists, and quotes come from the `markdown` BuiltInGrammar.
Inline code, links, and emphasis come from the `markdown_inline` BuiltInGrammar through Injection.
A fenced code block gets the BuiltInGrammar that its info string names.

## Scope

- Vendor `markdown` and `markdown_inline` with `tools/vendor_grammar.py` at the revision that the pinned nvim-treesitter commit names.
- Keep both `location` layouts.
- Add `markdown_inline` as a BuiltInGrammar with no GrammarMatch row.
- Adapt and embed the injection queries of both Grammars.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and the Markdown GrammarMatch row from the spec.
- Record the highlight time of a Markdown fixture of about 1 MiB with many paragraphs under `## Completion`.

## Acceptance criteria

- [x] `tools/check_vendored_grammars.py` passes for both Grammars.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.md` and `.markdown` select Markdown, and no path selects Markdown inline.
- [x] A heading has the `keyword` role, and inline code has the `string` role.
- [x] A link has the `string` role, and a list marker has the `punctuation` role.
- [x] Emphasis keeps the default foreground.
- [x] A fenced `zig` block has Zig Spans, and a fenced `js` block has JavaScript Spans.
- [x] A fenced block with an unknown info string has no injected Spans.
- [x] A fenced block inside a block quote has no injected Span on the `>` marker.
- [x] An HTML block inside Markdown has HTML Spans.
- [x] YAML front matter has YAML Spans, and TOML front matter has TOML Spans.
- [x] A fenced `js` block uses the JavaScript BuiltInGrammar, also when a UserGrammar claims `.js`.
- [x] Each fixture joins the byte-plane oracle test.
- [x] The highlight time of the large Markdown fixture is recorded.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- "M27 injection" Markdown tests in `src/highlight/tree_sitter_highlighter.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`

## Completion

### Change summary

- `tools/vendor_grammar.py` vendored `markdown_inline` and then `markdown`, both with `--injections`, and updated the manifest.
- Both Grammars keep their `location` layouts: `tree-sitter-markdown-inline` and `tree-sitter-markdown`.
- `markdown_inline` has an empty GrammarMatch row. So no path selects it, and only an Injection selects it.
- `BuiltInGrammar` gets the tags `markdown_inline` and `markdown` after `xml`.
- The two scanners export no common global symbol. `nm -g` on the compiled objects shows only `tree_sitter_markdown*` and `tree_sitter_markdown_inline*` symbols.
- The adapted Markdown injection query keeps the fenced code, HTML block, YAML front matter, TOML front matter, and `markdown_inline` patterns.
- The adapted Markdown inline injection query keeps the combined `html` pattern and records the removed `latex` pattern.
- Every required Injection worked with the existing algorithm. No change to `tree_sitter_highlighter.zig` outside the tests was necessary.
- `src/benchmark/main.zig` gets the benchmark `highlight_markdown_1m`. It generates the fixture at run time, so the repository holds no 1 MiB fixture.

### Large Markdown fixture

- Fixture: 12,788 copies of a heading and a paragraph with inline code, a link, and emphasis. The size is 1,048,616 bytes. So the host tree has 25,576 `inline` nodes, and each one is an Injection layer.
- Method: `zig build bench -Doptimize=ReleaseSafe -- highlight_markdown_1m` on an Apple M5 Pro with macOS. The harness runs 2 warmups and 15 samples.
- Result: median 434 ms, p95 444 ms.
- Reference: `highlight_javascript_1m` has a median of 300 ms on the same build.
- Limiter: a `sample` profile shows that the tree-sitter runtime uses the time, in `ts_lex`, `ts_parser_parse`, `ts_query_cursor__advance`, and the tree cursor. The Span merge does not show in the top frames.
- A 2 MiB variant took a median of 1,143 ms, so the time grows a little faster than the size. Nobody investigated this further.

### Commands and results

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars --summary all`: 84/84 tests passed.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: OK.
- `zig build test --summary all`: 27/27 steps succeeded, 1459/1459 tests passed.
- `python3 tools/check_agent_docs.py`: pass.
- A removed fenced code pattern in the adapted Markdown injection query made the three fenced code tests fail.

### Tests

- "M27 grammar GrammarMatch selects Markdown and no path selects Markdown inline".
- "M27 grammar Markdown fixture has keyword, punctuation, and string roles".
- "M27 injection Markdown inline gives inline code and links the string role and keeps emphasis default".
- "M27 injection Markdown pipe table cells get Markdown inline Spans".
- "M27 injection Markdown fenced zig and js blocks get Zig and JavaScript Spans".
- "M27 injection Markdown fenced block with an unknown info string has no injected Spans".
- "M27 injection Markdown fenced block in a block quote has no injected Span on the quote marker".
- "M27 injection Markdown HTML block and inline HTML get HTML Spans".
- "M27 injection Markdown YAML and TOML front matter get YAML and TOML Spans".
- "M27 injection Markdown fenced js block uses the JavaScript BuiltInGrammar when a UserGrammar claims .js".
- The Markdown fixture joins "interval merge matches byte planes for every BuiltInGrammar fixture".

### Defaults chosen

- The info string of a fenced code block gets the `@label` Capture. That Capture has the `variable` role, as the SPEC classification gives.
- The full fenced code block has the `markup.raw.block` Capture at priority 90. So injected Spans win inside the block, and the fences keep the `string` role.
