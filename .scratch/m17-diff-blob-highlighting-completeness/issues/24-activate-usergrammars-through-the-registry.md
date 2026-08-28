# 24 — Activate UserGrammars Through the Registry

**What to build:** Select and load active UserGrammars from a user registry while preserving deterministic GrammarMatch behavior and readable fallback.

**Blocked by:** 23 — Validate Trusted UserGrammar Bundles.

**Status:** done

- [x] GrammarMatch uses exact filename, compound suffix, simple extension, and shebang precedence; explicit configuration replaces one UserGrammar's defaults.
- [x] Active UserGrammar conflicts are startup errors, while an overlap with a BuiltInGrammar is reported and the UserGrammar takes precedence.
- [x] TreeSitterHighlighter loads a matching active UserGrammar on first use without changing the public Highlighter seam.
- [x] Disable, removal, or runtime failure restores a matching BuiltInGrammar or plain text.
- [x] Tampered active payloads block startup precisely, while invalid inactive installations remain listed without blocking startup.
- [x] Validation receipts are reused only while bundle, bbr, and tree-sitter runtime identities match; compiled queries and native handles remain process-local.
