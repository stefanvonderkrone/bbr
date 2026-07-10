# Domain Docs

How engineering skills consume this repository's domain documentation.

## Layout

This is a multi-context repository. `CONTEXT-MAP.md` names the contexts, routes to their `CONTEXT.md` glossaries, and describes relationships between them. System-wide architectural decisions live in `docs/adr/`; context-specific decisions may live under `src/<context>/docs/adr/`.

## Before exploring

- Read `CONTEXT-MAP.md`.
- Read every per-context `CONTEXT.md` relevant to the work.
- Read system-wide and context-specific ADRs touching the area.
- If a file is absent, proceed silently; domain-modeling skills create documentation lazily when a term or decision is actually resolved.

## Use the glossary vocabulary

Use canonical domain terms in issue titles, plans, hypotheses, tests, and implementation discussion. Do not substitute synonyms that a glossary explicitly marks with `_Avoid_`.

If a needed concept is absent, reconsider whether the codebase actually uses it or note a genuine gap for the domain-modeling workflow.

## Flag ADR conflicts

Surface contradictions explicitly rather than silently overriding an ADR, including why reopening the decision may be warranted.
