# 13: Docs and completion evidence

**What to build:** Shipped behavior is documented from current sources and the hermetic suite gates completion without needing live Credentials.

**Blocked by:** 08 Interactive auth login; 09 Non-interactive auth login; 10 Auth status; 11 Auth logout and local isolation; 12 Credential containment.

**Status:** done

- [x] README, glossary, startup diagnostics, and token-rotation guidance match the shipped `bbr auth` behavior; token expiry and minimum API scopes are cited from current official docs.
- [x] The complete hermetic suite passes through the repository test command alongside formatting, build, and CLI script checks; new test files join the import chain and the reported count increases.
- [x] Live Bitbucket evidence stays Credential-gated and optional; required CI stays Credential-free.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`, `e7347b8`). README,
Bitbucket glossary, `bbr auth` usage, bbr skill, completion scripts, and M19
rotation guidance match shipped behavior. Token expiry (admin-capped, 365-day
default) and minimum scopes (`read:account`, `read:repository:bitbucket`,
`read:pullrequest:bitbucket`, `write:pullrequest:bitbucket`,
`read:workspace:bitbucket`) are cited from current Atlassian docs.
`zig fmt --check`, `zig build`, full suite 1113/1113, and all three Python
harnesses pass. Live checks stay gated and optional. Draft PR #12 holds the
branch.
