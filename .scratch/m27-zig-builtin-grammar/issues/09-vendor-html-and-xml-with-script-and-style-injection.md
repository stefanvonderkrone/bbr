# 09: Vendor HTML and XML with script and style Injection

Status: resolved
Blocked by: 01, 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for HTML, XML, and SVG Files.
In an HTML File, `<script>` content has JavaScript highlighting, and `<style>` content has CSS highlighting.
HTML is the first production Injection host.

## Scope

- Vendor `html` and `xml` with `tools/vendor_grammar.py` at the revisions that the pinned nvim-treesitter commit names.
- Keep the XML `location` layout, and copy `common/scanner.h` below `vendors/tree-sitter/xml/`.
- Copy the raw `html_tags` queries, and the raw `dtd` queries if the `xml` queries inherit them.
- Adapt `html_tags/injections.scm` and `html/injections.scm` into `vendors/tree-sitter/html/queries/injections.scm`.
- Embed the HTML injection query and prepare it in the HTML `RuntimePackage`.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.

## Acceptance criteria

- [x] `tools/check_vendored_grammars.py` passes for both Grammars.
- [x] `vendors/tree-sitter/common/scanner.h` keeps its checksum.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.html` and `.htm` select HTML, and `.xml` and `.svg` select XML.
- [x] Each Grammar has a Capture fixture with tag, property, string, and comment roles.
- [x] `<script>` content has JavaScript Spans, and `<style>` content has CSS Spans.
- [x] `<script type="text/javascript">` content has JavaScript Spans.
- [x] `<script type="module">` content has JavaScript Spans, and `<script type="importmap">` content has JSON Spans.
- [x] A `style` attribute value has CSS Spans.
- [x] The adapted injection query records the removed `comment`, `regex`, and `#gsub!` forms with `; bbr:` comments.
- [x] A fenced `html` block in a ReviewBody gets HTML Spans and injected JavaScript Spans.
- [x] Each fixture joins the byte-plane oracle test.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- "M27 injection" HTML tests in `src/highlight/tree_sitter_highlighter.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`

## Completion

### Change summary

- `tools/vendor_grammar.py` vendored `html` with `--injections` and `xml` at the pinned revisions, and updated the manifest.
- The tool copied the raw `html`, `html_tags`, and `xml` queries. The pinned `xml` queries do not inherit `dtd`, so no `dtd` query is in the tree.
- The XML scanner include is at `vendors/tree-sitter/xml/common/scanner.h`. `vendors/tree-sitter/common/scanner.h` keeps the checksum `da66ef2b...e564c`.
- `BuiltInGrammar` gets the tags `html` and `xml` after `zig`.
- The adapted HTML injection query records the removed `comment`, `regex`, `python`, and `toml` patterns and the removed `#gsub!` with `; bbr:` comments.
- `type="module"` and `type="importmap"` use the static `javascript` and `json` patterns of the query. The captured name `module` or `importmap` resolves to no Grammar, so that match has no Injection. So no alias is necessary.
- The adapted HTML highlight query has the pattern `(attribute_value)` with no Capture, because the adapter removed `@nospell`. The tree-sitter runtime gives a null capture pointer to such a match, and the highlighter stopped with a panic. The new `query_predicates.capturesOf` returns an empty slice for that match. All five capture loops use it.
- `addTreeSitter` in `build.zig` builds the Grammar source paths at build time with `b.pathJoin`. Ticket 04 made this change. So the build needs no higher comptime branch quota.
- The runner reran `tools/vendor_grammar.py` for `html` with `--injections` after tickets 06 and 08. The HTML injection query now keeps the Python and TOML Injections.

### Commands and results

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars --summary all`: 44/44 tests passed.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: OK.
- `zig build test --summary all`: 27/27 steps succeeded, 1419/1419 tests passed.
- `python3 tools/check_agent_docs.py`: pass.

### Tests

- "M27 grammar GrammarMatch selects HTML and XML".
- "M27 grammar HTML fixture has tag, property, string, and comment roles".
- "M27 grammar XML fixture has tag, property, string, and comment roles".
- "M27 grammar a highlight pattern without Captures produces no Span and no failure".
- "M27 injection HTML script and style content get JavaScript and CSS Spans".
- "M27 injection HTML style attribute value gets CSS Spans".
- "M27 injection HTML script type selects JavaScript or JSON".
- "M27 injection a fenced html block in a ReviewBody gets HTML and injected JavaScript Spans" in `src/tui/presentation.zig`, next to the Zig fence test.
- The HTML and XML fixtures join "interval merge matches byte planes for every BuiltInGrammar fixture".

### Defaults chosen

- tree-sitter-css parses a `style` attribute value such as `color: red` as a selector. So `color` gets the CSS `tag` Capture, not `property`. Neovim uses the same Grammar and query, so it shows the same result. The test asserts the CSS `tag` Capture.
- The HTML query keeps no `python` or `toml` Injection, because those BuiltInGrammars are not in the manifest of this branch. After the merge with ticket 06 and ticket 08, rerun the tool for `html` with `--injections`, because the kept static names can change.
