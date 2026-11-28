# Make every task spawn safe without a test

Status: ready-for-agent
Blocked by: none

## Problem

`diagnostics.concurrent` and `diagnostics.selectConcurrent` in `src/diagnostics.zig` panic in a Debug build when a task argument holds a `Handle` with a slot. The check is a runtime walk of the argument values, so it runs only in a Debug build and only for a spawn that a test reaches. A spawn that no test reaches has no check. A release build has no check.

`CODING_STANDARDS.md` says that each new production task spawn has a Debug test that reaches it. The operator decided that this rule must be enforced, not only reviewed. The existing worker spawns in `drainPresentationCommands` in `src/tui/app.zig` have no such test today.

A check that each spawn is reached by a test needs an inventory of the spawn sites, a record of the reached sites from every test binary, and a build step after all test runs. The `zig_test` runs of `zig build test` are cached, so a cached run writes no record. That design depends on build-system internals that change between Zig versions. This ticket removes the need for it.

## Proposal

Make the wrapper safe in every build mode, so that a spawn needs no test for its slot check.

1. **Strip the slots.** `concurrent` and `selectConcurrent` copy `args` and set `leaf = null` on each `Handle` that the copy holds by value: in itself, in a field, in an optional, in an array element, or in the active field of a tagged union. The task gets the copy. Pointers stay as they are. A Debug build keeps the existing panic before the strip, so a mistake on a tested path still fails loudly.
2. **Reject a pointer to a Handle holder at compile time.** Each argument that is a single-item pointer to a type that holds a `Handle` by value is a compile error. The message names the argument type and the fix: pass the task its own slot as `*?Leaf` and pass the `Handle` by value. `mayHoldHandle` needs `@setEvalBranchQuota`, because the walk of the large worker types exceeds the default quota of 1,000 backward branches.
3. **Move the rules.** The rule section "A task gets its slot by pointer" in `docs/rules/diagnostics.md` names the strip and the compile error as its enforcement. Remove the standards "Each new task spawn is reached by a Debug test" from `CODING_STANDARDS.md`. Narrow "A task argument holds no slot behind a pointer" to what the compile error cannot see: a pointer behind a pointer and a type-erased source such as `anyopaque`.

## Evidence

A prototype on `origin/main` at 2026-11-23 showed the following:

- Each of the 26 spawn instantiations passes a `Handle` by value, directly or inside `bitbucket.client.Client`, `highlight.highlighter.Highlighter`, or `tui.file_enrichment.Request`. A compile-time ban of every by-value `Handle` therefore needs a type split of those types. The strip needs no change at a spawn site.
- With the strip, `zig build` and `zig build test` pass. The full run took 3 min 17 s.
- No spawn argument is a single-item pointer to a type that holds a `Handle`. The compile error of step 2 passes on the current tree. The `PagedLists` Slot pointers and the `*?Leaf` slot pointers are not rejected.

The prototype of step 1:

```zig
fn stripSlots(subject: anytype) void {
    const T = @TypeOf(subject.*);
    if (T == Handle) {
        subject.leaf = null;
        return;
    }
    if (comptime !mayHoldHandle(T)) return;
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!field.is_comptime) stripSlots(&@field(subject.*, field.name));
        },
        .optional => if (subject.*) |*child| stripSlots(child),
        .array => for (subject) |*item| stripSlots(item),
        .@"union" => switch (subject.*) {
            inline else => |*payload| stripSlots(payload),
        },
        else => {},
    }
}
```

## Limits

- A release build that passes a slot by mistake loses that evidence without a message. Today the same mistake lets two tasks overwrite each other's evidence. The evidence tests in `src/tui/app.zig`, `src/tui/session.zig`, `src/tui/file_enrichment.zig`, and `src/bitbucket/client.zig` read the leaf evidence on the tested paths.
- The compile error sees one pointer level. A pointer behind a pointer and a type-erased source stay a standard in `CODING_STANDARDS.md`.
- A type split of `Handle` into a type with a slot and a type without one would make every wrong spawn a compile error. It changes `Client`, `Highlighter`, `Request`, and all 26 spawn instantiations. It is out of scope.
- A Debug test for each worker spawn in `drainPresentationCommands` is still useful for behavior. It is not part of this rule.

## Acceptance criteria

- [ ] A test in `src/diagnostics.zig` shows that the strip removes a slot from a `Handle` by value, in a struct field, in an optional, in an array element, and in a tagged union, and keeps each pointer.
- [ ] A single-item pointer argument to a type that holds a `Handle` is a compile error with a message that names the type and the fix. A compile-error regression test or a `tests/` script that compiles a bad spawn shows it.
- [ ] `docs/rules/diagnostics.md` names the strip and the compile error as enforcement. `CODING_STANDARDS.md` no longer holds "Each new task spawn is reached by a Debug test", and its pointer standard names only what the compile error cannot see.
- [ ] `python3 tools/check_agent_docs.py` and `zig build test` pass.

## Comments

### 2026-11-18 filed

The operator asked for this ticket and said that rules must be enforced.

### 2026-11-24 triage

- The first proposal recorded each reached spawn site in a test build and failed `zig build test` on an unreached site. Triage rejected it. The `zig_test` runs are cached, the sites sit in at least 8 test binaries, and the record hand-off depends on build-system internals.
- The operator chose the strip and the compile error. The file name changed with the scope. `CODING_STANDARDS.md` links the new name.
