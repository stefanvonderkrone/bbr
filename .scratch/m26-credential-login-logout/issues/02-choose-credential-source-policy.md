# Choose the M26 Credential source policy

Label: wayfinder:grilling
Type: grilling
Status: open
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
