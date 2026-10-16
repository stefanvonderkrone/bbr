# 10: Auth status

**What to build:** A reviewer proves their Credential works and sees exactly where each field came from, with the proven account identity distinct from the typed address and the token never printed.

**Blocked by:** 06 Auth storage safety; 07 Credential resolve rule.

**Status:** done

- [x] `bbr auth status [profile]` uses the shared Profile selector, carries no Workspace override and no local-only mode, and validates live with both account and Workspace probes on every call.
- [x] Output reports the Profile name, configured email, Workspace, per-field file-versus-environment source markers, the proven account UUID, and separate account and Workspace results; the token never prints in any form.
- [x] Exit `0` only when both probes pass; missing Credentials hint `bbr auth login`; bad or unsafe storage, `401`, forbidden-or-invisible Workspace, and transport-plus-rate-limit failures each report distinctly as their own cause.
- [x] Status never writes storage and never repairs modes; hermetic tests cover output shape and every failure state without duplicating existing per-probe coverage.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`). `bbr auth status
[profile]` uses the shared selector with no Workspace override and validates
live with both probes on every call. Output reports profile, configured
email, workspace, per-field file-vs-env markers, token source without the
value, proven account UUID, and both check results. Exit 0 only when both
pass; missing, bad-storage, 401, forbidden-or-invisible, and transport
failures report distinctly. Status never writes storage. Suite 1113/1113.
