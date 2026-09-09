# Pre-size Diff parser lists

Type: task
Status: resolved
Blocked by: 13

## Question

If Action 18 passes the P1 gate, can hunk counts safely pre-size parser lists, and does the measured allocation or parse-time gain justify the added code?

## Answer

Reject Action 18. A bounded `old_count + new_count` Line capacity hint preserved checksum `bce79ba680bfd196`, but it did not give a material gain.

The unchanged parser measured 317,167 ns and 334,875 ns median across two ReleaseFast runs. The experiment measured 319,083 ns and 339,750 ns. Allocations fell from 1,228 to 1,211, retained bytes fell from 2,105,062 to 1,995,662, and peak bytes rose from 1,672,972 to 1,683,644.

The 1.4% allocation reduction and 5.2% retained-byte reduction do not justify extra parser code without a latency or peak-memory gain. Hunk counts can also overestimate actual Lines because each context Line contributes to both counts. Production code remains unchanged.
