# 24: Check that a published Session never changes its Diff or Threads

Status: ready-for-agent
Blocked by: none

## Summary

The search candidate key of ticket 07 covers the Diff, the Threads, and the mention names only by their identity and the Session epoch.
This is correct only while a published Session never changes these values in place.
Refresh and Reconciliation make a new Session with a new epoch today, so the rule holds.
No compile error, lint, or test enforces the rule.
A later change that edits a Thread or the Diff in place keeps the same key, and Buffer Search then shows stale matches with no error.

The triage decides how to enforce the rule at the highest level that works.
For example, the Session can expose these values only as `const` data, or a test can fail when an in-place edit keeps the key.
The triage also decides if the rule belongs in the `AGENTS.md` rules table.

## What to build

Make the mention names of a Session read-only after the Session loader builds them, so that all three inputs that the search candidate key covers by identity are read-only data.

- `Session.mention_names` in `src/tui/session.zig` becomes `*const review_body.MentionNames`, with `&.empty` as its default.
- `resolveMentions` fills a local `MentionNames` in the Session arena and sets the field to a pointer to it when it is complete. No code changes the map after that.
- Each reader that takes `&session.mention_names` reads `session.mention_names`.
- The test "mention display survives reprojection and both searches while yank keeps authored bytes" in `src/tui/presentation.zig`, which puts a name into the map before `Presentation.init`, builds its own map and sets the field instead.
- The `.mention_names` arm of `SearchCandidateInputs.key` in `src/tui/buffer.zig` hashes the pointer value. Its doc comment and the `session_epoch` doc comment name the rule and the types that hold it.
- Add one row to the `AGENTS.md` rules table. Rule: a published Session never changes its Diff, Threads, or mention names, and a change makes a new Session with a new Session Epoch through Refresh or Reconciliation. Enforcement: the types `[]const File`, `[]const Hunk`, `[]const Line`, `*const Comment`, and `*const MentionNames` make an in-place change a compile error. The search candidate key covers a field reassignment by identity. A `@constCast` or a field reassignment after publication is a convention (no check), and the row names why: test fixtures change a Session legitimately before publication, and no text check can see publication.

## Acceptance criteria

- [ ] `Session.mention_names` is `*const review_body.MentionNames`. Only `resolveMentions` and test fixtures before publication set it.
- [ ] A scratch call of `session.mention_names.getOrPut(...)` in production code fails to compile after the change and compiles at `aba58b5`. Record both compiler results in the Completion. Do not commit the scratch call.
- [ ] Buffer Search and ReviewCards still show resolved mention names: the existing mention name tests pass unchanged, apart from the fixture setup.
- [ ] The `AGENTS.md` rules table has the new row.
- [ ] `zig build test` passes.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Comments

### 2026-11-16 triage

The runner asked for a triage of tickets 23 and 24 together, and set this ticket to `ready-for-agent`. Ticket 23 is blocked by this ticket.

**Premise.** The premise is true at `aba58b5`, and only one of the three inputs can change in place without a `@constCast`.

- `SearchCandidateInputs.key` in `src/tui/buffer.zig:1283-1285` covers the Diff by `files` pointer and length, the Threads by pointer and length, and the mention names by the address of the Session field. The Session Epoch is a value.
- The Diff is read-only data: `Diff.files` is `[]const File` (`src/diff/model.zig`), `File.hunks` is `[]const Hunk`, and `Hunk.lines` is `[]const Line`.
- The Threads are read-only data: `Session.threads` is `[]const Thread` (`src/tui/session.zig:51`), and a Thread holds `*const Comment` and `[]const *const Comment` (`src/review/thread.zig:24-25`).
- The mention names are not. `Session.mention_names` is a `StringHashMapUnmanaged` held by value (`src/tui/session.zig:52`, `src/tui/review_body.zig:7`). Any code with a `*Session` can call `getOrPut` on it, and the key, which hashes only the field address, stays the same.
- Today only the loaders change it, through `resolveMentions` (`src/tui/session.zig:98`, called at 298 and 349) before publication. A Session replacement takes `next_session_epoch + 1` (`src/tui/presentation.zig:13415`), and only `createInputs` sets `published.session` (4462-4463).
- A field reassignment, such as `session.threads = new`, changes the pointer, so the key changes. It stays the same only when the new slice gets the address and length of the old one in the same Session.
- The five `@constCast` edits of Session content are in test fixtures, all before `Presentation.init`: `src/tui/presentation.zig:21034`, `21722`, `21928`, `25716`, and `26068`. No production code edits a published Session.

**The rule matters beyond the key.** `DisclosureBuild.create` retains the published Session (`src/tui/presentation.zig:2930-2935`), and its worker reads `session.diff`, `session.threads`, and `session.mention_names` (`searchCandidateInputs` and `buildBuffer`, 3215-3249) while the Presentation thread owns the Session. So an in-place change after publication is also a data race, and the key is not the only code that depends on the rule.

**Level.** The fix is a type change, the second level of the `correct` skill.

- Architecture was rejected. Moving the Diff, Threads, and mention names into a separate read-only object touches about 214 uses of `session.diff`, `session.threads`, and `session.mention_names` in `src`. It still leaves the field reassignable, because a Zig struct field cannot be read-only.
- Types close the only in-place path that compiles today. After the change, an in-place edit of any of the three needs a `@constCast`.
- A lint on `@constCast` or on field assignments was rejected. The five fixture edits are legitimate, because they run before publication, and a text check cannot see publication. A baseline of five exceptions would also fail on each new legitimate fixture.
- A test that fails when an in-place edit keeps the key was rejected. It would need the forbidden edit to exist, so it proves nothing about production code.
- A Debug assertion that compares the identity at publication with the identity at each build was rejected. The key already sees a reassignment with a new address, so the assertion would cover only an address reuse in the same arena.

**Effect on ticket 23.** This ticket does not remove the identity fields from the key, because a field reassignment stays possible. It changes the `.mention_names` arm, so do it first and give ticket 23 a stable key to replace.
