# 02: Clear the Review Search input with Ctrl-U

Status: needs-triage
Blocked by: none
Source: [M30 ticket 07, finding 5](../../m30-viewer-scrollbars/issues/07-run-the-live-m30-outside-check.md#findings)

## Problem

`Ctrl-U` does not clear the Review Search input.
In a shell and in many terminal inputs, `Ctrl-U` deletes the text before the cursor.
[Ticket 01](01-clear-an-accepted-buffer-search-query.md) reports that `Ctrl-U` in the Buffer Search input repeats the accepted query.

## What to decide

- Whether `Ctrl-U` clears every text input of bbr, such as Review Search, Buffer Search, and the List Overlays, through one shared input handler.
- The help Overlay entry for it.

## Comments

### 2026-11-16 filed

The operator filed this ticket from finding 5 of the live M30 outside check.
