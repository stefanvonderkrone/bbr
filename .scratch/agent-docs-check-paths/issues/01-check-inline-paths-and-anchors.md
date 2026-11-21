# Check inline-code paths and heading anchors in agent docs

Status: needs-triage
Blocked by: none

## Problem

`tools/check_agent_docs.py` checks the Markdown links in the agent docs and reports a target file that does not exist. Two kinds of reference stay unchecked:

- **Paths in inline code.** `prose()` removes inline code before the link check, so a path such as `src/tui/presentation.zig` is never checked. Most file references in bbr are inline code: the rules table in `AGENTS.md` alone names dozens of source and test files. A renamed or deleted file leaves a dead path, and the check still passes.
- **Heading anchors.** The check reads only the file part of a link and ignores `#anchor`. A renamed heading leaves a dead anchor, and the check still passes.

On November 11, a manual scan found no broken reference: 215 inline-code paths and 5 anchor links all resolved. This ticket prevents future drift. The retro in session `ses_e38baeb9cffe00nhxrCe6jCmIf` (ranked finding 6) found this kind of drift in the WebApp repo, where a skill still named a file that no longer exists.

## Proposal

- In the documents that the check already reads, also check each inline-code span that is a repo-relative path. A path counts when it starts with `src/`, `tests/`, `tools/`, `docs/`, `skills/`, or `.scratch/` and has a file extension. Triage decides the exact pattern and if glob patterns such as `src/**/GLOSSARY.md` are skipped.
- For each link with `#anchor` to a Markdown file, check that the target file has a heading with that anchor. Use the GitHub anchor rules: lower case, spaces become `-`, and punctuation is removed.
- Keep fenced code blocks excluded, as they are today.
- Triage decides if `skills/bbr/*.md` and the other `docs/*.md` files join the checked documents.
- `.scratch/` tickets name planned and example files that do not exist yet, this ticket too. Triage decides if the inline-path check skips `.scratch/`, or if tickets mark such paths.

## Acceptance criteria

- [ ] A missing file in an inline-code path such as `src/missing.zig` fails the check, with the document and the line number.
- [ ] A link to a heading that does not exist fails the check, with the document, the line number, and the anchor.
- [ ] Paths inside fenced code blocks are still not checked.
- [ ] The current agent docs pass.
- [ ] `tests/check_agent_docs_test.py` covers a missing inline path, a missing anchor, an existing anchor, and a path in a fenced block.
- [ ] `zig build test` passes.
