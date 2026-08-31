# Define the bbr version identity

Type: grilling
Status: resolved
Blocked by: none

## Question

What CalVer format should identify a bbr build, and how should the build derive the date and commit hash without losing reproducibility? Define same-day build ordering, dirty-worktree behavior, release tags, `build.zig.zon` compatibility, user-visible version output, and CI acceptance evidence.

## Answer

A bbr version identifies one source revision, not one compilation. Clean builds of the same revision produce the same version on every target and at every build time.

### Version format

Use a Semantic Versioning-compatible CalVer string:

- An untagged build uses `YYYY.M.D-0+g<hash>`.
- A release build uses `YYYY.M.D-N+g<hash>`.
- `<hash>` is the first 12 lowercase hexadecimal characters of the commit hash.
- A dirty build appends `.dirty` to the build metadata, as in `YYYY.M.D-0+g<hash>.dirty`.

The date is the UTC date of the Git `HEAD` committer timestamp. It is not the compilation date or the local calendar date.

Release sequence `N` starts at `1`. A later release on the same UTC date uses the previous maximum plus one. Release automation rejects a reused or skipped sequence.

### Metadata sources

The build supports two complete metadata sources. It never combines partial data from both sources.

1. Explicit metadata takes precedence. It supplies a Unix epoch, the full 40-character lowercase commit hash, the release sequence, and the dirty flag. Release and archive tooling derives the epoch from `SOURCE_DATE_EPOCH`. If any explicit field is present, every explicit field is required.
2. Without explicit metadata, the build reads `HEAD`'s committer timestamp and full hash from Git. An exact matching release tag supplies the release sequence. Otherwise, the sequence is `0`.

If neither source is complete, the build fails with the missing fields and the accepted explicit inputs.

Git mode marks the build dirty when the worktree has tracked changes or untracked files in build inputs. Ignored files do not mark the build dirty. A dirty worktree on an exact release tag retains the tag's sequence and adds `.dirty`. This behavior supports local diagnosis, but official release CI rejects the build.

### Release tags and package version

Release tags use the annotated form `vYYYY.M.D-N`. The tag must point directly at the release commit. Its date must match that commit's UTC committer date.

On a release commit, `build.zig.zon` stores the hashless `YYYY.M.D-N` value. Development commits retain the latest release value. Before the first release, the value remains `0.0.0`. The package version omits the commit hash because adding the hash to the same commit would change that hash.

### User-visible output

`bbr --version` writes one line to standard output:

```text
bbr <version>
```

The command performs no network, Credential, config, database, or terminal initialization.

### CI acceptance evidence

Hermetic tests must cover clean development, clean release, dirty development, dirty tagged, malformed tag, partial explicit metadata, and missing metadata cases. They must prove that the formatter emits a value accepted by Zig's `std.SemanticVersion` parser.

Reproducibility checks must build one clean revision under different wall-clock times and time zones and compare `bbr --version`. Explicit metadata and Git metadata for the same revision must produce the same line.

The release job must verify all of these conditions:

- The worktree is clean.
- `HEAD` has exactly one matching annotated release tag.
- The tag date matches the UTC committer date.
- The sequence is the next value for that date.
- `build.zig.zon` equals the hashless tag version.
- `bbr --version` equals the expected version and contains the expected 12-character hash.
- A source archive built without `.git` produces the same version through complete explicit metadata.
