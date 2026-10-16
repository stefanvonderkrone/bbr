# 09: Non-interactive auth login

**What to build:** Automation logs in without a terminal through one explicit flag, while a miswired pipeline fails loudly instead of hanging.

**Blocked by:** 08 Interactive auth login.

**Status:** ready-for-agent

- [ ] `--stdin` supplies only the token as one silent line with no prompts and no retries; it requires `--email` and `--workspace`; surrounding spaces, tabs, and carriage returns are trimmed and empty, missing, or over-length input is invalid, naming the bad field without printing values.
- [ ] Piped input without `--stdin` is refused before the first prompt, reads nothing, and directs the user to a terminal or to `--stdin` with `--email` and `--workspace`.
- [ ] Exit status matches the interactive contract: `0` only when the Credential validates and saves, else `1`, with the prior stored Credential preserved on failure.
- [ ] The Python CLI harness proves piped refusal, strict `--stdin`, and safe error output.
