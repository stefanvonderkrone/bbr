# Built-in Grammars now, User Grammars later

M13 ships a fixed set of pinned `BuiltInGrammar`s compiled at build time so highlighting is reproducible and requires no runtime network access, cache, or C compiler. Their sources and highlight queries are copied under `vendors/tree-sitter/` with recorded upstream commits and checksums; they are not git submodules, and the build never fetches them. `TreeSitterHighlighter` nevertheless owns an internal Grammar registry so M17 can add Neovim-style installation and management of `UserGrammar`s; Grammar provenance must not leak through the public `Highlighter` interface.

M17 owns runtime installation, trust, ABI compatibility, and cache lifecycle without changing M13's hermetic built-in delivery model.
