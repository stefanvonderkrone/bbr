# 09: Make Sidebar Motions visible while the Comment Overview shows

Status: needs-triage
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## Problem

On every File Tree entry, `g g`, `G`, and the row scroll keys move the DiffPane cursor or scroll.
They do not move the File Tree cursor.
While the Comment Overview shows, the DiffPane is hidden.
So these keys change nothing that the reviewer sees from the Sidebar.

Review finding M29-6 reported this only for the "All Files" root entry.
The fix in commit `c20f84f` gives the root entry the same Actions as a File entry.
A probe test showed that `G` on a File entry also leaves the File Tree cursor in place.
So the root entry now matches the File entries, and the gap affects every entry.

## Question for triage

Choose one behavior for Sidebar Motions while the Comment Overview shows:

- Move the File Tree cursor, and so the File Tree Filter.
- Move the Overview selection.
- Keep the current behavior, which moves the hidden DiffPane.

The brief and the SPEC do not decide this.
