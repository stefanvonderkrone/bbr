# bbr verification map

Read this index before a drive. These files define the maintained user journeys for the local TUI.

## Baseline preconditions

- Follow [Launch](../SKILL.md#launch) from the checkout root.
- Require a successful doctor check and the visible `VERIFY_NEW` source line.
- Use the helper as `control.py` below. The full path is `.agents/skills/verify-bbr/scripts/control.py`.
- Keep `$BBR_VERIFY_RUN` set. Start a separate run for each independent journey.
- The fixture has modified `sample.txt` and added `notes.txt`. It has no remote Threads or Drafts initially.

## Driving conventions

- Use tmux key names through `control.py keys`. Literal queries use `control.py text`.
- Capture the action state before confirmation and the resulting state after confirmation.
- Use labels that include the feature ID and entry point.
- Inspect the capture before the next step. A key send does not prove that an Action ran.
- Cover each listed entry point before reporting the complete feature as verified.
- Report a missing precondition as a failed journey with its attempted command.
- Preserve the failure evidence. Keep the reason in the feature's `Gotchas`.
- Run cleanup after every attempt. Evidence must survive cleanup.

## Features

- [Inspect a local diff](local-diff.md) covers launch, File finder, Sidebar, Layout, Scope, and Selected Version.
- [Search a review](search.md) covers Buffer Search, Review Search, and occurrence navigation.
- [Author local Drafts](drafts.md) covers three CommentScopes, cancellation, save, and persistence.
- [Inspect keyboard help](help.md) covers the help Overlay and local-only availability messages.

## Coverage limits

The initial proof must cover one mapped feature. It does not prove all map entries.
Remote review startup by id, URL, CWD discovery, and Picker require a dedicated Bitbucket fixture and Credential.
Remote Submission, Comment mutation, Reviewer Verdicts, API verbs, auth, Grammar management, and completions need separate journeys.
The existing CLI tests are useful regression checks. They do not replace a real TUI drive.
