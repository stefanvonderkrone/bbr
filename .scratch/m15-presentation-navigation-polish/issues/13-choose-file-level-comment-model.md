# Choose the File-level Comment model

Type: grilling
Status: resolved
Blocked by: 01

## Question

How should bbr distinguish PullRequest-level, File-level, and inline Comment scopes across Review vocabulary and predicates, Draft persistence, Bitbucket mapping, root-owned Thread placement, Buffer projection at File headers, resolution, filtering, and duplicate reconciliation without overloading a line Anchor?

## Answer

Model the three root scopes explicitly and keep line anchoring narrow:

```zig
const CommentScope = union(enum) {
    pull_request,
    file: FileScope,
    inline: Anchor,
};

const FileScope = struct {
    path: []const u8,
    source_commit: []const u8,
};

const DraftKind = enum { comment, suggestion };
```

`Anchor` always identifies a line or range. A path without coordinates is a `FileScope`, never a degenerate Anchor. A root Comment or Draft carries exactly one `CommentScope`; a Reply carries only its parent and inherits the ultimate root's scope. Root-without-scope, Reply-with-scope, File scope with line coordinates, and inline scope without line coordinates are invalid and must be rejected rather than guessed. `Thread` placement, resolution, filtering, and predicates always use the root. Provide exhaustive PullRequest-level, File-level, and inline predicates over that effective root scope instead of retaining `isInline() == (anchor != null)`.

Draft kind is independent of root/Reply relationship and scope. A Suggestion may be a root or a Reply, but its effective scope must be inline and its effective Anchor must be on the new side. Thus a Suggestion Reply is valid inside an inline Thread; File-level and PullRequest-level Suggestion authoring is refused.

Generalize `AnchorState`, `AnchorResolution`, and Presentation's `AnchorProjection` to `ScopeState`, `ScopeResolution`, and `ScopeProjection`:

- `ScopeState` is `current`, `moved`, or `outdated`.
- `ScopeResolution` is a resolved state plus the projected `CommentScope`, or `unavailable`.
- PullRequest scope always resolves unchanged.
- Inline scope retains the existing line/range mapping behavior.
- File scope retains its authored path and source commit. On LocalReview refresh it stays `current` on an exact path, becomes `moved` only on a Git-proven rename, becomes `outdated` when Git proves that the File no longer participates, and becomes `unavailable` when the required evidence cannot be obtained.
- The durable authored scope never mutates. `ScopeProjection`, keyed by root TempId, owns Session-relative Draft placement; Replies reuse their root's entry.
- `AnchorSnapshot` remains exclusive to inline local roots. File-level fallbacks show authored path, state, body, and Replies without persisting the File's contents.

Project current and moved File-level roots immediately after their File header and before its first hunk, fold, or line. They belong to that File's isolated Buffer and count once per root in its Sidebar Comment/Draft tally; Replies never add to the tally. Outdated scopes that still match a Diff File's old or new path live in that File's Outdated disclosure. Unmatched outdated scopes and all unavailable scopes use review-level fallback sections in the all-files Buffer. A single-File isolate must not leak review-level or other-File fallbacks. Replies remain adjacent to their root in every placement.

At the Bitbucket boundary, classify only roots:

- `inline` absent/null maps to PullRequest scope.
- `inline.path` with every line/range coordinate absent/null maps to File scope.
- `inline.path` with a valid one-sided line or range maps to inline scope.
- A Reply's echoed `inline` data is ignored; parentage is its only domain relationship.

Creation performs the inverse mapping: omit `inline` for PullRequest roots, send path only for File roots, and send path plus coordinates for inline roots. Replies send their resolved parent. File scope's source commit and every projection/state field are local metadata, never request fields.

Duplicate reconciliation compares body plus the submitted relationship: roots compare their exact wire scope, while Replies compare their resolved parent. A File root matches the same path with no coordinates; an inline root on the same path is distinct. Ignore File scope's local source commit, projection state, and any scope Bitbucket echoes on Replies.

Persist Draft kind, root scope, and parent separately. The schema migration preserves existing rows: a parentless row without an Anchor becomes a PullRequest root, a parentless row with an Anchor becomes an inline root, and a row with a parent becomes a Reply with inherited scope. New File roots persist their path and authored source commit. No existing Draft is deleted or changes meaning.

The deterministic contract should cover exhaustive wire classification, invalid combinations, Reply inheritance (including Suggestion Replies), all four File-scope resolution outcomes, File-header placement in both layouts and isolate modes, per-File and review-level fallbacks, Sidebar root counts, SQLite migration/round-trip, create payloads for all scopes, and duplicate distinction between File and inline roots on the same path.
