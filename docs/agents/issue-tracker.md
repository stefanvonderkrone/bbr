# Issue tracker: Local Markdown

Issues and PRDs for this repo live as Markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/`, creating the directory if needed.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or issue number directly.

If you need to find a ticket, set the search directory to `.scratch/` and use a relative pattern.
For example, use Glob with `path: <checkout>/.scratch` and one of these patterns:
`**/SPEC.md`, `**/PRD.md`, or `**/issues/*.md`.
Root-level Glob patterns such as `.scratch/**/*.md` can return no files even when the files exist.
Read the `.scratch/` directory before you treat an empty search result as an absent ticket.

For a feature, read its `map.md` and follow the links to its decisions and implementation tickets.
Use paths from the current checkout because a feature's files can differ between Worktrees.

## Wayfinding operations

Used by `/wayfinder`. The map is a file with one child file per ticket.

- **Map:** `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket:** `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records `research`, `prototype`, `grilling`, or `task`; a `Status:` line records `claimed` or `resolved`.
- **Blocking:** a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every listed file is `resolved`.
- **Frontier:** scan `.scratch/<effort>/issues/` for open, unblocked, unclaimed files; first by number wins.
- **Claim:** set `Status: claimed` and save before any work.
- **Resolve:** append the answer under `## Answer`, set `Status: resolved`, then append a context pointer to the map's Decisions-so-far.
