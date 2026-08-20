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

## Not yet specified

- The dependency-ordered implementation slices needed after the individual M17 decisions are closed.
- The final acceptance matrix across remote/local DiffSource, binary and removed Files, Unified/SideBySide Layout, Changes/WholeFile Scope, File Enrichment, and UserGrammar failure paths.
- Any follow-on changes revealed by the integrated M17 contract, including documentation, migration, configuration, and opt-in live checks.

## Out of scope

- Implementing M17; this map ends at an implementation-ready specification.
- Terminal image protocol support; it is a separately gated stretch.
- Dirty-worktree review, repository relinking, local-to-remote Draft copy, and concurrent-process synchronization owned by M18.
- Side-aware version inspection owned by M20.
- Buffer and Review Search owned by M21.
- Durable File Read Receipts owned by M22.
