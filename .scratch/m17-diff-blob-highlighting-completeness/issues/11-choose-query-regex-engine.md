# Choose the query regex engine

Type: research
Status: open
Blocked by: none

## Question

Which pinned, byte-oriented regex engine and dialect should M17 use for tree-sitter `#match?` predicates under Zig 0.16, considering linear-time behavior, supported targets, dependency and build cost, licensing, UTF-8 byte semantics, and compatibility with BuiltInGrammar and credible UserGrammar queries; or, if no engine earns its cost, what restricted syntax and diagnostics form the durable contract?
