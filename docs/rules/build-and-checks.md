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

A line checker in `tools/` reads Zig source only through `zig_files` in `tools/source_lines.py`. `zig_files` reads each file and gives the checker the code lines of the file, without comments. A `//` inside a string literal stays. A checker that looks for a call, not for a name in a literal, passes `literals=False`. That option also empties each literal. A checker never reads a Zig file or splits its text itself, so raw Zig text never reaches it. A checker that reads no Zig code lines, such as `check_agent_docs.py` and `check_vendored_grammars.py`, goes in `NO_ZIG_SOURCE` with its reason. A checker that edits the raw source, such as `check_guard_mutations.py`, also goes there.

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

## Vendored Grammar checksums

Every vendored Grammar file under `vendors/tree-sitter/` has a checksum in `vendors/tree-sitter/manifest.zig.zon`. [ADR-0017](../adr/0017-builtin-grammar-queries-come-from-nvim-treesitter.md) gives the reasons for the vendored delivery.

Enforcement: `tools/check_vendored_grammars.py`, run by `zig build test`. It fails on a changed checksum and on a file that the manifest does not list. The tests in `tests/check_vendored_grammars_test.py`, run by `zig build test`, check the validator.

## Adapted queries in the build

The build compiles and embeds only files under `vendors/tree-sitter/<tag>/`. `vendors/tree-sitter/nvim-treesitter/queries/` holds the raw nvim-treesitter queries without changes. The build never reads them.

Enforcement: `tools/check_vendored_grammars.py`, run by `zig build test`. It fails when a manifest `.sources`, `.highlights`, `.injections`, or `.locals` path is outside `<tag>/`. The test `test_the_build_uses_no_raw_query` in `tests/check_vendored_grammars_test.py` checks this case.

## Query adaptation

An adapted query is the exact output of `tools/adapt_queries.py` from the raw nvim-treesitter queries. Every form that the adaptation removes leaves a `; bbr:` comment. An unknown predicate stops the adaptation. The adapted injection query of a host keeps only the Injections whose static Grammar name is a BuiltInGrammar. Thus a new BuiltInGrammar can make the query of a host stale. For each stale host query that the check names, run `tools/vendor_grammar.py` again for that host with `--injections`.

Enforcement: `tools/check_vendored_grammars.py`, run by `zig build test`. It adapts every query again and fails on a difference. The tests in `tests/adapt_queries_test.py`, run by `zig build test`, check the adaptation.

## BuiltInGrammar preparation

This rule governs `src/highlight/tree_sitter_highlighter.zig`, the module that links the vendored tree-sitter library behind the `Highlighter` seam of the core module. Every BuiltInGrammar query is valid. `TreeSitterHighlighter.init` prepares no query. `BuiltInPackages.get` prepares a BuiltInGrammar on its first use, under its mutex, and reuses it after that. A failed preparation fails only that highlight and keeps no entry. The next use tries again.

Enforcement: the `M27 grammar` and `M27 lazy` tests in `src/highlight/tree_sitter_highlighter.zig`, run by `zig build test`. The mutations `m27-lazy-reuse` and `m27-lazy-init` in `tools/check_guard_mutations.py` prove that these tests fail without the reuse and without the lazy start.

## BuiltInGrammar ABI

The ABI of every BuiltInGrammar lies in the range of the vendored tree-sitter runtime and equals the manifest `.abi`.

Enforcement: the test "M27 grammar every BuiltInGrammar ABI is compatible with the vendored runtime" in `src/highlight/tree_sitter_highlighter.zig`, run by `zig build test`.

## One manifest entry for each BuiltInGrammar

A new BuiltInGrammar is one entry in `vendors/tree-sitter/manifest.zig.zon` and one `BuiltInGrammar` tag in `src/highlight/grammar_match.zig`, in manifest order. The manifest `.matches` of the entry give its GrammarMatch row. The `inline else` arm of `grammarSource` in `src/highlight/tree_sitter_highlighter.zig` takes the language and the queries from the manifest entry.

Enforcement: the `comptime` block after `BuiltInGrammar` in `src/highlight/grammar_match.zig`. Its `@compileError` fails the build when the tags and the manifest entries differ in number, name, or order. The test "M27 grammar the GrammarMatch table equals the manifest" in `src/highlight/tree_sitter_highlighter.zig`, run by `zig build test`.

## Injection layers

Only BuiltInGrammars take part in Injection, as host and as injected Grammar. A UserGrammar never takes part. Injected Spans are ordered, relative to their line, and inside the ranges of their layer. A nested layer stays out of the gaps between the ranges of its parent layer. An `#offset!` that ends inside a UTF-8 sequence drops its Injection.

Enforcement: the `M27 injection` tests in `src/highlight/tree_sitter_highlighter.zig`, run by `zig build test`. The mutations `m27-parent-range-clip`, `m27-capture-clip`, and `m27-offset-utf8-boundary` in `tools/check_guard_mutations.py` prove that these tests fail without the range clips and the UTF-8 check.

## Injection cost

`mergeCaptureIntervals` in `src/highlight/tree_sitter_highlighter.zig` keeps the open intervals in a priority queue. The capture clip and the range clip use `overlappingRanges`. Thus a large injected region costs about as much as the same content without Injection.

Enforcement: the tests "M27 injection a large fenced Zig block costs about as much as the same Zig File", "M27 injection a combined PHP text layer costs about as much as the same HTML File", and "M27 injection merged Spans match the byte planes for random overlapping intervals" in `src/highlight/tree_sitter_highlighter.zig`, run by `zig build test`.

## Release archive notices

Each release archive holds exactly `bbr` and `THIRD_PARTY_NOTICES`. `tools/third_party_notices.py` writes the notices from `vendors/tree-sitter/manifest.zig.zon` and `vendors/regex-manifest.zig.zon`. A missing licence file stops the release. A Grammar without exactly one `LICENSE` entry in `.files` also stops the release. The notices do not hold the licences of the fetched Zig packages yet. Ticket 16 in `.scratch/m27-zig-builtin-grammar/issues/` tracks that gap.

Enforcement: `tests/third_party_notices_test.py`, run by `zig build test`. The release workflow `.github/workflows/release.yml` compares the file list of each archive with `bbr` and `THIRD_PARTY_NOTICES`.

## Guard mutations

A guard that a ticket adds has a test that fails without the guard. The guard has an entry in the `MUTATIONS` table of `tools/check_guard_mutations.py`. The entry holds the exact snippet of the guard, a weaker replacement, and the `zig build` step that must fail. A rule section that claims a test enforces a guard needs such an entry.

Enforcement: `python3 tools/check_guard_mutations.py`, which CI runs after `zig build test`. It fails when a mutation survives, when the build of a mutation stops before its tests run, and when a snippet does not match exactly once.
