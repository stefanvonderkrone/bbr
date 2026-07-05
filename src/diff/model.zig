//! The parsed diff model — the vocabulary of `src/diff/CONTEXT.md` as data.
//!
//! Everything here is **zero-copy**: `Line.text`, hunk headers, and file paths
//! all borrow slices of the raw unified-diff text passed to the parser. The raw
//! buffer must outlive the `Diff`. The parser allocates only the backing arrays
//! (`files`, `hunks`, `lines`); callers parse into an arena so there is no
//! per-node teardown (see `parser.zig`).

/// What happened to a `Line`. Bitbucket's diff is authoritative (ADR-0001), so
/// these three kinds are all a unified diff distinguishes. Intra-line emphasis
/// (`IntraLineSegment`) is a later, purely cosmetic overlay.
pub const LineKind = enum { context, added, removed };

/// A single row of the model. Exactly one of `old_no`/`new_no` is absent for a
/// changed line; both are present for `context`. Line numbers are 1-based, as
/// they appear in the file and in comment anchors.
pub const Line = struct {
    old_no: ?u32,
    new_no: ?u32,
    kind: LineKind,
    /// Text content with the diff prefix (` `/`+`/`-`) stripped, borrowed from
    /// the raw diff. Excludes the trailing newline.
    text: []const u8,
};

/// A contiguous region of change plus surrounding context, as delimited by the
/// `@@ -old_start,old_count +new_start,new_count @@` header.
pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    /// The full `@@ … @@` header line (including any trailing section text),
    /// borrowed from the raw diff.
    header: []const u8,
    lines: []const Line,
};

/// How a file changed. Derived from the `diff --git` preamble
/// (`new file mode` / `deleted file mode` / `rename …` / `/dev/null` sides).
pub const FileStatus = enum { added, modified, removed, renamed };

/// One changed path within a `Diff`. `old_path`/`new_path` are borrowed from the
/// raw diff and differ only for renames; for adds `old_path` and for removes
/// `new_path` may be `"/dev/null"`.
pub const File = struct {
    old_path: []const u8,
    new_path: []const u8,
    status: FileStatus,
    hunks: []const Hunk,
};

/// The complete set of changed files from one `DiffSource`.
pub const Diff = struct {
    files: []const File,
};
