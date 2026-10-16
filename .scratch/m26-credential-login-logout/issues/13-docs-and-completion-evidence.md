# 13: Docs and completion evidence

**What to build:** Shipped behavior is documented from current sources and the hermetic suite gates completion without needing live Credentials.

**Blocked by:** 08 Interactive auth login; 09 Non-interactive auth login; 10 Auth status; 11 Auth logout and local isolation; 12 Credential containment.

**Status:** ready-for-agent

- [ ] README, glossary, startup diagnostics, and token-rotation guidance match the shipped `bbr auth` behavior; token expiry and minimum API scopes are cited from current official docs.
- [ ] The complete hermetic suite passes through the repository test command alongside formatting, build, and CLI script checks; new test files join the import chain and the reported count increases.
- [ ] Live Bitbucket evidence stays Credential-gated and optional; required CI stays Credential-free.
