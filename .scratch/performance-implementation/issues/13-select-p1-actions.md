# Select P1 actions from the P0 profile

Type: grilling
Status: resolved
Blocked by: 03, 04, 05, 06, 07, 08, 09, 10, 11, 12

## Question

Which P1 actions pass the measured evidence gate after all P0 work, and which actions should close without implementation because their target cost is no longer material?

## Comments

The ReleaseFast P1 gate now measures every action on the Apple M5 Pro host. The harness reports 15 samples after two warmups and checks each output checksum.

- Action 11: JavaScript Highlighting retained 118,054 bytes at 4 KiB, 3,748,686 bytes at 100 KiB, 21,706,318 bytes at 1 MiB, and 49,103,510 bytes at 2 MiB. The 2 MiB BuiltInGrammar runs retained 19.7 MiB to 119.1 MiB.
- Action 12: Parsing 4,000 ReviewBodies took 618,708 ns median and retained 3,299,544 bytes. A 5,000-Line WholeFile projection took 145,625 ns and retained 6,049,368 bytes.
- Action 13: An unwrapped 50,000-row Presentation Frame projection took 604,208 ns, allocated 17,001,600 bytes, and retained 25,502,448 bytes. `VisualRow` is 336 bytes and `Row` is 104 bytes.
- Action 14: `Line` is 40 bytes and `Span` is 24 bytes. Parsing 50,000 Lines took 332,333 ns and retained 3,178,874 bytes. Dense 5,000-Line Span projection took at most 191,791 ns median.
- Action 15: File Tree tally projection for 2,000 Threads and 2,000 Drafts took 2,684,125 ns median. Buffer projection for the same review data took 10,204,667 ns median.
- Action 16: Wrapping the 50,000-row Buffer at 24 columns took 5,793,042 ns, allocated 92,181,216 bytes, and retained 286,734,208 bytes.
- Action 17: Two equal 100 KiB JavaScript Highlighting calls took 25,712,667 ns. One call took 12,850,750 ns. The benchmark proves the avoidable cost but does not prove that equal old and new File content occurs often.
- Action 18: Parsing the 300-File, 50,000-Line RawDiff took 332,333 ns median. Its 1,226 allocations peaked at 2,074,228 bytes.

Recommended gate: accept Actions 11, 13, 15, and 16. Reject Actions 12, 14, and 18 because their measured target costs are not material. Reject Action 17 because no measured Session workload establishes a useful cache hit rate.

The memory goal changes the Action 14 result. Compact fields can reduce `Line` from 40 to 32 bytes and `Span` from 24 to 16 bytes. These lists scale with review and File size, so a 20% to 33% size reduction passes the gate even though current scan latency is low. The revised recommendation accepts Actions 11, 13, 14, 15, and 16.

Action 18 also passes as a measured experiment. The 300-File RawDiff parser makes 1,226 allocations and retains 3,178,874 bytes. The execution ticket must compare pre-sizing against this baseline and close without the change if allocation, memory, and latency gains are not material.

`zig build bench`, `zig build test --summary all`, `zig fmt --check build.zig src/benchmark src/tui/benchmark.zig`, and `git diff --check` pass. The test suite reports 703 passing tests.

## Answer

Actions 11, 13, 14, 15, 16, and 18 pass the P1 evidence gate.

- Action 11 has material retained-memory costs across all BuiltInGrammars.
- Action 13 has a material memory cost because each 50,000-row Presentation Frame projection allocates 17.0 MiB for 336-byte `VisualRow` values.
- Action 14 has material density gains. A compact `Line` can use 20% less memory, and a compact `Span` can use 33% less memory.
- Action 15 has a material repeated-work cost. File Tree tallies take 2.68 ms for 2,000 Threads and 2,000 Drafts after Buffer computes equivalent tallies.
- Action 16 has material latency and memory costs. The wrapped 50,000-row projection takes 5.79 ms and retains 273.5 MiB.
- Action 18 warrants a measured implementation experiment because RawDiff parsing makes 1,226 allocations. Keep pre-sizing only if it gives a material allocation, memory, or latency gain.

Actions 12 and 17 fail the gate.

- Action 12 targets 0.62 ms of ReviewBody parsing for 4,000 bodies and 0.15 ms of WholeFile line work for 5,000 Lines. These costs do not justify Session cache state and invalidation rules.
- Action 17 can avoid 12.85 ms when two 100 KiB inputs are equal, but no measured Session workload establishes a useful hit rate. The cache remains speculative.
