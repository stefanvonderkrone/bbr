# Keep the leaf evidence in the one record

Status: resolved
Type: implementation
Blocked by: 06
Parent: ../PRD.md

## Goal

Issue 06 gives each failure one record.
The HTTP transport, the Bitbucket client, and the Git client record nothing, so the record is written at the boundary and names the typed error that reached it.
Some evidence exists only at the leaf, and it no longer reaches the diagnostic file.
Carry that evidence to the one record without a second record.
Do not add a second record at the leaf, and do not add a side channel that records apart from the boundary.

## Evidence that the record lost

- The JSON parse error behind `error.MalformedResponse`. `parseJson` and the decode sites in `src/bitbucket/client.zig` return `MalformedResponse` and drop the parser error. `Client.ErrorDetail` already reaches the CLI boundary and each page slot of `PagedLists` (`Slot.fetch` and `Slot.fetchPage` in `src/bitbucket/client.zig`), so it can carry the cause to the CLI. The TUI workers have no ErrorDetail.
- The HTTP phase of a transport failure, such as `connect` or `receive_head`. Commit `a01a43a` removed the phase tracking from `StdHttpClient.send` with its errdefer record.
- The exact HTTP status of a rejection. `classify` maps all 5xx to `ServerError` and every unknown status to `UnexpectedStatus`. Commit `941ef9e` removed the rejection record in `Client.send` that held the status and classification. `diagnostic.Cause.http` has no producer now.
- The page number of a failed page. `Slot.fetch` sets `context.page` on the client handle, but the client records nothing, so the boundary record of a transport, `MalformedResponse`, or rejection failure on a page has no page. Before `941ef9e`, the rejection record of `Client.send` kept the page. `PagedLists.deinit` keeps the page only for a failed page that the caller does not receive.
- The Git exit code and stderr behind `UnknownRef`, `NotAGitRepo`, and the other `on_fail` names. `runRaw` in `src/git/client.zig` maps a nonzero exit, a signal, and a launch error to `on_fail` and drops the termination and stderr. `diagnostic.Cause.git` exists and has a producer: the External Edit adapter (`src/tui/presentation_adapter.zig`, the `.git` cause of a failed editor exit).

## Work

1. Choose a carrier for each item that reaches the boundary with the error, for example an extended `Client.ErrorDetail`, a typed result, or a Git failure value.
2. Teach each boundary that records the typed error to record the carried evidence in the same record.
3. Keep the record free of bodies, headers, URLs, paths, and stderr text. Record numbers and closed enums only.

## Acceptance

- Each listed item reaches the one record of its failure, or the issue says why an item stays lost.
- A test reads exactly one record that holds the evidence for each item that reaches it.
- `zig build test` passes, and the record baseline lists no file.

## Design

### Carrier

The evidence travels in a slot that the boundary owns, and the `diagnostics.Handle` points to it.

- `diagnostic.Leaf` in `src/diagnostic.zig` holds the typed error that it explains, an optional Phase, an optional page, and an optional Cause.
  It holds only Zig errors, closed enums, and integers, so `assertSafe` covers it.
- `Handle.leaf` is an optional pointer to a `?Leaf` slot.
  `Handle.withLeaf(&slot)` sets it, and `forContext` keeps it.
  `Sink.handle` makes a handle without a slot.
- A client calls `Handle.note(leaf)`. `note` writes the slot and records nothing.
  It fills the page from the handle context when the leaf has none.
- `Handle.record` is the only way to the Sink.
  When the Failure's cause is the Zig error that the slot explains, `record` puts the leaf Phase, page, and Cause into that one record and empties the slot.
  A record of another error does not take the evidence.

So every boundary that records through a handle with the slot gets the evidence, and no boundary can forget it.
The CLI root handle in `main` owns one slot. `bbr api` and the other CLI commands derive their handles from it.
A boundary frame owns the slot, so the slot lives until the boundary records.

A slot is not safe for two concurrent writers.
The TUI root handle has no slot. Each worker owns one slot in its `PresentationSinkContext`.
Each concurrent fan-out of one client gives each task its own slot and moves the slot of the failure that it returns to the parent slot:
the `PagedLists` page slots, the `session.loadWith` branches, and the File Enrichment sides.

The record shows the evidence in the existing fields:

| Evidence | Record |
| --- | --- |
| HTTP rejection | `phase=rejection cause=http status=503 classification=server`. The classification names the `ApiError`. |
| Transport failure | The phase, such as `phase=connect`, and `cause=zig error=ConnectionRefused`. |
| JSON parse error | `phase=decode cause=zig error=UnexpectedEndOfInput`. The `decode` phase marks `MalformedResponse`. |
| Failed page | `page=3` in the context. |
| Git termination | `phase=execute cause=git termination=exited code=128 error=UnknownRef`. `Cause.git` gains the optional typed error, so the record keeps the `on_fail` name. A launch error has `phase=launch` and keeps its own Zig error. |

The HTTP seam gets the phase out through `Request.phase`, an optional pointer that `Client.send` sets and `StdHttpClient.send` advances.

### Rejected shapes

- An extended `Client.ErrorDetail`. It reaches the CLI boundary and the `PagedLists` page slots, but the TUI workers have none, and the Git client has none.
  Each boundary would merge the evidence by hand, so a boundary that forgets the merge records the typed error without the evidence.
  ErrorDetail also carries an allocator and the API message for stderr, which a worker does not need.
- A typed result union from each client method, such as `union { ok: T, failed: Failure }`.
  It makes the evidence impossible to drop, but it changes every client method and every caller that uses `try` on a client error.
  It is the largest change for the same record.
- An out-parameter on each client call. It changes every method signature, and each boundary still merges by hand.
- A thread-local slot. A worker can move between threads under an evented `Io`, and the state is hidden from the reader.

### Items

Each item has its own commit, a test that reads exactly one record with the evidence, and a red run before the change.

## Completion

Commits on `feat/leaf-evidence`:

| Commit | Evidence | Where it lands | Test, red before the change |
| --- | --- | --- | --- |
| `bb22690` | Carrier, HTTP status and classification | `Client.send` notes `phase=rejection` and `cause=http`. | "diagnostics the api boundary record holds the leaf evidence of a Bitbucket failure" (CLI), the two worker tests in `src/tui/presentation_runtime.zig`, and "diagnostics a boundary record takes the leaf evidence of its own error once". |
| `01a6e3a` | Transport phase | `Request.phase`, written by `StdHttpClient.send`. `Client.send` notes it. | `tests/record_once_cli_test.py` (`phase=connect` for `bbr api whoami` and `bbr auth status`), and the worker tests (`receive_head`, `send_body`). |
| `2c8dbf0` | JSON parse error | `jsonFailure` notes `phase=decode` with the parser error. | The CLI test (`UnexpectedEndOfInput`, `UnexpectedToken`) and the worker Picker test. |
| `5fabe2b` | Page number, and one writer for each slot | `PagedLists` page slots, `listPages` page numbers, `session.loadWith` branch slots, File Enrichment side slots. | "diagnostics a failed PullRequest page fails the list and its one record names the page" (pages 2 and 3 with their own status), the worker Picker test (`page=2`), and the session branch test. |
| `42c738c` | Git termination and launch phase | `ShellGitClient.diagnostic`. `runRaw` notes `phase=launch` or `cause=git` with the `on_fail` name. | `tests/record_once_cli_test.py` (`UnknownRef`, `NotAGitRepo`, code 128), `tests/git_launch_cli_test.py` (`phase=launch`), and "diagnostics a failed local git command keeps its termination in the worker record". |
| `99261c0` | Review fix: the verdict mutation keeps its own evidence | The mutation notes into its own slot. Its record takes that slot, and a result that names the mutation's error moves the slot to the caller. | "diagnostics each Reviewer Verdict request keeps its own status in the record of its error" (mutation 503 and reconciliation 502 keep their own status). |
| `5dd0085` | Review fix: a File side's transport OutOfMemory | Each side task notes into a slot that `enrichFromConcurrent` owns, and the join moves the slot of the returned failure with `Handle.adopt`. The enrichment worker gives the request and the client its own slot. | "diagnostics a transport OutOfMemory on one File side keeps its phase in the boundary record" and "... in the worker record" (`phase=receive_body`). |
| `c0c8b9e` | Review fix: a page's transport OutOfMemory | `PagedLists.complete` moves the slot of a page that returns `OutOfMemory`. | "diagnostics a transport OutOfMemory on a PullRequest page keeps its phase and page in the one record" (`phase=receive_head`, `page=2`). |
| `8f105f1` | Review fix: one writer for each slot | Every production task starts through `diagnostics.concurrent` or `diagnostics.selectConcurrent`, which panic in a Debug build when a task argument holds a `Handle` with a slot. `tools/check_task_spawns.py` rejects any other spawn. The Session load of a worker gets its own slot. | The page spawn of `2c8dbf0` panics in the PullRequest page tests. `tests/check_task_spawns_test.py` rejects its line. "diagnostics a task argument holds a slot only through a Handle with a slot". |

Each red run and each green run is in `../decisions-07.tsv`.

Checks at the last commit:

- `zig build test`: exit 0.
- `python3 tools/check_diagnostics.py`: passes. Catch baseline 36, unchanged. Record baseline lists no file.
- `python3 tools/check_error_comparisons.py`: passes.
- `python3 tools/check_task_spawns.py`: passes.
- `python3 tools/check_agent_docs.py`: passes.

User-visible change: none. The stderr messages are the same. Only the diagnostic records gain fields.

Acceptance:

- Each listed item reaches the one record of its failure on the CLI and on the TUI worker path. The exceptions are in Comments.
- A test reads exactly one record that holds the evidence for each item.
- `zig build test` passes, and the record baseline lists no file.

Review: a cross-model review of `bb22690..fa99fdb` found two paths that lost evidence and the unchecked one-writer rule. Commits `99261c0` to `8f105f1` fix them. Each red run is in `../decisions-07.tsv`.

## Comments

Evidence that stays lost, and why:

- A local blob read in File Enrichment. `GitBlobSource` holds a `GitClient` vtable value, and the side's slot cannot reach the `ShellGitClient` of the worker without a handle argument on each vtable function. The record keeps the Git error name.
- A Git Anchor transition. `GitAnchorResolver` records its own Git failures, and its `ShellGitClient` has no slot, because the resolver can run on more than one thread. The record keeps the Git error name.
- A translated error, such as `ReviewerVerdictChangeFailed` on the `bbr api set-verdict` path. The evidence explains the client error, not the translated name, so the record of the translated name does not take it.
- An item decode failure inside a list page, such as a missing field in one PullRequest. The record has the page only when the page goes through `PagedLists`.
- The slot keeps the evidence of the last failure that a client returned. A boundary that records the same error name later, after a handled failure and no other failure, takes that older evidence. No path in bbr does this now.
- One writer for each slot has a check at the task spawn, not at the write. `std.Io` exposes no current task, and an evented `Io` runs many tasks on one thread, so `note` cannot tell two tasks apart. `diagnostics.concurrent` and `diagnostics.selectConcurrent` reject a `Handle` with a slot in the task arguments instead. The check does not follow a pointer, so a `Handle` behind a pointer or a type-erased source, such as the Client in a `BlobSource`, is not checked. The check runs only in a Debug build and only on spawns that a test reaches. The worker Session load has no test that spawns it.
- A fan-out that moves the slot of a task to the wrong parent, or forgets the move, has no check. The behavior tests of each fan-out read the evidence in the record.
- When both sides of a concurrent File Enrichment fail with `OutOfMemory`, the new side's failure has no record. The old side's failure is the one that returns, and it keeps its evidence.

Incident: to show a red run, I ran `git stash` and then dropped `stash@{0}`, which was the operator's stash "On command-palette: build speed". I restored it with `git stash store` from commit `aa9532674a14`. `git stash list` shows it again.
