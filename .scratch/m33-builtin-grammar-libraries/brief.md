# M33 BuiltInGrammar libraries on demand: brief

Status: needs-triage
Milestone: M33
Blocked by: none

This brief is the full write-up of option B for the size of the bbr executable.
The requirements live in the M33 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Highlighting glossary](../../src/highlight/GLOSSARY.md).
The delivery model that M33 changes is in [ADR-0009](../../docs/adr/0009-built-in-grammars-now-user-grammars-later.md) and [ADR-0017](../../docs/adr/0017-builtin-grammar-queries-come-from-nvim-treesitter.md).
The measurements come from [the M27 binary size record](../m27-zig-builtin-grammar/binary-size.md).
The comparison with other review tools is in `research-diff-highlighting-tuicr-hunk.md`, a local report outside the repository.

The user chose option B on 2026-11-02.
Nobody grilled this brief yet.
The open questions at the end must have answers before the SPEC.

## Problem

M27 added 21 BuiltInGrammars to the 8 BuiltInGrammars of M13.
The ReleaseSafe executable grew from 12,980,144 bytes to 57,526,080 bytes.
The parse tables of the parsers cause almost all of the growth.
A tree-sitter `parser.c` holds its parse table, lex modes, and symbol metadata as `static const` arrays.
These arrays go into `__TEXT,__const`, which grew by 41,513,568 bytes.

Five Grammars cause 74% of the growth:

| BuiltInGrammar | Parser bytes in the executable |
| --- | ---: |
| `sql` | 11,709,896 |
| `kotlin` | 5,873,176 |
| `cpp` | 5,694,460 |
| `c_sharp` | 5,400,964 |
| `swift` | 4,427,734 |

M27 ticket 15 made the query preparation lazy.
That change moved 422 ms of start work to the first use of each language.
It saved no bytes, because the parser code stays in the executable.

Every reviewer downloads and stores every parser, also for languages that the reviewer never opens.
Most reviewers use a small number of languages.

## In my own words

The executable must contain only what every reviewer needs.
A parser is large and only some reviewers need it.
So each parser leaves the executable and becomes a separate file.
The release publishes that file for each target.
bbr gets it the first time a File needs it, and keeps it on disk after that.

The executable still knows every BuiltInGrammar.
It holds the name, the GrammarMatch rules, the queries, the Capture map, and the SHA-256 of each parser file.
So a BuiltInGrammar keeps its identity and its Injection rights.
Only the parser code arrives later.

bbr runs this parser code as native code with the user's permissions.
So bbr must load only the exact bytes that its own release built.
The SHA-256 pin in the executable gives that guarantee.

## Terms

**GrammarLibrary** (proposed term):
The shared library that holds the parser of one BuiltInGrammar for one release target.
The executable pins its SHA-256.
bbr downloads it on first use, or the reviewer installs it in advance.
_Avoid_: plugin, parser download, grammar bundle (a UserGrammar bundle is a different thing).

A GrammarLibrary is not a UserGrammar.
A UserGrammar comes from the user, needs a trust prompt, and takes no part in Injection.
A GrammarLibrary comes from the bbr release, needs no prompt, and keeps every BuiltInGrammar right.

The glossary gets this term after the grilling.

## Decision summary

| Topic | Choice |
| --- | --- |
| What leaves the executable | The parser code of each BuiltInGrammar: `parser.c` and `scanner.c` |
| What stays in the executable | The tree-sitter runtime, the queries, the GrammarMatch rules, the Capture maps, the Injection catalog, and the SHA-256 pins |
| Which BuiltInGrammars | All 29, as option B says |
| Where the files come from | The GitHub release of the same bbr version, or a mirror, or a local folder |
| Who builds them | The release build that also builds the executable, on the same runner |
| Trust | A SHA-256 pin in the executable. No trust prompt. No signature check in M33 |
| When bbr gets them | On first use, in the background, or in advance with a command |
| What the reviewer sees until then | Plain text. The Spans arrive when the GrammarLibrary is ready |
| Offline and behind a proxy | Plain text with a short status. A setting turns downloads off |

## Rejected options

- **A. Download the parser source and compile it locally**, as nvim-treesitter does.
  Reviewers would need a C compiler, which bbr does not need today.
  A local toolchain can change the output, so no pin is possible.
- **C. Keep small BuiltInGrammars in the executable and make only the large ones downloadable.**
  This keeps more languages offline.
  The user chose B, so one delivery path applies to every BuiltInGrammar.
  The design below can still keep a Grammar linked later, because the identity stays in the executable.
- **TextMate or Shiki grammars**, as tuicr and hunk use.
  These grammars are smaller.
  But bbr would lose its full-file parsing quality and its nvim-treesitter queries from ADR-0017.
- **Wasm Grammars.**
  A Wasm runtime adds its own size and work, and M27 deferred that research.

## Design

### Build

`build.zig` builds each BuiltInGrammar parser as a dynamic library with `b.addLibrary(.{ .linkage = .dynamic })`.
The build already does this for the UserGrammar test fixture.
The library exports only `tree_sitter_<name>`.
It links no other library except libc where the parser needs it.

The build computes the SHA-256 of each library after the link step.
A generated Zig file gives the executable a table of `name`, `target`, `file name`, `size`, and `sha256`.
So the pin always matches the library from the same build.
No hand-edited checksum exists.

A build option keeps the M27 behavior:

- `-Dgrammar-delivery=library` is the release default.
- `-Dgrammar-delivery=linked` links every parser into the executable, as M27 does.

The hermetic tests use `linked` where they test Captures, and `library` where they test delivery.
A reviewer who needs every language offline can also build with `linked`.

### File names and targets

The release has four targets: `macos-x86_64`, `macos-aarch64`, `linux-x86_64`, and `linux-aarch64`.
29 Grammars on 4 targets give 116 GrammarLibraries per release.

The proposed asset name is `bbr-grammar-<name>-<target>-<sha256 first 16 hex>.<dylib|so>`.
The digest in the name makes each asset name unique for its content.

On Linux, the release executable links glibc dynamically, because `build.zig` sets `link_libc` and the runner builds natively.
So `dlopen` works, and a GrammarLibrary uses the same glibc as the executable.
On macOS arm64, the Zig linker signs each library ad hoc.
The pin covers the signed bytes.

### Release publication

The release workflow uploads the GrammarLibraries of each target with the archive of that target.
The current publication rule in AGENTS.md requires exactly four archives and `SHA256SUMS`.
M33 changes that rule and its tests in `tests/publish_release_test.py`:

- The expected asset set is the four archives, `SHA256SUMS`, and the GrammarLibraries that the four builds report.
- `SHA256SUMS` also lists each GrammarLibrary.
- The final check compares the remote asset names with that set, as it does today.
- Publication never deletes an asset, also not an old GrammarLibrary.

### Storage

bbr stores GrammarLibraries under `xdg.dataHome()` in `bbr/grammars/<target>/`.
The file name is the asset name.
The folder has mode 0700 and each file has mode 0600.
Only `src/xdg.zig` reads the XDG variables, as the AGENTS.md rule says.

The digest in the file name keys the store.
If a new bbr release builds a byte-equal GrammarLibrary, bbr does not download it again.
Whether a Zig build gives byte-equal libraries is an open question.

### Download

A first use queues one download for that GrammarLibrary.
A second request for the same GrammarLibrary waits for the first one.
The work runs on a background worker, never on the input or paint path.

The request goes to `https://github.com/stefanvonderkrone/bbr/releases/download/<tag>/<asset>`, or to the mirror from the settings.
GitHub answers with a redirect to its object store.

Rules for the request:

- The request carries no `Authorization` header and no Bitbucket Credential.
  It uses its own client setup, not the Bitbucket client.
- A redirect must stay on `https`.
  Main's HTTP client has open Credential bugs on redirects (review finding X-2).
  The ticket `credential-transport-hardening` fixes them.
  M33 must not depend on that fix, because it sends no Credential.
- The request uses the proxy policy of M19 and the system certificates.
- The request has a timeout and a size limit.
  The size limit is the pinned size of the GrammarLibrary.
  A larger body stops the download.
- bbr writes to a temporary file in the same folder, checks the size and the SHA-256, and then renames the file into place.
  A failed download never replaces a good file.
- The download never goes through `readArchive` or any other decoder.
  The std decompressor can panic on hostile input (review findings X-3 and M32I-8).
  A GrammarLibrary is one raw file with no archive.

### Load

bbr checks the SHA-256 of the file on disk before each `std.DynLib.open`.
Then it looks up `tree_sitter_<name>` and checks the ABI version against the tree-sitter runtime.
A mismatch makes the Grammar unavailable for the process, and the file stays for a later check.

Native code runs when `dlopen` runs.
The pin is the only protection.
A process that runs as the same user can still replace the file between the check and the load.
M33 accepts this, because such a process can already change bbr itself.

### Highlighting behavior

- A File whose GrammarLibrary is not ready shows plain text.
  The File Enrichment worker adds the Spans when the GrammarLibrary is ready, as it does for content today.
- Query preparation stays lazy, as M27 ticket 15 made it.
  The first use of a language now costs the download, the check, the load, and the query preparation.
- Injection keeps its M27 rules.
  Only catalog names from the executable can select a Grammar.
  A Markdown fence name never becomes a URL or a file path.
- If an injected GrammarLibrary is not ready, the host Spans stay and the injected region shows plain text.
  A ready GrammarLibrary adds the injected Spans at the next Enrichment.
- A failed download is recorded for the process.
  bbr does not retry it on every frame or every File.
  The retry rule is an open question.
- The status shows one short message for a failed GrammarLibrary, not one per File.

### Commands and settings

The existing `bbr grammar install` and `bbr grammar update` belong to UserGrammars.
M33 proposes new verbs that do not change them:

- `bbr grammar fetch [--all | <name>...]` downloads GrammarLibraries in advance.
- `bbr grammar fetch --from <folder>` imports GrammarLibraries from a local folder for offline machines.
  The import checks each file against the pins.
- `bbr grammar status` lists each BuiltInGrammar with its state: linked, ready, missing, or failed.
- `bbr grammar prune` removes GrammarLibraries that the current executable does not pin.

Proposed settings in the config file:

```toml
[highlight.grammars]
download = "auto"   # or "never"
mirror = ""         # an https base URL that serves the release asset names
```

With `download = "never"`, bbr uses only the files that are already in the store.

### Development builds

A development build has no release tag, so no release URL exists for it.
A `zig build` installs the GrammarLibraries into `zig-out/lib/`.
A development build looks there first.
The rule for a development build that runs from another folder is an open question.

## Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Native code from the network | A changed file runs with the user's permissions | SHA-256 pin from the same build, check before each load |
| Corporate proxy or no network | No colors for languages that are not in the store | Plain text, one status message, `fetch --from`, mirror setting, `linked` build |
| GitHub is slow or down | The first use of a language waits | Background work, plain text first, no retry storm |
| macOS library validation | A signed executable with Hardened Runtime refuses libraries from another Team ID | The release is not signed today. If signing comes, sign each GrammarLibrary with the same Team ID before the build computes the pin |
| glibc version | A GrammarLibrary needs the glibc of the build runner | Same runner and same glibc as the executable, so no new limit |
| More release assets | 116 more files per release, more upload time | Measure the upload. Keep the publication checks strict |
| Byte-equal builds | Without them, each release downloads every GrammarLibrary again | Measure. Accept the downloads if the builds differ |
| License notices | Each parser has its own license | Add the notice to the release notices and to `bbr grammar status` |

## Expected result

The base executable loses the parser code of all 29 BuiltInGrammars.
Before M27 it was 13 MB with 8 linked parsers, so the new size is probably below 13 MB.
This is an estimate.
The object sizes do not give the exact link result, so M33 measures it.

A reviewer who uses five languages downloads only those five GrammarLibraries.
Their size depends on the language, from about 20 KB for HTML to about 12 MB for SQL.

## Measurements for the SPEC

- Executable size per target, with `linked` and with `library`.
- Size of each GrammarLibrary per target.
- Time to first frame, time to first answered input, and time to the first Spans of a File.
- First-use cost of each step: download, check, load, query preparation.
- Steady-state Highlighting cost, which must not change.
- Release workflow time before and after.

## Open questions for the grilling

1. Must every BuiltInGrammar move, or must a small core stay linked? B says all of them.
2. Is `GrammarLibrary` the right term?
3. Does a missing GrammarLibrary download automatically, or does bbr ask the first time?
4. What is the retry rule after a failed download: once per process, or after a fixed time?
5. Does a GrammarLibrary come from the release of the same tag, or from one shared release for all versions?
6. Must bbr also check a signature, or is the pin enough?
7. Does the Linux release need a musl or a static build later? A static executable cannot use `dlopen`.
8. How does a development build find its GrammarLibraries outside `zig-out/`?
9. Do the hermetic Capture tests keep the `linked` build, or do they load GrammarLibraries?
10. Does Homebrew or another package manager need all GrammarLibraries in the package?
11. Which ADR number does M33 take? The next free number when the ADR ticket runs.
