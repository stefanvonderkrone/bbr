# M21 Buffer and Review Search

Label: wayfinder:map

## Destination

An implementation-ready M21 specification and dependency map for Buffer Search and Review Search, without implementing the milestone.

## Notes

- Primary domains: Presentation and Diff. Review owns authored bodies. Bitbucket and Git supply remote and local File Enrichment. Consult `CONTEXT-MAP.md`, each domain's `CONTEXT.md`, `TODO.md`, and the M20 Selected Version contract.
- Use `prototype`, `grilling`, `domain-modeling`, `technical-writing`, and `zig` as each ticket requires.
- Treat the M21 entries in `TODO.md` as requirements that tickets can refine when a conflict appears.
- Buffer Search examines old and new source Lines in the current Buffer. A shared context Line counts once in Unified and SideBySide Layouts.
- Buffer Search includes every authored Comment, Reply, and Draft body owned by the current Buffer. It includes text behind ReviewCard, Thread, and Fold disclosures. Activating a hidden match reveals its owner.
- Review Search examines both old and new versions of every changed File and every authored body in the Review. Selected Version does not limit its corpus.
- Review Search keeps version-specific changed occurrences separate. It coalesces equivalent unchanged old and new occurrences into one version-neutral result.
- Both searches must reject generated Presentation text such as gutters, borders, headers, and disclosure labels.
- This map plans M21 only. It does not implement M21.

## Decisions so far

- [Define Search Corpus and Occurrence Identity](issues/01-define-search-corpus-and-occurrence-identity.md) — Buffer Search covers current Buffer semantics; Review Search covers complete File versions and all authored bodies through Session-scoped occurrences.
- [Define Buffer Search Interaction](issues/02-define-buffer-search-interaction.md) — Buffer Search uses Neovim-style incremental input, semantic occurrence traversal, temporary disclosure reveal, and configurable `/`, `n`, and `N` Actions.
- [Prototype Buffer Search Feedback](issues/03-prototype-buffer-search-feedback.md) — Buffer Search uses the bottom command line, Theme-owned ochre and orange match styles, and a persistent right-aligned active and total count.
- [Define Review Search Matching and Ordering](issues/04-define-review-search-matching-and-ordering.md) — Review Search returns one Unicode smart-case `fzy`-ranked occurrence per logical line, with deterministic streamed ordering and Diff-proven version-neutral coalescing.

## Not yet specified

- The implementation slices and full acceptance matrix depend on the interaction prototypes, occurrence model, and streaming policy.

## Out of scope

- Implementing M21. This map ends at an implementation-ready specification.
- Regular-expression search, text replacement, and repository-wide search.
- Searching unchanged Files outside the current Review.
- A persistent search index or search history across application restarts.
