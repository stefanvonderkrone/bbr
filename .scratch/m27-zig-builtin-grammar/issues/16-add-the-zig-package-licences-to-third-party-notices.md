# 16: Add the Zig package licences to THIRD_PARTY_NOTICES

Status: needs-triage
Blocked by: none
Spec: [M27 spec](../SPEC.md)

## Problem

`tools/third_party_notices.py` writes the `THIRD_PARTY_NOTICES` file of each release archive.
The file covers the components under `vendors/`.
`bbr` also links Zig packages that `build.zig.zon` fetches: `vaxis` and `zf`, and their dependencies `zigimg` and `uucode`.
Their licences are MIT, but the file does not hold their text.
This gap existed before M27. The fix of review finding M27-2 found it.

## Options

1. Add a `build.zig` step that reads each package `LICENSE` from its dependency path and appends it.
2. Copy each package `LICENSE` into `vendors/` with a checksum, and list it in a manifest.
3. Keep the gap and record the decision.

## Comments

Zig 0.16 keeps a fetched package as a `.tar.gz` in the global cache.
So a Python script cannot read the licence text without the Zig build.
