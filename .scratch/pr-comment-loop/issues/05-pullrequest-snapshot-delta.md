# Report the changes since a saved PullRequest snapshot

Status: needs-triage
Blocked by: 04

## Problem

Agents ask, again and again, "is there new feedback since my last check?" Today an agent fetches everything again and compares it with earlier output by hand, or it writes a script for the comparison. It must also keep new findings apart from replies that the team already wrote. This comes from ranked finding 1 of the retro in session `ses_e38baeb9cffe00nhxrCe6jCmIf`.

## Proposal

Let the snapshot verb from ticket 04 take a saved snapshot, for example `--since PATH`. It then reports only the changes for each PullRequest:

- new root Comments (new findings)
- new Replies, shown with their root Comment for context
- edited Comments, with the old and the new text
- Comments that someone resolved, reopened, or deleted, or that became outdated
- new Tasks and Tasks whose state changed
- changed Reviewer Verdicts
- a changed source commit

When there are no changes, the report says so in one line for each PullRequest. When the saved snapshot or the new snapshot is incomplete, the report says which parts it cannot compare.

## Acceptance criteria

- [ ] With a saved snapshot, the verb reports only the changes listed above, for each PullRequest.
- [ ] A report with no changes has one line for each PullRequest.
- [ ] An incomplete snapshot on either side makes the report name the parts it cannot compare. The report does not show those parts as unchanged.
- [ ] The report can also be written with `--json`.
- [ ] `skills/bbr/VERBS.md` and the verb help describe the option.
- [ ] `zig build test` passes.
