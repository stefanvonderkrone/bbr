# 06: Document M24 and verify the integrated suite

Status: resolved
Blocked by: 01, 02, 03, 04, 05
Spec: [M24 spec](../SPEC.md)

## What to build

The documentation describes the shipped Browser and Startup Detection.
The integrated suite passes with every M24 slice merged.

## Scope

- Apply the "Glossary changes" section of the spec to the Bitbucket, Git, and Presentation glossaries and to `GLOSSARY-MAP.md`.
- Add the six new rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
- Add `src/tui/browser.zig` and `src/bitbucket/summary_cache.zig` to `docs/code-navigation.md` and `src/tui/IMPLEMENTATION.md`.
- Add the Browser request bound to the "Acquisition concurrency" section of `src/tui/IMPLEMENTATION.md`.
- Record the live participant field shape in `src/bitbucket/IMPLEMENTATION.md` after ticket 07, or mark it as unproven.
- Update `README.md` for plain `bbr`, `bbr <repo-slug>`, `bbr detect`, `bbr check-browser`, the Browser keys, and the Summary Cache file.
- Check the M24 lines in `TODO.md`.
  Rewrite the startup line and the `bbr detect` line to match decisions 1 to 7 of the brief.
  Leave the LocalReview ADR line open.
- Record the integrated evidence under `## Completion` in the spec.

## Acceptance criteria

- [x] Every glossary term in the spec exists with its `_Avoid_` line, and the AdjacentPullRequest entry names the Browser.
- [x] Every new AGENTS.md rule names a test or a `comptime` check that exists.
- [x] README, `usage`, and shell completions describe the same commands and keys.
- [x] The TODO.md M24 lines match the shipped behavior.
- [x] The full hermetic suite passes, and the reported test count increases.
- [x] `python3 tools/check_agent_docs.py` passes.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test-cli`
- `zig build test --summary all`
- `python3 tools/check_agent_docs.py`

## Completion

This commit implements the ticket.

### Change summary

- The Bitbucket glossary adds Repository Summary, PullRequest Summary, and Summary Cache.
- The Git glossary adds Startup Detection and changes AdjacentPullRequest and GitClient.
- The Presentation glossary adds Browser, Browser Entry, Browser Start, and Detecting Frame, and changes Pane and Interaction Context.
- `GLOSSARY-MAP.md` changes "Git → Bitbucket" and adds "Bitbucket → Presentation".
- `AGENTS.md` adds the six M24 rules. The Pane rule also names the Browser Pane test.
- `docs/code-navigation.md` names the Startup Detection functions, the Summary Cache file, `src/tui/browser.zig`, and `src/bitbucket/summary_cache.zig`.
- `src/tui/IMPLEMENTATION.md` adds the Browser and Startup Detection owners and the Browser request bound under "Acquisition concurrency".
- `src/bitbucket/IMPLEMENTATION.md` marks the live participant field shape as unproven until ticket 07.
- `README.md` adds "Start a review" with plain `bbr`, `bbr <repo-slug>`, `bbr detect`, `bbr check-browser`, the Browser keys, and the Summary Cache file.
- `usage` in `src/main.zig` now names the Summary Cache file and the Browser keys, as the README does.
- `TODO.md` checks the shipped M24 lines and rewrites the startup line and the `bbr detect` line. The LocalReview ADR text and the live check line stay open.
- `FEATURES.md` replaces the stale pre-filtered Picker startup text and adds the Browser.

### Rule verification

- Each test that a new AGENTS.md rule names exists under that exact name.
- The six rules in the spec named one test each for the Browser state and Startup Detection rows. The rows also name the real tests "M24 browser Session replacement keeps the Browser scroll", "M24 browser s switches the Sort, keeps the Selection, and survives a return and a Session replacement", and "M24 startup the detection worker opens one AdjacentPullRequest and turns a failure into a plain Browser".
- The Startup Detection row describes the shipped call graph. `openTui` calls `startup.start`, which calls `startup.inspect`. The TUI worker calls `startup.detect`.
- A probe arm added to `browser.Entry` failed `zig build test-browser` at `render.drawBrowser`, `frame.hitTest`, and `browserContext`, and at four other switches. The probe was reverted.
- Ticket 04 proved the `comptime` allowlist error for a `description` field.
- The Completion notes of tickets 01 to 05 show no mistake class that happened twice, so this ticket adds no other rule.

### Defaults chosen

- The README and `usage` describe the keys that the Keymap binds by default: `b`, Escape, Enter, `h`, `l`, `j`, `k`, `gg`, `G`, `ctrl-d`, `ctrl-u`, `s`, `R`, and `q`.
- The shell completions already list `check-browser` and `detect`, so `src/completion.zig` does not change.
- The TODO.md line for tests and the live shape check stays unchecked, because ticket 07 has not run.
- The spec stays `claimed`, because ticket 07 is unresolved.

### Checks

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-browser`: "9/9 steps succeeded; 74/74 tests passed".
- `zig build test-cli`: "10/10 steps succeeded".
- `zig build test --summary all`: "25/25 steps succeeded; 1440/1440 tests passed". The baseline before M24 was 1378.
- `python3 tools/check_agent_docs.py`: pass.

### Review

- I read the full diff.
- The README, `usage`, and the shell completions name the same commands.
- The README and `usage` name the same Browser keys.
