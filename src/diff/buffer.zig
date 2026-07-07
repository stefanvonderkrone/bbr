//! Buffer — the flattened, ordered rows the renderer walks to draw one `Diff`.
//!
//! A `Diff` is a tree (files → hunks → lines); rendering and navigation want a
//! flat sequence. `build` flattens the tree into `Row`s for a given `Layout`.
//! Zero-copy: every `Row` points into the `Diff` it was built from, so the
//! `Diff` (and the raw text it borrows) must outlive the `Buffer`. Only the row
//! array is allocated — pass an arena.
//!
//! Presentation concern, but it depends only on the diff model (no vaxis), so it
//! lives with the model and stays hermetically testable.

const std = @import("std");
const model = @import("model.zig");
const intraline = @import("intraline.zig");
const review = @import("../review/comment.zig");
const Thread = @import("../review/thread.zig").Thread;
const Comment = review.Comment;
const Draft = @import("../review/draft.zig").Draft;

/// Re-export so the renderer can name the segment type without reaching into
/// `intraline` directly.
pub const Segment = intraline.Segment;

/// Below this common-byte fraction a removed/added pair is treated as two
/// unrelated lines rather than an edit, so no intra-line emphasis is attached.
const emphasis_threshold: f64 = 0.5;

/// How a `Buffer` is arranged on screen. Only `unified` is built today;
/// `side_by_side` is the other axis (design §11) and lands later.
pub const Layout = enum { unified, side_by_side };

pub const RowKind = enum { file_header, hunk_header, line, line_pair, fold, comment, draft, section };

/// A diff body line plus any intra-line emphasis. `emphasis` is empty for
/// context lines and for changed lines with no modified counterpart (pure
/// add/remove); when present it partitions `line.text` into common/changed runs
/// (the same side of an `intraline.Pair`), so the renderer paints only the
/// changed runs with a brighter band.
pub const LineRow = struct {
    line: *const model.Line,
    emphasis: []const Segment = &.{},
};

/// One row of the side-by-side layout: the old line on the left, the new line
/// on the right. A context line fills both (the same `*Line`); a removed line
/// fills only `left`, an added line only `right`. A modified pair fills both
/// with distinct lines aligned on the row. An absent side (`null`) is drawn as
/// an empty gutter — the classic "missing line" filler.
pub const LinePair = struct {
    left: ?LineRow = null,
    right: ?LineRow = null,
};

/// A comment woven into the diff: the comment itself plus whether it's a reply
/// (so the renderer can indent it under its root).
pub const CommentRow = struct {
    comment: *const Comment,
    is_reply: bool,
};

/// A pending Draft woven into the diff: the Draft itself plus whether it's a
/// reply (indented under whatever it replies to), so the renderer can mark it
/// distinctly from a published comment.
pub const DraftRow = struct {
    draft: *const Draft,
    is_reply: bool,
};

pub const SectionKind = enum {
    /// PR-level comments (no anchor), shown once at the top.
    pr_comments,
    /// PR-level pending Drafts (no anchor), shown once near the top.
    pending,
    /// A per-file "Outdated (N)" group. `path` names the file.
    outdated,
};

/// A section divider introducing a run of comment rows.
pub const Section = struct {
    kind: SectionKind,
    count: usize,
    path: []const u8 = "",
};

/// One drawable row. Borrows the diff node (or comment) it projects.
pub const Row = union(RowKind) {
    file_header: *const model.File,
    hunk_header: *const model.Hunk,
    line: LineRow,
    line_pair: LinePair,
    fold: Fold,
    comment: CommentRow,
    draft: DraftRow,
    section: Section,
};

/// A collapsed run of context lines (the "Changes" scope hides long unchanged
/// stretches behind a fold). The hidden lines are already in the model, so
/// expanding is free — no refetch.
pub const Fold = struct {
    /// Stable identity across rebuilds: the first hidden line. The app keys its
    /// expanded-set on this pointer to reveal an individual fold.
    id: *const model.Line,
    /// The hidden context lines — a subslice of the hunk's `lines`.
    lines: []const model.Line,
};

/// Options for a build: comment weaving plus diff scope/folding.
///
/// `show_resolved` reveals resolved (but current) threads otherwise hidden
/// behind the toggle; outdated threads are never hidden regardless (design §9b).
///
/// `fold_context` is the "Changes" scope: context runs longer than
/// `2*context_margin + min_fold` collapse into a `Fold`, keeping `context_margin`
/// lines next to each change. `false` is the "whole-file" scope over the fetched
/// diff — every fetched line shown, no folds. (True whole-file, including
/// unchanged regions *outside* the fetched hunks, needs the file blob and is
/// deferred.) Folds whose `id` is in `expanded` are shown in full.
pub const BuildOptions = struct {
    show_resolved: bool = false,
    fold_context: bool = false,
    context_margin: usize = 3,
    min_fold: usize = 2,
    expanded: []const *const model.Line = &.{},
    /// Pending Drafts to weave in: anchored Drafts appear under their diff line
    /// (after any published comments there); unanchored ones in a "Pending"
    /// section near the top. Borrowed — must outlive the Buffer.
    drafts: []const Draft = &.{},
};

pub const Buffer = struct {
    rows: []const Row,
    layout: Layout,
};

pub const BuildError = error{
    /// The requested `Layout` is not implemented yet.
    LayoutUnsupported,
} || std.mem.Allocator.Error;

/// Flatten `diff` into rows for `layout`, with no comments. `allocator` should
/// be the buffer-scoped arena; the returned rows borrow `diff`.
pub fn build(allocator: std.mem.Allocator, diff: model.Diff, layout: Layout) BuildError!Buffer {
    return buildWithComments(allocator, diff, layout, &.{}, .{});
}

/// Flatten `diff` and weave `threads` in: PR-level comments as a section at the
/// top; each current/moved inline thread right under the diff line it anchors
/// to; each file's outdated threads in a per-file "Outdated" section after its
/// hunks. Resolved-but-current threads are hidden unless `opts.show_resolved`.
/// Rows borrow both `diff` and `threads` (and the comments they point at).
pub fn buildWithComments(
    allocator: std.mem.Allocator,
    diff: model.Diff,
    layout: Layout,
    threads: []const Thread,
    opts: BuildOptions,
) BuildError!Buffer {
    var rows: std.ArrayList(Row) = .empty;

    // 1. PR-level comments (no anchor), respecting the resolved toggle.
    const pr_count = countWhere(threads, isPrLevel, opts);
    if (pr_count > 0) {
        try rows.append(allocator, .{ .section = .{ .kind = .pr_comments, .count = pr_count } });
        for (threads) |*t| {
            if (isPrLevel(t.*) and inlineVisible(t.*, opts)) try emitThread(allocator, &rows, t);
        }
    }

    // 1b. PR-level pending Drafts (no anchor) — the reviewer's own unsent work.
    const pending_count = countUnanchoredDrafts(opts.drafts);
    if (pending_count > 0) {
        try rows.append(allocator, .{ .section = .{ .kind = .pending, .count = pending_count } });
        for (opts.drafts) |*d| {
            if (d.anchor == null) try emitDraft(allocator, &rows, d);
        }
    }

    // 2. Files, with inline threads under their lines and an outdated section.
    for (diff.files) |*file| {
        try rows.append(allocator, .{ .file_header = file });
        for (file.hunks) |*hunk| {
            try rows.append(allocator, .{ .hunk_header = hunk });
            const emphasis = try computeEmphasis(allocator, hunk.lines);
            const folds = try computeFolds(allocator, hunk.lines, opts);
            switch (layout) {
                .unified => try emitUnifiedHunk(allocator, &rows, threads, file, hunk.lines, emphasis, folds, opts),
                .side_by_side => try emitSideBySideHunk(allocator, &rows, threads, file, hunk.lines, emphasis, folds, opts),
            }
        }

        // Per-file outdated section — never hidden (design §9b).
        const od_count = fileOutdatedCount(threads, file.new_path);
        if (od_count > 0) {
            try rows.append(allocator, .{ .section = .{ .kind = .outdated, .count = od_count, .path = file.new_path } });
            for (threads) |*t| {
                if (isFileOutdated(t.*, file.new_path)) try emitThread(allocator, &rows, t);
            }
        }
    }

    return .{ .rows = try rows.toOwnedSlice(allocator), .layout = layout };
}

/// Append a thread's rows: root first, then its replies (indented).
fn emitThread(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), t: *const Thread) !void {
    try rows.append(allocator, .{ .comment = .{ .comment = t.root, .is_reply = false } });
    for (t.replies) |reply| {
        try rows.append(allocator, .{ .comment = .{ .comment = reply, .is_reply = true } });
    }
}

/// Append one Draft row. A reply Draft is indented under whatever it replies to.
fn emitDraft(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), d: *const Draft) !void {
    try rows.append(allocator, .{ .draft = .{ .draft = d, .is_reply = d.parent != null } });
}

/// Emit a hunk's lines in unified layout: one row per line, each followed by
/// any inline threads anchored to it.
fn emitUnifiedHunk(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    threads: []const Thread,
    file: *const model.File,
    lines: []const model.Line,
    emphasis: []const []const Segment,
    folds: []const Fold,
    opts: BuildOptions,
) !void {
    var i: usize = 0;
    while (i < lines.len) {
        if (foldStartingAt(folds, &lines[i])) |f| {
            try rows.append(allocator, .{ .fold = f });
            i += f.lines.len;
            continue;
        }
        try rows.append(allocator, .{ .line = .{ .line = &lines[i], .emphasis = emphasis[i] } });
        try weaveInline(allocator, rows, threads, file, &lines[i], opts);
        i += 1;
    }
}

/// Emit a hunk's lines in side-by-side layout: old on the left, new on the
/// right, modified pairs aligned on one row. Inline threads are woven after the
/// pair that carries their anchored line (once per underlying line, so a
/// context line — present on both sides — doesn't double-emit).
fn emitSideBySideHunk(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    threads: []const Thread,
    file: *const model.File,
    lines: []const model.Line,
    emphasis: []const []const Segment,
    folds: []const Fold,
    opts: BuildOptions,
) !void {
    var i: usize = 0;
    while (i < lines.len) {
        if (foldStartingAt(folds, &lines[i])) |f| {
            try rows.append(allocator, .{ .fold = f });
            i += f.lines.len;
            continue;
        }
        switch (lines[i].kind) {
            .context => {
                const both: LineRow = .{ .line = &lines[i] };
                try rows.append(allocator, .{ .line_pair = .{ .left = both, .right = both } });
                try weaveInline(allocator, rows, threads, file, &lines[i], opts);
                i += 1;
            },
            .added => {
                // An added run with no preceding removed: right side only.
                const start = i;
                while (i < lines.len and lines[i].kind == .added) i += 1;
                var p = start;
                while (p < i) : (p += 1) {
                    try rows.append(allocator, .{ .line_pair = .{ .right = .{ .line = &lines[p], .emphasis = emphasis[p] } } });
                    try weaveInline(allocator, rows, threads, file, &lines[p], opts);
                }
            },
            .removed => {
                const rem_start = i;
                while (i < lines.len and lines[i].kind == .removed) i += 1;
                const rem_end = i;
                var add_start = i;
                var add_end = i;
                if (i < lines.len and lines[i].kind == .added) {
                    add_start = i;
                    while (i < lines.len and lines[i].kind == .added) i += 1;
                    add_end = i;
                }
                const rn = rem_end - rem_start;
                const an = add_end - add_start;
                var p: usize = 0;
                while (p < @max(rn, an)) : (p += 1) {
                    const left: ?LineRow = if (p < rn) .{ .line = &lines[rem_start + p], .emphasis = emphasis[rem_start + p] } else null;
                    const right: ?LineRow = if (p < an) .{ .line = &lines[add_start + p], .emphasis = emphasis[add_start + p] } else null;
                    try rows.append(allocator, .{ .line_pair = .{ .left = left, .right = right } });
                    if (right) |rr| try weaveInline(allocator, rows, threads, file, rr.line, opts);
                    if (left) |ll| {
                        // Only weave the old line separately when it isn't the
                        // same line already woven on the right.
                        if (right == null or ll.line != right.?.line)
                            try weaveInline(allocator, rows, threads, file, ll.line, opts);
                    }
                }
            },
        }
    }
}

/// Append any current/moved inline threads anchored to `ln` in `file`,
/// respecting the resolved toggle. Outdated threads are grouped separately.
fn weaveInline(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    threads: []const Thread,
    file: *const model.File,
    ln: *const model.Line,
    opts: BuildOptions,
) !void {
    for (threads) |*t| {
        const anc = t.root.anchor orelse continue;
        if (t.root.state == .outdated) continue; // grouped below
        if (!std.mem.eql(u8, anc.path, file.new_path)) continue;
        if (!inlineVisible(t.*, opts)) continue;
        if (anchorMatchesLine(anc, ln)) try emitThread(allocator, rows, t);
    }
    // Pending anchored Drafts hang off the same line, after any published thread.
    for (opts.drafts) |*d| {
        const anc = d.anchor orelse continue;
        if (!std.mem.eql(u8, anc.path, file.new_path)) continue;
        if (anchorMatchesLine(anc, ln)) try emitDraft(allocator, rows, d);
    }
}

/// Compute the folds for one hunk under the current scope. A maximal run of
/// context lines keeps `context_margin` lines next to each adjacent change and
/// folds the rest, provided at least `min_fold` lines would be hidden. Returns
/// no folds when `fold_context` is off (whole-file scope) or when an individual
/// fold's id is in `opts.expanded`. Fold ranges never overlap a change, so they
/// never split a modified pair in the side-by-side layout.
fn computeFolds(allocator: std.mem.Allocator, lines: []const model.Line, opts: BuildOptions) ![]const Fold {
    var folds: std.ArrayList(Fold) = .empty;
    if (!opts.fold_context) return folds.toOwnedSlice(allocator);

    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].kind != .context) {
            i += 1;
            continue;
        }
        const s = i;
        while (i < lines.len and lines[i].kind == .context) i += 1;
        const e = i; // context run [s, e)

        const keep_top: usize = if (s > 0) opts.context_margin else 0;
        const keep_bottom: usize = if (e < lines.len) opts.context_margin else 0;
        const run = e - s;
        if (run < keep_top + keep_bottom) continue;
        if (run - keep_top - keep_bottom < opts.min_fold) continue;

        const fold_start = s + keep_top;
        const fold_end = e - keep_bottom;
        if (isExpanded(opts.expanded, &lines[fold_start])) continue;
        try folds.append(allocator, .{ .id = &lines[fold_start], .lines = lines[fold_start..fold_end] });
    }
    return folds.toOwnedSlice(allocator);
}

fn foldStartingAt(folds: []const Fold, line_ptr: *const model.Line) ?Fold {
    for (folds) |f| {
        if (f.id == line_ptr) return f;
    }
    return null;
}

fn isExpanded(expanded: []const *const model.Line, id: *const model.Line) bool {
    for (expanded) |e| {
        if (e == id) return true;
    }
    return false;
}

/// Compute intra-line emphasis for every line in a hunk. Returns a slice
/// index-aligned with `lines`; entries default to empty. A maximal run of
/// removed lines immediately followed by a run of added lines is treated as a
/// modification: removed[k] is word-diffed against added[k] (paired by index),
/// and if the two are similar enough both lines get their emphasis segments.
/// Pure adds, pure removes, and context stay empty (whole-line band).
fn computeEmphasis(allocator: std.mem.Allocator, lines: []const model.Line) ![]const []const Segment {
    const out = try allocator.alloc([]const Segment, lines.len);
    for (out) |*e| e.* = &.{};

    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].kind != .removed) {
            i += 1;
            continue;
        }
        const rem_start = i;
        while (i < lines.len and lines[i].kind == .removed) i += 1;
        const rem_end = i;
        if (i >= lines.len or lines[i].kind != .added) continue;
        const add_start = i;
        while (i < lines.len and lines[i].kind == .added) i += 1;
        const add_end = i;

        const pairs = @min(rem_end - rem_start, add_end - add_start);
        var k: usize = 0;
        while (k < pairs) : (k += 1) {
            const pair = try intraline.diff(allocator, lines[rem_start + k].text, lines[add_start + k].text);
            if (intraline.similarity(pair) >= emphasis_threshold) {
                out[rem_start + k] = pair.old;
                out[add_start + k] = pair.new;
            }
        }
    }
    return out;
}

fn isPrLevel(t: Thread) bool {
    return t.root.anchor == null;
}

/// A current/moved thread is visible unless it's resolved and the toggle is off.
fn inlineVisible(t: Thread, opts: BuildOptions) bool {
    return opts.show_resolved or !t.resolved;
}

fn isFileOutdated(t: Thread, path: []const u8) bool {
    const anc = t.root.anchor orelse return false;
    return t.root.state == .outdated and std.mem.eql(u8, anc.path, path);
}

fn fileOutdatedCount(threads: []const Thread, path: []const u8) usize {
    var n: usize = 0;
    for (threads) |*t| {
        if (isFileOutdated(t.*, path)) n += 1;
    }
    return n;
}

fn countUnanchoredDrafts(drafts: []const Draft) usize {
    var n: usize = 0;
    for (drafts) |*d| {
        if (d.anchor == null) n += 1;
    }
    return n;
}

fn countWhere(threads: []const Thread, pred: fn (Thread) bool, opts: BuildOptions) usize {
    var n: usize = 0;
    for (threads) |*t| {
        if (pred(t.*) and inlineVisible(t.*, opts)) n += 1;
    }
    return n;
}

/// Does `anchor` bind to this diff line? Prefer the new side (`to` ↔ `new_no`),
/// falling back to the old side (`from` ↔ `old_no`).
fn anchorMatchesLine(anchor: review.Anchor, ln: *const model.Line) bool {
    if (anchor.to) |to| return ln.new_no != null and ln.new_no.? == to;
    if (anchor.from) |from| return ln.old_no != null and ln.old_no.? == from;
    return false;
}

// ---------------------------------------------------------------------------
// Tests — hermetic; build a Diff via the parser, then flatten it.
// ---------------------------------------------------------------------------

const testing = std.testing;
const parse = @import("parser.zig").parse;

const two_file_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-old
    \\+new
    \\diff --git a/b.txt b/b.txt
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -5 +5,2 @@
    \\ ctx
    \\+extra
    \\
;

test "build flattens files → hunks → lines in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, two_file_diff);
    const buf = try build(a, diff, .unified);

    try testing.expectEqual(Layout.unified, buf.layout);
    // file A: header + hunk header + 3 lines = 5; file B: header + hunk + 2 = 4.
    try testing.expectEqual(@as(usize, 9), buf.rows.len);

    try testing.expect(buf.rows[0] == .file_header);
    try testing.expectEqualStrings("a.txt", buf.rows[0].file_header.new_path);
    try testing.expect(buf.rows[1] == .hunk_header);
    try testing.expect(buf.rows[2] == .line);
    try testing.expectEqual(model.LineKind.context, buf.rows[2].line.line.kind);
    try testing.expectEqual(model.LineKind.removed, buf.rows[3].line.line.kind);
    try testing.expectEqual(model.LineKind.added, buf.rows[4].line.line.kind);

    try testing.expect(buf.rows[5] == .file_header);
    try testing.expectEqualStrings("b.txt", buf.rows[5].file_header.new_path);
    try testing.expect(buf.rows[6] == .hunk_header);
    try testing.expectEqual(model.LineKind.context, buf.rows[7].line.line.kind);
    try testing.expectEqual(model.LineKind.added, buf.rows[8].line.line.kind);
}

test "a modified line pair carries intra-line emphasis; unrelated lines do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // First hunk: a genuine edit (one word changes). Second: a wholesale
    // replacement (nothing in common) — those must not be emphasized.
    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,4 +1,4 @@
        \\ ctx
        \\-let value = 1;
        \\+let value = 2;
        \\ tail
        \\-aaaaaaaa
        \\+zzzzzzzz
        \\
    ;
    const diff = try parse(a, raw);
    const buf = try build(a, diff, .unified);

    // Rows: header, hunk, ctx, -edit, +edit, tail, -aaaa, +zzzz.
    const removed_edit = buf.rows[3].line;
    const added_edit = buf.rows[4].line;
    try testing.expectEqual(model.LineKind.removed, removed_edit.line.kind);
    try testing.expect(removed_edit.emphasis.len > 0);
    try testing.expect(added_edit.emphasis.len > 0);
    // The common prefix "let value = " is not emphasized; only "1"/"2" is.
    try testing.expect(!removed_edit.emphasis[0].emphasis);

    // The wholesale replacement shares nothing → treated as unrelated, no emphasis.
    try testing.expectEqual(@as(usize, 0), buf.rows[6].line.emphasis.len);
    try testing.expectEqual(@as(usize, 0), buf.rows[7].line.emphasis.len);
}

test "rows borrow the diff (pointer identity, not copies)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, two_file_diff);
    const buf = try build(a, diff, .unified);

    try testing.expectEqual(&diff.files[0], buf.rows[0].file_header);
    try testing.expectEqual(&diff.files[0].hunks[0].lines[0], buf.rows[2].line.line);
}

test "empty diff yields no rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = try build(a, .{ .files = &.{} }, .unified);
    try testing.expectEqual(@as(usize, 0), buf.rows.len);
}

test "side_by_side pairs context, aligns a modification, and fills add/remove" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ctx, then a modified pair (old/new), then a pure add, then a pure remove.
    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,4 +1,4 @@
        \\ ctx
        \\-let x = 1;
        \\+let x = 2;
        \\+brand new
        \\-goodbye
        \\
    ;
    const diff = try parse(a, raw);
    const buf = try build(a, diff, .side_by_side);
    try testing.expectEqual(Layout.side_by_side, buf.layout);

    // Rows: file_header, hunk_header, then 4 line_pairs.
    try testing.expect(buf.rows[0] == .file_header);
    try testing.expect(buf.rows[1] == .hunk_header);

    // Context: both sides show the same line.
    const ctx = buf.rows[2].line_pair;
    try testing.expect(ctx.left != null and ctx.right != null);
    try testing.expectEqual(ctx.left.?.line, ctx.right.?.line);

    // Modification: left removed, right added, aligned on one row, both emphasized.
    const mod = buf.rows[3].line_pair;
    try testing.expectEqual(model.LineKind.removed, mod.left.?.line.kind);
    try testing.expectEqual(model.LineKind.added, mod.right.?.line.kind);
    try testing.expect(mod.left.?.emphasis.len > 0);

    // Pure add: right only.
    const add = buf.rows[4].line_pair;
    try testing.expect(add.left == null);
    try testing.expectEqual(model.LineKind.added, add.right.?.line.kind);

    // Pure remove: left only.
    const rem = buf.rows[5].line_pair;
    try testing.expectEqual(model.LineKind.removed, rem.left.?.line.kind);
    try testing.expect(rem.right == null);

    try testing.expectEqual(@as(usize, 6), buf.rows.len);
}

test "side_by_side weaves an inline thread once, under its anchored pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    // anchor_diff new-side line 2 is "+new"; comment anchors there.
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "why?", .anchor = .{ .path = "a.txt", .to = 2 } },
    };
    const threads = try @import("../review/thread.zig").build(a, &comments);
    const buf = try buildWithComments(a, diff, .side_by_side, threads, .{});

    // Exactly one comment row (not double-woven across the two panes).
    try testing.expectEqual(@as(usize, 1), countKind(buf, .comment));
}

// --- Comment weaving --------------------------------------------------------

/// A one-file diff whose new-side lines are 1 (keep), 1→gone, 2 (new).
const anchor_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-old
    \\+new
    \\
;

fn countKind(buf: Buffer, kind: RowKind) usize {
    var n: usize = 0;
    for (buf.rows) |r| {
        if (r == kind) n += 1;
    }
    return n;
}

// A hunk with a long unchanged middle: change, 10 context lines, change.
const long_context_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,12 +1,12 @@
    \\-a
    \\+A
    \\ c1
    \\ c2
    \\ c3
    \\ c4
    \\ c5
    \\ c6
    \\ c7
    \\ c8
    \\ c9
    \\ c10
    \\-b
    \\+B
    \\
;

test "the changes scope folds a long context run, keeping a margin each side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, long_context_diff);

    // Whole-file scope (the default): no folding.
    const whole = try build(a, diff, .unified);
    try testing.expectEqual(@as(usize, 0), countKind(whole, .fold));

    // Changes scope: the 10-line context run keeps 3 lines each side and folds
    // the remaining 4 into a single fold row.
    const folded = try buildWithComments(a, diff, .unified, &.{}, .{ .fold_context = true });
    try testing.expectEqual(@as(usize, 1), countKind(folded, .fold));
    var fold_id: *const model.Line = undefined;
    for (folded.rows) |r| {
        if (r == .fold) {
            try testing.expectEqual(@as(usize, 4), r.fold.lines.len);
            fold_id = r.fold.id;
        }
    }

    // Expanding that fold (by id) reveals all lines, with no fold row left.
    const expanded = try buildWithComments(a, diff, .unified, &.{}, .{
        .fold_context = true,
        .expanded = &.{fold_id},
    });
    try testing.expectEqual(@as(usize, 0), countKind(expanded, .fold));
    // The expanded buffer has exactly the fold's hidden lines more than the folded one.
    try testing.expectEqual(folded.rows.len + 4 - 1, expanded.rows.len);
}

test "a short context run is never folded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // anchor_diff has only one context line — nothing to fold.
    const diff = try parse(a, anchor_diff);
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .fold_context = true });
    try testing.expectEqual(@as(usize, 0), countKind(buf, .fold));
}

test "folds apply in the side-by-side layout too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, long_context_diff);
    const buf = try buildWithComments(a, diff, .side_by_side, &.{}, .{ .fold_context = true });
    try testing.expectEqual(@as(usize, 1), countKind(buf, .fold));
}

test "an inline thread is woven right under its anchored line, replies indented" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    // Anchor to new line 2 (the "+new" line).
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "why?", .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "because" },
    };
    const threads = try @import("../review/thread.zig").build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});

    // Rows: file_header, hunk_header, line(keep), line(old), line(new),
    //       comment(root), comment(reply).
    try testing.expectEqual(@as(usize, 7), buf.rows.len);
    try testing.expect(buf.rows[4] == .line);
    try testing.expectEqual(@as(?u32, 2), buf.rows[4].line.line.new_no);
    try testing.expect(buf.rows[5] == .comment);
    try testing.expect(!buf.rows[5].comment.is_reply);
    try testing.expectEqual(@as(review.CommentId, 1), buf.rows[5].comment.comment.id);
    try testing.expect(buf.rows[6] == .comment);
    try testing.expect(buf.rows[6].comment.is_reply);
}

test "PR-level comments get a section at the top" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "overall LGTM" }, // no anchor
    };
    const threads = try @import("../review/thread.zig").build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});

    try testing.expect(buf.rows[0] == .section);
    try testing.expectEqual(SectionKind.pr_comments, buf.rows[0].section.kind);
    try testing.expectEqual(@as(usize, 1), buf.rows[0].section.count);
    try testing.expect(buf.rows[1] == .comment);
}

test "resolved threads hide behind the toggle, whole thread revealed when on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "nit", .resolved = true, .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "fixed" },
    };
    const threads = try @import("../review/thread.zig").build(a, &comments);

    // Hidden by default: no comment rows.
    const hidden = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 0), countKind(hidden, .comment));

    // Revealed: the whole thread (root + reply) appears.
    const shown = try buildWithComments(a, diff, .unified, threads, .{ .show_resolved = true });
    try testing.expectEqual(@as(usize, 2), countKind(shown, .comment));
}

test "outdated threads go in a per-file section and are never hidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        // Outdated AND resolved — still shown (outdated wins).
        .{ .id = 1, .author = "Ada", .body = "stale note", .resolved = true, .state = .outdated, .anchor = .{ .path = "a.txt", .from = 99 } },
    };
    const threads = try @import("../review/thread.zig").build(a, &comments);

    // Even with the resolved toggle off, the outdated section shows.
    const buf = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 1), countKind(buf, .section));
    var found = false;
    for (buf.rows) |r| {
        if (r == .section and r.section.kind == .outdated) {
            found = true;
            try testing.expectEqual(@as(usize, 1), r.section.count);
            try testing.expectEqualStrings("a.txt", r.section.path);
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 1), countKind(buf, .comment));
}

test "an anchored draft is woven under its line; a PR-level draft gets a pending section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .top_level, .body = "overall: needs tests" }, // no anchor
        .{ .local_id = 2, .kind = .inline_comment, .body = "why new?", .anchor = .{ .path = "a.txt", .to = 2, .commit = "c0" } },
    };
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });

    // A pending section at the very top, then the PR-level draft row.
    try testing.expect(buf.rows[0] == .section);
    try testing.expectEqual(SectionKind.pending, buf.rows[0].section.kind);
    try testing.expectEqual(@as(usize, 1), buf.rows[0].section.count);
    try testing.expect(buf.rows[1] == .draft);
    try testing.expectEqual(@as(u64, 1), buf.rows[1].draft.draft.local_id);

    // Exactly two draft rows total (one pending, one inline), and the inline one
    // sits right after the "+new" line (new_no == 2).
    try testing.expectEqual(@as(usize, 2), countKind(buf, .draft));
    for (buf.rows, 0..) |r, i| {
        if (r == .draft and r.draft.draft.local_id == 2) {
            try testing.expect(buf.rows[i - 1] == .line);
            try testing.expectEqual(@as(?u32, 2), buf.rows[i - 1].line.line.new_no);
        }
    }
}

test "a reply draft carries the reply flag for indentation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .reply, .body = "re", .parent = .{ .comment = 5 } },
    };
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });
    try testing.expectEqual(@as(usize, 1), countKind(buf, .draft));
    for (buf.rows) |r| {
        if (r == .draft) try testing.expect(r.draft.is_reply);
    }
}

test "an inline thread anchored to a missing current line is not lost silently" {
    // Anchored to new line 999 (not in the diff) but marked current → it simply
    // doesn't attach anywhere. This documents the known gap (Bitbucket would
    // normally mark such a comment outdated); guard so the count stays 0.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "ghost", .anchor = .{ .path = "a.txt", .to = 999 } },
    };
    const threads = try @import("../review/thread.zig").build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 0), countKind(buf, .comment));
}
