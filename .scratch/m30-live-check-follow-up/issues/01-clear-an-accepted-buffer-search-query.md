# 01: Clear an accepted Buffer Search query

Status: needs-triage
Blocked by: none
Source: [M30 ticket 07, finding 2](../../m30-viewer-scrollbars/issues/07-run-the-live-m30-outside-check.md#findings)

## Problem

No input clears an accepted Buffer Search query.
`/`, `Ctrl-U`, and `Enter` repeat the accepted query. `Esc` and a motion keep the highlights.
The hit Scroll Marks follow the highlights, as the M30 SPEC asks, so they stay too.
Only a query with no hits removes the marks and the highlights.

## What to decide

- Which input clears the query, its highlights, and its marks. Candidates are `Esc` in the DiffPane, an empty accepted query, or a separate Action such as `:noh` in Vim.
- Whether `n` and `N` still work after a clear, as in Vim, or need a new query.
- The help Overlay entry and the Keymap Action for it.

## Comments

### 2026-11-16 filed

The operator filed this ticket from finding 2 of the live M30 outside check.
