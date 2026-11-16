# 13: Mark an outdated Thread in a collapsed group

Status: needs-triage
Blocked by: none
Spec: [M30 spec](../SPEC.md)
Source: [ticket 07, finding 3](07-run-the-live-m30-outside-check.md#findings)

## Problem

An outdated unresolved Thread in a collapsed Outdated group has no `●` Scroll Mark.
`scroll_marks.rowMarks` marks only a visible root ReviewCard and a resolved Thread disclosure.
On PullRequest A, only the one current Thread has a `●` mark, so the track hides the other unresolved Threads.

## What to decide

- Whether a hidden Thread gets a mark, and on which row: the row of the collapsed Outdated group is the likely choice.
- What a press on that mark does. It can move to the group row, or it can open the group and move to the Thread.
- Whether a resolved Thread inside a collapsed group needs the same treatment.

## Comments

### 2026-11-16 filed

The operator filed this ticket from finding 3 of the live M30 outside check.
