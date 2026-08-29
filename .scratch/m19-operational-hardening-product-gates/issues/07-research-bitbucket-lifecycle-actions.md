# Research Bitbucket PullRequest lifecycle Actions

Type: research
Status: resolved
Blocked by: none

## Question

What do current primary Bitbucket Cloud sources establish about approve, unapprove, merge, and decline endpoints, required permissions and scopes, stale-SourceCommit controls, merge strategies, confirmations, conflict responses, rate limits, and recoverable failure behavior?

## Answer

[Research: Bitbucket PullRequest lifecycle Actions](../research/bitbucket-pullrequest-lifecycle-actions.md). Bitbucket exposes all four Actions, but no documented SourceCommit precondition or confirmation step. A client must gate on the current SourceCommit, confirm irreversible or high-impact Actions, poll asynchronous merges, and reconcile state before retrying an uncertain mutation.
