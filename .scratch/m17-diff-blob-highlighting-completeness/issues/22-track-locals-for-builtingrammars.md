# 22 — Track Locals for BuiltInGrammars

**What to build:** Evaluate `#is-not? local` with real locals queries and lexical scope tracking so local identifiers do not receive global-symbol Captures.

**Blocked by:** 21 — Execute BuiltInGrammar Match Predicates.

**Status:** ready-for-agent

- [ ] JavaScript and TypeScript use pinned locals queries rather than inferred Highlighting Captures.
- [ ] `#is-not? local` accepts global identifiers and rejects local identifiers, including shadowed names in nested scopes.
- [ ] Locals filtering composes with `#match?`, `#eq?`, fallback Captures, and later-pattern precedence.
- [ ] Malformed locals predicates or locals queries reject the complete Grammar with a source diagnostic.
- [ ] Exact-Capture fixtures cover local declarations, references, shadowing, UTF-8, zero-width Captures, invalid ranges, and cursor match loss.
