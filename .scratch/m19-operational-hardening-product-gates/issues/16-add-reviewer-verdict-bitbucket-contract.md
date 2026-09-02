# 16 — Add the Reviewer Verdict Bitbucket contract

**What to build:** The Bitbucket context translates the Authenticated Account's Reviewer Verdict and changes it only after a fresh SourceCommit check. Callers receive one typed result that distinguishes definite, stale, reconciled, and unresolved outcomes.

**Blocked by:** 15 — Gate bounded Candidate Session acquisition.

**Status:** done

- [x] PullRequest acquisition includes PullRequest state, PullRequest Author UUID, and translated reviewer data needed to derive Approved, Changes Requested, or No Verdict.
- [x] Atlassian participant and endpoint wire shapes remain inside the Bitbucket context.
- [x] Approved and Changes Requested use their specified POST endpoints. No Verdict deletes the endpoint for the current Approved or Changes Requested verdict.
- [x] A target POST can replace the existing Reviewer Verdict directly.
- [x] Before each mutation, the adapter fetches the current PullRequest and compares its SourceCommit with the expected SourceCommit. A mismatch sends no mutation.
- [x] After definite success or an uncertain outcome, the adapter reacquires SourceCommit and Reviewer Verdict.
- [x] The typed result distinguishes success, reconciled success, definite `ApiError`, stale SourceCommit, and unresolved outcome.
- [x] Reviewer Verdict operations never retry automatically. A `401` invalidates the cached Authenticated Account identity.
- [x] Hermetic client tests cover verdict derivation, PullRequest Author identity, all four mutation endpoint shapes, every `ApiError`, malformed responses, stale refusal, uncertain reconciliation, and a SourceCommit change during mutation.
- [x] A Credential-gated local check can exercise Reviewer Verdict mutation without exposing Credential data.
