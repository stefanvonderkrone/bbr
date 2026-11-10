# Read a PullRequest snapshot in one command

Status: needs-triage
Blocked by: none

## Problem

Agents check several related PullRequests for new review activity. One example is a split change with one PullRequest each in pr-pauschalvergleich, pr-deviced, and pr-webapp. The retro in session `ses_e38baeb9cffe00nhxrCe6jCmIf` (ranked finding 1) found four of these checks on November 5 and 6. Together they used 73 tool calls and returned about 196,000 characters.

In each check, the agent did the same steps:

- read the bbr skill, `VERBS.md`, and the `--help` of each verb
- wrote a Python collector around `bbr api ... --json`
- fetched the Comments, Tasks, and Reviewer Verdicts of each PullRequest
- separated root Comments from Replies by hand

Examples: the sessions "Fetch both PR comments", "Check split cluster findings", and "Check three split PRs".

## Proposal

Add a read-only `bbr api` verb that reads one or more PullRequests and prints one snapshot. The verb name is open for triage.

- The input is one or more Repository and PullRequest id pairs. The pairs can be in different Repositories of the same Workspace.
- For each PullRequest, the snapshot has:
  - the source commit (head) and the PullRequest state
  - each Thread: the root Comment, then its Replies in order
  - for each Comment: the id, author, CommentScope (`path:line`, File-level, or Review-level), outdated state, resolved state, and exact text
  - the Tasks with their state
  - the Reviewer Verdicts
- The verb follows all pages.
- When a fetch fails or stops early, the snapshot marks that PullRequest and that part as incomplete. It never shows a partial list as complete.
- The text output is compact. `--json` gives the complete structure.
- `--out PATH` saves the JSON snapshot for ticket 05.

## Relation to other tickets

Ticket 01 changes the text output of `list-comments`. Use the same Comment line format in both verbs.

## Acceptance criteria

- [ ] One command reads a snapshot of two or more PullRequests in different Repositories.
- [ ] The snapshot has the source commit, the Threads with root Comments and Replies, the Tasks, and the Reviewer Verdicts of each PullRequest.
- [ ] The Comment text is exactly the text that Bitbucket returns.
- [ ] A failed or partial page fetch marks the PullRequest as incomplete, and the command exits with a non-zero status.
- [ ] `--out PATH` writes the JSON snapshot.
- [ ] The verb sends no write request.
- [ ] `skills/bbr/VERBS.md` and the verb help describe the verb.
- [ ] `zig build test` passes.
