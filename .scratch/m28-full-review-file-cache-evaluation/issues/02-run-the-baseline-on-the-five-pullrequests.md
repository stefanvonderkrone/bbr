# 02: Run the footprint benchmark on the largest PullRequest

Status: resolved
Blocked by: 01
Spec: [M28 spec](../SPEC.md)

## What to build

A human runs scenario S1 of the benchmark from ticket 01 once on PullRequest A in `pr-webapp`.
This run is the footprint run.
It needs the operator's Credential and live network access.

The run measures only the current LRU with its default budget of 256 MiB.
S1 reads every File once and reports `full_review_bytes`, the memory that a full Review needs.
Ticket 03 applies the footprint rule of the spec to that number.

## Method change on 2026-11-02

The operator replaced the full baseline with the footprint run on 2026-11-02.
The full baseline was two runs of S1 to S8 on five PullRequests, on different days and networks.
Each run took 15 to 50 hours, and the operator judged that cost too high.
The section "Method change on 2026-11-02" of the [M28 spec](../SPEC.md) gives the reason.

The run guide of the full baseline is obsolete, so this ticket no longer holds it.
The duration tables and the two-run plan are obsolete too.
The Git history of this file keeps the old guide.
Use it only if the footprint rule decides nothing and the full baseline runs again.

## Run guide

Run every command from the root of a clean checkout.
The header key `bbr_version` must not end with `.dirty`.

1. Run `bbr auth status`. It must exit with `0`.
   The Credential must select the `pr-webapp` Workspace.
2. Make an output directory outside the repository, such as `mkdir -p ~/m28-runs`.
3. Build and install the harness with `zig build install-bench-file-cache`.
4. Run S1 on PullRequest A. Read its id from the local file `pullrequests.txt`, outside the repository.

```sh
zig-out/bin/bbr-file-cache-bench remote pr-webapp <pull-request> --scenarios s1 \
  --run-label footprint --network-label <network> --output-dir ~/m28-runs
```

The run keeps the defaults `--cache-max-bytes 268435456` and `--dwell-ms 1000`.
It prints one `header` line, one `scenario=s1` line, and one `check` line.
A `failures` value above `0` makes the result invalid. Run it again.
Record the `header` line without the PullRequest id and the File count under `## Completion`.
Also record the `scenario=s1` line and the `check` line.
Do not copy the checkpoint file into the repository, because its name holds the PullRequest id.

## Acceptance criteria

- [x] One run of S1 on PullRequest A with the default budget exists.
- [x] The run records its date, network label, and bbr commit.
- [x] The header shows the state, the File count, and `probe_ms`.
- [x] For the merged PullRequest A, the `not_found` side count and the Hunk mismatch File count are zero.
- [x] The result has `failures=0`.
- [x] The recorded output holds no PullRequest id, File count, source text, File path, query text, Comment text, or URL.

## Completion

The operator's agent ran the footprint run on 2026-11-02, from 17:45 to 18:00 CET.

- Network label: `home-office-vpn-wired`.
- bbr version: `2026.11.2-0+ge5d60b6f8b3d`.
- Command: `bbr-file-cache-bench remote pr-webapp <PullRequest A> --scenarios s1 --run-label footprint --network-label home-office-vpn-wired`, with an output directory outside the repository.
- Options: the default budget of 256 MiB and the default dwell time of 1,000 ms.

Header, without the PullRequest id and the File count:

```text
state=MERGED range_files=26 session_requests=4 probe_ms=590.9 cols=200 rows=50
```

Result, with only the keys that the decision needs: bytes, requests, and latency.
The keys that count Files or File Jumps stay in the local run files, because they show the File count.

```text
scenario=s1 refetches=0 latency_median_ms=350.7 latency_p95_ms=1469.3 added_delay_p95_ms=0.0 requests=663 failures=0 rate_limited=0 request_median_ms=312.3 request_p95_ms=473.2 retries=6 peak_retained_bytes=35373616 retained_bytes=35373616 full_review_bytes=35373616 peak_rss_bytes=855785472 cache_hit_rate=1.000 low_samples=true
```

Check:

```text
not_found_sides=0 hunk_mismatch_files=0
```

The 6 retries were `HttpConnectionClosing` errors.
Each one succeeded on its first retry.
The raw run files stay in a local folder outside the repository, because their names hold the PullRequest id.
The File count of PullRequest A stays in those files too.

Derived facts:

- The full Review needs 35,373,616 bytes, which is 33.7 MiB and 13% of the 256 MiB budget.
- `peak_retained_bytes` equals `full_review_bytes`, so the LRU evicted no File during S1.
- A cold full fetch of PullRequest A costs 663 requests.
  That number is below the Bitbucket limit of 1,000 requests for each user in a rolling hour.
- `range_files` is 26, not the planning value 5.
- `low_samples=true` because S1 had no refetch sample. With no eviction, no refetch was possible.
- `peak_rss_bytes` is 855,785,472 bytes, which is 816 MiB.
  The File cache explains at most 33.7 MiB of it.
  [Ticket 05](05-explain-the-peak-rss-of-the-footprint-run.md) asks for a measurement.

Changed paths: this ticket and [the M28 spec](../SPEC.md).
No code changed.

## Comments

2026-11-01: Review finding M28-12. `tools/m28-baseline-run.sh` retried every failure 6 times with 15-minute waits.
A permanent failure, such as `CheckpointMismatch` or `MissingCredential`, used about 75 minutes before the script stopped.
The harness now classifies each error in `failureOf` in `src/benchmark/file_cache.zig`.
It exits with code `3` for a permanent failure and with code `1` for a transient failure.
`zig build` cannot pass the child exit code through.
The installed build runner ends with `process.exit(code)`, and `code` is only 0, 1, or 2.
See `lib/zig/compiler/build_runner.zig` lines 974 to 980 of Zig 0.16.0.
So the script now runs `zig build install-bench-file-cache` once and then runs `zig-out/bin/bbr-file-cache-bench`.
It stops at once on exit code `3`.
Nobody executed the changed script, because the M28 rest work bans every run of it, also with a stubbed `zig`.
`sh -n` and `shellcheck` pass, and a review read checks the exit code paths.
`zig build test` runs the real binary with `summarize` and no files, and it expects exit code `3`.

2026-11-01: Review finding M28-10. `zig build test` compiled no benchmark executable, so CI missed a compile error in a benchmark root.
A compile error in `src/benchmark_file_cache.zig` passed `zig build test` before the change.
After the change, `zig build test` failed with `compile exe bbr-file-cache-bench ReleaseFast ... 1 errors`.
The test step now depends on the compile steps of `bbr-bench`, `bbr-file-acquisition-bench`, `bbr-buffer-search-bench`, and `bbr-file-cache-bench`.

2026-11-01: The formulas in "Expected duration" match `Scenario.requestEstimate`.
The upper bound 16F + 778W + 8L + 5 agrees with the code for W = 5 and L = 4.
For example, F = 100 gives 1,600 + 3,890 + 32 + 5 = 5,527 requests.
No way exists to measure W or L without Bitbucket. "Plan the runs" gives the reason and the cheapest live way.

2026-11-01: Review finding M28-7. No baseline and no ADR exist, and no agent can make them.
This ticket needs the live runs by a human. Ticket 03 then decides, and ticket 04 then writes the ADR.
The `Blocked by:` lines agree: 02 is blocked by 01, 03 by 02, and 04 by 03.
The pull request of the M28 branch claims only ticket 01.

2026-11-01: Review finding M28-13. Private PullRequest metadata is in the repository.
`.scratch/m28-full-review-file-cache-evaluation/brief.md` listed the PullRequest numbers and their statistics.
The statistics were File counts, binary File counts, changed lines, diff sizes, and the count of the user's PullRequests.
The "Benchmark PullRequests" table of the SPEC, the duration table of this ticket, and `tools/m28-baseline-run.sh` also name the PullRequests or their File counts.
Evidence from local Git only, with no fetch:

- Commit `78a54b9` added `brief.md`. `git branch -r --contains 78a54b9` shows `origin/m28-full-review-file-cache-evaluation`.
- `origin/m28-full-review-file-cache-evaluation` is at `53c08e4`, and that commit has the brief table and the SPEC table.
- `git branch -r --contains 5b385b7` shows no branch, so the local remote-tracking refs do not show that commit as pushed.
  These refs can be out of date.

So the data is already in the pushed history.
A change at the branch tip does not remove it from that history.
A history rewrite and a force push need the operator, so this work changes no file content.
The operator can choose one of these options:

1. Keep the data, because it holds no source text, File path, or Comment text.
2. Remove the data at the tip only. The pushed history keeps it.
3. Rewrite the branch history to remove the data, and force push. Every clone of the branch must reset.

2026-11-01: Out of scope for M28, recorded only:

- X-2: the Credential transport on `main` needs its own review.
- X-3: the decoders of untrusted Bitbucket data need their own review.

2026-11-01: `zig build test` under the hermetic environment of the M28 rest work fails one step, `tests/version_identity_test.sh`.
That test fetches Zig dependencies over the network, and the environment blocks the network.
The log shows `ConnectionRefused` for the dependency URLs.
Every other step passes. So the failure comes from the environment, not from these changes.

2026-11-02: Resolution of review finding M28-13. The operator chose option 3.
The PullRequest ids moved to the local file `pullrequests.txt` in the folder that holds the repository checkout, outside the repository.
The selection table with its statistics moved to the local file `pullrequests-selection.md` in the same folder.
The brief, the SPEC, and this ticket now name the PullRequests only as PullRequest A to PullRequest E.
They keep the selection rule and the duration formulas, but no id and no per-PullRequest number.
On 2026-11-02, an agent rewrote the branch history and force pushed the branch.
Every commit after `origin/main` got the same scrub. The commits of `main` kept their hashes.
`tools/m28-baseline-run.sh` now reads the ids from the local file and checks the file before the build.
`tests/m28_baseline_run_test.py` runs a copy of the script with a stub `zig` and no network.
It checks a missing, empty, and malformed file, and `zig build test` runs it.
`tools/check_agent_docs.py` now fails on a PullRequest id in `.scratch/` prose outside inline code.
It also fails on an id after `pr-webapp` or in a `remote` command, also in code.

2026-11-02: S4 alone ran on PullRequest A from 19:28 to 21:32 CET. The cold Review Search did not complete, and the operator stopped it. [The Review Search bug](../../review-search-cold-projection/issues/01-a-cold-review-search-on-a-large-review-never-completes.md) records the evidence. ADR-0016 records the effect on the decision.
