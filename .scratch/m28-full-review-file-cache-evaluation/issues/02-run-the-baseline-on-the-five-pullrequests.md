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

Before each run:

1. Check out the bbr commit that resolved ticket 01, and note the commit hash.
2. Make sure that `bbr auth status` exits with `0`.
3. Pick a network label, such as `office-wired` or `home-vpn`.
   The second run must use a different network condition from the first run.

For each run, and for each PullRequest from PullRequest A to PullRequest E:

1. Run `zig build bench-file-cache -- remote pr-webapp <id> --run-label <run> --network-label <label>`.
2. If the request budget makes the run too long, split it with `--scenarios`.
   Run the remaining scenarios later on the same day and network.
3. If a PullRequest result has a failure other than a `429`, run that PullRequest again.
4. Copy the output lines into `## Completion` in this ticket.

After both runs:

1. Run the `summarize` mode on the output of both runs.
2. Copy its outcome into `## Completion`.
3. If the outcome is `Inconclusive`, do a third run on a third day under a third network condition.
   Then run `summarize` on all three runs.

## Run guide

Ticket 01 wrote this guide. Use it with the steps above.

### Prepare

1. Check out the commit that resolved ticket 01 in a clean checkout.
   The header key `bbr_version` must not end with `.dirty`.
2. Run `bbr auth status`. It must exit with `0`.
   The benchmark uses the same Credential as `bbr`.
   The Workspace comes from the Credential, so the Credential must select the `pr-webapp` Workspace.
3. Make an output directory: `mkdir -p ~/m28-runs`.
4. Record the date, the network label, the machine, and the macOS version.
   Get them with `date +%F`, `sysctl -n hw.model`, and `sw_vers -productVersion`.
5. Do not use `bbr` or another Bitbucket API client during a run.
   Other requests use the same hourly rate limit.

### Optional smoke test

This test shows that the Credential and the network work. Do not record its output.

```sh
zig build bench-file-cache -- remote pr-webapp <pull-request> --scenarios s1 --dwell-ms 0 --run-label smoke --network-label smoke
```

### Run one PullRequest

Use the same `--run-label` for every PullRequest of one run, for example `run1`, `run2`, and `run3`.
`summarize` groups the lines by the run label.
A label must not contain a space or `=`.

```sh
zig build bench-file-cache -- remote pr-webapp <pull-request> --run-label run1 --network-label office-wired \
  | tee ~/m28-runs/run1-<pull-request>.txt
```

Do the same for PullRequest B to PullRequest E.
The build runner sends the benchmark lines to standard output and its own progress to standard error.
Only the benchmark lines go into the file.

Keep the other options at their defaults.
The defaults are `--cache-max-bytes 268435456`, `--dwell-ms 1000`, `--seed 28`, `--query return`, `--second-query const`, and `--hourly-request-budget 900`.

### Split a long run

Run all scenarios in one invocation when you can.
If you must split a run, use exactly these two parts on the same day and network, with the same run label:

```sh
zig build bench-file-cache -- remote pr-webapp <pull-request> --run-label run1 --network-label office-wired --scenarios s1,s2,s3 \
  | tee ~/m28-runs/run1-<pull-request>-a.txt
zig build bench-file-cache -- remote pr-webapp <pull-request> --run-label run1 --network-label office-wired --scenarios s4,s5,s6,s7,s8 \
  | tee ~/m28-runs/run1-<pull-request>-b.txt
```

S2 needs S1, and S7 and S8 need S1 or S4, so the harness refuses other splits.
In the second part, S4 starts in a new process, so most of its fetches are cold fetches.
Record each split under `## Completion`.

### Expected duration

These numbers are estimates from the request budget. Nobody measured them.

Before each scenario, the harness estimates two requests for each File that the scenario can fetch.
It waits until the requests of the last hour and the estimate fit in 900.
If the estimate alone is above 900, it waits until no request of the last hour remains.
The harness prints nothing while it waits.

The rows of this table named the benchmark PullRequests. They are not in the repository.

One full run of the five PullRequests takes the sum of their times.
Run the PullRequests one after another, or split the run over two sessions on the same day.
The dwell time adds 1 second for each File Jump. S1 alone has F File Jumps.

### Read the output

Each invocation prints these lines:

- One `header` line with `bbr_version`, `state`, `files`, and `probe_ms`.
- One `scenario=sN` line for each scenario.
- One `check` line with `not_found_sides` and `hunk_mismatch_files`.

Look for these values:

- `failures` must be `0` on every scenario line. If not, run that PullRequest again.
- `rate_limited` counts `429` responses. A `429` response stays in the data. Record the count.
- `refetches` above `0` in S5 or S6 is a delay.
- `added_delay_p95_ms` above `300` on any scenario line is a delay.
- `low_samples=true` means fewer than 20 refetch samples. The p95 is then the maximum.
- For a merged PullRequest, `not_found_sides` and `hunk_mismatch_files` must be `0`. If not, record the PullRequest. Ticket 03 decides how to use it.
- A line `error=unsupported_command` or an error such as `ScenarioStalled` stops the run.
  Record the error under `## Comments`, and set this ticket to `needs-info`.

### Summarize

After both runs, give every output file of both runs to `summarize`. Use absolute paths.

```sh
zig build bench-file-cache -- summarize ~/m28-runs/run1-*.txt ~/m28-runs/run2-*.txt
```

It prints one line for each run and then `outcome=No delay`, `outcome=Delay`, or `outcome=Inconclusive`.
The `scenarios=` key names each scenario that shows a delay.
`restart_review_search` names the restart Review Search delay.
For `Inconclusive`, do a third run with `--run-label run3`, then give all three runs to `summarize`.

### Record

Paste every output file and the `summarize` output under `## Completion`.
The output holds no source text, File path, query text, Comment text, or URL.
Check this before you paste it.

## Acceptance criteria

- [ ] Two runs on different days and network conditions cover all five PullRequests and all scenarios S1 to S8.
- [ ] Each run records its date, network label, bbr commit, machine, and macOS version.
- [ ] Each PullRequest header shows the state, the File count, and `probe_ms`.
- [ ] For every merged PullRequest, the `not_found` side count and the Hunk mismatch File count are zero.
      If not, the result names the PullRequest, and ticket 03 decides how to use it.
- [ ] No PullRequest result has a failure other than a `429`.
- [ ] The `summarize` outcome for the runs is recorded.
- [ ] A third run exists when the first two runs are `Inconclusive`.
- [ ] The recorded output holds no source text, File path, query text, Comment text, or URL.
