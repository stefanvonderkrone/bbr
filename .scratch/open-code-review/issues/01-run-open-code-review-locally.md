# Run Open Code Review locally in delegation mode

Status: resolved
Blocked by: none

## Problem

bbr has no automated review before a human reviews a change. CodeRabbit reviewed PR 1 to 40, and about 95% of its 168 inline findings led to a fix. Alibaba Open Code Review (`ocr`) selects the files of a diff and resolves review rules for each file. Its built-in Zig rule knows nothing about the thread model, the diagnostics rules, or the data layout of bbr.

## Decisions

- Delegation mode: `ocr delegate preview` and `ocr delegate rule` select the files and the rules. The OpenCode session reviews the diff with the `open-code-review-delegate` skill. No `ocr` provider and no API key are needed.
- The repository agent `ocr-review` in `opencode.jsonc` uses `anthropic/claude-sonnet-5-5` with no variant, so it runs at the default effort. A user or a plugin can change the model.
- The `ocr` CLI is the pinned release binary v1.14.0, checked against `sha256sum.txt`. It is not the npm package, because that package updates itself.
- `.opencodereview/rule.json` holds the project rules. Each Zig entry keeps the built-in `zig.md` through `merge_system_rule`. The rules put thread safety and data-oriented design first. Then come the CodeRabbit finding classes with real signal, and then the guards against known false positives.
- Docs must not drift. Markdown files are reviewed, and a code change makes the reviewer search the docs for stale text. `.scratch/` is excluded.
- No CI.

## Acceptance criteria

- [x] `ocr version` prints v1.14.0, and the binary matches the published SHA-256.
- [x] The `open-code-review-delegate` skill is in `.agents/skills/`, and `skills-lock.json` records it.
- [x] `ocr delegate rule` resolves the project rule for a TUI Zig file, a core Zig file, `build.zig`, a `tools/` Python file, and a doc.
- [x] `ocr delegate preview` excludes `vendors/` and `.scratch/`, and keeps `*_test.zig` and Markdown docs.
- [x] The `ocr-review` agent loads in OpenCode.
- [x] `python3 tools/check_agent_docs.py` passes.

## Completion

- Installed `ocr` v1.14.0 (`d29ca204`) from the `opencodereview-darwin-arm64` release asset to `~/.local/bin/ocr`. `shasum -a 256 -c sha256sum.txt --ignore-missing` printed `OK`.
- Added the `open-code-review-delegate` skill from `alibaba/open-code-review` `main` at `39515dca`, and its `skills-lock.json` entry with the version 1 folder hash. The lock now marks `code-review`, `implement`, and `implement-spec` as local skills, because the repo changed them in `b6c01307`.
- Added `.opencodereview/build_rules.py`, which writes `rule.json`.
- Added `docs/code-review.md` with a link from `docs/agents/tools.md`, and corrected the config file name in `docs/agents/tools.md` to `opencode.jsonc`.
- Added `.opencodereview/rule.json` with five entries: `src/tui/**/*.zig`, `src/**/*.zig`, `build.zig` and `build.zig.zon`, the Python files in `tools/` and `tests/`, and Markdown.
- Added the `ocr-review` subagent to `opencode.jsonc`.

Checks:

- `ocr delegate rule --format json` resolved the project pattern for `src/tui/presentation.zig`, `src/bitbucket/client.zig`, `build.zig`, `tools/check_diagnostics.py`, `docs/rules/tui-state.md`, and `src/tui/selected_version_hardening_test.zig`.
- `ocr delegate preview --format json --from 38445a9b~20 --to bb516b9c` listed 37 reviewable files. It excluded the 44 `.scratch/` files and two `.txt` baselines, and it kept the `tests/*.py` files and the Markdown docs.
- `opencode api get /api/agent` in this Worktree listed `ocr-review` as a subagent with model `anthropic/claude-sonnet-5-5`.
- `ocr delegate preview --format json -c 64a1edfb` excluded the `vendors/` files as `user_exclude`. `ocr delegate preview --format json -c e32ce2f4` kept `src/tui/selected_version_hardening_test.zig` and the `tests/*.py` files of that commit.
- `npx skills experimental_install --dry-run --frozen-lockfile` no longer lists `open-code-review-delegate` as a mismatch.
- The `ocr-review` subagent reviewed the uncommitted workspace changes on `anthropic/claude-sonnet-5-5` with 5 of 5 files covered. It reported two low findings: an unsourced npm claim in `docs/agents/tools.md` and the section numbers in the shared rule text. Both are fixed.
- `python3 tools/check_agent_docs.py` passed.
- `zig build test` exited with 0.

The changes are uncommitted.

## Comments
