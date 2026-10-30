# 07: Run the live M30 outside check

Status: ready-for-human
Blocked by: 06
Spec: [M30 spec](../SPEC.md)

## What to build

A human proves M30 on the largest benchmark PullRequest from M28.
This check needs a Bitbucket Credential and a real terminal, so an agent cannot run it.

## Steps

Run each step in a terminal with 30 rows, then repeat it in a terminal with 80 rows.

1. Open `pr-webapp` #14, which has 593 Files.
2. Add at least two Drafts in Files far apart.
   Make sure that the PullRequest has at least one unresolved and one resolved Thread.
3. Pick five Scroll Marks of different kinds.
   For each one, press its track cell, and make sure that the DiffPane shows its Thread, Draft, or File header.
4. Type a Buffer Search query with hits in several Files.
   Pick three hit marks, and make sure that each one leads to a real hit.
5. Clear the query, and make sure that the hit marks go away.
6. Drag the DiffPane thumb from the top to the bottom.
   Make sure that the DiffPane reaches the first and the last row.
7. Drag the pointer past the bottom of the window and past the top.
   Make sure that the DiffPane pins at the last and the first row.
8. Drag the File Tree thumb from the top to the bottom.
9. Open Review Search with a common query, and drag its list thumb from the top to the bottom.
10. Isolate one long File with `o`, and make sure that the thumb and the marks cover only that File.
11. Switch to the SideBySide Layout and back, and make sure that the thumb follows.
12. Resize the terminal during a drag, and make sure that the drag goes on.
13. Scroll with the wheel, and make sure that the wheel works as before.

## Acceptance criteria

- [ ] Every checked mark leads to a real item of its kind, at 30 and at 80 rows.
- [ ] Every drag reaches the first and the last row of its scroll bar.
- [ ] A drag past the window edges pins the scroll at the end.
- [ ] The thumb and the marks follow File isolation, the Layout switch, and the resize.
- [ ] The wheel works as before.
- [ ] Notes on how readable the marks are in a crowded track are recorded for ticket 08.
- [ ] The results, the terminal sizes, and the bbr commit are recorded under `## Completion` in this ticket.
