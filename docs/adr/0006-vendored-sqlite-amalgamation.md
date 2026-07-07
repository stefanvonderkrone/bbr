# SQLite is vendored as the amalgamation, compiled into the executable

The `PendingReviewStore` (ADR-0002, ADR-0003) is backed by SQLite. We obtain SQLite by
**vendoring the official amalgamation** (`sqlite3.c` + headers) under `vendors/sqlite/` and
compiling it into the `bbr` executable with the bundled `zig cc`. We do *not* link a system
`libsqlite3` and do *not* add a third-party Zig binding dependency.

The C code is attached only to the **executable module**; the pure `bbr` library module stays
C-free. `SqliteStore` (`src/persist/sqlite_store.zig`) lives on the executable side and is the
only file that does `@cImport("sqlite3.h")`.

## Why

- **Reproducible, hermetic builds.** The exact SQLite version is pinned in-tree (version + URL +
  SHA-256 in `vendors/sqlite/README.md`), so CI and every developer machine compile the same
  source with no system package to install and no version drift (the dev machine had a
  pkg-config `libsqlite3` at 3.51 and a Homebrew keg at 3.53 — vendoring removes that ambiguity).
  This matches how the Zig dependencies are already pinned by exact commit + hash.
- **The domain still needs no C toolchain.** Because the amalgamation is on the executable
  module and the store is reached only through the `PendingReviewStore` seam, the core `bbr`
  module and its tests build and run with no C — the in-memory fake stands in (ADR-0003). Only
  the executable's tests (which include the `SqliteStore` round-trip) compile the C.

## Consequences

- A ~9 MB `sqlite3.c` lives in the repo and is recompiled when the build cache misses; the first
  build after a checkout pays a one-time C compile. Updating SQLite is the documented three-step
  swap in `vendors/sqlite/README.md`.
- The amalgamation is compiled `SQLITE_THREADSAFE=0`: the store is touched only on the main
  thread (design §10/§11), never from a load worker. Revisit this flag if that ever changes.
- Schema versioning uses SQLite's built-in `PRAGMA user_version`; migrations are a forward
  switch in `SqliteStore.migrate`. The Bitbucket token is never written to the database (§12).
