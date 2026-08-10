# Live-probe published Comment mutation edge cases

Type: task
Status: resolved
Blocked by: 01

## Question

Using a disposable Bitbucket Cloud PullRequest owned by the tester, execute and record the minimum reversible mutation matrix needed by [Define the author-owned published Comment mutation contract](06-define-published-comment-mutation-contract.md): delete a root with Replies and inspect the resulting graph and UI; round-trip edit a Suggestion-bearing root and Reply through `content.raw`; and attempt an `inline` change on update only to determine whether the server rejects or ignores it. Record request/response shapes, final cleanup, and fixture-safe facts without exposing credentials.

## Answer

Bitbucket Cloud PullRequest 1856 was probed on 2026-08-10 with uniquely prefixed, tester-owned Comments. Deleting a root with a Reply returns `204` and tombstones rather than removes the root: its single-resource `GET` still returns `200` with `deleted: true` and empty `content.raw`, and the list endpoint still includes it. The Reply remains individually fetchable and listed, with its original `parent.id`. Clients must therefore reconcile the authoritative graph and render the surviving Thread rather than cascade locally.

A Suggestion-bearing inline root created from `{ content: { raw }, inline }` and its Reply created from `{ content: { raw }, parent: { id } }` both returned `201`. Updating either resource by its own CommentId with only `{ content: { raw } }` returned `200` and round-tripped the replacement bytes exactly. The root's rendered HTML retained its `language-suggestion` block, and the Reply retained its parent. Suggestion-bearing roots and Replies therefore use the ordinary body-only Comment update contract.

Updating an existing inline root with `{ content: { raw }, inline: <different valid Anchor> }` returned `400`. The response envelope had top-level `type` and `error`, with `error.message`, `error.fields`, and the message `Bad request`. A follow-up `GET` proved both the original Anchor and original body were unchanged. Published Anchors are server-rejected on update, not silently moved; bbr must keep them immutable and send no speculative `inline` field.

Every created root, Reply, Suggestion, and confirmation Comment was deleted. Follow-up list queries found zero Comments with either probe prefix. No credentials, account identifiers, repository content, or reusable request authorization were recorded.
