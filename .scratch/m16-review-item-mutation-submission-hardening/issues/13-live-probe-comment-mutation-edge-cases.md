# Live-probe published Comment mutation edge cases

Type: task
Blocked by: 01

## Question

Using a disposable Bitbucket Cloud PullRequest owned by the tester, execute and record the minimum reversible mutation matrix needed by [Define the author-owned published Comment mutation contract](06-define-published-comment-mutation-contract.md): delete a root with Replies and inspect the resulting graph and UI; round-trip edit a Suggestion-bearing root and Reply through `content.raw`; and attempt an `inline` change on update only to determine whether the server rejects or ignores it. Record request/response shapes, final cleanup, and fixture-safe facts without exposing credentials.
