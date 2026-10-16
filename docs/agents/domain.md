# Domain Docs

How engineering skills consume this repository's domain documentation.

## Layout

This is a multi-context repository.
[`GLOSSARY-MAP.md`](../../GLOSSARY-MAP.md) names the contexts, links their `GLOSSARY.md` files, and describes their relationships.
Each `GLOSSARY.md` contains domain vocabulary.
[`Code navigation`](../code-navigation.md) maps implementation owners and seams.
Context-specific `IMPLEMENTATION.md` files contain code entry points, API quirks, and runtime notes.
System-wide architectural decisions live in `docs/adr/`.
Context-specific decisions can live under `src/<context>/docs/adr/`.

## Before exploring

- Read `GLOSSARY-MAP.md`.
- Read every per-context `GLOSSARY.md` relevant to the work.
- For implementation work, follow `docs/code-navigation.md` to the relevant code owners and implementation notes.
- Read system-wide and context-specific ADRs touching the area.
- If a file is absent, proceed silently; domain-modeling skills create documentation lazily when a term or decision is actually resolved.

## Use the glossary vocabulary

Use canonical domain terms in issue titles, plans, hypotheses, tests, and implementation discussion. Do not substitute synonyms that a glossary explicitly marks with `_Avoid_`.

If a needed concept is absent, reconsider whether the codebase actually uses it or note a genuine gap for the domain-modeling workflow.

## Flag ADR conflicts

Surface contradictions explicitly rather than silently overriding an ADR, including why reopening the decision may be warranted.
