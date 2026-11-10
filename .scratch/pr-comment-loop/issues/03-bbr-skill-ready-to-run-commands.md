# Replace the help step of the bbr skill with ready-to-run commands

Status: needs-triage
Blocked by: 01, 02, 04, 05

## Problem

Step 3 of `skills/bbr/SKILL.md` says "Run VERB --help first". In the pr-webapp retro, agents ran `bbr … --help` 88 times in 32 sessions. Each session also loaded `SKILL.md` and `VERBS.md`, about 15k characters together. Most of these sessions only fetched and answered PullRequest Comments.

## Proposal

- Remove the step that makes `--help` mandatory. Keep `--help` as the fallback when a flag is unclear.
- Add a short section for the PullRequest Comment loop with complete commands: list the open Comments, reply to a Comment, and resolve a Comment. Use the defaults from tickets 01 and 02.
- Add complete commands to read a snapshot of several PullRequests and to report the changes since a saved snapshot (tickets 04 and 05).
- Check each command against `--help` before you write it into the skill.
- Keep `~/.agents/skills/bbr` the same as `skills/bbr`.

## Acceptance criteria

- [ ] `SKILL.md` has no mandatory `--help` step.
- [ ] `SKILL.md` has complete commands for the PullRequest Comment loop, and each command runs as written.
- [ ] The test "skills/bbr/VERBS.md lists every bbr api verb once" passes.
- [ ] `python3 tools/check_agent_docs.py` passes.
