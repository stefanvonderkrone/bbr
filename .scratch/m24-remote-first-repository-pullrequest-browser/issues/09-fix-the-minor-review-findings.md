# 09: Fix the minor review findings

Status: resolved
Blocked by: 08
Spec: [M24 spec](../SPEC.md)

## What to build

This round fixes the minor M24 findings of the all-branches review.
It also fixes two new findings from the ticket 08 review.
It fixes the M24 parts of the cross-branch findings X-5 and X-6.
The base is `5406fc9`. `origin/main` stayed at `497c86f`, so no new merge was necessary.

## Acceptance criteria

- [x] A failing test precedes each behavior fix in the history.
- [x] A mutation proves each test-only fix.
- [x] Every M24 rule row in AGENTS.md names a check that fails, or says "Convention (no check)".
- [x] `zig build test`, `zig build test-browser`, `zig fmt --check build.zig src tests`, and `python3 tools/check_agent_docs.py` pass.

## Completion

### Chosen load: a Refresh replaced the PullRequest that the reviewer chose

Failing test: `0138d05`. Fix: `d3c1f34`.
The stale repair key `R` called `queueRefresh` during a chosen load.
The Refresh removed the queued load or replaced the load in flight.
`queueRefresh` now returns when the replacement has the cause `.picker` or `.browser`.
The chosen Session replaces the published Session anyway.
The `refresh` Action already did nothing during a replacement.
`queueReconciliation` stays unchanged, because each caller checks the replacement first.
A guard in `queueReconciliation` could not run.
It could also leave a durable lane that waits forever.
The tests "M24 browser a stale repair reload keeps the PullRequest the reviewer chose" and "M24 browser a settled Reviewer Verdict keeps the PullRequest the reviewer chose" cover a queued load and a load in flight.
A mutation of the Reviewer Verdict caller check fails the second test.

### M24-11: no Browser after a failed first load

Failing test: `e0e230e`. Fix: `b4e4af1`.
A failed replacement kept no key, so `openBrowser` with no Session refused.
`Presentation.failed_replacement_key` now holds the key of the last failed replacement.
`failReplacement` sets it at all four failure sites.
With no Session, `open_browser` uses that key as the Browser Start.
With no key, the refusal stays.
Presentation has no Credential Workspace, so the fix uses only the failed key.
The test is "M24 browser b after a failed first load starts the Browser on the failed PullRequest".
Before the fix, it failed with `expected null, found .action_refused`.
Open: `b` during a first load that is still in flight still refuses.

### Selection index after a failed rebuild

Failing test: `03842b5`. Fix: `b83be35`.
A failed rebuild cleared `cursor_index`, so a lost Selection then went to row 0.
`Browser.fallback_row` now keeps the row of the failed rebuild.
The next successful rebuild uses it and clears it.
No field indexes past the Entries, so the M24-2 guarantee holds.
The test is "M24 browser a lost Selection after a failed rebuild lands on the row at the same index".
Before the fix, it failed with `expected 2, found 0`.

### M24-9: cached PullRequest rows looked confirmed

Failing test: `f1b0d1e`. Fix: `03b2759`.
`render.drawBrowser` now paints a PullRequest row dim when its Repository has a `cached` load.
Decision: the row stays dim for the whole `cached` state, not only while the request runs.
This matches the SPEC rule for the dim count.
Bitbucket did not confirm a `cached` list yet.
The test is "M24 cache cached PullRequest rows paint dim while their refresh runs and loaded rows paint normal".
The SPEC names only the dim count. This ticket records the dim rows as an addition.

### M24-7: no test sent `not_found`

Commit: `f2cea9f`.
The test "M24 browser one failed Repository keeps the others, and only forbidden and not_found drop the previous list" now also fails a loaded Repository with `error.NotFound`.
Mutation: `dropsPrevious` with `Forbidden` only. The test failed with `expected len: 0, found len: 1`.

### M24-6: no test guarded the 0600 mode

Commit: `cacd4c6`.
The test now sets the file to mode 0644 before the second save, and it expects 0600.
`createFileAtomic` with `.replace = true` always creates a new file with the given mode.
So the last `setFilePermissions` call changed nothing.
With the call deleted and a 0644 file, all tests passed.
We deleted the dead call and its comment.
Mutation: `createFileAtomic` with mode 0644. The test failed with `expected 384, found 420`.

### M24-8: a raw slug went into the request path

Failing test: `1e7941a`. Fix: `75e5bb8`.
About 25 URL builders in `src/bitbucket/client.zig` formatted the Workspace or the slug with `{s}`.
The detected slug also reached `getPullRequest`, so a fix of only the list was not enough.
`appendPath` and `pathUrl` now percent-encode each segment and refuse `.` and `..`.
`repositoryEndpoint` takes a `comptime` suffix format.
An empty slug now gives `BadRequest` instead of a `//` path.
The test is "Repository paths percent-encode the Workspace and the Repository slug and refuse dot segments".
`cd092b4` adds `tools/check_bitbucket_paths.py`, and `zig build test` runs it.
The check found one more raw URL, `workspaceMembersEndpoint`, and the commit fixes it.
On the pre-fix `client.zig`, the check reported 30 violations and exited 1.

### M24-12: one account saw the Summary Cache of another

Failing test: `237d33a`. Fix: `abda173`.
The Summary Cache now stores an `account` field.
The value is the SHA-256 hex digest of the Credential email.
The file holds no email and no token.
The file `version` is now 2, so bbr rebuilds a version 1 file.
`decode` returns null for another account.
The test is "M24 cache a Summary Cache saved for one account is empty for another account in the same Workspace".
The SPEC JSON example still shows version 1 with no `account`.
The SPEC decision of one file for one Workspace stays.

### M24-13: the detect test did not prove "no network"

Commit: `3110b20`.
The named Repository case in `tests/detect_cli_test.py` now asserts that `reason:` is absent.
Mutation: `startup.inspect` used the branch "main" after a Git failure. Only the new assertion failed.

### X-5 and X-6: M24 rule rows and weak tests

Commits: `fbb4a02`, `eed9fba`, `b8b1a14`.
A helper ran one mutation for each sentence of each M24 rule row.
It also ran one mutation for each guard of this round.
Three mutations survived:

- A failed replacement that reset the Sort or the scroll. `fbb4a02` extends two tests, and the row names the new test names.
- A `work_id` on the Summary Cache commands. The row marks that sentence as a convention.
- A copy of the detection logic outside `src/startup.zig`. The Startup Detection row is now "Convention (no check)".

The FIFO row and the Summary Cache row now name the tests that kill their mutations.
`b8b1a14` adds the chosen load rule.
`cd092b4` adds the Bitbucket URL rule.

### Out of scope

- M24-3 and X-2: the Credential follows a `next` link or a redirect to any host. That is main's HTTP client, and it gets its own ticket.
- X-3: untrusted bytes reach decoders that panic.

### Review

The runner read each helper diff before it took the commits.
It checked that each `queueReconciliation` caller tests `self.replacement`.

### Checks

All checks ran with HOME, the XDG directories, and the proxies set to paths under `$TMPDIR`.

- `zig build test --summary all`: 26/26 steps succeeded, 1491/1491 tests passed, in eight runs.
- `zig build test-browser --summary all`: 9/9 steps succeeded, 83/83 tests passed.
- `zig fmt --check build.zig src tests`: exit 0.
- `python3 tools/check_agent_docs.py`: "Agent documents and tracker metadata pass."

A helper saw one failed `zig build test` run and did not keep the output.
Eight later runs passed. The cause is unknown.
