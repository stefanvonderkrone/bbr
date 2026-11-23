"""Writes rule.json. Edit the rule text here, then run python3 .opencodereview/build_rules.py."""

import json
from pathlib import Path

SCOPE = """# bbr review rules

bbr is a Zig 0.16 terminal UI for Bitbucket pull requests, built on libvaxis.
Report a defect only when you can name the trigger, the path through the code, and the effect.
Give the line, the cause, and the smallest fix. Do not report style that `zig fmt` or a check in `tools/` already handles.
Before you report intended behavior as a defect, read the ADRs in `docs/adr/` and the area rule in `docs/rules/`.
Verify a Zig API against ZIG.md before you claim that it behaves in a particular way."""

THREADS = """## Thread safety (highest priority)

The thread model is in ZIG.md section 2 and in `.agents/skills/zig/runtime.md`.
- Only the main thread changes UI state: Presentation, a Session after publication, a Buffer, a Frame, and the vaxis loop. A worker delivers its result as an event through `loop.postEvent`. Report each worker that writes state that the main thread reads, unless a mutex or an atomic protects it.
- `gpa` belongs to the main thread. A worker allocates from `std.heap.page_allocator` or from an arena that it owns, and moves ownership to the main thread through the event. This toolchain has no `std.heap.ThreadSafeAllocator`.
- `std.Io.concurrent`, `async`, and `groupAsync` copy the argument tuple by value. A slice copies only its header. Report a task argument whose backing storage can be freed or reused before the task ends.
- Await every future before code destroys state that the worker can reach, such as the event queue, the HTTP Client, a Session, or an arena.
- Share the `std.http.Client`, never a `Request`. Each worker owns and deinitializes its Request.
- A task gets only its own diagnostic slot by pointer. A task argument holds no `Handle` with a slot behind a pointer or a type-erased source.
- The last reference of a shared Session is released on the thread that owns the Session, also when a worker cannot deliver its completion.
- Wrap a write that must finish, such as a diagnostic record, in `io.swapCancelProtection(.blocked)`. Call `io.recancel()` only in the task that received the cancelation.
- Keep each lock and its unlock in one scope. Report a lock that is held across a blocking call, an `Io` call, or a callback.
- After a required concurrent step fails, start no dependent work, but still await the work that started.
- When concurrent results can arrive in any order, such as pages, the merge must not depend on arrival order."""

DOD = """## Data-oriented design

Apply these rules only on a hot path: a loop per row, per cell, or per Line, a paint, a Buffer or Frame rebuild, a search scan, or a loop over all Files. Name the hot path in the finding. Do not report cold paths.
- Refer to an element of a growable list by index, not by pointer. Report a pointer or slice into an `ArrayList`, a `MultiArrayList`, or a hash map that lives across an append, an insert, a remove, or a rebuild.
- Keep hot structs small. Report a new field in a struct that a hot loop iterates when the loop does not read the field. Suggest moving cold data to a side table indexed by the same index.
- Prefer `std.MultiArrayList` when a hot loop reads only a few fields of a struct with many fields.
- Report two or more `bool` fields that encode one state. Use an enum or a tagged union.
- Report an `?T` or a padded struct in a large array when a sentinel value or a separate bit set does the same job.
- Report an allocation for each item on a hot path. Use the per-frame arena, a scratch arena, or one batch allocation.
- When a list or map size is known before its loop, reserve that size first. Before each `appendAssumeCapacity` or `insertAssumeCapacity`, check that the reserved capacity covers every item that the path can stage, including items that a callback or a release stages.
- Answer a question about one File through an index, such as `fileIndexForRow`, not through a scan of all rows.
- Bound quadratic work with saturating arithmetic (`*|`, `+|`) before an allocation, and keep a fallback above the bound.
- Report repeated work on each rebuild when the result depends only on immutable input, such as the Diff."""

SAFETY = """## Memory, illegal behavior, and errors

- Memory from `allocator.create` or `alloc` is undefined. Default field values do not apply. Report a field that is read before the code assigns it.
- Free each temporary allocation that does not escape, or put it in a local scratch arena.
- Do not hash or compare a struct with `std.mem.asBytes` when it contains padding, slices, or pointers.
- Clamp each value from the network, a file, or the environment before `@intCast`, a duration conversion, or a sleep.
- Guard each `for (a..b)` and each slice `[a..b]` against `a > b` when an endpoint comes from layout arithmetic or input.
- Use saturating arithmetic or an overflow check when a user setting can reach the maximum of its type.
- Report `.?` on a path where an earlier mode, such as local or demo mode, leaves the optional null.
- `vaxis` cells borrow their text until `render`. Report text from a stack buffer or from memory freed before the render.
- Follow `docs/rules/diagnostics.md`: one record per failure. Report `catch null`, `catch {}`, `_ = err;`, or an `else` prong over a whole error set when the code means to skip one expected error. `OutOfMemory`, `Canceled`, and the other errors must propagate.
- A `catch` whose error set contains `error.Canceled` names `error.Canceled`. A cancelation does not count toward a retry or give-up limit and starts no retry. A diagnostic record of the cause before `io.recancel()` is not such a count.
- An `errdefer` that records a diagnostic must record the correct phase for every error that can pass it.
- On each failure branch, restore the state that the success path changed before the call, such as a hidden Overlay, a pending destination, or a status message that the user must see."""

DOCS_DRIFT = """## Docs must not drift

When the change alters a behavior, a name, a key, a command, a limit, or a rule, search for it with `code_search` in `docs/`, `CODING_STANDARDS.md`, `ZIG.md`, `FEATURES.md`, `TODO.md`, `README.md`, `AGENTS.md`, the `GLOSSARY.md` files, `skills/bbr/`, and `.agents/skills/`. Report each text that the change makes stale, and name the file and the line. A doc that the diff does not touch can still be stale."""

GUARDS = """## Do not report these

- `_ = f() catch |err| { ... };` compiles in Zig 0.16 and discards the payload.
- A comparison of two runtime error values, such as `err != leaf.err`. The ban on error comparisons covers only error literals.
- An exhaustive `switch` over a tagged union without an `else` prong. An `else` prong is a compile error there.
- A parser bug, before you trace every index increment in the loop.
- Behavior that an ADR records, such as silent speculative File Enrichment failures (ADR 0010).
- Missing doc comments. bbr adds a comment only for a reason that the code cannot show.
- A missing test that an earlier commit adds. bbr often adds the failing test in the commit before the fix. Before you report a missing test, run `git log -5 --stat`. Drop the finding only when an earlier commit adds a test that reaches the changed code."""

TUI = """## TUI state and paint

Read `docs/rules/tui-state.md`, `docs/rules/tui-paint.md`, and the TUI sections of `CODING_STANDARDS.md` for the area of the change.
- Build a label or a Title from an exhaustive `switch` over the state enum, not from a list of `if` checks.
- No code changes a published Session through `@constCast`, a field reassignment, or a mutable alias.
- State that outlives its Frame holds no row number and no `*const bbr.diff.Line`. Make Line row identities through `LineOwner.of`.
- A change to a key handler that reads keys outside the Keymap updates `help.fixed_sections` in `src/tui/help.zig`.
- `presentation.zig` imports no vaxis and no `theme.zig`.
- Apply a geometry change before an action that reads the viewport.
- A rebuild that a worker runs carries a snapshot. Report a snapshot that a later main-thread change makes stale and that nothing checks at acceptance.
- A queued cache update keeps its place in the queue. Only a Review Search source scan can pass it."""

CONTRACTS = """## API, CLI, and file contracts

Read `docs/rules/cli.md` before a finding about stdout, stderr, or a config path.
- A paginator stops on a repeated `next` link.
- Treat an empty environment variable as unset. Accept only an absolute `HOME` or XDG base directory for a fallback path.
- Reject invalid flags and trailing input before any network call or storage write.
- Write stdout only through `bbr.stdout`. Write stderr through `File.writerStreaming`. After a recorded failure, a failed stderr write returns `error.Reported`.
- An atomic replace through a symlink resolves the link first.
- Open a config file with `O_NONBLOCK` and check the descriptor type before the read.
- Turn off terminal echo while a secret is read, and restore it in a `defer`."""

BUILD = """# bbr build rules

Read `docs/rules/build-and-checks.md` and ZIG.md section 5.
- A source file belongs to one module only. Shared declarations go through the public API of the `bbr` module.
- Only the exe module links libc and SQLite. The `bbr` core module and its tests stay C-free.
- Pin each dependency by commit and hash in `build.zig.zon`.
- A new test file is reached from a `test { _ = @import(...); }` chain, or its tests do not run.

""" + DOCS_DRIFT + "\n\n" + GUARDS

TOOLS = """# bbr line-check rules

The scripts in `tools/` enforce the rules in `docs/rules/`. `zig build test` runs them.
- Remove comments and string literals before a match. Use the shared `tools/source_lines.py`.
- Match across line breaks, both operand orders, and `test` blocks nested inside a struct.
- Report a check that can pass on a violation, or fail on correct code. Name the input that does it.
- Each check has a test in `tests/` with a violation and a passing case.
- Read files as UTF-8 explicitly, and set a timeout on each subprocess.
- The message of a failed check names the rule and the fix.

""" + DOCS_DRIFT

DOCS = """# bbr documentation rules

The docs of bbr are agent instructions and rules. A wrong doc makes an agent write wrong code.
- Check each claim about code against the code: names, paths, line numbers, keys, commands, limits, and counts. Report each claim that the code does not support.
- An Enforcement line names a mechanism that rejects the violation: a compile error, a test, or a check in `tools/`. Report a claim that a type or a convention enforces a rule when nothing fails on a violation.
- A rule in `CODING_STANDARDS.md` says why no check covers it and links its related checked rule.
- Report links to missing files, to ignored paths, or to machine-local paths such as `/var/folders/` or `file://`.
- Use one term for each thing, the term from `GLOSSARY-MAP.md` and the glossaries.
- Use ASD-STE100 Simplified Technical English: one thought per sentence, active voice, simple tenses, no semicolons, and no em dashes."""

ZIG_CORE = "\n\n".join([SCOPE, THREADS, DOD, SAFETY, DOCS_DRIFT, GUARDS])

rules = {
    "include": ["src/**/*_test.zig", "tests/**/*.py", "**/*.md"],
    "exclude": [
        "vendors/**",
        "zig-pkg/**",
        ".zig-cache/**",
        "zig-out/**",
        ".scratch/**",
        ".agents/**",
        ".opencode/**",
    ],
    "rules": [
        {"path": "src/tui/**/*.zig", "rule": ZIG_CORE + "\n\n" + TUI, "merge_system_rule": True},
        {"path": "src/**/*.zig", "rule": ZIG_CORE + "\n\n" + CONTRACTS, "merge_system_rule": True},
        {"path": "{build.zig,build.zig.zon}", "rule": BUILD, "merge_system_rule": True},
        {"path": "{tools,tests}/**/*.py", "rule": TOOLS, "merge_system_rule": True},
        {"path": "**/*.md", "rule": DOCS},
    ],
}

target = Path(__file__).with_name("rule.json")
target.write_text(json.dumps(rules, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
