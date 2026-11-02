# M27 binary size and startup cost

This file records the cost of the M27 BuiltInGrammars.
Ticket 12 measured it on 2026-10-31.

## Summary

| Value | Before (`4cb5365`) | After (`c65a2f9`) | Change |
| --- | --- | --- | --- |
| `zig-out/bin/bbr` bytes, `zig build` (Debug) | 38,096,224 | 87,445,520 | +49,349,296 (+130%) |
| `zig-out/bin/bbr` bytes, `zig build -Doptimize=ReleaseSafe` | 12,980,144 | 57,526,080 | +44,545,936 (+343%) |
| Clean ReleaseSafe build, wall time, median of 3 | 64.45 s | 66.90 s | +2.45 s (+4%) |
| Clean ReleaseSafe build, user CPU time, 1 run | 192.86 s | 234.62 s | +41.76 s (+22%) |
| `TreeSitterHighlighter.init`, ReleaseSafe, median of 5 medians | 28.3 ms | 422.2 ms | +393.9 ms (15 times) |
| Highlight benchmarks of the M13 fixtures | see below | see below | under 1.5% on each fixture |

No Grammar is dropped for size.
The SPEC sets no limit on any value.

The largest user-visible cost is the `TreeSitterHighlighter.init` time.
`src/main.zig` calls `TreeSitterHighlighter.init` before `app.run`.
So the ReleaseSafe bbr starts about 0.39 s later before the TUI shows its first frame.
The SPEC puts lazy query preparation out of scope, so M27 keeps this cost.

## Host and toolchain

- Host: Apple M5 Pro (`Mac17,8`), 18 cores, macOS 26.7.1 (build 25G241).
- Toolchain: `zig version` prints `0.16.0`. The binary is `/opt/homebrew/bin/zig`.
- Native target: `aarch64-macos`. The bench reports `target_cpu=apple_m1`.
- Before: commit `4cb5365`, the M27 planning commit.
- After: commit `c65a2f9`, the M27 integration commit at the time of the measurement.
- Each side was a temporary Worktree from `git worktree add --detach`.
  The Worktrees were under `$TMPDIR/m27/` and are now removed.
- No other agent ran during the measurements.
  The load average was between 2.4 and 8.3, from other desktop programs.
  `top` showed no process above 11% CPU.
  The before and after runs alternate, so both sides saw the same load.

## Executable size

The `size zig-out/bin/bbr` output of the ReleaseSafe build:

```text
before:
__TEXT	__DATA	__OBJC	others	dec	hex
11212736	555488	0	4296442432	4308210656	100ca13e0

after:
__TEXT	__DATA	__OBJC	others	dec	hex
55448556	654688	0	4296639040	4352742284	10371938c
```

The `size` output of the Debug build:

```text
before: 27561844	3389376	0	4302374048	4333325268	102494bd4
after:  74902632	5159744	0	4302620040	4382682416	1053a6d30
```

`size -m zig-out/bin/bbr` on the ReleaseSafe build shows where the bytes go:

| Section | Before | After | Change |
| --- | --- | --- | --- |
| `__TEXT,__text` | 5,336,336 | 7,862,744 | +2,526,408 |
| `__TEXT,__const` | 5,166,320 | 46,679,888 | +41,513,568 |
| `__TEXT,__cstring` | 287,014 | 470,385 | +183,371 |
| `__DATA,__const` | 241,864 | 310,352 | +68,488 |
| `__DATA,__data` | 34,152 | 64,904 | +30,752 |
| `__LINKEDIT` | 1,474,560 | 1,671,168 | +196,608 |

### What dominates the growth

The parse tables of the new Grammars are almost all of the growth.
A tree-sitter `parser.c` holds its parse table, lex modes, and symbol metadata as `static const` arrays.
The compiler puts these arrays in `__TEXT,__const`.

To prove it, `size -m` ran on each `parser.o` and `scanner.o` in the ReleaseSafe `.zig-cache`.
`nm -gU` named the Grammar of each object by its exported `tree_sitter_<name>` symbol.
For the 21 new Grammars, the objects sum to 41,500,871 bytes of `__TEXT,__const` and 2,495,200 bytes of `__TEXT,__text`.
The executable grows by 41,513,568 and 2,526,408 bytes in the same sections.
So the vendored parsers explain more than 99% of the `__TEXT` growth.
The embedded queries, the manifest, and the Zig code explain the rest.

The `__TEXT,__text` and `__TEXT,__const` bytes of each new Grammar, parser and scanner together:

| Grammar | Bytes |
| --- | --- |
| `sql` | 11,709,896 |
| `kotlin` | 5,873,176 |
| `cpp` | 5,694,460 |
| `c_sharp` | 5,400,964 |
| `swift` | 4,427,734 |
| `odin` | 2,213,174 |
| `ruby` | 2,157,108 |
| `rust` | 1,113,614 |
| `php` | 1,078,232 |
| `groovy` | 924,712 |
| `zig` | 685,668 |
| `c` | 681,812 |
| `python` | 452,204 |
| `markdown` | 449,519 |
| `markdown_inline` | 446,411 |
| `java` | 397,250 |
| `make` | 149,268 |
| `xml` | 48,397 |
| `dockerfile` | 47,012 |
| `toml` | 25,032 |
| `html` | 20,428 |

SQL alone is 26% of the growth.
SQL, Kotlin, C++, C#, and Swift together are 74% of the growth.
The SPEC names these five Grammars as the risk for size.

The Debug executable grows by 49 MB, a little more than the ReleaseSafe executable.
The parse tables have the same size in both modes, and Debug code is larger.

## Clean build time

Method:

- A clean build has no local `.zig-cache` and no `zig-out`.
- Each side has its own `--global-cache-dir`.
  Before each run, the script deletes everything in that directory except `p/`.
  `p/` holds the fetched `vaxis` and `zf` packages, so the build uses no network.
  So the global cache is cold: compiler_rt, libc++, RE2, and every module compile again.
- `zig build --fetch --global-cache-dir <dir>` filled `p/` once before the first run.
- The command is `zig build -Doptimize=ReleaseSafe --global-cache-dir <dir>`.
  It builds `bbr` and the benchmark executables, because the install step depends on both.
- The runs alternate: before, after, before, after, before, after.

| Run | Before | After |
| --- | --- | --- |
| 1 | 70.18 s | 73.01 s |
| 2 | 62.05 s | 65.50 s |
| 3 | 64.45 s | 66.90 s |
| Median | 64.45 s | 66.90 s |

Each after run is 2.4 s to 3.5 s slower than the before run next to it.
The gap is the same size as the spread between runs, so the wall time grows by a few seconds at most.

A fourth run on each side used `/usr/bin/time -p`:

| Side | Real | User | Sys |
| --- | --- | --- | --- |
| Before | 66.01 s | 192.86 s | 27.34 s |
| After | 67.12 s | 234.62 s | 32.92 s |

The new Grammars add 41.8 s of CPU time but only about 1 s to 3 s of wall time.
The build compiles the C sources in parallel on 18 cores.
So the wall time follows the longest serial step, not the C compile.
That step is probably the LLVM compile of the Zig modules.
This is an inference from the user and real times. No profile of the build ran.

## `TreeSitterHighlighter.init` time

Method:

- A temporary patch added the case `m27_init_time` to `src/benchmark/main.zig` on both sides.
  The patch was identical on both sides and is not in the repository.
- The case calls `TreeSitterHighlighter.init(gpa, null)` and `deinit` 3 times to warm up.
  Then it times 21 calls of `init` with `std.Io.Clock.awake` and calls `deinit` after each.
  It prints the minimum, the median, and the maximum.
- `zig build -Doptimize=ReleaseSafe` builds `bbr-bench` in ReleaseSafe.
- Five processes ran on each side, in alternating order.
- The case prints the package count of the last `init`.
  It is 8 before and 29 after, so every BuiltInGrammar query was prepared in the timed region.

| Process | Before median (min to max) | After median (min to max) |
| --- | --- | --- |
| 1 | 28.77 ms (28.50 to 32.09) | 425.81 ms (424.47 to 433.26) |
| 2 | 28.41 ms (28.20 to 28.61) | 426.46 ms (423.10 to 434.41) |
| 3 | 28.26 ms (27.98 to 29.34) | 420.35 ms (417.89 to 431.80) |
| 4 | 28.12 ms (27.74 to 28.95) | 422.18 ms (417.62 to 431.49) |
| 5 | 27.94 ms (27.68 to 28.17) | 418.22 ms (414.11 to 445.99) |

### What limits `init`

`init` prepares one Grammar after the other on one core.
A `sample` profile of the after build during `m27_init_time` shows the top of the stack:

| Function | Samples |
| --- | --- |
| `ts_query__perform_analysis` | 2,780 |
| `ts_query_new` | 372 |
| `analysis_state_set__insert_sorted` | 356 |
| `_platform_memmove` | 69 |

So `ts_query_new` in the tree-sitter runtime uses almost all of the time.
It analyzes each query pattern against the parse table of its Grammar.
RE2 and the predicate validation do not show in the profile.

A second temporary patch timed each `RuntimePackage.init` call inside `TreeSitterHighlighter.init`.
The medians over 24 calls:

| Grammar | Median | Grammar | Median |
| --- | --- | --- | --- |
| `cpp` | 80.3 ms | `groovy` | 7.5 ms |
| `swift` | 60.2 ms | `c` | 6.7 ms |
| `c_sharp` | 59.6 ms | `markdown` | 4.2 ms |
| `php` | 33.3 ms | `javascript` | 3.8 ms |
| `ruby` | 27.3 ms | `java` | 3.7 ms |
| `odin` | 25.4 ms | `markdown_inline` | 2.3 ms |
| `kotlin` | 19.3 ms | `yaml` | 2.1 ms |
| `rust` | 19.0 ms | `bash` | 1.3 ms |
| `sql` | 13.5 ms | `make` | 1.3 ms |
| `python` | 11.7 ms | `go` | 0.7 ms |
| `tsx` | 10.2 ms | `html` | 0.2 ms |
| `zig` | 10.1 ms | `css` | 0.2 ms |
| `typescript` | 9.8 ms | `xml` | 0.1 ms |
| | | `dockerfile`, `toml`, `json` | under 0.1 ms each |

The sum is 413.9 ms, close to the measured 422 ms of the whole `init`.
The 8 M13 Grammars sum to 28.1 ms, the same as the before value.
So the new Grammars explain the full growth, and the M13 Grammars did not get slower.
C++, Swift, and C# take 48% of the time.
The C++ query inherits the C query, so it probably has the most patterns on a large parse table.
This cause is an inference. No count of patterns ran.

## Highlight benchmarks

Method:

- `zig build` builds `bbr-bench` in ReleaseFast, the default mode of `zig build bench`.
- `bbr-bench <fixture>` ran 3 times on each side for each M13 fixture, in alternating order.
- Each process runs 2 warmups and 15 samples and prints the median of the samples.
- The table gives the median of the 3 process medians and their range.
- Each fixture printed the same output checksum on both sides.
  So both sides produced the same Spans, and no run failed.

| Fixture | Before, ms (range) | After, ms (range) | Change |
| --- | --- | --- | --- |
| `highlight_javascript_4k` | 0.46 (0.45 to 0.47) | 0.46 (0.45 to 0.46) | -0.8% |
| `highlight_javascript_100k` | 12.56 (12.53 to 12.64) | 12.62 (12.59 to 12.68) | +0.5% |
| `highlight_javascript_1m` | 283.66 (282.97 to 283.88) | 285.38 (285.01 to 285.88) | +0.6% |
| `highlight_javascript_2m` | 937.02 (910.15 to 939.28) | 940.03 (910.38 to 941.04) | +0.3% |
| `highlight_typescript_2m` | 499.77 (499.74 to 500.07) | 501.52 (491.81 to 501.97) | +0.3% |
| `highlight_tsx_2m` | 1233.74 (1226.25 to 1235.21) | 1238.09 (1228.24 to 1243.04) | +0.4% |
| `highlight_css_2m` | 298.94 (298.91 to 304.89) | 302.45 (300.98 to 303.43) | +1.2% |
| `highlight_go_2m` | 186.10 (183.53 to 187.52) | 185.74 (184.35 to 188.68) | -0.2% |
| `highlight_bash_2m` | 255.38 (254.80 to 256.96) | 257.12 (256.72 to 258.61) | +0.7% |
| `highlight_json_2m` | 195.69 (193.87 to 197.19) | 194.77 (194.71 to 195.55) | -0.5% |
| `highlight_yaml_2m` | 72.12 (71.84 to 72.33) | 72.68 (72.39 to 74.34) | +0.8% |
| `highlight_equal_javascript_100k` | 24.93 (24.77 to 26.40) | 25.28 (25.26 to 25.41) | +1.4% |

Most ranges overlap.
`highlight_javascript_1m`, `highlight_bash_2m`, and `highlight_yaml_2m` are slower by less than 1% with no overlap.
A cause for this small change is a guess: `CaptureInterval` now carries a Capture, a priority, and a depth.
The M13 fixtures have no injection query, so they run no Injection layer.
Ticket 10 records the tree-sitter runtime as the limiter of the highlight benchmarks.

The after side also has the new fixture `highlight_markdown_1m`.
One ReleaseFast process gave a median of 381.35 ms.
Ticket 10 records 434 ms in ReleaseSafe for the same fixture.

The `peak_bytes` value changed on several fixtures.
For example, `highlight_json_2m` went from 35,287,234 to 80,154,088 bytes, and `highlight_css_2m` went from 119,695,066 to 96,568,552 bytes.
`highlight_tsx_2m` printed two different values in the 3 after runs.
This file does not explain these changes, and the SPEC does not ask for them.

## Lazy preparation (ticket 15)

On 2026-11-02, the operator chose lazy loading.
Ticket 15 measured the change on the same host, with the same toolchain.

- Before: commit `c5fb81d`. After: the ticket 15 change on top of `c5fb81d`.
- A temporary patch added the case `m27_lazy_timing` to `src/benchmark/main.zig` on both sides.
  The patch is not committed.
- The case times 21 calls of `TreeSitterHighlighter.init` after 3 warm-up calls, and prints the median.
- For each File type, the case creates 11 new highlighters.
  It times the first highlight and the second highlight of a small fixture on each, and prints the medians.
- `zig build -Doptimize=ReleaseSafe` built `bbr` and `bbr-bench` on each side.
- The values are the medians of 3 runs of `bbr-bench m27_lazy_timing`.

| Value | Before | After |
| --- | --- | --- |
| `TreeSitterHighlighter.init`, median | 423 ms | below 1 µs |
| First highlight of a `.cpp` File | 0.07 ms | 87 ms |
| First highlight of a `.swift` File | 0.07 ms | 64 ms |
| First highlight of a `.cs` File | 0.07 ms | 64 ms |
| First highlight of a `.md` File with `zig` and `js` fences | 0.13 ms | 22 ms |
| First highlight of a `.js` File | 0.04 ms | 4 ms |
| First highlight of a `.zig` File | 0.03 ms | 11 ms |
| Later highlight of the same File, each type | 0.006 ms to 0.06 ms | 0.006 ms to 0.08 ms |
| `zig-out/bin/bbr` bytes, ReleaseSafe | 57,549,040 | 57,531,904 |

The `init` time is below the 28 ms of the build before M27, because `init` now prepares no query.
The test "M27 lazy init prepares no BuiltInGrammar query" proves that `init` allocates nothing.
The first use of a Grammar now pays the `ts_query_new` time that `init` paid before.
These first-use times agree with the per-Grammar times above.
The `.md` value includes the Markdown, Markdown inline, Zig, and JavaScript Grammars.
`zig build test-builtin-grammars` took 126 s before and 31 s after, in Debug.
The binary size and the `vendors/` size do not change, so they stay open.
