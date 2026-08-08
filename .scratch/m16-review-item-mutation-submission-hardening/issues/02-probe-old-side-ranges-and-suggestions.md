# Probe old-side Comment ranges and multi-line Suggestions

Type: research
Status: resolved
Blocked by: none

## Question

What request shapes does Bitbucket Cloud accept for old-side single-line and multi-line inline Comments, how does its web UI render those ranges, and how does it render or constrain multi-line Suggestion bodies across new-side and old-side Anchors? Record the exact supported envelope so bbr refuses unsupported authoring rather than guessing.

## Answer

The documented REST shape uses `{ path, from }` for an old-side single-line Comment and `{ path, start_from, from }` for an old-side range. New-side equivalents use `to` and `start_to`. Coordinates are 1-based and ranges run from the top line to the bottom line. Bitbucket documents new-side multi-line Suggestions through its multi-line selection and Suggest-code UI; at the REST boundary they remain fenced `suggestion` Markdown in `content.raw`.

bbr must continue refusing old-side Suggestions and mixed-side, unmatched, descending, or hunk-gap-spanning Anchor shapes. Atlassian does not document applicable old-side Suggestion semantics, malformed/mixed-shape rejection, old-side UI card placement, or maximum range limits. Those behavior gaps graduate to [Live-probe old-side range and Suggestion behavior](14-live-probe-old-side-range-and-suggestion-behavior.md).

Context: `docs/research/bitbucket-old-side-ranges-and-suggestions.md` on branch `research/bitbucket-old-side-ranges-and-suggestions`, commit `5da040a34ba9cd1cf73763dcdd03a028cb89093a`.
