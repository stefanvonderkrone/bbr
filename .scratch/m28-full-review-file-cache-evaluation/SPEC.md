# M28 Full-Review File cache evaluation

Status: ready-for-agent
Milestone: M28

The [M28 brief](brief.md) records the approved decisions.
This spec turns the brief and the M28 section of [TODO.md](../../TODO.md) into an evaluation plan.
The tickets live in [issues](issues/).
The earlier disk-cache no-go is in [M17 ticket 09](../m17-diff-blob-highlighting-completeness/issues/09-decide-persistent-file-cache.md).
The current cache policy is in [ADR-0010](../../docs/adr/0010-file-enrichment-transfers-per-side-ownership.md).

## Problem Statement

File Enrichment keeps inactive File content in a byte-budgeted LRU for one Session.
The default budget is 256 MiB.
When the LRU evicts a File, bbr fetches the File again when the reviewer returns to it.
Review Search acquires every File of the Review, so a large Review can evict and refetch many Files.
Session replacement and a process restart discard all File content, so bbr fetches it again.

Nobody measured these refetches on real large PullRequests.
So nobody knows if the reviewer waits for them.

## Solution

M28 makes a measured decision, not a new cache.

1. Ticket 01 adds an opt-in benchmark that drives the real Presentation against live Bitbucket.
2. A human runs the benchmark twice on five PullRequests, on different days and networks.
3. A human applies the stop rule to the results.
4. If no workflow shows a delay, an ADR records "no change", and M28 ends.
5. If a workflow shows a delay, M28 compares the candidate policies and picks the smallest one that removes the delay.

The benchmark output holds only metadata and numbers.
It never holds source content, File paths, query text, Comment text, or Credential values.

## User Stories

1. As a reviewer, I want bbr to keep its current memory use when the cache causes no wait, so that M28 adds no cost without a reason.
2. As a reviewer, I want a File Jump back to a File to be fast, so that I can compare Files without a wait.
3. As a reviewer, I want a repeat Review Search to use the File content that bbr already acquired, so that a query edit does not refetch Files.
4. As a reviewer, I want bbr to keep my source code off the disk unless measurements justify a disk cache, so that a cache does not leak code.
5. As a reviewer, I want any disk cache to be opt-in, private, bounded, and safe to delete, so that I control what stays on my machine.
6. As a maintainer, I want the decision to rest on numbers from real PullRequests, so that the decision holds later.
7. As a maintainer, I want the benchmark to drive the production Presentation code, so that the numbers include prefetch, Review Search acquisition, and eviction.
8. As a maintainer, I want benchmark output that I can paste into a ticket, so that the evidence stays with the decision.
9. As a maintainer, I want hermetic tests for the benchmark logic, so that the p95 and refetch numbers are correct.

## Current behavior under test

These code paths decide the current policy.
The benchmark measures them and does not change them.

| Concern | Owner |
| --- | --- |
| The cache policy and budget | `CachePolicy`, `previewCacheEnforcement`, and `Storage` in `src/tui/file_enrichment.zig`. |
| The configuration keys | `[files.cache]` keys `enabled` and `max_bytes` in `src/tui/config.zig`. The default is `Configuration.default_inactive_file_cache_max_bytes`, 256 MiB. Zero means unlimited inactive content. |
| The focused File | `Storage.focusAdmitted` and `Storage.requiresCacheEnforcement`. The focused File is outside the budget. |
| The remote fetch | `file_enrichment.enrichConcurrent` with `RemoteBlobSource`. Each File uses at most two requests to `GET /repositories/{workspace}/{repo}/src/{commit}/{path}`. |
| The prefetch | `ensureFocusedEnrichment` and `enrichmentRange` in `src/tui/presentation.zig`. The Enrichment Range holds every File with a row in the DiffPane viewport, plus one File above and one File below. The active File is demand work. After it is terminal, the other Files of the range follow as speculative work, up to four at once. Files in the range are outside the budget. An open Review Search stops new speculative work. |
| Review Search acquisition | `openReviewSearch`, `pumpReviewSearchAcquisition`, `holdReviewSearchFiles`, `maybeQueueReviewSourceScan`, and `replaceReviewSearchQuery` in `src/tui/presentation.zig`. Up to eight File Enrichments run at once, in display path order. A query edit clears the source scan and scans every File again. |
| The worker | `presentationEnrichmentWorker` in `src/tui/app.zig`. |
| The command seam | `presentation_runtime.CommandExecutor` and `CompletionSink` in `src/tui/presentation_runtime.zig`. |
| The HTTP seam | `HttpClient` in `src/http/client.zig`. Production uses `StdHttpClient`. Tests use `FakeHttpClient`. |
| The existing benchmark | `zig build bench-file-acquisition` in `src/benchmark/file_acquisition.zig`. It measures File Enrichment concurrency, not the cache. |
| The p95 rule | `harness.run` in `src/benchmark/harness.zig` uses the nearest rank: index `(n * 95 + 99) / 100 - 1` of the sorted samples. |

## Definitions

These words are local to this spec.
They are measurement words, not domain terms, so no glossary gets them.

- Visible Action: an Action whose result the reviewer waits for on screen.
  M28 measures two kinds: a File Jump, and a Review Search open or query edit.
- Cold fetch: the first File Enrichment of a File in one benchmark run of one PullRequest.
- Refetch: a File Enrichment of a File that the same benchmark run already admitted once.
  A refetch after eviction, after Session replacement, and after a process restart are all refetches.
- Hit: a Visible Action whose File content is ready when the Action starts.
  A File Jump is a hit when File Enrichment of its target File is terminal at the start.
  A fetch that is in flight at the start is no hit, because the reviewer waits for its rest.
  A File that a speculative refetch made ready before the Action counts as a hit.
  The `enrichment_refetches` key shows those refetches.
- Added delay: the latency of a Visible Action sample with a refetch, minus the hit median.
  The hit median is the median latency of the hit samples of the same Action kind.
  The median comes from the same run, PullRequest, and scenario.
  If no hit sample exists, the added delay is the full latency.

## Measurement method

### Benchmark PullRequests

The benchmark uses the five PullRequests in `pr-webapp` from the brief.
Their ids are in the local file `~/m28-runs/pullrequests.txt`, outside the repository.
`tools/m28-baseline-run.sh` reads that file. The letters A to E follow its order.

| PullRequest | Reason |
| --- | --- |
| PullRequest A | Most Files and most changed lines |
| PullRequest B | Many Files with small changes |
| PullRequest C | Largest open PullRequest |
| PullRequest D | Many changed lines in a mid-size File set |
| PullRequest E | Most binary Files |

### The harness

Ticket 01 adds `src/benchmark/file_cache.zig` and the build step `zig build bench-file-cache`.
The command is `zig build bench-file-cache -- remote <repository> <pull-request-id> [options]`.
It resolves the Credential with `bbr.bitbucket.auth.resolve`, like `src/benchmark/file_acquisition.zig`.
So it uses the default Profile, as `bbr` does without `--profile`.
The `remote` mode needs two options:

- `--output-dir DIR` names the directory for the request window, the lock, and the checkpoint files.
  The harness creates the directory.
- `--run-label LABEL` names the run.
  It must not be empty.
  It must not contain `/` or `\`, because it names the checkpoint file.

The harness drives the real `Presentation` from `src/tui/presentation.zig`.
It sends each Action through `Presentation.dispatch`, as the Presentation tests do.
It executes each produced `OwnedCommand` through its own `presentation_runtime.CommandExecutor`.
For `enrich_file`, the executor makes the same `file_enrichment.enrichConcurrent` call as `presentationEnrichmentWorker`.
It runs File Enrichments concurrently, as `src/tui/app.zig` does.
For every other command kind that a scenario produces, it calls the production function that `src/tui/app.zig` calls.
It fails the run on a command kind that it does not support.
It uses the production Highlighter and `Configuration.default_highlight_max_file_bytes`.
It builds each Presentation Frame at a fixed geometry of 200 columns and 50 rows.
The Frame size sets the Enrichment Range, and the range sets which Files stay outside the budget.
So a run at another size measures another policy.
The fixed size keeps all runs comparable, and it is a common full-screen terminal size.
The header prints `cols` and `rows`.
It paints no terminal.

The harness must not copy the prefetch, eviction, or Review Search acquisition policy.
These policies must come from the production code.
If a measurement needs a hook in production code, the hook must change no production behavior.
Ticket 01 then lists the hook and the reason under `## Completion`.

### Instrumentation points

- `MeasuringHttpClient` wraps `StdHttpClient.httpClient()` behind the `HttpClient` seam.
  It gates each attempt on the request window and retries a failed attempt.
  It counts attempts, `/src/` requests, `429` responses, retries, and final failures.
  It records the latency of each attempt and the time in which the harness waits.
  It never stores a URL, a header, or a body.
- The executor records the start and the end of each `enrich_file` command.
  It records the File index, the work id, and the `speculative` flag.
  It counts every `enrich_file` command, inside or outside a span.
- At the start of each span, the harness records which Files have terminal File Enrichment.
  It also keeps the fetches that are in flight at the start.
  A span can wait for these fetches, so they count for the span.
- At the end of each span, the harness also counts the `enrich_file` commands that the Presentation still queues for the current Session.
  A command ahead of them in the queue, such as a running disclosure build, can hold them back until after the span.
  The span caused these fetches or can wait for them, so they count for the span.
- The harness keeps one admitted flag for each File in each run.
  The flag survives Session replacement and the simulated restart.
  An `enrich_file` command for a File with the flag set is a refetch.
- The harness reads `Storage.retainedBytes()` after each admission.
  It keeps the peak and the value at the end of each scenario.
- The harness keeps the full-Review size: the sum of the largest `Result.retainedBytes()` of each admitted File.
  This number is the memory that a full-Review memory cache would need.
- The harness reads the process peak memory from `getrusage` at the end of each scenario.
- A File Jump latency starts at `Presentation.dispatch`.
  It ends at the first Presentation Frame after File Enrichment of the focused File is terminal.
  If the content is present at dispatch, it ends at the next Frame.
- A Review Search first-result latency ends at the first Frame that shows one Search Occurrence.
- A Review Search complete-result latency ends at the first Frame in which the scan is complete.
  The scan is complete when the query is not pending, every File is source-scanned, and no Review Search command is queued.

### Merged PullRequest check

The five PullRequests include merged PullRequests.
The harness opens every PullRequest through the same Candidate Session acquisition and File Enrichment path.
For each PullRequest, it prints the state, the count of sides with `not_found`, and the count of Hunk mismatch Files.
A Hunk mismatch File has a text side with a Hunk Line that differs from the fetched blob.
The check compares each Hunk Line text with the blob line at the same line number.
The check compares in memory and prints only counts.

### Scenarios

The harness runs one chain of scenarios for each PullRequest, in this order.
A dwell time of 1,000 ms follows each File Jump after its File is ready.
The random sequences use the seed 28, so each run uses the same Files.

| Id | Scenario | Steps | Samples |
| --- | --- | --- | --- |
| S1 | Sequential review | From the first File, `next_file` through every File in File Tree order. | One File Jump for each File. |
| S2 | Revisit after eviction | File Jump through the File Finder to the 50 least recently focused Files, oldest first. | 50 File Jumps. |
| S3 | Non-sequential navigation | 200 File Jumps through the File Finder to seeded random Files. | 200 File Jumps. |
| S4 | First Review Search after a restart | Restart as S8 does, then open Review Search with the configured query. | First-result and complete-result latency. |
| S5 | Query edits | In the open Overlay, add one character, remove it, then replace the query with a second query. | Three complete-result latencies. |
| S6 | Overlay reopen | Close Review Search, do 10 seeded File Jumps, and open Review Search with the same query. | One complete-result latency. |
| S7 | Session replacement | Run `refresh`, then do 20 seeded File Jumps to Files that the run admitted. Repeat three times. | 60 File Jumps. |
| S8 | Process restart | Destroy the Presentation and the `StdHttpClient`, then create new ones and load the Session. Do the S7 File Jumps. Repeat three times. | 60 File Jumps and the Candidate Session time. |

A File with only binary or unavailable sides takes part in File Jumps, but it never causes a fetch.
S4 complete-result latency also stands for the first Review Search after S7 or S8.
The restart Review Search added delay is the S4 complete-result latency minus the S6 complete-result latency.
This estimate is valid only when S6 had no refetch.

S4 starts with a process restart, so its Review Search acquires every File again.
The restart loads the Session and waits until the first File is shown, as a reviewer does after a start.
Then the S4 span starts.
S5 and S6 continue on the content that S4 acquired.
So S6 is a warm Review Search, and rule 3 compares a cold and a warm Review Search on the same PullRequest.
The S4 sample has no hit baseline, so its `added_delay_p95_ms` is its full latency.
Rule 1 does not apply to S4, because rule 3 gives the added delay of S4.

The default query is `return`, and the second query is `const`.
The options `--query` and `--second-query` replace them.
The output records only the query length.

### Request budget

Bitbucket limits `/2.0/repositories/*` to 1,000 requests for each user in a rolling hour.
This limit applies to a personal API token, which the Credential holds.
The source is [API request limits](https://support.atlassian.com/bitbucket-cloud/docs/api-request-limits/).
Bitbucket sends no `X-RateLimit` headers, so the harness cannot read the remaining requests.
One full acquisition of a PullRequest with F Files needs about 2F requests.

The harness keeps a rolling request window in `<output-dir>/requests.log`.
The file holds one Unix timestamp in nanoseconds for each line, and nothing else.
The window survives a crash, a kill, and a restart, so a new process sees the requests of the old one.
At start, the harness drops entries older than one hour and rewrites the file atomically.
It appends without a sync for each line, so a power loss can lose the last lines.

The budget is `--hourly-request-budget`, and the default is 900.
The default stays below 1,000, because other `bbr` use shares the same Bitbucket limit.

The harness applies two gates:

1. Before each attempt, the per-request gate checks the window.
   If the window holds the budget, the attempt waits until the oldest entry leaves the hour.
   One lock covers the check and the record, so concurrent requests never exceed the budget.
2. Before each scenario, the harness estimates an upper bound of its requests.
   `range_files` is the largest Enrichment Range at the fixed Frame.
   The harness gets it from the production `enrichmentRange` at each scroll position of the start Frame.
   `session_requests` is the largest number of requests that one Session load sent at a start.
   Each scenario has a count of full passes over every File, of File Jumps, and of Session loads.
   A File Jump can fetch the whole Enrichment Range.
   A Session load sends `session_requests` requests and also fetches the Enrichment Range of its start.
   Each File uses at most two requests.
   So the estimate is `loads * session_requests + 2 * (passes * files + (jumps + loads) * range_files)`.
   S1 has one pass and one File Jump, for its `to_top` jump.
   S2 has 50 File Jumps, and S3 has 200 File Jumps.
   S4 has one pass and one Session load.
   S5 has four passes, because it can open the Overlay before its three edits.
   S6 has two passes and 10 File Jumps.
   S7 and S8 each have three Session loads and 60 File Jumps.
   If the estimate fits in the budget, the harness waits until the window has room for the whole estimate.
   Then the scenario runs without waits from the window, if the estimate holds.
   If the estimate exceeds the budget, the harness does not wait before the scenario.
   The per-request gate then sets the pace inside the scenario.

The harness no longer waits for an empty hour.
A `429` response fills the window.
The harness adds entries until the window holds the budget, and these entries persist like requests.

The harness prints a note on stderr before each wait.
A note holds `key=value` pairs and never a URL, a path, a header, a body, or a token.
For example: `wait reason=window seconds=12.5 resume=2026-10-31T13:05:00Z`.
The `reason` is `window` for the per-request gate, `scenario` before a scenario, and `retry` for a backoff.
`resume` is the UTC time when the wait ends.

### Excluded time

A harness wait does not count as latency.
The harness counts a stall when at least one request is in flight and every in-flight request waits.
The latency of a span is its time minus the stall time inside the span.
The S8 Candidate Session time and `probe_ms` use the same rule.
A Visible Action with stall time in its span counts in `paced_samples`.

This rule has two limits:

- A backoff of one request while other requests progress stays in the latency.
  The reviewer waits for that request too.
- CPU work that overlaps a stall leaves the latency too.

### Retry

The harness retries a failed attempt below the `HttpClient` seam.
It retries only a `GET` request.
It retries after a `429` response, a `5xx` response, or a send error other than `OutOfMemory` and `Canceled`.
It does not retry another status, such as `401` or `404`.

The policy uses full jitter backoff:

- Retry k waits a random time from 0 to `min(15 min, 2 s * 2^(k-1))`.
- With 8 attempts, the ceilings are 2, 4, 8, 16, 32, 64, and 128 s.
- If the response has `Retry-After`, the wait is at least that time.
- After 8 attempts, the harness gives up.
  It prints `give_up attempts=8` with the status or the error, and every later request fails.
  The run exits non-zero, and the checkpoint keeps the last finished segment.

The counters follow the attempts:

- `requests` counts attempts, so it matches the entries in the window.
- `rate_limited` counts the attempts with a `429` response.
- `retries` counts the attempts that the harness retries.
- `failures` counts final failures only.
  A `503` that succeeds on a retry is no failure.

The round trip of each attempt stays in the latency.
The backoff wait leaves the latency when it is stall time.
This changes the old rule that a `429` response stays in the data.

`RemoteBlobSource` in production retries once, above the harness retry.
The harness retry handles a retryable response first.
So the production retry runs only after the harness gives up, and then it fails at once.

`StdHttpClient` has no request timeout, so the harness adds one.
Each live attempt times out after 120 s.
The timeout cancels the attempt and counts as a send error, so the harness retries it.
A slow download of a large File must finish inside the 120 s.

### Resume

A rerun with the same options resumes the run.
The unit of resume is a segment.
A segment is a sequence of selected scenarios that share state in memory.

- The selected scenarios among S1 to S6 form one segment.
  Each of them measures the LRU, the focus history, or the open Overlay that the scenario before it left.
  A new process cannot rebuild that state, so a resumed S2 would measure something else.
- S7 is one segment, and S8 is one segment.
  Each starts with a Session replacement or a restart, which discards all File content.
  They need only the admitted flags, and the checkpoint holds those flags.

The checkpoint file is `<output-dir>/<run-label>-<pull-request>-<selection>.txt`.
The selection is `all`, or the selected ids joined by `-`, for example `s1-s2-s3`.
The file holds these lines:

1. The `header` line.
2. One `scenario=` line for each finished scenario.
3. One `progress` line.
   It holds the finished scenarios, the admitted and checked flags as bit strings, the largest sizes, and the check counters.
   It holds no File path.
4. The `check` line, only when every segment is done.

The harness writes the file after the header and after each segment.
Each write goes to a temporary file, syncs it, and replaces the checkpoint.
So a crash leaves the file at the last finished segment.

A rerun reads the checkpoint and acts on it:

- With a `check` line, the rerun prints the stored lines and sends no request.
- Without a `check` line, it prints the stored lines and restores the progress.
  It prints `resume skip=` with the finished scenarios.
  Then it runs the first unfinished segment from its first scenario.
- A failed segment leaves no line in the checkpoint.
  The rerun starts that segment again with the state of the last finished segment.
- These header keys must match the current options: `network_label`, `bbr_version`, `cache_max_bytes`, `dwell_ms`, `seed`, `query_bytes`, `second_query_bytes`, `hourly_request_budget`, `cols`, and `rows`.
  A difference prints `checkpoint mismatch key=<key>` and stops the run.
- A different File count stops the run with `FileCountChanged`.

Standard output repeats the checkpoint content without the `progress` line.

The harness locks `<output-dir>/lock` for the whole run.
A second harness on the same output directory prints `another harness uses this output directory` and stops.
The OS releases the lock when the process ends, also after a crash or a kill.

The option `--scenarios` selects a subset, so a human can split a long run across sessions.
A subset has its own checkpoint file, because the selection is part of the file name.
Every invocation prints the same header, so the results merge.

### Output

The harness prints one header line and one line for each scenario as `key=value` pairs, like `harness.run`.
The header holds the run label, the network label, the bbr commit, and the cache budget.
It also holds the PullRequest id, its state, and its File count.
The header also holds `probe_ms`, the median of five `getPullRequest` latencies before the chain.
It also holds the Frame size as `cols` and `rows`.
It also holds `range_files` and `session_requests`, the inputs of the request estimate in "Request budget".
Each scenario line holds these keys:

- `samples`, `hits`, `cold_fetches`, and `refetches`.
  These keys count Visible Action samples by their class in "Definitions".
- `enrichments`, the `enrich_file` commands that the scenario executed, inside or outside a span.
  `enrichment_refetches` counts the commands for an admitted File.
  `speculative_enrichments` counts the commands that started as speculative work.
  These counts show the refetches that the prefetch did before a File Jump.
- `latency_median_ms` and `latency_p95_ms`.
- `added_delay_p95_ms`, computed over the samples with a refetch.
- `first_result_ms` and `complete_result_ms` for S4, S5, and S6.
- `requests`, `src_requests`, `failures`, and `rate_limited`, as the "Retry" section defines them.
- `request_estimate`, the estimate of gate 2 in "Request budget".
  A `requests` value above `request_estimate` means that the estimate failed.
- `retries`, the attempts that the harness retried.
- `paused_ms`, the stall time in the scenario, which the latencies exclude.
- `paced_samples`, the Visible Actions with stall time in their span.
- `peak_retained_bytes`, `retained_bytes`, `full_review_bytes`, and `peak_rss_bytes`.
- `cache_hit_rate`, which is hits divided by hits plus refetches. Cold fetches do not count.
  A hit that a speculative refetch made ready counts as a hit, so compare `enrichment_refetches` too.
- `low_samples=true` when the scenario has fewer than 20 samples with a refetch.

The p95 uses the nearest rank, like `harness.run`.
With fewer than 20 samples, the p95 is the maximum, and `low_samples=true` marks it.
The harness prints no File path, URL, source text, Comment text, or query text.
The notes on stderr and the files in the output directory follow the same rule.
They never hold the Credential token.

### Runs and network conditions

The baseline is two runs of all five PullRequests with the current default budget.
The two runs are on different days.
They also use different network conditions, for example a wired office network and a home network over VPN.
Each run records its network label and its `probe_ms`.
A PullRequest result with `failures` above 0 is invalid, and the human runs that PullRequest again.
[Ticket 02](issues/02-run-the-baseline-on-the-five-pullrequests.md) has the run guide.

## Stop rule

A run shows a delay when one of these conditions is true for one PullRequest:

1. One scenario other than S4 has `added_delay_p95_ms` above 300.
2. S5 or S6 has `refetches` above zero.
3. The restart Review Search added delay is above 300 ms.

The baseline result is one of these outcomes:

- No delay: neither run shows a delay.
  Ticket 04 records "no change" in an ADR, and M28 ends.
- Delay: both runs show a delay.
  M28 compares the candidate policies in the next section.
- Inconclusive: one run shows a delay, and the other does not.
  The human runs a third run on a third day under a third network condition.
  The outcome follows the two runs that agree.

The rule applies only to complete runs.
A run is complete when it has a result for each PullRequest that any run of the input has.
A result is one `check` line and one scenario line for each of S1 to S8.
Each of these scenario lines must have `failures=0`.
If one run is not complete, `summarize` prints an `incomplete` line for that run and gives "Inconclusive".
The human then runs the missing PullRequest again.

Ticket 03 applies this rule.
Ticket 03 also records which scenarios show the delay, because the trigger limits the candidates.

## Candidate policies

This section applies only when the baseline outcome is "Delay".
M28 then compares these policies, from the smallest to the largest.

| Id | Policy | Can remove a delay in | Measurement |
| --- | --- | --- | --- |
| C0 | The current LRU at 256 MiB. | Nothing. It is the baseline. | The baseline runs. |
| C1 | A revised LRU: a larger default `max_bytes`, or a rule that keeps Review Search Files longer. | S2, S3, S5, S6. | The harness with `--cache-max-bytes`, or a prototype of the rule. |
| C2 | A full-Review memory cache: keep every File for the Session lifetime under a hard bound. Optionally carry content across Session replacement when the Repository, commit, and path match. | S2, S3, S5, S6, and S7 with the carry-over. | The harness with `--cache-max-bytes 0`, and `full_review_bytes`. |
| C3 | An opt-in disk cache under the state home. | S2, S3, S5, S6, S7, S8. | A disk read simulation in the harness. |

Ticket 03 drops each candidate that cannot remove the measured delay.
For example, a delay only in S8 leaves only C3.

### C1 and C2 memory bound

The comparison reports the representative and the worst `full_review_bytes` and `peak_rss_bytes` over the five PullRequests.
It defines a hard bound for C2.
It defines the behavior when one Review exceeds the bound.
The default proposal is that C2 falls back to LRU eviction at the bound and shows no error.

### C3 disk cache design

The disk evaluation covers each item from decision 3 of the brief.

- Source-code retention: the disk cache is off by default.
  A new `[files.cache]` key turns it on.
  The cache holds raw File content only, never Highlighting Spans, Comments, or Credentials.
- Location: `$XDG_STATE_HOME/bbr/file-cache/`.
  The code gets the path only from `xdg.stateHome` in `src/xdg.zig`.
- File permissions: the directory has mode `0700`, and each entry has mode `0600`.
  The cache refuses a target that is not a regular file or a directory, like `auth.toml` storage in M26.
- Key and invalidation: the key is the Workspace, the Repository, the commit hash, and the path.
  Content at a commit never changes, so a new SourceCommit uses new keys and needs no invalidation.
  A blob id key is an option when the RawDiff carries `index` blob ids.
  The comparison records whether a blob id key removes duplicates across commits.
- ReviewIdentity: the cache serves only RemoteReview.
  LocalReview reads blobs from local `git`, so it needs no cache.
- Size limits: a byte limit for the whole cache, with eviction by last access.
- Cleanup: at startup, the cache deletes entries past a maximum age and above the byte limit.
  The ADR names a way for the reviewer to delete the whole cache.
- Atomic writes: each entry is a temporary file in the cache directory, then a rename.
- Corruption recovery: each entry has a header.
  The header holds the format version, the key, the length, and a SHA-256 of the content.
  A bad header, length, or digest deletes the entry, and bbr fetches the File.
- Format migration: a different format version deletes the whole cache directory.
- Unavailable cache: an I/O failure counts as a miss.
  File Enrichment never fails because of the cache.
  The status shows one warning for each Session.
- Seam: the cache is a `BlobSource` decorator over `RemoteBlobSource` in `src/tui/file_enrichment.zig`.
  Presentation and the Session Epoch rules stay the same.

The simulation measures C3 without writing source content to disk.
For each File, the harness writes random bytes of the same length to a private temporary directory.
It reads them back and records the read latency.
It adds the Highlighting time of the real content, which it measures in memory.
It deletes the directory at the end of the run.
The OS page cache can make reads faster than a cold disk, and the report states this limit.

### Decision

The decision picks the smallest candidate that has no delay in two runs that agree.
The candidate must also have a hard bound on memory and on disk use.
The valid decisions are no change, a revised LRU, a full-Review memory cache, or an opt-in disk cache.

## Conditional work

The tracker counts every ticket in `issues/` toward the completion of this spec.
A ticket for work that never happens would block the spec.
So the tickets for the comparison and the policy do not exist yet.

When ticket 03 records the outcome "Delay", ticket 03 writes these tickets.
It numbers them from 05 and adds them to the `Blocked by:` line of ticket 04.

- Compare the remaining candidates on the five PullRequests (`ready-for-agent` for the harness options, `ready-for-human` for the runs).
- Decide the policy from the comparison (`ready-for-human`).
- Build the selected policy behind `[files.cache]` (`ready-for-agent`).
  The ticket adds deterministic eviction, invalidation, corruption, failure, and Session Epoch tests.

Each new ticket follows this spec, and the human reviews it before an agent claims it.

## Glossary changes

M28 adds no glossary term while it measures.
The "Definitions" section names only measurement words.

If the decision changes the policy, the policy ticket updates these entries:

- File Enrichment, in the [Presentation glossary](../../src/tui/GLOSSARY.md): the retention rule of the selected policy.
- File, in the [Diff glossary](../../src/diff/GLOSSARY.md): "held in a Session-side table" changes if content outlives the Session.

The spec uses existing terms from the Diff, Presentation, Review, and Bitbucket glossaries.
Examples are File, File Enrichment, File Jump, Review Search, Search Occurrence, and Session Epoch.

## AGENTS.md rules

M28 touches these existing rules:

- "Only `src/xdg.zig` reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`."
  The harness reads no XDG variable.
  A C3 disk cache gets its path from `xdg.stateHome`.
- "`presentation.zig` does not import vaxis or `theme.zig`."
  The harness lives in `src/benchmark/` and adds no import to `presentation.zig`.
- "A File Jump calls `Published.jumpToFileHeader`."
  The harness makes File Jumps only through `next_file` and the File Finder, so this rule holds.
- "The status paints each part through `Theme.statusStyle`."
  A C3 warning, if any, uses an existing part or a new arm of `StatusPart`.

Ticket 01 adds one rule to the table:

| Rule | Enforcement |
| --- | --- |
| The File cache benchmark prints only metadata and numbers, never source text, File paths, query text, Comment text, or URLs. | The test "M28 cache benchmark output holds no source, path, query, or Comment text" in `src/benchmark/file_cache.zig`. |

The follow-up for the persistent window, the retry, and the resume adds these rules:

| Rule | Enforcement |
| --- | --- |
| The File cache benchmark keeps its request window in `<output-dir>/requests.log`. No rolling hour in that file holds more requests than the budget. A `429` response fills the window. | The tests "M28 cache the request window survives a restart and never exceeds the budget in any hour" and "M28 cache a 429 marks the request window full" in `src/benchmark/file_cache.zig`. |
| A harness wait never counts as File cache benchmark latency. | The test "M28 cache a harness wait inside a span is not latency" in `src/benchmark/file_cache.zig`. |
| The File cache benchmark retries a `GET` with full jitter backoff and waits at least the `Retry-After` time. After 8 attempts, it exits non-zero and keeps the checkpoint. | The tests "M28 cache retries back off with full jitter up to the cap and honour Retry-After" and "M28 cache gives up after 8 attempts and a rerun resumes at the first unfinished segment" in `src/benchmark/file_cache.zig`. |
| A File cache benchmark rerun resumes at the first unfinished segment. The selected scenarios among S1 to S6 form one segment. A rerun of a finished run sends no request. | The tests "M28 cache gives up after 8 attempts and a rerun resumes at the first unfinished segment", "M28 cache a rerun of a finished run sends no request", and "M28 cache a failure inside S1 to S6 restarts that segment from S1" in `src/benchmark/file_cache.zig`. |
| The Credential token never reaches the File cache benchmark stdout, stderr, or a run file. | The test "M28 cache the Credential token never reaches the output, the notes, or the run files" in `src/benchmark/file_cache.zig`. |

## ADR conflicts

[M17 ticket 09](../m17-diff-blob-highlighting-completeness/issues/09-decide-persistent-file-cache.md) says not to use an arbitrary latency threshold without workflow evidence.
The 300 ms threshold in decision 2 of the brief applies only to measured workflows on real PullRequests.
So the threshold meets the M17 reopen condition and does not conflict with it.

[ADR-0010](../../docs/adr/0010-file-enrichment-transfers-per-side-ownership.md) keeps the LRU and says that M17 decides on a disk cache.
M17 decided "no disk cache".
The M28 ADR from ticket 04 records the new evidence and the M28 decision.
It replaces ADR-0010 only if the decision changes the policy.

## Testing Decisions

A good test asserts numbers that the report prints and the absence of forbidden text.
Tests do not assert private helper calls or the order of internal commands.

Every new test name starts with `M28 cache`, so `zig build test-file-cache` runs them.
The tests join the `zig build test` import chain.

### Seams

- `FakeHttpClient` from `src/http/fake_client.zig` is the network seam.
  The tests drive the harness against it with no network and no Credential.
- An injected clock is the time seam for the request window, the latency numbers, and every wait.
  It gives the awake time for latencies, the wall time for the window, and a sleep.
  The fake clock records each sleep, so a test can assert the backoff sequence.
- An injected random source is the seam for the retry jitter.
- `CachePolicy.max_retained_bytes` is the eviction seam.
  A small budget forces eviction in a small fixture.

### Prior art

- `harness.run` in `src/benchmark/harness.zig` for the p95 rule and the output format.
- `src/benchmark/file_acquisition.zig` for the Credential, the remote source, and the sample loop.
- The test "File content cache evicts the least-recently-focused whole File and refetches it on revisit" in `src/tui/file_enrichment.zig`.
- The prefetch sentinel tests in `src/tui/presentation.zig`, which assert that content sentinels never leak.

### Test plan

Statistics:

- The p95 of 1, 19, 20, and 100 samples matches the nearest rank.
- Fewer than 20 refetch samples set `low_samples=true`.
- The added delay subtracts the hit median, and it is the full latency when no hit exists.
- The cache hit rate excludes cold fetches.

Classification:

- A first fetch counts as a cold fetch.
- "M28 cache a File Jump to a File whose fetch is still in flight is a fetch, not a hit".
  A slow source keeps each prefetch in flight when the File Jump starts.
  S1 counts those jumps as cold fetches, and S2 counts them as refetches.
- A File that a small budget evicts and that a File Jump revisits counts as one refetch.
- A File after `refresh` counts as a refetch.
- A File after the simulated restart counts as a refetch.
- With `--cache-max-bytes 0`, S2, S3, S5, and S6 have no refetch.

Scenarios on `FakeHttpClient`:

- Each scenario runs to the end on a fixture with text, binary, added, and removed Files.
- S5 and S6 report refetches with a small budget and none with an unlimited budget.
- A fake `429` response counts in `rate_limited` once for each attempt that gets it.
- The executor fails the run on an unsupported command kind.

Merged PullRequest check:

- A blob that matches its Hunks gives zero Hunk mismatch Files.
- A blob with one changed Hunk Line gives one Hunk mismatch File.

Request budget:

- "M28 cache the request window survives a restart and never exceeds the budget in any hour".
  Two runs share one output directory.
  No hour in `requests.log` holds more entries than the budget.
  The second run keeps the entries of the last hour of the first run, and its own entries follow them.
- "M28 cache a harness wait inside a span is not latency".
  A budget below the scenario estimate makes the gate wait inside spans.
  The latency stays 0, and `paused_ms` and `paced_samples` are above 0.
- "M28 cache a 429 marks the request window full".
  After one `429`, the window holds the budget, and the retry waits with `reason=window`.
- The harness waits before a scenario when the window has no room for an estimate that fits in the budget.
- "M28 cache the request estimate bounds the requests of each scenario".
  The tall fixture and a fixture of 20 short Files each run every scenario at a cache budget of 1 and at the default budget.
  No scenario sends more requests than its `request_estimate`.
  In the short fixture, `range_files` is above 3, and S3 sends more than 400 requests at a cache budget of 1.
  So one File for each File Jump is not an upper bound.
  The short fixture has 41 Comment pages, so the Session load costs more than the start Enrichment Range.
  Its `session_requests` equals the requests of one Session load of the fixture.

Retry:

- "M28 cache retries back off with full jitter up to the cap and honour Retry-After".
  Three `503` responses with the maximum jitter wait 2, 4, and 8 s.
  A cap of 5 s gives 2, 4, 5, and 5 s.
  A `429` with a `Retry-After` of 7 s waits 7 s.
- "M28 cache gives up after 8 attempts and a rerun resumes at the first unfinished segment".
  The run returns an error after exactly 8 attempts of one request.

Resume:

- "M28 cache gives up after 8 attempts and a rerun resumes at the first unfinished segment".
  A failure inside S7 keeps the S1 to S6 lines.
  The rerun prints S7 and S8, and its S7 has no cold fetch.
- "M28 cache a rerun of a finished run sends no request".
- "M28 cache a failure inside S1 to S6 restarts that segment from S1".
- "M28 cache a second harness on the same output directory fails".
- "M28 cache a rerun with other options fails on the checkpoint".

Containment:

- "M28 cache benchmark output holds no source, path, query, or Comment text".
  Sentinels in the fake blobs, paths, query, and Comment bodies never appear in the output.
  They also never appear in the notes or in a file in the output directory.
- "M28 cache the Credential token never reaches the output, the notes, or the run files".

Stop rule:

- Two runs with no delay give "No delay".
- Two runs with a delay give "Delay".
- One run with a delay gives "Inconclusive".
- One refetch in S5 or S6 is a delay, even with a low latency.
- "M28 cache summarize applies rule 3, not rule 1, to the S4 restart Review Search".
- "M28 cache S4 is a cold Review Search after a restart, also when every File fits the budget".
- A run with a missing or failed result gives "Inconclusive".

## Out of Scope

- A change to the cache policy before the decision.
- LocalReview measurements. LocalReview reads blobs from local `git`.
- A cache for Highlighting Spans on disk.
- A cache for RawDiff, Comments, or PullRequest metadata.
- Artificial network throttling. The runs use real network conditions.
- Changes to the prefetch policy, unless the decision selects C1 with a prefetch change.
- Storage of any benchmark output that holds source content.

## Further Notes

- Decision 1 of the brief makes the alternatives conditional.
  The TODO lines for the alternatives stay, but ticket 04 marks them as not needed when the outcome is "No delay".
- Decision 4 of the brief fixes the five PullRequests.
  If a PullRequest becomes unavailable, ticket 02 records it, and ticket 03 decides with the remaining four.
- The harness does not read `config.toml`.
  The options set the budget, so a run does not depend on local configuration.

## Choices this spec records

The brief does not answer these questions.
This spec records a choice for each one.
The human can change a choice at ticket 03.

1. Runs that disagree: a third run decides, and the outcome follows the two runs that agree.
2. The baseline for the added delay: the hit median of the same Action kind in the same run, PullRequest, and scenario.
3. Refetch after Session replacement or a restart: it counts as a refetch under the 300 ms rule.
4. Repeat Review Search: S5 query edits and S6 Overlay reopen. One refetch in either is a delay.
5. The round trip of each attempt stays in the latency, also for a `429`, because a reviewer waits for it.
   A harness wait leaves the latency, because the reviewer never makes that wait.
6. The sample floor: with fewer than 20 refetch samples, the p95 is the maximum, and the output marks it.
7. The disk cache location: the state home, as the M28 request names, not a new cache home.
8. The disk simulation uses random bytes of the same length, so no source content reaches the disk.
9. Conditional tickets: the spec describes them, and ticket 03 writes them only for the outcome "Delay".
10. The default budget is 900 requests an hour, below the Bitbucket limit of 1,000, because other `bbr` use shares that limit.
11. The request window persists in the output directory, so a restart cannot exceed the budget.
12. The retry policy is full jitter from 2 s, doubled for each retry. The cap is 15 min, and the limit is 8 attempts.
13. The harness excludes a wait from latency only while every in-flight request waits.
14. The unit of resume is a segment, and S1 to S6 form one segment because they share state in memory.
15. S4 starts with a process restart.
    Before this change, S4 ran after S1 had admitted every File, so S4 sent no request and rule 3 could not fire.
    A restart before S4 costs one Session load and adds no Review Search, so it is the smallest change that makes S4 cold.
    The alternative, a Review Search after each S7 refresh and each S8 restart, costs six full acquisitions and changes the S7 and S8 File Jumps.
16. The request estimate of a scenario is an upper bound of its requests.
    So a scenario whose estimate fits in the budget waits before it starts and never inside a measured span.
    The estimate counts the production Enrichment Range for each File Jump and Session load, and the observed Session-load requests.
    An estimate of one File for each File Jump was too low after the Enrichment Range arrived.
    The budget stays 900 requests an hour.
