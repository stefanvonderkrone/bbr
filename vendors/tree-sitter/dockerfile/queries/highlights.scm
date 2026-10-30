; bbr: adapted from nvim-treesitter runtime/queries/dockerfile/highlights.scm at commit a2f694478be07f89c2d03cc17858a8745a400c4b.
; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.
; bbr: bbr changed this query. Each "; bbr:" comment records one change.

[
  "FROM"
  "AS"
  "RUN"
  "CMD"
  "LABEL"
  "EXPOSE"
  "ENV"
  "ADD"
  "COPY"
  "ENTRYPOINT"
  "VOLUME"
  "USER"
  "WORKDIR"
  "ARG"
  "ONBUILD"
  "STOPSIGNAL"
  "HEALTHCHECK"
  "SHELL"
  "MAINTAINER"
  "CROSS_BUILD"
] @keyword

[
  ":"
  "@"
] @operator

(comment) @comment ; bbr: removed @spell

(image_spec
  (image_tag
    ":" @punctuation.special)
  (image_digest
    "@" @punctuation.special))

(double_quoted_string) @string

[
  (heredoc_marker)
  (heredoc_end)
] @label

((heredoc_block
  (heredoc_line) @string)
  (#set! priority 90))

(expansion
  [
    "$"
    "{"
    "}"
  ] @punctuation.special)

((variable) @constant
  (#match? @constant "^[A-Z][0-9A-Z_]*$"))

(arg_instruction
  .
  (unquoted_string) @property)

(env_instruction
  (env_pair
    .
    (unquoted_string) @property))

(expose_instruction
  (expose_port) @number)
