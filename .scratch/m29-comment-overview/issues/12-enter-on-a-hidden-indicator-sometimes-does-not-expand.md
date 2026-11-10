# 12: Enter on a hidden indicator sometimes does not expand

Status: needs-triage
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## Summary

The live M29 outside check, ticket 07, found this on 2026-11-10 at commit `8e5a94a`.
Enter on a `[...] (enter to expand)` row sometimes did not expand the ReviewCard.
Other times it worked.

## Answers

The operator answered on 2026-11-10.

1. The row was in the DiffPane.
2. The cursor got there through normal navigation, not through the Comment Overview.
3. The cards were a Draft and a Draft Reply.

So the bug probably exists on `main` too. Check `main` first.

## Suspected cause

Not proved.
`review_card.hidden_indicator` is the row text.
The expand Action can depend on the row kind under the cursor.
A Draft card can map Enter to the Composer or another Draft Action before the disclosure.

## What to do

1. Reproduce with a fixture Review that has a long Draft and a long Draft Reply, on `main` and on this branch.
2. Add a Presentation test that fails before the fix.

## Comments
