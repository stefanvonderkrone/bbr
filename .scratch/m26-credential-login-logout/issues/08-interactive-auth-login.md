# 08: Interactive auth login

**What to build:** A reviewer sets up remote review with one guided command that prompts for what is missing, proves the Credential live, and saves only working Credentials as the Active Profile.

**Blocked by:** 06 Auth storage safety; 07 Credential resolve rule.

**Status:** done

- [x] `bbr auth login [profile]` accepts only `--email`, `--workspace`, and `--stdin`; unknown arguments are usage errors that state the token never rides as a CLI argument without echoing any value; top-level login/logout entry points are removed or hint at the `auth` group.
- [x] TTY login prompts for each missing field in Email, Token, Workspace order; `--email` and `--workspace` skip their prompts when present and non-empty; the token prompt hides input and restores echo on every exit path.
- [x] Empty input retries up to three times per field; EOF aborts with nothing saved; exit `0` only when the Credential validates live and the Profile saves as active, else exit `1`.
- [x] Live validation runs the account probe and the Workspace probe before any save, reports `unauthorized` and forbidden-or-invisible Workspace separately without response bodies, and preserves the prior stored Credential on any failure.
- [x] The Python CLI harness proves hidden input, echo restoration, Profile selection, and exit codes; unit tests drive the rest through command dispatch with a fake HTTP client.

## Comments

Implemented on `m26-auth-integration` (`ceb8698`, in `src/main.zig`).
`bbr auth login [profile]` accepts only `--email`, `--workspace`, `--stdin`;
unknown arguments fail naming the token rule. TTY prompts run Email, Token,
Workspace in order, skip present flags, hide the token with echo restore on
every exit. Empty input retries 3x; EOF aborts with nothing saved. Exit 0 only
on live validation plus save. Validation runs account and Workspace probes
first, reports unauthorized vs forbidden-or-invisible separately, and never
saves on failure. Top-level `login` hints at the group. Follow-up `e7347b8`
teaches shell completion the `auth` subcommands and flags. Harness covers
hidden input, echo restore, profile selection, exit codes. Suite 1113/1113.
