; bbr: adapted from nvim-treesitter runtime/queries/markdown_inline/injections.scm at commit a2f694478be07f89c2d03cc17858a8745a400c4b.
; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.
; bbr: bbr changed this query. Each "; bbr:" comment records one change.

((html_tag) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined))

; bbr: removed pattern for latex
