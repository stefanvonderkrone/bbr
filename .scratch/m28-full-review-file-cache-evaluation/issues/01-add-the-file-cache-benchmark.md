# 01: Add the File cache benchmark

Status: resolved
Blocked by: none
Spec: [M28 spec](../SPEC.md)

## What to build

A maintainer runs `zig build bench-file-cache -- remote <repository> <pull-request-id>`.
The benchmark drives the real Presentation through the scenarios S1 to S8 against live Bitbucket.
It prints one header line and one `key=value` line for each scenario.
The output holds only metadata and numbers.

Hermetic tests prove the statistics, the refetch classification, the request budget, and the containment on `FakeHttpClient`.
This ticket does not run the benchmark against Bitbucket.

## Scope

- Add `src/benchmark/file_cache.zig`.
  Follow the "Measurement method" section of the spec.
- Add the build step `bench-file-cache` in `build.zig`, like `bench-file-acquisition`.
  Use the `ReleaseFast` benchmark optimize mode.
- Add the test step `test-file-cache` with the filter `M28 cache`.
  Add the new tests to the `zig build test` import chain.
- Drive `Presentation` through `Presentation.dispatch`.
  Execute commands through a `presentation_runtime.CommandExecutor`.
  Run `enrich_file` through `file_enrichment.enrichConcurrent`, as `presentationEnrichmentWorker` does.
- Add `MeasuringHttpClient` behind the `HttpClient` seam.
  It counts requests, `/src/` requests, `429` responses, and failures, and it records latencies.
- Implement the scenarios S1 to S8, the merged PullRequest check, the request budget, and the output keys from the spec.
- Add the options `--cache-max-bytes`, `--dwell-ms`, `--seed`, `--query`, `--second-query`, `--hourly-request-budget`, `--run-label`, `--network-label`, and `--scenarios`.
  The defaults are 256 MiB, 1000, 28, `return`, `const`, 900, empty, empty, and all scenarios.
- Add a `summarize` mode that reads the output lines of two or three runs and prints the stop rule outcome.
  It prints `No delay`, `Delay`, or `Inconclusive`, and the scenarios that show a delay.
- Add the M28 rule from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
- Add `zig build bench-file-cache` to the "Tests" row of `docs/code-navigation.md`.

Do not change the cache policy, the prefetch, or Review Search acquisition.
If a measurement needs a production hook, the hook must change no production behavior.
List each hook and its reason under `## Completion`.

## Acceptance criteria

- [x] `zig build bench-file-cache` with no arguments prints the usage and exits with a failure.
- [x] The harness gets prefetch, eviction, and Review Search acquisition only from the production code.
- [x] The p95 of 1, 19, 20, and 100 samples matches the nearest rank in `harness.run`.
- [x] Fewer than 20 refetch samples print `low_samples=true`.
- [x] The added delay subtracts the hit median, and it is the full latency when no hit exists.
- [x] The cache hit rate excludes cold fetches.
- [x] A first fetch is a cold fetch.
- [x] A fetch after eviction, `refresh`, or the simulated restart is a refetch.
- [x] On `FakeHttpClient` with a small budget, S5 and S6 report refetches.
- [x] On `FakeHttpClient` with `--cache-max-bytes 0`, S2, S3, S5, and S6 report no refetch.
- [x] Every scenario runs to the end on a fixture with text, binary, added, and removed Files.
- [x] A fake `429` response counts in `rate_limited`, also after the `RemoteBlobSource` retry.
- [x] An unsupported command kind fails the run with a clear message.
- [x] A matching blob gives zero Hunk mismatch Files, and one changed Hunk Line gives one.
- [x] The request budget waits before a scenario when the hour log is full.
- [x] The request budget never waits inside a measured span.
- [x] The test "M28 cache benchmark output holds no source, path, query, or Comment text" passes.
      Every input of the test holds a sentinel.
- [x] `summarize` gives `No delay`, `Delay`, and `Inconclusive` for the three cases in the spec test plan.
- [x] `summarize` treats one refetch in S5 or S6 as a delay.
- [x] `AGENTS.md` has the M28 rule, and the named test exists with that exact name.
- [x] `tools/check_xdg_reads.py` passes, so the harness reads no XDG variable.

## Tests that prove it

- The `M28 cache` tests in `src/benchmark/file_cache.zig`.
- The existing test "File content cache evicts the least-recently-focused whole File and refetches it on revisit" in `src/tui/file_enrichment.zig` still passes.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-cache`
- `zig build test --summary all`
- `python3 tools/check_agent_docs.py`

## Completion

The commit that resolves this ticket is the commit with the subject "benchmark: add the M28 File cache benchmark".

### Changes

- `src/benchmark/file_cache.zig` holds the harness, the `summarize` mode, and the `M28 cache` tests.
- `src/benchmark_file_cache.zig` is the executable root. It creates the production `TreeSitterHighlighter` and passes the bbr version.
- `build.zig` adds the `bench-file-cache` step in `ReleaseFast` and the `test-file-cache` step with the filter `M28 cache`.
- `src/main.zig` adds the harness to the test import chain of `zig build test`.
- `src/benchmark/harness.zig` adds `p95Index`. `harness.run`, `harness.runSplit`, and the harness use it, so the nearest-rank rule has one owner.
- `AGENTS.md` adds the M28 containment rule and the scenario dependency rule.
- `docs/code-navigation.md` adds `zig build bench-file-cache` to the "Tests" row.

### Production hooks

None. The harness reads public Presentation fields, such as `published`, `commands`, and `issued_commands`.
The executor calls the same production functions as the `app.zig` workers.
The worker glue in the harness is a copy of the `app.zig` glue without the vaxis loop.
The executor switch has no `else` branch, so a new command kind fails the build.

### Choices

The spec does not answer these questions. The harness uses these choices.

1. `samples`, `hits`, `cold_fetches`, and `refetches` count Visible Actions. The S4 first result is a second latency of the same Visible Action.
2. A File Jump uses only the `enrich_file` commands for its target File. A Review Search uses all `enrich_file` commands in its span. A refetch wins over a cold fetch.
3. A File is admitted when one side has content.
4. A refetch that is faster than the hit median adds a delay of 0, not a negative delay.
5. `low_samples=true` also applies to a scenario with no refetch.
6. A `404` response is not a failure. The merged PullRequest check counts it as a `not_found` side. A `429` response counts in `rate_limited`.
7. The header key `bbr_version` holds the version identity, which holds the short commit hash and a `.dirty` mark.
8. The output also has `request_median_ms` and `request_p95_ms` on each scenario line. The header also has `dwell_ms`, `seed`, `query_bytes`, `second_query_bytes`, and `hourly_request_budget`.
9. The merged PullRequest check prints as one `check` line after the scenario lines.
10. S1 starts at the top and sends `next_file` until the File stops changing.
11. S2 jumps to at most 50 Files that the run focused before, oldest first. It skips the current File.
12. S5 adds `s`, removes it, and then replaces the query with Ctrl-K and the second query.
13. The 10 File Jumps in S6 are not samples. A reopened Overlay keeps its query.
14. S7 and S8 use the same seed over the admitted Files, so S8 repeats the S7 targets.
15. `candidate_session_ms` in S8 is the median of the three restart load times.
16. The request estimate counts only `/src/` requests. It does not count the Session loads in S7 and S8.
17. A label with a space or `=` fails. A query must have 1 to 64 bytes of UTF-8.
18. A `--scenarios` subset must keep its dependencies. S2 needs S1. S7 and S8 need S1 or S4. Without them, S2, S7, and S8 have almost no samples. `Options.requireDependencies` enforces this rule.

### Checks

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build bench-file-cache` with no arguments: prints the usage and exits with code 1.
- `zig build test-file-cache --summary all`: 20 of 20 tests pass. 16 are `M28 cache` tests.
- `zig build test --summary all`: 24 of 24 steps and all tests pass. The test count before this ticket was 1378.
- `python3 tools/check_agent_docs.py`: pass.
- `python3 tools/check_xdg_reads.py .`: pass.
- The containment test fails when the harness prints the Repository name. The dependency test fails when `parse` skips `requireDependencies`.

### Review

The runner reviewed the diff against the spec.
The review found that a `--scenarios` split can drop the scenario that S2, S7, or S8 depend on.
The runner added `Options.requireDependencies`, its test, and its rule in `AGENTS.md`.

### Not verified

No run used live Bitbucket. Ticket 02 makes the first live run.
The tests use the plain Highlighter and a fake clock, so their latencies are 0 ms.
