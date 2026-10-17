# Draft format interaction review

The agent created these unpublished fixtures through the Composer on 2026-10-16.
They belong to the agreed test PullRequest, https://bitbucket.org/check24/pr-webapp/pull-requests/2425.

- Review-level Draft TempId 44 has no parent.
- Draft Reply TempId 45 has Draft TempId 44 as its parent.
- Both Drafts remain unpublished with `state_kind = 0`.

Both bodies reuse the [published format body](../published-formats-2026-10-15/body.md) with these exact changes:

1. Replace the first line with `M23 Draft format review. Agent-authored unpublished test example.`
2. Replace the case labels `P01` through `P16` with `Q01` through `Q16`.
3. Omit the final newline after the closing fence.

The agent compared both stored bodies with the exact Composer paste buffer through read-only SQLite queries.
Both bodies matched all 2,362 bytes.
The comparison also confirmed the parent identity and unpublished state.
These are local project fixtures, not Cloud observations.

## Catppuccin Mocha check

The agent expanded both bodies at 150 columns by 55 rows.
Selection starts at the root's Q01 and extends through the Reply's Q16 code row.
Buffer Search uses query `a`, as in the approved published-body check.
The human must check readability with Selection and after clearing Selection.
The human approved both Draft bodies with "looks good".

## Light Theme check

The agent restored the same Selection and query `a` across both Draft bodies in the light Theme.
The human approved this check with "looks good".
The system Theme check remains pending.

## System Theme loading blocker

bbr remained on `Loading PR #2425…` during two system-Theme launches.
The agent closed the first Session normally and retried once.
A direct `get-pull-request` read for the same Workspace, Repository, and PullRequest returned `Forbidden`.
The public Bitbucket API endpoint remained reachable.
The system Theme review cannot continue until PullRequest access works again.
This loading failure does not establish a Theme presentation failure.

The human requested another attempt.
The same direct PullRequest read succeeded on retry.
The agent restarted bbr in the system Theme and restored both expanded Draft bodies with Selection and query `a`.
Human approval of the system Theme check remains pending.

The human approved the system Theme check with "looks good".
The combined Draft and Draft Reply Selection and search review now passes in Catppuccin Mocha, light, and system Themes.
