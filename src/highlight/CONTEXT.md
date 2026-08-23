# Highlighting

Syntax coloring of file content via tree-sitter, behind the `Highlighter` seam; plain and
tree-sitter implementations ship today. Produces foreground colors only —
diff backgrounds are composed over them per cell by Presentation.

## Language

**Highlighter**:
The seam that turns a File's full content into Spans. Implementations: `PlainHighlighter` (none) and `TreeSitterHighlighter` (built-in Grammars).
_Avoid_: colorizer, lexer, formatter.

**Grammar**:
A tree-sitter language definition plus its highlight query, selected for a File by a GrammarMatch. A Grammar may ship with bbr or be installed by the user; that provenance does not change highlighting behavior.
_Avoid_: language (ambiguous), parser (that's the runtime object), syntax.

**BuiltInGrammar**:
A pinned Grammar shipped with bbr. The initial set is tsx/jsx, css, go, bash, json, and yaml.
_Avoid_: bundled grammar, default grammar, native grammar.

**UserGrammar**:
A Grammar installed and managed by the user for a file type bbr does not support itself.
_Avoid_: custom grammar, external grammar, plugin grammar.

**GrammarMatch**:
An ordered rule that selects a Grammar for a File: exact filename, compound suffix, simple extension, then shebang. The first match wins. An active UserGrammar takes precedence over an overlapping BuiltInGrammar after installation reports the affected BuiltInGrammar; conflicts between UserGrammars are invalid.
_Avoid_: file association, language detection, extension mapping.

**Capture**:
A hierarchical syntax role assigned by a Grammar, such as `function.call`, `keyword`, or `comment`. A Theme resolves an unknown specific Capture through its less-specific parents and finally the default foreground.
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
