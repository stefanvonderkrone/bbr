# M26 Credential login and logout

Status: ready-for-agent
Milestone: M26

## Problem Statement

Reviewers who need remote review must set up their Credential through shell environment variables today. There is no guided login flow under one command group, no status view that proves the Credential works, and no documented logout semantics. Piped input works without an explicit flag, storage permissions are implicit, and environment-versus-file precedence is per-field without a stated contract. This leaves automation, failure reporting, and Credential safety to guesswork.

## Solution

Add `bbr auth login`, `bbr auth status`, and `bbr auth logout` as the single Credential management surface outside the TUI. Login reads email and Workspace interactively or from arguments and reads the token only through hidden terminal input or one explicit piped-input flag. The Credential resolves through per-field environment overlay on the selected Profile, persists as TOML Profiles with safe modes and atomic replacement, and validates live against Bitbucket before save and on every status call. Status reports per-field source, the proven account identity, and distinct failure causes without ever printing the token. Logout removes Profiles idempotently and explains its limits. Keep `bbr local` free of Credential reads.

## User Stories

1. As a reviewer, I want `bbr auth login` to prompt for Email, Token, and Workspace, so that I can set up remote review without shell exports.
2. As a reviewer, I want the token prompt hidden with terminal echo restored on every exit, so that my token never shows on screen.
3. As a reviewer, I want empty input retried up to three times per field, so that a blank line does not abort my login.
4. As a reviewer, I want EOF to abort login with nothing saved, so that cancellation never leaves partial Credentials.
5. As a reviewer, I want `--email` and `--workspace` to skip their prompts, so that I type only what is missing.
6. As an automation author, I want `--stdin` to supply the token as one silent line, so that scripts log in without a terminal.
7. As an automation author, I want `--stdin` to require `--email` and `--workspace`, so that non-interactive logins carry their full context.
8. As an automation author, I want piped input without `--stdin` refused before the first prompt, so that a miswired pipeline fails loudly instead of hanging.
9. As a reviewer, I want exit `0` only when the Credential validates and saves, so that scripts can trust the exit status.
10. As a reviewer, I want abort, invalid input, failed validation, and save failure to exit `1`, so that every failure is detectable.
11. As a reviewer, I want unknown arguments rejected with a hint that the token never rides as a CLI argument, so that I learn the safe path.
12. As a reviewer, I want the token to travel only through hidden input or `--stdin`, so that process listings and history never capture it.
13. As a reviewer, I want login to prove the account and Workspace access before saving, so that only working Credentials persist.
14. As a reviewer, I want `unauthorized` and forbidden Workspace failures reported separately, so that I know whether my token or my access is wrong.
15. As a reviewer, I want a failed login to preserve my prior stored Credential, so that a typo does not lock me out.
16. As a reviewer, I want named Profiles selected by positional arg, `--profile`, `BBR_PROFILE`, Active Profile, then `default`, so that multi-account use stays predictable.
17. As a reviewer, I want a successful login to select its Profile as active, so that the next command uses it.
18. As a reviewer, I want per-field environment overlay on the selected Profile, so that I can override one field without rewriting the file.
19. As a reviewer, I want empty environment values treated as missing, so that blanks cannot pass as complete Credentials.
20. As a reviewer, I want a partial environment set to fill the rest from the file, so that token-only exports keep working.
21. As an automation author, I want a complete environment set to resolve without the file, so that containers need no stored state.
22. As an automation author, I want env to rescue an absent or broken auth file when it completes the Credential, so that automation survives broken storage.
23. As a reviewer, I want file errors to surface only when env cannot complete the Credential, so that diagnostics point at the real gap.
24. As an API user, I want `bbr api --workspace` to override only the Workspace field, so that one-off Workspace switches need no file edit.
25. As a reviewer, I want one resolve rule for remote review, status, and API commands, so that source behavior never depends on the entry point.
26. As a reviewer, I want new auth directories created with mode `0700`, so that stored Credentials start private.
27. As a reviewer, I want the existing auth directory repaired to `0700` on login and logout, so that older installs converge without manual chmod.
28. As a reviewer, I want only the auth directory itself ever chmodded, so that unrelated parent directories never change.
29. As a reviewer, I want a failed directory repair to warn and continue, so that a chmod problem does not block login.
30. As a reviewer, I want `auth.toml` written atomically with mode `0600`, so that an interrupted login cannot erase a valid Credential.
31. As a reviewer, I want a failed `0600` enforcement to warn visibly, so that weak file modes never go unnoticed.
32. As a reviewer, I want symlinked auth paths followed normally, so that managed home directories keep working.
33. As a reviewer, I want directories and special files at the auth path refused with exit `1`, so that reads never block and writes never go somewhere unsafe.
34. As a reviewer, I want `bbr auth status` to always validate live, so that its result reflects Bitbucket reality rather than file contents.
35. As a reviewer, I want status to report per-field file-versus-env source markers, so that mixed Credentials read clearly.
36. As a reviewer, I want status to show the configured email plus the proven account UUID, so that I never mistake a typed address for proven identity.
37. As a reviewer, I want status to exit `0` only when both account and Workspace probes pass, so that partial access never reads as healthy.
38. As a reviewer, I want missing Credentials to hint `bbr auth login`, so that the fix is obvious.
39. As a reviewer, I want transport and rate-limit failures reported as transport, so that a network fault never reads as an invalid Credential.
40. As a reviewer, I want status to never write or repair storage, so that inspection is side-effect free.
41. As a reviewer, I want `bbr auth logout` to remove the selected Profile and keep the rest, so that multi-Profile setups survive single logout.
42. As a reviewer, I want `bbr auth logout --all` to delete only `auth.toml`, so that nothing else on disk is touched.
43. As a reviewer, I want logout to succeed when the file is absent, so that cleanup scripts stay idempotent.
44. As a reviewer, I want logout to state that it does not revoke the API token and cannot remove environment overrides, so that I know what logout actually ends.
45. As a reviewer, I want logout to attempt the same directory repair as login but still refuse unsafe file targets, so that teardown is safe.
46. As a security-minded reviewer, I want no Credential value in diagnostics, logs, headers, URLs, storage, or snapshots, so that secrets never leak through tooling.
47. As a reviewer, I want `bbr local` to run without touching Credential storage, so that offline review needs no login.
48. As a reviewer, I want README, glossary, startup diagnostics, and token-rotation guidance to match the shipped behavior, so that docs never describe a surpassed flow.
49. As a reviewer, I want token expiry and minimum API scopes cited from current official docs, so that I request exactly the access I need.
50. As a maintainer, I want the hermetic suite to gate completion with live checks optional, so that CI stays Credential-free.

## Implementation Decisions

- Group login, status, and logout under one `auth` command with no top-level aliases. Status is the output half of the command-group item, not a second feature.
- Login grammar is `bbr auth login [profile]` with optional `--email`, `--workspace`, and `--stdin`. There is no token argument. Unknown arguments are usage errors that state the token never rides as a CLI argument and never echo the value.
- TTY login prompts in Email, Token, Workspace order for each missing field. `--email` and `--workspace` skip their prompts when present and non-empty. The token prompt hides input and restores echo on every exit path.
- TTY empty input retries up to three times per field. EOF aborts with nothing saved. Exit `0` only when the Credential validates live and the Profile saves as active.
- `--stdin` reads only the token as one line with no prompts and no retries. It requires `--email` and `--workspace`. Trim surrounding spaces, tabs, and carriage returns. Empty, missing, or over-length input is invalid. Name the bad field without printing values.
- Non-terminal stdin without `--stdin` refuses before the first prompt, reads nothing, and directs the user to a terminal or `--stdin` with `--email` and `--workspace`.
- Live validation runs the account probe and the Workspace probe before any save. Report `unauthorized` and forbidden-or-invisible Workspace separately without response bodies. Preserve the prior stored Credential on any failure.
- Credential resolution is per-field environment overlay on the selected Profile, not exactly-one-source. This consciously overrides the milestone checklist line that rejects partial sets. Empty counts as missing. Partial sets fill from the file. Complete sets resolve without the file and bypass absent, malformed, or unreadable files. File errors surface only when env cannot complete the Credential.
- Profile selection order is positional arg, `--profile`, `BBR_PROFILE`, Active Profile, then `default`. A complete environment set needs no base Profile.
- The API Workspace flag remains a single-field Workspace override applied after the shared resolve. Status carries no Workspace override and reports the resolved Workspace.
- One resolve path serves remote review, auth status, and API commands.
- New auth directories are created with mode `0700`. Login and logout repair only the auth directory itself to `0700`, never parents. Failed directory repair warns and continues. File writes use atomic replacement with mode `0600`. Failed `0600` enforcement warns and keeps the file. Other write or replace failures exit `1` with nothing saved. Interrupted login keeps the prior Credential via atomicity. Profile upserts merge and never drop other Profiles.
- Symlinks at the auth directory and file are followed. Directories, fifos, sockets, and device nodes at the file path, or a non-directory at the directory path, refuse with exit `1`. No uid ownership check.
- Status grammar is `bbr auth status [profile]` with the shared Profile selector and no live-validation flag. It runs both probes on every call and has no local-only mode.
- Status reports Profile name, configured email, Workspace, per-field file-versus-env source markers, proven account UUID, and separate account and Workspace results. The token never prints in any form. Exit `0` only when both probes pass.
- Status failures exit `1` with distinct reports: missing Credential hints login, bad or unsafe storage reports without repair, `401` reports invalid Credential, forbidden or invisible Workspace reports separately, transport and rate-limit failures report as transport.
- Status never writes storage and never chmods. Logout attempts the directory repair, refuses directory or special file targets, deletes only `auth.toml` for `--all`, succeeds when absent, and documents no revocation and no environment removal.
- The existing HTTP client seam stays the replacement boundary for probes. No new seams are introduced. Filesystem behavior goes through the existing directory and atomic-file interfaces. Terminal behavior is covered through the existing CLI harness.
- Seams used, highest first: command dispatch with injected environment, filesystem, and fake HTTP client as the primary deterministic seam; the Python CLI harness as the secondary seam for terminal echo, piped input, and exit codes.

## Testing Decisions

- Good tests assert externally visible behavior: prompts, exit codes, stored Profiles, resolved Credentials, status output, failure reports, file modes, and rendered diagnostics. Tests do not assert private parsing helpers, buffer sizes, retry-loop counters, or internal transaction steps.
- The primary deterministic seams are auth resolution and storage with injected environment maps and temporary data directories, plus command dispatch with a fake HTTP client. Tests drive commands and inspect resolved Credentials, stored files, modes, output text, and exit codes.
- The Python CLI harness is the only secondary integration seam. It proves hidden token input, echo restoration, Profile selection, piped refusal, strict `--stdin`, safe errors, and help output that unit tests cannot observe alone.
- Existing probe tests receive credit for separate account and Workspace coverage. Existing diagnostic-omission tests receive credit for URL and body stripping. Existing TOML and persistence tests receive credit for round trips. New tests cover only the gaps: failure-plus-preservation integration, atomic-failure behavior, unsafe targets, precedence and file rescue, status output and per-state failures, idempotent logout, and LocalReview isolation.
- Required hermetic failure tests are preserve-prior on failed validation, atomic-replacement failure, unsafe directory and special targets, and LocalReview isolation from Credential storage.
- Containment evidence is omission where code never prints upstream text plus redaction tests where it does, spanning diagnostics, logs, Authorization headers, token-bearing URLs, storage, and snapshots.
- No duplicate tests solely to raise counts. Tests added in new files must join the test import chain and the reported test count must increase.
- The complete hermetic suite must pass through the repository test command alongside formatting, build, and CLI script checks. Live Bitbucket evidence stays Credential-gated and optional.

## Out of Scope

- Migrating accepted TOML storage to JSON.
- A native credential-store adapter.
- Revoking Atlassian API tokens through logout.
- Removing environment overrides through logout beyond documenting the limit.
- A local-only status mode or a validation flag on status.
- A Workspace override flag on status.
- Ownership checks on the auth directory or file.
- Persistent disk caching of reviewed source or File content changes.
- Browser work, LocalReview expansion beyond isolation, and other milestones.
- Implementation work itself; this spec hands to tickets and implementation.

## Further Notes

- The completed [Agree the M26 completion contract](map.md) is the decision index for this spec.
- [Choose the M26 login input policy](issues/01-choose-login-input-policy.md) owns input grammar, hidden prompts, `--stdin`, refusal, and exit status.
- [Choose the M26 Credential source policy](issues/02-choose-credential-source-policy.md) owns the overlay rule and consciously overrides the reject-partial checklist line.
- [Choose the M26 auth storage safety policy](issues/03-choose-auth-storage-safety-policy.md) owns modes, atomicity, target refusal, and read-only status expectations.
- [Define the M26 auth status contract](issues/04-define-auth-status-contract.md) owns always-live validation, source and identity reporting, and the failure matrix.
- [Define the M26 completion evidence](issues/05-define-m26-completion-evidence.md) owns the acceptance matrix this spec collapses into buildable form.
- Implementation should link this contract from the M26 milestone notes when the behavior ships.
