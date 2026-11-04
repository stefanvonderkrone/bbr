# 10: Quit in the Detecting Frame waits for the detect request

Status: needs-triage
Blocked by: none
Spec: [M24 spec](../SPEC.md)

## Summary

The live M24 outside check, ticket 07 step B4, failed on 2026-11-04 at commit `151352c`.
The spec requires that `q` in the Detecting Frame exits bbr at once.

- Sometimes bbr exits at once.
- Sometimes bbr shows "shutting down…" and exits only after a delay.

## Steps

1. In a WorkingCopy on a branch with an open PullRequest, run `bbr`.
2. Press `q` while "Detecting PR for <branch>…" shows.

## Suspected cause

Not proved.
The operator saw that the delay occurs when a fetch already runs.
`statusText` in `src/tui/app.zig` shows "shutting down…" while `projection.shutting_down` is set.
So shutdown probably waits for an issued command, such as the detect request or the Repository list, to complete.
A `q` before the first request starts exits at once.

## What to do

1. Reproduce offline with a fake HTTP client that holds the detect response.
2. Find which issued commands the shutdown waits for in the Detecting Frame.
3. Cancel or abandon each read-only request on `q`. Keep the wait only for work that must complete, such as a Submission.
4. Add a test that fails when `q` in the Detecting Frame waits for a held read-only request.

## Comments
