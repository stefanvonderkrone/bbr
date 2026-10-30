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
| The prefetch | `PrefetchArm`, `maybeQueuePrefetch`, and `pauseQueuedPrefetch` in `src/tui/presentation.zig`. Only `next_file` to the next File in a RemoteReview arms the prefetch of one successor. |
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
- Hit: a Visible Action whose File content is present when the Action starts, so no `enrich_file` command starts for it.
- Added delay: the latency of a Visible Action sample with a refetch, minus the hit median.
  The hit median is the median latency of the hit samples of the same Action kind.
  The median comes from the same run, PullRequest, and scenario.
  If no hit sample exists, the added delay is the full latency.

## Measurement method

### Benchmark PullRequests

The benchmark uses the five PullRequests in `pr-webapp` from the brief.

| PullRequest | State | Files | Reason |
| --- | --- | --- | --- |
| #14 | merged | 593 | Most Files and most changed lines |
| #545 | merged | 400 | Many Files with small changes |
| #1516 | open | 316 | Largest open PullRequest |
| #2119 | merged | 144 | Many changed lines in a mid-size File set |
| #1436 | merged | 83 | Most binary Files |

### The harness

Ticket 01 adds `src/benchmark/file_cache.zig` and the build step `zig build bench-file-cache`.
The command is `zig build bench-file-cache -- remote <repository> <pull-request-id> [options]`.
It resolves the Credential with `bbr.bitbucket.auth.resolve`, like `src/benchmark/file_acquisition.zig`.

The harness drives the real `Presentation` from `src/tui/presentation.zig`.
It sends each Action through `Presentation.dispatch`, as the Presentation tests do.
It executes each produced `OwnedCommand` through its own `presentation_runtime.CommandExecutor`.
For `enrich_file`, the executor makes the same `file_enrichment.enrichConcurrent` call as `presentationEnrichmentWorker`.
It runs File Enrichments concurrently, as `src/tui/app.zig` does.
For every other command kind that a scenario produces, it calls the production function that `src/tui/app.zig` calls.
It fails the run on a command kind that it does not support.
It uses the production Highlighter and `Configuration.default_highlight_max_file_bytes`.
It builds each Presentation Frame at a fixed geometry of 200 columns and 50 rows.
It paints no terminal.

The harness must not copy the prefetch, eviction, or Review Search acquisition policy.
These policies must come from the production code.
If a measurement needs a hook in production code, the hook must change no production behavior.
Ticket 01 then lists the hook and the reason under `## Completion`.

### Instrumentation points

- `MeasuringHttpClient` wraps `StdHttpClient.httpClient()` behind the `HttpClient` seam.
  It counts requests, `/src/` requests, `429` responses, and other failures.
  It records the latency of each request.
  It never stores a URL, a header, or a body.
- The executor records the start and the end of each `enrich_file` command.
  It records the File index, the `speculative` flag, and the `search_acquisition` flag.
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

Four of the five PullRequests are merged.
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
| S4 | First Review Search | Open Review Search with the configured query. | First-result and complete-result latency. |
| S5 | Query edits | In the open Overlay, add one character, remove it, then replace the query with a second query. | Three complete-result latencies. |
| S6 | Overlay reopen | Close Review Search, do 10 seeded File Jumps, and open Review Search with the same query. | One complete-result latency. |
| S7 | Session replacement | Run `refresh`, then do 20 seeded File Jumps to Files that the run admitted. Repeat three times. | 60 File Jumps. |
| S8 | Process restart | Destroy the Presentation and the `StdHttpClient`, then create new ones and load the Session. Do the S7 File Jumps. Repeat three times. | 60 File Jumps and the Candidate Session time. |

A File with only binary or unavailable sides takes part in File Jumps, but it never causes a fetch.
S4 complete-result latency also stands for the first Review Search after S7 or S8.
The restart Review Search added delay is the S4 complete-result latency minus the S6 complete-result latency.
This estimate is valid only when S6 had no refetch.

The default query is `return`, and the second query is `const`.
The options `--query` and `--second-query` replace them.
The output records only the query length.

### Request budget

Bitbucket limits `/2.0/repositories/*` requests to between 1,000 and 10,000 an hour for each user.
One full acquisition of #14 needs about 1,200 requests.

The harness keeps a log of its requests in the last hour.
Before each scenario, it estimates the requests as two for each File that the scenario can fetch.
It waits until the log and the estimate fit in `--hourly-request-budget`, which defaults to 900.
If the estimate alone exceeds the budget, it waits for an empty hour and then starts.
The harness never waits inside a measured span.
A `429` response stays in the data, because a reviewer would wait for it too.
The harness reports each `429` response.

The option `--scenarios` selects a subset, so a human can split a long run across sessions.
Every invocation prints the same header, so the results merge.

### Output

The harness prints one header line and one line for each scenario as `key=value` pairs, like `harness.run`.
The header holds the run label, the network label, the bbr commit, and the cache budget.
It also holds the PullRequest id, its state, and its File count.
The header also holds `probe_ms`, the median of five `getPullRequest` latencies before the chain.
Each scenario line holds these keys:

- `samples`, `hits`, `cold_fetches`, and `refetches`.
- `latency_median_ms` and `latency_p95_ms`.
- `added_delay_p95_ms`, computed over the samples with a refetch.
- `first_result_ms` and `complete_result_ms` for S4, S5, and S6.
- `requests`, `src_requests`, `failures`, and `rate_limited`.
- `peak_retained_bytes`, `retained_bytes`, `full_review_bytes`, and `peak_rss_bytes`.
- `cache_hit_rate`, which is hits divided by hits plus refetches. Cold fetches do not count.
- `low_samples=true` when the scenario has fewer than 20 samples with a refetch.

The p95 uses the nearest rank, like `harness.run`.
With fewer than 20 samples, the p95 is the maximum, and `low_samples=true` marks it.
The harness prints no File path, URL, source text, Comment text, or query text.

### Runs and network conditions

The baseline is two runs of all five PullRequests with the current default budget.
The two runs are on different days.
They also use different network conditions, for example a wired office network and a home network over VPN.
Each run records its network label and its `probe_ms`.
A PullRequest result with a failure other than a `429` is invalid, and the human runs that PullRequest again.

## Stop rule

A run shows a delay when one of these conditions is true for one PullRequest:

1. One scenario has `added_delay_p95_ms` above 300.
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
- An injected clock is the time seam for the request budget and the latency numbers.
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
- A File that a small budget evicts and that a File Jump revisits counts as one refetch.
- A File after `refresh` counts as a refetch.
- A File after the simulated restart counts as a refetch.
- With `--cache-max-bytes 0`, S2, S3, S5, and S6 have no refetch.

Scenarios on `FakeHttpClient`:

- Each scenario runs to the end on a fixture with text, binary, added, and removed Files.
- S5 and S6 report refetches with a small budget and none with an unlimited budget.
- A fake `429` response counts in `rate_limited`, also when `RemoteBlobSource` retries it.
- The executor fails the run on an unsupported command kind.

Merged PullRequest check:

- A blob that matches its Hunks gives zero Hunk mismatch Files.
- A blob with one changed Hunk Line gives one Hunk mismatch File.

Request budget:

- The harness waits before a scenario when the hour log is full.
  It never waits inside a measured span.
- An estimate above the budget waits for an empty hour.

Containment:

- "M28 cache benchmark output holds no source, path, query, or Comment text".
  Sentinels in the fake blobs, paths, query, and Comment bodies never appear in the output.

Stop rule:

- Two runs with no delay give "No delay".
- Two runs with a delay give "Delay".
- One run with a delay gives "Inconclusive".
- One refetch in S5 or S6 is a delay, even with a low latency.

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
5. A `429` response stays in the latency data, because a reviewer waits for it too.
6. The sample floor: with fewer than 20 refetch samples, the p95 is the maximum, and the output marks it.
7. The disk cache location: the state home, as the M28 request names, not a new cache home.
8. The disk simulation uses random bytes of the same length, so no source content reaches the disk.
9. Conditional tickets: the spec describes them, and ticket 03 writes them only for the outcome "Delay".
