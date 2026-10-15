# Choose the M26 login input policy

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: none
Parent: ../map.md

## Question

Must M26 require an explicit flag before login accepts non-interactive standard input, or retain the current piped-input behavior?

The current milestone requires an explicit flag. Current `bbr login [profile]` accepts piped input without one.
Choose the accepted behavior and its command grammar under `bbr auth login`.
If a flag is required, define the input fields, their order, EOF and empty-input behavior, and rejection diagnostics without the flag.
Define exit status for cancellation and invalid input. Preserve hidden terminal token input and terminal restoration.
Keep token values out of command arguments and output.

Coverage: the login-input item in the original review table. Its acceptance tests belong to the separate test handoff.

References:

- `TODO.md`, M26 interactive-login requirement.
- `src/main.zig`, `promptInput`, `promptField`, and `loginRun`.
- `tests/auth_cli_test.py`, terminal and piped-input checks.
