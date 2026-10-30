; bbr: adapted from nvim-treesitter runtime/queries/html/highlights.scm at commit a2f694478be07f89c2d03cc17858a8745a400c4b.
; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.
; bbr: bbr changed this query. Each "; bbr:" comment records one change.

; bbr: inherited from html_tags
(tag_name) @tag ; bbr: removed @nospell

; (erroneous_end_tag_name) @error ; we do not lint syntax errors
(comment) @comment ; bbr: removed @spell

(attribute_name) @tag.attribute ; bbr: removed @nospell

(attribute_value) ; bbr: removed @nospell

((attribute
  (quoted_attribute_value) @string)
  (#set! priority 99))

(text) @none ; bbr: removed @spell

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading)
  (#eq? @_tag "title"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading.1)
  (#eq? @_tag "h1"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading.2)
  (#eq? @_tag "h2"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading.3)
  (#eq? @_tag "h3"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading.4)
  (#eq? @_tag "h4"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading.5)
  (#eq? @_tag "h5"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.heading.6)
  (#eq? @_tag "h6"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.strong)
  (#any-of? @_tag "strong" "b"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.italic)
  (#any-of? @_tag "em" "i"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.strikethrough)
  (#any-of? @_tag "s" "del"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.underline)
  (#eq? @_tag "u"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.raw)
  (#any-of? @_tag "code" "kbd"))

((element
  (start_tag
    (tag_name) @_tag)
  (text) @markup.link.label)
  (#eq? @_tag "a"))

((attribute
  (attribute_name) @_attr
  (quoted_attribute_value
    (attribute_value) @string.special.url))
  (#any-of? @_attr "href" "src")
  ; bbr: removed (#set! @string.special.url url @string.special.url)
  )

[
  "<"
  ">"
  "</"
  "/>"
] @tag.delimiter

"=" @operator

; inherits: html_tags

(doctype) @constant

"<!" @tag.delimiter

(entity) @character.special
