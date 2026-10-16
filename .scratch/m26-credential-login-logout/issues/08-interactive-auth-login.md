# 08: Interactive auth login

**What to build:** A reviewer sets up remote review with one guided command that prompts for what is missing, proves the Credential live, and saves only working Credentials as the Active Profile.

**Blocked by:** 06 Auth storage safety; 07 Credential resolve rule.

**Status:** ready-for-agent

- [ ] `bbr auth login [profile]` accepts only `--email`, `--workspace`, and `--stdin`; unknown arguments are usage errors that state the token never rides as a CLI argument without echoing any value; top-level login/logout entry points are removed or hint at the `auth` group.
- [ ] TTY login prompts for each missing field in Email, Token, Workspace order; `--email` and `--workspace` skip their prompts when present and non-empty; the token prompt hides input and restores echo on every exit path.
- [ ] Empty input retries up to three times per field; EOF aborts with nothing saved; exit `0` only when the Credential validates live and the Profile saves as active, else exit `1`.
- [ ] Live validation runs the account probe and the Workspace probe before any save, reports `unauthorized` and forbidden-or-invisible Workspace separately without response bodies, and preserves the prior stored Credential on any failure.
- [ ] The Python CLI harness proves hidden input, echo restoration, Profile selection, and exit codes; unit tests drive the rest through command dispatch with a fake HTTP client.
