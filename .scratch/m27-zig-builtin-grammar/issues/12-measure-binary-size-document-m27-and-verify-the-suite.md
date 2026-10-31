# 12: Measure the binary size, document M27, and verify the integrated suite

Status: resolved
Blocked by: 04, 05, 06, 07, 10, 11
Spec: [M27 spec](../SPEC.md)

## What to build

The binary size before and after M27 is recorded.
The glossary, the agent documents, the ADRs, and the README describe the shipped M27 behavior.
The integrated hermetic suite passes with every M27 test.

## Scope

- Measure the values from the "Binary size measurement" section of the spec.
  Write them to `.scratch/m27-zig-builtin-grammar/binary-size.md` and link that file under `## Completion`.
- Apply the glossary changes from the "Glossary changes" section of the spec to `src/highlight/GLOSSARY.md`.
- Add `docs/adr/0014-builtin-grammar-queries-come-from-nvim-treesitter.md` with the decisions from the "ADRs" section of the spec.
- Add the six M27 rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
  Make sure that each named test and check exists with that exact name.
- Name the vendoring tools and Injection in `docs/code-navigation.md`.
- Add a BuiltInGrammar list with the GrammarMatch rules to `README.md`, near "Manage UserGrammars".
  State that an active UserGrammar takes precedence and that Injection uses only BuiltInGrammars.
- Update `FEATURES.md` for the new BuiltInGrammars.
- Check each M27 line in `TODO.md` that the evidence proves.
- Run the integrated checks and record the results under `## Completion`.

## Acceptance criteria

- [x] `binary-size.md` records the host, the toolchain, both commits, both build modes, the `size` output, the build time, the `TreeSitterHighlighter.init` time, and the bench results.
- [x] No Grammar is dropped for size.
- [x] The glossary entries match the spec and use the glossary terms exactly.
- [x] ADR-0014 exists and states its relation to ADR-0009.
- [x] `AGENTS.md` has the six M27 rules, and each named test and check exists.
- [x] `README.md` lists every BuiltInGrammar with its GrammarMatch rules.
- [x] `vendors/tree-sitter/README.md` describes the procedure, the generated Swift parser, and the licences.
- [x] `python3 tools/check_agent_docs.py` passes.
- [x] `zig fmt --check build.zig src`, `zig build`, and `zig build test-builtin-grammars` pass.
- [x] `python3 tools/check_vendored_grammars.py .` and `python3 tests/adapt_queries_test.py` pass.
- [x] `zig build test --summary all` passes, and the reported test count is higher than before M27.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build -Doptimize=ReleaseSafe`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `python3 tests/adapt_queries_test.py`
- `zig build test --summary all`

## Completion

The changes are uncommitted.
The runner reviews and commits them.
The code review is the runner's review.

### Binary size

[binary-size.md](../binary-size.md) records the method, every run, and the limiters.
The before build is `4cb5365`, and the after build is `c65a2f9`.
The host is an Apple M5 Pro with macOS 26.7.1 and Zig 0.16.0.

| Value | Before | After |
| --- | --- | --- |
| `zig-out/bin/bbr` bytes, Debug | 38,096,224 | 87,445,520 |
| `zig-out/bin/bbr` bytes, ReleaseSafe | 12,980,144 | 57,526,080 |
| Clean ReleaseSafe build, median of 3 | 64.45 s | 66.90 s |
| `TreeSitterHighlighter.init`, ReleaseSafe, median of 5 processes | 28.3 ms | 422.2 ms |

- The parse tables of the new Grammars in `__TEXT,__const` explain more than 99% of the `__TEXT` growth.
  SQL alone is 26% of the growth.
- `ts_query_new` explains the `init` growth.
  C++, Swift, and C# take 48% of the `init` time.
- Each M13 highlight benchmark changed by less than 1.5%, with the same output checksum.
- No Grammar is dropped for size.

`src/main.zig` calls `TreeSitterHighlighter.init` before the TUI starts.
So the ReleaseSafe bbr starts about 0.39 s later than before M27.
The SPEC puts lazy query preparation out of scope, so this ticket records the cost and changes nothing.

### Change summary

- `src/highlight/GLOSSARY.md`: the BuiltInGrammar set after M27, `markdown_inline`, the new term Injection, and the Capture and GrammarMatch additions from the SPEC.
- `docs/adr/0014-builtin-grammar-queries-come-from-nvim-treesitter.md` (new): the SPEC decisions, stated as a refinement of ADR-0009.
- `AGENTS.md`: seven new rules.
  These are the six SPEC rules and one rule for the vendoring direction.
  The rule for a new BuiltInGrammar names the manifest entry and the tag, as ticket 03 shipped it.
  The adapted-query rule says that a new BuiltInGrammar can make a host injection query stale.
  The glyph rule now also names `tests/check_box_glyphs_test.py`.
- `build.zig`: the new step `test-python` runs five Python test files, and `zig build test` depends on it.
  The files are `tests/adapt_queries_test.py`, `tests/check_agent_docs_test.py`, `tests/check_box_glyphs_test.py`, `tests/check_vendored_grammars_test.py`, and `tests/verify_bbr_control_test.py`.
  Before this ticket, `zig build test` ran only the first and the fourth.
- `tools/check_vendored_grammars.py`: the check fails when a manifest `.sources`, `.highlights`, `.injections`, or `.locals` path is outside `<tag>/`.
  The new test `test_the_build_uses_no_raw_query` in `tests/check_vendored_grammars_test.py` covers it.
- `docs/code-navigation.md`: entry points for BuiltInGrammars and GrammarMatch, Injection, and the vendoring tools, and the `test-python` and `test-builtin-grammars` steps.
- `README.md`: the section "BuiltInGrammars" before "Manage UserGrammars".
  It lists every BuiltInGrammar with its GrammarMatch rules, the Injections, the UserGrammar precedence, and that Injection uses only BuiltInGrammars.
- `vendors/tree-sitter/README.md`: the sections "Licences" and "Generated parser.c", the vendoring direction, and the new check case.
  The recipe says that the build compiles the adapted copy in `vendors/tree-sitter/<tag>/queries/`.
- `FEATURES.md`: the M27 feature line.
- `TODO.md`: all 8 M27 lines are checked.

### Proof of the Python test wiring

A temporary `self.fail("M27 wiring proof")` in `tests/check_box_glyphs_test.py` made `zig build test --summary all` fail.
The summary was `28/31 steps succeeded (1 failed); 1465/1465 tests passed`, and the failed command was `python3 .../tests/check_box_glyphs_test.py`.
The file was restored from a copy, and `git diff tests/check_box_glyphs_test.py` is empty.

A removed direction check in a copy of `tools/check_vendored_grammars.py` made `test_the_build_uses_no_raw_query` fail.
The tool was restored from a copy.

### Checks

| Command | Result |
| --- | --- |
| `python3 tools/check_agent_docs.py` | Pass. |
| `zig fmt --check build.zig src` | Pass. |
| `zig build` | Pass. |
| `zig build -Doptimize=ReleaseSafe` | Pass. |
| `zig build test-builtin-grammars --summary all` | 7/7 steps succeeded. 90/90 tests passed. |
| `python3 tools/check_vendored_grammars.py .` | Pass. |
| `python3 tests/adapt_queries_test.py` | 24 tests, OK. |
| `python3 tests/check_vendored_grammars_test.py` | 14 tests, OK. |
| `zig build test --summary all` | 31/31 steps succeeded. 1465/1465 tests passed. Before M27, 1378 tests passed. |

The `WorkerLaunchFailed` warnings in the test output also appear on green runs.

### Defaults chosen

- `zig build test` runs all five Python test files.
  Each file is hermetic and takes less than 0.3 s.
  `tests/check_agent_docs_test.py` also keeps its own CI step.
  The CLI tests stay in `test-cli`, which `zig build test` already runs.
- `TreeSitterHighlighter.init` has no permanent benchmark case.
  The `before` commit cannot run a new case, so the measurement used the same temporary patch on both sides.
- The highlight benchmarks use ReleaseFast, the default mode of `zig build bench`.
  The `init` time uses ReleaseSafe, as the SPEC asks.
- The new AGENTS rule for the build never generating or downloading a source is a convention (no check) for that half.
  No check builds offline. Ticket 07 proved one offline build.
- ADR-0014 keeps its number, although another unmerged branch also plans an ADR-0014.
- The spec stays `claimed`, because ticket 13 is `ready-for-human`.

### Changed paths

- `AGENTS.md`
- `FEATURES.md`
- `README.md`
- `TODO.md`
- `build.zig`
- `docs/adr/0014-builtin-grammar-queries-come-from-nvim-treesitter.md` (new)
- `docs/code-navigation.md`
- `src/highlight/GLOSSARY.md`
- `tests/check_vendored_grammars_test.py`
- `tools/check_vendored_grammars.py`
- `vendors/tree-sitter/README.md`
- `.scratch/m27-zig-builtin-grammar/binary-size.md` (new)
- `.scratch/m27-zig-builtin-grammar/SPEC.md`
- `.scratch/m27-zig-builtin-grammar/issues/12-measure-binary-size-document-m27-and-verify-the-suite.md`
