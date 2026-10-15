# Issue tracker: Local Markdown

Issues and PRDs for this repo live as Markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- State is recorded as a `Status:` line near the top of each issue file. Bold Markdown labels are also accepted.
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/`, creating the directory if needed.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or issue number directly.

If you need to find a ticket, set the search directory to `.scratch/` and use a relative pattern.
For example, use Glob with `path: <checkout>/.scratch` and one of these patterns:
`**/SPEC.md`, `**/PRD.md`, or `**/issues/*.md`.
Root-level Glob patterns such as `.scratch/**/*.md` can return no files even when the files exist.
Read the `.scratch/` directory before you treat an empty search result as an absent ticket.

For a feature, read its `map.md` and follow the links to its decisions and implementation tickets.
Use paths from the current checkout because a feature's files can differ between Worktrees.

## Wayfinding operations

Used by `/wayfinder`. The map is a file with one child file per ticket.

- **Map:** `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket:** `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records `research`, `prototype`, `grilling`, or `task`. The status is `open`, `claimed`, or `resolved`.
- **Blocking:** a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every listed file is `resolved`.
- **Frontier:** scan `.scratch/<effort>/issues/` for open, unblocked, unclaimed files; first by number wins.
- **Claim:** set `Status: claimed` and save before any work.
- **Resolve:** append the answer under `## Answer`, set `Status: resolved`, then append a context pointer to the map's Decisions-so-far.

## Implementation operations

Use the triage states in [Triage labels](triage-labels.md) before implementation.
The normal implementation path is `ready-for-agent` to `claimed` to `resolved`.
An implementation ticket has no `Type:` field, or has `Type: implementation`.

1. Read the spec, ticket, and blockers. A blocker is complete only when its status is `resolved`.
2. Claim an unblocked ticket by setting `Status: claimed` before editing code.
3. Add `Claimed by:` with a session identifier or Worktree path so another agent can identify the owner.
4. Build the ticket and run its required checks.
5. Complete the code review and address its findings.
6. Check each acceptance criterion that the evidence proves.
7. Add a `## Completion` section with the change summary, check commands and results, and review result.
8. Add commit references when commits exist. Otherwise, record the changed paths and state that the changes are uncommitted.
9. Set `Status: resolved` and remove `Claimed by:` only after all required criteria and checks pass.

If work stops, record the remaining work under `## Comments`.
Release the claim to `ready-for-agent`, `needs-info`, or `ready-for-human`, as appropriate.
Confirm that a previous owner stopped before taking over a claimed ticket.
Local file claims require one coordinator when several agents share a checkout.
Recheck the claim and blockers in the integration Worktree before starting parallel work.

New tickets must declare `Blocked by: none` or list local ticket numbers.
The existing `## Blocked by` section form is also accepted.
Blockers belong to the same feature directory and must form an acyclic graph.
Historical tickets can use `done` or `completed` as aliases for `resolved`.
New status changes use `resolved`.
Historical completion notes can remain in `## Answer`, `## Progress`, or `## Comments`.
New completions use `## Completion`.

## Spec completion

Each spec owns the implementation tickets in its feature directory by default.
If tickets live elsewhere, add `Implementation directory:` with a path relative to the spec's directory.
Decision tickets with a wayfinding `Type:` do not count as implementation tickets.

Use `Status: ready-for-agent` before implementation and `Status: claimed` while implementation is active.
After all implementation tickets resolve, check the integrated acceptance criteria and required checks.
Keep the spec `claimed` while those integrated checks and the final review are active.
Record the integrated check and review evidence under `## Completion`, then set `Status: resolved`.
If a spec has no implementation tickets, keep its status unchanged until implementation tickets exist.
When a resolved spec gains unfinished implementation work, reopen it as `ready-for-agent` or `claimed`.
Leave the decision map as the historical record of the design phase.

## Validate the tracker and agent documents

Run `python3 tools/check_agent_docs.py` after changes to agent documents or tracker metadata.
The check validates local Markdown file links, status values, blocker references, dependency cycles, and spec completion consistency.
It accepts historical metadata forms without rewriting their evidence.
