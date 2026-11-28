# Build and checks rules

This doc holds the checked rules for `build.zig`, `tools/`, `tests/`, the benchmarks, the libraries and system calls of the core module of `src/root.zig`, and the release publication. The parts that no check covers are in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

## Core module without libc

The core `bbr` module (`src/root.zig`) uses no libc. A macOS build links libc implicitly. Thus a libc call in core compiles on macOS and fails only on Linux. A test that needs a system call on Linux uses `std.os.linux`.

Enforcement: `zig build test` compiles the core tests for `x86_64-linux` on every host (`core-linux-tests` in `build.zig`).

## Release asset set

`tools/publish_release.py` publishes a release. Publication requires exactly four local target archives and `SHA256SUMS`. Every remote draft asset must have an expected name. The script reads all remote asset pages before the first write and again after the upload. The final asset names must match the expected set. A failed final check stops publication. The script rejects an unexpected asset, but it does not delete the asset.

Enforcement: `tests/publish_release_test.py`, run by `zig build test`.

## Latest release choice

The script chooses `--latest` from the final remote snapshot after the upload. Latest-release ordering compares only valid canonical `vYYYY.M.D-N` tags. An uncomparable latest tag permits publication with `--latest=false`. A malformed incoming release tag permits no publication.

Enforcement: `tests/publish_release_test.py`, run by `zig build test`.

## Benchmark cell metrics

A benchmark measures cells with the vaxis measurement that the app uses, `terminal_cell_metrics` in `src/tui/terminal_cell_metrics.zig`. The benchmark module exports it as `tui.terminal_cell_metrics`. `CellMetrics.bytes` counts one cell per byte. Thus a benchmark on it misses the grapheme cost that dominates a Buffer rebuild.

Enforcement: `tools/check_benchmark_metrics.py`, run by `zig build test`. It fails on `.bytes` or `CellMetrics.bytes` in `src/benchmark/` and `src/benchmark_buffer_search.zig`, and names the replacement. A `.bytes =` field initializer is not a match.

## Benchmark compilation in tests

`addBenchmark` in `build.zig` adds only the compile step to `test`.
The function calls `dependOn` on `test_step` and does not call `addRunArtifact`.
Direct `addExecutable` calls use the literal name `"bbr"` or `"grammar-cli-integration"`, or the identifier `name` inside `addBenchmark`.

Enforcement: `tools/check_benchmark_builds.py`, run by `zig build test`, rejects other names in direct `addExecutable` calls. It requires `addBenchmark` to call `dependOn` on `test_step` and rejects `addRunArtifact` calls in that function. The check reads only `build.zig`. It does not see an alias of `addExecutable` or reject run dependencies elsewhere. `tests/check_benchmark_builds_test.py` tests the check under `zig build test`.

## Test file suffixes

The suffix of a file name in `tests/` decides where the file runs. No list needs an update. The suffixes are:

- `*_cli_test.py` runs under `zig build test-cli`, with the built bbr as its argument. `zig build test` includes `zig build test-cli`.
- `*_ci_test.py` runs only in CI. Use it for a test that needs tmux, Neovim, or another tool that only CI installs.
- Every other `*_test.py` runs under `zig build test` with `python3`.
- `*_test.sh` runs under `zig build test` with `sh`.

Any other file in `tests/` is a support file and goes in `test_support_files` in `build.zig`.

Enforcement: `addTestScripts` in `build.zig` lists `tests/` when the build configures. `zig build test` fails on a file that fits no suffix and is not a support file. The CI step `Tests that need CI tools` runs `tests/*_ci_test.py` with a glob.

## Checker source lines

A line checker in `tools/` reads Zig source only through `zig_files` in `tools/source_lines.py`. `zig_files` reads each file and gives the checker the code lines of the file, without comments. A `//` inside a string literal stays. A checker that looks for a call, not for a name in a literal, passes `literals=False`. That option also empties each literal. A checker never reads a Zig file or splits its text itself, so raw Zig text never reaches it. A checker that reads no Zig source, such as `check_agent_docs.py`, goes in `NO_ZIG_SOURCE` with its reason.

Enforcement: `CheckersTest` in `tests/source_lines_test.py`, run by `zig build test`. It fails on each `tools/check_*.py` that calls `read_text(`, `read_bytes(`, `open(`, or `.splitlines()`, or that does not import `zig_files`. `MARKDOWN_READERS` exempts only the Markdown reader function of `check_doc_symbols.py` from the raw-read check.

## Code names in rule docs

A backticked dotted code name in `AGENTS.md`, `CODING_STANDARDS.md`, or `docs/rules/*.md` names current Zig code.
Each segment names an identifier in `src/`.
When the second-to-last segment names a struct, union, or enum, its body contains the final segment.
Use the full `std` prefix for standard library names.

Enforcement: `tools/check_doc_symbols.py` and `tests/check_doc_symbols_test.py` run under `zig build test`. CI also runs the checker directly. The checker skips fenced code blocks, file names, and names that start with `std`, `vaxis`, `zf`, or `c`. It skips the generic `error.X` placeholder. It drops a leading `bbr` or `tui` segment. Comments and string literals supply no identifiers. The checker does not see undotted names or names outside the listed docs. A name occurrence in a container body satisfies the check, even when that occurrence declares no member. The checker does not resolve imports or distinguish containers with the same name. A generic type is a function that returns a `struct`. The checker does not read it as a container. It checks the members of a generic type only as identifiers. The checker fails on a missing `AGENTS.md`, a missing `CODING_STANDARDS.md`, or an empty `docs/rules/`. It does not see a short `std` name whose segments all name identifiers in `src/`.

## Compile claims in Enforcement paragraphs

An Enforcement sentence in `docs/rules/` that claims a compile error names a mechanism that fails on the violation: a `comptime` assertion, an exhaustive switch, a `@compileError`, or a `tests/*_test.py` or `tests/*_test.sh` that compiles the violation.
A sentence that starts with "Its" or "Their" continues the sentence before it.
The check reads each whole Enforcement paragraph, up to the next blank line, and skips fenced examples.
A type that only lacks a way to write, such as a `const` pointer, a missing field, or a return type without an error union, is not such a mechanism, because a cast, a new field, or a `catch` compiles.

Enforcement: `tools/check_agent_docs.py` counts the sentences without a mechanism in each area doc and fails when a count differs from `tools/compile_claim_baseline.txt`. CI runs the check. The tests in `tests/check_agent_docs_test.py`, run by `zig build test`, reject the old return type claim of `ScanReviewSource.create` and the old `const` claim of the Session fields. The check reads the name of a mechanism, not what the mechanism fails on.

## Test names in Enforcement paragraphs

Each text in straight double quotes in an Enforcement paragraph of `docs/rules/*.md` is the name of a test.
The name is equal to the name of a `test "..."` declaration in a `.zig` file under `src/` or `tests/`.
Write other quoted text, such as a CI step name, as a code span.
Thus the check fails on a doc that names a renamed or deleted test.
It passes when another `.zig` file still declares a test with that name.

Enforcement: `tools/check_doc_symbols.py` and `tests/check_doc_symbols_test.py` run under `zig build test`. CI also runs the checker directly. The checker reads each paragraph that starts with `Enforcement:` up to the next blank line or fence. It skips fenced code blocks and code spans. It fails on a quoted name that no test declares, on an unpaired double quote, and on a curly double quote. It does not read single quotes. It compares the doc text with the raw text of the Zig literal and does not decode a Zig escape. A doc writes a backslash in a name as the Zig source writes it. A doc cannot cite a name with an escaped double quote. A doc also cannot cite a test whose name is not on the line of its `test` keyword. The checker does not check that the file that the paragraph names declares the test.

## CLI check environment

A CLI check under `zig build test-cli` gets no Credentials, Profile, or XDG home from the caller's environment. `build.zig` passes on only `PATH`, and the tools add a few locale and color variables. A check that needs Credentials, a Profile, or an XDG home sets them itself. Thus the check passes locally only when it also passes in CI. A script gets its environment from `cli_env` in `tests/cli_env.py`.

Enforcement: `build.zig` clears the environment of each `test-cli` run and sets `BBR_TEST_CLI=1`. `cli_env` exits without that marker, so a direct `python3 tests/...` run fails.

## File cache benchmark output

The File cache benchmark prints only metadata and numbers, never source text, File paths, query text, Comment text, or URLs. The Credential token never reaches its stdout, its stderr, or a run file.

Enforcement: the tests "M28 cache benchmark output holds no source, path, query, or Comment text" and "M28 cache the Credential token never reaches the output, the notes, or the run files" in `src/benchmark/file_cache.zig`, run by `zig build test`.

## File cache benchmark scenario subset

A `--scenarios` subset of the File cache benchmark keeps the scenarios that it depends on. S2 needs S1. S7 and S8 need S1 or S4.

Enforcement: `Options.requireDependencies` in `src/benchmark/file_cache.zig` rejects the subset and prints the usage. The test "M28 cache a scenario subset keeps the scenarios that it depends on", run by `zig build test`.

## File cache benchmark request window

The File cache benchmark keeps its request window in `<output-dir>/requests.log`. No rolling hour in that file holds more requests than the budget. A `429` response fills the window.

Enforcement: the tests "M28 cache the request window survives a restart and never exceeds the budget in any hour" and "M28 cache a 429 marks the request window full" in `src/benchmark/file_cache.zig`, run by `zig build test`.

## File cache benchmark File Jump hit

A File cache benchmark File Jump is a hit only when File Enrichment of its target File is terminal at the span start. A fetch in flight at the span start counts for the span. A fetch that the Presentation still queues at the span end also counts. A harness wait never counts as latency.

Enforcement: the tests "M28 cache a File Jump to a File whose fetch is still in flight is a fetch, not a hit", "M28 cache a File Jump whose fetch the Presentation still queues at the span end is a fetch, not a hit", and "M28 cache a harness wait inside a span is not latency" in `src/benchmark/file_cache.zig`, run by `zig build test`.

## File cache benchmark request estimate

The request estimate of a File cache benchmark scenario bounds its requests. It counts the production Enrichment Range at the fixed Frame for each File Jump and Session load, and the observed Session-load requests.

Enforcement: the test "M28 cache the request estimate bounds the requests of each scenario" in `src/benchmark/file_cache.zig`, run by `zig build test`. It fails when the estimate drops the Session-load requests.

## File cache benchmark retries and resume

The File cache benchmark retries a `GET` with full jitter backoff and waits at least the `Retry-After` time. After 8 attempts, it exits with code 1 and keeps the checkpoint. An attempt that gets no response times out, and the harness retries it.
A rerun resumes at the first unfinished segment. The selected scenarios among S1 to S6 form one segment. A rerun of a finished run sends no request.

Enforcement: the tests "M28 cache retries back off with full jitter up to the cap and honour Retry-After", "M28 cache a request that hangs times out and the harness retries it", "M28 cache gives up after 8 attempts and a rerun resumes at the first unfinished segment", "M28 cache a rerun of a finished run sends no request", and "M28 cache a failure inside S1 to S6 restarts that segment from S1" in `src/benchmark/file_cache.zig`, run by `zig build test`.

## File cache benchmark summary

The File cache benchmark `summarize` applies the stop rule only to complete runs. Each run needs a `check` line and S1 to S8 lines with `failures=0` for each PullRequest of the input. Otherwise it prints an `incomplete` line for each run and `outcome=Inconclusive scenarios=none`.
S4 starts with a process restart, so its Review Search acquires every File again, even when every File fits the budget. Stop rule 1 skips S4, and rule 3 (S4 minus S6 `complete_result_ms`) gives its added delay.

Enforcement: the tests "M28 cache summarize gives Inconclusive for a partial or failed run", "M28 cache S4 is a cold Review Search after a restart, also when every File fits the budget", and "M28 cache summarize applies rule 3, not rule 1, to the S4 restart Review Search" in `src/benchmark/file_cache.zig`, run by `zig build test`.

## File cache benchmark exit codes

A File cache benchmark failure exits with code 3 when a rerun fails in the same way, and with code 1 otherwise. Every error that the harness returns by name is in `NamedError` and has a class in `failureOf` in `src/benchmark/file_cache.zig`. An unnamed error, such as a full disk, exits with code 1. `tools/m28-baseline-run.sh` runs the binary that `zig build install-bench-file-cache` installs, because `zig build` exits with code 1 or 2 for any failed child. The script stops at once on code 3.

Enforcement: the exhaustive switch in `failureOf` (compile error for an unclassified name in `NamedError`). The tests "M28 cache a permanent failure exits with code 3 and a transient failure with code 1" and "M28 cache every error that the harness returns has a failure class" in `src/benchmark/file_cache.zig`. `zig build test` runs `bbr-file-cache-bench summarize` without files and expects exit code 3, so it fails when `main` in `src/benchmark_file_cache.zig` stops returning `exitCode`. `tests/m28_baseline_run_test.py`, run by `zig build test`, runs a copy of `tools/m28-baseline-run.sh` with a stub `zig` and checks the PullRequest file rules of the script.

## Live PullRequest ids stay out of the repository

A `.scratch/` document or an ADR in `docs/adr/` names no live PullRequest id outside inline code. It also names no id after `pr-webapp` or in a `remote` command, even in code. Live PullRequest ids and their statistics stay in a local file outside the repository, such as `pullrequests.txt` in the folder that holds the repository checkout. `tools/m28-baseline-run.sh` reads its ids from that file. A missing, empty, or malformed file stops the script before the build.

Enforcement: `tools/check_agent_docs.py`, run by CI. `PUBLIC_PULL_REQUESTS` in that file lists each public exception with a reason. The tests in `tests/check_agent_docs_test.py` and `tests/m28_baseline_run_test.py`, run by `zig build test`.
