---
name: bbr
description: Bitbucket Cloud work via bbr api. Use when listing Workspaces, reading Repositories, reviewing PullRequests, reading diffs or file bytes, managing Comments, managing Tasks, checking Authenticated Account, checking Reviewer Verdict.
---

# bbr api — Bitbucket Cloud CLI

`bbr api` talks to Bitbucket Cloud REST (`api.bitbucket.org/2.0`) without the TUI. Use this skill for any Bitbucket work in another project. It assumes login already works.

## Install

Copy this folder to your agent skill dir, then restart the agent:

```sh
cp -r skills/bbr ~/.claude/skills/bbr
# or: cp -r skills/bbr .agents/skills/bbr
ls ~/.claude/skills/bbr/SKILL.md
```

## 1. Select scope

Use the Profile default Workspace. Add `--workspace SLUG` only for cross-Workspace work. Done when you name the Workspace source (default or flag).

On `MissingCredential`, stop and run `bbr login`. Never paste tokens into Comments or Tasks.

## 2. Pick verb

Read [VERBS.md](./VERBS.md) and pick one verb from the matching group. Done when you name one verb.

Groups: Workspaces, Repositories, PullRequests, Files, Comments, Tasks, Identity.

## 3. Run VERB --help first

Run `bbr api VERB --help` before first use with new flags. It prints options plus example and needs no login. Done when you quote the help example you follow.

Rules: `bbr api [--profile NAME] [--workspace SLUG] [--json] VERB [options]`. Globals go before or after the verb. All flags use long `--kebab-case`. No short flags.

## 4. Run with output rule

Add `--json` for scripts. Default prints human lines. `get-diff`, `get-compare-diff`, and `get-blob` print raw bytes; add `--out PATH` to save to file. Keep stdout clean for `--json`; errors go to stderr. Done when output matches the asked form.

## 5. Mutation guard

Reads run free. Writes need approval unless the user ordered the write: `create-comment`, `update-comment`, `delete-comment`, `resolve-comment`, `reopen-comment`, `create-task`, `update-task`, `delete-task`, `resolve-task`, `reopen-task`, `set-verdict`. Done when approval exists or the user ordered it.

Notes: `Resolve` closes without editing prose; `reopen` reverses it. A PullRequest Author cannot set a Reviewer Verdict on that PullRequest. `set-verdict` needs `--expected-source-commit`. Use `--body-file` or `--content-file` for long text. Get the UUID via `whoami` where needed.

## Keep current

`bbr api --help` lists verbs. `bbr api VERB --help` defines flags. Follow help on conflict. Use canonical terms: Workspace, Repository, PullRequest, Comment, Task, Reviewer Verdict, Authenticated Account.
