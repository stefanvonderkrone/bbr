# 12: Enter on a hidden indicator sometimes does not expand

Status: needs-info
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## Summary

The live M29 outside check, ticket 07, found this on 2026-11-10 at commit `8e5a94a`.
Enter on a `[...] (enter to expand)` row sometimes did not expand the ReviewCard.
Other times it worked.

## Needed information

1. Was the row in the DiffPane or in the Comment Overview?
2. Did the cursor reach the DiffPane through Enter on an Overview Entry, or through normal navigation?
3. Was the card a Draft, a Comment, or a Reply? Was it in a resolved Thread or an outdated section?
4. Does it also fail on `main`? Then it is not an M29 bug.

## Suspected cause

Not proved.
`review_card.hidden_indicator` is the row text.
The expand Action can depend on the row kind under the cursor.
A cursor that an Overview jump puts on the card can sit on another row kind than the indicator.

## What to do

1. Get the answers above, then reproduce with a fixture Review.
2. Add a Presentation test that fails before the fix.

## Comments
