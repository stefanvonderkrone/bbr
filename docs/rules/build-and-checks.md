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

Every benchmark executable uses `addBenchmark` in `build.zig`.
The function adds the compile step to the `test` step.
The `test` step does not run benchmarks.
Only the app `bbr` and the fixture `grammar-cli-integration` use a direct executable declaration outside `addBenchmark`.
Those declarations each fit on one line.

Enforcement: `tools/check_benchmark_builds.py`, run by `zig build test`, rejects other direct executable declarations outside `addBenchmark`. It checks the compile-only dependency in `addBenchmark` and requires each call to pass `test_step`. `tests/check_benchmark_builds_test.py` tests the check under `zig build test`.

## Test file suffixes

The suffix of a file name in `tests/` decides where the file runs. No list needs an update. The suffixes are:

- `*_cli_test.py` runs under `zig build test-cli`, with the built bbr as its argument. `zig build test` includes `zig build test-cli`.
- `*_ci_test.py` runs only in CI. Use it for a test that needs tmux, Neovim, or another tool that only CI installs.
- Every other `*_test.py` runs under `zig build test` with `python3`.
- `*_test.sh` runs under `zig build test` with `sh`.

Any other file in `tests/` is a support file and goes in `test_support_files` in `build.zig`.

Enforcement: `addTestScripts` in `build.zig` lists `tests/` when the build configures. `zig build test` fails on a file that fits no suffix and is not a support file. The CI step "Tests that need CI tools" runs `tests/*_ci_test.py` with a glob.

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

## CLI check environment

A CLI check under `zig build test-cli` gets no Credentials, Profile, or XDG home from the caller's environment. `build.zig` passes on only `PATH`, and the tools add a few locale and color variables. A check that needs Credentials, a Profile, or an XDG home sets them itself. Thus the check passes locally only when it also passes in CI. A script gets its environment from `cli_env` in `tests/cli_env.py`.

Enforcement: `build.zig` clears the environment of each `test-cli` run and sets `BBR_TEST_CLI=1`. `cli_env` exits without that marker, so a direct `python3 tests/...` run fails.
