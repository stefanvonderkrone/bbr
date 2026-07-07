# Vendored SQLite

The SQLite **amalgamation**, compiled into `bbr` with the bundled `zig cc`. See
[`docs/adr/0006-vendored-sqlite-amalgamation.md`](../../docs/adr/0006-vendored-sqlite-amalgamation.md)
for why the amalgamation is vendored in-tree rather than linked from the system.

- **Version:** 3.50.4 (`3500400`, released 2025-07-30)
- **Source:** <https://www.sqlite.org/2025/sqlite-amalgamation-3500400.zip>
- **Archive SHA-256:** `1d3049dd0f830a025a53105fc79fd2ab9431aea99e137809d064d8ee8356b032`

Only the library sources are kept (`sqlite3.c`, `sqlite3.h`, `sqlite3ext.h`);
the CLI `shell.c` from the archive is not vendored.

## Updating

1. Download the new `sqlite-amalgamation-<n>.zip` from sqlite.org and verify its
   SHA-256 against the release page.
2. Replace `sqlite3.c`, `sqlite3.h`, `sqlite3ext.h` from the archive.
3. Update the version, URL, and checksum above.
4. `zig build test` — the round-trip tests in `src/persist/sqlite_store.zig`
   exercise the new build.

Compile flags live in `build.zig` (see the `sqlite_flags` there).
