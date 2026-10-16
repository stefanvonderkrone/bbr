# Define the M26 completion evidence

Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04
Parent: ../map.md

## Question

What evidence permits M26 to be marked complete after the accepted input, source, storage, and status decisions ship?

Agree one acceptance matrix that maps every M26 checklist item to behavior, evidence, and unresolved gaps.
Separate implemented behavior from missing tests. Existing validation and diagnostic stripping must receive credit.
Define the evidence needed for Credential containment across diagnostics, logs, Authorization headers, token-bearing URLs, and storage.
Decide whether omitting sensitive data is sufficient where code never prints upstream error text.
Set the test boundary for failed validation preserving prior Credentials, atomic replacement failures, unsafe targets, and LocalReview isolation.
Decide which auth CLI checks belong in the required hermetic suite and whether any live evidence is necessary.
Define the documentation acceptance bar for token expiry, minimum scopes, logout semantics, and the final command grammar.
Scope and expiry facts must come from current official documentation during the documentation handoff.
Do not turn this decision into implementation or require duplicate tests solely to increase the test count.

Coverage: validation, Credential containment, logout explanation, documentation, and test items in the original review table.
Use the accepted status contract to avoid counting the command and its output requirements as two features.
Record the resulting acceptance contract in this ticket's answer and link it from M26.

Prerequisites:

- [Choose the M26 login input policy](./01-choose-login-input-policy.md).
- [Choose the M26 Credential source policy](./02-choose-credential-source-policy.md).
- [Choose the M26 auth storage safety policy](./03-choose-auth-storage-safety-policy.md).
- [Define the M26 auth status contract](./04-define-auth-status-contract.md).

References:

- `TODO.md`, M26 checklist and verification commands.
- `src/http/std_client.zig`, submission diagnostic omission tests.
- `src/bitbucket/client.zig`, separate account and Workspace probe tests.
- `src/bitbucket/auth.zig`, TOML and persistence tests.
- `tests/auth_cli_test.py` and `tests/api_auth_cli_test.py`.
- `build.zig`, required test composition.
- The single M26 handoff linked from the parent map.

## Answer

M26 is complete when the four accepted decisions ship with the evidence below. Command and status count once: `bbr auth status` is the status half of the command-group item, not a second feature.

Acceptance matrix, checklist order:

- Command group: `bbr auth login`, `bbr auth status`, `bbr auth logout` with no top-level aliases. Evidence: hermetic command-parsing tests plus CLI checks.
- Login input: TTY prompts with hidden token and restore, `--stdin` token-only with required `--email` and `--workspace`, early refusal without the flag, generic unknown-arg error, `0` only on save. Evidence: hidden-input and echo-restore checks, piped refusal, strict `--stdin`, exit-status checks.
- Validation before save: both account and Workspace probes run before any write, classified errors print without bodies, failed login preserves the prior Credential. Existing probe and diagnostic-stripping tests receive credit. Missing evidence: one integration test for failure plus preservation.
- Storage: TOML Profiles preserved, new bbr dir `0700`, repair-only-bbr-dir with warn-continue, `0600` file with warn-keep, atomic replace, symlinks followed, dir and special targets refused, no owner check. Evidence: mode, merge-preservation, atomic-failure, and unsafe-target tests.
- Source: per-field env overlay with empty as missing, env rescues bad files, profile picks the base, `bbr api --workspace` stays a Workspace-only override, one rule for review, status, and API. This overrides the checklist reject-partial line. Evidence: precedence, partial-mix, file-rescue, and workspace-flag tests.
- Status: always live with both probes, per-field source markers, configured email plus proven UUID, distinct exit-`1` reports, read-only. Evidence: output and per-state failure tests.
- Logout: removes the selected Profile, `--all` deletes only `auth.toml`, absent file succeeds, explains no token revocation and no env removal. Evidence: idempotent-logout tests.
- Containment: no Credential value in diagnostics, logs, Authorization headers, token-bearing URLs, storage, or snapshots. Omission suffices where code never prints upstream text. Redaction tests cover paths that do.
- Docs: README, Bitbucket glossary, startup diagnostics, and M19 guidance match the four decisions. Token expiry and minimum scopes cite current official docs. Logout and grammar sections state revocation, env, and command facts.
- Suite: the above hermetic tests plus `zig fmt --check`, `zig build`, `zig build test --summary all`, and the auth CLI scripts gate completion. Required failure tests: preserve-prior, atomic failure, unsafe targets, LocalReview isolation. No duplicate tests for counts. Live Bitbucket evidence stays Credential-gated and optional.
