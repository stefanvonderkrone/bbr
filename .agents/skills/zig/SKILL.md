---
name: zig
description: Zig 0.16.0 source lookup and validation. Use for Zig source, build files, stdlib APIs, or Zig dependency changes.
---

# Zig 0.16.0

## Read the installed source first

1. Run `zig version` and `zig env`.
2. Use the reported `std_dir` to find the API in the installed stdlib.
3. Open the declaration before using or describing that API.
4. Cite the verified signature, field, or type with its source path and line.

Use [ZIG.md](../../../ZIG.md) for the version-pinned API catalog and dependency source lookup.
Check every recalled API against the installed source.

## Read the reference for the change

Before editing, read each reference that matches the work:

- [Standard library](stdlib.md) covers process initialization, collections, readers, writers, file limits, paths, and reserved names.
- [Runtime ownership](runtime.md) covers concurrent work, HTTP clients, terminal cell text, SQLite bindings, and dynamic library lifetimes.
- [Tests](testing.md) covers test discovery, module ownership, hermetic fixtures, and stalled pagination tests.
- [Builds and performance](build-performance.md) covers native dependencies, platform workarounds, benchmarks, allocation metrics, and bounded algorithms.

## Validate the change

1. For a CI failure, read the first failed step in `.github/workflows/ci.yml`.
2. After the final Zig source edit, run `zig fmt --check build.zig src tests`.
   Require exit code zero for the full scope on any host.
3. For behavior or build changes, run `zig build` and `zig build test --summary all`.
4. State the native target tested. Cross-compilation proves compilation, not native runtime behavior.
5. For tests in a new file, confirm that the appropriate test-step count increases.

## Keep the references current

Put newly verified API facts in `ZIG.md` and its re-verification checklist.
Put recurring mistakes and durable rules in the matching reference beside this skill.
After a Zig upgrade, recheck the facts against the installed stdlib before using them.
