; bbr: adapted from nvim-treesitter runtime/queries/toml/highlights.scm at commit a2f694478be07f89c2d03cc17858a8745a400c4b.
; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.
; bbr: bbr changed this query. Each "; bbr:" comment records one change.

(bare_key) @property

[
  (string)
  (quoted_key)
] @string

(boolean) @boolean

(comment) @comment ; bbr: removed @spell

(escape_sequence) @string.escape

(integer) @number

(float) @number.float

[
  (local_date)
  (local_date_time)
  (local_time)
  (offset_date_time)
] @string.special

"=" @operator

[
  "."
  ","
] @punctuation.delimiter

[
  "["
  "]"
  "[["
  "]]"
  "{"
  "}"
] @punctuation.bracket
