# Check the test names in Enforcement paragraphs

Status: ready-for-agent
Blocked by: none

## Problem

An Enforcement paragraph in `docs/rules/*.md` names its tests in double quotes.
No check reads these names.
Agents left a stale name in a rule doc two times.
Commit `b75c930f` fixed one of them: `docs/rules/tui-state.md` still named a renamed test of the Review Search source scan rule.
A first check owned a per-file lookup with a sentence and file search.
Over three review rounds, that check needed a new tokenizer fix in each round, and the last review found three more gaps.

## Proposal

Extend `tools/check_doc_symbols.py`, which already runs in `zig build test` and in CI.

- Each double-quoted text in an Enforcement paragraph of `docs/rules/*.md` must be equal to the name of a `test "..."` declaration in a `.zig` file under `src/` or `tests/`.
- The check compares the raw text of the Zig literal with the text of the doc. It does not decode Zig escapes.
- The check does not look for the file of the test.
- A code span is not read. A run of N backticks closes only on a run of N backticks.
- A curly double quote in an Enforcement paragraph fails. Single quotes and apostrophes are not read.
- A quote that is not a test name, such as a CI step name, is a code span.
- Each error names the doc, the line, and the name, and tells the fix.

## Acceptance criteria

- [ ] A test fails before the fix for a missing test name.
- [ ] A test name that a different `.zig` file declares passes.
- [ ] A quote in a single-backtick and in a multi-backtick code span is not read.
- [ ] A curly double quote fails, and the error says to use double quotes.
- [ ] An apostrophe passes.
- [ ] A CI step name in double quotes fails, and the current docs write step names as code spans.
- [ ] The check fails on `docs/rules/tui-state.md` from `b75c930f^`.
- [ ] One rule section in `docs/rules/build-and-checks.md` states the rule, with its Enforcement paragraph.
- [ ] `zig build test` passes.
