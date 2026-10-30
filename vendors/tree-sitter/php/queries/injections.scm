; bbr: adapted from nvim-treesitter runtime/queries/php/injections.scm at commit a2f694478be07f89c2d03cc17858a8745a400c4b.
; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.
; bbr: bbr changed this query. Each "; bbr:" comment records one change.

; bbr: inherited from php_only
; bbr: removed pattern for phpdoc

(heredoc
  (heredoc_body) @injection.content
  (heredoc_end) @injection.language
  (#set! injection.include-children))

(nowdoc
  (nowdoc_body) @injection.content
  (heredoc_end) @injection.language
  (#set! injection.include-children))

; regex
; bbr: removed pattern for regex

; bash
((function_call_expression
  function: (_) @_shell_func_identifier
  arguments: (arguments
    .
    (argument
      (_
        (string_content) @injection.content))))
  (#set! injection.language "bash")
  (#any-of? @_shell_func_identifier
    "shell_exec" "escapeshellarg" "escapeshellcmd" "exec" "passthru" "proc_open" "shell_exec"
    "system"))

(expression_statement
  (shell_command_expression
    (string_content) @injection.content)
  (#set! injection.language "bash"))

; inherits: php_only

((text) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined))
