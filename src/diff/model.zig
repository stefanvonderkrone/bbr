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
/// changed line. Hunk context has both; full-content context can have only the
/// selected side when the other side does not exist. Line numbers are 1-based,
/// as they appear in the file and in comment anchors.
pub const Line = struct {
    old_no: ?u32,
    new_no: ?u32,
    kind: LineKind,
    /// Text content with the diff prefix (` `/`+`/`-`) stripped, borrowed from
    /// the raw diff. Excludes the trailing newline.
    text: []const u8,
    /// True for a line that came from the fetched diff (a Hunk line), false for a
    /// `context` line synthesized from the file blob to fill the gaps between
    /// hunks in the true-whole-file view. Anchors bind only to Hunk lines, so a
    /// blob-sourced line never captures a comment or Draft (M9). Defaults true so
    /// the parser and every existing construction stay Hunk lines.
    in_hunk: bool = true,
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

pub const UnavailableReason = union(enum) {
    invalid_utf8,
    invalid_path,
    acquisition_failed: anyerror,
};

/// The independently renderable state of one expected File side. Text and
/// binary sizes are optional until acquisition provides them.
pub const FileContentStatus = union(enum) {
    text: ?usize,
    binary: ?usize,
    unavailable: struct {
        byte_size: ?usize = null,
        reason: UnavailableReason,
    },

    pub fn byteSize(self: FileContentStatus) ?usize {
        return switch (self) {
            .text, .binary => |size| size,
            .unavailable => |value| value.byte_size,
        };
    }
};

/// Index-aligned Session projection for one File. A null side is absent from
/// the File, as for the old side of an added File.
pub const FileContent = struct {
    old: ?FileContentStatus = null,
    new: ?FileContentStatus = null,
};

/// One changed path within a `Diff`. `old_path`/`new_path` are borrowed from the
/// raw diff and differ only for renames; for adds `old_path` and for removes
/// `new_path` may be `"/dev/null"`.
pub const File = struct {
    old_path: []const u8,
    new_path: []const u8,
    status: FileStatus,
    hunks: []const Hunk,
    /// File Content Status known from the RawDiff. File Enrichment refines text
    /// sizes and failures but must preserve binary sides.
    content: FileContent = .{ .old = .{ .text = null }, .new = .{ .text = null } },

    /// The path to show a reviewer. For a removed file the new side is
    /// `/dev/null`, so the real name lives on `old_path`; every other status
    /// (add / modify / rename) names the file by its new path.
    pub fn displayPath(self: File) []const u8 {
        return if (self.status == .removed) self.old_path else self.new_path;
    }
};

/// The complete set of changed files from one `DiffSource`.
pub const Diff = struct {
    files: []const File,
};

/// A file's fetched full-text blobs, used by the true-whole-file view (M9) to
/// fill the unchanged regions the diff omits. `new` is the file at the PR's
/// source commit, `old` at the destination — either may stay `null` until the
/// lazy per-file fetch returns. Held index-aligned with `Diff.files` (a Session
/// side table), not on `File`, because they arrive after the diff is parsed.
pub const FileBlob = struct {
    old: ?[]const u8 = null,
    new: ?[]const u8 = null,
};

const std = @import("std");

test "displayPath uses the real name for a removed file, not /dev/null" {
    const removed: File = .{ .old_path = "src/gone.zig", .new_path = "/dev/null", .status = .removed, .hunks = &.{} };
    try std.testing.expectEqualStrings("src/gone.zig", removed.displayPath());

    const added: File = .{ .old_path = "/dev/null", .new_path = "src/new.zig", .status = .added, .hunks = &.{} };
    try std.testing.expectEqualStrings("src/new.zig", added.displayPath());

    const modified: File = .{ .old_path = "src/a.zig", .new_path = "src/a.zig", .status = .modified, .hunks = &.{} };
    try std.testing.expectEqualStrings("src/a.zig", modified.displayPath());
}
