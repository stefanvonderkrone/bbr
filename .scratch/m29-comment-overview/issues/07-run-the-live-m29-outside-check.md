# 07: Run the live M29 outside check

Status: ready-for-human
Blocked by: 06
Spec: [M29 spec](../SPEC.md)

## What to build

A human proves M29 on a real PullRequest and on a LocalReview.
This check needs a Bitbucket Credential and a PullRequest with many Threads, so an agent cannot run it.

## Steps

RemoteReview:

1. Open a PullRequest with Review-level, File-level, and inline Threads across several Files.
   It also needs at least one resolved Thread and one Reply to a Reply.
2. Add one Draft Reply and one Review-level Draft.
3. Press `g o`.
   Count the Overview Entries without filters.
4. Count the Comments in the Bitbucket web UI, and add the number of Drafts.
   Compare the two counts.
5. Turn on `u`, `d`, and `a` one at a time.
   Make sure that each result matches the Bitbucket web UI and your Drafts.
6. Type a query with an author name, then with a word from a body, then with a path.
7. Move the File Tree cursor over a File, a Directory, and the root entry.
8. Press `o`, and make sure that the newest Thread comes first.
9. Press Enter on an inline entry, on a resolved Thread entry, and on a Review-level entry.
   Make sure that the cursor lands on each ReviewCard.
10. Switch with `g o` and `g d` several times.
    Make sure that each view keeps its cursor, scroll, query, and filters.
11. Open Review Search with `g f`, and open a Review-level result.
    Make sure that the Comment Overview shows with the item selected.
12. Press `R`, and make sure that the DiffPane shows with a fresh Comment Overview.

LocalReview:

1. Open a LocalReview with `bbr local` and at least three Drafts in two Files.
2. Press `g o`, and turn on `a`.
   Make sure that every Draft shows.
3. Press Enter on each Draft, and make sure that the cursor lands on its ReviewCard.

## Acceptance criteria

- [ ] The RemoteReview count matches the Bitbucket web UI count plus the Drafts.
- [ ] Each toggle, the query, and the File Tree Filter give the expected entries.
- [ ] Newest first puts the newest Thread at the top.
- [ ] Each Enter lands on the right ReviewCard, also for a collapsed resolved Thread.
- [ ] Each view keeps its state across several switches.
- [ ] The Review Search route selects the Review-level item in the Comment Overview.
- [ ] `R` shows the DiffPane and resets the Comment Overview.
- [ ] On the LocalReview, mine only shows every Draft.
- [ ] The results, the PullRequest, and the bbr commit are recorded under `## Completion` in this ticket.
