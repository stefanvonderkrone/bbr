# Cache Highlighting results

Type: task
Status: resolved
Blocked by: 13, 14

## Question

If Action 17 passes the P1 gate, how will the Session identify and reuse immutable Highlighting results across equal File content without retaining unsafe Grammar state?

## Answer

Action 17 failed the P1 evidence gate. Two equal 100 KiB JavaScript Highlighting calls take 25,712,667 ns median, but no measured Session workload establishes a useful cache hit rate. Do not add speculative cache state.
