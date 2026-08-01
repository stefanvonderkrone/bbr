# Presentation is a typed command-producing state machine

Presentation owns the lifetime and publication of everything the terminal renders, but terminal mechanics and remote I/O must remain outside it. We will replace the ownership choreography in `app.run` with one deep Presentation module that consumes typed inputs, produces typed commands, and exposes an immutable render projection. This gives production and deterministic integration tests the same seam while preserving Zig's exhaustive tagged-union checking.

This decision builds on ADR-0007 (durable Submission reconciliation), ADR-0010 (File Enrichment ownership transfer), and ADR-0011 (SubmissionRun liveness). It is the integration seam that makes those local ownership guarantees safe when Actions and worker completions interleave.

## Context

The existing implementation has safe local primitives, but their composition remains manual:

- `ArenaRing.begin/commit/abort` protects a visible Buffer from a failed rebuild.
- File Enrichment transfers independently owned sides into Session storage.
- `app.run` still orders Session destruction, PendingReview loading, Buffer replacement, navigation updates, stale-result rejection, worker reaping, submission persistence, and shutdown.

That ordering permits invalid hybrid states. In particular, the current replacement path can destroy the old Session, install the new Session, and then retain the old Buffer value if construction of the new Buffer fails. The Buffer's arena may remain alive while the Session data it borrows has already been destroyed.

PTY tests cannot exhaustively exercise these event-order and allocation-failure lifetimes. The needed test seam is the Presentation transition itself.

## Decision

The external interface has one mutation entry point, one command drain, one immutable projection, and one shutdown query:

```zig
pub const Presentation = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        dependencies: Dependencies,
        boot: Boot,
    ) InitError!Presentation;

    pub fn deinit(self: *Presentation) void;

    /// Serialized and non-reentrant. Consumes every owned input, including a
    /// completion that is stale, rejected, or fails during admission.
    pub fn dispatch(
        self: *Presentation,
        input: OwnedInput,
    ) DispatchError!void;

    /// Moves one queued command to the terminal adapter. The adapter must
    /// return one correlated completion or launch-failure completion.
    pub fn takeCommand(self: *Presentation) ?OwnedCommand;

    /// Borrowed and immutable. Valid until the next dispatch or deinit.
    pub fn projection(self: *const Presentation) Projection;

    /// True only after shutdown was requested, every Durable Operation reached
    /// a persisted terminal state, and all issued commands were drained.
    pub fn readyToExit(self: *const Presentation) bool;
};
```

`OwnedInput` and `OwnedCommand` are closed tagged unions. New cases require exhaustive handling at compile time. Every command carries a correlation identity; Session-bound commands additionally carry a Session Epoch, and Durable Operation commands carry an OperationId plus Repository-qualified PullRequest identity.

The terminal adapter:

- translates vaxis events into portable Presentation input;
- moves commands into workers or timers;
- owns futures, threads, event posting, and reaping;
- returns typed completions, including worker-launch failure;
- renders the current Projection;
- never swaps or destroys a Session, Buffer, PendingReview, or navigation state.

Presentation owns portable Keymap resolution, Leader, Count, and Overlay input capture. Keeping those inside the module lets Session replacement reset half-resolved input atomically without an ordering protocol with the terminal adapter.

## Published state

One privately owned aggregate is the atomic unit of publication:

```text
Published review
├── Session and Session Epoch
├── repository-qualified PendingReview and its storage
├── active Buffer generation and Buffer
├── navigation and Selection
├── expanded Folds and isolated File
├── Composer, Leader, and Count
└── Session-specific status
```

Reviewer preferences cross Session replacement: layout, scope, and `show_resolved`. Session-relative state does not: navigation, Selection, expanded Folds, isolated File, Composer, Leader, Count, and Session-specific status reset when replacement commits.

Rendering receives only a borrowed immutable Projection. It cannot retain pointers across `dispatch`, and it cannot access mutable Session, PendingReview, navigation, ArenaRing, worker, or Durable Operation state.

## Atomic Session replacement

A loaded Session is a candidate, not current state. Replacement prepares the candidate's PendingReview, initial Buffer, navigation, and reset Session-relative state privately. Only a completely usable candidate is published; the old aggregate is destroyed after publication commits.

The agreed outcomes are:

- If candidate PendingReview loading or Buffer construction fails, destroy the candidate and preserve the exact old aggregate, including its cursor, Selection, folds, isolation, input grammar, and Session Epoch.
- If initial load fails and there is no old aggregate, publish no Session. Quit, help, and Picker Actions remain available.
- While replacement loads, retain the old aggregate as rollback state but suspend Session-specific Actions. Session-independent Actions remain available, and Durable Operations continue.
- Latest replacement intent wins. If A is current and B then C are requested, discard B even if it completes first. If C fails, restore interaction with A rather than falling back to B.
- Selecting A again through the Picker cancels replacement intent and reuses A. Explicit refresh and post-Submission Reconciliation may still replace a Session with another Session for the same PullRequest.
- A File Enrichment result for A may be accepted while C is loading because A remains published until C commits.

Session Epoch identifies one published Session, not one PullRequest. It advances only when replacement commits. File Enrichment is accepted only for the exact current Session Epoch and valid File index; PullRequestId plus File index is insufficient because Reconciliation and refresh can replace a Session with another for the same PullRequest.

Every owned completion is consumed or destroyed exactly once. Superseded candidate Sessions, stale File Enrichment, rejected results, worker post failures, and shutdown draining all use the same admission path.

## Buffer transactions

Buffer allocation, construction, commit/rollback, navigation normalization, and generation policy are hidden behind Presentation. Callers do not use `ArenaRing.begin/commit/abort`.

Changing layout, scope, resolved visibility, folds, isolation, Draft projection, or File Enrichment stages the resulting Buffer before publishing the related visible state. A failed rebuild preserves the previous Buffer and navigation. File Enrichment already admitted safely into its Session remains available for a later reprojection even if that immediate Buffer build fails.

Draft saving uses one deep `Published.saveDraft` interface rather than exposing a Buffer candidate or transaction guard. It constructs the candidate Draft, stages its Buffer, persists the Draft, and then publishes Draft and Buffer through an infallible final step. Allocation, Buffer construction, or persistence failure preserves the exact old projection; the Composer closes only after success. This keeps the stage → persist → publish ordering and `ArenaRing` generation policy out of every caller.

## Session-bound work and Durable Operations

Session replacement invalidates only Session-bound projection work. It does not cancel reviewer-authorized durable effects.

- File Enrichment carries Session Epoch and is rejected after its Session is replaced.
- Submission carries an OperationId and Repository-qualified PullRequest identity. It continues posting and persisting after its originating Session is replaced.
- Submission progress always persists against its original PullRequest. Visible modal/projection changes additionally depend on which Session is current.
- When another PullRequest becomes current, remove the old PullRequest's blocking submission modal and show a non-blocking global status identifying the PullRequest being submitted. Completion likewise produces a PullRequest-qualified global result.
- Only one Submission is active globally for now. Another PullRequest may be reviewed, but attempting another Submission reports which PullRequest is already submitting.

PullRequest storage identity is `(Workspace, Repository, PullRequestId)`. PullRequestId alone is only unique within a Repository and cannot key the global SQLite database safely.

## Submission checkpoints

There is no transaction shared by SQLite and Bitbucket. Submission therefore uses short per-item checkpoints rather than POSTing the entire batch and persisting every outcome once at the end:

```text
persist A as submitting
POST A
persist A outcome + persist B as submitting
POST B
persist B outcome
```

Persisting the previous outcome and next intent may share one short SQLite transaction. No SQLite transaction remains open during network I/O.

Presentation does not emit the next POST command until the previous outcome is durable. If persistence fails after a remote result, Presentation retains that result, pauses the Durable Operation, exposes a retryable global error, and emits no further POST.

A persisted `submitting` Draft found during recovery is ambiguous: Bitbucket might have accepted its POST before the process died. Recovery performs the Duplicate guard first. A match becomes `posted(CommentId)`; absence permits the normal POST path when anchors are still current.

The durability seam must express these transaction-shaped intentions rather than expose raw SQLite choreography. It evolves the current per-Draft `PendingReviewStore` capabilities to cover Repository-qualified review loading, active SubmissionRun discovery, beginning a run, checkpointing an outcome and next intent, and terminal clean/partial completion. Production uses SQLite; deterministic tests use an in-memory transactional adapter.

## SubmissionRun recovery and process ownership

SubmissionRun is durable recovery state, not proof of a live owner. ADR-0011 defines authoritative local liveness:

- acquire an exclusive OS advisory lock for the Repository-qualified PullRequest before creating the active SubmissionRun;
- hold the lock's file descriptor for the complete Submission;
- a held lock means another local `bbr` instance owns the run;
- an unheld lock beside an active row means recovery is available;
- never steal a held lock automatically; a hung owner must be terminated by the user;
- PID, owner UUID, and heartbeat timestamps may be diagnostic metadata but never authorize takeover.

Startup exposes interrupted runs as non-blocking global notifications even when the reviewer opens another PullRequest. Recovery requires explicit confirmation because it may cause external POSTs.

Before recovery emits a new POST, it reacquires the OS lock and checks the PullRequest's SourceCommit. A changed SourceCommit blocks all new POSTs but does not block read-only Duplicate-guard reconciliation: ownership of ambiguous `submitting` Drafts must be resolved before repair.

If automatic matching cannot resolve an ambiguous Draft, the reviewer may:

- link it to an existing author-owned Bitbucket Comment, recording that CommentId as `posted`;
- explicitly confirm it was not published, returning it to `draft` for repair;
- decide later, leaving it unresolved and immutable.

Unresolved ambiguous Drafts use an amber/orange background plus the explicit label `outcome unknown - resolve before editing`. Confirmed failures retain red treatment. Meaning never depends on color alone.

Draft editing, re-anchoring, deletion, and mutation of author-owned published Comments are tracked separately under `.scratch/review-item-mutation/`. A Draft participating in an active SubmissionRun or unresolved after recovery cannot be mutated.

## Shutdown

Quit with no Durable Operation begins ordinary command draining. Quit during Submission enters a `finishing Submission for <PullRequest>` state: stop accepting new work, drain and destroy Session-bound results, allow Submission to reach a persisted terminal outcome, then exit.

Abrupt termination remains recoverable from SubmissionRun and Draft checkpoints, but an ordinary quit does not deliberately abandon an authorized Submission.

## Dependency placement

In-process behavior stays behind Presentation with no extra external seam:

- Actions and portable input grammar;
- atomic publication and rollback;
- Session Epoch admission;
- Buffer and navigation construction;
- the clock-free Submission state machine;
- command scheduling policy and stale-result disposal.

Local-substitutable dependencies are injected as internal seams:

- transactional Review durability: SQLite and in-memory adapters;
- Submission locks: OS advisory-lock and in-memory lock-table adapters;
- allocator: production allocator and tracking/failing test allocators.

Bitbucket is truly external. Presentation represents remote work as typed commands and completions. The production worker adapter uses the existing Bitbucket/HTTP/CommentPoster implementations; deterministic tests inspect commands and feed scripted completions without credentials, threads, sleeps, vaxis, or PTYs.

Terminal rendering is an adapter over Projection. vaxis does not cross the Presentation seam.

## Errors and tests

Expected operational failures become typed Projection state rather than escaping and leaving callers to repair ordering:

- candidate load, store, or Buffer failure;
- lock already held by another instance;
- changed SourceCommit;
- rejected or ambiguous Bitbucket operation;
- persistence temporarily unavailable;
- stale completion;
- Action refused while replacement is pending.

`dispatch` returns only failures that prevent Presentation from preserving its invariants, principally allocator exhaustion or a corrupt adapter/ownership contract. Owned inputs are still disposed on error.

The Presentation interface is the deterministic integration-test seam. Tracking and failing allocators drive complete Action/completion sequences and verify published state, emitted commands, and eventual cleanup. PTY E2E remains a thin real-world smoke test. Tests target observable behavior rather than ArenaRing indices, allocator implementation, worker threads, or private state-machine phases.

## Options considered

### Minimal reducer returning effects

```zig
pub fn apply(self: *Presentation, input: Input) !Update;
pub fn projection(self: *const Presentation) Projection;
```

`Update` would return a borrowed slice of effects created by the transition. This has the smallest method count and retains exhaustive tagged unions. We rejected the returned-slice shape because it gives the caller an ordering rule: copy or start every effect before the next `apply`. Command ownership, backpressure, launch failure, and shutdown draining are clearer when commands move explicitly out of a queue. We retained its single mutation entry point and closed tagged unions.

### Extensible type-erased WorkOrders

```zig
pub fn dispatch(self: *Presentation, input: Input) !void;
pub fn nextEffect(self: *Presentation) ?Effect;
pub fn projection(self: *const Presentation) Projection;
```

Each WorkOrder would carry an owned type-erased payload, execution function, trusted completion handler, and destroy function. New worker kinds would not add cases to a central union. We rejected this flexibility because it gives up Zig's exhaustive checking and moves correctness into function pointers, payload destructors, and private constructors. The current set of command kinds does not justify that loss of compile-time visibility.

### Directly injected asynchronous worker ports

Presentation could call injected `load`, `enrich`, and `post` ports that schedule callbacks. This would reduce explicit command types, but callbacks introduce reentrancy and lifetime rules, make deterministic ordering less visible, and entangle the module with execution mechanics. We rejected callbacks in favor of commands as data and serialized completion input.

### Keep orchestration in `app.run`

We could add tests around the existing helpers and retain manual Session swaps, Buffer transactions, and worker-result switches. This does not create the needed seam: allocator and event-order failures still cross helpers, vaxis remains required to drive the lifecycle, and each new completion repeats ownership cleanup. We rejected incremental helper extraction because it would preserve a shallow interface and the existing composition risk.

### Heartbeat lease for cross-process Submission ownership

A durable lease row with expiry and heartbeat would allow automatic takeover. We rejected it because a suspended or paused owner can outlive its lease and resume after another instance takes over. Bitbucket offers no fencing token or idempotency key to reject the former owner. ADR-0011 chooses an OS advisory lock instead.

### One SQLite transaction after posting the whole batch

This minimizes local writes but loses all remote outcomes if the process dies before the final transaction. Restart would see unpublished Drafts and risk duplicate Comments. We rejected it in favor of per-item checkpoints required by ADR-0007.

## Consequences

- `app.run` becomes a thin terminal adapter: translate input, execute typed commands, return completions, render Projection, and drain workers.
- Presentation is deliberately a large implementation behind a small interface. Its depth comes from concentrating atomic publication, ownership, persistence ordering, recovery, and shutdown rather than passing them through.
- Typed command/completion unions grow when a genuinely new external operation appears. This compile-time exhaustiveness is intentional.
- Commands and completions need explicit owned payload cleanup in Zig, but there is one exactly-once protocol rather than one per event arm.
- A complete published review may be heap-resident so its ArenaRing has a stable address and atomic replacement is a pointer swap.
- Short synchronous SQLite checkpoints and OS-lock acquisition may briefly block the terminal thread. Workerizing them would add another acknowledgement protocol and requires measured need before reconsideration.
- Submission changes from one monolithic background worker into a sequence of externally executed commands, increasing event traffic while making persist-before-next-POST structural and testable.
- The durability store requires a schema/interface migration from `(pr_id, local_id)` CRUD to Repository-qualified, transaction-shaped operations and active SubmissionRun discovery.
- Removing Presentation would scatter its invariants back across the terminal loop, workers, store calls, and tests. Passing this deletion test is evidence that the module earns its seam.
