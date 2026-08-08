# Live-probe old-side range and Suggestion behavior

Type: task
Status: resolved
Blocked by: 02

## Question

Using a disposable Bitbucket Cloud PullRequest, post old-side single-line and multi-line Comments and record their API round trip and web-UI card placement; post fenced Suggestion bodies on supported new-side ranges and probe whether old-side bodies expose an Apply action; verify the server's treatment of mixed, unmatched, descending, hunk-gap-spanning, and practical boundary-size range shapes. Record fixture-safe facts and clean up every probe without exposing credentials.

## Answer

Bitbucket Cloud accepts and round-trips ordinary old-side single-line Comments as `{ from }` and old-side ranges as `{ start_from, from }`. In the web UI a single-line card is placed under its anchored line; a range card is placed under its inclusive bottom line and labelled `Lines -<start_from> to -<from>`. New-side ranges use the same bottom-line placement with `+` bounds.

A fenced `suggestion` body is accepted and rendered as **Suggested change** for both new-side and old-side Anchors. New-side single and ranged Suggestions expose an enabled **Apply suggestion** action and show the selected source lines as removals plus the proposed replacement. Old-side single and ranged fenced bodies render only proposed added lines and expose a disabled **Apply suggestion** action. Bitbucket supplies no visible explanation on hover. bbr must therefore continue refusing Suggestion authoring when the effective inline CommentScope is old-side; ordinary old-side Comments remain supported.

The API accepts ambiguous mixed-side single coordinates and all-four-coordinate ranges, so server acceptance is not evidence of a meaningful authoring shape. It rejects unmatched `start_from`/`start_to`, descending ranges, and ranges longer than 30 lines; exactly 30 inclusive lines are accepted on both sides. bbr should enforce a one-side-only, matched, ascending, maximum-30-line Anchor before submission. PullRequest 1856 has one hunk, but Bitbucket accepted a 30-line range extending beyond the rendered hunk context; bbr should retain its stricter cross-gap refusal because a visual Selection cannot safely name hidden rows.

The final Chrome DevTools UI probes used CommentIds `837245795`, `837245796`, `837245797`, `837245800`, `837245801`, and `837245803`. All returned `204` on cleanup, and a follow-up query found no remaining `[bbr-m16-ui-probe` Comments. Earlier API probes were likewise fully cleaned up. No Suggestion was applied and the PullRequest's code was not changed.

## Comments

### 2026-08-08 API probe on PullRequest 1856

- Bitbucket accepted and round-tripped old-side single-line `{ from: 73 }` and range `{ start_from: 73, from: 75 }` Comments.
- It accepted fenced `suggestion` bodies on both new-side and old-side single/range Anchors. In every case `content.html` rendered a `language-suggestion` code block; the API does not reveal whether the web UI offers **Apply suggestion**.
- It accepted ambiguous mixed-side `{ from: 73, to: 73 }` and all-four-coordinate range shapes. bbr must still refuse them because acceptance does not establish unambiguous placement or application semantics.
- It rejected an unmatched `start_from` or `start_to`, rejected descending ranges, and rejected 31-line ranges. It accepted exactly 30 lines on both old and new sides, establishing an inclusive maximum of 30 lines per side.
- PullRequest 1856 contains only one hunk, so a genuine hunk-gap-spanning request could not be constructed without changing the PullRequest's code.
- The T3 preview and authenticated web HTTP could not access the private repository (`404` and `401`, respectively), so card placement and **Apply suggestion** availability remain unobserved.
- The UI-inspection probe CommentIds `837233629`, `837233630`, `837233655`, `837233658`, `837233672`, `837233674`, `837233685`, `837233686`, `837233693`, and `837233694` were all deleted after the requested Chrome integration proved unavailable. A follow-up API query found no remaining `[bbr-m16-probe` Comments.
- Four malformed-body attempts and their corrected predecessors were already deleted: `837233632`, `837233634`, `837233635`, `837233637`, `837233659`, `837233660`.
- Chrome DevTools MCP could not start because it is configured for `/Applications/Google Chrome.app`, while this machine has only `/Applications/Google Chrome Canary.app`. The ticket was released unclaimed pending MCP configuration or installation of stable Chrome.

### 2026-08-08 Chrome DevTools UI probe

- After stable Chrome became available and the user authenticated, the six UI cases were recreated and inspected on PullRequest 1856.
- Single-line cards appeared under their anchored row. Both old- and new-side ranged cards appeared under their bottom row with explicit signed range labels.
- New-side Suggestion Apply actions were enabled; old-side Suggestion Apply actions were present but disabled, with no hover explanation.
- All six UI probes were deleted and absence of the probe prefix was verified through the API.
