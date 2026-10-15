# Agent guidance

Only use subagents if the user explicitly requests them.

## Agent skills

### Issue tracker

Issues and PRDs are tracked as local Markdown under `.scratch/`; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` states. See `docs/agents/triage-labels.md`.

### Domain docs

Read `GLOSSARY-MAP.md` for domain vocabulary and relationships. Read `docs/code-navigation.md` to find implementation owners. System-wide decisions live under `docs/adr/`. See `docs/agents/domain.md`.
