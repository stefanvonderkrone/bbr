# 02: Run the baseline on the five PullRequests

Status: ready-for-human
Blocked by: 01
Spec: [M28 spec](../SPEC.md)

## What to build

A human runs the benchmark from ticket 01 on the five PullRequests in `pr-webapp`.
The human runs it twice, on different days and under different network conditions.
This ticket needs the user's Credential and live network access, so an agent cannot run it.

The runs measure only the current LRU with its default budget of 256 MiB.
Do not run any candidate policy in this ticket.

No baseline exists yet. The M28 order is fixed:

1. A human does the live runs of this ticket.
2. Ticket 03 decides on the recorded results.
3. Ticket 04 then writes the ADR with the next free ADR number.

The pull request of the M28 branch claims only ticket 01.
It holds no baseline and no ADR.

## Steps

Before run 1:

1. Read `range_files` and `session_requests` in the `header` line of each PullRequest, as "Plan the runs" describes.
2. Recompute the requests and the time of each PullRequest with the formulas in "Expected duration".
3. Plan the run days with these numbers, not with the table values.

For each run:

1. Prepare the checkout, the Credential, and the output directory, as "Prepare" describes.
2. Pick a run label, such as `run1`, and a network label, such as `office-wired` or `home-vpn`.
   The second run must use a different network condition from the first run.
3. Start `tools/m28-baseline-run.sh` in the background, as "Start a run" describes.
   The script runs PullRequest A to PullRequest E one after another.
4. Watch the progress.
   If the script stops with exit code `1`, run the same start command again to resume it.
   If the script stops with exit code `3`, fix the cause first, as "Resume a run" describes.
5. If a PullRequest result has `failures` above `0`, run that PullRequest again.
6. Copy the checkpoint files of the run into `## Completion` in this ticket.

After both runs:

1. Run the `summarize` mode on the checkpoint files of both runs.
2. Copy its outcome into `## Completion`.
3. If the outcome is `Inconclusive`, do a third run on a third day under a third network condition.
   Then run `summarize` on all three runs.

## Method changes

- S4 starts with a process restart, so its Review Search is cold.
  Before, S4 ran after S1 had admitted every File, so it sent no request, and stop rule 3 could not fire.
  The SPEC records this change as choice 15.
- The request estimate of a scenario is now an upper bound of its requests.
  Each File Jump and each Session load can fetch the whole Enrichment Range, not one File.
  The estimate also counts the requests of each Session load.
  The header prints `range_files` and `session_requests`, and each scenario line prints `request_estimate`.
  The SPEC records this change as choice 16.

## Run guide

Use this guide with the steps above.
Run every command from the root of the checkout.

### Prepare

1. Check out the commit that contains the resume changes in a clean checkout.
   The header key `bbr_version` must not end with `.dirty`.
2. Run `bbr auth status`. It must exit with `0`.
   The benchmark uses the default Profile, as `bbr` does without `--profile`.
   The Workspace comes from the Credential, so the Credential must select the `pr-webapp` Workspace.
3. Make the output directory: `mkdir -p ~/m28-runs`.
4. Record the date, the network label, the machine, and the macOS version.
   Get them with `date +%F`, `sysctl -n hw.model`, and `sw_vers -productVersion`.
5. Do not use `bbr` or another Bitbucket API client during a run.
   Other requests use the same hourly Bitbucket limit, and the request window does not see them.
6. Connect the Mac to power and keep the lid open.
   `caffeinate -i` blocks only idle sleep. A closed lid still puts the Mac to sleep.

### Optional smoke test

This test shows that the Credential and the network work. Do not record its output.
Use the run output directory, so the request window counts the smoke test requests.
The smoke test writes its own checkpoint file, `smoke-<pull-request>-s1.txt`.
The `summarize` command in this guide does not match that file name.

```sh
zig build bench-file-cache -- remote pr-webapp <pull-request> --scenarios s1 --dwell-ms 0 \
  --run-label smoke --network-label smoke --output-dir ~/m28-runs
```

### Plan the runs

Do this once before run 1.
The duration table below uses planning values for W and L that nobody measured.
The `header` line of each PullRequest prints the real values.
The harness prints the header after the Session load and the probe, before S1 starts.
For each PullRequest, run the smoke test command with that PullRequest number:

```sh
zig build bench-file-cache -- remote pr-webapp <pull-request> --scenarios s1 --dwell-ms 0 \
  --run-label smoke --network-label smoke --output-dir ~/m28-runs
```

When the `header` line appears, press Ctrl-C.
The header costs about L + 2W + 5 requests, so the five headers cost much less than the hourly budget.
Read `files`, `range_files`, and `session_requests` from each header.
Put them into the formulas in "Expected duration" as F, W, and L.

You can also read the header of each PullRequest during run 1.
But then the plan is late, because run 1 reaches PullRequest E last.

No way exists to measure W or L without Bitbucket:

- W comes from the Buffer of the loaded Session at the fixed Frame of 200 × 50 cells.
  The Buffer has rows for the Comments of the PullRequest, and only Bitbucket has the Comments.
  A local clone gives the Git diff, but Bitbucket can show another diff, for example for renames and binary Files.
  A harness mode that builds a Session from a local diff is also new code, not a small change.
- L is the requests of one Session load.
  `session.loadWith` sends one request each for the PullRequest, the account, and the raw diff.
  The Comment requests add one request per Comment page.
  Only Bitbucket knows the Comment count, so L needs Bitbucket.

### Start a run

Start the run detached from the terminal:

```sh
caffeinate -i nohup tools/m28-baseline-run.sh run1 office-wired ~/m28-runs > ~/m28-runs/run1.log 2>&1 & echo $! > ~/m28-runs/run1.pid
```

The script takes the run label, the network label, and the output directory.
First it runs `zig build install-bench-file-cache`.
This builds the harness and installs it as `zig-out/bin/bbr-file-cache-bench`.
Then it runs `zig-out/bin/bbr-file-cache-bench remote` for each PullRequest with these values.
The script runs the binary, not `zig build bench-file-cache`, because `zig build` gives every failure exit code `1` or `2`.

The harness exits with one of these codes:

- `0`: the PullRequest is finished.
- `1`: a transient failure. A rerun can succeed, for example after a network outage.
  The script waits 15 minutes and runs the PullRequest again.
  After 6 failed attempts for one PullRequest, the script stops with exit code `1`.
- `3`: a permanent failure. A rerun fails in the same way.
  The script stops at once with exit code `3` and prints `m28: #<pull-request> failed permanently, stop`.

The last log line before that message names the error, for example `error: CheckpointMismatch`.
These errors are permanent:

- A wrong option or an invalid Credential: `InvalidArguments`, `MissingCredential`, `Unauthorized`, `Forbidden`, `NotFound`, `BadRequest`, `Conflict`.
- A Bitbucket response that the harness cannot read: `UnexpectedStatus`, `MalformedResponse`.
- A run file problem: `RunInProgress`, `CheckpointMismatch`, `InvalidCheckpoint`.
- A changed PullRequest: `FileCountChanged`.
- A harness defect: `UnsupportedCommand`, `ScenarioStalled`, `ReviewSearchUnavailable`, `ReplacementFailed`.

These errors are transient: `RetriesExhausted`, `Timeout`, `RateLimited`, `ServerError`, `OutOfMemory`, and every error from the operating system, such as a full disk.

Use the same run label for every PullRequest of one run, for example `run1`, `run2`, and `run3`.
`summarize` groups the lines by the run label.
A label must not contain a space or `=`.

The script keeps the other options at their defaults.
The defaults are `--cache-max-bytes 268435456`, `--dwell-ms 1000`, `--seed 28`, `--query return`, `--second-query const`, and `--hourly-request-budget 900`.

### Watch the progress

- Follow the log with `tail -f ~/m28-runs/run1.log`.
- A `wait reason=` line tells why the harness waits and when it continues.
  `reason=window` is the per-request gate.
  `reason=scenario` waits before a scenario.
  `reason=retry` is a backoff after a failed request.
- Count the finished scenarios with `grep -c '^scenario=' ~/m28-runs/run1-*-all.txt`.
  A finished PullRequest has 8.
- Check that the run is alive with `ps -p "$(cat ~/m28-runs/run1.pid)"`.

### Stop a run

```sh
kill -- -"$(cat ~/m28-runs/run1.pid)"
```

The shell gives the background job its own process group.
This command stops every process of the group: `caffeinate`, the script, and the benchmark.

### Resume a run

After a crash, a kill, a reboot, or exit code `1`, run the same start command again.
After exit code `3`, fix the cause first, then run the same start command again:

- `CheckpointMismatch`: use the options of the first start.
- `RunInProgress`: stop the other harness.
- `MissingCredential`, `Unauthorized`, or `Forbidden`: fix the Credential, as "Prepare" describes.
- `FileCountChanged`: the PullRequest changed during the run.
  Record it under `## Comments`, and set this ticket to `needs-info`.
- A harness defect or another permanent error: record it under `## Comments`, and set this ticket to `needs-info`.

- A finished PullRequest sends no request. The harness prints its stored lines.
- An unfinished PullRequest starts again at its first unfinished segment.
  The selected scenarios among S1 to S6 form one segment. S7 and S8 are one segment each.
- A segment that stops in the middle starts again at its first scenario.
  So a restart repeats the requests of that segment.
- The OS releases the lock on the output directory when the process ends.
- `requests.log` keeps the request window, so the resumed run stays inside the hourly budget.

Use the same run label, network label, and output directory.
A different network label stops the run with `checkpoint mismatch key=network_label`.

### Run one PullRequest again

A checkpoint with a `check` line is finished, and a rerun sends no request for it.
To run a PullRequest again, rename its checkpoint file, for example to `run1-<pull-request>-all.txt.invalid`.
Then run the same start command again.
Do not delete `requests.log`.

### Split a long run

Resume makes a split rarely necessary.
If you must split a run, use exactly these two parts on the same day and network, with the same run label:

```sh
zig build bench-file-cache -- remote pr-webapp <pull-request> --run-label run1 --network-label office-wired \
  --output-dir ~/m28-runs --scenarios s1,s2,s3
zig build bench-file-cache -- remote pr-webapp <pull-request> --run-label run1 --network-label office-wired \
  --output-dir ~/m28-runs --scenarios s4,s5,s6,s7,s8
```

Each part has its own checkpoint file, such as `run1-<pull-request>-s1-s2-s3.txt`.
Add these files to the `summarize` command.
S2 needs S1, and S7 and S8 need S1 or S4, so the harness refuses other splits.
In the second part, S4 starts in a new process, so its fetches are cold fetches, not refetches.
Record each split under `## Completion`.

### Expected duration

These numbers are estimates. Nobody measured them.

The formulas use three values of a PullRequest:

- F is the File count, the header key `files`.
- W is the largest Enrichment Range in Files, the header key `range_files`.
- L is the requests of one Session load, the header key `session_requests`.

The upper bound applies when no File stays in the LRU.
It is the sum of the `request_estimate` values of S1 to S8, plus the start and the probe.
The start sends L + 2W requests, and the probe sends 5 requests.
So the upper bound is 16F + 778W + 8L + 5 requests.

The lower bound applies when every File stays in the LRU:

- S1 sends 2F requests, and S4 sends L + 2F requests.
- S7 and S8 each send 3 × (L + 2 × min(F, 21W)) requests.
- S2, S3, S5, and S6 send no request.
- The start and the probe add L + 2W + 5 requests.

The request window allows 900 requests in one hour.
So the time is the requests divided by 900 requests an hour, plus the dwell time.
The dwell time adds about F + 380 seconds.
Each scenario whose `request_estimate` fits in the budget can also wait up to one hour before it starts.

The table uses the planning values W = 5 and L = 4.
Nobody measured these values for the five PullRequests.
"Plan the runs" tells how to read the real values before run 1.
Recompute the table with them before you plan the run days.
The formulas match `Scenario.requestEstimate` in `src/benchmark/file_cache.zig`, with 3 Session replacements of 20 File Jumps each in S7 and S8.

The rows of this table named the benchmark PullRequests. They are not in the repository.

One run of the five PullRequests sends the sum of the requests of each PullRequest.
It takes the sum of their times, without the waits before scenarios.
A segment restart repeats its requests.
S1 to S6 of the largest PullRequest send most of its requests.
So a crash late in S1 to S6 of the largest PullRequest can add most of its time.

### Read the output

Each PullRequest prints these lines:

- One `header` line with `bbr_version`, `state`, `files`, `range_files`, `session_requests`, `probe_ms`, and the Frame size `cols` and `rows`.
- One `scenario=sN` line for each scenario.
- One `check` line with `not_found_sides` and `hunk_mismatch_files`.

The checkpoint file `~/m28-runs/<run-label>-<pull-request>-all.txt` holds the same lines and one `progress` line.
The checkpoint files are the results of the run.

Look for these values:

- `failures` must be `0` on every scenario line. If not, run that PullRequest again.
- `requests` counts attempts. `rate_limited` counts the attempts with a `429` response. Record the count.
- `range_files` in the header is the largest Enrichment Range in Files at the fixed Frame.
  `session_requests` in the header is the largest number of requests of one Session load.
  The request estimate uses both values.
- `request_estimate` is the upper bound of the requests of the scenario.
  A `requests` value above `request_estimate` means that the estimate failed.
  Then the scenario can wait inside a measured span. Record the scenario and both values under `## Comments`.
- `retries` counts the attempts that the harness retried.
- `paused_ms` is the time in which the harness waited, and the latencies exclude it.
- `paced_samples` counts the Visible Actions with a harness wait in their span.
- `refetches` above `0` in S5 or S6 is a delay.
- `hits`, `cold_fetches`, and `refetches` classify the Visible Actions.
  A File Jump to a File whose fetch is still in flight is a fetch, not a hit.
- `enrichments` counts every File Enrichment of the scenario, also the speculative ones outside a span.
  `enrichment_refetches` counts those for an admitted File, and `speculative_enrichments` counts the speculative ones.
  A File that the prefetch refetched before the File Jump counts as a hit, so `cache_hit_rate` can be high while `enrichment_refetches` is high too.
- `added_delay_p95_ms` above `300` on any scenario line other than S4 is a delay.
- S4 starts with a restart, so its Review Search acquires every File again.
  Its `added_delay_p95_ms` is its full latency, and the stop rule ignores it.
  `summarize` compares the S4 `complete_result_ms` with the S6 `complete_result_ms` instead.
- `low_samples=true` means fewer than 20 refetch samples. The p95 is then the maximum.
- For a merged PullRequest, `not_found_sides` and `hunk_mismatch_files` must be `0`. If not, record the PullRequest. Ticket 03 decides how to use it.
- A line `error=unsupported_command` or an error such as `ScenarioStalled` stops the run with exit code `3`.
  Record the error under `## Comments`, and set this ticket to `needs-info`.

The log also holds these notes:

- `resume skip=` names the finished scenarios that a resumed run skips.
- `segment done=` names a finished segment.
- `give_up attempts=8` means that one request failed 8 times.
  The harness keeps the checkpoint and exits with code `1`, and the script runs the PullRequest again.
- `m28: #<pull-request> failed attempt <n> of 6 with exit code 1, retry in 900 s` is a transient failure.
- `m28: #<pull-request> failed permanently, stop` follows an exit code `3`.
  The line before it names the error. "Resume a run" tells what to do.
- `checkpoint mismatch key=<key>` means that an option differs from the checkpoint.
  The harness exits with code `3`. Use the options of the first start.
- `another harness uses this output directory` means that a second harness runs.
  The harness exits with code `3`. Stop one of them.

### Summarize

After both runs, give the checkpoint files of both runs to `summarize`. Use absolute paths.

```sh
zig build bench-file-cache -- summarize ~/m28-runs/run1-*-all.txt ~/m28-runs/run2-*-all.txt
```

It prints one line for each run and then `outcome=No delay`, `outcome=Delay`, or `outcome=Inconclusive`.
The `scenarios=` key names each scenario that shows a delay.
`restart_review_search` names the restart Review Search delay.
A line such as `run_label=run1 incomplete pull_request=<pull-request> missing=s7` names the first gap of an incomplete run.
The gap is `missing=check`, `missing=<scenario>`, or `reason=failures scenario=<scenario>`.
An incomplete run gives `outcome=Inconclusive scenarios=none`, so run that PullRequest again before a third run.
For `Inconclusive` without an `incomplete` line, do a third run with the run label `run3`, then give all three runs to `summarize`.

### Record

Paste every checkpoint file and the `summarize` output under `## Completion`.
The output holds no source text, File path, query text, Comment text, or URL.
Check this before you paste it.

## Acceptance criteria

- [ ] Two runs on different days and network conditions cover all five PullRequests and all scenarios S1 to S8.
- [ ] Each run records its date, network label, bbr commit, machine, and macOS version.
- [ ] Each PullRequest header shows the state, the File count, and `probe_ms`.
- [ ] For every merged PullRequest, the `not_found` side count and the Hunk mismatch File count are zero.
      If not, the result names the PullRequest, and ticket 03 decides how to use it.
- [ ] No PullRequest result has `failures` above `0`.
- [ ] The `summarize` outcome for the runs is recorded.
- [ ] A third run exists when the first two runs are `Inconclusive`.
- [ ] The recorded output holds no source text, File path, query text, Comment text, or URL.

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
`.scratch/m28-full-review-file-cache-evaluation/brief.md` lists the PullRequest numbers, File counts, binary File counts, changed lines, diff sizes, and the count of PullRequests that the user wrote.
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
