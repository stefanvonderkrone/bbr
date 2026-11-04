# 01: Rework the Browser into a Repository view and a PullRequest view

Status: needs-triage
Blocked by: none

## Finding

The operator found this need during the live M24 outside check, M24 ticket 07, on 2026-11-04.
The Workspace of the check has more than 300 Repositories.
An expanding list of all Repositories is hard to use at that size.

The operator moved this work to M25 on 2026-11-04.
M25 also plans the back Actions and the Browser sort and filter settings, so one milestone owns the Browser navigation.

## Current M24 behavior

- The M24 spec sorts by update time by default.
- `cycle_browser_sort` (`s`) switches between `.updated` and `.name` for the whole Browser.
- The Browser is one tree. Enter on a Repository row expands it in place.
- A Repository row shows the open-PullRequest count, or `?` before a load.
- The Browser has no search.

## Decisions

The operator gave these decisions on 2026-11-04.

### Repository view

1. The Repository list always sorts by display name, without regard to case.
2. The `s` Action and `cycle_browser_sort` go away.
3. A Repository row shows the display name on the left and `last updated YYYY-MM-DD` on the right.
4. A Repository row shows no PullRequest count and no `?`.
5. `/` filters the Repository list. The filter matches only Repository names, and it hides the rows that do not match.
6. Enter on a Repository opens the PullRequest view of that Repository. The Repository list does not expand in place.

### PullRequest view

7. The PullRequest view lists the PullRequests of one Repository, in update-time order.
8. `/` filters the PullRequest list and hides the rows that do not match. It matches the title, the Branch name, and the id, in that order of priority.
9. An Overlay filters the PullRequest list by state, by author, and by reviewer.
10. The state filter offers `OPEN`, `MERGED`, and `DECLINED`. It does not offer a "closed" state.
11. The PullRequest view opens with the state filter `OPEN`.
12. The author and reviewer filters are pick lists of the people in the loaded PullRequests.
13. A `SUPERSEDED` PullRequest shows under `DECLINED`.

## Open questions

1. Can the state, author, and reviewer filters be active at the same time?
2. Does the reviewer filter mean "is a reviewer", or "is a reviewer who has not approved yet"?
3. Which key opens the filter Overlay?
4. M25 decides the back navigation between the review Session, the PullRequest view, and the Repository view, together with its hierarchical back Actions.
5. Does the `bbr` startup on a branch with no open PullRequest open the PullRequest view of that Repository?
6. Does the Summary Cache still hold PullRequests, or only Repositories?

## Acceptance criteria

To be written in the M25 spec.

## Comments
