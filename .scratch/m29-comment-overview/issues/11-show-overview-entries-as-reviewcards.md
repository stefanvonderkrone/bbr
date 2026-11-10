# 11: Show Overview Entries as ReviewCards

Status: needs-triage
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## Finding

The operator asked for this change during the live M29 outside check, ticket 07, on 2026-11-10.

- Each Comment, Draft, and Reply in the Comment Overview must look as it does in the DiffPane.
- An entry has a rounded border and its Title in the top border.
- A Reply has the same indentation as in the DiffPane.
- The body text wraps automatically to the width of the Comment Overview.

## Current behavior

The spec defines an Overview Entry as one row of the Comment Overview.
The row shows the author and a part of the body, and it does not wrap.

## Open questions

1. Does an entry show the complete body, or a body with the row budget and the `[...] (enter to expand)` disclosure of the DiffPane?
2. Does an entry show the anchor context, such as the path and the line, in its Title or above the card?
3. Does a context entry, the dim parent of a matching entry, also show as a full card?
4. Does Enter on an entry still open the DiffPane, or does Enter on a collapsed card expand it in the Comment Overview?
5. Does the query highlight its matches in the card body, as Buffer Search does?

## Comments
