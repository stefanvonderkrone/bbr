# Define the tree-sitter query predicate contract

Type: research
Status: resolved
Blocked by: none

## Question

Which tree-sitter query predicates are required by the built-in highlight queries and supported by the vendored Zig bindings, and what adapter behavior and fixtures prove captures are preserved, rejected, or reported rather than silently dropped or incorrectly applied?

## Answer

The BuiltInGrammar queries require `#match?`, `#eq?`, and `#is-not? local`; they use no directives. The vendored C API exposes predicate steps and match data but evaluates none of them. The current adapter therefore silently rejects every conditional pattern.

M17 must use one predicate profile for BuiltInGrammars and UserGrammars. Validate each Grammar atomically, compile regexes at validation, and reject unknown operators, directives, malformed arguments, invalid regexes, and unsupported properties with source diagnostics. A false predicate rejects only its match and preserves fallback Captures. A true match applies all its Captures. Later query patterns retain precedence after filtering. Predicate errors and cursor match loss fail Highlighting rather than produce partial Spans.

Correct `#is-not? local` behavior requires pinned JavaScript and TypeScript locals queries and scope tracking; it must not be approximated. Capture validation must reject invalid ranges, preserve UTF-8 boundaries, and discard zero-width captures by rule. Fixtures must assert exact accepted and rejected Captures, fallback preservation, local shadowing, overlap precedence, diagnostics, UTF-8 behavior, and no cursor match loss.

Full inventory, evidence, fixture matrix, and primary sources: [Tree-sitter query predicate contract research](../research/07-tree-sitter-query-predicate-contract.md).
