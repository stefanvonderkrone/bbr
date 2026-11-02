# 10: Jump to the item of a pressed Scroll Mark

Status: needs-triage
Blocked by: 07
Spec: [M30 spec](../SPEC.md)

## What to decide

A press on a Scroll Mark off the thumb centers the first row of the pressed cell.
On a long Buffer, one track cell holds many rows.
So the marked item is often outside the visible rows after the press.

The review finding M30-3 measured this with a model of `view.cellFirstRow` and `pressScrollBar`:

| Track rows | Buffer rows | Rows per cell | Share of the cell that shows |
| --- | --- | --- | --- |
| 30 | 2,000 | 76 | 17.5 percent |
| 30 | 20,000 | 769 | 1.8 percent |
| 80 | 20,000 | 263 | 14.6 percent |
| 80 | 60,000 | 789 | 4.9 percent |

The SPEC puts "A press on a Scroll Mark that jumps to the item of the mark" under Out of Scope.
So M30 keeps the current press.
The user decides after ticket 07 whether a later milestone adds the jump.

## Possible change

When the pressed cell holds a Scroll Mark, the press scrolls to the first row of the winning item in that cell.
`scroll_marks.project` can return that row beside the mark kind.
A test presses a Draft mark on a Buffer with more than 20 rows per cell.
It expects the Draft header in the visible DiffPane rows.

## Acceptance criteria

- [ ] The user records the answer and the reason under `## Answer` in this ticket.
- [ ] If the user selects the jump, a new implementation ticket names its tests and its AGENTS.md rule change.
