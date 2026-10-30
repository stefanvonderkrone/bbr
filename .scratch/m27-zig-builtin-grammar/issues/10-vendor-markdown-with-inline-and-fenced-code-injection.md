# 10: Vendor Markdown with inline and fenced code Injection

Status: ready-for-agent
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

- [ ] `tools/check_vendored_grammars.py` passes for both Grammars.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.md` and `.markdown` select Markdown, and no path selects Markdown inline.
- [ ] A heading has the `keyword` role, and inline code has the `string` role.
- [ ] A link has the `string` role, and a list marker has the `punctuation` role.
- [ ] Emphasis keeps the default foreground.
- [ ] A fenced `zig` block has Zig Spans, and a fenced `js` block has JavaScript Spans.
- [ ] A fenced block with an unknown info string has no injected Spans.
- [ ] A fenced block inside a block quote has no injected Span on the `>` marker.
- [ ] An HTML block inside Markdown has HTML Spans.
- [ ] YAML front matter has YAML Spans, and TOML front matter has TOML Spans.
- [ ] A fenced `js` block uses the JavaScript BuiltInGrammar, also when a UserGrammar claims `.js`.
- [ ] Each fixture joins the byte-plane oracle test.
- [ ] The highlight time of the large Markdown fixture is recorded.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- "M27 injection" Markdown tests in `src/highlight/tree_sitter_highlighter.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`
