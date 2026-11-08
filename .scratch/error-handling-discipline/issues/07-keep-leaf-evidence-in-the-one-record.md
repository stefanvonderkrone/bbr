# Keep the leaf evidence in the one record

Status: claimed
Claimed by: feat/leaf-evidence worktree /Volumes/Work/t3-code/error-handling-discipline
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
