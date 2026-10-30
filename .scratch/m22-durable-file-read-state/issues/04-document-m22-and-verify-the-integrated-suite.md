# 04: Document M22 and verify the integrated suite

Status: ready-for-agent
Blocked by: 02, 03
Spec: [M22 spec](../SPEC.md)

## What to build

The glossaries, the agent documents, and the README describe the shipped M22 behavior.
The integrated hermetic suite passes with every M22 test.

## Scope

- Apply the glossary changes from the "Glossary changes" section of the spec.
  Edit the Review, Presentation, and Diff glossaries.
- Add the `FileReadStore` seam to the "Seams" list in `docs/code-navigation.md`.
- Add the two M22 rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
  Make sure that each named test exists with that exact name.
- Describe `m`, `toggle_file_read`, bold unread Files, and bold Directory rows in `README.md`.
  State that read state stays local and never goes to Bitbucket.
- In the M22 section of `TODO.md`, replace "discard stale receipts for changed or no-longer-participating Files".
  The new text states that preparation only reads receipts and that the next mark replaces a stale receipt.
- Check each M22 TODO line that the evidence proves.
- Run the integrated checks and record the results under `## Completion` in this ticket.

## Acceptance criteria

- [ ] The glossary entries match the spec and use the glossary terms exactly.
- [ ] `docs/code-navigation.md` names `FileReadStore`, its SQLite adapter, and its in-memory fake.
- [ ] `AGENTS.md` has the two M22 rules, and each named test exists.
- [ ] `README.md` documents the `m` binding, the Action name, and the local-only storage.
- [ ] `TODO.md` matches decision 3 of the brief.
- [ ] `python3 tools/check_agent_docs.py` passes.
- [ ] `zig fmt --check build.zig src`, `zig build`, and `zig build test-file-read` pass.
- [ ] `zig build test --summary all` passes, and the reported test count is higher than before M22.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`
