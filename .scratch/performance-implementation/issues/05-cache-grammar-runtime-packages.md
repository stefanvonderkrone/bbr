# Cache Grammar runtime packages

Type: task
Status: resolved
Blocked by: 01, 29

## Question

How will Action 3 compile and validate each Grammar query package once, make UserGrammar loading safe across workers, keep parsers and cursors call-local, and destroy cached queries before their libraries close?

## Comments

Added `highlight_javascript_100k`, a stage-isolated ReleaseFast benchmark with a stable Span checksum. The baseline median was 16,972,958 ns with a 17,683,375 ns p95 and 26,110 timed allocations.

Time Profiler, Allocations, and CPU Counters traces cover the baseline and changed benchmark. The baseline trace samples `ts_query_new` and `bbr_regex_compile` during repeated Highlighting calls. The changed trace sees query compilation only during Highlighter initialization.

## Answer

Each Grammar now owns one immutable `RuntimePackage`. The package owns the compiled Highlight query, optional Locals query, validated predicate tables, RE2 objects, Capture names, and Locals Capture identities. BuiltInGrammar packages compile during `TreeSitterHighlighter.init` and live until its matching `deinit`.

The UserGrammar Registry now attempts every active native-library load and package build during single-threaded Registry initialization. It stores either the immutable package or the load error before workers start. Worker calls only read this frozen state. A failed UserGrammar still falls back to a matching BuiltInGrammar or plain text.

Each Highlighting call still creates and destroys its own parser, syntax tree, Locals query cursor, and Highlight query cursor. No mutable tree-sitter execution object crosses a worker boundary.

Registry teardown destroys each UserGrammar package before it closes that package's dynamic library. Highlighter teardown destroys BuiltInGrammar packages.

The changed benchmark produced 13,001,042 ns and 13,083,417 ns medians in two runs. The first run's p95 was 13,558,041 ns. This is a 23.4% median reduction and a 23.3% p95 reduction from the baseline. Timed allocations fell from 26,110 to 26,105. All runs kept checksum `ac25b3368ca1037c`.

Profile assets are `../profiles/highlight-cache-baseline-{time,allocations,counters}.trace` and `../profiles/highlight-cache-changed-{time,allocations,counters}.trace`. The traces ran for 14.72 seconds and 12.75 seconds on the Apple M5 Pro host. CPU Counters is hardware evidence. Harness ceiling rates remain calibration proxies.

`zig build test --summary all` passes all 699 tests. `zig fmt --check build.zig src/highlight src/main.zig src/benchmark tests/grammar_cli_integration.zig` and `git diff --check` pass.
