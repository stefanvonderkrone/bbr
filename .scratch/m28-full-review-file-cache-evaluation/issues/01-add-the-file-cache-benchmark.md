# 01: Add the File cache benchmark

Status: ready-for-agent
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

- [ ] `zig build bench-file-cache` with no arguments prints the usage and exits with a failure.
- [ ] The harness gets prefetch, eviction, and Review Search acquisition only from the production code.
- [ ] The p95 of 1, 19, 20, and 100 samples matches the nearest rank in `harness.run`.
- [ ] Fewer than 20 refetch samples print `low_samples=true`.
- [ ] The added delay subtracts the hit median, and it is the full latency when no hit exists.
- [ ] The cache hit rate excludes cold fetches.
- [ ] A first fetch is a cold fetch.
- [ ] A fetch after eviction, `refresh`, or the simulated restart is a refetch.
- [ ] On `FakeHttpClient` with a small budget, S5 and S6 report refetches.
- [ ] On `FakeHttpClient` with `--cache-max-bytes 0`, S2, S3, S5, and S6 report no refetch.
- [ ] Every scenario runs to the end on a fixture with text, binary, added, and removed Files.
- [ ] A fake `429` response counts in `rate_limited`, also after the `RemoteBlobSource` retry.
- [ ] An unsupported command kind fails the run with a clear message.
- [ ] A matching blob gives zero Hunk mismatch Files, and one changed Hunk Line gives one.
- [ ] The request budget waits before a scenario when the hour log is full.
- [ ] The request budget never waits inside a measured span.
- [ ] The test "M28 cache benchmark output holds no source, path, query, or Comment text" passes.
      Every input of the test holds a sentinel.
- [ ] `summarize` gives `No delay`, `Delay`, and `Inconclusive` for the three cases in the spec test plan.
- [ ] `summarize` treats one refetch in S5 or S6 as a delay.
- [ ] `AGENTS.md` has the M28 rule, and the named test exists with that exact name.
- [ ] `tools/check_xdg_reads.py` passes, so the harness reads no XDG variable.

## Tests that prove it

- The `M28 cache` tests in `src/benchmark/file_cache.zig`.
- The existing test "File content cache evicts the least-recently-focused whole File and refetches it on revisit" in `src/tui/file_enrichment.zig` still passes.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-cache`
- `zig build test --summary all`
- `python3 tools/check_agent_docs.py`
