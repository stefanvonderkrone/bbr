# Show the Comment body in the text output of list-comments

Status: needs-triage
Blocked by: none

## Problem

Agents fetch and answer PullRequest Comments in many sessions. A 30-day retro of the pr-webapp sessions found 21 sessions for this task, with 84 `list-comments` calls. The agents run `list-comments --json` because the text output has no Comment body:

```
#892743507 check24-pauschalreise-app-bamboo [app/routes/api/json/payment.server.ts current]  resolved
```

The JSON output costs 6 to 11k characters per call. Agents fetch it about 4 times per session, after each reply.

## Proposal

- Make the text output one compact block per Comment: the id, the parent id, `path:line`, the author, the outdated state, the resolved state, and the body.
- Add a filter that lists only the open (unresolved) Comments. The flag name is open for triage.
- Keep the `--json` output unchanged.

## Observation

`bbr api list-comments --repository pr-webapp --pull-request-id 2537 --limit 1 --json` printed `[]`. The same call with `--limit 3` and no `--json` printed one Comment. Check if `--limit` and `--json` interact incorrectly.

## Acceptance criteria

- [ ] The text output of `list-comments` shows the id, parent id, `path:line`, author, outdated state, resolved state, and body of each Comment.
- [ ] A flag lists only the open Comments.
- [ ] The `--json` output does not change.
- [ ] `skills/bbr/VERBS.md` and the verb help describe the new output and flag.
- [ ] `zig build test` passes.
