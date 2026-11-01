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

## Steps

For each run:

1. Prepare the checkout, the Credential, and the output directory, as "Prepare" describes.
2. Pick a run label, such as `run1`, and a network label, such as `office-wired` or `home-vpn`.
   The second run must use a different network condition from the first run.
3. Start `tools/m28-baseline-run.sh` in the background, as "Start a run" describes.
   The script runs PullRequest A to PullRequest E one after another.
4. Watch the progress.
   If the run stops, run the same start command again to resume it.
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

### Start a run

Start the run detached from the terminal:

```sh
caffeinate -i nohup tools/m28-baseline-run.sh run1 office-wired ~/m28-runs > ~/m28-runs/run1.log 2>&1 & echo $! > ~/m28-runs/run1.pid
```

The script takes the run label, the network label, and the output directory.
It runs `zig build bench-file-cache -- remote` for each PullRequest with these values.
If one PullRequest fails, the script waits 15 minutes and runs it again.
After 6 failed attempts for one PullRequest, the script stops with exit code `1`.

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
This command stops every process of the group: `caffeinate`, the script, the build runner, and the benchmark.

### Resume a run

After a crash, a kill, or a reboot, run the same start command again.

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
The header of each run prints the real `range_files` and `session_requests`.
The optional smoke test prints them for PullRequest E.
Recompute the table with these values before you plan the runs.

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
- A line `error=unsupported_command` or an error such as `ScenarioStalled` stops the run.
  Record the error under `## Comments`, and set this ticket to `needs-info`.

The log also holds these notes:

- `resume skip=` names the finished scenarios that a resumed run skips.
- `segment done=` names a finished segment.
- `give_up attempts=8` means that one request failed 8 times.
  The harness keeps the checkpoint, and the script runs the PullRequest again.
- `checkpoint mismatch key=<key>` means that an option differs from the checkpoint.
  Use the options of the first start.
- `another harness uses this output directory` means that a second harness runs.
  Stop one of them.

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
