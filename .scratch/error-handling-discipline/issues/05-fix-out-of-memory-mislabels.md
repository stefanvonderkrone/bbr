# Fix the out-of-memory mislabels

Status: resolved
Type: implementation
Blocked by: 02
Parent: ../PRD.md

## Goal

Some handlers report an error as out of memory, or as another wrong error, when the callee can also fail for a different reason.
The user then sees the wrong message, and the diagnostic loses the real cause.
The codemod of issue 02 found these sites and left them unconverted.

## Sites

- `src/tui/presentation.zig:7064` reports out of memory, but `createPersisted` can also fail with `error.DraftNotFound`.
- `src/tui/presentation.zig:8485` `ScanReviewSource.create` reports out of memory for the text errors `InvalidUtf8`, `LineEnding`, `Nul`, and `TooLong`.
- `src/tui/presentation.zig:10211` `search.Query.init` in `retryStaleBufferDisclosure` reports out of memory for those same text errors.
- `src/tui/presentation.zig:10995` reports out of memory, but `retryPost` can also fail with `error.DraftNotFound` and `error.InvalidSubmissionState`.
- Nine `parseJson` call sites in `src/bitbucket/client.zig` turn `error.OutOfMemory` into `error.MalformedResponse`. Line 1667 keeps `error.OutOfMemory`.
- `src/tui/config.zig:153` returns a read failure as `error.WriteFailed`.
- `src/tui/presentation.zig:13346` returns `error.AnchorRangeDescending` as `error.MixedSides`.
- `runRaw` in `src/git/client.zig` returns a Git launch error as the command's `on_fail` name. A missing git binary then shows `NotAGitRepo`, for example `bbr local: cannot determine SourceRef: NotAGitRepo`, and the launch cause has no record. Commit `287a9cc` restored this mapping and raised the catch baseline of `src/git/client.zig` from 3 to 4, because the operator forbade a user text change in issue 06. The fix shows the real launch error, such as `FileNotFound`, and records it once at the boundary. It changes the user text, so it needs the operator's approval.

The line numbers match the checker after commit `d32d9a3`. They did not move from `ee1662a`.

## Work

1. Give each non-OOM error its own prong with the correct user-visible outcome, or record the cause through `reportFailure` or a `diagnostics.Handle`.
2. Use the checked switch form of issue 01. Add no `else` prong.
3. Lower `tools/diagnostic_catch_baseline.txt` in the same commit.

## Acceptance

- `zig build test` passes.
- No listed site reports an error that the callee did not return.

## Completion

Each listed site now returns an error its callee returned. The catch baseline falls from 53 to 37. The record baseline stays empty. `zig build test` passed on each commit. The last run is `a530b16`, 45/45 steps, 1545/1545 tests.

The line numbers in the site list were stale. Each site was found again by its callee.

- Git launch (`060c043`). `runRaw` returns the launch error. A missing git binary prints `bbr local: cannot determine SourceRef: FileNotFound` and the diagnostic file has one `FileNotFound` record. A non-zero git exit still uses the command name, such as `NotAGitRepo`. Catch baseline for `src/git/client.zig` falls from 4 to 3. Test: `tests/git_launch_cli_test.py`. Red log: `issue05-git-launch-red.log`.
- JSON parse (`90dce79`). `jsonFailure` keeps `error.OutOfMemory` and maps each parse error to `error.MalformedResponse`. The nine call sites use that helper. Catch baseline for `src/bitbucket/client.zig` falls from 10 to 1. An allocation failure is no longer `MalformedResponse`, so a CLI message says `out of memory` instead of `invalid response`.
- Theme read (`f96c9f9`). `persistTheme` returns the read error. A directory `config.toml` is `error.IsDir`. The status says `Theme applied, but config.toml could not be read`. A write failure still says `Theme applied, but config.toml could not be written`. The diagnostic record keeps the zig error. Catch baseline for `src/tui/config.zig` falls from 7 to 6. Red log: `issue05-config-read-red.log` (`expected error.IsDir, found error.WriteFailed`).
- Search text (`403e329`). `ScanReviewSource.create` and `retryStaleBufferDisclosure` name `InvalidUtf8`, `LineEnding`, `Nul`, `TooLong`, and `OutOfMemory`. A newline query sets `buffer_search_invalid_query`, whose status text is `Buffer Search Query is invalid`. `TooLong` uses `Buffer Search Query limit is 256 characters`. Out of memory stays `out_of_memory`. Catch baseline for `src/tui/presentation.zig` falls from 9 to 7. Red log: `issue05-search-red.log` (`expected .buffer_search_invalid_query, found .out_of_memory`).
- Submission retry (`8e7d041`). A missing Draft makes the machine skip the post and return `error.InvalidSubmissionState`. The status is `submission_launch_failed`, and the record names `InvalidSubmissionState`. `retryPost` also names `DraftNotFound` as `persistence_failed`. `createPersisted` names `DraftNotFound` as `recovery_claim_failed` and records that cause. The store refuses `beginSubmission` for a Draft it does not hold, so that recovery path has no UI fixture. Catch baseline for `src/tui/presentation.zig` falls from 7 to 5. Red log: `issue05-retry-red.log` (`expected .persistence_failed, found .out_of_memory` on the old binary).
- Descending Anchor (`a530b16`). `reanchorCandidate` returns `error.AnchorRangeDescending` and `error.AnchorSideAmbiguous`. The status for a descending range is `an Anchor range must run forward`. An ambiguous side stays `that source range is ambiguous`. `spanFromLines` does not build a descending range, so this text is latent. Catch baseline for `src/tui/presentation.zig` falls from 5 to 4. Green log: `issue05-anchor-green.log`.

Checker. `tools/check_diagnostics.py` reads source lines. It does not know a callee error set. It already rejects an `else` prong that drops the capture. It cannot tell that a named prong is the wrong name for that callee. An exhaustive switch with no `else` fails to compile when the callee gains an error. That is the check. The checker semantics are unchanged, so `AGENTS.md` is unchanged.

Review. The author reviewed the diffs. No separate review pass was run.
