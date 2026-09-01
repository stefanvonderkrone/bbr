# Operations

M16 hardens review-item mutation and Submission around one rule: Presentation
authorizes work and owns projection, Review owns local mutation and Submission
policy, Bitbucket owns remote wire behavior, and the terminal adapter only
executes typed `OwnedCommand` values and returns correlated `OwnedInput`
completions.

## Mutation ownership

- Draft body edit, re-anchor, and subtree deletion are transaction-shaped local
  mutations. The store rechecks ReviewIdentity, parentage, graph closure,
  DraftState, and active or recovered SubmissionRun participation before commit.
- A published Comment can be edited or deleted only when the Authenticated
  Account UUID matches its author UUID. Missing identity evidence fails closed.
- Published Anchors are immutable. Editing changes only `content.raw`; there is
  no published re-anchor action. Deleted Comments may remain as structural
  tombstones so surviving Replies retain CommentId, author, parentage, and root
  CommentScope.
- Remote mutations and Submission are Durable Operations qualified by
  Repository and PullRequest. They continue across Session replacement, but
  their result is never projected into a different PullRequest. Remote writes
  share one lane through their first Reconciliation attempt.

## External Edit

`Ctrl-E` in an open Composer snapshots its exact bytes and invokes the first
non-empty `GIT_EDITOR`, `VISUAL`, or `EDITOR`, in that order. The program receives
one secure `0600` temporary Markdown file while bbr leaves the alternate screen,
disables mouse reporting, restores cooked mode and echo, and gives the child its
inherited standard streams. Returning changed UTF-8 without NUL bytes replaces
the open Composer body; it does not save or publish anything.

`[external_edit].max_bytes` defaults to `1048576`, must be greater than zero,
and limits only the file returned by the local program. Validation, cancellation,
and launch failures preserve the original Composer body. A terminal restoration
failure is fatal and prints the retained file path.

## Submission and repair

- Each SubmissionRun durably freezes its ordered Draft graph and checkpoints an
  item before the next external effect. Parents are posted before Replies.
- Retryable POSTs use capped local backoff and never run earlier than valid
  Bitbucket `Retry-After` guidance. The effective delay is persisted before the
  wait command. POST and Duplicate-guard attempt budgets are independent.
- An ambiguous POST is never blindly repeated. The Duplicate guard checks for an
  author-owned Comment with the same scope and exact body. Exhausted checks settle
  as `outcome_unknown`, which remains immutable until explicitly repaired.
- Recovery is explicit. A reviewer can resume, link an existing author-owned
  Comment, confirm not published, decide later, or Abandon recovery. Abandonment
  preserves ambiguous evidence and never means the Comment was not published.
- A changed SourceCommit enters the Stale repair gate without a POST. Reload
  privately stages one complete Candidate Session. Review-level roots can resume;
  File-level roots require current scope; new-side inline roots require explicit
  re-anchor; old-side roots require their exact authored span. There is no
  submit-anyway action.
- Selective retry authorizes only one eligible failed Draft subtree and its Reply
  descendants. There is no retry-all action.

## Selection compatibility

`v` is the reliable Selection action. Pinned libvaxis fixtures cover xterm and
Kitty Shift+Arrow encodings, but terminal emulators and multiplexers decide what
bytes they send. Shift+Arrow is therefore terminal-dependent convenience, not a
support guarantee. Record terminal name/version, multiplexer, and keyboard
configuration when manually checking it.

## Verification tiers

The default tier is hermetic:

```sh
zig build test
zig fmt --check build.zig src
```

It includes the scripted terminal-adapter harness, typed completion correlation,
Session-bound versus Durable Operation admission, launch failures, allocation
failure sweeps, transaction fault injection, rollback, recovery, stale repair,
Retry-After fixtures, and pinned vaxis input fixtures. The scripted harness uses
no real network, sleep, terminal, or PTY. Live `429` induction is intentionally
not required.

The PTY tier must run in a real interactive terminal:

```sh
BBR_ALLOW_PTY_SMOKE=1 zig build check-external-edit
```

Its controlled editor verifies inherited streams, cooked mode, echo, and exact
prefilled/returned bytes. The handoff exercises mouse disable/restore,
alternate-screen exit/re-entry, a complete redraw, and then asks for `q` through
the recreated input loop.

The Bitbucket mutation tier is credential-gated and destructive. Use only a
disposable PullRequest:

```sh
BITBUCKET_USERNAME='account@example.com' \
BITBUCKET_TOKEN='...' \
BITBUCKET_WORKSPACE='workspace' \
BBR_ALLOW_LIVE_MUTATION=1 \
zig build check-mutation -- <repo> <pull-request-id>
```

It creates a uniquely marked Review-level Comment, fetches it, verifies stable
identity, author UUID, body, and CommentScope, updates only its body, verifies it
again, deletes it, and accepts either absence or a valid Deleted Comment. Cleanup
is best-effort on every post-create failure. Credential material is never logged.

## Credential-gated checks

Remote checks read these three environment variables:

- `BITBUCKET_USERNAME` contains the Atlassian account email.
- `BITBUCKET_TOKEN` contains the Atlassian API token.
- `BITBUCKET_WORKSPACE` contains the Bitbucket Workspace.

Do not store these values in the repository or type them on a command line. On macOS,
store each value as a generic password with Keychain Access. Then use this launch pattern:

```sh
env \
  BITBUCKET_USERNAME="$(security find-generic-password -w -s '<username-service>' -a '<keychain-account>')" \
  BITBUCKET_TOKEN="$(security find-generic-password -w -s '<token-service>' -a '<keychain-account>')" \
  BITBUCKET_WORKSPACE="$(security find-generic-password -w -s '<workspace-service>' -a '<keychain-account>')" \
  zig build check -- <repository> <pull-request-id>
```

Replace only the placeholders. Do not enable shell tracing for this command. Shell tracing can
print the values after command substitution.

## Proxy behavior

`StdHttpClient` reads `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` through
`initDefaultProxies`. It also reads their lowercase forms. bbr has no proxy setting.

An invalid proxy URL stops startup. Unsupported proxy schemes and non-empty `NO_PROXY` or
`no_proxy` values also stop startup. bbr does not retry through a direct connection.

## CI and live checks

Required CI receives no Credential. It runs only the hermetic suite and native build checks.
Direct connectivity, blob, Comment mutation, Reviewer Verdict mutation, and all other live
checks remain explicit local opt-ins. GitHub Actions does not run these checks.
