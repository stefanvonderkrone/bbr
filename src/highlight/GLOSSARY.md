# Highlighting

The vocabulary of syntax coloring, Grammars, and Themes.

## Language

**Highlighter**:
The seam that turns a File's full content into Spans. Implementations: `PlainHighlighter` (none) and `TreeSitterHighlighter` (BuiltInGrammars and active UserGrammars).
_Avoid_: colorizer, lexer, formatter.

**Grammar**:
A tree-sitter language definition plus its highlight query, selected for a File by a GrammarMatch. A Grammar may ship with bbr or be installed by the user; that provenance does not change highlighting behavior.
_Avoid_: language (ambiguous), parser (that's the runtime object), syntax.

**BuiltInGrammar**:
A pinned Grammar shipped with bbr. The set after M27 is tsx, typescript, javascript, css, go, bash, json, yaml, zig, c, cpp, rust, odin, java, kotlin, groovy, c_sharp, python, ruby, swift, sql, toml, dockerfile, make, html, xml, markdown_inline, markdown, and php. `markdown_inline` is a BuiltInGrammar with no GrammarMatch rule. Only an Injection selects it.
_Avoid_: bundled grammar, default grammar, native grammar.

**UserGrammar**:
A Grammar installed and managed by the user for a file type bbr does not support itself.
_Avoid_: custom grammar, external grammar, plugin grammar.

**GrammarMatch**:
An ordered rule that selects a Grammar for a File: exact filename, compound suffix, simple extension, then shebang. The first match wins. An active UserGrammar takes precedence over an overlapping BuiltInGrammar after installation reports the affected BuiltInGrammar; conflicts between UserGrammars are invalid. An Injection selects its Grammar by name, not by GrammarMatch.
_Avoid_: file association, language detection, extension mapping.

**Injection**:
A region of a File that a host BuiltInGrammar gives to another BuiltInGrammar.
An injection query of the host names the region and the Grammar.
Spans from the injected Grammar take precedence over host Spans at equal priority.
Only BuiltInGrammars take part, as host and as injected Grammar.
_Avoid_: embedded language, sub-grammar, nested parser.

**Capture**:
A query-local `u16` identity for a hierarchical syntax role assigned by a Grammar. Each Grammar classifies Capture names once into Theme roles such as function, keyword, or comment. Unknown roles use the default foreground. A Span from an Injection carries the Capture of the injected Grammar's query. A Capture name that starts with `_` produces no Span.
_Avoid_: scope, token type, syntax class.

**Span**:
An ordered, non-overlapping half-open UTF-8 byte range within a Line, assigned a Capture that maps only to a foreground color. Span endpoints never split a UTF-8 code point; terminal columns are a Presentation concern. Distinct from an IntraLineSegment, which determines diff emphasis in the background.
_Avoid_: token, segment (reserved for diff), highlight, region.

**LineDecoration**:
The presentation-neutral composition of a Line's Spans and IntraLineSegments, partitioned wherever its foreground capture or diff emphasis changes. A Theme later turns that meaning into terminal colors.
_Avoid_: styled line, rendered line, colored line.

**Theme**:
A named, selectable mapping from highlight captures to foreground colors *and* the neutral/green/red diff backgrounds — the single place color decisions live. The default `system` Theme uses the terminal's foreground, background, and ANSI palette; fixed-color built-ins are plain light/dark, Catppuccin Latte/Frappé/Macchiato/Mocha, and light/dark variants of Gruvbox and Solarized.
_Avoid_: palette, colorscheme, style.
