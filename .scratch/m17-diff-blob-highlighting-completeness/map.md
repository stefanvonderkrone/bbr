# M17 diff, blob and highlighting completeness

Label: wayfinder:map

## Destination

An implementation-ready M17 specification and dependency map that resolves Diff, File Enrichment, Bitbucket blob validation, Presentation rendering, query predicates, UserGrammar management, and cache/prefetch policy without implementing the milestone.

## Notes

- Primary domains: Diff, Highlighting, Presentation, Bitbucket, and Git. Consult the relevant `CONTEXT.md` files, `CONTEXT-MAP.md`, TODO.md, ADR-0001, ADR-0003, ADR-0004, ADR-0009, and ADR-0010.
- Use `research`, `prototype`, `grilling`, `domain-modeling`, and `zig` as each ticket requires.
- M17 must preserve the shared Diff pipeline for remote and local review, the Highlighter seam, independent old/new File Enrichment ownership, and the existing inactive File cache policy.
- Terminal image protocols are not baseline M17 scope. Persistent disk caching and bounded prefetch are decisions, not assumed deliverables.
- This map plans M17 only. It does not implement M17 or reopen settled M13, M14, or M15 contracts.

## Decisions so far

- [Define the binary File and placeholder contract](issues/01-define-binary-file-and-placeholder-contract.md) — classify RawDiff binary stubs at File level and invalid UTF-8 per side; preserve usable text, suppress unsafe enrichment and anchors, and render explicit status placeholders.
- [Define removed-File enrichment and blob validation](issues/02-define-removed-file-old-side-and-blob-validation.md) — use destination commit plus old path for removed content, normalize and encode RawDiff paths, preserve typed per-side failures, splice old-side WholeFile Lines, and keep live metadata checks opt-in.
- [Choose side-by-side line matching](issues/03-choose-side-by-side-line-matching.md) — use deterministic order-preserving dynamic matching with symmetric token similarity, a 50% pair threshold, explicit gaps, and unchanged Diff and Anchor identity.
- [Define the DiffPane line-wrapping contract](issues/04-define-diff-line-wrapping-contract.md) — wrap decorated Diff Lines into navigable visual rows, preserve semantic Selection and Anchors, independently balance SideBySide continuations, and keep clipping as the launch default.
- [Decide whether Diffstat has a concrete consumer](issues/05-decide-diffstat-consumer-or-close-deferral.md) — close the obsolete deferral: M17 has no Diffstat consumer, and any future change totals must start as a source-neutral Diff summary.
- [Choose the File Enrichment prefetch policy](issues/06-choose-file-enrichment-prefetch-policy.md) — prefetch one remote successor only after explicit forward traversal; keep demand loading elsewhere, one speculative File maximum, and existing cache and Session Epoch rules.
- [Define the tree-sitter query predicate contract](issues/07-define-tree-sitter-query-predicate-contract.md) — validate `#match?`, `#eq?`, and `#is-not? local` atomically, evaluate matches without losing fallback Captures, and prove behavior with exact predicate, locals, precedence, diagnostic, and cursor-loss fixtures.
- [Define the UserGrammar lifecycle](issues/08-define-usergrammar-lifecycle.md) — install trusted local native bundles through a user-scoped CLI registry, activate deterministic GrammarMatch rules, validate and cache atomically, preserve BuiltInGrammar and plain-text fallback, and prove the workflow end to end.
- [Decide whether to add a persistent File cache](issues/09-decide-persistent-file-cache.md) — keep File content and Highlighting Session-only; reconsider disk persistence only with measured cross-Session delay and a complete data-handling design.
- [Choose the query regex engine](issues/11-choose-query-regex-engine.md) — use pinned RE2 through a C ABI wrapper, with one bounded UTF-8 dialect, atomic Grammar validation, and a Zig 0.16 smoke-test gate for each declared target.
- [Define the integrated M17 contract](issues/10-define-integrated-m17-contract.md) — land independently correct slices, keep UserGrammar atomic, and require native macOS/Linux proof on x86_64 and aarch64 before integrated acceptance.

## Not yet specified

- None. The route to the implementation-ready M17 specification is complete.

## Out of scope

- Implementing M17; this map ends at an implementation-ready specification.
- Terminal image protocol support; it is a separately gated stretch.
- Dirty-worktree review, repository relinking, local-to-remote Draft copy, and concurrent-process synchronization owned by M18.
- Side-aware version inspection owned by M20.
- Buffer and Review Search owned by M21.
- Durable File Read Receipts owned by M22.
- UserGrammar sandboxing; M17 documents trusted native execution, while M27 researches Wasm Grammars and confined helper processes.
