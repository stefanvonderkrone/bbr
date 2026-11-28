# Make each check message name its rule and its fix

Status: ready-for-agent
Blocked by: none

## Problem

After ticket 01, an implementing agent reads a rule doc only when its pointer fires. For the checked rules, the check output is then the main way that the agent learns the rule. When a message names only the failing line, the agent must find and read the rule doc to learn the fix.

Some checks already do this well. `tools/check_error_comparisons.py` names the replacement: a `switch` on the error with named prongs.

## Proposal

- Audit each `tools/check_*.py` and each compile-time rule check (`comptime` blocks, exhaustive switches with a rule comment).
- Make each failure message state the rule in one sentence, the fix, and the doc that explains it.
- Add one regression test for each message that changes, in the existing `tests/check_*_test.py` files.

## Acceptance criteria

- [ ] Each failure message of `tools/check_*.py` names the rule, the fix, and the rule doc.
- [ ] The audit lists each compile-time rule check with its message, or with the reason why a compile error cannot carry one.
- [ ] `zig build test` passes.

## Comments

### 2026-11-23 triage

- On 2026-11-23, 12 of the 14 `tools/check_*.py` name no rule doc in their messages. Only `check_agent_docs.py` and `check_doc_symbols.py` do.
- The tests in `tests/check_*_test.py` can assert the exact message text. A changed message then breaks such a test. Update the test with the message in the same commit.
- The rule doc is the section in `docs/rules/` with its anchor, for example `docs/rules/diagnostics.md#a-task-gets-its-slot-by-pointer`.
