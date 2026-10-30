# M24 Remote-first Repository and PullRequest Browser: brief

Status: ready-for-agent
Milestone: M24

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M24.
The requirements live in the M24 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Bitbucket glossary](../../src/bitbucket/GLOSSARY.md), [the Git glossary](../../src/git/GLOSSARY.md), and [the Presentation glossary](../../src/tui/GLOSSARY.md).

## In my own words

Today, plain `bbr` works only inside a WorkingCopy of a Bitbucket Repository.
It finds the AdjacentPullRequest for the current branch, or it shows a Picker for one Repository.
A reviewer who reviews other people's work across many Repositories has no entry point.
That reviewer must know the Repository slug and the PullRequestId, or paste a URL.

The goal is one entry point for both cases.
When the current branch has exactly one open PullRequest, `bbr` opens it, as it does today.
In every other case, `bbr` opens a Browser for the whole Workspace.
The Browser is a tree, like a file manager: Repositories, and under each one its open PullRequests.
Each row shows only the facts that belong to that row.

The real problem is fast orientation across the Workspace without waiting for the network.
The cache and on-demand loading make the Browser useful at once.
Request identities and partial-failure states keep it correct when the network is slow or fails.

## Expert approach

- Raw sources: the Bitbucket Cloud REST API for `GET /repositories/{workspace}` and `GET /repositories/{workspace}/{repo}/pullrequests`, its pagination contract, its `fields` filter for participants, and its rate limits.
- Prior art: file managers and tools such as `lazygit` and `gh dash`.
  Each one shows a cached list at once, refreshes it in the background, and keeps the selection stable during the refresh.
- Method: the Browser is one more Presentation state machine (ADR-0012) with one View tree (ADR-0013).
  Acquisition stays behind the `HttpClient` seam, so fakes drive every state.
- Outside check: run `bbr` on the real Workspace in three places:
  a branch with one open PullRequest, a branch with none, and a directory outside Git.
  Measure the time to the first Browser frame from the cache and from a cold start.
  Count the requests during a full expansion, and confirm that no 429 response occurs.

## Decisions

The user made these decisions on 2026-10-29 and 2026-10-30.

1. **Startup detects the AdjacentPullRequest first.**
   Plain `bbr` enters the TUI at once and shows a "Detecting PR for `<branch>`…" loading frame.
   The input stays live, so `q` quits.
2. **Exactly one AdjacentPullRequest opens its review Session.**
   This is the "show the PullRequest when detected" rule.
3. **Two or more AdjacentPullRequests open the Browser.**
   The detected Repository is expanded, and the newest AdjacentPullRequest has focus.
   The pre-filtered Picker is removed from startup.
4. **No AdjacentPullRequest, or a detached HEAD, opens the Browser with the detected Repository expanded and focused.**
5. **A failed detection opens the plain Browser with no note.**
   A failed detection is: no Git repository, no Bitbucket Remote, a Remote in a different Workspace, or a failed PullRequest list request.
6. **`bbr <repo-slug>` keeps its meaning.**
   It runs the same detection, but the Repository comes from the argument and not from the Remote.
   When nothing is detected, the Browser opens with that Repository expanded.
7. **The `bbr detect` subcommand stays.**
   It runs the same detection as startup and prints the result without the TUI.
   The result is the PullRequest that opens, or the Browser start with its expanded Repository.
   The user reversed the earlier removal on 2026-10-30.
8. **A new configurable `open_browser` Action, bound to `b`, opens the Browser from a review Session.**
   When the Browser has not loaded yet, it starts with the Session's Repository expanded and its PullRequest focused.
   The `p` Picker stays until M25 replaces it.
9. **The summary cache is a separate file under `$XDG_STATE_HOME/bbr`.**
   It is scoped to the Workspace.
   It holds no Credential and no PullRequest description.
   bbr rebuilds it after any parse error.
   Access goes through `src/xdg.zig`.

## Specification changes

- Changed: "Replace no-argument WorkingCopy detection with Browser startup" becomes "detect first, and open the Browser when detection does not find exactly one PullRequest" (decisions 1 to 6).
- Resolved: "Decide whether `bbr detect` remains useful" is answered: it stays and reports the new startup outcome (decision 7).
- Added: the `open_browser` Action and its lazy Browser start (decision 8).
- Added: the cache file location and its rebuild-on-error rule (decision 9).
- Added: the detecting loading frame is one more Interaction Context in the Browser projection specification.
- Kept: every other M24 TODO line, including the Repository and PullRequest row facts, sorts, bounded concurrency, stale-result rejection, return-state retention, and the live shape check.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the implementation tickets in this directory.
M24 has size L, so the tickets split acquisition, cache, Browser Presentation, and startup into separate slices.
