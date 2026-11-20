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

## Test file suffixes

The suffix of a file name in `tests/` decides where the file runs. No list needs an update. The suffixes are:

- `*_cli_test.py` runs under `zig build test-cli`, with the built bbr as its argument. `zig build test` includes `zig build test-cli`.
- `*_ci_test.py` runs only in CI. Use it for a test that needs tmux, Neovim, or another tool that only CI installs.
- Every other `*_test.py` runs under `zig build test` with `python3`.
- `*_test.sh` runs under `zig build test` with `sh`.

Any other file in `tests/` is a support file and goes in `test_support_files` in `build.zig`.

Enforcement: `addTestScripts` in `build.zig` lists `tests/` when the build configures. `zig build test` fails on a file that fits no suffix and is not a support file. The CI step "Tests that need CI tools" runs `tests/*_ci_test.py` with a glob.

## Checker source lines

A line checker in `tools/` reads Zig source only through `zig_files` in `tools/source_lines.py`. `zig_files` reads each file and gives the checker the code lines of the file, without comments. A `//` inside a string literal stays. A checker that looks for a call, not for a name in a literal, passes `literals=False`. That option also empties each literal. A checker never reads a file or splits text itself, so raw text never reaches it. A checker that reads no Zig source, such as `check_agent_docs.py`, goes in `NO_ZIG_SOURCE` with its reason.

Enforcement: `CheckersTest` in `tests/source_lines_test.py`, run by `zig build test`. It fails on each `tools/check_*.py` that calls `read_text(`, `read_bytes(`, `open(`, or `.splitlines()`, or that does not import `zig_files`.

## Compile claims in Enforcement paragraphs

An Enforcement sentence in `docs/rules/` that claims a compile error names a mechanism that fails on the violation: a `comptime` assertion, an exhaustive switch, a `@compileError`, or a `tests/*_test.py` or `tests/*_test.sh` that compiles the violation.
A sentence that starts with "Its" or "Their" continues the sentence before it.
The check reads each whole Enforcement paragraph, up to the next blank line, and skips fenced examples.
A type that only lacks a way to write, such as a `const` pointer, a missing field, or a return type without an error union, is not such a mechanism, because a cast, a new field, or a `catch` compiles.

Enforcement: `tools/check_agent_docs.py` counts the sentences without a mechanism in each area doc and fails when a count differs from `tools/compile_claim_baseline.txt`. CI runs the check. The tests in `tests/check_agent_docs_test.py`, run by `zig build test`, reject the old return type claim of `ScanReviewSource.create` and the old `const` claim of the Session fields. The check reads the name of a mechanism, not what the mechanism fails on.

## CLI check environment

A CLI check under `zig build test-cli` gets no Credentials, Profile, or XDG home from the caller's environment. `build.zig` passes on only `PATH`, and the tools add a few locale and color variables. A check that needs Credentials, a Profile, or an XDG home sets them itself. Thus the check passes locally only when it also passes in CI. A script gets its environment from `cli_env` in `tests/cli_env.py`.

Enforcement: `build.zig` clears the environment of each `test-cli` run and sets `BBR_TEST_CLI=1`. `cli_env` exits without that marker, so a direct `python3 tests/...` run fails.

## Named schema migration steps

Every schema migration is one named `Step` in `SqliteStore.migrations` in `src/persist/sqlite_store.zig`. [ADR-0018](../adr/0018-a-schema-migration-step-has-a-name-that-the-store-records.md) gives the reasons. A new step appends one `Step`. Only the first `legacy_version` steps write `user_version`, which stops at 11. `migrateStep` runs each step in a `BEGIN IMMEDIATE` transaction. Inside it, `reconcile` records the names that a store from before named steps applied, and the step runs only when its name is not in `schema_steps`. A step has no `BEGIN`, `COMMIT`, or `user_version` of its own. `SqliteStore.open` sets the busy timeout before it migrates. A store that records every name opens without a write lock.

Enforcement: `stepError` in `src/persist/sqlite_store.zig` feeds a `@compileError` that fails the build on an empty, invalid, or repeated name, on a list without every legacy step, and on `COMMIT` or `user_version` in step SQL outside literals and comments. Its error names the step or its index, and the fix. The test "M22 read steps reject invalid names lists and migration-owned SQL at comptime" checks each case. A `BEGIN` in a step fails every open at runtime, because the step already runs in a transaction. The `M22 read` tests in `src/persist/sqlite_store.zig` check the `user_version` limit, steps from two branches, the reconcile of old stores, the open without a write lock, a step that another process applied, and the busy timeout. `tests/store_migration_race_cli_test.py`, run by `zig build test-cli`, starts four bbr processes at once on each new store and on each store in the old M22 shape. It expects every open to succeed and the names of a store that one bbr made. `zig build test` runs them.

## Migration test fixtures

A migration test that fakes a database at version 7 or later uses `downgradeTo` in `src/persist/sqlite_store.zig`. It undoes legacy steps and deletes their names from `schema_steps`. A test that fakes a store from before named steps also drops `schema_steps`. A fixture below version 7 applies the legacy step SQL and `user_version` directly, as `preTicketStore` does. Each legacy step has its inverse in `downgrades`.

Enforcement: the `comptime` block after `downgrades` in `src/persist/sqlite_store.zig` fails to compile when `SqliteStore.legacy_version` has no entry. `downgradeTo` fails with `error.SchemaVersionStale` when `migrate` ends at another version. The tests "v8 migration preserves every authored Draft field and lifecycle state" and "M22 read a version 10 database migrates to version 11, keeps its Drafts, and reopens once" call `downgradeTo`. `zig build test` runs them.

## Schema version in a CLI check

A CLI check that needs the current schema version or step names reads them from a store that the built bbr makes. It does not write the number or the names.

Enforcement: `tests/store_message_cli_test.py`, run by `zig build test-cli`, fakes a store with the version and step names of the reference store. It expects `schema_steps` as its only table after the run, so a stale name fails when a step creates a table.
