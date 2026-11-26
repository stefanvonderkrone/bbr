# Persist and Bitbucket rules

This doc is the area doc for `src/persist/` and `src/bitbucket/`. `src/persist/sqlite_store.zig` holds the SQLite store, its schema migration steps in `migrate`, and the migration tests. `src/bitbucket/client.zig` holds the Bitbucket client and its REST paths. `src/bitbucket/url.zig` holds the pull-request URL parse. `src/bitbucket/credential.zig` and `src/bitbucket/auth.zig` hold the credential and auth code. This doc has no rule section yet. A checked rule that governs only these modules goes here as a new section.

A rule about a failure in these modules is in [`diagnostics.md`](diagnostics.md). These `diagnostics.md` rules also apply to code in these modules:

- [Paged list cleanup joins before it records](diagnostics.md#paged-list-cleanup-joins-before-it-records)
- [A SQLite result goes through SqliteStore.native](diagnostics.md#a-sqlite-result-goes-through-sqlitestorenative)
- [A boundary records every error except error.Reported](diagnostics.md#a-boundary-records-every-error-except-errorreported)
- [A client notes leaf evidence in the boundary slot](diagnostics.md#a-client-notes-leaf-evidence-in-the-boundary-slot)
- [A Bitbucket client error return notes fresh evidence](diagnostics.md#a-bitbucket-client-error-return-notes-fresh-evidence)
