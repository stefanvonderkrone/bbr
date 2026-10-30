# 08: Decide on a separate mark column

Status: ready-for-human
Blocked by: 07
Spec: [M30 spec](../SPEC.md)

## What to decide

The user tests the Scroll Marks in the track by hand.
The user then decides whether bbr also needs a separate mark column next to the DiffPane scroll bar.
Decision 5 of the [M30 brief](../brief.md) asks for this checkpoint.

## Steps

1. Read the notes from ticket 07 on how readable the marks are in a crowded track.
2. Review a long PullRequest for at least one session with the Scroll Marks in the track.
3. Check whether the thumb style hides the mark kinds too much on thumb cells.
4. Check whether File header marks crowd out the border on a PullRequest with many Files.
5. Choose one answer:
   - Keep the track marks only.
   - Add the mark column.
   - Change the track marks, for example the glyphs or the priority, without a column.

## If the user selects the column

The column takes one DiffPane content column left of the border scroll bar.
The layout tree always declares that column while it is enabled.
So the geometry does not change between hit testing and paint.
A new implementation ticket in this directory describes the column work.
That ticket names its enforcing tests and the AGENTS.md rule changes.
No column work starts without that ticket.

## Acceptance criteria

- [ ] The user records the answer and the reason under `## Answer` in this ticket.
- [ ] If the user selects the column, a new implementation ticket exists, and the spec links it.
- [ ] If the user changes the track marks, a new implementation ticket describes the change.
- [ ] If the user keeps the track marks only, `TODO.md` records that M30 needs no mark column.
- [ ] `python3 tools/check_agent_docs.py` passes after the change.
