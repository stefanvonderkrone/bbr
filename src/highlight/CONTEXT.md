# Highlighting

Syntax coloring of file content via tree-sitter. Post-MVP and behind the `Highlighter`
seam; the MVP ships a plain (no-op) implementation. Produces foreground colors only —
diff backgrounds are composed over them per cell by Presentation.

## Language

**Highlighter**:
The seam that turns a File's full content into Spans. Implementations: `PlainHighlighter` (none) now, `TreeSitterHighlighter` later.
_Avoid_: colorizer, lexer, formatter.

**Grammar**:
A tree-sitter language definition plus its highlight query, selected by File extension. The configured set (initially tsx/jsx, css, go, bash, json, yaml) determines which Files get colored.
_Avoid_: language (ambiguous), parser (that's the runtime object), syntax.

**Span**:
A range of a Line assigned a highlight capture (e.g. keyword, string, comment) that maps to a foreground color. Distinct from an IntraLineSegment, which is about diff emphasis, not syntax.
_Avoid_: token, segment (reserved for diff), highlight, region.

**Theme**:
A named, selectable mapping from highlight captures to foreground colors *and* the neutral/green/red diff backgrounds — the single place color decisions live. The default `system` Theme uses the terminal's foreground, background, and ANSI palette; fixed-color built-ins are plain light/dark, Catppuccin Latte/Frappé/Macchiato/Mocha, and light/dark variants of Gruvbox and Solarized.
_Avoid_: palette, colorscheme, style.
