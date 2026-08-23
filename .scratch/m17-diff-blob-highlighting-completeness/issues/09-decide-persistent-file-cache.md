# Decide whether to add a persistent File cache

Type: grilling
Status: resolved
Blocked by: none

## Question

Does a persistent disk cache earn its storage, security, corruption recovery, versioning, invalidation, and cleanup complexity over the existing in-memory File cache policy? Choose a precise opt-in design behind the current policy, or record a durable no-go decision.

## Answer

Do not add a persistent File content cache in M17. Keep `[files.cache]` Session-only. bbr writes no File content or Highlighting data to disk, and Session replacement or process exit discards that data.

The existing inactive File cache avoids refetches within a Session. The selected remote one-File-ahead prefetch policy removes about 90% of sequential enrichment lag after the first two Files in the measured workflow. A disk cache would mainly help after Session replacement or process restart, but this map has no evidence that repeated acquisition in those cases causes a material review delay. That unproven benefit does not justify storing reviewed source code on disk or adding retention, permissions, cleanup, invalidation, corruption recovery, and format migration policy.

Reopen this decision only when a future proposal provides representative workflow measurements that show repeated remote File Enrichment across Session replacement or process restart causes a material delay. The proposal must also define source-code retention, file permissions, cleanup, invalidation, corruption recovery, and format migration. Do not use an arbitrary latency threshold without workflow evidence.
