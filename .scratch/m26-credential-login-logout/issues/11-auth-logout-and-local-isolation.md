# 11: Auth logout and local isolation

**What to build:** A reviewer ends a session for one Profile or every Profile with predictable, idempotent teardown, while offline review keeps working without any Credential.

**Blocked by:** 06 Auth storage safety; 07 Credential resolve rule.

**Status:** done

- [x] `bbr auth logout` removes the selected Profile and keeps the rest; `--all` deletes only the auth file and touches nothing else on disk; absent files succeed so cleanup scripts stay idempotent.
- [x] Logout states that it does not revoke the API token and cannot remove environment overrides; it attempts the same directory repair as login yet still refuses unsafe file targets.
- [x] `bbr local` runs without touching Credential storage, proven by an isolation test; top-level logout entry points are removed or hint at the `auth` group.
- [x] Hermetic tests prove single-Profile removal, `--all` scope, idempotent absent-file logout, and LocalReview isolation.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`). `bbr auth logout` removes
the selected Profile and keeps the rest; `--all` deletes only `auth.toml`.
Absent files succeed. Output states no API-token revocation and no
environment removal. Logout repairs the dir and refuses unsafe targets.
`bbr local` dispatches before Credential resolution; the harness proves
broken storage never surfaces a Credential error there. Top-level `logout`
hints at the group. Suite 1113/1113.
