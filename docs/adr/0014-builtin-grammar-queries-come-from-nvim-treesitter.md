# BuiltInGrammar queries come from nvim-treesitter

M27 adds 21 BuiltInGrammars to the 8 BuiltInGrammars of M13.
Each new BuiltInGrammar uses the repository and the revision that nvim-treesitter pins.
Its highlight query and its injection query come from one pinned nvim-treesitter commit.
Markdown, HTML, and PHP contain other languages, so `TreeSitterHighlighter` gets Injection.

This ADR is a refinement of [ADR-0009](0009-built-in-grammars-now-user-grammars-later.md), not a reversal.
The delivery stays hermetic: pinned, vendored, checksummed, and compiled into the executable.
[ADR-0003](0003-swappable-seams-std-http-sqlite-treesitter.md) also holds.
The `Highlighter` seam and the core `bbr` module stay C-free.

## Decision

- New BuiltInGrammars use the nvim-treesitter queries.
  The 8 M13 BuiltInGrammars keep their upstream queries and revisions.
  The manifest field `.query_source` records `.nvim_treesitter` or `.upstream` for each entry.
- `tools/adapt_queries.py` turns the raw nvim-treesitter queries into the adapted queries.
  It resolves `; inherits:` lines, rewrites `#lua-match?`, `#not-lua-match?`, and `#contains?`, and removes Neovim-only directives and Captures.
  Each removed form leaves a `; bbr:` comment, and an unknown predicate stops the adaptation.
  `vendors/tree-sitter/nvim-treesitter/queries/` holds the raw copies.
  The build compiles only the adapted copies in `vendors/tree-sitter/<tag>/`.
- A generated `parser.c` comes from one vendoring run with a pinned tree-sitter CLI.
  The build never runs the CLI.
  Swift is the only generated parser in M27. Its manifest entry records the CLI version, the command, and the JavaScript runtime.
- Injection is internal to `TreeSitterHighlighter`.
  Only BuiltInGrammars take part, as host and as injected Grammar.
  A UserGrammar is never a host and never an injected Grammar.

## Why nvim-treesitter queries

nvim-treesitter pins one revision of each Grammar and keeps a highlight query for that revision.
So one nvim-treesitter commit gives a matched pair of a Grammar revision and a query.
Neovim uses the same pairs, so a reviewer can compare the Captures of bbr with Neovim on the same File.
The M13 BuiltInGrammars keep their upstream queries, so M27 does not change their colors.

The cost is the Neovim-only forms in these queries.
Neovim runs Lua predicates and directives that bbr does not have.
A silent drop of an unknown form would change the colors without a record.
So the adaptation stops on an unknown form, and every removal leaves a comment.
`tools/check_vendored_grammars.py` runs the adaptation again in `zig build test`.
So a hand edit of an adapted query fails the suite.

## Why a generated parser is a refinement of ADR-0009

ADR-0009 says that the Grammar sources are copied under `vendors/tree-sitter/`.
The Swift repository has no committed `parser.c` at the pinned revision.
So the vendoring run generates it with tree-sitter CLI v0.26.9, the version of the vendored runtime.
The generated file is committed and checksummed like every copied file.
The build input stays a fixed set of committed files, which is the goal of ADR-0009.
Only the way that the file entered the repository is different.

## Why Injection stays inside TreeSitterHighlighter

Injection needs the parse tree of the host and the prepared queries of the injected Grammar.
Both live in `TreeSitterHighlighter`.
The `Highlighter` seam, `HighlightResult`, and `Span` do not change, so no caller needs to know about Injection.

UserGrammars take no part because a UserGrammar is native code with the user's permissions.
An Injection from a BuiltInGrammar host would load that code for a File that the UserGrammar did not claim.
So a fenced `js` block in Markdown uses the JavaScript BuiltInGrammar, also when a UserGrammar claims `.js`.

## Consequences

- A host's adapted injection query depends on the set of BuiltInGrammars.
  The adaptation keeps only the Injections whose static Grammar name is a BuiltInGrammar.
  After a new BuiltInGrammar, `tools/check_vendored_grammars.py` names each stale adapted host query and tells the maintainer to rerun `tools/vendor_grammar.py`.
- The ReleaseSafe executable grows from 12,980,144 to 57,526,080 bytes.
  The parse tables of the new Grammars are almost all of the growth.
- `TreeSitterHighlighter.init` prepares every query at startup.
  In ReleaseSafe, it takes 422 ms after M27 and 28 ms before.
  [The binary size record](../../.scratch/m27-zig-builtin-grammar/binary-size.md) has the method and the per-Grammar times.
- New Captures map to the existing Theme roles through dotted-prefix rules in `Capture.init`.
  M27 adds no Theme color.
