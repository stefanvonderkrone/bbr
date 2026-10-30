; bbr: adapted from nvim-treesitter runtime/queries/markdown_inline/highlights.scm at commit a2f694478be07f89c2d03cc17858a8745a400c4b.
; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.
; bbr: bbr changed this query. Each "; bbr:" comment records one change.

; From MDeiml/tree-sitter-markdown
(code_span) @markup.raw ; bbr: removed @nospell

(emphasis) @markup.italic

(strong_emphasis) @markup.strong

(strikethrough) @markup.strikethrough

(shortcut_link
  (link_text) ; bbr: removed @nospell
  )

; Conceal backslash in backslash escapes
((backslash_escape) ; bbr: removed @conceal
  ; bbr: removed (#offset! @conceal 0 0 0 -1)
  ; bbr: removed (#set! conceal "")
  )

; Conceal backslash in hard line breaks
((hard_line_break
  "\\" ; bbr: removed @conceal
  )
  ; bbr: removed (#set! conceal "")
  )

; Conceal codeblock and text style markers
([
  (code_span_delimiter)
  (emphasis_delimiter)
] ; bbr: removed @conceal
  ; bbr: removed (#set! conceal "")
  )

; Conceal inline links
(inline_link
  [
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  ; bbr: removed (#set! conceal "")
  )

[
  (link_label)
  (link_text)
  (link_title)
  (image_description)
] @markup.link.label

((inline_link
  (link_destination) @_url) @_label
  ; bbr: removed (#set! @_label url @_url)
  )

((image
  (link_destination) @_url) @_label
  ; bbr: removed (#set! @_label url @_url)
  )

; Conceal image links
(image
  [
    "!"
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  ; bbr: removed (#set! conceal "")
  )

; Conceal full reference links
(full_reference_link
  [
    "["
    "]"
    (link_label)
  ] @markup.link
  ; bbr: removed (#set! conceal "")
  )

; Conceal collapsed reference links
(collapsed_reference_link
  [
    "["
    "]"
  ] @markup.link
  ; bbr: removed (#set! conceal "")
  )

; Conceal shortcut links
(shortcut_link
  [
    "["
    "]"
  ] @markup.link
  ; bbr: removed (#set! conceal "")
  )

[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @markup.link.url ; bbr: removed @nospell

((uri_autolink) @_url
  ; bbr: removed (#offset! @_url 0 1 0 -1)
  ; bbr: removed (#set! @_url url @_url)
  )

(entity_reference) ; bbr: removed @nospell

; Replace common HTML entities.
((entity_reference) @character.special
  (#eq? @character.special "&nbsp;")
  ; bbr: removed (#set! conceal " ")
  )

((entity_reference) @character.special
  (#eq? @character.special "&lt;")
  ; bbr: removed (#set! conceal "<")
  )

((entity_reference) @character.special
  (#eq? @character.special "&gt;")
  ; bbr: removed (#set! conceal ">")
  )

((entity_reference) @character.special
  (#eq? @character.special "&amp;")
  ; bbr: removed (#set! conceal "&")
  )

((entity_reference) @character.special
  (#eq? @character.special "&quot;")
  ; bbr: removed (#set! conceal "\"")
  )

((entity_reference) @character.special
  (#any-of? @character.special "&ensp;" "&emsp;")
  ; bbr: removed (#set! conceal " ")
  )
