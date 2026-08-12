# M16 Review-Item Mutation and Submission Hardening

Status: ready-for-agent
Milestone: M16

## Problem Statement

Reviewers can author and submit a client-side PendingReview, but they cannot safely repair every Review item or understand and recover every partial Submission outcome from inside bbr. Editing and deleting locally owned Drafts is incomplete, author-owned published Comments cannot be mutated, substantial Composer bodies cannot be handed to an external editing program, and Submission failures are summarized too coarsely to explain dependencies or support precise repair.

These gaps become dangerous when Bitbucket accepts only part of a Submission, a response is lost, a process exits mid-run, rate limiting delays work, or the PullRequest's SourceCommit changes. Without durable participant identity, explicit ownership, atomic persistence, and a no-POST repair gate, bbr could duplicate a Comment, post a Reply beneath the wrong parent, lose ambiguous publication evidence, mutate another author's Comment, or publish an inline Draft against obsolete code.

## Solution

Give reviewers direct, contextual mutation Actions on each ReviewCard and use one typed-target, prefilled Composer for both local Draft and author-owned Bitbucket Comment edits. Let reviewers re-anchor eligible inline root Drafts, confirm cascade deletion of Draft subtrees, confirm remote deletion of their published Comments, and use a secure External Edit handoff while keeping the Composer open.

Replace the status-only Submission result with one dependency-tree Overlay that follows a durable SubmissionRun from authorization through progress, recovery, stale repair, and terminal results. Persist every transition before the next external effect, respect Bitbucket retry guidance, reconcile ambiguous outcomes before another POST, and permit retry only for the selected eligible failed Draft subtree. If SourceCommit changes, reload and explicitly repair affected roots before any fresh POST; never offer submit-anyway.

## User Stories

1. As a reviewer, I want every ReviewCard row to target its stable local Draft or Bitbucket Comment identity, so that Actions cannot affect the wrong item.
2. As a reviewer, I want local Drafts and published Bitbucket Comments to be named distinctly, so that I understand whether an Action changes local or remote state.
3. As a keyboard user, I want contextual edit, re-anchor, and delete Actions, so that I can repair Review items without leaving the DiffPane workflow.
4. As a reviewer, I want unavailable mutation Actions to remain discoverable with a precise reason, so that I know why an item cannot currently be changed.
5. As a reviewer, I want to edit an existing Comment Draft with its body prefilled, so that I can correct it without recreating it.
6. As a reviewer, I want to edit an existing Reply Draft with its body prefilled, so that its parent relationship remains intact.
7. As a reviewer, I want to edit an existing Suggestion Draft as replacement code, so that I do not have to manipulate its fenced Markdown representation manually.
8. As a reviewer, I want a Draft edit to preserve its TempId, kind, parent relationship, CommentScope, Anchor, and AnchorSnapshot, so that it remains the same Draft.
9. As a reviewer, I want accepting byte-identical Draft content to be a no-op, so that an unchanged edit does not clear useful failure evidence.
10. As a reviewer, I want a real edit of a failed Draft to return it to `draft`, so that a corrected item can be submitted again.
11. As a reviewer, I want blank or invalid edited content refused by the same rules as creation, so that mutation cannot create an invalid Draft.
12. As a reviewer, I want to re-anchor an eligible inline root Draft from the current cursor or Selection, so that I can repair where it belongs.
13. As a reviewer, I want re-anchor to be a visible two-stage interaction, so that the selected Draft and candidate source range are both clear before acceptance.
14. As a reviewer, I want Escape to cancel re-anchor without changing the Draft, so that exploratory navigation is safe.
15. As a reviewer, I want re-anchor to preserve Draft identity, body, kind, and Reply descendants, so that only its Anchor changes.
16. As a reviewer, I want an identical replacement Anchor to be a no-op, so that it neither writes storage nor resets a failure.
17. As a reviewer, I want a real re-anchor of a failed Draft to return it to `draft`, so that the repaired subtree can become eligible for Submission.
18. As a reviewer, I want re-anchor to reject mixed-side, cross-File, descending, unmatched, and hunk-gap-spanning ranges, so that bbr never guesses an Anchor.
19. As a reviewer, I want an Anchor range capped at 30 inclusive lines, so that locally accepted ranges remain within Bitbucket's verified envelope.
20. As a reviewer, I want ordinary old-side Comment ranges supported, so that I can comment on removed code.
21. As a reviewer, I want old-side Suggestions refused, so that bbr does not offer a Suggestion Bitbucket renders with a disabled Apply action.
22. As a reviewer, I want Replies to inherit their root's CommentScope rather than expose independent re-anchor, so that parentage remains the single source of placement.
23. As a LocalReview reviewer, I want re-anchor to capture a replacement AnchorSnapshot, so that later outdated or unavailable placement retains authored evidence.
24. As a RemoteReview reviewer, I want re-anchor to bind the appropriate commit and side without inventing local snapshot semantics, so that the remote contract stays authoritative.
25. As a reviewer, I want to delete a Draft only after confirmation, so that accidental destructive Actions are reversible until accepted.
26. As a reviewer, I want Draft deletion confirmation to show the number of Reply descendants, so that I understand the complete local cascade.
27. As a reviewer, I want deleting a parent Draft to atomically delete all of its Draft Reply descendants, so that no invalid local parent references remain.
28. As a reviewer, I want deletion refused when any member of the subtree is immutable, so that ambiguous or published evidence cannot disappear.
29. As a reviewer, I want every accepted Draft mutation persisted before Presentation changes, so that refresh, switching, restart, and crashes cannot reveal an uncommitted mutation.
30. As a reviewer, I want mutation failure to preserve the previous ReviewCard, Buffer, ScopeProjection, and navigation, so that the visible Review remains internally consistent.
31. As a reviewer, I want a failed edit, re-anchor, or deletion to preserve my active interaction and proposed input, so that I can retry without reconstructing it.
32. As a reviewer, I want successful mutation to restore navigation by typed Draft identity, so that row reflow does not lose my place.
33. As a reviewer, I want Drafts in an active or recovered SubmissionRun to be immutable, so that the frozen participant graph and parent remapping cannot change mid-run.
34. As a reviewer, I want a recovered ambiguous Draft labelled `outcome unknown - resolve before editing`, so that uncertainty is explicit without relying on color.
35. As a reviewer, I want read-only Duplicate-guard reconciliation before mutating a recovered `submitting` Draft, so that an accepted remote Comment is not duplicated or erased locally.
36. As a reviewer, I want to link an unresolved recovered Draft to an existing author-owned Bitbucket Comment, so that bbr can record the confirmed published identity.
37. As a reviewer, I want to confirm that an unresolved recovered Draft was not published, so that it can safely return to `draft` for repair.
38. As a reviewer, I want to decide later about an ambiguous Draft, so that lack of evidence does not force a dangerous assertion.
39. As a reviewer, I want to abandon an unrecoverable SubmissionRun conservatively, so that no further POST occurs and the lock can be released without losing ambiguity evidence.
40. As a reviewer, I want ordinary `draft` and `failed` items mutable after recovery becomes terminal, so that I can repair the remaining PendingReview.
41. As a reviewer, I want ambiguous `outcome_unknown` items to remain immutable after abandonment, so that abandonment is not mistaken for proof of non-publication.
42. As a reviewer, I want published Comment mutation available only when my Authenticated Account UUID matches the Comment author's UUID, so that ownership is proven rather than inferred.
43. As a reviewer, I want Review loading to succeed even if authenticated identity acquisition fails, so that read-only reviewing does not depend on mutation capability.
44. As a reviewer, I want a missing identity or author UUID to disable mutation with a precise reason, so that bbr fails closed.
45. As a reviewer, I want a `401` to invalidate cached mutation identity, so that stale credentials cannot authorize later writes.
46. As a reviewer, I want to edit my published root Comments and Replies, so that I can correct remote content without using Bitbucket's web UI.
47. As a reviewer, I want published Suggestion bodies edited as ordinary raw Comment content, so that their Markdown round-trips exactly.
48. As a reviewer, I want published edits to preserve CommentId, parentage, and CommentScope, so that only the authored body changes.
49. As a reviewer, I want published inline Anchors to remain immutable, so that bbr does not send unsupported or misleading re-anchor updates.
50. As a reviewer, I want to delete my published Comment only after a remote-effect confirmation, so that I understand the action is immediate on Bitbucket.
51. As a reviewer, I want root deletion confirmation to explain that Replies survive beneath a Deleted Comment tombstone, so that I do not expect a local cascade.
52. As a reviewer, I want Deleted Comments rendered as structural tombstones with no mutation Actions, so that surviving Replies retain their real Thread structure.
53. As a reviewer, I want a successful or outcome-unknown published mutation followed by Reconciliation, so that Bitbucket remains authoritative.
54. As a reviewer, I want rejected published mutation to leave the complete visible Session unchanged, so that bbr does not optimistically project a remote effect that failed.
55. As a reviewer, I want published Comment mutation to avoid automatic retries, so that a lost response cannot duplicate or repeat a remote mutation.
56. As a reviewer, I want a `404` mutation result to trigger Reconciliation, so that a stale local Comment graph can be corrected.
57. As a reviewer, I want a failed Reconciliation after confirmed mutation reported as applied-but-reload-required, so that remote success is not misrepresented as mutation failure.
58. As a reviewer, I want a published mutation to continue across Session replacement, so that changing PullRequests does not cancel an authorized remote effect.
59. As a reviewer, I want remote mutation completion to name its Repository-qualified PullRequest when another Session is current, so that results cannot be attributed to the wrong Review.
60. As a reviewer, I want only one remote-write Durable Operation at a time, so that Submission and published mutation cannot interleave unpredictably.
61. As a reviewer, I want later remote writes for a PullRequest refused after Reconciliation failure until authoritative reload, so that stale Session data cannot authorize another write.
62. As a Composer user, I want `Ctrl-E` to invoke External Edit only while the Composer owns input, so that the DiffPane's existing binding is unchanged.
63. As a Composer user, I want External Edit to receive the exact current body bytes, so that prefilled multiline content is not normalized or altered.
64. As a Composer user, I want editor selection to prefer `GIT_EDITOR`, then `VISUAL`, then `EDITOR`, so that common developer configuration works predictably.
65. As a Composer user, I want a missing editor or shell reported non-fatally, so that the Composer remains usable.
66. As a security-conscious user, I want External Edit to use an exclusive owner-only temporary directory and `0600` file, so that unpublished review content is not exposed locally.
67. As a terminal user, I want bbr to leave the alternate screen, restore cooked mode, and suspend input dispatch while the external program runs, so that the editor gets a normal terminal.
68. As a terminal user, I want bbr to recreate its terminal state, restore mouse mode, apply current geometry, and redraw completely afterward, so that the TUI remains usable.
69. As a Composer user, I want changed UTF-8 content with no NUL accepted atomically, so that a valid edit replaces the body completely or not at all.
70. As a Composer user, I want unchanged, cancelled, and failed External Edit outcomes distinguished, so that I know whether anything was applied.
71. As a Composer user, I want every non-fatal External Edit outcome to keep the Composer open, so that I retain control over final save or cancellation.
72. As a Composer user, I want cleanup attempted on every ordinary External Edit path, so that temporary review content is not left behind unnecessarily.
73. As a Composer user, I want accepted content retained even if cleanup alone fails, with the remaining path reported, so that cleanup failure does not destroy my edit.
74. As a terminal user, I want terminal restoration failure to exit safely and report the retained file path, so that bbr never resumes in a partially restored TUI.
75. As a user, I want `[external_edit].max_bytes` to default to 1 MiB and require a positive value, so that returned-file memory use is bounded explicitly.
76. As a user, I want an oversized returned file refused before full allocation, so that the local safety limit is effective.
77. As a user, I want the External Edit byte limit documented as local rather than a Bitbucket Comment limit, so that configuration does not imply an undocumented server contract.
78. As a reviewer, I want one Submission Overlay from authorization through completion, so that progress, repair, and results remain in one coherent surface.
79. As a reviewer, I want the Overlay to show the topologically ordered Draft dependency forest, so that roots and Replies reflect actual POST order and parentage.
80. As a reviewer, I want every Submission row to show typed identity, body summary, scope or parent context, and textual state, so that meaning is inspectable without color.
81. As a reviewer, I want to distinguish queued, posting, waiting, Duplicate-guard reconciliation, persistence, posted, failed, skipped, and outcome-unknown states, so that I know what bbr is doing.
82. As a reviewer, I want selected-row details to show the classified reason, attempt, server delay, parent dependency, and descendant impact, so that failures are actionable.
83. As a reviewer, I want a skipped Reply to identify the nearest failed or unresolved ancestor, so that it is not misrepresented as an independent failure.
84. As a reviewer, I want a nonterminal Submission Overlay to remain blocking for its owning PullRequest, so that dismissal cannot be confused with cancellation.
85. As a reviewer, I want terminal clean and partial results to remain in the same dependency tree until explicitly dismissed, so that I can inspect every outcome.
86. As a reviewer, I want posted Draft rows to be inspectable but never retryable, so that published work is not duplicated.
87. As a reviewer, I want to repair a selected failed Draft directly from the terminal Overlay, so that Submission results connect to the established mutation interactions.
88. As a reviewer, I want Retry selected subtree to include exactly the selected failed Draft and its Reply descendants, so that unrelated work is not repeated.
89. As a reviewer, I want the selected retry participant set previewed before authorization, so that I understand the external effects.
90. As a reviewer, I want no retry-all Action, so that partial repair remains deliberate and dependency-scoped.
91. As a reviewer, I want returning from repair to rebuild the same dependency projection and retain logical selection, so that I can continue triage in context.
92. As a reviewer, I want Submission progress persisted per item before the next POST, so that interruption recovery cannot lose accepted outcomes.
93. As a reviewer, I want no database transaction held during network or timer work, so that persistence remains short and locally recoverable.
94. As a reviewer, I want a response-lost POST checked through the Duplicate guard before any repeat POST, so that duplicate Comments are avoided when possible.
95. As a reviewer, I want failure of all Duplicate-guard reads to produce `outcome_unknown`, so that uncertainty stops publication rather than being guessed away.
96. As a reviewer, I want each Draft to receive three total POST attempts, so that retries are bounded and predictable.
97. As a reviewer, I want Duplicate-guard reads to have an independent three-attempt budget, so that publication checks do not consume POST opportunities.
98. As a reviewer, I want fallback waits of exactly one and two seconds, so that retry behavior is deterministic.
99. As a reviewer, I want valid `Retry-After` guidance to raise but never shorten local backoff, so that bbr respects Bitbucket's requested delay.
100. As a reviewer, I want both delay-seconds and HTTP-date `Retry-After` forms supported, so that standard server guidance is honored.
101. As a reviewer, I want malformed, overflowed, expired, or absent retry guidance to fall back safely, so that invalid metadata cannot break Submission.
102. As a reviewer, I want wait state and effective duration persisted before a timer starts, so that crash recovery cannot retry early.
103. As a reviewer, I want a recovered pending wait repeated in full, so that bbr favors over-waiting over an unsafe early retry.
104. As a reviewer, I want timer launch or sleep failure to pause recoverably without consuming an attempt, so that infrastructure failure is not misclassified as a Bitbucket rejection.
105. As a reviewer, I want static waiting details rather than a countdown, so that Presentation requires no polling clock.
106. As a reviewer, I want exhausted retryable POSTs recorded as failed with their ApiError, so that they can be repaired and retried deliberately.
107. As a reviewer, I want selected-subtree retry to start a fresh attempt budget, so that a repaired Draft receives the normal bounded policy.
108. As a reviewer, I want final server delay carried into a selected-subtree retry when applicable, so that a fresh run does not immediately violate recent guidance.
109. As a reviewer, I want a changed SourceCommit to enter a Stale repair gate with no new POST, so that obsolete inline Anchors cannot be published.
110. As a reviewer, I want no submit-anyway Action, so that stale safety cannot be bypassed ambiguously.
111. As a reviewer, I want the stale Overlay to show loaded and observed SourceCommits and the blocking reason, so that the repair requirement is explicit.
112. As a reviewer, I want Reload PullRequest to prepare one complete Candidate Session atomically, so that stale repair never publishes a hybrid Session.
113. As a reviewer, I want reload failure to preserve the previous Session, Session Epoch, Overlay, and retry Action, so that inspection remains usable.
114. As a reviewer, I want an unavailable ScopeResolution treated as visible evidence rather than a failed reload, so that missing mapping evidence does not hide the Draft.
115. As a reviewer, I want recovered stale runs to perform read-only Duplicate-guard reconciliation, so that SourceCommit movement does not prevent establishing prior publication.
116. As a reviewer, I want a recovered run retained until it completes cleanly or I explicitly abandon it, so that its lock and evidence are not released implicitly.
117. As a reviewer, I want Review-level roots eligible after successful reload, so that unanchored publication is not blocked unnecessarily.
118. As a reviewer, I want File-level roots eligible only when their authored FileScope remains current, so that projected moves are not silently posted as authored truth.
119. As a reviewer, I want moved, outdated, or unavailable File-level roots left pending for recreation or deletion, so that unsupported File re-anchor is not invented.
120. As a reviewer, I want new-side inline roots explicitly re-anchored after SourceCommit changes, so that even plausible projections do not silently rewrite authored Anchors.
121. As a reviewer, I want old-side roots preserved only when the authoritative refreshed Diff contains the exact authored span, so that BaseCommit semantics remain side-aware.
122. As a reviewer, I want Replies beneath an unpublished root to inherit that root's stale gate, so that descendants cannot bypass an ineligible parent.
123. As a reviewer, I want Replies beneath a reconciled published Comment to remain eligible after reload, so that stable CommentId parentage can continue without an Anchor POST.
124. As a reviewer, I want stale repair eligibility computed independently per root subtree, so that one unrepaired root does not block unrelated eligible work.
125. As a reviewer, I want a fresh SubmissionRun to capture the refreshed SourceCommit and check it again before POST, so that a second source change is also refused safely.
126. As a reviewer, I want Submission to continue as a PullRequest-qualified Durable Operation when I switch Reviews, so that Session replacement does not cancel authorized work.
127. As a reviewer, I want returning to the owning PullRequest to reconstruct the live or terminal Overlay from durable state, so that stale Session Frames are not retained.
128. As a reviewer, I want Session Epoch to reject stale Session-bound completions without discarding Durable Operation checkpoints, so that asynchronous work cannot mutate the wrong Session.
129. As a reviewer, I want ordinary quit to drain an active Submission or published mutation to a persisted terminal outcome, so that intentional shutdown does not create avoidable recovery work.
130. As a reviewer, I want abrupt termination recoverable from SubmissionRun and Draft checkpoints, so that process failure does not lose the PendingReview.

## Implementation Decisions

- `ReviewIdentity` is the sole Review identity. Remote identities are Workspace/Repository/PullRequestId-qualified; commands may own a copy-safe representation but do not introduce a competing domain concept.
- Every external effect carries a unique CommandId. Durable Operations additionally carry an OperationId and remote ReviewIdentity; Session-bound work additionally carries Session Epoch. Typed target identity must also match before a completion is admitted.
- Submission and published Comment mutation share one global remote-write lane. Draft mutation is local and External Edit is Session-bound, so neither occupies that lane.
- A remote-write operation retains the lane through its first Reconciliation attempt. Failed Reconciliation releases the lane but marks that PullRequest as requiring authoritative reload before another remote write from the stale Session.
- Review owns pure Draft mutation validation, root stale-repair eligibility, and the clock-free SubmissionRun transition model. It performs no persistence, network, clock, sleep, terminal, or Presentation I/O.
- A SubmissionRun freezes and durably stores its ordered participant graph at creation. Recovery uses this membership rather than recomputing it from the current PendingReview.
- A selected-subtree retry creates a fresh SubmissionRun containing only the selected eligible Draft and its transitive Reply descendants.
- Draft mutation uses a closed transaction-shaped intention for body edit, re-anchor, or subtree deletion. The store atomically rechecks ReviewIdentity, TempId, DraftState, parentage, graph closure, SubmissionRun participation, and the proposed cascade.
- Every Draft mutation follows stage, persist, publish. Presentation stages the complete candidate PendingReview, ScopeProjection, Presentation Frame, interaction result, and navigation before persistence; publication after commit is infallible.
- Editing preserves Draft identity and all non-body authored data. A real edit resets `failed` to `draft`; a byte-identical edit performs no persistence and preserves failure evidence.
- Suggestion editing exposes replacement code while bbr preserves the Suggestion kind and fenced Markdown representation used for storage and Bitbucket `content.raw`.
- Re-anchor applies only to inline root Drafts. It replaces the Anchor while preserving TempId, kind, body, and descendants; Replies and published Comments have no independent re-anchor.
- Valid Anchors are one-side-only, matched, ascending, within one File and visible hunk continuity, and no longer than 30 inclusive lines. Old-side Suggestions remain unsupported.
- LocalReview re-anchor replaces the root AnchorSnapshot. RemoteReview re-anchor stores side-appropriate authored commit identity without introducing a local snapshot.
- Draft deletion is one atomic local subtree cascade. If any descendant is immutable, the whole deletion is refused.
- A Draft participating in an active or recovered SubmissionRun is immutable for the run's lifetime. `submitting`, transient `posted`, and `outcome_unknown` records are never locally mutable.
- Ambiguous recovery may resolve by linking an author-owned Comment, confirming non-publication, or deciding later. Abandon recovery emits no POST, changes the in-flight ambiguous item to `outcome_unknown`, terminalizes the run as partial, and releases its lock without asserting non-publication.
- The persistence schema advances through one forward-only migration. Existing TempIds, bodies, kinds, parent relationships, CommentScopes, AnchorSnapshots, and DraftStates are preserved; normalized SubmissionRun participants and checkpoints are added. No dual runtime interface is retained.
- Bitbucket independently acquires and caches the Authenticated Account UUID for the Credential lifetime. Acquisition failure does not fail Review loading; `401` invalidates the cached capability.
- Published Comment ownership compares UUIDs only. Missing identity evidence disables mutation; display names and Credential presence never authorize it.
- Published Comment updates are CommentId-addressed and send only accepted Composer bytes as `content.raw`. They preserve identity, parentage, and CommentScope; Suggestion Markdown is ordinary Comment content.
- Published inline Anchors are immutable. No published re-anchor or replacement workflow is part of M16 because Bitbucket rejects Anchor changes atomically.
- Published deletion is remote and never cascaded locally. A root with Replies reconciles as a Deleted Comment tombstone retaining Thread structure.
- Published Comment mutation has no automatic retries. Definite failure restores the initiating interaction when its Session remains current; response-lost or malformed-success outcomes start Reconciliation as unknown.
- Confirmed published mutation success always starts Reconciliation. bbr never patches the old Comment graph optimistically.
- `404` mutation results also start Reconciliation. A failed Reconciliation after confirmed mutation reports success plus reload-required rather than mutation failure.
- Bitbucket owns HTTP, JSON, authenticated-account wire data, Comment update/delete shapes, Deleted Comment decoding, Retry-After parsing, and response classification. Raw Atlassian vocabulary never crosses its boundary.
- ApiError represents a classified response received from Bitbucket. Transport delivery is represented separately as definitely-not-delivered or outcome-unknown; malformed write success is outcome-unknown because the effect may have landed.
- `HttpClient.Response` owns optional `retry_after_ms`. The real adapter recognizes `Retry-After` case-insensitively, parses non-negative delay-seconds or HTTP-date, and returns `null` for missing, malformed, overflowing, or expired values.
- Retry guidance propagates only from definite `429` and `5xx` responses. Undocumented rate-limit headers are diagnostic only.
- Each Draft receives three total POST attempts with deterministic one-second and two-second fallback waits. Effective delay is the maximum of local backoff and valid server guidance, with no jitter or arbitrary duration cap.
- Duplicate-guard reads have an independent three-attempt budget with the same schedule. Exhaustion after an ambiguous POST yields `outcome_unknown` and forbids another POST.
- Wait phase, attempt count, classified reason, local delay, optional server delay, effective delay, and pending marker are durable before timer launch. Recovery repeats a pending wait in full.
- Timer launch or sleep failure pauses infrastructure without consuming an attempt. The pure model emits durations but never reads time or sleeps.
- Presentation owns Interaction Context, direct typed ReviewCard targeting, ActionAvailability, Overlays, Composer and confirmation state, ScopeProjection, complete Frame staging, command scheduling, completion admission, and outcome projection.
- Contextual bindings are `e` for edit, `a` for root-Draft re-anchor, and `D` for delete. Unavailable Actions remain visible and return exact identity- or state-specific reasons.
- One typed-target Composer handles Draft and published Comment editing with existing validation. A successful save emits either a local persistence intention or a remote mutation command according to its retained target.
- Re-anchor is a two-stage capture retaining the selected TempId while source navigation chooses a replacement Anchor. Delete confirmation names either local descendant count or remote tombstone consequence.
- External Edit is available only in the Composer Interaction Context through `Ctrl-E`; the DiffPane binding remains unchanged.
- Presentation emits an owned correlated External Edit command with the exact Composer body snapshot and rejects input until the matching completion returns.
- The terminal adapter resolves `GIT_EDITOR`, `VISUAL`, then `EDITOR`; invokes the selected command through `/bin/sh -c` with the temporary path passed as a safely quoted positional argument; and inherits stdio and working directory.
- External Edit uses an exclusive owner-only temporary directory and exclusive `0600` Markdown file, writes exact bytes, suspends vaxis only after preparation, restores cooked terminal mode, runs synchronously, then recreates input and redraws before queued event dispatch resumes.
- Changed results are accepted only after exit code zero, byte difference, size validation, UTF-8 validation, and NUL rejection. Atomic Composer reseed preserves the old body on allocation failure.
- External Edit classifies applied, unchanged, cancelled, and failed outcomes and keeps the Composer open after every non-fatal result. Cleanup failure after accepted content does not discard it; terminal restoration failure is fatal and reports the retained path.
- Configuration exposes exactly `[external_edit].max_bytes = 1048576`. The value must be positive, has no alias, is measured in raw bytes before full allocation, and is documented as a local returned-file safety limit rather than a Bitbucket Comment limit.
- The Submission Overlay is one dependency-tree Overlay from authorization through terminal result. It shows static per-item state, selected-item detail, parent blockage, classified reason, attempt and delay metadata, and descendant impact.
- A nonterminal Overlay cannot be dismissed as cancellation. Terminal clean or partial results remain until explicitly dismissed.
- Repair from the terminal Overlay reuses the typed-target Composer, two-stage re-anchor, and confirmation interactions. Retry selected subtree is the only retry Action; there is no retry-all.
- Recovery uses the same Overlay. Duplicate-guard progress, ambiguity choices, and conservative Abandon recovery are part of the dependency tree rather than a separate workflow.
- Overlay visibility is Session-relative, while Submission ownership is PullRequest-qualified. Switching Sessions removes the blocking Overlay but does not cancel the Durable Operation; returning reconstructs it from durable state.
- A changed SourceCommit enters the Stale repair gate and emits no new POST. There is no submit-anyway Action.
- Reload PullRequest stages a complete Candidate Session and publishes atomically. Failure preserves the old Session and Epoch; individual unavailable ScopeResolution results remain usable evidence.
- Stale eligibility is per root: Review-level roots become eligible after reload; File-level roots require current authored scope; new-side inline roots require explicit re-anchor; old-side inline roots may remain only when the exact authored span still exists; Replies inherit local-root eligibility or may use a reconciled published parent CommentId.
- A fresh selected-subtree Submission captures the refreshed SourceCommit and runs the stale check again before POST.
- Ordinary quit drains Durable Operations to a persisted terminal outcome. Abrupt exit relies on SubmissionRun, Draft checkpoints, and the OS advisory lock for recovery.
- Implementation proceeds in dependency order: identity and durability foundation; pure Review contracts; Bitbucket capability; Draft mutation; published Comment mutation; External Edit; Submission repair; integrated acceptance and documentation.

## Testing Decisions

- Tests assert external behavior rather than private implementation details. They verify published Projection, emitted typed commands, durable records, interaction retention, navigation by identity, classified outcomes, and eventual ownership cleanup; they do not assert allocator call numbers, arena positions, private phases, or worker internals.
- The highest deterministic integration seam is the typed Presentation state machine. Representative `Action -> OwnedCommand -> typed completion -> Projection` sequences prove cross-module composition without repeating every lower-level branch combination.
- Presentation integration coverage includes representative Draft edit, real and no-op re-anchor, subtree deletion, active and recovered run refusal, ambiguity resolution, abandonment, LocalReview snapshot replacement, RemoteReview boundaries, and persisted mutation reload after Session replacement.
- Pure Review tests exhaustively cover Comment, Reply, and Suggestion mutation rules; Anchor side and range validation; the 30-line boundary; Suggestion fence handling; failed-state reset; graph closure; immutable subtree refusal; root stale eligibility; participant freezing; retries; Duplicate guard; recovery; abandonment; and selected-subtree membership.
- Composer and Selection tests exhaustively cover prefill, validation, atomic reseed, portable Shift+Arrow selection start/extension/contraction/reversal, `v` as the reliable Selection Action, refusal shapes, and Escape.
- Transactional store contract tests use the in-memory adapter and SQLite implementation to cover each DraftMutation and SubmissionRun intention, forward migration preservation, concurrent-state mismatch, cascade atomicity, checkpoint durability, and rollback.
- Exhaustive allocation-failure sweeps cover each distinct stage-persist-publish transition. Every failure must preserve the old complete Projection and retain the reviewer's active edit, re-anchor, or confirmation input.
- Bitbucket fake-adapter fixtures cover UUID acquisition and invalidation, body-only update shape, Suggestions as `content.raw`, deletion and Deleted Comment decoding, immutable Anchor rejection, every ApiError class, missing identity evidence, and definite-versus-unknown delivery.
- Retry-After adapter and pure policy tests cover case-insensitive lookup, delay-seconds, HTTP-date, malformed, expired, and overflowing values; `429` and `5xx` propagation; ignored metadata for other classes; maximum-delay selection in both directions; exact one-second/two-second waits; three-attempt ceilings; independent POST and Duplicate-guard budgets; pending-wait recovery; timer failure; and terminal-delay carryover.
- Published Comment mutation crosses Presentation with one author-owned edit and one confirmed delete, proving UUID ActionAvailability, typed command identity, definitive interaction restoration, unknown-outcome Reconciliation, no optimistic graph patch, and PullRequest-qualified completion after Session replacement.
- Submission crosses Presentation from authorization through terminal dependency-tree result, proving parent-before-Reply command order, checkpoint-before-next-POST, continue/skip/abort behavior, selected-subtree isolation, waiting and exhaustion projection, clean and partial terminalization, and `outcome_unknown` after exhausted publication checks.
- Recovery and stale tests cross Presentation for interrupted-run discovery, explicit claim, held-lock refusal, current-source resume, changed-source read-only Duplicate guard, automatic clean completion, explicit abandonment, atomic Candidate Session reload, per-root eligibility, unrelated stale-root exclusion, and a second SourceCommit change before POST.
- Async admission tests deliberately interleave Session replacement with Draft POST, wait, Reconciliation, External Edit, and File Enrichment completions. Late, duplicate, wrong-CommandId, wrong-OperationId, wrong-target, stale-Epoch, and launch-failure completions are covered once per distinct admission rule.
- A deterministic terminal-adapter harness drains each typed command family into scripted executors and returns completions through the production event sink, proving ownership transfer, correlation, queueing, launch failure, admission, and reaping without network, sleep, terminal, or PTY dependencies.
- External Edit adapter tests cover editor precedence, safe shell argument passing, secure directory and `0600` file creation, exact bytes, byte-limit enforcement, UTF-8 and NUL validation, process outcomes, cleanup, and fatal restoration failure without requiring a real terminal.
- Existing prior art includes pure Submission state-machine tests, FakeHttpClient response sequences, in-memory and SQLite PendingReviewStore round trips, headless Presentation rendering, typed presentation-adapter command tests, and Session Epoch rejection for asynchronous acquisition.
- One opt-in PTY smoke test uses a controlled helper program to verify inherited terminal streams, cooked mode and echo, exact prefilled and returned bytes, mouse disable and restore, alternate-screen exit and re-entry, complete redraw, and a recreated input loop. It remains outside the hermetic default suite.
- Shift+Arrow terminal compatibility remains a documented manual check recording terminal, version, multiplexer, and configuration. It creates no support guarantee because terminal escape sequences cannot be established by a generic PTY; `v` remains reliable.
- One credential-gated, destructive-opt-in Bitbucket check uses a disposable PullRequest to acquire UUID, create, fetch, update, and delete a uniquely marked Review-level Comment while verifying stable identity, author, body, and CommentScope. It performs best-effort cleanup and never prints Credential material.
- No live `429` is required. Raw-response fixtures and deterministic parser and policy tests establish Retry-After behavior because Bitbucket rate limiting cannot be induced reliably.
- Each implementation slice keeps `zig build test` green. Non-hermetic PTY, manual terminal, and live Bitbucket checks run only through their explicit opt-ins.

## Out of Scope

- Applying Suggestions; Bitbucket's web UI remains responsible for applying them.
- Authoring old-side Suggestions; ordinary old-side Comments remain supported.
- Mutating Comments authored by another Bitbucket account or inferring ownership from display names.
- Re-anchoring a published Comment or automatically creating a replacement published Comment.
- Retrying published Comment mutations automatically.
- Submitting against a changed SourceCommit without reload and required repair.
- A submit-anyway path.
- Retry-all or more than one active Submission at a time.
- Automatic takeover of a SubmissionRun whose OS advisory lock is held by another process.
- Durable recovery records for published Comment mutation; authoritative reload determines the result after abrupt exit.
- Countdown timers or periodic Presentation ticks for retry waits.
- Treating `[external_edit].max_bytes` as a Bitbucket Comment character or payload limit.
- Defining a supported-terminal matrix for Shift+Arrow input.
- General Presentation and navigation polish owned by M15, Diff and Highlighting completeness owned by M17, and LocalReview expansion owned by M18.

## Further Notes

- Bitbucket Cloud live probes established that root deletion with Replies leaves a Deleted Comment tombstone, body-only updates round-trip Suggestion roots and Replies, and published Anchor updates are rejected atomically.
- Live range probes established side-specific 1-based range fields, bottom-line ReviewCard placement, a 30-inclusive-line maximum, server acceptance of ambiguous mixed shapes that bbr must still refuse, and a disabled Apply action for old-side Suggestions.
- Bitbucket documents `429` but no retry ceiling and does not guarantee `Retry-After`; the bounded three-attempt policy is therefore a local product decision.
- Bitbucket remains authoritative for published Comments. Draft `posted` state remains transient reconciliation evidence and is removed after clean Submission completion.
- SubmissionRun liveness uses the existing OS advisory-lock decision. Lock-file existence, PID, or heartbeat metadata never authorizes takeover.
- The submit adapter retains its current whole-operation allocator lifetime; it must not reset the client arena while the HTTP client is alive.
- Prototype decisions selected direct contextual ReviewCard Actions and the dependency-tree Submission Overlay. Those interaction choices are settled inputs to implementation, not alternatives to revisit.
