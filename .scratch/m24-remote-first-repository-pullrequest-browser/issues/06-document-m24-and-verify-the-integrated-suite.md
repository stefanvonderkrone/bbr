# 06: Document M24 and verify the integrated suite

Status: ready-for-agent
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

- [ ] Every glossary term in the spec exists with its `_Avoid_` line, and the AdjacentPullRequest entry names the Browser.
- [ ] Every new AGENTS.md rule names a test or a `comptime` check that exists.
- [ ] README, `usage`, and shell completions describe the same commands and keys.
- [ ] The TODO.md M24 lines match the shipped behavior.
- [ ] The full hermetic suite passes, and the reported test count increases.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test-cli`
- `zig build test --summary all`
- `python3 tools/check_agent_docs.py`
