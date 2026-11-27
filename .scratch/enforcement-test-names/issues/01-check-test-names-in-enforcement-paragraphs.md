# Check the test names in Enforcement paragraphs

Status: resolved
Blocked by: none

## Problem

An Enforcement paragraph in `docs/rules/*.md` names its tests in double quotes.
No check reads these names.
Agents left a stale name in a rule doc two times.
Commit `b75c930f` fixed one of them: `docs/rules/tui-state.md` still named a renamed test of the Review Search source scan rule.
A first check used a per-file lookup with a sentence and file search.
That check needed a new tokenizer fix in each of three review rounds.
The last review found three more gaps.

## Proposal

Extend `tools/check_doc_symbols.py`.
That checker already runs in `zig build test` and in CI.

- Each double-quoted text in an Enforcement paragraph of `docs/rules/*.md` must be equal to the name of a `test "..."` declaration.
- The declaration is in a `.zig` file under `src/` or `tests/`.
- The check compares the raw text of the Zig literal with the text of the doc. It does not decode Zig escapes.
- The check does not look for the file of the test.
- The check does not read a code span. A run of N backticks closes only on a run of N backticks.
- A curly double quote in an Enforcement paragraph fails. The check does not read single quotes and apostrophes.
- A quote that is not a test name, such as a CI step name, is a code span.
- Each error names the doc, the line, and the name, and tells the fix.

## Acceptance criteria

- [x] A test fails before the fix for a missing test name.
- [x] A test name that a different `.zig` file declares passes.
- [x] The check does not read a quote in a single-backtick or a multi-backtick code span.
- [x] A curly double quote fails, and the error says to use straight double quotes.
- [x] An apostrophe passes.
- [x] A CI step name in double quotes fails, and the current docs write step names as code spans.
- [x] The check fails on `docs/rules/tui-state.md` from `b75c930f^`.
- [x] One rule section in `docs/rules/build-and-checks.md` states the rule, with its Enforcement paragraph.
- [x] `zig build test` passes.

## Completion

Commits:

- `81b781b2` files this ticket.
- `6e7d5bb6` adds the red tests. Seven subtests failed before the fix.
- `52e422f4` adds the check to `tools/check_doc_symbols.py` and writes the CI step name of the test file suffix rule as a code span.
- `5ae35e81` adds the rule section "Test names in Enforcement paragraphs" to `docs/rules/build-and-checks.md`, a pointer in `docs/agents/rule-areas.md`, and a new CI step name.
- `e7ca833c` adds the red tests of the review: an unpaired quote, a wrapped name, and the curly quote message.
- `991aa1c7` fails an unpaired quote, matches a wrapped name, and updates the rule section.

Checks:

- `zig build test` exits with 0.
- `zig fmt --check src build.zig tests` passes.
- `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py .`, `python3 tools/check_diagnostics.py .`, and `python3 tools/check_doc_symbols.py .` pass.
- Each `tests/check_*_test.py` and `tests/source_lines_test.py` passes.
- On a copy of the repo with `docs/rules/tui-state.md` from `b75c930f^`, the checker exits with 1 and names the old test "M21 kernel Review Search retries a reopened query scan that cannot queue at the next event" on line 265.

Review:

- A readonly review found no high-severity bug.
- The fixes cover an unpaired quote, a name that wraps over two lines, tests for the raw compare, the fence end, and Enforcement text outside `docs/rules/`, and the prose of the rule section and the curly quote error.
- The rule section keeps the sentence about the file of the test, as the section "Compile claims in Enforcement paragraphs" does.
- The review flagged STE problems in the messages of commits that already exist. These commits stay as they are.
