# Add a script that merges main into a milestone branch

Status: needs-triage
Blocked by: none

## Problem

The open milestone branches (M22, M24, M27, M28, M29, M30, M32) get `origin/main` merged in again and again. On November 2, 6, and 10, a coordinator session started one subagent for each branch, 21 subagents in total. The retro in session `ses_e38baeb9cffe00nhxrCe6jCmIf` (ranked finding 8) flagged this.

The 21 subagents made 674 tool calls with 2.65 million characters of output, about 32 calls and 126,000 characters per merge. No subagent prompt mentions a conflict. Each subagent did the same steps:

1. Loaded skills with `cat`, about 30,000 characters before any Git work.
2. Ran `git status`, `git fetch`, and `git merge --no-ff --no-commit origin/main`.
3. Read the diffs of `AGENTS.md`, `build.zig`, and `src/main.zig`, and counted the rules table rows by hand.
4. Built an isolated test environment: HOME and the XDG directories under `$TMPDIR`, the `BITBUCKET_*` variables unset, and the Zig package cache copied in. Then it ran `zig build test`, often twice.
5. Committed with a fixed message and reported.

Steps 2, 4, and 5 never change. The coordinator also repeats a long "live-environment ban" in each prompt, because the subagents must never start bbr against the real environment. An agent needs judgement only when the merge conflicts or a check fails.

## Proposal

Add a script, for example `tools/merge_main.py <worktree>`. Triage decides the name and the language.

- It refuses a checkout with tracked changes or a merge already in progress.
- It fetches `origin` and runs `git merge --no-ff --no-commit origin/main`.
- On a conflict, it stops and prints the conflicted files. It leaves the merge in progress for an agent or a human.
- It runs `zig build test` in an isolated environment: a temporary HOME and XDG directories, the `BITBUCKET_*` variables unset, and the Zig package cache available. Only this script builds that environment, so the live-environment ban becomes a property of the script, not a prompt rule.
- When the checks pass, it commits with a standard message that names the merged `origin/main` commit.
- When a check fails, it leaves the merge uncommitted and prints the failing step.
- It never pushes, rebases, stashes, or resets.
- It writes a short log that a coordinator can read: the branch, the merged commit, the result, and the check summary.
- A coordinator can run it for each milestone worktree in a loop, and start an agent only for the branches that conflict or fail.

## Related

Ticket 01 in `.scratch/agents-md-pointers/` on branch `agents-md-pointers` moves the rules table out of `AGENTS.md`. Every milestone branch edits that table, so it causes most of the merge work.

## Acceptance criteria

- [ ] The script merges `origin/main` into a clean milestone worktree, runs `zig build test` in the isolated environment, and commits when the checks pass.
- [ ] A worktree with tracked changes or a merge in progress makes the script exit with an error, and it changes nothing.
- [ ] A conflict makes the script stop with the conflicted files listed and the merge left in progress.
- [ ] A failing check leaves the merge uncommitted and names the failing step.
- [ ] The test run gets no `BITBUCKET_*` variable and no real HOME or XDG directory. A test proves this.
- [ ] The script never pushes.
- [ ] `docs/agents/` names the script as the first step for "merge main into a branch".
- [ ] `zig build test` passes, with tests for the clean, conflict, dirty-checkout, and failing-check paths.
