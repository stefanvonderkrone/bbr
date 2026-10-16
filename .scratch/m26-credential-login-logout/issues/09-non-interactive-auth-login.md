# 09: Non-interactive auth login

**What to build:** Automation logs in without a terminal through one explicit flag, while a miswired pipeline fails loudly instead of hanging.

**Blocked by:** 08 Interactive auth login.

**Status:** done

- [x] `--stdin` supplies only the token as one silent line with no prompts and no retries; it requires `--email` and `--workspace`; surrounding spaces, tabs, and carriage returns are trimmed and empty, missing, or over-length input is invalid, naming the bad field without printing values.
- [x] Piped input without `--stdin` is refused before the first prompt, reads nothing, and directs the user to a terminal or to `--stdin` with `--email` and `--workspace`.
- [x] Exit status matches the interactive contract: `0` only when the Credential validates and saves, else `1`, with the prior stored Credential preserved on failure.
- [x] The Python CLI harness proves piped refusal, strict `--stdin`, and safe error output.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`). `--stdin` reads only the
token as one silent line with no prompts and no retries, requires `--email`
and `--workspace`, trims spaces/tabs/CR, and rejects empty, missing, and
over-length input naming the token field without values. Piped input without
`--stdin` is refused before the first prompt with nothing read. Exit status
matches the interactive contract with the prior Credential preserved.
Harness covers refusal, strict `--stdin`, and non-echo of secrets.
Suite 1113/1113.
