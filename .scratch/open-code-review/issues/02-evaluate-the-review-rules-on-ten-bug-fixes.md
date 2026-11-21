# Evaluate the review rules on ten bug fixes

Status: ready-for-agent
Blocked by: 01

## Problem

Nothing shows yet that the project rules find real defects in bbr, or that they find more than the built-in rules.

## Method

Use the ten newest bug fixes: `81787495`, `2e8ab1e7`, `9f285acb`, `3127762c`, `3ae9b944`, `f1e76906`, `1825dd0a`, `8c5770a6`, `e60b43c0`, and `1e809a19`.

1. For each fix, write down the expected finding before any run.
2. Find the commit that brought in the bug with `git blame` on the lines that the fix changes. When no commit clearly brought in the bug, mark the case `no clean origin` and skip it.
3. Review the origin commit in commit mode twice with the same model: once with the project rules, and once with `--rule` set to an empty rule list, which leaves only the built-in rules.
4. Count hits, misses, and false positives for each run.
5. As false-positive controls, review each fix commit and the refactor commit `c63780fe`.

## Acceptance criteria

- [ ] A results table lists each case with its expected finding, origin commit, and outcome for both rule sets.
- [ ] The table names the model of each run.
- [ ] Each rule that caused a false positive is changed or removed.

## Comments
