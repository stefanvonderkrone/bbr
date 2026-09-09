# Index Buffer rows by File

Type: task
Status: resolved
Blocked by: 01, 29

## Question

How will Action 6 remove every `fileIndexForRow` linear scan by storing a compact File index or File row range without changing navigation, focus, or mouse targeting?

## Answer

Each Buffer now stores one ordered `FileRow` entry per projected File. The entry holds the Diff File index and its first Buffer row. `Buffer.fileIndexForRow` and `Buffer.fileHeaderRow` use binary search over this compact index. Presentation and the application now use these methods, and both duplicate full-prefix scans are deleted. Isolate view entries retain the original Diff File index instead of treating the only projected File as File zero.

The new `buffer_navigation_300_files_50000_lines` ReleaseFast benchmark runs 1,000 bottom-row lookups against the 300-File, 50,000-Line Buffer. The baseline median was 37,670,000 ns. Three changed medians were 5,875 ns, 5,917 ns, and 9,625 ns, a minimum 3,914x gain. The checksum stayed `48ff8`, and the timed lookup made no allocations. The related Buffer projection median was 1,020,834 ns after the change.

Time Profiler identified the baseline linear scan as the hot stack. CPU Counters showed instruction-processing pressure rather than a useful memory-bandwidth ceiling. Allocations confirmed that the lookup itself allocates nothing. Baseline and changed Time Profiler, Allocations, and CPU Counters traces are in [`../profiles/`](../profiles/), named `buffer-navigation-baseline-*` and `buffer-navigation-changed-*`.

Navigation, focus, mouse targeting, File finder, and isolate behavior remain covered by the Presentation and Buffer tests. `zig build test --summary all` passes all 700 tests. Formatting checks and `git diff --check` pass.
