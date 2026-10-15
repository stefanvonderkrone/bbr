# Define the M26 completion evidence

Label: wayfinder:grilling
Type: grilling
Status: open
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
