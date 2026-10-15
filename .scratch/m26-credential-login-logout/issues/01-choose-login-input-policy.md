# Choose the M26 login input policy

Label: wayfinder:grilling
Type: grilling
Status: resolved
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

## Answer

M26 requires an explicit flag for non-interactive login. `bbr auth login` never reads piped input without it.

Accepted grammar: `bbr auth login [profile] [--email EMAIL] [--workspace WS] [--stdin]`, with the existing positional versus `--profile` rule unchanged. Any other argument is a usage error. The usage error states that bbr does not accept the token as a CLI argument. It never echoes the argument value. The Credential token travels only through hidden terminal input or `--stdin`.

TTY path: prompt for each missing field in Email, Token, Workspace order. `--email` and `--workspace` skip their prompts when present and non-empty. The token prompt hides input and restores terminal echo on every exit. Empty input retries up to three times per field. EOF aborts the login. Nothing is saved on abort.

`--stdin` path: read only the token, one line from stdin. Require `--email` and `--workspace` with `--stdin`. Reject `--stdin` combined with missing email or workspace. Read no prompts and retry nothing. Trim surrounding spaces, tabs, and carriage returns. Treat empty, missing EOF, or over-length input as invalid input. Name the bad field in the diagnostic. Never print the token.

Refusal without the flag: when stdin is not a terminal and `--stdin` is absent, refuse before the first prompt, read nothing, and tell the user to run with a terminal or pass `--stdin` with `--email` and `--workspace`.

Exit status: `0` only when the Credential validates live and the Profile saves and becomes the Active Profile. `1` for usage errors, abort, invalid input, failed account or Workspace validation, and save failure. Failed login preserves the prior stored Credential.

This keeps the current hidden-input and restore behavior, keeps tokens out of argv and output, and moves the old bare-pipe behavior under `--stdin`.
