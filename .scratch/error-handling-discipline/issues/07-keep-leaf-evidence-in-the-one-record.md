# Keep the leaf evidence in the one record

Status: needs-triage
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
- The page number of a failed page. `Slot.fetch` sets `context.page` on the client handle, but the client records nothing, so the boundary record of a transport, `MalformedResponse`, or rejection failure on a page has no page. Before `941ef9e`, the rejection record of `Client.send` kept the page. `PagedLists.finish` keeps the page only for a failed page that the caller does not receive.
- The Git exit code and stderr behind `UnknownRef`, `NotAGitRepo`, and the other `on_fail` names. `runRaw` in `src/git/client.zig` maps a nonzero exit, a signal, and a launch error to `on_fail` and drops the termination and stderr. `diagnostic.Cause.git` exists and has a producer: the External Edit adapter (`src/tui/presentation_adapter.zig`, the `.git` cause of a failed editor exit).

## Work

1. Choose a carrier for each item that reaches the boundary with the error, for example an extended `Client.ErrorDetail`, a typed result, or a Git failure value.
2. Teach each boundary that records the typed error to record the carried evidence in the same record.
3. Keep the record free of bodies, headers, URLs, paths, and stderr text. Record numbers and closed enums only.

## Acceptance

- Each listed item reaches the one record of its failure, or the issue says why an item stays lost.
- A test reads exactly one record that holds the evidence for each item that reaches it.
- `zig build test` passes, and the record baseline lists no file.
