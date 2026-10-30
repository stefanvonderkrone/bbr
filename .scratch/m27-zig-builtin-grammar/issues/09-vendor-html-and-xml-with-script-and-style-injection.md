# 09: Vendor HTML and XML with script and style Injection

Status: ready-for-agent
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

- [ ] `tools/check_vendored_grammars.py` passes for both Grammars.
- [ ] `vendors/tree-sitter/common/scanner.h` keeps its checksum.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.html` and `.htm` select HTML, and `.xml` and `.svg` select XML.
- [ ] Each Grammar has a Capture fixture with tag, property, string, and comment roles.
- [ ] `<script>` content has JavaScript Spans, and `<style>` content has CSS Spans.
- [ ] `<script type="text/javascript">` content has JavaScript Spans.
- [ ] `<script type="module">` content has JavaScript Spans, and `<script type="importmap">` content has JSON Spans.
- [ ] A `style` attribute value has CSS Spans.
- [ ] The adapted injection query records the removed `comment`, `regex`, and `#gsub!` forms with `; bbr:` comments.
- [ ] A fenced `html` block in a ReviewBody gets HTML Spans and injected JavaScript Spans.
- [ ] Each fixture joins the byte-plane oracle test.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- "M27 injection" HTML tests in `src/highlight/tree_sitter_highlighter.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`
