# 24 — Activate UserGrammars Through the Registry

**What to build:** Select and load active UserGrammars from a user registry while preserving deterministic GrammarMatch behavior and readable fallback.

**Blocked by:** 23 — Validate Trusted UserGrammar Bundles.

**Status:** ready-for-agent

- [ ] GrammarMatch uses exact filename, compound suffix, simple extension, and shebang precedence; explicit configuration replaces one UserGrammar's defaults.
- [ ] Active UserGrammar conflicts are startup errors, while an overlap with a BuiltInGrammar is reported and the UserGrammar takes precedence.
- [ ] TreeSitterHighlighter loads a matching active UserGrammar on first use without changing the public Highlighter seam.
- [ ] Disable, removal, or runtime failure restores a matching BuiltInGrammar or plain text.
- [ ] Tampered active payloads block startup precisely, while invalid inactive installations remain listed without blocking startup.
- [ ] Validation receipts are reused only while bundle, bbr, and tree-sitter runtime identities match; compiled queries and native handles remain process-local.
