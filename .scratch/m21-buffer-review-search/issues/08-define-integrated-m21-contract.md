Type: grilling
Status: resolved
Blocked by: 03, 06, 07

# Define the Integrated M21 Contract

## Question

What complete module, state, Action, event, and acceptance contract makes M21 ready for implementation?

Combine the corpus, interaction, prototypes, matcher, streaming, and navigation decisions. Place pure match and rank logic behind the smallest useful interfaces. Preserve atomic Presentation Frames, Session Epoch safety, the File cache budget, remote and local parity, and current Keymap configuration. Produce dependency-ordered implementation slices and a deterministic acceptance matrix for every M21 requirement.

## Answer

M21 uses one pure search module and keeps all interaction, scheduling, and publication policy in Presentation. It adds no runtime dependency. The implementation must follow the detailed behavior in tickets 01 through 07 and the concurrency limit in ticket 09. This answer defines how those decisions fit the current code.

### Module contract

Add `src/tui/search.zig`. The module is terminal-free, worker-free, and cache-free. It owns these concepts:

- `Query`: validated UTF-8, decoded Unicode scalars, smart-case state, and a maximum of 256 scalars.
- `Candidate`: one semantic logical line, its owner, its canonical corpus key, and the mapping from semantic UTF-8 ranges to authored or source UTF-8 ranges.
- `Occurrence`: one source or authored location, its exact matched ranges, its scalar column, and optional fuzzy score evidence.
- `Mode`: `literal` or `fuzzy`.
- `Batch`: owned Occurrences and their owned range arrays. A source Occurrence owns location data but never copies the matched source Line.

The module exposes one matching operation:

```zig
pub fn scan(
    allocator: std.mem.Allocator,
    query: Query,
    candidates: []const Candidate,
    mode: Mode,
) !Batch
```

`scan` applies smart-case matching, maps semantic ranges back to exact source ranges, and returns deterministic corpus order. Fuzzy mode also calculates scores and sorts by the contract in [Define Review Search Matching and Ordering](04-define-review-search-matching-and-ordering.md). Callers do not implement matching, ranking, range merging, or tie-breaking.

`buffer.zig` prepares Buffer Search candidates from the same Diff, Review, and `BuildOptions` that build the visible Buffer. Candidate preparation happens before disclosure projection. It therefore includes Fold Lines and complete owned ReviewBodies without treating generated rows as text. Unified and SideBySide projections share one candidate identity for the same unchanged Line.

Presentation prepares Review Search candidates in two partitions:

- one ReviewBody partition containing every Comment, Reply, and Draft;
- one partition per File after every present version reaches a terminal File Enrichment state.

Each File partition performs old and new matching together. It can therefore emit a version-neutral Occurrence before publication. Presentation replaces a complete partition at once and globally sorts all available Occurrences.

### Unicode and bounded matching

Commit a generated Zig Unicode table beside `search.zig`. Generate it from a pinned Unicode release's `CaseFolding.txt` simple mappings and `DerivedCoreProperties.txt` `Uppercase` property. Record the Unicode version and source checksums in the generated file. Do not add a runtime Unicode package.

Use an ASCII fast path, then the generated table for non-ASCII scalars. Apply only one-scalar common and simple case-fold mappings. Do not apply full mappings, locale mappings, or normalization.

Literal mode returns leftmost, non-overlapping matches. Fuzzy mode returns the best complete-query alignment for each Candidate. Exact `fzy` dynamic programming runs below a benchmark-set scalar-cell limit. Above that limit, a deterministic greedy subsequence returns exact UTF-8 ranges and a fallback score. Every exact result ranks before every fallback result. Candidate length and canonical corpus order break ties within each class.

The implementation benchmark must set the scalar-cell limit before merging the search kernel. The benchmark must cover long generated lines, long Unicode lines, and the 256-scalar maximum query. It must record the chosen limit in the source next to the fallback.

### Session-scoped state

Store both search states in `Published` because Session replacement owns their lifetime.

`BufferSearchState` contains:

- the accepted query and accepted Occurrences;
- the active Occurrence identity;
- the active search input, saved query, saved cursor, and saved scroll used for cancellation;
- the saved search origin and Count;
- search-owned disclosure reveals.

`ReviewSearchState` contains:

- the current query and query generation;
- one replaceable ReviewBody partition and one replaceable partition per File;
- globally sorted available Occurrences and the selected identity;
- per-version acquisition states;
- result-list and Preview scroll state;
- queued and active File acquisition work;
- the one active scan partition and the newest queued generation;
- a pending exact-navigation destination when content needs reacquisition.

`ActiveSearch` is `none`, `buffer`, or `review`. Only the active search contributes match styles to the current Presentation Frame. Switching the active search leaves the other state intact. Session replacement clears both states and increments the Session Epoch through the existing replacement path.

Every state mutation that changes rows, highlights, disclosure, Scope, isolation, Selected Version, or cursor position stages one complete Buffer and Presentation Frame. A build, match, or allocation failure keeps the prior Frame and reports a classified Presentation error.

### Query input

Both searches use end-only Unicode query editing:

- printable valid UTF-8 appends one scalar;
- Backspace removes one scalar;
- `ctrl-w` removes the prior whitespace-delimited word and adjacent trailing whitespace;
- `ctrl-u` clears the query;
- the 257th scalar is refused with a visible status message;
- line endings, NUL, and invalid UTF-8 are refused.

Buffer Search keeps its accepted-versus-preview behavior from [Define Buffer Search Interaction](02-define-buffer-search-interaction.md).

Review Search starts File Enrichment when it opens, including when its query is empty. An empty Review Search query emits no Occurrences. The Overlay still shows acquisition states and the number of available logical-line candidates. Reopening restores the query, selection, result scroll, and Preview scroll. Escape closes the Overlay without clearing them.

Digits enter Review Search query text. Review Search does not use Count. Buffer Search retains its approved Count behavior.

### Actions and Interaction Contexts

Add these configurable Actions and default bindings:

| Action | Default | Context |
| --- | --- | --- |
| `open_buffer_search` | `/` | DiffPane contexts |
| `next_search_occurrence` | `n` | DiffPane contexts |
| `previous_search_occurrence` | `N` | DiffPane contexts |
| `open_review_search` | `g f` | DiffPane contexts |
| `next_review_search_occurrence` | Down, `ctrl-n` | Review Search Overlay |
| `previous_review_search_occurrence` | Up, `ctrl-p` | Review Search Overlay |
| `open_search_occurrence` | Enter | Review Search Overlay |

Add `buffer_search_input` and `review_search` Interaction Contexts. Fixed editing keys run before configurable Action resolution in both query inputs. In Review Search, configured navigation and opening Actions run before an otherwise printable key becomes query text.

`open_buffer_search` is unavailable while Selection is active. `open_review_search` is available from every DiffPane context and captures the complete input surface while open. A primary click selects a Review Search row. A primary double-click opens it. The wheel scrolls the list or Preview under the pointer.

Remove `toggle_diff_wrap`, its default `w` binding, and `Preferences.diff_wrap`. Build every source `VisualRow` with wrapping enabled. A configured override for the removed Action becomes an unknown Action under the existing strict config rules.

### Presentation Frame and rendering

Extend the immutable Presentation Frame with:

- projected match ranges for each visual source or ReviewBody row;
- the active Occurrence identity;
- Buffer Search prompt and count data;
- Review Search Overlay geometry, result-row targets, Preview data, acquisition rows, and independent scroll positions.

Project UTF-8 ranges to cells only after wrapping. One semantic Occurrence can paint several visual continuations. Shared SideBySide context can paint both halves but contributes one count.

Add `search_match`, `search_active`, and `search_no_match` to every built-in Theme. Apply search backgrounds after diff, syntax, emphasis, Comment, Draft, cursor, and Selection composition. `search_match` keeps the prior foreground and attributes. `search_active` replaces the foreground and makes it bold. Search styles never add cells or change wrapping.

Render Buffer Search in the bottom command line exactly as [Prototype Buffer Search Feedback](03-prototype-buffer-search-feedback.md) specifies. Render Review Search from one `ReviewSearchProjection`; rendering must not inspect mutable search state.

### File Enrichment leases

Extend `file_enrichment.Storage` with a read lease for one File. A lease exposes immutable old and new `SideView` values and pins their owned content against LRU eviction. The lease uses thread-safe retain and release counts because a scan command crosses the UI and worker threads.

Session destruction retires leased content instead of freeing it. The final lease release frees retired content. A lease release on the current Session immediately reapplies the normal inactive-content budget. At most one File scan lease exists at a time, in addition to the focused-File protection already in Storage.

A lease owns no Session pointer. A stale worker completion can therefore release the lease after Session replacement without reading freed Session state.

### Acquisition and scan scheduling

Reuse the existing `enrich_file` command and `file_enrichment.Storage`. Do not add a second blob cache or a persistent search index.

When Review Search opens, Presentation sorts Files by `File.displayPath()` and Diff order. It joins existing File Enrichment and queues enough new work to keep at most eight Files active for Review Search. One remote modified File can use two side requests. Thus the request maximum remains 16. LocalReview work uses at most eight Git processes.

Started focused-File work completes. While Review Search is open, new search acquisition fills available slots before focused demand. One-successor prefetch pauses. Opening an evicted selected result uses the same high-priority search acquisition path.

Remote blob acquisition returns classified failure and normalized `Retry-After` evidence from the Bitbucket adapter. The File Enrichment worker retries transport failures, `RateLimited`, and `ServerError` once in the same File slot. It honors `Retry-After` when present. Other remote failures and every local failure become terminal without retry.

Closing Review Search removes queued search acquisition and scan commands. Started File Enrichment finishes into the normal cache. Started scans finish, but Presentation rejects their publication into the closed Overlay. Reopening resumes full-path acquisition from current cache states.

Add one self-owned `scan_search` command. It carries:

- command id;
- Session Epoch;
- query generation and query snapshot;
- either an owned ReviewBody candidate snapshot or one File read lease;
- the partition identity.

Only one `scan_search` command runs at a time. A query edit increments the generation, discards older queued scans, clears stale current-generation partitions, and records the newest generation. The active scan can finish. Its stale completion is rejected, then Presentation starts the next partition with only the newest generation. This gives one scan worker without a persistent actor or a second command channel.

Add one `search_scan_completed` owned input. It carries the command id, Session Epoch, query generation, partition identity, owned Batch or classified failure, candidate count, and returned lease ownership. Presentation admits it only when command id, Epoch, generation, open search state, and partition identity all match. Every rejection path deinitializes the Batch and releases the lease.

ReviewBodies scan first. File scans become eligible when all present versions of that File are terminal. Each accepted completion replaces its whole partition, globally sorts available Occurrences, and restores selection by Occurrence identity. If that identity disappeared, selection stays at the old list index and clamps to the last result.

### Navigation

Opening an Occurrence follows [Define Search Navigation and State Lifetime](07-define-search-navigation-and-state-lifetime.md). Presentation resolves the destination from identity against the current Session before changing the Frame.

For a cached source destination, Presentation stages File focus, isolation replacement when applicable, Selected Version, Scope, disclosure reveal, exact wrapped row, and match ranges in one Frame. It closes the Overlay only after publishing that Frame.

For an evicted source destination, Presentation retains the pending destination and keeps the Overlay open. Successful reacquisition builds and publishes the destination Frame, then closes the Overlay. Failure keeps the Overlay open and changes the affected version to its terminal failure row. Presentation never navigates to an approximate Line.

Authored navigation resolves CommentId or TempId against current Threads and the PendingReview. It applies the approved CommentScope behavior and saves every disclosure opened to expose the exact logical body line.

### Dependency-ordered implementation slices

1. **Search kernel and reachable source.** Add the Unicode table, `search.zig`, Candidate builders, bounded fuzzy benchmark, and source-range projection. Make source wrapping unconditional and remove `toggle_diff_wrap`. Prove literal and fuzzy semantics before state work.
2. **Buffer Search.** Add Buffer Search state, Actions, query input, semantic traversal, temporary disclosure reveal, command-line feedback, Theme styles, and atomic Frame projection. This slice provides complete `/`, `n`, and `N` behavior without File Enrichment.
3. **Authored Review Search.** Add the Review Search state and Overlay with ReviewBody candidates, fuzzy ordering, Preview, keyboard and pointer input, state retention, and exact authored navigation. This slice works before source acquisition completes.
4. **Streamed source Review Search.** Add eight-File scheduling, retry evidence, read leases, serial scan commands, per-version status rows, version-neutral coalescing, global reorder, cache enforcement, and remote or local parity.
5. **Exact source navigation and hardening.** Add cached and reacquired destination transactions, out-of-Hunk WholeFile navigation, Epoch and generation rejection, closure and shutdown cleanup, partial failures, allocation rollback, and the full acceptance matrix.

Each slice must leave all prior tests green and add a runnable user path. Do not create placeholder interfaces for later slices.

### Deterministic acceptance matrix

Live Bitbucket and PTY checks are optional. The required evidence uses pure tests, typed Presentation command tests, and headless rendering.

| Area | Required cases | Test tier |
| --- | --- | --- |
| Unicode query | ASCII and non-ASCII uppercase detection, simple fold pairs, multi-scalar folds excluded, no normalization, invalid UTF-8, NUL, 256-scalar limit | Pure |
| Literal matching | leftmost non-overlap, whitespace, punctuation, tabs, combining scalars, repeated matches, scalar columns, line boundaries | Pure |
| Fuzzy matching | exact and boundary bonuses, gaps, smart case, one result per Candidate, exact ranges, deterministic ties, exact and fallback classes | Pure |
| ReviewBody mapping | matches across Markdown delimiters, links, Suggestions, generated boundaries, authored ranges, logical body lines | Pure |
| Occurrence identity | old, new, version-neutral, CommentId, TempId, changed body, stable Buffer rebuild, expired Epoch | Pure and Presentation |
| Buffer corpus | Layouts, all Scope values, isolation, shared context once, hidden Fold, Thread, and ReviewCard content, generated text excluded | Pure and Presentation |
| Buffer query input | incremental edits, cancel restore, Enter, empty reuse, no prior query, no matches, Count, query limit, Selection refusal | Presentation |
| Buffer traversal | same-Line occurrences, old before new, `n`, `N`, Count, both wrap messages, manual cursor move, reprojection restoration | Presentation |
| Buffer feedback | prompt, active and total count, hidden count at narrow width, no-match color, match style priority, wrapped and SideBySide painting | Headless render |
| Review query input | first empty open, restored reopen, Unicode edits, digits as text, Escape retention, no Count | Presentation |
| Review ranking | ReviewBodies first, File-atomic partitions, global reorder, selection identity retention, clamp after removal | Pure and Presentation |
| Review Overlay | landscape and portrait layout, dense fields, complete Preview context, independent scrolling, long paths, source horizontal Preview, wrapped ReviewBody | Headless render |
| Pointer parity | click selection, double-click opening, list wheel, Preview wheel, stale Frame target rejection | Presentation and headless render |
| Acquisition | path order, eight File slots, 16 remote side requests, eight Git processes, in-flight join, no duplicate fetch, paused prefetch | Presentation with fake workers |
| Retry | one transport retry, `RateLimited` with `Retry-After`, one `ServerError` retry, definitive remote failure, local no-retry | Adapter and Presentation |
| File states | loading, text, absent, binary size, invalid UTF-8 size, invalid path, acquisition failure, usable opposite version | Presentation and headless render |
| Cache leases | scan pin, focused pin, budget overage while pinned, eviction after release, reacquisition, Session retirement, rejected completion cleanup | Pure and Presentation |
| Stale work | old command id, closed Overlay, old query generation, old Session Epoch, Session replacement, shutdown queue closure | Presentation and runtime |
| Source opening | old, new, version-neutral, isolated and all-Files Buffers, visible Hunk, Fold, out-of-Hunk WholeFile, exact wrapped range | Presentation |
| Reacquired opening | loading Overlay retained, successful atomic destination Frame, failed exact navigation, no approximate fallback | Presentation |
| Authored opening | Review, File, and inline scope, Reply inheritance, Draft, outdated, unavailable, complete disclosure chain | Presentation |
| Search lifetime | separate state, one active highlight owner, Overlay close and reopen, Layout, Scope, isolation, refresh, Review switch | Presentation |
| Unconditional wrapping | removed Action and binding, strict override rejection, Unified and SideBySide reachability, no horizontal source destination | Keymap, Presentation, and headless render |
| Atomic failure | matcher allocation failure, Candidate build failure, Frame build failure, lease allocation failure, prior Frame preserved | Pure and Presentation |

The implementation is complete when every matrix row passes, `zig build test --summary all` reports the increased test count, and every M21 item in `TODO.md` can point to one or more matrix rows.
