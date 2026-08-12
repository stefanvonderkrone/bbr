# M16 review-item mutation and submission hardening

Label: wayfinder:map

## Destination

An implementation-ready M16 specification and dependency map in which every review-item mutation, editor-handoff, Submission repair, rate-limit, stale-SourceCommit, and integration-test decision is resolved, without implementing the milestone itself.

## Notes

- Primary domains: Review, Presentation, and Bitbucket. Consult `src/review/CONTEXT.md`, `src/tui/CONTEXT.md`, `src/bitbucket/CONTEXT.md`, and ADR-0002, ADR-0005, ADR-0007, ADR-0008, ADR-0011, and ADR-0012 as relevant.
- Use the `prototype`, `grilling`, `domain-modeling`, `research`, and `zig` skills as each ticket requires.
- Treat M16 in `TODO.md` and the acceptance criteria in `.scratch/review-item-mutation/issues/` as constraints rather than reopening them from first principles.
- Editing a Draft or an author-owned published Comment or Reply uses the same prefilled Composer interaction; their persistence and Reconciliation effects remain distinct.
- `Ctrl-E` opens External Edit only in the Composer Interaction Context; the existing DiffPane one-row scroll binding remains unchanged.
- Submission uses one live per-item Overlay from start through completion. A retry targets only the selected failed Draft and its Reply-descendant subtree; there is no retry-all Action.
- A changed SourceCommit always requires reload and repair/re-anchor before new POSTs. M16 does not offer submit-anyway.
- Bitbucket remains authoritative for published Comments. Re-anchor is exposed for a published inline Comment only if primary evidence proves Bitbucket supports it unambiguously.
- Research conclusions must cite primary sources. Environment-dependent behavior may remain an explicit live-probe task when credentials or a suitable PullRequest are unavailable.

## Decisions so far

- [Establish Bitbucket's published Comment mutation contract](issues/01-establish-bitbucket-comment-mutation-contract.md) — Use UUID ownership, body-only ID-addressed updates and deletes, immutable published Anchors, and post-mutation Reconciliation; live-probe the few undocumented edge cases.
- [Probe old-side Comment ranges and multi-line Suggestions](issues/02-probe-old-side-ranges-and-suggestions.md) — Use documented side-specific 1-based range fields, keep Suggestions new-side-only, refuse ambiguous range shapes, and live-probe the undocumented UI and rejection envelope.
- [Establish Bitbucket's Retry-After contract](issues/03-establish-retry-after-contract.md) — Treat `429` as rate limiting, parse either standard `Retry-After` form when present, fall back to bounded local backoff otherwise, and choose a local retry ceiling because Bitbucket publishes none.
- [Live-probe old-side range and Suggestion behavior](issues/14-live-probe-old-side-range-and-suggestion-behavior.md) — Place range cards at their signed bottom line, cap Anchors at 30 inclusive lines, keep strict one-side-only shapes, and refuse old-side Suggestions because Bitbucket renders their Apply action disabled.
- [Choose the review-item mutation interaction](issues/04-choose-review-item-mutation-interaction.md) — Use direct contextual ReviewCard Actions, one typed-target prefilled Composer, two-stage root-Draft re-anchor capture, and identity-specific confirmation and unavailability reasons.
- [Define the Draft mutation contract](issues/05-define-draft-mutation-contract.md) — Mutate eligible Drafts through atomic stage-persist-publish transactions, freeze SubmissionRun participants and ambiguous outcomes, and permit conservative recovery abandonment without losing evidence.
- [Define the external-editor handoff](issues/07-define-external-editor-handoff.md) — Use a correlated Composer command/completion, secure exact-byte temporary file, synchronous cooked-terminal handoff, atomic validated reseed, and explicit outcome/cleanup projection; decide the public limit key separately.
- [Design the live Submission repair Overlay](issues/08-design-submission-repair-overlay.md) — Use one dependency-tree Overlay through progress and terminal results, selected-subtree repair and retry, conservative recovered-run abandonment, and PullRequest-qualified Durable Operation projection across Session replacement.
- [Define the rate-limit and retry policy](issues/09-define-rate-limit-and-retry-policy.md) — Use three-attempt POST and Duplicate-guard budgets, deterministic 1s/2s waits raised by valid server guidance, durable wait checkpoints, and static per-item retry projection.
- [Define the stale-SourceCommit repair workflow](issues/10-define-stale-sourcecommit-repair.md) — Enter a no-POST Stale repair gate, reconcile before explicit abandonment, reload and inspect scope by root, and start fresh SubmissionRuns only for eligible repaired subtrees.
- [Live-probe published Comment mutation edge cases](issues/13-live-probe-comment-mutation-edge-cases.md) — Root deletion tombstones while preserving Replies, body-only Suggestion and Reply edits round-trip exactly, and Bitbucket rejects published Anchor changes atomically.
- [Define the author-owned published Comment mutation contract](issues/06-define-published-comment-mutation-contract.md) — Gate serialized body-only edits and confirmed deletes by UUID ownership, retain styled Deleted Comment tombstones, and reconcile every success or ambiguous outcome without automatic mutation retries.
- [Choose the external-editor configuration language](issues/15-choose-external-editor-configuration-language.md) — Expose a positive 1 MiB `[external_edit].max_bytes` local returned-file safety limit with precise diagnostics and no implied Bitbucket Comment limit.
- [Define M16's deterministic integration coverage](issues/11-define-m16-integration-coverage.md) — Use layered seam ownership, representative Presentation sequences, exhaustive transactional failure injection, a scripted async-adapter harness, and narrow opt-in PTY, manual terminal, and credential-gated checks.
- [Define the integrated M16 contract](issues/12-define-integrated-m16-contract.md) — Use canonical Review identity, Review-owned policy, atomic persistence, one correlated remote-write lane, and eight dependency-ordered vertical slices.

## Not yet specified

None. The route to the implementation-ready M16 specification is complete.

## Out of scope

- Implementing M16; this map ends at an implementation-ready specification.
- Submitting Drafts after SourceCommit changes without first reloading and repairing their CommentScopes.
- Mutating Comments authored by another Bitbucket user.
- Applying Suggestions; that remains a Bitbucket web-UI responsibility.
- General Presentation/navigation polish owned by M15, diff/highlighting completeness owned by M17, and local-review expansion owned by M18.
- More than one active Submission at a time or automatic takeover of another process's live SubmissionRun.
