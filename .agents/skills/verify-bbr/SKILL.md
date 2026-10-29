---
name: verify-bbr
description: Drive the bbr terminal UI through an isolated local Git review. Use to verify diff navigation, search, Draft authoring, or help and capture terminal evidence after a change.
---

# Verify bbr

Use the real `bbr` executable in a private tmux terminal. Read [the feature map](features/README.md) before each drive.
The primary user interface is the TUI. Secondary interfaces include `bbr api`, `auth`, `grammar`, and `completion`.
This skill seeds a LocalReview without a Remote or Credential. It does not prove remote Bitbucket behavior.

## Launch

Run from the checkout root on macOS or Linux with Zig 0.16.0, Git, Python 3, and tmux on `PATH`.
`launch` builds the binary. No server, port, migration command, or login is required.

```sh
zig version
export BBR_VERIFY_RUN="$(.agents/skills/verify-bbr/scripts/control.py launch)"
.agents/skills/verify-bbr/scripts/control.py doctor
```

`launch` runs `zig build` first, so the drive never uses a stale binary. It copies the binary into a new temporary directory. It creates an empty private `HOME` and a disposable Git WorkingCopy.
It commits `main` and `review` Refs there. `sample.txt` replaces `VERIFY_OLD` with `VERIFY_NEW` at line 20.
`notes.txt` adds `VERIFY_NOTES`. The app runs `bbr local main review` from this WorkingCopy in a 140 by 44 terminal.
Readiness requires the rendered `VERIFY_NEW` source text, not just a live process.
The app creates and migrates its own SQLite store on startup.

The helper uses `env -i` with explicit `PATH`, `HOME`, XDG paths, `LANG`, and `TERM`.
Each drive gets a private tmux socket, Refs, config, and database. Concurrent runs can use separate run directories.
The helper sets `XDG_STATE_HOME` to `$HOME/.local/state` inside the private `HOME`, so the database path is `$HOME/.local/state/bbr/pending.db`.
`env -i` removes your own `XDG_STATE_HOME`, so the store never reaches your real state directory.
Drive only the instance recorded in `$BBR_VERIFY_RUN/instance.json`.

If launch fails, the helper runs cleanup and retains the failed run's evidence.
After any later failed command, run the cleanup command below before another attempt.

## Doctor

Run this read-only check first when behavior looks wrong.

```sh
.agents/skills/verify-bbr/scripts/control.py doctor
```

Require `healthy: true` in the JSON output. The helper checks scratch ownership, the binary hash, and the source binary hash.
It checks the version, the recorded live pane PID, its `bbr local main review` command, and SQLite integrity.
If the checkout binary changed, rebuild and launch a new run. Keep the old evidence.
No auth probe is needed for a LocalReview.

## Drive

Use the helper's `keys` command for tmux key names. Use `text` for literal text.
Use `wait` for a visible result before the next action. It fails after 15 seconds.
Capture the screen before and after each meaningful action.

```sh
.agents/skills/verify-bbr/scripts/control.py capture before-finder
.agents/skills/verify-bbr/scripts/control.py keys F
.agents/skills/verify-bbr/scripts/control.py text sample
.agents/skills/verify-bbr/scripts/control.py capture finder-query
.agents/skills/verify-bbr/scripts/control.py keys Enter
.agents/skills/verify-bbr/scripts/control.py wait VERIFY_NEW
.agents/skills/verify-bbr/scripts/control.py capture focused-sample
```

Follow the selected feature file for its complete journey and expected state.
The File finder uses `F`. Buffer Search uses `/`. Review Search uses `g f`.
`C`, `I`, and `i` open Review-level, File-level, and inline Composers.
`C-s` saves a Composer. `Escape` cancels an Overlay.
Bindings come from `src/tui/keymap.zig` and Composer input in `src/tui/presentation.zig`.

## Evidence

Keep proof under `$BBR_VERIFY_RUN`, inside `.scratch/verify-bbr/<run-id>/`.
The helper retains the build version and SHA-256, seeded diff, action log, and named screen captures.
Each capture creates a plain `.txt` file and an `.ansi` file with terminal attributes.
Record the feature ID and entry point in capture labels and the final proof report.
Capture both the action and its result. A final screen alone is insufficient.

Exercise keyboard paths through the production TUI. Do not call internal setters or test-only endpoints.
For Drafts, inspect `control.py db` and restart the app to prove persistence through the TUI.
Cleanup backs up SQLite as `pending.db` in the evidence directory.
For read-only journeys, compare the recorded `fixture.diff` with the displayed old and new text.
Use ANSI captures for Layout, Selected Version, or color claims. Plain text cannot prove those attributes.
The helper records actions in `actions.jsonl`. Add assertions and record failures instead of inferring success from sent keys.

This LocalReview uses real Git and SQLite. It uses no mocks or dry-run flag.
It does not simulate remote PullRequests, published Comments, Submission, Credential validation, or Reviewer Verdicts.
For those features, use a dedicated remote fixture and the existing opt-in `check`, `check-mutation`, or `check-verdict` commands.
Read `docs/m16-operations.md` and `docs/m19-operations.md` before those checks.
Never count a local refusal message as proof of a remote operation.
Mock an external system only at an existing production boundary.
If you use a dry-run elsewhere, inspect file changes, network activity, and Git Refs to prove what it skips.

## Cleanup

Run this after success and after every failed drive.

```sh
.agents/skills/verify-bbr/scripts/control.py cleanup
test -f "$BBR_VERIFY_RUN/launch.txt"
test -f "$BBR_VERIFY_RUN/actions.jsonl"
test -f "$BBR_VERIFY_RUN/cleanup.json"
```

The helper captures the last screen and stops only the private tmux server named by this run's socket.
It backs up the database and removes the owned temporary directory. It never kills a process by name.
Evidence remains under `.scratch/verify-bbr/`. Report the absolute run path after cleanup.
`cleanup.json` must contain `scratch_removed: true`.

## Helpers

The executable helper is `scripts/control.py`. All commands run from the checkout root.
The examples above show `launch`, `doctor`, `keys`, `text`, `wait`, `capture`, and `cleanup`.
Use these commands for Draft evidence and a fresh TUI process with the same private store.

```sh
.agents/skills/verify-bbr/scripts/control.py db
.agents/skills/verify-bbr/scripts/control.py restart
.agents/skills/verify-bbr/scripts/control.py --help
```

`db` reads Draft rows without changes and writes `drafts.json` in the evidence directory.
`restart` stops the private tmux server and starts a new process with the same Refs and `HOME`.
Capture before restart because it replaces `launch.txt` and `launch.ansi`.
`BBR_VERIFY_RUN` must stay set for every command after `launch`.
If the terminal tool resets environment variables between calls, export the printed absolute run path in each call.
