# 14: Fix the M27 review findings

Status: resolved
Blocked by: 12
Spec: [M27 spec](../SPEC.md)

## What to build

The adversarial review of 2026-10-31 found two major and six minor M27 problems.
It also found two cross-branch classes, X-5 and X-6, with M27 parts.
The branch merges `origin/main` first, then fixes each finding test first.

## Acceptance criteria

- [x] The branch merges `origin/main` with a merge commit, and the suite passes.
- [x] Each fixed finding has a test that fails on the code before the fix.
- [x] Each finding that stays open has evidence and a recorded decision.
- [x] The AGENTS.md rule table names only enforcement that exists.
- [x] `zig build test`, `zig fmt --check build.zig src tests`, and `python3 tools/check_agent_docs.py` pass.

## Completion

### Merge

- `da8743b` merges `origin/main` at `497c86f` (PR #16). Git reported no conflict.
- Main adds `src/tui/help.zig` and an exhaustive `keymap.helpSection`.
- M27 adds no Keymap Action and no Overlay. So no help section and no `help.fixed_sections` entry changed.
- The recipe `single-A-m27.remerge.diff` also shows a merge with no change.
- After the merge, `zig build test --summary all` gave 31/31 steps and 1506/1506 tests.

### Findings

| Finding | Result | Commit | Proof |
| --- | --- | --- | --- |
| M27-1 major, quadratic span merge | Fixed. `mergeCaptureIntervals` keeps the open intervals in a priority queue. | `3e2e555` | The test "M27 injection a large fenced Zig block costs about as much as the same Zig File" failed before the fix: Markdown 2775 ms, Zig 79 ms. The test "M27 injection merged Spans match the byte planes for random overlapping intervals" proves the same output. |
| M27-2 major, no licence text in release archives | Fixed. Each archive holds `bbr` and `THIRD_PARTY_NOTICES`. | `bed3aa5` | `tests/third_party_notices_test.py` failed with 5 failures before the generator existed. The release job checks the exact archive file list. |
| M27-3 minor, O(captures x ranges) clipping | Fixed. `overlappingRanges` uses two binary searches. | `c18c03d` | The test "M27 injection a combined PHP text layer costs about as much as the same HTML File" failed before the fix: PHP 3511 ms, HTML 399 ms. |
| M27-4 minor, no test for the parent range clip | Fixed with a test. | `f068b06` | The test "M27 injection a nested Injection stays out of the gaps between its parent layer ranges" fails under the mutation `if (true or parent.ranges.len == 0)`. |
| M27-5 minor, startup grows to about 420 ms | Open. The operator decides. | none | Ticket [15](15-decide-lazy-preparation-of-builtingrammar-queries.md) records the costs and the options. |
| M27-6 minor, combined Injection per parent layer | Open. The code follows the SPEC wording. | none | Ticket [13](13-compare-m27-captures-with-neovim-on-real-pullrequests.md) now asks the human to check this difference. |
| M27-7 minor, no test for the UTF-8 check on `#offset!` | Fixed with a test. | `ca18f74` | The test "M27 injection an offset that ends inside a UTF-8 sequence drops its Injection" fails when the `utf8Boundary` checks go. |
| M27-8 minor, one injected layer error removes all highlighting | Not fixed. No legitimate state reaches the error. | none | See the M27-8 evidence below. |
| X-5, M27 part | Fixed. The Injection row marks its unenforced sentence as a convention. New rows name only real checks. | this ticket | `python3 tools/check_guard_mutations.py` proves each named guard test. |
| X-6, M27 part | Fixed. `tools/check_guard_mutations.py` removes 8 M27 guards and expects a test failure for each. CI runs it. | `03329e8` | At the parent of `ca18f74` and at the parent of `f068b06`, the tool reported `SURVIVED`. At the tip, it reports `caught` for all 8. |

### M27-8 evidence

- The only production caller, `highlightBuiltIn`, passes no match limit. So the limit is the maximum `u32` value.
- `highlightWithQueryLimit` is the only caller with a real limit. It is test code and has no Injections.
- `ts_parser_parse_string` returns null only for a missing language, a cancellation, or a wasm scanner error. bbr sets none of these.
- `appendLayer` sorts and joins the ranges, so `ts_parser_set_included_ranges` cannot reject them.
- Each range boundary is a node boundary or a checked offset, so `checkedRange` cannot fail.
- A seeded fuzz run of 21,000 changed HTML, Markdown, and PHP inputs gave no failure.
- A skip for a failed layer would guard a state that cannot occur. If a production caller adds a match limit, add the skip then.

### Measurements

ReleaseSafe, fastest of 3 runs, Apple M5 Pro:

| Case | Before | After M27-1 | After M27-3 |
| --- | --- | --- | --- |
| `.zig`, 4000 and 16000 lines | 15 and 56 ms | 13 and 57 ms | 14 and 57 ms |
| `.md` fence, 4000 and 16000 lines | 533 and 8419 ms | 35 and 148 ms | 37 and 147 ms |
| PHP, 4000 and 16000 segments | 88 and 966 ms | 88 and 964 ms | 43 and 245 ms |

PHP still grows a little faster than linear.
The tree-sitter runtime causes this cost when it parses with many included ranges.
For 8000 to 32000 ranges, the parse of the HTML layer grows from 30 ms to 397 ms.
The query time and the merge time stay linear.

### Out of scope

- X-2, the Credential transport leaks on main. One owner fixes `StdHttpClient` on main.
- X-3, untrusted bytes in std and zigimg decoders. The M32 work owns it.
- The licences of the fetched Zig packages. Ticket [16](16-add-the-zig-package-licences-to-third-party-notices.md) records the gap.

### Checks

All checks ran on the tip with HOME and XDG under `$TMPDIR` and no `BITBUCKET_*` variables.

- `zig build test --summary all`: 32/32 steps succeeded, 1511/1511 tests passed.
- `zig fmt --check build.zig src tests`: pass.
- `python3 tools/check_agent_docs.py`: pass.
- `python3 tools/check_guard_mutations.py`: 8 of 8 mutations caught, 204 s on 18 cores, 1881 s of CPU time.
  On a 4-core CI runner, this step can take about 8 minutes. This number is an estimate.
- The two timing tests passed while 9 copies of the suite ran in parallel.
