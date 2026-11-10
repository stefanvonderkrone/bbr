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

## Decisions

The operator answered on 2026-11-10.

1. An entry uses the row budget of the DiffPane, with the `[...] (enter to expand)` disclosure.
2. The first line inside the card, before the body, names the anchor context, such as the path and the line. It uses a dimmer text color than the body.
3. A context entry, the dim parent that the Comment Overview shows above a matching Reply, shows as a full card in a dim style.
4. Enter on the `[...] (enter to expand)` row or on the bottom border below it expands the card in the Comment Overview. Enter on every other row of the entry opens the DiffPane at the ReviewCard.
5. The query highlights its matches in the card body, as Buffer Search does.

## Open questions

1. Does the expanded state of a card in the Comment Overview stay separate from the DiffPane disclosure state? The runner proposes yes.

## Comments
