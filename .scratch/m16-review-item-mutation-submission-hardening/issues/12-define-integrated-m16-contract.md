# Define the integrated M16 contract

Type: grilling
Status: resolved
Blocked by: 05, 06, 07, 08, 09, 10, 11

## Question

How should every accepted M16 behavior fit into Review ownership, Bitbucket anti-corruption, PendingReviewStore transactions, Presentation Actions and projections, Durable Operation commands, terminal effects, configuration and documentation, and a dependency-ordered set of implementation slices so the milestone can be executed without reopening product or architecture decisions?

## Answer

Implement M16 as one contract across Review, Bitbucket, Presentation, persistence, and terminal adapters. The detailed behavior in every blocking decision remains mandatory; this answer fixes where that behavior lives, how it crosses seams, and the order in which to add it.

### Canonical identity and operation ownership

- `ReviewIdentity` is the only domain identity for a Review. Remove the competing `ReviewKey` vocabulary from domain interfaces. Commands and durable records may use an owned, copy-safe `OwnedReviewIdentity`, but that is a representation of `ReviewIdentity`, not a second domain concept. APIs that start or recover a Submission accept only the remote variant at the type boundary.
- Submission and author-owned published Comment mutation share one global remote-write lane. Only one of these Durable Operations can own the lane at a time, regardless of PullRequest. Draft mutation is local and External Edit is Session-bound, so neither uses the lane.
- A remote-write operation owns the lane through its first Reconciliation attempt. If Reconciliation fails, release the lane but mark that PullRequest as requiring authoritative reload. Refuse further remote writes from its stale Session until `R` publishes a complete replacement Session. Other PullRequests remain usable.
- Each external effect has a unique `CommandId`. A completion is admitted only when its `CommandId`, OperationId, and typed target (`TempId`, `CommentId`, or other command-specific identity) all match. Session-bound effects additionally match the Session Epoch. Late, duplicate, and mismatched completions are consumed and discarded exactly once.

### Review ownership

- Review owns the pure Draft-mutation rules, root repair eligibility, and the clock-free SubmissionRun transition model. This includes the frozen participant graph, parent dependencies and remapping, attempt budgets, waits, Duplicate-guard states, per-item outcomes, stale-gate eligibility, recovery choices, Abandon recovery, and terminalization.
- A SubmissionRun durably stores its ordered `SubmissionRunItem` participant graph when it begins. Each item records its TempId and dependency relationship. Recovery uses this frozen membership; it never recomputes participants from the current PendingReview. Selected-subtree retry creates a fresh run with only the selected eligible Draft and its transitive Reply descendants.
- Review exposes one pure root-eligibility operation. Its inputs are the authored CommentScope, current ScopeResolution evidence, loaded and observed SourceCommits, and parent publication state. Its result applies to the root and its Reply descendants and follows [Define the stale-SourceCommit repair workflow](10-define-stale-sourcecommit-repair.md). Presentation supplies Session-scoped evidence and projects the verdict; the accepted SubmissionRun persists membership, not transient ScopeProjection data.
- The pure SubmissionRun model proposes durable transitions and external effects but performs no persistence, network access, clock access, sleeping, terminal I/O, or Session publication.

### PendingReviewStore and SQLite

- Replace raw mutation choreography with one transaction-shaped `DraftMutation` intention carrying expected ReviewIdentity and a closed case: `edit_body`, `reanchor`, or `delete_subtree`. The store atomically rechecks typed identity, eligible DraftState, active or recovered SubmissionRun participation, expected parentage and graph closure, and the complete delete cascade before committing.
- Keep reserve-stage-persist-publish ordering. Presentation privately stages the PendingReview, ScopeProjection, Presentation Frame, interaction result, and identity-based navigation; the store commits the mutation; an infallible final step publishes the staged aggregate. Any earlier failure preserves the old complete projection and the reviewer's active input.
- Expand transaction-shaped Submission intentions to begin a run with frozen participants, checkpoint an outcome and next intent, persist wait and Duplicate-guard state, resolve ambiguity, abandon recovery, and complete clean or partial. No SQLite transaction remains open during external work.
- Add one forward-only schema migration. Preserve every existing Draft TempId, body, kind, parent relationship, CommentScope, AnchorSnapshot, and DraftState. Create normalized SubmissionRun participant and checkpoint storage. After migration, use only the new runtime path; do not maintain dual old/new interfaces.

### Bitbucket anti-corruption and failure results

- Bitbucket independently acquires the Authenticated Account UUID on the first remote Review load and caches it for the Credential lifetime. Identity acquisition failure does not fail Review loading; published Comment mutation remains unavailable with a precise reason. A `401` clears the cached identity and disables mutation until identity is acquired again. Ownership compares UUIDs only.
- Bitbucket owns Comment update/delete wire shapes, authenticated-account wire data, Deleted Comment decoding, `Retry-After` parsing, and HTTP classification. Review and Presentation receive only domain values and typed results; no raw status, header, JSON, or Atlassian field crosses the boundary.
- Use `ApiError` only for a classified response received from Bitbucket. Represent transport delivery separately as `definitely_not_delivered` or `outcome_unknown`. A malformed successful write response is `outcome_unknown` because Bitbucket may have applied the effect; a malformed read response is a definite read failure. Only received `429` and `5xx` responses can carry `retry_after_ms`.
- Submission applies automatic retry and Duplicate-guard policy only through its settled typed outcomes. Published Comment mutation never retries automatically. An unknown published mutation outcome starts Reconciliation while the operation still owns the remote-write lane.

### Presentation, Actions, and projections

- Presentation owns Interaction Context, direct ReviewCard targeting, ActionAvailability, Overlays, Composer and confirmation state, ScopeProjection, complete Presentation Frame staging, command scheduling, completion admission, and projection of all outcomes. It does not own Review policy or perform external I/O.
- Add contextual `edit`, `reanchor`, and `delete` Actions with the accepted `e`, `a`, and `D` bindings. Every ReviewCard row resolves to a typed local Draft or Bitbucket Comment target. Unavailable Actions stay discoverable and return the identity- and state-specific reason from the accepted contracts.
- Use one typed-target prefilled Composer for Draft and published Comment edits. External Edit is a Composer Action only. Root-Draft re-anchor uses the accepted two-stage capture. Delete uses an identity-specific confirmation and shows the Draft descendant or remote tombstone consequence.
- Replace the status-only Submission projection with one dependency-tree Overlay from authorization through terminal result. Reconstruct it from durable SubmissionRun and Draft state after Session replacement. It projects static wait detail, classified outcomes, blocked Reply ancestry, repair Actions, ambiguity resolution, Abandon recovery, and Retry selected subtree; it provides no retry-all or submit-anyway Action.
- The Stale repair gate uses the same Overlay. Reload prepares one Candidate Session atomically. Each root's Review eligibility verdict controls only its own subtree. No new POST occurs until reload and the required explicit repair are complete.
- Published Comment mutation and Submission project PullRequest-qualified progress and results across Session replacement. A failed Reconciliation preserves the old complete Session, reports that authoritative reload is required, and gates only later remote writes for that PullRequest.

### Commands, terminal effects, and configuration

- Extend the closed `OwnedCommand` and `OwnedInput` unions for authenticated-account acquisition, Comment update/delete, Reconciliation, External Edit, detailed Submission waits and Duplicate guards, stale-head checks, and Candidate Session reload. Every owned payload has one explicit destruction path.
- The terminal adapter executes commands, owns futures and timers, posts typed completions, and reaps work. A deterministic scripted executor drives the same command/completion path in tests.
- External Edit is the only command that temporarily stops dispatch. The adapter prepares the secure temporary file, suspends vaxis and restores the cooked terminal, runs `/bin/sh -c` synchronously, restores the TUI, and returns a correlated typed completion. Presentation only snapshots and reseeds Composer bytes.
- Add `[external_edit].max_bytes = 1048576` exactly as defined in [Choose the external-editor configuration language](15-choose-external-editor-configuration-language.md). Zero is invalid and no compatibility alias exists. Document editor precedence, local byte-limit semantics, manual Shift+Arrow compatibility, recovery and stale repair, mutation ownership, unsupported published re-anchor, Retry-After behavior, and all opt-in checks.

### Dependency-ordered implementation slices

1. **Identity and durability foundation:** introduce canonical owned ReviewIdentity representation, `CommandId`, external failure results, the forward SQLite migration, transaction-shaped Draft mutations, and durable frozen SubmissionRun items. Keep current visible behavior and leave `zig build test` green.
2. **Pure Review contracts:** implement and exhaustively test Draft mutation validation, subtree closure, root repair eligibility, and the complete SubmissionRun transition model with three-attempt POST and Duplicate-guard budgets, durable waits, recovery, abandonment, and selected participant sets.
3. **Bitbucket capability:** add Authenticated Account acquisition and invalidation, body-only Comment update/delete, Deleted Comment decoding, Retry-After transport metadata, and definite-versus-unknown delivery results with fake-adapter coverage.
4. **Draft mutation vertical slice:** add typed ReviewCard targets, contextual Actions, prefilled Composer edit, two-stage root re-anchor, cascade confirmation, stage-persist-publish, interaction retention, ScopeProjection replacement, and LocalReview AnchorSnapshot behavior.
5. **Published Comment mutation vertical slice:** add UUID ActionAvailability, update/delete commands, the shared remote-write lane, response-lost handling, Reconciliation, PullRequest-qualified completion, and reload-required gating.
6. **External Edit vertical slice:** add strict configuration, Composer command/completion correlation, secure file and process adapter, terminal suspend/restore, atomic `Composer.seed`, cleanup diagnostics, and deterministic adapter tests.
7. **Submission repair vertical slice:** add the dependency-tree Overlay, per-item progress and detail, static retry waits, selected-subtree retry, recovery and ambiguity Actions, Stale repair gate, Candidate Session reload, per-root eligibility, and Abandon recovery.
8. **Integrated acceptance pass:** add the scripted terminal-adapter harness and representative cross-seam sequences from [Define M16's deterministic integration coverage](11-define-m16-integration-coverage.md); update documentation; run `zig build test`; then run only the explicit opt-in PTY, manual terminal, and credential-gated checks.

Each slice must keep deterministic tests green and must not expose an Action before its persistence, rollback, and failure behavior is complete. Lower seams own exhaustive branch matrices; Presentation tests prove representative composition without repeating the Cartesian product.

This resolves the final M16 fog. Implementation can use these slices without another product or architecture decision. A discovery that changes an accepted product behavior or crosses the stated M16 scope requires a new decision effort rather than an implicit change during implementation.
