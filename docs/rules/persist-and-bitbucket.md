# Persist and Bitbucket rules

This doc holds the checked rules for `src/persist/`, the SQLite store and its schema migrations, and for `src/bitbucket/`, the Bitbucket client, its URL paths, and its caches. The parts that no check covers are in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

A rule about a failure in these modules is in [`diagnostics.md`](diagnostics.md). These rules name the modules:

- [A SQLite result goes through SqliteStore.native](diagnostics.md#a-sqlite-result-goes-through-sqlitestorenative)
- [Paged list cleanup joins before it records](diagnostics.md#paged-list-cleanup-joins-before-it-records)
- [A Bitbucket client error return notes fresh evidence](diagnostics.md#a-bitbucket-client-error-return-notes-fresh-evidence)
