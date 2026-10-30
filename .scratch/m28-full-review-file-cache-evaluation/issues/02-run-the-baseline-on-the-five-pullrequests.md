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

For each run, and for each PullRequest #14, #545, #1516, #2119, and #1436:

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
