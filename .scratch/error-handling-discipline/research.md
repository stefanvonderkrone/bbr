# Error handling in Zig: `try`, `catch`, and diagnostics

Research for bbr. Date: 2026-11-07.

## Sources and method

| Source | Version | Location |
| --- | --- | --- |
| Zig language reference | 0.16.0 | `doc/langref.html.in` at tag `0.16.0` (<https://codeberg.org/ziglang/zig/raw/tag/0.16.0/doc/langref.html.in>), rendered at <https://ziglang.org/documentation/0.16.0/> |
| Zig standard library | 0.16.0 | `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std`. This file writes `std/<path>:<line>`. |
| bbr | `ca3ff606` (main) | This repository |
| Ghostty | `5813c946` (main, fast-forward pull) | `/Volumes/Work/Github/ghostty`. Ghostty requires Zig 0.17.0 (`build.zig.zon:7`). |
| TigerBeetle | `68958eb7` (0.18.0, shallow clone) | `/Volumes/Work/Github/tigerbeetle` |
| TigerBeetle `tidy.zig` | tag `0.17.0` (`ac790315`) | `src/tidy.zig` is not in the 0.18.0 tree. I read it from <https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/0.17.0/src/tidy.zig>. |
| Yuan et al., OSDI 2014 | paper | <https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-yuan.pdf> |
| Zig issue #2647 | closed 2024-12-08 | <https://github.com/ziglang/zig/issues/2647> |

I counted the Ghostty and TigerBeetle sites with `rg`. I counted the bbr sites with the `production` and `CAUSE_DROP` functions of `tools/check_diagnostics.py`. Ghostty and TigerBeetle counts include tests. The bbr catch counts exclude tests.

I compiled three small Zig 0.16.0 programs to check two language facts. The section "Facts verified with the compiler" lists them.

## Summary

1. Zig treats an error as control flow, not as a message. Andrew Kelley closed the "errors with payloads" proposal with "Error codes are for control flow" ([#2647, 2024-12-08](https://github.com/ziglang/zig/issues/2647)). Detail goes through a side channel.
2. The stdlib uses one side-channel shape: an optional `Diagnostics` out-parameter or field (`std.json`, `std.zon`, `std.tar`, `std.zip`, `std.Target.Query`). `std.Io.Reader` and `std.Io.Writer` go further. They return one generic error and keep the cause in the concrete implementation's `err` field.
3. `try` is the default. Error return traces make it cheap to propagate and still find the origin in Debug builds (langref "Error Return Traces"). Handle the error where a decision is possible, or where the function cannot return an error.
4. The stdlib itself writes an intentional drop as an exhaustive switch that names each dropped error: `catch |err| switch (err) { error.WriteFailed => {} }` (`std/debug.zig:887-892`). The compiler rejects that form when the callee gains a new error. So a sanctioned drop form already exists, and the compiler checks it.
5. `catch |_|` is a compile error in Zig 0.16 ("discard of error capture; omit it instead"). One alternative in bbr's `CAUSE_DROP` comment can never match compiled code.
6. Yuan et al. found that 92% of catastrophic failures came from bad handling of explicit non-fatal errors. 25% came from ignored errors, and a handler that only logs counts as ignoring. So recording a cause through a Handle does not make a drop correct. The handler must also restore a valid state.
7. Ghostty propagates with `try` inside a subsystem and catches at each thread entry, xev callback, and C ABI export. There it logs with a scoped `std.log` and `key=value` text, and goes on. Only 4 of its 92 `catch {}` sites have a comment on the same or the previous line.
8. Ghostty tests `errdefer` paths with `src/tripwire.zig`, a fault-injection module that costs nothing outside tests. bbr already uses `std.testing.checkAllAllocationFailures` in some files.
9. TigerBeetle separates programmer errors (assertions, crash) from operating errors (must be handled). For environment failures where stopping is the right answer, it calls `vsr.fatal` with one exit code per reason, and does not propagate the error.
10. TigerBeetle's `tidy.zig` (0.17.0) is a Zig test. It does text bans plus AST checks. One ban is `== error.` and `!= error.` ("switch to avoid silent anyerror upcast"). It has no baseline. bbr's catch ratchet has no equivalent there.
11. Of bbr's 381 cause-dropping sites, most are not mysterious. 64 of the 92 sites in `src/tui/render.zig` are scratch `allocPrint` with a fallback label. 47 sites in `src/tui/presentation.zig` set `action_error = .out_of_memory`. 91 sites are `catch return error.X` translations. These groups can move to checked forms in bulk.

## Zig language and standard library

### Error sets, `anyerror`, inferred sets

- An error set is like an enum. Each error name gets one integer for the whole compilation (langref 0.16.0, `langref.html.in:2957-2963`).
- A subset coerces to a superset. A superset does not coerce to a subset (`langref.html.in:2970-2977`).
- `anyerror` is the global error set. The langref says it "should generally be avoided because it prevents the compiler from knowing what errors are possible at compile-time" (`langref.html.in:2990-3004`).
- An inferred error set (`!T`) makes the function generic. It cannot be a function pointer target, can differ across targets, and does not work with recursion. In those cases the langref recommends an explicit error set (`langref.html.in:3207-3226`).
- `||` merges two sets. The stdlib uses it for platform-specific sets (`langref.html.in:3191-3205`).
- `@errorCast` converts between error sets. A value outside the destination set is safety-checked Illegal Behavior (`langref.html.in:4912-4918`).

### `try`, `catch`, and the four choices

The langref lists four ways to use an error union (`langref.html.in:3028-3037`):

1. Give a default value: `catch value`.
2. Return the same error: `try`.
3. Unwrap because the error cannot happen: `catch unreachable`.
4. Take a different action per error: `if ... else |err| switch (err)`.

Details:

- `try x` is shorthand for `x catch |err| return err` (`langref.html.in:3055-3069`).
- The right side of `catch` must have the payload type or be `noreturn` (`langref.html.in:3042-3046`).
- A `switch` on the error can handle some errors and return the rest: `else => |leftover_err| return leftover_err`. The rest has a narrower error set (`langref.html.in:3101-3116`).
- `catch unreachable` "invokes safety-checked Illegal Behavior". In Debug and ReleaseSafe it panics when the assumption is wrong (`langref.html.in:3071-3083`). The langref offers it as the way to ignore an error on purpose and still crash in safe modes (`langref.html.in:3174-3178`).
- In ReleaseFast and ReleaseSmall, the optimizer assumes that `unreachable` is never reached (`langref.html.in:2846-2851`). So a wrong `catch unreachable` there is unchecked Illegal Behavior (`langref.html.in:6061-6078`).

### `errdefer`

- `errdefer` runs only when the block exits with an error. The cleanup sits directly after the acquisition (`langref.html.in:3131-3164`).
- `errdefer |err|` can capture the error (`langref.html.in:3166-3168`).

### Error return traces

- An error return trace shows each point where an error was returned to the caller. "This makes it practical to use try everywhere and then still be able to know what happened" (`langref.html.in:3229-3231`).
- It also shows when a handler replaced one error with another, which a stack trace does not show (`langref.html.in:3235-3251`).
- It is on by default in Debug only. It is off in ReleaseSafe, ReleaseFast, and ReleaseSmall (`langref.html.in:3259`).
- It activates when `main` returns an error, when an error reaches `catch unreachable`, or through `@errorReturnTrace()` with `std.debug.dumpErrorReturnTrace` (`langref.html.in:3262-3268`, `4903-4910`).
- The cost on the success path is about one memory write (`langref.html.in:3269-3313`).

Consequence: a release build of bbr has no error return trace. The `@src()` in a `diagnostic.Failure` is the only origin a release diagnostic file has.

### Allocation failure

- Zig libraries return `error.OutOfMemory` and do not crash. "By convention, Zig programmers do not consider this to be a satisfactory solution" to crash on allocation failure (`langref.html.in:6468-6475`).
- The Zen says: "Runtime crashes are better than bugs." "Compile errors are better than runtime crashes." "Resource allocation may fail; resource deallocation must succeed." (`langref.html.in:8532-8538`).
- The stdlib follows the last rule. `std.mem.Allocator.free` returns `void` (`std/mem/Allocator.zig:443`). `std.Io.File.close` returns `void` (`std/Io/File.zig:221`).
- `std.testing.checkAllAllocationFailures` runs a test once per allocation and fails each allocation in turn (`std/testing.zig:1115`, doc comment above it).

### Assertions

- `std.debug.assert(ok)` is `if (!ok) unreachable`. In Debug and ReleaseSafe it panics. In ReleaseFast and ReleaseSmall the optimizer uses it as a fact (`std/debug.zig:405-421`).
- So an assertion is for a programmer error, never for input that can be wrong.

### Unexpected operating system errors

- `error.Unexpected` means that the OS returned an undocumented code. The doc says "it would be better to handle this error than to invoke undefined behavior" (`std/Io.zig:709-719`).
- `std.posix.unexpectedErrno` prints the code and a stack trace only when `std.options.unexpected_error_tracing` is on. That option is on only in Debug (`std/posix.zig:1667-1675`, `std/std.zig:186-191`).
- `std.Io.Threaded.errnoBug` panics in Debug for an errno that shows a programmer bug. In release it returns `error.Unexpected` (`std/Io/Threaded.zig:14054-14057`).

### Diagnostics side channels in the stdlib

The stdlib never puts a payload on an error. It uses a side channel.

| API | Shape | Citation |
| --- | --- | --- |
| `std.json.Scanner` | `diagnostics: ?*Diagnostics = null`. Line, column, and byte offset are valid "notably just after an error". | `std/json/Scanner.zig:61`, `1542-1565` |
| `std.zon.parse.fromSlice` | `diag: ?*Diagnostics` parameter. On `error.ParseZon` it stores a readable explanation. | `std/zon/parse.zig:194`, `255-273` |
| `std.tar` | `diagnostics: ?*Diagnostics` option. Some errors go into the list and are not returned. The caller must check the list. Entries carry `code: anyerror`. | `std/tar.zig:25-50`, `134` |
| `std.zip`, `std.Target.Query` | Same optional `Diagnostics` field. | `std/zip.zig:613`, `649`, `std/Target/Query.zig:186-188` |
| `std.Io.Reader` | `error.ReadFailed`: "See the `Reader` implementation for detailed diagnostics." | `std/Io/Reader.zig:112-116` |
| `std.Io.Writer` | `error.WriteFailed`: "See the `Writer` implementation for detailed diagnostics." | `std/Io/Writer.zig:91-94` |
| `std.Io.File.Reader` and `File.Writer` | The real cause is in `err: ?Error`. Separate fields hold size and seek errors. | `std/Io/File/Reader.zig:19-29`, `std/Io/File/Writer.zig:12-18` |

The 0.15.1 release notes give the reason for the Reader and Writer design. "The old interface passed errors through … This made errors in streams about as useful as anyerror. The new interface carefully defines precise error sets for each function with actionable meaning." The reading example marks `error.ReadFailed` with "caller can check reader implementation for diagnostics" (<https://ziglang.org/download/0.15.1/release-notes.html>).

Note that `std.tar` uses `anyerror` in a diagnostics payload. bbr's `diagnostic.Cause.zig: anyerror` follows the same pattern (`src/diagnostic.zig:79`). That is the side channel, not a function error set, so the langref advice against `anyerror` does not apply.

### Cancelation

- `error.Canceled` is in `std.Io.Cancelable` (`std/Io.zig:704-707`).
- A cancel request makes only the next cancelation point return `error.Canceled`. Later points do not signal it again. "As such, it is usually a bug to ignore `error.Canceled`" (`std/Io.zig:1181-1188`).
- `io.recancel()` re-arms the request after code caught it (`std/Io.zig:1305-1311`).
- `swapCancelProtection(.blocked)` stops all cancelation points. The doc example then writes `error.Canceled => unreachable` (`std/Io.zig:1314-1343`).

### The stdlib's own intentional drops

- Counts in the 0.16.0 stdlib: 688 `catch |err|`, 525 `catch |err| switch (err) {`, 323 `catch unreachable`, 210 `catch return`, 130 `catch {}`, 0 `catch |_|`, 334 `errdefer`.
- The stdlib writes some drops as a switch that names the dropped error:
  - `std.debug.dumpErrorReturnTrace` has the doc "ignores write errors". Its body is `catch |err| switch (err) { error.WriteFailed => {} }` (`std/debug.zig:887-892`). The same form is at `std/debug.zig:800` and `882`.
  - `std/crypto/tls/Client.zig:343` writes `error.EndOfStream => {}, // We have assurance the remainder of stream can be buffered.`
- Other drops are plain `catch {}` in cleanup paths. Examples: `dirDeleteFile(...) catch {}` after it blocks cancelation (`std/Io/Threaded.zig:7381-7382`), and a flush that runs only when no earlier error exists (`std/Io/Threaded.zig:13834`).

### Facts verified with the compiler

I compiled these with Zig 0.16.0:

1. `std.fmt.allocPrint(a, ...) catch |err| switch (err) { error.OutOfMemory => "n=?" }` compiles, because the set is exactly `error{OutOfMemory}`.
2. The same switch on `Dir.openFile` fails with "'error.OutOfMemory' not a member of destination error set". So a prong that names an error the callee cannot return is a compile error. A callee that gains an error makes the switch non-exhaustive, which is also a compile error.
3. `f() catch |_| 0` fails with "discard of error capture; omit it instead".

## Ghostty

Commit `5813c946`. Ghostty requires Zig 0.17.0 (`build.zig.zon:7`). So some stdlib names can differ from bbr's 0.16.

### Error sets

- Named sets are common: 149 `pub const …Error =` declarations. Merges are frequent:
  - `src/App.zig:76`: `pub const CreateError = Allocator.Error || font.SharedGridSet.InitError;`
  - `src/pty.zig:60`
- Inferred `!T` is also common in app and surface code, for example `src/termio/Thread.zig:236`.
- `anyerror` has 64 hits in 10 files. Most are test callbacks, type-erased vtables, and the C snapshot error mapper (`src/terminal/c/snapshot.zig:637`).
- A comptime assertion pins a narrow error set at a drop site: `src/apprt/embedded.zig:262` `comptime assert(@TypeOf(err) == error{OutOfMemory});` then `return .unknown`. This is a checked drop, like the stdlib switch form.
- For a switch that must compile on all platforms, Ghostty widens the set and uses `@errorCast`. `src/termio/Thread.zig:158-167` explains this: "Windows doesn't have OpenptyFailed".

### Logging

- About one scope per file: 191 `std.log.scoped(` declarations in 190 files.
- The format is `key=value`, with context fields before `err`. Examples:
  - `log.warn("error in renderer err={}", .{err})` (`src/renderer/Thread.zig:196`).
  - `"error opening requested working directory dir={s} err={}"` (`src/apprt/embedded.zig:531-533`).
  - `err={}` occurs 468 times.
- A custom `logFn` writes to the macOS unified log and to stderr. `GHOSTTY_LOG` picks the destinations (`src/main_ghostty.zig:118-168`, `HACKING.md:114-124`).
- About 451 of 808 `catch |err|` sites have a `log.*(` call on the next line (multiline `rg` estimate).

### Boundaries: where Ghostty catches

- **Thread entry.** A `void` `threadMain` calls a `!void` `threadMain_` and logs the error. The comment is "Call child function so we can use errors..." (`src/renderer/Thread.zig:193-197`). The termio thread also writes the error text into the terminal, because "the user would just see a blank terminal window" (`src/termio/Thread.zig:136-218`). It then keeps the event loop running to drain the mailbox (`src/termio/Thread.zig:223-233`).
- **Event loop callbacks.** They cannot return an error. They log and rearm (`src/renderer/Thread.zig:480-483`). They switch on `error.Canceled => return .disarm` (`src/renderer/Thread.zig:660-662`).
- **C ABI.** Each `export fn` wraps a `foo_()` and maps an error to a sentinel such as `null`, `false`, or `.empty` (`src/apprt/embedded.zig:1704-1712`, `1058-1061`). libghostty-vt returns a `Result` enum with `out_of_memory = -1` (`src/terminal/c/result.zig:2-12`).
- **Terminal stream.** A failed VT action sets `semantic_failure = true` and logs. The stream goes on (`src/terminal/stream_terminal.zig:46-58`, `614-617`). The doc says: "A terminal can't really stop in the middle it must go on. But this is flagged to true to let consumers know some sort of unhandle-able error state happened."

### Allocation failure

- Ghostty usually propagates `OutOfMemory` in explicit sets (`src/termio/stream_handler.zig:1092`).
- A self-contained subsystem can degrade: "an OOM … degrades it without corrupting terminal state, so we log" (`src/terminal/stream_terminal.zig:809-812`).
- Some functions document that they leave state unchanged on OOM: "It is safe to ignore the error" (`src/terminal/PageList.zig:3680-3682`).
- `catch unreachable` goes mostly on fixed buffers and discarding writers, sometimes with a reason: "Blank value can never fail because no allocs happen." (`src/termio/stream_handler.zig:1524`).

### `errdefer` discipline and fault injection

- An `errdefer` follows each acquisition at once (`src/renderer/Thread.zig:124-149`). A block limits an `errdefer` when ownership moves: "Renderer.init takes ownership of the config only on success … so this errdefer must end here" (`src/Surface.zig:575-578`, `662-673`).
- `src/tripwire.zig` is fault injection for error paths. The module doc says: "Improper `errdefer` is one of the highest sources of bugs in Zig code. Many `errdefer` points are hard to exercise in unit tests and rare to encounter in production, so they often hide bugs" (`src/tripwire.zig:1-8`).
  - A test arms a named point, for example `errorAlways(point, error.OutOfMemory)`. Production code calls `try tw.check(.point)` (`src/tripwire.zig:21-50`).
  - It is enabled only when `builtin.is_test` (`src/tripwire.zig:128`).
  - `end` fails with `error.UntrippedError` when an armed point never fired (`src/tripwire.zig:196-212`).
  - 14 modules use it, for example `src/terminal/Screen.zig:2537` and `src/font/Atlas.zig:829-863`.

### Intentional drops

- Counts in `src/`: 92 `catch {}`, 808 `catch |err|` (173 of them `catch |err| switch`), 151 `catch unreachable`, 325 `catch return`, 64 `catch @panic`, 40 `catch null`, 0 `catch |_|`, 721 `errdefer`.
- 4 of 92 `catch {}` sites have a comment on the same or the previous line. With nearby block comments, the share is about 10 to 15%. Most drops are on calls whose failure is not important, such as thread `setName`, `wakeup.notify()`, and flush.
- Explained examples: the stderr print in a child after a failed exec ("We MUST NOT return any other error condition", `src/Command.zig:264-287`), and a flush ("Flushing *shouldn't* fail but...", `src/cli/edit_config.zig:66`).
- `src/os/stderr.zig:10-12` says: "best-effort: errors are ignored, since this is only used for diagnostics".

### Diagnostics side channel

- `src/cli/args.zig:40-42`: when the destination has a `_diagnostics` field, parse errors go into that `DiagnosticList`, and "only allocation errors will be returned". This is the `std.tar` shape.
- `DiagnosticList` entries carry a location (`cli:index` or `file{path,line}`), a key, and a message (`src/cli/diagnostics.zig:13-55`, `87-111`).

### Documented conventions

- `CONTRIBUTING.md`, `HACKING.md`, and the root `AGENTS.md` say nothing about error handling.
- `src/terminal/c/AGENTS.md:82-100` has C ABI rules:
  - A C value must be checked in every build mode before it becomes a Zig enum.
  - "Never guard the check with `std.debug.runtime_safety`."
  - Getters and setters return `Result` "even when every current option always succeeds, so new options can report errors".
- `src/quirks.zig:32-57` defines `inlineAssert`. The reason is that `std.debug.assert` "isn't always optimized away in `ReleaseFast`" and costs "as much as 15-20%" in tight loops.

## TigerBeetle

Commit `68958eb7` (0.18.0). `tidy.zig` from tag `0.17.0` (`ac790315`).

### TIGER_STYLE: assertions and errors

All lines refer to `docs/TIGER_STYLE.md`.

- "Assertions detect programmer errors. Unlike operating errors, which are expected and which must be handled, assertion failures are unexpected. The only correct way to handle corrupt code is to crash." (L104-107).
- Assertion density: "a minimum of two assertions per function" (L109-113).
- Pair assertions: assert one property on two code paths, for example before a disk write and after the read (L115-118).
- Assertions can replace a comment "where the assertion condition is critical and surprising" (L120-121).
- Compile-time assertions check design integrity "before the program even executes" (L128-134).
- Assert the negative space too. Test with invalid data (L136-140).
- "All errors must be handled." The guide cites Yuan et al. and quotes the 92% finding (L213-219).
- "Always motivate, always say why" (L221). Comments explain why (L360-361).
- "Put a limit on everything" (L96-100). Static allocation at startup, and no allocation after initialization (L151-152). 70 lines per function at most (L161-162).
- Return type order: "`void` trumps `bool`, `bool` trumps `u64`, `u64` trumps `?u64`, and `?u64` trumps `!u64`." (L426-429). An error union is the last choice for a return type.
- The guide says nothing direct about `anyerror`, `catch unreachable`, `errdefer`, or `OutOfMemory`.

### `fatal` instead of propagation

- `vsr.FatalReason` assigns "a separate exit status for each fatal condition", for example `no_space_left = 2` (`src/vsr.zig:699-713`).
- The `vsr.fatal` doc: "Use fatal when encountering an environmental error where stopping is the intended end response. … Propagating fatal errors up the stack needlessly increases dimensionality (unusual defers might run), but doesn't improve experience --- the leaf of the call stack has the most context for printing error message. Don't use fatal for situations which are necessarily bugs … use assert or panic instead." (`src/vsr.zig:715-730`).
- `src/storage.zig` sets a policy per error:
  - A read `EIO` is retried by binary search over sectors, then treated as a checksum failure (L267-294).
  - Other read errors are "impossible" and panic after `log.err` (L313-327).
  - `NoSpaceLeft` calls `fatal` (L419-421).
  - An fsync failure panics (L497).
- The network path logs with `warn` and closes the connection. The protocol retries (`src/message_bus.zig:691-695`).

### Error sets at boundaries

- The IO layer has explicit sets, for example `ReadError = error{ … } || posix.UnexpectedError` (`src/stdx/io/linux.zig:1038-1048`).
- An errno switch maps each code:
  - `.INTR` re-enqueues the completion.
  - `.FAULT => unreachable` marks a programmer error.
  - `.AGAIN => error.WouldBlock`.
  - `else` goes to `stdx.unexpected_errno` (`src/stdx/io/linux.zig:470-488`).
- `stdx.unexpected_errno` logs in every build mode, not only in Debug. Its label "works around the absence of stack traces in ReleaseSafe builds" (`src/stdx/stdx.zig:1026-1038`).
- An impossible error is closed off by name: `bufPrint(...) catch |err| switch (err) { error.NoSpaceLeft => unreachable }` (`src/stdx/stdx.zig:1021-1022`).
- The C client maps Zig error sets to C status enums with exhaustive switches and no `else` (`src/clients/c/tb_client_exports.zig:21-37`, `78-87`, `117-126`).
- Callers that never cancel mark `error.Canceled => unreachable` with a reason, for example "We don't cancel anything." (`src/stdx/process.zig:714`).

### Enforcement: `tidy.zig`

- `tidy.zig` is a Zig `test "tidy"` (`src/tidy.zig:19` at 0.17.0). For each `.zig` file it runs text checks and then parses the file with `std.zig.Ast.parse` for AST checks (`src/tidy.zig:219-241`).
- `tidy_banned` does a plain `std.mem.indexOf` for each banned string and names a replacement (`src/tidy.zig:302-344`). Relevant bans:
  - `"== error."` and `"!= error."` with "switch to avoid silent anyerror upcast" (L328-329).
  - `"unexpectedErrno"` with `stdx.unexpected_errno` (L324).
  - `"debug.assert("` with "unqualified assert" (L332).
- `FIXME` and `dbg(` are reminders. Developers use them while they work, and tidy fails on them before merge (L346-357).
- Other checks: line length, function length, dead declarations, `defer` newlines, and Markdown titles (L375-1100).
- Exemptions are code, not data: two file paths skip the bans (L304-306). Call sites dodge a ban with a split token and a comment such as "(Bypass tidy's ban.)" (`src/stdx/stdx.zig:134-135`, `196`, `949-950` at 0.18.0).
- Tidy has no baseline or ratchet. Each check has zero tolerance.
- `src/static_allocator.zig` enforces static allocation at run time. `alloc`, `resize`, and `remap` assert that the state is `.init` (L60-72). `free` is allowed in `.deinit` "To make errdefer cleanup easier" (L16-17).
- `tidy.zig` is not in the 0.18.0 tree. The 0.18.0 changelog says "Tidy now fails on LLM-authored contributions" (`CHANGELOG.md:168`). I did not find where tidy lives now.

### Counts

Counts in `src/` at 0.18.0, tests and fuzzers included: 8514 `assert(`, 238 `comptime assert(`, 307 `maybe(`, 128 `catch unreachable`, 42 `catch {}`, 191 `catch |`, 38 `catch return`, 13 `anyerror`, 481 `errdefer`, 170 `@panic(`.

`maybe(ok)` is "the dual of `assert`". It documents that a condition can be true or false (`src/stdx/stdx.zig:394-401`).

## Other primary sources

### Zig issue #2647: errors with payloads

- The proposal asks for a value with an error, for example the position of a bad character.
- Andrew Kelley closed it as not planned: "Error codes are for control flow." (2024-12-08).
- marler8997 described the side-channel pattern. A caller passes `*FooError`. The callee fills it and returns `error.Foo` through a `set` function.
- Andrew Kelley then described the compiler's own pattern (2024-12-10). Many compiler parts have a `fail` helper that records the message and returns `error{AlreadyReported}` or a similar one-error set, for example `fn fail(diags: *Diags, …) error{LinkFailure}` in `src/link.zig`. "Then error.AlreadyReported is used to indicate the error state has already been recorded somewhere and you can keep using try."
- Other commenters raise lifetime problems for payloads that point to memory (ayende, 2025-02-20). This is opinion from the thread, not a decision.

### Yuan et al., "Simple Testing Can Prevent Most Critical Failures" (OSDI 2014)

- 198 failures in Cassandra, HBase, HDFS, MapReduce, and Redis. 48 were catastrophic (Table 1).
- "almost all (92%) of the catastrophic system failures are the result of incorrect handling of non-fatal errors explicitly signaled in software." (p. 250, Finding 10).
- 35% of catastrophic failures came from three trivial patterns (p. 256, Finding 11):
  - The handler ignores the error (25%). "an error handler that only logs the error is also considered as ignoring the error".
  - The handler over-catches and aborts (8%).
  - The handler has "TODO" or "FIXME" (2%).
- Another 23% would show up with 100% statement coverage of the handler (Finding 12).
- About "can never happen" comments in empty handlers: "errors that 'can never happen' should be handled defensively … developers' judgement could be wrong, later code evolutions may enable the error" (p. 261).
- Their checker, Aspirator, excluded `FileNotFound` and exceptions in shutdown, close, and cleanup methods to reduce false positives (p. 259).
- Cassandra had the fewest bugs per handler. "The vast majority of the exceptions are handled by recursively propagating them to the callers, and are handled by top level methods in the call graphs" (p. 261).

## Comparison

| Topic | Zig language and stdlib | Ghostty | TigerBeetle | bbr today |
| --- | --- | --- | --- | --- |
| Propagation | `try` by default. Error return traces in Debug make it cheap. Explicit sets for pointers, recursion, and cross-target code. | `try` inside subsystems. Named sets with `\|\|`, and inferred sets in app code. | Explicit sets at the IO and client boundaries. `!T` is the last choice of return type. Environment failures call `fatal`, not propagate. | `try` everywhere (about 17,900 `try ` including tests). 205 `anyerror` mentions, many in `diagnostic.Cause` and reporters. |
| Dropping errors | `catch unreachable` for impossible errors. `catch \|err\| switch (err) { error.X => {} }` for named drops. Some plain `catch {}` in cleanup. | 92 `catch {}`, about 4% with an adjacent comment. `comptime assert(@TypeOf(err) == error{OutOfMemory})` at some drops. | 42 `catch {}`, mostly cleanup and tooling. Named `error.X => unreachable` in stdx. | 381 cause-dropping sites under a per-file ratchet. |
| Logging and diagnostics | `std.log` scopes and levels. Side channels: optional `Diagnostics` or the implementation's `err` field. | Scoped `std.log`, `key=value`, custom `logFn`. `DiagnosticList` for config. `semantic_failure` flag. | Scoped `std.log`, `key=value` with `@errorName`. `unexpected_errno` logs in every mode. `fatal` has one exit code per reason. | Typed `diagnostic.Failure` with `@src()` through `diagnostics.Handle` into an opt-in `Sink`. `std.log` is banned. |
| Assertions | `assert` is `unreachable` with a condition. It is an optimizer fact in fast modes. | `inlineAssert` for hot loops. `assertIntegrity` checks. | At least two per function. Pair, compile-time, and negative-space assertions. `maybe()`. | 38 `assert` sites in `src/`. `comptime` blocks for layout, Theme, and diagnostic safety. |
| Enforcement | Compiler: exhaustive error switch, no `catch \|_\|`, unused error results. | Tripwire fault injection. No written error rules. | `tidy.zig` test: text bans and AST checks, zero tolerance, no baseline. Runtime `StaticAllocator`. | Python lint scripts. A per-file catch ratchet. Compile-time `assertSafe`. Rule table in `AGENTS.md`. |

## Implications for bbr

These are proposals. Each one names the bbr mechanism it touches. The order is by expected value per unit of work.

### 1. Sanction one checked drop form, and let the ratchet count it as handled

- Form: `catch |err| switch (err) { error.OutOfMemory => fallback }`. The prong names every dropped error. No `else` prong.
- Why it is safe: the compiler rejects the switch when the callee gains a new error, and it rejects a name the callee cannot return. Each site is then a compile-time ratchet.
- Precedent: the stdlib (`std/debug.zig:887-892`) and TigerBeetle (`src/stdx/stdx.zig:1021-1022`) use it.
- The current `CAUSE_DROP` regex already accepts this form, because the form has a named capture. So the gap is the other way round. Some captured forms still drop the cause, and the lint cannot see them:
  - `catch |err| { _ = err; ... }`.
  - A capture switch with an `else =>` prong that neither records nor returns.
- Proposal: extend `tools/check_diagnostics.py` to count those two forms as drops.
- Proposal: add a row for the form to the `AGENTS.md` rule table and a section to `ZIG.md`.

### 2. Convert the large groups in bulk

| Group | Sites (approximate) | Proposed form |
| --- | --- | --- |
| `allocPrint(scratch, …) catch "label"` in `src/tui/render.zig` | 64 of 92 | One helper, for example `labelOr(scratch, fmt, args, fallback)`, that holds the one OOM switch. The cause is known (OOM only), so nothing is lost. |
| `catch { self.action_error = .out_of_memory; … }` in `src/tui/presentation.zig` | 47 of 125 | The named OOM switch. The handler already restores a valid state and tells the user. Optionally also call `reportFailure` with `error.OutOfMemory`. |
| `catch return error.X` translations across `src/` | 91 | `catch \|err\| switch (err) { error.Overflow, error.InvalidCharacter => return error.InvalidNumber }`. The mapping becomes explicit and checked. |
| `bufPrint(&buf, …) catch unreachable` | 13 | `catch \|err\| switch (err) { error.NoSpaceLeft => unreachable }`, with an assertion or a comment on the buffer size. |
| `catch {}` | 21 | Review each one by hand. Keep a drop only for cleanup or best-effort output, for example a flush before an error exit. |

- Each conversion lowers `tools/diagnostic_catch_baseline.txt`. The baseline could fall from 381 to fewer than 100 sites. The rest are then the real review targets.
- Yuan et al. found that an empty handler or a log-only handler caused 25% of catastrophic failures. So the review of the rest must ask a second question: does the handler leave a valid state? Recording through a `diagnostics.Handle` alone does not answer it.

### 3. Remove the dead `catch |_|` alternative from the lint

- `catch |_|` is a compile error in Zig 0.16.
- Proposal: drop it from the comment and the regex, or keep it and say that it is defensive.
- This is minor. It prevents a false belief that the form can exist.

### 4. State where `try` stops: a boundary rule

- Proposed rule: inside a module, use `try`. Catch only at a function that cannot return an error, or that owns a user-visible decision.
- In bbr these are:
  - Worker task entry points.
  - Presentation event and command handlers. Presentation is a typed command-producing state machine (`docs/adr/0012`).
  - CLI `main`, through `exitFailure`.
  - The SQLite and HTTP seams that convert foreign codes into typed causes.
- At each boundary, record once through a `diagnostics.Handle`, then restore state or show the failure.
- This matches Ghostty's `threadMain`/`threadMain_` split (`src/renderer/Thread.zig:193-197`) and the Cassandra result in Yuan et al.
- A release build has no error return trace. So `@src()` at the boundary is the only origin. Propose to record at the deepest point that still has context, and to propagate after that.

### 5. Consider a `fail` helper that returns a one-error set

- Andrew Kelley's compiler pattern (#2647): `handle.fail(phase, cause, @src())` records the Failure and returns `error.Reported`.
- Callers above then use `try`, and no second layer records the same failure again.
- This fits the existing `Handle.failure` (`src/diagnostics.zig:21-25`). Today it returns a `Failure` value.
- Open point: `error.Reported` can collide with a real error at a boundary that maps errors to user messages. The boundary then needs a prong for it.

### 6. Make `ReadFailed`, `WriteFailed`, and `Canceled` explicit

- `ReadFailed` and `WriteFailed` carry no cause by design (`std/Io/Reader.zig:112-116`). `ZIG.md` and `.agents/skills/zig/stdlib.md:40-41` already say this.
- Proposal: one helper per concrete reader or writer type returns the stored `err`. Add a lint that rejects `.zig = err` in a `catch` whose callee is a `std.Io.Reader` or `Writer` method, unless the helper wraps it. This is hard with regex. See item 8.
- For `error.Canceled`, the stdlib says ignoring it "is usually a bug" (`std/Io.zig:1181-1188`). Proposal: a `catch` switch on an error set that contains `Canceled` must name `error.Canceled` in its own prong. The prong returns it, or calls `io.recancel()`, or sits under `swapCancelProtection(.blocked)` and writes `unreachable`. The convention is checkable in review now. A future AST check can verify it.

### 7. Adopt TigerBeetle's `== error.` ban

- `err == error.X` compiles against `anyerror` and silently widens the set. The compiler then cannot say that the name is impossible.
- bbr passes `anyerror` through `diagnostic.Cause` and `reportFailure`. So such comparisons are likely in reporting code.
- A ban fits as a line check in `tools/` through `zig_files` in `tools/source_lines.py`, with `literals=False`.
- Example present today: `src/tui/presentation.zig:1325` writes `if (err == error.OutOfMemory)`.

### 8. Consider an AST checker for catch sites

- TigerBeetle parses each file with `std.zig.Ast` inside a Zig test (`src/tidy.zig:229-233` at 0.17.0).
- An AST checker can see:
  - The `catch` payload.
  - Whether the right side is a `switch` with an `else` prong.
  - Whether the block uses the capture.
- The regex in `check_diagnostics.py` cannot do this reliably across lines. It now needs a "next line" special case, because 10 sites put the handler on the next line.
- Cost: a new kind of checker beside the Python tools. `AGENTS.md` requires that line checkers read through `tools/source_lines.py`. An AST checker would need its own row in the rule table.
- Opinion: do this only if items 1 and 2 leave a residue that the regex misclassifies.

### 9. Test error paths, not only the happy path

- Yuan et al.: 23% of catastrophic failures would show up with plain statement coverage of the handler.
- bbr already uses `std.testing.checkAllAllocationFailures` or `FailingAllocator` in about 10 files.
- Proposal: require it for each new function that builds owned state with more than one allocation and `errdefer`. Ghostty's tripwire shows a cheap way to inject non-OOM errors at named points (`src/tripwire.zig:21-50`).
- bbr already has a fake Io vtable for diagnostic write failures (`src/diagnostics.zig:261-285`). The same approach could inject `error.Canceled` into worker code.

### 10. Assertions: adopt the split, not the quota

- TigerBeetle's split is useful for bbr: an assertion is for a programmer error, and an error is for an operating condition. `std.debug.assert` becomes an optimizer fact in ReleaseFast (`std/debug.zig:405-421`). So an assertion on Bitbucket data or terminal input would be unchecked Illegal Behavior in a fast build.
- Opinion: the two-assertions-per-function quota fits a database with static allocation. It fits a TUI with many small render functions less well. Pair assertions at persistence seams (before a SQLite write and after the read) give the most value per assertion.
- bbr already uses `comptime` blocks as enforcement in the `AGENTS.md` rule table. That matches TigerBeetle's compile-time assertions.

### 11. Consider `fatal` for a small set of CLI conditions

- TigerBeetle stops at the leaf with one exit code per reason (`src/vsr.zig:699-730`).
- bbr's `exitFailure` in `src/main.zig` is the closest equivalent. Distinct exit codes per reason could help scripts that call `bbr api`.
- This is low priority. It does not apply to the TUI, which must recover and show the failure.

## Open questions

1. Is `error.OutOfMemory` in a render path an expected outcome or a failure to record? The ratchet text calls a cache miss expected. OOM in scratch paint is not clearly either.
2. If bbr adopts `error.Reported`, which boundary owns the user message, and how does the boundary tell "recorded" from "not recorded"?
3. Should a log-only `catch` (record, then go on) count as a drop for the ratchet, as Yuan et al. count it?
4. Can the lint identify a `std.Io.Reader` or `Writer` call without type information? If not, is the AST checker of item 8 worth its cost?
5. Where does TigerBeetle's tidy live after 0.18.0? The 0.17.0 version is the latest public copy I found.
6. Ghostty targets Zig 0.17. Which of its patterns depend on 0.17 APIs? The patterns cited here use only language features that 0.16 has.
7. Does the per-file ratchet need a per-site allow marker, like Aspirator's configuration or TigerBeetle's tidy dodges? Or does the checked switch form of item 1 make a marker unnecessary?
