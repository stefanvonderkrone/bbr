---
name: bbr
description: Bitbucket Cloud work through bbr api. Use for member UUID lookup by name, reviewer assignment, Branches, PullRequest creation, draft-to-ready updates, decline, commit lookup, and Reviewer Verdicts. Also use for Workspaces, Repositories, diffs, file bytes, Comments, Tasks, and the Authenticated Account.
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

Groups: Workspaces, Repositories, Branches, PullRequests, Files, Comments, Tasks, Identity.

## 3. Run VERB --help first

Run `bbr api VERB --help` before first use with new flags. It prints options plus example and needs no login. Done when you quote the help example you follow.

Rules: `bbr api [--profile NAME] [--workspace SLUG] [--json] VERB [options]`. Globals go before or after the verb. All flags use long `--kebab-case`. No short flags.

## 4. Run with output rule

Add `--json` for scripts. Default prints human lines. `get-diff`, `get-compare-diff`, and `get-blob` print raw bytes; add `--out PATH` to save to file. Keep stdout clean for `--json`; errors go to stderr. Done when output matches the asked form.

## 5. Mutation guard

Reads run free. Writes need approval unless the user ordered the write. The write commands are `create-branch`, `create-pull-request`, `update-pull-request`, `decline-pull-request`, `create-comment`, `update-comment`, `delete-comment`, `resolve-comment`, `reopen-comment`, `create-task`, `update-task`, `delete-task`, `resolve-task`, `reopen-task`, and `set-verdict`. Done when approval exists or the user ordered it.

`Resolve` closes without editing prose. `reopen` reverses it. A PullRequest Author cannot set a Reviewer Verdict on that PullRequest. `set-verdict` needs `--expected-source-commit`. Use `--body-file`, `--content-file`, or `--description-file` for long text. Use `whoami` for the Authenticated Account's UUID. For another account, follow the member lookup steps below.

Files supplied through `--description-file` must not exceed 1 MiB.

## Resolve a member name to a UUID

When the user names a reviewer or another account, resolve that name in the selected Workspace:

1. Run `bbr api search-workspace-members --help`.
2. Run `bbr api search-workspace-members --name 'Ada Lovelace' --json` with the user's name as the value.
   For several names in the same Workspace, use one command with repeated `--name` flags:
   `bbr api search-workspace-members --name 'Ada Lovelace' --name 'Grace Hopper' --json`.
   The command fetches the member list once for all names.
   If the request fails, report the error and stop this lookup.
3. Read the JSON array, which contains one group per supplied name in input order, including duplicate names.
   Each group contains `name` and `matches`. Each match contains `uuid`, `display_name`, and `nickname` directly.
   Use the complete matches without `--limit` to check for ambiguity.
   Apply these selection rules independently to each group:
   - For one result, use its UUID directly when the complete display name or nickname matches with only minor differences.
     Minor differences include casing, repeated spaces, umlaut spelling, or one character added, removed, or replaced.
     Treat `max mustermann` and `Max Mustermann` as the same name.
     Accept `jon doe` for `John Doe` when that query returns only this member.
     Accept `Jorg Muller` for `Jörg Müller` under the same condition.
   - For multiple results, ask the user to choose, even when one result matches exactly.
     Show each candidate's display name, nickname, and UUID.
   - For one result with larger differences or only a partial name match, ask the user to confirm that member.
4. If a group contains no matches, ask for a more complete name, nickname, or another Workspace.
   Search another Workspace only after the user selects it.
5. Pass the selected UUID to the command's existing `--reviewer` or `--uuid` option.
   Reviewer Verdict writes still use the Authenticated Account.

Done when a single result with only minor name differences or the user's selection supplies the UUID for the next command.

Search reads every member page before it ranks matches. It handles reversed name parts, omitted middle names, and small typos. German spelling forms are approximate matches, including `Jorg` for `Jörg` and `Mueller` for `Müller`. A complete spelling match ranks above a partial name match. Exact matches compare the complete display name or nickname, ignoring case differences and repeated spaces. A nickname match has no priority over another member's exact display-name match.

Use `list-workspace-members --json` to read the member directory without a name filter. Both commands need the `read:workspace:bitbucket` API token scope. Workspace membership does not prove Repository access.

## Branch and PullRequest workflow

Use `create-branch --name NAME --target REV` with a commit hash or an existing branch name as the target. Branch names exclude the `refs/heads/` prefix.

`create-pull-request` requires a title and a source branch. It creates a Ready PullRequest by default. Add `--draft true` for a Draft PullRequest. An omitted destination branch uses the Repository's main branch.

For a fork source, use `--source-repository WORKSPACE/SLUG` with `--source-branch NAME`. The selected Workspace and `--repository` identify the destination Repository.

Use `update-pull-request --draft false` to make a Draft PullRequest ready. Use `--draft true` to make it a draft. The command changes only supplied fields. An empty description clears the description.

Repeated `--reviewer UUID` options replace the complete reviewer list. `--clear-reviewers` sends an empty list. Omitted reviewers use Bitbucket defaults on creation and stay unchanged on update. Do not combine `--reviewer` with `--clear-reviewers`.

Approval uses `set-verdict --verdict approved` with the expected SourceCommit. `decline-pull-request` closes the PullRequest without merging. Decline is not a Reviewer Verdict.

## Commit lookup

`list-commit-pull-requests --commit HASH` lists PullRequests where Bitbucket reviewed the commit, including closed PullRequests. It follows pages by default. Use `--page`, `--pagelen`, `--no-follow`, and `--limit` to control the results.

The Pull Request Commit Links app must exist. Bitbucket installs it when someone selects `Go to pull request` on a commit's details page. Pending indexing fails with `PullRequestLinksIndexing`. Report the hint instead of treating that failure as an empty list. The command does not poll automatically. `NotFound` can also mean that links lack an index.

## Keep current

`bbr api --help` lists verbs. `bbr api VERB --help` defines flags. Follow help on conflict. Use the canonical terms Workspace, Workspace Member, Repository, Branch, PullRequest, Draft PullRequest, Ready PullRequest, Comment, Task, Reviewer Verdict, and Authenticated Account.
