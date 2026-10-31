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

## Comments

### Runner notes for the human (2026-10-31)

Tickets 01 to 06 are resolved on the branch `m29-comment-overview`.
The hermetic suite passes: `zig build test --summary all` reports 1453/1453 tests.
The count before M29 was 1378.
No agent ran this check, because it needs a Bitbucket Credential and a real PullRequest.

Build and start:

```sh
cd /Volumes/Work/t3-code/m29-comment-overview
git log --oneline -1            # record this commit under ## Completion
zig build
bbr auth status                 # make sure that the Profile is valid
zig build run -- <PullRequest URL>
```

For the LocalReview part, run `zig build run -- local <base-ref> <source-ref>` in a Git repository with at least two changed Files.

Keys in the Comment Overview:

- `g o` shows the Comment Overview. `g d` shows the DiffPane.
- `/` edits the query. Enter keeps the query. Escape restores the query from before `/`.
- `u` is unresolved only, `d` is Drafts only, and `a` is mine only.
- `o` switches between Review order and newest first.
- Enter opens the selected entry in the DiffPane.
- Tab moves focus between the Sidebar and the Comment Overview.
- `g f` opens Review Search. The File Finder also works from the Comment Overview.

What to look for:

- The Title shows `Comment Overview <matches>/<records>`. Use `<records>` for step 4.
  `<records>` counts every Comment, Reply, and Draft that the DiffPane shows as a ReviewCard.
  A Draft in the `submitting` state is not counted.
- A dim entry is a context entry. It is the parent of a matching entry, and the Title count does not include it.
- The File Tree starts with "All Files" only while the Comment Overview shows.
  A File Tree cursor move narrows the list at once. Enter on a File moves focus to the Comment Overview and does not jump.
- The filter row is narrow at 80 columns. Its chips drop from the end, so the order chip can hide. Use a terminal of at least 100 columns, or check the order by the entry order.
- Newest first uses no timestamp, because Bitbucket Comments carry none in the Session. A Draft is newer than every Comment. A larger CommentId is newer.
  So "newest" means the Thread with the newest member by CommentId. Compare it with the web UI on that basis.
- When a Review Search route clears a filter, the status shows "Comment Overview filters cleared to show the entry".
- When an entry has no ReviewCard any more, the status shows "The entry is no longer in the Review".

Record under `## Completion`: the PullRequest URL, the commit hash, each count, and each step result.
If a step fails, write the step, the expected result, and the actual result under `## Comments`.
Then set this ticket to `resolved`, and set the M29 spec to `resolved`.
