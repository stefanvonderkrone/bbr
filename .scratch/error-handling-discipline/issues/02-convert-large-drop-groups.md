# Convert the large drop groups

Status: resolved
Type: implementation
Blocked by: 01
Parent: ../PRD.md

## Goal

Convert the large groups of cause-dropping `catch` sites to the sanctioned form of issue 01, or to a helper that holds it.
The baseline in `tools/diagnostic_catch_baseline.txt` then falls from 391 to fewer than 100 sites.
The remaining sites are the real review list.

## Groups

The counts come from research.md, section "Implications for bbr", proposal 2.

| Group | Sites | Proposed form |
| --- | --- | --- |
| `allocPrint(scratch, …) catch "label"` in `src/tui/render.zig` | 64 of 92 | One helper, for example `labelOr(scratch, fmt, args, fallback)`, that holds the one `OutOfMemory` switch. |
| `catch { self.action_error = .out_of_memory; … }` in `src/tui/presentation.zig` | 47 of 125 | The named `OutOfMemory` switch. Optionally also call `reportFailure` with `error.OutOfMemory`. |
| `catch return error.X` translations across `src/` | 91 | `catch \|err\| switch (err) { error.Overflow, error.InvalidCharacter => return error.InvalidNumber }`. |
| `bufPrint(&buf, …) catch unreachable` | 13 | `catch \|err\| switch (err) { error.NoSpaceLeft => unreachable }`, with an assertion or a comment on the buffer size. |
| `catch {}` | 21 | Review each site by hand. Keep a drop only for cleanup or best-effort output. |

## Work

1. Convert one group per commit. Lower the baseline in the same commit.
2. For each remaining site, check that the handler leaves a valid state. Yuan et al. found that empty and log-only handlers caused 25% of catastrophic failures. A record through a `diagnostics.Handle` alone does not make a drop correct.
3. List the residue in this issue under `## Comments`, with one line per site and its reason.

## Decide before resolution

- Open question 1 of the PRD: is `error.OutOfMemory` in a render path an expected outcome or a failure to record?
- Open question 2 of the PRD: does a log-only `catch` count as a drop?

## Acceptance

- `zig build test` passes after each commit.
- The baseline is below 100 sites.
- Each remaining site has a reason in this issue.

## Resolution

Open question 1 of the PRD: `error.OutOfMemory` in a render path is an expected outcome.
The frame still paints a fallback label, and a record would repeat on every frame.
The handler names `error.OutOfMemory` in its own prong and records nothing.
`formatLabel` in `src/tui/render.zig` holds that switch for the per-frame labels.

Open question 2 of the PRD: a log-only `catch` that records its cause is not a drop for the ratchet.
The ratchet counts causes that no code records.
A recorded cause does not make the handler correct, so the residue review below asks whether each handler leaves a valid state.
Some residue sites record the cause in the callee, where the lint cannot see it, for example `parseJson` and `SqliteStore.native`.

## Completion

The baseline fell from 391 to 70 sites in six commits:

| Commit | Group | Before | After |
| --- | --- | --- | --- |
| `d801b00` | `allocPrint(scratch, ...) catch label` in `src/tui/render.zig`, behind `formatLabel` | 391 | 320 |
| `8c5a32b` | `.out_of_memory` blocks in `src/tui/presentation.zig`, and the codemod | 320 | 250 |
| `87f9add` | `catch return error.X` translations | 250 | 232 |
| `d73bdaa` | `catch unreachable` | 232 | 223 |
| `f3661b0` | value, return, and block fallbacks | 223 | 79 |
| `e27dbc6` | `catch {}`, read by hand, converted by the codemod | 79 | 70 |

[convert_drops.py](../convert_drops.py) is the codemod.
It writes `catch |err| if (false) H else switch (err) {}` for each site, runs `zig build analyze` through [check_build.zig](../check_build.zig), and writes the names from the `unhandled error value` notes as one prong whose body is the old handler `H`.
`check_build.zig` analyzes every unfiltered artifact of `build.zig` with `-fno-emit-bin`: `bbr`, the three benchmark executables, the core, executable, version, and Linux core test binaries, and the grammar CLI integration executable.
The codemod reproduced three hand-converted Presentation sites byte for byte before it converted a group.
`convert_drops.py --verify REV` fails unless each token change since `REV` is a switch opening after a `catch` or its closing brace.
It passed for each codemod commit.
A changed prong body made it fail.
[convert_drops.json](../convert_drops.json) records the names or the revert reason of each site.

The codemod converted 250 sites.
209 name one error, 31 name two, and 10 name three.
It reverted 58 sites: 40 have more than three names, 9 call a function that returns `anyerror`, 5 would shadow an outer `err` capture, and 4 are out-of-memory mislabels.
It skipped 2 chained catches.
No site stayed unanalyzed.
The 10 captured `else` drops were outside the codemod.

The 40 sites over the cap have these set sizes: 21 have four names, 5 have six, 1 has nine, 11 have fourteen, 1 has thirty-nine, and 1 has forty-five.
A cap of four would admit 21 more sites: 11 SQLite ROLLBACK cleanups, 4 UTF-8 reads, 2 URL parses, 3 config key parses, and the CPU count fallback.

Checks: `zig build test` passed with exit 0 before each commit.
`python3 tools/check_diagnostics.py` passed.
No test file changed.
No separate code review ran in this session. `--verify` is the mechanical proof for the five codemod commits, and the `formatLabel` commit only moves each fallback into the call.

## Comments

Residue: each site that still drops its cause, at the line of `e27dbc6`, with its reason.
Each reason says why the handler leaves a valid state, or what a review must check.

Sets with more than three names:

- `src/api/workspaces.zig:116` CpuCountError has four names. An unknown CPU count gives one worker, a valid concurrency.
- `src/benchmark/file_acquisition.zig:71` The credential load has 39 names. The opt-in benchmark stops with MissingCredential, and the operator loses only the cause.
- `src/benchmark/main.zig:499` `std.process.run` has 45 names. The benchmark reports the host CPU as "unknown".
- `src/bitbucket/auth.zig:514` `setPermissions` has nine names. A visible warning names the directory, and the directory stays usable.
- `src/bitbucket/auth.zig:571` `setFilePermissions` has 14 names. A visible warning names the file, and the saved file stays.
- `src/bitbucket/client.zig:69` The error envelope parse has 14 names. ErrorDetail keeps its reason without a message.
- `src/bitbucket/client.zig:400` `parseJson` records each failure in its `errdefer` and returns MalformedResponse. Finding: OutOfMemory also becomes MalformedResponse, where line 1667 keeps it.
- `src/bitbucket/client.zig:554` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:612` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:1091` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:1167` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:1378` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:1486` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:1539` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/client.zig:1588` The same `parseJson` translation and OutOfMemory finding.
- `src/bitbucket/url.zig:34` `std.Uri.parse` has four names. Each is a malformed URL, and MalformedUrl is the documented parse error.
- `src/logging_config.zig:30` The key parse has four syntax errors. The caller reports the invalid line.
- `src/persist/sqlite_store.zig:346` ROLLBACK in an `errdefer`, with the four SqliteError names. `native` records the SQLite result, and the transaction error propagates. After a failed ROLLBACK, the next `BEGIN IMMEDIATE` fails and is recorded, so no write joins the open transaction.
- `src/persist/sqlite_store.zig:387` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:431` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:564` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:620` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:689` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:833` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:1053` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:1092` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:1188` The same ROLLBACK cleanup.
- `src/persist/sqlite_store.zig:1326` The same ROLLBACK cleanup.
- `src/tui/config.zig:227` The key parse has four syntax errors. The line is not a theme assignment, and the rewrite keeps scanning.
- `src/tui/config.zig:313` The key parse has four syntax errors. The parser records a config diagnostic and skips the line.
- `src/tui/config.zig:324` The string array parse has six syntax errors. The parser records a config diagnostic and skips the line.
- `src/tui/config.zig:368` The string array parse has six syntax errors. The parser records a config diagnostic and skips the line.
- `src/tui/frame.zig:558` `utf8Decode` has four names. An undecodable grapheme is not whitespace.
- `src/tui/render.zig:953` `std.Uri.parse` has four names. The link text stays visible without a hyperlink.
- `src/tui/search.zig:446` `utf8Decode` has four names. `unreachable` holds, because `Utf8View.init` validated the text.
- `src/tui/search.zig:526` `utf8Decode` has four names. `unreachable` relies on the caller of `wordStart` to pass valid UTF-8, because the view is unchecked. A review must confirm each caller.
- `src/tui/search.zig:895` The same unchecked view in `advanceGreedy`. A review must confirm each caller.
- `src/tui/search.zig:984` `utf8CountCodepoints` has six names. `unreachable` relies on valid UTF-8 candidate text and alternatives. A review must confirm the source.
- `src/tui/search.zig:1180` `utf8CountCodepoints` has six names. A display column falls back to 0.
- `src/tui/search.zig:1308` `utf8CountCodepoints` has six names. The authored column falls back to a byte count.

Callees that return `anyerror`:

- `src/git/client.zig:250` `git config` for the branch remote. The lookup falls back to the remote "origin".
- `src/git/client.zig:336` The same remote lookup and fallback.
- `src/git/client.zig:348` `git config --get-regexp` exits 1 when no key exists. The client uses no URL rewrites.
- `src/main.zig:605` A failed Session load records and counts itself, so the acquisition gate fails. A failed setup step, such as the proxy setup, records through the `errdefer` but does not count, and its 0 ms sample enters the medians. A review must check that case.
- `src/main.zig:606` The same check for the bounded sample.
- `src/review/anchor.zig:116` A failed `git diff` caches the transition as unavailable. The Anchor shows as unavailable.
- `src/review/anchor.zig:137` The same transition cache.
- `src/tui/presentation.zig:4300` The scope resolver failure gives an unavailable scope.
- `src/tui/presentation.zig:4302` The legacy anchor resolver failure gives an unavailable scope.

A nested catch that would shadow the outer `err` capture:

- `src/bitbucket/auth.zig:504` `setPermissions` after the directory is created. A visible warning names the directory.
- `src/highlight/tree_sitter_highlighter.zig:85` The built-in fallback after a recorded UserGrammar failure. The file shows without spans.
- `src/highlight/tree_sitter_highlighter.zig:90` The same fallback after a recorded highlight failure.
- `src/tui/file_enrichment.zig:39` The retry backoff sleep. A canceled sleep starts the retry at once. Issue 04 must decide whether cancelation stops the retry.
- `src/tui/file_enrichment.zig:267` Both sides failed. The new side's await failure returns OutOfMemory in place of the old side's `err`. A review must check that the old cause is recorded first.

Chained catches:

- `src/http/std_client.zig:172` The first catch retries the proxy value with the scheme "http". The configuration stays valid.
- `src/http/std_client.zig:172` The second catch rejects a value that neither parse accepts with InvalidProxyConfiguration.

Out-of-memory mislabels, which are findings:

- `src/tui/presentation.zig:7064` `SubmissionTree.createPersisted` can also fail with DraftNotFound. The handler reports out of memory.
- `src/tui/presentation.zig:8485` `ScanReviewSource.create` can also fail with InvalidUtf8, LineEnding, Nul, and TooLong. The handler reports out of memory.
- `src/tui/presentation.zig:10211` `queueBufferSearchOpening` can fail with the same four text errors. The handler reports out of memory.
- `src/tui/presentation.zig:10995` `DurableSubmission.retryPost` can also fail with DraftNotFound and InvalidSubmissionState. The handler reports out of memory.

Captured `else` drops from issue 01:

- `src/bitbucket/client.zig:122` The handler records the HTTP status, and `else` classifies the remaining statuses as other.
- `src/review/draft.zig:137` `else` maps AnchorRangeDescending and AnchorSideAmbiguous to InvalidDraftScope. The two names could replace the `else`.
- `src/tui/config.zig:153` Finding: `else` reports a config read failure as WriteFailed.
- `src/tui/config.zig:169` `else` maps a failed atomic write to WriteFailed. The caller reports the failed write without the cause.
- `src/tui/config.zig:521` `else` gives a generic Keymap message in a config diagnostic.
- `src/tui/presentation.zig:4843` `else` maps a scan failure to SearchFailed.
- `src/tui/presentation.zig:4876` The same SearchFailed mapping.
- `src/tui/presentation.zig:9099` `else` maps a query failure to the invalid query action error.
- `src/tui/presentation.zig:11574` `else` maps a span failure to the invalid selection action error.
- `src/tui/presentation.zig:13346` Finding: `else` maps AnchorRangeDescending and AnchorSideAmbiguous to MixedSides.

Follow-ups outside this issue:

- A `decodeJson` helper that records the cause and returns MalformedResponse would remove the nine `parseJson` drops and settle the OutOfMemory finding.
- `src/tui/app.zig` has 22 `allocPrint(frame, ...)` status labels in the checked switch form. A helper like `formatLabel` would hold their switch once.
- Three converted sites translate an error to itself: two `error.OutOfMemory => return error.OutOfMemory` in `src/tui/file_enrichment.zig` and `error.InvalidUtf8 => return error.InvalidUtf8` in `src/tui/search.zig`. Each is `try`.
- `src/benchmark/file_acquisition.zig` translates a canceled sleep to SleepFailed. Issue 04 covers Canceled prongs.
