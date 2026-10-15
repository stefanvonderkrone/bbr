# Choose the M26 Credential source policy

Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: none
Parent: ../map.md

## Question

Must M26 use exactly one complete Credential source, or retain environment overrides for individual Profile fields?

The milestone requires a complete environment set to override stored Credentials and rejects partial environment sets.
Current resolution combines environment and Profile fields. It reads `auth.toml` before applying even a complete environment set.
Choose the rule for absent, empty, partial, and complete `BITBUCKET_*` sets.
Define whether a complete environment Credential bypasses an absent, malformed, or unreadable auth file.
Define how explicit Profile selection interacts with environment Credentials.
Account for `bbr api --workspace`, which currently overrides the selected Workspace separately.
Decide whether the same source rule applies to remote review, auth status, and API commands.
Include migration consequences for scripts that supply only a token through the environment.

Coverage: the Credential source item in the original review table. This decision also constrains status output and documentation.

References:

- `src/bitbucket/auth.zig`, `resolve` and Profile selection.
- `src/api/cli.zig`, `cliCredential` and global Workspace selection.
- `README.md` and `docs/m19-operations.md`, environment and Keychain examples.
- `tests/api_auth_cli_test.py`, current override expectations.

## Answer

M26 retains per-field environment overlay. It does not adopt the exactly-one-source rule.

Each non-empty `BITBUCKET_USERNAME`, `BITBUCKET_TOKEN`, and `BITBUCKET_WORKSPACE` value overlays the same field from the selected Profile. An empty value counts as missing. An absent set uses the file Profile alone. A partial set fills the missing fields from the file. A complete set resolves without the file.

A Credential that env can complete bypasses an absent, malformed, or unreadable auth file. File errors surface only when env alone cannot complete the Credential. This keeps automation alive when storage breaks.

Explicit Profile selection still picks the file base: positional arg, then `--profile`, then `BBR_PROFILE`, then the Active Profile, then `default`. Env overlays that base. A complete env set needs no base Profile.

`bbr api --workspace` stays as a single-field Workspace override after the same resolve. It applies to file, env, and mixed Credentials.

One resolve path serves remote review, auth status, and API commands. No per-command source rule.

Migration: scripts that export only `BITBUCKET_TOKEN` keep working against the stored email and Workspace. Docs describe overlay, not rejection. This consciously overrides the M26 checklist line that rejects partial sets.
