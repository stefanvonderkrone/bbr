//! Buffer — the flattened, ordered rows the renderer walks to draw one `Diff`.
//!
//! A `Diff` is a tree (files → hunks → lines); rendering and navigation want a
//! flat sequence. `build` flattens the tree into `Row`s for a given `Layout`.
//! Zero-copy: every `Row` points into the `Diff` it was built from, so the
//! `Diff` (and the raw text it borrows) must outlive the `Buffer`. Only the row
//! array is allocated — pass an arena.
//!
//! Presentation owns this projection. It depends on Diff and Review's public
//! models but remains network-free and vaxis-free.

const std = @import("std");
const bbr = @import("bbr");
const model = bbr.diff.model;
const intraline = bbr.diff.intraline;
const decoration = bbr.highlight.decoration;
const review = bbr.review.comment;
const Thread = bbr.review.Thread;
const Comment = review.Comment;
const Draft = bbr.review.Draft;
const Parent = bbr.review.draft.Parent;
const anchor_projection = bbr.review.anchor;
const review_card = @import("review_card.zig");
const CellMetrics = @import("cell_metrics.zig").CellMetrics;

/// Re-export so the renderer can name the segment type without reaching into
/// `intraline` directly.
pub const Segment = intraline.Segment;

/// Below this common-byte fraction a removed/added pair is treated as two
/// unrelated lines rather than an edit, so no intra-line emphasis is attached.
const emphasis_threshold: f64 = 0.5;

/// How a `Buffer` is arranged on screen. Only `unified` is built today;
/// `side_by_side` is the other axis (design §11) and lands later.
pub const Layout = enum { unified, side_by_side };

pub const RowKind = enum { file_header, hunk_header, status_placeholder, line, line_pair, disclosure, comment, draft, snapshot, section };

pub const DisclosureKey = union(enum) {
    resolved_thread: review.CommentId,
    fold: *const model.Line,
    outdated_file: *const model.File,
    outdated_review,
    review_card: review_card.Owner,
};

pub const DisclosureKind = enum { resolved_thread, fold, outdated, review_card };

pub const Disclosure = struct {
    key: DisclosureKey,
    kind: DisclosureKind,
    expanded: bool,
    count: usize,
    path: []const u8 = "",
};

/// A diff body line plus any intra-line emphasis. `emphasis` is empty for
/// context lines and for changed lines with no modified counterpart (pure
/// add/remove); when present it partitions `line.text` into common/changed runs
/// (the same side of an `intraline.Pair`), so the renderer paints only the
/// changed runs with a brighter band.
pub const LineRow = struct {
    line: *const model.Line,
    decoration: decoration.LineDecoration,
};

/// One row of the side-by-side layout: the old line on the left, the new line
/// on the right. A context line fills each side named by its line numbers; a
/// removed line fills only `left`, and an added line only `right`. A modified
/// pair fills both with distinct lines aligned on the row. An absent side
/// (`null`) is drawn as an empty gutter — the classic "missing line" filler.
pub const LinePair = struct {
    left: ?LineRow = null,
    right: ?LineRow = null,
};

const MatchOperation = enum { pair, left, right, done };

const MatchCell = struct {
    cost: f64,
    exact_pairs: usize,
    first_old: usize = std.math.maxInt(usize),
    first_new: usize = std.math.maxInt(usize),
    operation: MatchOperation,
};

fn chooseMatch(best: *?MatchCell, candidate: MatchCell) void {
    const current = best.* orelse {
        best.* = candidate;
        return;
    };
    const cost_delta = candidate.cost - current.cost;
    const equal_cost = @abs(cost_delta) <= 1e-12;
    const earlier_pair = candidate.first_old < current.first_old or
        (candidate.first_old == current.first_old and candidate.first_new < current.first_new);
    if (cost_delta < -1e-12 or
        (equal_cost and candidate.exact_pairs > current.exact_pairs) or
        (equal_cost and candidate.exact_pairs == current.exact_pairs and earlier_pair))
    {
        best.* = candidate;
    }
}

pub const StatusPlaceholder = struct {
    file: *const model.File,
    old: ?model.FileContentStatus = null,
    new: ?model.FileContentStatus = null,
};

/// A comment woven into the diff: the comment itself plus whether it's a reply
/// (so the renderer can indent it under its root). A multi-line body emits one
/// CommentRow per visual line (M11 option A2), all sharing `comment`, so the
/// buffer keeps its one-Row-per-screen-line invariant and `Nav`/scroll are
/// untouched. `line` is that row's visual line (zero-copy into `comment.body`);
/// `is_first` marks the header row that carries the marker + author.
pub const ReviewCardRow = review_card.ReviewCardRow;
pub const CommentRow = ReviewCardRow;
pub const DraftRow = ReviewCardRow;

pub const SnapshotRow = struct {
    draft: *const Draft,
    line: []const u8,
    selected: bool,
};

pub const SectionKind = enum {
    /// PR-level comments (no anchor), shown once at the top.
    pr_comments,
    /// PR-level pending Drafts (no anchor), shown once near the top.
    pending,
    /// A per-file "Outdated (N)" group. `path` names the file.
    outdated,
    /// Review-level Anchors whose required Git evidence was unavailable.
    unavailable,
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
    status_placeholder: StatusPlaceholder,
    line: LineRow,
    line_pair: LinePair,
    disclosure: Disclosure,
    comment: CommentRow,
    draft: DraftRow,
    snapshot: SnapshotRow,
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
/// `fold_context` is the "Changes" scope: context runs longer than
/// `2*context_margin + min_fold` collapse into a `Fold`, keeping `context_margin`
/// lines next to each change. `false` is the "whole-file" scope over the fetched
/// diff — every fetched line shown, no folds. (True whole-file, including
/// unchanged regions *outside* the fetched hunks, needs the file blob and is
/// deferred.) Every hidden-content owner keeps a persistent disclosure row and
/// is expanded only when its tagged semantic key is explicitly present.
pub const BuildOptions = struct {
    fold_context: bool = false,
    context_margin: usize = 3,
    min_fold: usize = 2,
    expanded_disclosures: []const DisclosureKey = &.{},
    /// Pending Drafts to weave in: anchored Drafts appear under their diff line
    /// (after any published comments there); unanchored ones in a "Pending"
    /// section near the top. Borrowed — must outlive the Buffer.
    drafts: []const Draft = &.{},
    anchor_projections: []const anchor_projection.ProjectionEntry = &.{},
    scope_projections: []const anchor_projection.ScopeProjectionEntry = &.{},
    /// Isolate view: when set, project only `diff.files[only_file]` — its header,
    /// hunks (with woven inline threads/drafts), and its outdated section. The
    /// PR-level comment and pending sections are suppressed (they belong to no
    /// single File), as are the other files' rows and stranded Drafts. `null`
    /// flattens the whole Diff (the continuous all-files scroll).
    only_file: ?usize = null,
    /// True-whole-file scope (M9): splice each file's fetched Hunk lines into the
    /// unchanged lines of its old blob for a removed File, or its new blob for
    /// every other File. A File with no selected blob falls back to the fetched
    /// rendering. Implies no folding. `false` keeps the Changes/fetched behaviour
    /// driven by `fold_context`.
    whole_file: bool = false,
    /// Per-file blobs for the whole-file splice, index-aligned with `diff.files`
    /// (a shorter/empty slice just means "not loaded" for the missing files).
    blobs: []const model.FileBlob = &.{},
    /// Side-specific Highlighting results, index-aligned with `diff.files`.
    highlights: []const bbr.highlight.highlighter.FileHighlights = &.{},
    /// Per-side File Content Status, index-aligned with `diff.files`.
    content_statuses: []const model.FileContent = &.{},
    /// Shared terminal geometry for ReviewCard wrapping.
    card_width: usize = 80,
    cell_metrics: CellMetrics = .bytes,
    collapsed_rows: usize = 6,
};

pub fn disclosureKey(row: Row) ?DisclosureKey {
    return switch (row) {
        .disclosure => |value| value.key,
        .comment, .draft => |card| if (card.part == .disclosure_footer) .{ .review_card = card.owner } else null,
        else => null,
    };
}

fn disclosureExpanded(keys: []const DisclosureKey, key: DisclosureKey) bool {
    for (keys) |candidate| if (std.meta.eql(candidate, key)) return true;
    return false;
}

pub const Buffer = struct {
    rows: []const Row,
    layout: Layout,
    file_tallies: []const FileTally = &.{},
};

pub const FileTally = struct { comments: usize = 0, drafts: usize = 0 };

pub const BuildError = error{
    /// The requested `Layout` is not implemented yet.
    LayoutUnsupported,
} || decoration.Error;

/// Flatten `diff` into rows for `layout`, with no comments. `allocator` should
/// be the buffer-scoped arena; the returned rows borrow `diff`.
pub fn build(allocator: std.mem.Allocator, diff: model.Diff, layout: Layout) BuildError!Buffer {
    return buildWithComments(allocator, diff, layout, &.{}, .{});
}

/// Flatten `diff` and weave `threads` in: PR-level comments as a section at the
/// top; each current/moved inline thread right under the diff line it anchors
/// to; each file's outdated threads in a per-file "Outdated" section after its
/// hunks. Resolved Threads and Outdated groups keep a disclosure row even when
/// their content is collapsed.
/// Rows borrow both `diff` and `threads` (and the comments they point at).
pub fn buildWithComments(
    allocator: std.mem.Allocator,
    diff: model.Diff,
    layout: Layout,
    threads: []const Thread,
    opts: BuildOptions,
) BuildError!Buffer {
    var rows: std.ArrayList(Row) = .empty;

    // A Draft is placed exactly once: a root Draft by its anchor (inline line, or
    // the PR-level "Pending" section); a reply Draft after its parent's row (a
    // published Comment or another Draft), following the `parent` link — never by
    // anchor. The `emitted` guard makes "exactly once" enforceable and lets an
    // orphaned reply (parent hidden or absent) surface at the end rather than
    // vanish.
    const emitted = try allocator.alloc(bool, opts.drafts.len);
    @memset(emitted, false);
    const emitted_threads = try allocator.alloc(bool, threads.len);
    @memset(emitted_threads, false);
    var w: Weave = .{
        .a = allocator,
        .rows = &rows,
        .threads = threads,
        .drafts = opts.drafts,
        .emitted = emitted,
        .emitted_threads = emitted_threads,
        .opts = opts,
    };

    // 1. PR-level comments (no anchor), respecting the resolved toggle. Skipped
    // in the isolate view — PR-level comments belong to no single File.
    const pr_count = if (opts.only_file == null) countWhere(threads, isPrLevel) else 0;
    if (pr_count > 0) {
        try rows.append(allocator, .{ .section = .{ .kind = .pr_comments, .count = pr_count } });
        for (threads) |*t| {
            if (isPrLevel(t.*)) try w.emitThread(t);
        }
    }

    // 1b. PR-level pending Drafts: root Drafts with no anchor — the reviewer's
    // own unsent top-level work. Reply Drafts are placed under their parent (in
    // emitThread / emitDraft), not here.
    const pending_count = if (opts.only_file == null) countPendingRoots(opts.drafts) else 0;
    if (pending_count > 0) {
        try rows.append(allocator, .{ .section = .{ .kind = .pending, .count = pending_count } });
        for (opts.drafts, 0..) |*d, i| {
            if (d.parent == null and draftScope(d, opts) == .review) try w.emitDraft(i);
        }
    }

    // 2. Files, with inline threads under their lines and an outdated section.
    // In the isolate view only the focused file is emitted.
    for (diff.files, 0..) |*file, fi| {
        if (opts.only_file) |only| {
            if (fi != only) continue;
        }
        try rows.append(allocator, .{ .file_header = file });

        // File-level roots live at the File header, before hunks/folds/lines.
        for (threads) |*t| {
            if (threadCurrentInFile(t.*, file.*)) try w.emitThread(t);
        }
        for (opts.drafts, 0..) |*draft, draft_index| {
            if (draft.parent == null and draftCurrentInFile(draft, opts, file.*)) try w.emitDraft(draft_index);
        }

        try emitStatusPlaceholders(allocator, &rows, layout, file, contentStatus(opts.content_statuses, fi));

        // True-whole-file: splice the fetched Hunk lines into the selected side's
        // unchanged lines and emit one continuous sequence without headers or
        // folds. Falls back to the per-hunk path when that side is unavailable.
        if (opts.whole_file and wholeFileContent(opts.blobs, fi, file.*) != null) {
            const content = wholeFileContent(opts.blobs, fi, file.*).?;
            const lines = switch (content.side) {
                .old => try spliceOldSide(allocator, file.*, content.blob),
                .new => try spliceNewSide(allocator, file.*, content.blob),
            };
            switch (layout) {
                .unified => try w.emitUnifiedHunk(fi, file, lines, try computeEmphasis(allocator, lines), &.{}),
                .side_by_side => try w.emitSideBySideHunk(fi, file, lines, &.{}),
            }
        } else for (file.hunks) |*hunk| {
            try rows.append(allocator, .{ .hunk_header = hunk });
            const folds = try computeFolds(allocator, hunk.lines, opts);
            switch (layout) {
                .unified => try w.emitUnifiedHunk(fi, file, hunk.lines, try computeEmphasis(allocator, hunk.lines), folds),
                .side_by_side => try w.emitSideBySideHunk(fi, file, hunk.lines, folds),
            }
        }

        // Per-file Outdated disclosure remains at the File even while closed.
        const od_count = fileOutdatedCount(threads, file.*) + draftOutdatedCount(opts.drafts, opts, file.*);
        if (od_count > 0) {
            const key: DisclosureKey = .{ .outdated_file = file };
            const expanded = disclosureExpanded(opts.expanded_disclosures, key);
            try rows.append(allocator, .{ .disclosure = .{ .key = key, .kind = .outdated, .expanded = expanded, .count = od_count, .path = file.displayPath() } });
            if (expanded) {
                for (threads) |*t| {
                    if (isFileOutdated(t.*, file.*)) try w.emitThreadContent(t);
                }
                for (opts.drafts, 0..) |*draft, draft_index| {
                    if (draft.parent != null or w.emitted[draft_index]) continue;
                    if (draftOutdatedInFile(draft, opts, file.*)) try w.emitDraftSnapshot(draft_index);
                }
            } else {
                for (threads, 0..) |*thread, thread_index| {
                    if (isFileOutdated(thread.*, file.*)) w.emitted_threads[thread_index] = true;
                }
                for (opts.drafts, 0..) |*draft, draft_index| {
                    if (draft.parent == null and draftOutdatedInFile(draft, opts, file.*)) w.emitted[draft_index] = true;
                }
            }
        }
    }

    var unavailable_count: usize = 0;
    var fallback_outdated_count: usize = 0;
    if (opts.only_file == null) for (threads, 0..) |thread, thread_index| {
        if (!emitted_threads[thread_index] and thread.root.state == .outdated) fallback_outdated_count += 1;
    };
    for (opts.drafts, 0..) |*draft, draft_index| {
        if (draft.parent != null or emitted[draft_index]) continue;
        if (!draftInScope(draft, diff, opts)) continue;
        switch (draftResolution(draft, opts)) {
            .unavailable => unavailable_count += 1,
            .resolved => |resolved| {
                if (resolved.state == .outdated) fallback_outdated_count += 1;
            },
        }
    }
    if (fallback_outdated_count > 0) {
        const key: DisclosureKey = .outdated_review;
        const expanded = disclosureExpanded(opts.expanded_disclosures, key);
        try rows.append(allocator, .{ .disclosure = .{ .key = key, .kind = .outdated, .expanded = expanded, .count = fallback_outdated_count } });
        if (expanded) {
            if (opts.only_file == null) for (threads, 0..) |*thread, thread_index| {
                if (!emitted_threads[thread_index] and thread.root.state == .outdated) try w.emitThreadContent(thread);
            };
            for (opts.drafts, 0..) |*draft, draft_index| {
                if (draft.parent != null or emitted[draft_index]) continue;
                if (!draftInScope(draft, diff, opts)) continue;
                const resolution = draftResolution(draft, opts);
                if (resolution == .resolved and resolution.resolved.state == .outdated) try w.emitDraftSnapshot(draft_index);
            }
        } else {
            for (opts.drafts, 0..) |*draft, draft_index| {
                if (draft.parent != null or emitted[draft_index]) continue;
                if (!draftInScope(draft, diff, opts)) continue;
                const resolution = draftResolution(draft, opts);
                if (resolution == .resolved and resolution.resolved.state == .outdated) emitted[draft_index] = true;
            }
        }
    }
    if (unavailable_count > 0) {
        try rows.append(allocator, .{ .section = .{ .kind = .unavailable, .count = unavailable_count } });
        for (opts.drafts, 0..) |*draft, draft_index| {
            if (draft.parent != null or emitted[draft_index]) continue;
            if (!draftInScope(draft, diff, opts)) continue;
            const resolution = draftResolution(draft, opts);
            switch (resolution) {
                .unavailable => try w.emitDraftSnapshot(draft_index),
                .resolved => {},
            }
        }
    }

    // 3. A reply Draft shares its parent's visibility: when the parent thread is
    // hidden (resolved, toggle off), the reply hides with it — so an un-emitted
    // reply is deliberately left out here. A *root* Draft has no parent to hide
    // behind, so an anchored one whose line isn't currently visible is surfaced
    // in a trailing pending section (with its own reply subtree) rather than lost.
    var stranded: usize = 0;
    for (opts.drafts, 0..) |*d, i| {
        if (!emitted[i] and d.parent == null and draftInScope(d, diff, opts)) stranded += 1;
    }
    if (stranded > 0) {
        try rows.append(allocator, .{ .section = .{ .kind = .pending, .count = stranded } });
        for (opts.drafts, 0..) |*d, i| {
            if (!emitted[i] and d.parent == null and draftInScope(d, diff, opts)) try w.emitDraft(i);
        }
    }

    return .{ .rows = try rows.toOwnedSlice(allocator), .layout = layout, .file_tallies = try fileTallies(allocator, diff, threads, opts.drafts, opts) };
}

fn contentStatus(statuses: []const model.FileContent, file_index: usize) model.FileContent {
    if (file_index >= statuses.len) return .{};
    return statuses[file_index];
}

fn unavailableOrBinary(status: ?model.FileContentStatus) ?model.FileContentStatus {
    const value = status orelse return null;
    return switch (value) {
        .binary, .unavailable => value,
        .text => null,
    };
}

fn emitStatusPlaceholders(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    layout: Layout,
    file: *const model.File,
    content: model.FileContent,
) !void {
    const old = unavailableOrBinary(content.old);
    const new = unavailableOrBinary(content.new);
    switch (layout) {
        .unified => {
            if (old) |status| try rows.append(allocator, .{ .status_placeholder = .{ .file = file, .old = status } });
            if (new) |status| try rows.append(allocator, .{ .status_placeholder = .{ .file = file, .new = status } });
        },
        .side_by_side => if (old != null or new != null)
            try rows.append(allocator, .{ .status_placeholder = .{ .file = file, .old = old, .new = new } }),
    }
}

/// Mutable weaving context shared by the emit helpers: the row sink plus the
/// threads/Drafts being placed and a per-Draft `emitted` guard. Reply Drafts are
/// placed relative to their parent, so the guard keeps each Draft to a single
/// row; root Drafts are placed by anchor.
const Weave = struct {
    a: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    threads: []const Thread,
    drafts: []const Draft,
    /// Index-aligned with `drafts`; set once the Draft has been placed.
    emitted: []bool,
    emitted_threads: []bool,
    opts: BuildOptions,

    /// Append a thread's rows: root, then any pending reply-Drafts to the root,
    /// then each published reply followed by its own pending reply-Drafts.
    fn emitThread(w: *Weave, t: *const Thread) !void {
        if (t.resolved) {
            const key: DisclosureKey = .{ .resolved_thread = t.root.id };
            const expanded = disclosureExpanded(w.opts.expanded_disclosures, key);
            try w.rows.append(w.a, .{ .disclosure = .{ .key = key, .kind = .resolved_thread, .expanded = expanded, .count = t.replies.len } });
            if (!expanded) return;
        }
        try w.emitThreadContent(t);
    }

    fn emitThreadContent(w: *Weave, t: *const Thread) !void {
        const index = (@intFromPtr(t) - @intFromPtr(w.threads.ptr)) / @sizeOf(Thread);
        if (w.emitted_threads[index]) return;
        w.emitted_threads[index] = true;
        try w.emitComment(t.root, false);
        try w.emitRepliesTo(.{ .comment = t.root.id });
        for (t.replies) |reply| {
            try w.emitComment(reply, true);
            try w.emitRepliesTo(.{ .comment = reply.id });
        }
    }

    /// Parse authored bytes into a width-independent ReviewBody and project the
    /// shared ReviewCardRow shape used by root Comments, Replies, and Drafts.
    fn emitComment(w: *Weave, c: *const Comment, is_reply: bool) !void {
        const owner: review_card.Owner = .{ .comment = c.id };
        const marker = if (c.suggestion() != null) "±" else if (is_reply) "↳" else "▸";
        const header = if (c.deleted)
            try std.fmt.allocPrint(w.a, "{s} Deleted Comment", .{marker})
        else
            try std.fmt.allocPrint(w.a, "{s} {s}", .{ marker, c.author });
        const parsed = try review_card.ReviewBody.parse(w.a, c.body);
        const projected = try review_card.project(w.a, parsed, .{
            .owner = owner,
            .source = .{ .comment = c },
            .role = if (c.deleted)
                (if (is_reply) .deleted_reply else .deleted_comment)
            else if (is_reply)
                .comment_reply
            else
                .comment,
            .header = header,
            .content_width = cardContentWidth(w.opts.card_width, is_reply),
            .metrics = w.opts.cell_metrics,
            .collapsed_rows = w.opts.collapsed_rows,
            .expanded = disclosureExpanded(w.opts.expanded_disclosures, .{ .review_card = owner }),
        });
        for (projected) |row| try w.rows.append(w.a, .{ .comment = row });
    }

    /// Append one Draft row (marking it emitted), then cascade its own pending
    /// reply-Drafts right after it, so a reply chain nests under its root.
    fn emitDraft(w: *Weave, i: usize) std.mem.Allocator.Error!void {
        if (w.emitted[i]) return;
        w.emitted[i] = true;
        const d = &w.drafts[i];
        // A posted/submitting Draft is represented by the server Comment once the
        // post-submit re-fetch lands; hide its own row so it doesn't double up
        // with that Comment (the transient reconciliation window, ADR-0007). Its
        // pending descendants are still placed, so a failed reply under a posted
        // parent stays visible for a selective retry.
        const published = switch (d.state) {
            .posted, .submitting => true,
            else => false,
        };
        if (!published) {
            const is_reply = d.parent != null;
            const owner: review_card.Owner = .{ .draft = d.local_id };
            const marker: []const u8 = if (d.kind == .suggestion) "±" else if (is_reply) "↳" else "✎";
            const label = if (d.state == .outcome_unknown) "outcome unknown" else "draft";
            const header = try std.fmt.allocPrint(w.a, "{s} {s}", .{ marker, label });
            const parsed = try review_card.ReviewBody.parse(w.a, d.body);
            const role: review_card.CardRole = if (d.state == .outcome_unknown)
                (if (is_reply) .outcome_unknown_reply else .outcome_unknown)
            else if (is_reply)
                .draft_reply
            else
                .draft;
            const projected = try review_card.project(w.a, parsed, .{
                .owner = owner,
                .source = .{ .draft = d },
                .role = role,
                .header = header,
                .content_width = cardContentWidth(w.opts.card_width, is_reply),
                .metrics = w.opts.cell_metrics,
                .collapsed_rows = w.opts.collapsed_rows,
                .expanded = disclosureExpanded(w.opts.expanded_disclosures, .{ .review_card = owner }),
            });
            for (projected) |row| try w.rows.append(w.a, .{ .draft = row });
        }
        try w.emitRepliesTo(.{ .draft = d.local_id });
    }

    fn emitDraftSnapshot(w: *Weave, i: usize) std.mem.Allocator.Error!void {
        const draft = &w.drafts[i];
        if (draft.snapshot) |snapshot| {
            var lines = std.mem.splitScalar(u8, snapshot.text, '\n');
            var line_index: u32 = 0;
            while (lines.next()) |line| : (line_index += 1) {
                try w.rows.append(w.a, .{ .snapshot = .{
                    .draft = draft,
                    .line = line,
                    .selected = line_index >= snapshot.selection_start and line_index < snapshot.selection_start +| snapshot.selection_len,
                } });
            }
        }
        try w.emitDraft(i);
    }

    /// Emit every not-yet-placed reply Draft whose parent is `parent`, recursively
    /// (so a reply-to-a-reply-Draft nests correctly). The `emitted` guard bounds
    /// the recursion even if the parent graph contains a cycle.
    fn emitRepliesTo(w: *Weave, parent: Parent) std.mem.Allocator.Error!void {
        for (w.drafts, 0..) |*d, i| {
            if (w.emitted[i]) continue;
            const p = d.parent orelse continue;
            if (parentEql(p, parent)) try w.emitDraft(i);
        }
    }

    /// Emit a hunk's lines in unified layout: one row per line, each followed by
    /// any inline threads and root Drafts anchored to it.
    fn emitUnifiedHunk(
        w: *Weave,
        file_idx: usize,
        file: *const model.File,
        lines: []const model.Line,
        emphasis: []const []const Segment,
        folds: []const Fold,
    ) !void {
        var i: usize = 0;
        while (i < lines.len) {
            if (foldStartingAt(folds, &lines[i])) |f| {
                const key: DisclosureKey = .{ .fold = f.id };
                const expanded = disclosureExpanded(w.opts.expanded_disclosures, key);
                try w.rows.append(w.a, .{ .disclosure = .{ .key = key, .kind = .fold, .expanded = expanded, .count = f.lines.len } });
                if (!expanded) {
                    i += f.lines.len;
                    continue;
                }
            }
            try w.rows.append(w.a, .{ .line = try decoratedLine(w.a, &lines[i], lineSpans(w.opts.highlights, file_idx, lines[i]), emphasis[i]) });
            try w.weaveInline(file, &lines[i]);
            i += 1;
        }
    }

    /// Emit a hunk's lines in side-by-side layout: old on the left, new on the
    /// right, modified pairs aligned on one row. Inline threads are woven after
    /// the pair that carries their anchored line (once per underlying line, so a
    /// context line — present on both sides — doesn't double-emit).
    fn emitSideBySideHunk(
        w: *Weave,
        file_idx: usize,
        file: *const model.File,
        lines: []const model.Line,
        folds: []const Fold,
    ) !void {
        var i: usize = 0;
        while (i < lines.len) {
            if (foldStartingAt(folds, &lines[i])) |f| {
                const key: DisclosureKey = .{ .fold = f.id };
                const expanded = disclosureExpanded(w.opts.expanded_disclosures, key);
                try w.rows.append(w.a, .{ .disclosure = .{ .key = key, .kind = .fold, .expanded = expanded, .count = f.lines.len } });
                if (!expanded) {
                    i += f.lines.len;
                    continue;
                }
            }
            switch (lines[i].kind) {
                .context => {
                    const line = try decoratedLine(w.a, &lines[i], lineSpans(w.opts.highlights, file_idx, lines[i]), &.{});
                    const pair: LinePair = if (lines[i].new_no == null)
                        .{ .left = line }
                    else if (lines[i].old_no == null)
                        .{ .right = line }
                    else
                        .{ .left = line, .right = line };
                    try w.rows.append(w.a, .{ .line_pair = pair });
                    try w.weaveInline(file, &lines[i]);
                    i += 1;
                },
                .added => {
                    // An added run with no preceding removed: right side only.
                    const start = i;
                    while (i < lines.len and lines[i].kind == .added) i += 1;
                    var p = start;
                    while (p < i) : (p += 1) {
                        try w.rows.append(w.a, .{ .line_pair = .{ .right = try decoratedLine(w.a, &lines[p], lineSpans(w.opts.highlights, file_idx, lines[p]), &.{}) } });
                        try w.weaveInline(file, &lines[p]);
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
                    try w.emitSideBySideChangeBlock(file_idx, file, lines[rem_start..rem_end], lines[add_start..add_end]);
                },
            }
        }
    }

    fn emitSideBySideChangeBlock(
        w: *Weave,
        file_idx: usize,
        file: *const model.File,
        removed: []const model.Line,
        added: []const model.Line,
    ) !void {
        const stride = added.len + 1;
        const similarities = try w.a.alloc(f64, removed.len * added.len);
        for (removed, 0..) |old, old_index| {
            for (added, 0..) |new, new_index| {
                similarities[old_index * added.len + new_index] = try intraline.matchingSimilarity(std.heap.page_allocator, old.text, new.text);
            }
        }

        const cells = try w.a.alloc(MatchCell, (removed.len + 1) * stride);
        var old_cursor = removed.len + 1;
        while (old_cursor > 0) {
            old_cursor -= 1;
            var new_cursor = added.len + 1;
            while (new_cursor > 0) {
                new_cursor -= 1;
                if (old_cursor == removed.len and new_cursor == added.len) {
                    cells[old_cursor * stride + new_cursor] = .{ .cost = 0, .exact_pairs = 0, .operation = .done };
                    continue;
                }

                var best: ?MatchCell = null;
                if (old_cursor < removed.len and new_cursor < added.len) {
                    const score = similarities[old_cursor * added.len + new_cursor];
                    if (score >= emphasis_threshold) {
                        const next = cells[(old_cursor + 1) * stride + new_cursor + 1];
                        chooseMatch(&best, .{
                            .cost = next.cost + 1.0 - score,
                            .exact_pairs = next.exact_pairs + @intFromBool(std.mem.eql(u8, removed[old_cursor].text, added[new_cursor].text)),
                            .first_old = old_cursor,
                            .first_new = new_cursor,
                            .operation = .pair,
                        });
                    }
                }
                if (old_cursor < removed.len) {
                    const next = cells[(old_cursor + 1) * stride + new_cursor];
                    chooseMatch(&best, .{
                        .cost = next.cost + 1.0,
                        .exact_pairs = next.exact_pairs,
                        .first_old = next.first_old,
                        .first_new = next.first_new,
                        .operation = .left,
                    });
                }
                if (new_cursor < added.len) {
                    const next = cells[old_cursor * stride + new_cursor + 1];
                    chooseMatch(&best, .{
                        .cost = next.cost + 1.0,
                        .exact_pairs = next.exact_pairs,
                        .first_old = next.first_old,
                        .first_new = next.first_new,
                        .operation = .right,
                    });
                }
                cells[old_cursor * stride + new_cursor] = best.?;
            }
        }

        old_cursor = 0;
        var new_cursor: usize = 0;
        while (old_cursor < removed.len or new_cursor < added.len) {
            switch (cells[old_cursor * stride + new_cursor].operation) {
                .pair => {
                    const pair = try intraline.diff(w.a, removed[old_cursor].text, added[new_cursor].text);
                    const left = try decoratedLine(w.a, &removed[old_cursor], lineSpans(w.opts.highlights, file_idx, removed[old_cursor]), pair.old);
                    const right = try decoratedLine(w.a, &added[new_cursor], lineSpans(w.opts.highlights, file_idx, added[new_cursor]), pair.new);
                    try w.rows.append(w.a, .{ .line_pair = .{ .left = left, .right = right } });
                    try w.weaveInline(file, right.line);
                    try w.weaveInline(file, left.line);
                    old_cursor += 1;
                    new_cursor += 1;
                },
                .right => {
                    const right = try decoratedLine(w.a, &added[new_cursor], lineSpans(w.opts.highlights, file_idx, added[new_cursor]), &.{});
                    try w.rows.append(w.a, .{ .line_pair = .{ .right = right } });
                    try w.weaveInline(file, right.line);
                    new_cursor += 1;
                },
                .left => {
                    const left = try decoratedLine(w.a, &removed[old_cursor], lineSpans(w.opts.highlights, file_idx, removed[old_cursor]), &.{});
                    try w.rows.append(w.a, .{ .line_pair = .{ .left = left } });
                    try w.weaveInline(file, left.line);
                    old_cursor += 1;
                },
                .done => unreachable,
            }
        }
    }

    /// Append any current/moved inline threads anchored to `ln` in `file`
    /// (respecting the resolved toggle), then any root Drafts anchored there.
    /// Outdated threads are grouped separately; reply Drafts follow their parent.
    fn weaveInline(w: *Weave, file: *const model.File, ln: *const model.Line) !void {
        // Blob-synthesized context lines (whole-file gaps) carry no diff anchor —
        // only Hunk lines bind comments/Drafts (M9 anchor safety).
        if (!ln.in_hunk) return;
        for (w.threads) |*t| {
            const anc = t.anchor() orelse continue;
            if (t.root.state == .outdated) continue; // grouped below
            if (!anchorMatchesFile(anc, file.*)) continue;
            if (anchorMatchesLine(anc, ln)) try w.emitThread(t);
        }
        // Root anchored Drafts hang off the same line, after any published
        // thread. Reply Drafts are placed under their parent, not by anchor.
        for (w.drafts, 0..) |*d, i| {
            if (d.parent != null) continue;
            const anc = projectedDraftAnchor(d, w.opts) orelse continue;
            if (!anchorMatchesFile(anc, file.*)) continue;
            if (anchorMatchesLine(anc, ln)) try w.emitDraft(i);
        }
    }
};

fn cardContentWidth(width: usize, is_reply: bool) usize {
    const indent: usize = if (is_reply) 8 else 4;
    return @max(width -| indent, 1);
}

/// True when two `Parent` references name the same target.
fn parentEql(a: Parent, b: Parent) bool {
    return switch (a) {
        .draft => |x| b == .draft and b.draft == x,
        .comment => |x| b == .comment and b.comment == x,
    };
}

fn decoratedLine(allocator: std.mem.Allocator, line: *const model.Line, spans: []const decoration.Span, emphasis: []const Segment) decoration.Error!LineRow {
    const decorated = decoration.decorate(allocator, line.text, spans, emphasis) catch |err| switch (err) {
        // Bitbucket's diff is authoritative and can differ slightly from the
        // fetched blob used for highlighting (for example around normalized
        // whitespace). Keep that one line plain instead of rejecting the whole
        // Buffer and losing highlighting for every subsequent File.
        error.InvalidSpan => try decoration.decorate(allocator, line.text, &.{}, emphasis),
        error.InvalidEmphasis => return error.InvalidEmphasis,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .line = line, .decoration = decorated };
}

/// Select the agreed file side, then return only the ordered Spans for `line`.
fn lineSpans(highlights: []const bbr.highlight.highlighter.FileHighlights, file_idx: usize, line: model.Line) []const decoration.Span {
    if (file_idx >= highlights.len) return &.{};
    const file = highlights[file_idx];
    const selected = switch (line.kind) {
        .removed => file.old,
        .added => file.new,
        .context => file.new orelse file.old,
    } orelse return &.{};
    const number = switch (line.kind) {
        .removed => line.old_no,
        .added => line.new_no,
        .context => if (file.new != null) line.new_no else line.old_no,
    } orelse return &.{};

    var first: usize = 0;
    while (first < selected.spans.len and selected.spans[first].line < number) first += 1;
    var end = first;
    while (end < selected.spans.len and selected.spans[end].line == number) end += 1;
    return selected.spans[first..end];
}

const WholeFileContent = struct {
    side: enum { old, new },
    blob: []const u8,
};

/// Select old content for a removed File and new content for every other File.
fn wholeFileContent(blobs: []const model.FileBlob, fi: usize, file: model.File) ?WholeFileContent {
    if (fi >= blobs.len) return null;
    if (file.status == .removed) return .{ .side = .old, .blob = blobs[fi].old orelse return null };
    return .{ .side = .new, .blob = blobs[fi].new orelse return null };
}

/// Splice a removed File from its old content. RawDiff old line numbers decide
/// every gap boundary, and Hunk Lines enter the result without modification.
fn spliceOldSide(allocator: std.mem.Allocator, file: model.File, blob: []const u8) ![]const model.Line {
    var lines = try splitBlobLines(allocator, blob);
    defer lines.deinit(allocator);

    var out: std.ArrayList(model.Line) = .empty;
    var old_cursor: u32 = 1;

    for (file.hunks) |hunk| {
        while (old_cursor < hunk.old_start) : (old_cursor += 1) {
            const text = blobLine(lines.items, old_cursor) orelse break;
            try out.append(allocator, .{
                .old_no = old_cursor,
                .new_no = null,
                .kind = .context,
                .text = text,
                .in_hunk = false,
            });
        }
        try out.appendSlice(allocator, hunk.lines);
        old_cursor = hunk.old_start + hunk.old_count;
    }

    while (blobLine(lines.items, old_cursor)) |text| : (old_cursor += 1) {
        try out.append(allocator, .{
            .old_no = old_cursor,
            .new_no = null,
            .kind = .context,
            .text = text,
            .in_hunk = false,
        });
    }

    return out.toOwnedSlice(allocator);
}

/// Splice a file's fetched Hunk lines into the unchanged lines of its new-side
/// `blob`, producing the whole file as one `Line` sequence. Gaps before, between,
/// and after the hunks are filled with `.context` lines drawn from the blob and
/// flagged `in_hunk = false` (so they never anchor). Hunk lines are copied
/// verbatim (keeping their kind, numbers, and `in_hunk = true`), and Bitbucket's
/// hunk line numbers stay authoritative (ADR-0001): the gaps are computed from
/// them, never the other way round. A blob shorter than the hunks expect just
/// yields fewer gap lines — it degrades, it never misplaces a Hunk line.
fn spliceNewSide(allocator: std.mem.Allocator, file: model.File, blob: []const u8) ![]const model.Line {
    var lines = try splitBlobLines(allocator, blob);
    defer lines.deinit(allocator);

    var out: std.ArrayList(model.Line) = .empty;
    // `new_cursor` is the next new-file line number (1-based) not yet emitted;
    // `old_off` maps an unchanged new line to its old number: old = new + old_off.
    var new_cursor: u32 = 1;
    var old_off: i64 = 0;

    for (file.hunks) |hunk| {
        // Gap: blob lines from the cursor up to (but not including) the hunk.
        while (new_cursor < hunk.new_start) : (new_cursor += 1) {
            const text = blobLine(lines.items, new_cursor) orelse break;
            try out.append(allocator, .{
                .old_no = offsetOldNo(new_cursor, old_off),
                .new_no = new_cursor,
                .kind = .context,
                .text = text,
                .in_hunk = false,
            });
        }
        // The hunk's own lines, verbatim (removed lines included).
        try out.appendSlice(allocator, hunk.lines);
        // Advance past the hunk's new-side span and fold its net line delta in.
        new_cursor = hunk.new_start + hunk.new_count;
        old_off -= @as(i64, hunk.new_count) - @as(i64, hunk.old_count);
    }

    // Trailing gap after the last hunk.
    while (blobLine(lines.items, new_cursor)) |text| : (new_cursor += 1) {
        try out.append(allocator, .{
            .old_no = offsetOldNo(new_cursor, old_off),
            .new_no = new_cursor,
            .kind = .context,
            .text = text,
            .in_hunk = false,
        });
    }

    return out.toOwnedSlice(allocator);
}

/// Drop a single trailing newline so a body ending in `\n` doesn't emit a
/// spurious blank last row; interior blank lines are preserved.
fn trimTrailingNewline(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\n') s[0 .. s.len - 1] else s;
}

/// old_no for an unchanged new line, clamped to a non-negative u32 (a mismatched
/// blob could in theory drive it negative; a wrong gutter number beats a crash).
fn offsetOldNo(new_no: u32, old_off: i64) ?u32 {
    const v = @as(i64, new_no) + old_off;
    return if (v < 1) null else @intCast(v);
}

/// The 1-based `n`th line of a blob already split into lines, or null if out of
/// range (so gap loops stop cleanly at end-of-file).
fn blobLine(lines: []const []const u8, n: u32) ?[]const u8 {
    if (n == 0 or n > lines.len) return null;
    return lines[n - 1];
}

/// Split a blob into its lines, borrowing slices of `blob` (zero-copy). A single
/// trailing newline is not treated as an extra empty line, matching how editors
/// count lines; interior blank lines are preserved.
fn splitBlobLines(allocator: std.mem.Allocator, blob: []const u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    if (blob.len == 0) return lines;
    const body = if (blob.len > 0 and blob[blob.len - 1] == '\n') blob[0 .. blob.len - 1] else blob;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines;
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
    return t.scope() == .review;
}

fn isFileOutdated(t: Thread, file: model.File) bool {
    if (t.root.state != .outdated) return false;
    return scopeMatchesFile(t.scope(), file);
}

fn threadCurrentInFile(t: Thread, file: model.File) bool {
    return t.root.state != .outdated and t.scope() == .file and scopeMatchesFile(t.scope(), file);
}

fn fileOutdatedCount(threads: []const Thread, file: model.File) usize {
    var n: usize = 0;
    for (threads) |*t| {
        if (isFileOutdated(t.*, file)) n += 1;
    }
    return n;
}

fn projectedDraftAnchor(draft: *const Draft, opts: BuildOptions) ?review.Anchor {
    return switch (draftResolution(draft, opts)) {
        .unavailable => null,
        .resolved => |resolved| if (resolved.state == .outdated) null else switch (resolved.scope) {
            .@"inline" => |anchor| anchor,
            else => null,
        },
    };
}

fn draftOutdatedInFile(draft: *const Draft, opts: BuildOptions, file: model.File) bool {
    return switch (draftResolution(draft, opts)) {
        .unavailable => false,
        .resolved => |resolved| resolved.state == .outdated and scopeMatchesFile(resolved.scope, file),
    };
}

fn draftOutdatedCount(drafts: []const Draft, opts: BuildOptions, file: model.File) usize {
    var count: usize = 0;
    for (drafts) |*draft| {
        if (draft.parent == null and draftOutdatedInFile(draft, opts, file)) count += 1;
    }
    return count;
}

fn anchorMatchesFile(anchor: review.Anchor, file: model.File) bool {
    return if (anchor.to != null)
        std.mem.eql(u8, anchor.path, file.new_path)
    else
        std.mem.eql(u8, anchor.path, file.old_path);
}

/// Whether a Draft belongs to the current file scope. In the all-files view
/// (`only_file == null`) every Draft is in scope; in the isolate view only a
/// Draft anchored to the focused file is — so a stranded PR-level or other-file
/// Draft never leaks into a single-file projection.
fn draftInScope(d: *const Draft, diff: model.Diff, opts: BuildOptions) bool {
    const only = opts.only_file orelse return true;
    if (only >= diff.files.len) return false;
    return switch (draftResolution(d, opts)) {
        .unavailable => false,
        .resolved => |resolved| scopeMatchesFile(resolved.scope, diff.files[only]),
    };
}

/// Root Drafts (not replies) with no anchor — the PR-level "Pending" section.
fn countPendingRoots(drafts: []const Draft) usize {
    var n: usize = 0;
    for (drafts) |*d| {
        if (d.parent == null and d.effectiveScope() == .review) n += 1;
    }
    return n;
}

fn draftScope(draft: *const Draft, opts: BuildOptions) review.CommentScope {
    return switch (draftResolution(draft, opts)) {
        .unavailable => draft.effectiveScope(),
        .resolved => |resolved| resolved.scope,
    };
}

fn draftResolution(draft: *const Draft, opts: BuildOptions) anchor_projection.ScopeResolution {
    if (anchor_projection.findScope(opts.scope_projections, draft.local_id)) |resolution| return resolution;
    if (anchor_projection.find(opts.anchor_projections, draft.local_id)) |legacy| return switch (legacy) {
        .unavailable => .unavailable,
        .resolved => |resolved| .{ .resolved = .{ .state = resolved.state, .scope = .{ .@"inline" = resolved.anchor } } },
    };
    return .{ .resolved = .{ .state = .current, .scope = draft.effectiveScope() } };
}

fn draftCurrentInFile(draft: *const Draft, opts: BuildOptions, file: model.File) bool {
    return switch (draftResolution(draft, opts)) {
        .unavailable => false,
        .resolved => |resolved| resolved.state != .outdated and resolved.scope == .file and scopeMatchesFile(resolved.scope, file),
    };
}

fn scopeMatchesFile(scope: review.CommentScope, file: model.File) bool {
    return switch (scope) {
        .review => false,
        .file => |value| std.mem.eql(u8, value.path, file.old_path) or std.mem.eql(u8, value.path, file.new_path),
        .@"inline" => |anchor| anchorMatchesFile(anchor, file),
    };
}

pub fn fileTallies(allocator: std.mem.Allocator, diff: model.Diff, threads: []const Thread, drafts: []const Draft, opts: BuildOptions) ![]const FileTally {
    const tallies = try allocator.alloc(FileTally, diff.files.len);
    @memset(tallies, .{});
    for (threads) |thread| for (diff.files, 0..) |file, index| {
        if (scopeMatchesFile(thread.scope(), file)) {
            tallies[index].comments += 1;
            break;
        }
    };
    for (drafts) |*draft| {
        if (draft.parent != null) continue;
        const resolution = draftResolution(draft, opts);
        const scope = switch (resolution) {
            .unavailable => continue,
            .resolved => |resolved| resolved.scope,
        };
        for (diff.files, 0..) |file, index| if (scopeMatchesFile(scope, file)) {
            tallies[index].drafts += 1;
            break;
        };
    }
    return tallies;
}

fn countWhere(threads: []const Thread, pred: fn (Thread) bool) usize {
    var n: usize = 0;
    for (threads) |*t| {
        if (pred(t.*)) n += 1;
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
const parse = bbr.diff.parse;

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
    try testing.expect(removed_edit.decoration.runs.len > 1);
    try testing.expect(added_edit.decoration.runs.len > 1);
    // The common prefix "let value = " is not emphasized; only "1"/"2" is.
    try testing.expect(!removed_edit.decoration.runs[0].emphasis);

    // The wholesale replacement shares nothing → treated as unrelated, no emphasis.
    try testing.expectEqual(@as(usize, 1), buf.rows[6].line.decoration.runs.len);
    try testing.expectEqual(@as(usize, 1), buf.rows[7].line.decoration.runs.len);
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
    try expectChangedLinesExactlyOnce(diff, buf);
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
    try testing.expect(mod.left.?.decoration.runs.len > 1);

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

test "side_by_side leaves an insertion before later related Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,3 @@
        \\-const host = config.host;
        \\-const port = config.port;
        \\+logger.info("starting");
        \\+const host = settings.host;
        \\+const port = settings.port;
        \\
    ;
    const diff = try parse(a, raw);
    const buf = try build(a, diff, .side_by_side);
    try expectChangedLinesExactlyOnce(diff, buf);

    const insertion = buf.rows[2].line_pair;
    try testing.expect(insertion.left == null);
    try testing.expectEqualStrings("logger.info(\"starting\");", insertion.right.?.line.text);
    try testing.expectEqualStrings("const host = config.host;", buf.rows[3].line_pair.left.?.line.text);
    try testing.expectEqualStrings("const host = settings.host;", buf.rows[3].line_pair.right.?.line.text);
    try testing.expectEqualStrings("const port = config.port;", buf.rows[4].line_pair.left.?.line.text);
    try testing.expectEqualStrings("const port = settings.port;", buf.rows[4].line_pair.right.?.line.text);
}

test "side_by_side leaves a deletion between related Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,2 @@
        \\-client.open(source);
        \\-client.retry(source);
        \\-client.close(source);
        \\+client.open(target);
        \\+client.close(target);
        \\
    ;
    const diff = try parse(a, raw);
    const buf = try build(a, diff, .side_by_side);
    try expectChangedLinesExactlyOnce(diff, buf);

    try testing.expectEqualStrings("client.open(target);", buf.rows[2].line_pair.right.?.line.text);
    try testing.expectEqualStrings("client.retry(source);", buf.rows[3].line_pair.left.?.line.text);
    try testing.expect(buf.rows[3].line_pair.right == null);
    try testing.expectEqualStrings("client.close(source);", buf.rows[4].line_pair.left.?.line.text);
    try testing.expectEqualStrings("client.close(target);", buf.rows[4].line_pair.right.?.line.text);
}

test "side_by_side leaves unrelated Lines unmatched and without IntraLineSegments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\-import legacy
        \\-legacy.boot()
        \\+const service = createService()
        \\+return service.run()
        \\
    ;
    const diff = try parse(a, raw);
    const buf = try build(a, diff, .side_by_side);
    try expectChangedLinesExactlyOnce(diff, buf);

    try testing.expectEqual(@as(usize, 6), buf.rows.len);
    try testing.expectEqualStrings("import legacy", buf.rows[2].line_pair.left.?.line.text);
    try testing.expect(buf.rows[2].line_pair.right == null);
    try testing.expectEqualStrings("legacy.boot()", buf.rows[3].line_pair.left.?.line.text);
    try testing.expect(buf.rows[4].line_pair.left == null);
    try testing.expectEqualStrings("const service = createService()", buf.rows[4].line_pair.right.?.line.text);
    for (buf.rows[2..]) |row| {
        const line = row.line_pair.left orelse row.line_pair.right.?;
        try testing.expectEqual(@as(usize, 1), line.decoration.runs.len);
    }
}

test "side_by_side matches the earliest repeated Line and rebuilds stably" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,2 @@
        \\-same
        \\-
        \\-same
        \\+same
        \\+
        \\
    ;
    const diff = try parse(a, raw);
    const first = try build(a, diff, .side_by_side);
    const second = try build(a, diff, .side_by_side);
    try expectChangedLinesExactlyOnce(diff, first);

    try testing.expectEqual(&diff.files[0].hunks[0].lines[0], first.rows[2].line_pair.left.?.line);
    try testing.expectEqual(&diff.files[0].hunks[0].lines[3], first.rows[2].line_pair.right.?.line);
    for (first.rows[2..], second.rows[2..]) |first_row, second_row| {
        try testing.expectEqual(if (first_row.line_pair.left) |line| line.line else null, if (second_row.line_pair.left) |line| line.line else null);
        try testing.expectEqual(if (first_row.line_pair.right) |line| line.line else null, if (second_row.line_pair.right) |line| line.line else null);
    }
}

test "side_by_side pairs identical Lines while Unified keeps Diff order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\-same
        \\-same
        \\+same
        \\+same
        \\
    ;
    const diff = try parse(a, raw);
    const side_by_side = try build(a, diff, .side_by_side);
    const unified = try build(a, diff, .unified);
    try expectChangedLinesExactlyOnce(diff, side_by_side);

    const lines = diff.files[0].hunks[0].lines;
    try testing.expectEqual(&lines[0], side_by_side.rows[2].line_pair.left.?.line);
    try testing.expectEqual(&lines[2], side_by_side.rows[2].line_pair.right.?.line);
    try testing.expectEqual(&lines[1], side_by_side.rows[3].line_pair.left.?.line);
    try testing.expectEqual(&lines[3], side_by_side.rows[3].line_pair.right.?.line);
    for (lines, unified.rows[2..]) |*line, row| try testing.expectEqual(line, row.line.line);
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
    const threads = try bbr.review.thread.build(a, &comments);
    const buf = try buildWithComments(a, diff, .side_by_side, threads, .{});

    // Exactly one comment row (not double-woven across the two panes).
    try testing.expectEqual(@as(usize, 1), countKind(buf, .comment));
}

test "side_by_side keeps old-side and new-side Comments and Drafts on their Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\-old comment
        \\-old draft
        \\+new comment
        \\+new draft
        \\
    ;
    const diff = try parse(a, raw);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "old", .anchor = .{ .path = "a.txt", .from = 1 } },
        .{ .id = 2, .author = "Bo", .body = "new", .anchor = .{ .path = "a.txt", .to = 1 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "old", .anchor = .{ .path = "a.txt", .from = 2, .commit = "base" } },
        .{ .local_id = 2, .kind = .comment, .body = "new", .anchor = .{ .path = "a.txt", .to = 2, .commit = "source" } },
    };
    const buf = try buildWithComments(a, diff, .side_by_side, threads, .{ .drafts = &drafts });

    var latest_pair: ?LinePair = null;
    for (buf.rows) |row| switch (row) {
        .line_pair => |pair| latest_pair = pair,
        .comment => |card| if (card.part == .header) {
            const expected: []const u8 = if (card.commentItem().id == 1) "old comment" else "new comment";
            const line = if (card.commentItem().id == 1) latest_pair.?.left.? else latest_pair.?.right.?;
            try testing.expectEqualStrings(expected, line.line.text);
        },
        .draft => |card| if (card.part == .header) {
            const expected: []const u8 = if (card.draftItem().local_id == 1) "old draft" else "new draft";
            const line = if (card.draftItem().local_id == 1) latest_pair.?.left.? else latest_pair.?.right.?;
            try testing.expectEqualStrings(expected, line.line.text);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), countKind(buf, .comment));
    try testing.expectEqual(@as(usize, 2), countKind(buf, .draft));
}

test "unavailable File sides project non-source Status Placeholders in every Layout and Scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const content_statuses = [_]model.FileContent{
        .{
            .old = .{ .unavailable = .{ .reason = .{ .acquisition_failed = error.NotFound } } },
            .new = .{ .text = 12 },
        },
    };

    for ([_]Layout{ .unified, .side_by_side }) |layout| {
        for ([_]bool{ false, true }) |whole_file| {
            const projected = try buildWithComments(a, diff, layout, &.{}, .{
                .whole_file = whole_file,
                .fold_context = !whole_file,
                .content_statuses = &content_statuses,
            });
            try testing.expectEqual(@as(usize, 1), countKind(projected, .status_placeholder));
            for (projected.rows) |row| if (row == .status_placeholder) {
                try testing.expect(row.status_placeholder.old != null);
                try testing.expect(row.status_placeholder.new == null);
            };
            try testing.expect(countKind(projected, if (layout == .unified) .line else .line_pair) > 0);
        }
    }
}

test "Status Placeholders do not hide Review-level or File-level Comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "review", .scope = .review },
        .{ .id = 2, .author = "Bo", .body = "file", .scope = .{ .file = .{ .path = "a.txt", .source_commit = "abc" } } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const content_statuses = [_]model.FileContent{.{
        .old = .{ .unavailable = .{ .reason = .{ .acquisition_failed = error.NotFound } } },
        .new = .{ .text = 12 },
    }};
    const projected = try buildWithComments(a, diff, .unified, threads, .{ .content_statuses = &content_statuses });

    try testing.expectEqual(@as(usize, 1), countKind(projected, .status_placeholder));
    try testing.expectEqual(@as(usize, 2), countKind(projected, .comment));
}

test "binary Files project independent sides in every Layout and Scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\diff --git a/modified.bin b/modified.bin
        \\GIT binary patch
        \\literal 4
        \\payload
        \\
        \\literal 3
        \\payload
        \\diff --git a/added.bin b/added.bin
        \\new file mode 100644
        \\Binary files /dev/null and b/added.bin differ
        \\diff --git a/removed.bin b/removed.bin
        \\deleted file mode 100644
        \\Binary files a/removed.bin and /dev/null differ
        \\diff --git a/old.bin b/new.bin
        \\rename from old.bin
        \\rename to new.bin
        \\Binary files a/old.bin and b/new.bin differ
    ;
    const diff = try parse(a, raw);
    const content_statuses = [_]model.FileContent{
        diff.files[0].content,
        diff.files[1].content,
        diff.files[2].content,
        diff.files[3].content,
    };
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "review", .scope = .review },
        .{ .id = 2, .author = "Bo", .body = "file", .scope = .{ .file = .{ .path = "modified.bin", .source_commit = "abc" } } },
    };
    const threads = try bbr.review.thread.build(a, &comments);

    for ([_]Layout{ .unified, .side_by_side }) |layout| {
        for ([_]bool{ false, true }) |whole_file| {
            const projected = try buildWithComments(a, diff, layout, threads, .{
                .whole_file = whole_file,
                .fold_context = !whole_file,
                .content_statuses = &content_statuses,
            });
            try testing.expectEqual(@as(usize, if (layout == .unified) 6 else 4), countKind(projected, .status_placeholder));
            try testing.expectEqual(@as(usize, 2), countKind(projected, .comment));
            try testing.expectEqual(@as(usize, 0), countKind(projected, .line));
            try testing.expectEqual(@as(usize, 0), countKind(projected, .line_pair));
            for (projected.rows) |row| if (row == .status_placeholder) {
                const placeholder = row.status_placeholder;
                switch (placeholder.file.status) {
                    .modified => {
                        if (placeholder.old) |old| try testing.expectEqual(@as(?usize, 3), old.binary);
                        if (placeholder.new) |new| try testing.expectEqual(@as(?usize, 4), new.binary);
                    },
                    .added => {
                        try testing.expect(placeholder.old == null);
                        try testing.expectEqual(@as(?usize, null), placeholder.new.?.binary);
                    },
                    .removed => {
                        try testing.expectEqual(@as(?usize, null), placeholder.old.?.binary);
                        try testing.expect(placeholder.new == null);
                    },
                    .renamed => {
                        if (placeholder.old) |old| try testing.expectEqual(@as(?usize, null), old.binary);
                        if (placeholder.new) |new| try testing.expectEqual(@as(?usize, null), new.binary);
                    },
                }
            };
        }
    }
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
        if (r != kind) continue;
        switch (r) {
            .comment => |card| if (card.part == .header) {
                n += 1;
            },
            .draft => |card| if (card.part == .header) {
                n += 1;
            },
            else => n += 1,
        }
    }
    return n;
}

fn expectChangedLinesExactlyOnce(diff: model.Diff, buf: Buffer) !void {
    for (diff.files) |file| for (file.hunks) |hunk| for (hunk.lines) |*line| {
        if (line.kind == .context) continue;
        var count: usize = 0;
        for (buf.rows) |row| if (row == .line_pair) {
            if (row.line_pair.left) |left| count += @intFromBool(left.line == line);
            if (row.line_pair.right) |right| count += @intFromBool(right.line == line);
        };
        try testing.expectEqual(@as(usize, 1), count);
    };
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
    try testing.expectEqual(@as(usize, 0), countKind(whole, .disclosure));

    // Changes scope: the 10-line context run keeps 3 lines each side and folds
    // the remaining 4 into a single fold row.
    const folded = try buildWithComments(a, diff, .unified, &.{}, .{ .fold_context = true });
    try testing.expectEqual(@as(usize, 1), countKind(folded, .disclosure));
    var fold_id: *const model.Line = undefined;
    for (folded.rows) |r| {
        if (r == .disclosure and r.disclosure.kind == .fold) {
            try testing.expectEqual(@as(usize, 4), r.disclosure.count);
            fold_id = r.disclosure.key.fold;
        }
    }

    // Expanding that fold (by id) reveals all lines, with no fold row left.
    const expanded = try buildWithComments(a, diff, .unified, &.{}, .{
        .fold_context = true,
        .expanded_disclosures = &.{.{ .fold = fold_id }},
    });
    try testing.expectEqual(@as(usize, 1), countKind(expanded, .disclosure));
    // The persistent disclosure remains and the four hidden lines appear below it.
    try testing.expectEqual(folded.rows.len + 4, expanded.rows.len);
}

test "a short context run is never folded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // anchor_diff has only one context line — nothing to fold.
    const diff = try parse(a, anchor_diff);
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .fold_context = true });
    try testing.expectEqual(@as(usize, 0), countKind(buf, .disclosure));
}

test "folds apply in the side-by-side layout too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, long_context_diff);
    const buf = try buildWithComments(a, diff, .side_by_side, &.{}, .{ .fold_context = true });
    try testing.expectEqual(@as(usize, 1), countKind(buf, .disclosure));
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
    const threads = try bbr.review.thread.build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});

    // Each ReviewCard has a header followed by its projected body.
    try testing.expectEqual(@as(usize, 9), buf.rows.len);
    try testing.expect(buf.rows[4] == .line);
    try testing.expectEqual(@as(?u32, 2), buf.rows[4].line.line.new_no);
    try testing.expect(buf.rows[5] == .comment);
    try testing.expect(!buf.rows[5].comment.isReply());
    try testing.expectEqual(@as(review.CommentId, 1), buf.rows[5].comment.commentItem().id);
    try testing.expect(buf.rows[7] == .comment);
    try testing.expect(buf.rows[7].comment.isReply());
}

test "Deleted Comment tombstone retains its real Thread and neutral role" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "", .deleted = true, .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "survives" },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});

    try testing.expectEqualStrings("▸ Deleted Comment", buf.rows[5].comment.text());
    try testing.expectEqual(review_card.CardRole.deleted_comment, buf.rows[5].comment.role);
    try testing.expectEqual(@as(review.CommentId, 1), buf.rows[5].comment.commentItem().id);
    try testing.expectEqual(review_card.CardRole.comment_reply, buf.rows[6].comment.role);
    try testing.expectEqual(@as(?review.CommentId, 1), buf.rows[6].comment.commentItem().parent_id);
}

test "PR-level comments get a section at the top" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "overall LGTM" }, // no anchor
    };
    const threads = try bbr.review.thread.build(a, &comments);
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
    const threads = try bbr.review.thread.build(a, &comments);

    // Hidden by default: no comment rows.
    const hidden = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 0), countKind(hidden, .comment));

    // Revealed: the whole thread (root + reply) appears.
    const shown = try buildWithComments(a, diff, .unified, threads, .{ .expanded_disclosures = &.{.{ .resolved_thread = 1 }} });
    try testing.expectEqual(@as(usize, 2), countKind(shown, .comment));
}

test "resolved Thread disclosure remains present while independently expanded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 41, .author = "Ada", .body = "first", .resolved = true, .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 42, .author = "Lin", .body = "second", .resolved = true, .anchor = .{ .path = "a.txt", .to = 2 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);

    const collapsed = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 2), countKind(collapsed, .disclosure));
    try testing.expectEqual(@as(usize, 0), countKind(collapsed, .comment));

    const expanded = try buildWithComments(a, diff, .unified, threads, .{
        .expanded_disclosures = &.{.{ .resolved_thread = 41 }},
    });
    try testing.expectEqual(@as(usize, 2), countKind(expanded, .disclosure));
    try testing.expectEqual(@as(usize, 1), countKind(expanded, .comment));
}

test "outdated threads remain represented by a per-File disclosure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        // Outdated AND resolved — still shown (outdated wins).
        .{ .id = 1, .author = "Ada", .body = "stale note", .resolved = true, .state = .outdated, .anchor = .{ .path = "a.txt", .from = 99 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);

    const buf = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 1), countKind(buf, .disclosure));
    var found = false;
    for (buf.rows) |r| {
        if (r == .disclosure and r.disclosure.kind == .outdated) {
            found = true;
            try testing.expectEqual(@as(usize, 1), r.disclosure.count);
            try testing.expectEqualStrings("a.txt", r.disclosure.path);
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 0), countKind(buf, .comment));
}

test "an outdated thread remains under a deleted File's old path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n" ++
        "--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n");
    const comments = [_]Comment{.{
        .id = 1,
        .author = "Ada",
        .body = "keep this history",
        .state = .outdated,
        .anchor = .{ .path = "gone.txt", .from = 1 },
    }};
    const threads = try bbr.review.thread.build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{ .expanded_disclosures = &.{.{ .outdated_file = &diff.files[0] }} });

    try testing.expectEqual(@as(usize, 1), countKind(buf, .comment));
    var found = false;
    for (buf.rows) |row| if (row == .disclosure and row.disclosure.kind == .outdated) {
        found = true;
        try testing.expectEqualStrings("gone.txt", row.disclosure.path);
    };
    try testing.expect(found);
}

test "an anchored draft is woven under its line; a PR-level draft gets a pending section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "overall: needs tests" }, // no anchor
        .{ .local_id = 2, .kind = .comment, .body = "why new?", .anchor = .{ .path = "a.txt", .to = 2, .commit = "c0" } },
    };
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });

    // A pending section at the very top, then the PR-level draft row.
    try testing.expect(buf.rows[0] == .section);
    try testing.expectEqual(SectionKind.pending, buf.rows[0].section.kind);
    try testing.expectEqual(@as(usize, 1), buf.rows[0].section.count);
    try testing.expect(buf.rows[1] == .draft);
    try testing.expectEqual(@as(u64, 1), buf.rows[1].draft.draftItem().local_id);

    // Exactly two draft rows total (one pending, one inline), and the inline one
    // sits right after the "+new" line (new_no == 2).
    try testing.expectEqual(@as(usize, 2), countKind(buf, .draft));
    for (buf.rows, 0..) |r, i| {
        if (r == .draft and r.draft.draftItem().local_id == 2 and r.draft.part == .header) {
            try testing.expect(buf.rows[i - 1] == .line);
            try testing.expectEqual(@as(?u32, 2), buf.rows[i - 1].line.line.new_no);
        }
    }
}

test "a reply draft whose parent is absent stays hidden (shares parent visibility)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{
        // Parent comment 5 isn't present, so the reply has nothing to nest under.
        // A reply is never surfaced as a root, so it stays hidden — it still
        // persists and submits, but it doesn't float free in the diff.
        .{ .local_id = 1, .kind = .comment, .body = "re", .parent = .{ .comment = 5 } },
    };
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });
    try testing.expectEqual(@as(usize, 0), countKind(buf, .draft));
}

test "a reply draft to a resolved thread hides and reveals with its parent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "nit", .resolved = true, .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "fixed" },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "actually, reopen", .parent = .{ .comment = 1 } },
    };

    // Toggle off: the resolved thread is hidden, and so is the reply to it.
    const hidden = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts });
    try testing.expectEqual(@as(usize, 0), countKind(hidden, .draft));
    try testing.expectEqual(@as(usize, 0), countKind(hidden, .comment));

    // Toggle on: the whole thread reveals, with the reply draft nested under it.
    const shown = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts, .expanded_disclosures = &.{.{ .resolved_thread = 1 }} });
    try testing.expectEqual(@as(usize, 1), countKind(shown, .draft));
    for (shown.rows) |r| {
        if (r == .draft) try testing.expect(r.draft.isReply());
    }
}

test "a reply draft to a PR-level comment nests under it, not in the pending section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "overall looks good" }, // PR-level (no anchor)
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "one nit though", .parent = .{ .comment = 1 } },
    };
    const buf = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts });

    // Row 0: the PR-comments section. Row 1: the comment. Row 2: the reply draft,
    // sitting directly under the comment it answers — not in a pending section.
    try testing.expectEqual(SectionKind.pr_comments, buf.rows[0].section.kind);
    try testing.expect(buf.rows[1] == .comment and buf.rows[1].comment.commentItem().id == 1);
    try testing.expect(buf.rows[3] == .draft and buf.rows[3].draft.isReply());
    try testing.expectEqual(@as(usize, 1), countKind(buf, .draft));
    // No pending section was emitted for the reply.
    for (buf.rows) |r| {
        if (r == .section) try testing.expect(r.section.kind != .pending);
    }
}

test "a reply draft to an inline thread nests right after the thread" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 7, .author = "Ada", .body = "why?", .anchor = .{ .path = "a.txt", .to = 2 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "because X", .parent = .{ .comment = 7 } },
    };
    const buf = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts });

    // The reply draft immediately follows the published comment it answers.
    for (buf.rows, 0..) |r, i| {
        if (r == .comment and r.comment.commentItem().id == 7 and r.comment.part == .body) {
            try testing.expect(buf.rows[i + 1] == .draft);
            try testing.expect(buf.rows[i + 1].draft.isReply());
        }
    }
    // Placed inline, so no pending section at the top.
    try testing.expect(buf.rows[0] != .section or buf.rows[0].section.kind != .pending);
}

test "a reply-to-draft chain nests under its root draft" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "root", .anchor = .{ .path = "a.txt", .to = 2, .commit = "c0" } },
        .{ .local_id = 2, .kind = .comment, .body = "reply to my own draft", .parent = .{ .draft = 1 } },
    };
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });

    try testing.expectEqual(@as(usize, 2), countKind(buf, .draft));
    for (buf.rows, 0..) |r, i| {
        if (r == .draft and r.draft.draftItem().local_id == 1 and r.draft.part == .body) {
            try testing.expect(buf.rows[i + 1] == .draft);
            try testing.expectEqual(@as(u64, 2), buf.rows[i + 1].draft.draftItem().local_id);
            try testing.expect(buf.rows[i + 1].draft.isReply());
        }
    }
}

test "a posted draft's row is hidden but its pending reply is still placed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    // A partial batch: the root posted (now owned by the server after re-fetch),
    // its reply failed and stays pending for a selective retry.
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "root", .anchor = .{ .path = "a.txt", .to = 2, .commit = "c0" }, .state = .{ .posted = 999 } },
        .{ .local_id = 2, .kind = .comment, .body = "still pending", .parent = .{ .draft = 1 }, .state = .{ .failed = error.ServerError } },
    };
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .drafts = &drafts });

    // The posted root is hidden (the server Comment represents it); only the
    // pending reply renders as a draft row.
    try testing.expectEqual(@as(usize, 1), countKind(buf, .draft));
    for (buf.rows) |r| {
        if (r == .draft) try testing.expectEqual(@as(u64, 2), r.draft.draftItem().local_id);
    }
}

test "only_file projects a single file's rows, nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, two_file_diff);

    // Isolate the second file (b.txt): exactly one file_header, and it's b.txt.
    const only_b = try buildWithComments(a, diff, .unified, &.{}, .{ .only_file = 1 });
    try testing.expectEqual(@as(usize, 1), countKind(only_b, .file_header));
    for (only_b.rows) |r| {
        if (r == .file_header) try testing.expectEqualStrings("b.txt", r.file_header.new_path);
    }
    // b.txt alone: header + hunk header + 2 lines = 4 rows.
    try testing.expectEqual(@as(usize, 4), only_b.rows.len);

    // Isolating the first file yields a's rows and none of b's.
    const only_a = try buildWithComments(a, diff, .unified, &.{}, .{ .only_file = 0 });
    for (only_a.rows) |r| {
        if (r == .file_header) try testing.expectEqualStrings("a.txt", r.file_header.new_path);
    }
    try testing.expectEqual(@as(usize, 5), only_a.rows.len);
}

test "the isolate view suppresses PR-level and other-file rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, two_file_diff);
    // A PR-level comment, plus an inline comment on each file.
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "overall LGTM" }, // PR-level
        .{ .id = 2, .author = "Bo", .body = "on a", .anchor = .{ .path = "a.txt", .to = 1 } },
        .{ .id = 3, .author = "Cy", .body = "on b", .anchor = .{ .path = "b.txt", .to = 5 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    // A PR-level draft and one anchored to the other file.
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "needs tests" }, // PR-level
        .{ .local_id = 2, .kind = .comment, .body = "on b", .anchor = .{ .path = "b.txt", .to = 5, .commit = "c0" } },
    };

    // Isolate a.txt: no PR-level comment/pending sections, no b.txt comment/draft.
    const buf = try buildWithComments(a, diff, .unified, threads, .{ .only_file = 0, .drafts = &drafts });
    for (buf.rows) |r| {
        if (r == .section) try testing.expect(r.section.kind != .pr_comments and r.section.kind != .pending);
    }
    // Exactly the one inline comment that anchors to a.txt; b's comment is gone.
    try testing.expectEqual(@as(usize, 1), countKind(buf, .comment));
    for (buf.rows) |r| {
        if (r == .comment) try testing.expectEqual(@as(review.CommentId, 2), r.comment.commentItem().id);
    }
    // The PR-level draft and the b.txt draft are both suppressed.
    try testing.expectEqual(@as(usize, 0), countKind(buf, .draft));
}

// A one-file modification whose hunk covers only new lines 2-4; the full file
// is five lines. Line 1 ("a") and line 5 ("e") live only in the blob.
const whole_file_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -2,3 +2,3 @@
    \\ b
    \\-c
    \\+CHANGED
    \\ d
    \\
;
const whole_file_blob = "a\nb\nCHANGED\nd\ne\n";

const removed_whole_file_diff =
    \\diff --git a/gone.txt b/gone.txt
    \\deleted file mode 100644
    \\--- a/gone.txt
    \\+++ /dev/null
    \\@@ -2,2 +0,0 @@
    \\-b
    \\-c
    \\
;
const removed_whole_file_blob = "a\nb\nc\nd\n";

test "whole_file splices blob gaps around the hunk, hunk lines preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, whole_file_diff);
    const blobs = [_]model.FileBlob{.{ .new = whole_file_blob }};
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .whole_file = true, .blobs = &blobs });

    // Continuous file: a header and no hunk headers.
    try testing.expectEqual(@as(usize, 1), countKind(buf, .file_header));
    try testing.expectEqual(@as(usize, 0), countKind(buf, .hunk_header));

    // Rows: file_header, then 6 lines — a(gap) b c CHANGED d e(gap).
    try testing.expectEqual(@as(usize, 7), buf.rows.len);
    const first = buf.rows[1].line;
    try testing.expectEqualStrings("a", first.line.text);
    try testing.expectEqual(@as(?u32, 1), first.line.new_no);
    try testing.expect(!first.line.in_hunk); // blob-sourced gap line

    // The hunk's context "b" is a real Hunk line.
    try testing.expectEqualStrings("b", buf.rows[2].line.line.text);
    try testing.expect(buf.rows[2].line.line.in_hunk);

    // The change is present with its kinds.
    try testing.expectEqual(model.LineKind.removed, buf.rows[3].line.line.kind);
    try testing.expectEqual(model.LineKind.added, buf.rows[4].line.line.kind);

    // The trailing gap line "e" comes from the blob.
    const last = buf.rows[6].line;
    try testing.expectEqualStrings("e", last.line.text);
    try testing.expectEqual(@as(?u32, 5), last.line.new_no);
    try testing.expect(!last.line.in_hunk);
}

test "whole_file splices removed Files from old content without changing Hunk Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, removed_whole_file_diff);
    const blobs = [_]model.FileBlob{.{ .old = removed_whole_file_blob }};
    const comments = [_]Comment{.{ .id = 1, .author = "Ada", .body = "gap?", .anchor = .{ .path = "gone.txt", .from = 1 } }};
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{.{ .local_id = 1, .kind = .comment, .body = "gap draft", .anchor = .{ .path = "gone.txt", .from = 4, .commit = "base" } }};
    const buf = try buildWithComments(a, diff, .unified, threads, .{ .whole_file = true, .blobs = &blobs, .drafts = &drafts });

    try testing.expectEqual(@as(usize, 0), countKind(buf, .hunk_header));
    try testing.expectEqual(@as(usize, 4), countKind(buf, .line));
    try testing.expectEqualStrings("a", buf.rows[1].line.line.text);
    try testing.expectEqual(@as(?u32, 1), buf.rows[1].line.line.old_no);
    try testing.expect(!buf.rows[1].line.line.in_hunk);
    try testing.expectEqual(diff.files[0].hunks[0].lines[0], buf.rows[2].line.line.*);
    try testing.expectEqual(diff.files[0].hunks[0].lines[1], buf.rows[3].line.line.*);
    try testing.expectEqualStrings("d", buf.rows[4].line.line.text);
    try testing.expectEqual(@as(?u32, 4), buf.rows[4].line.line.old_no);
    try testing.expect(!buf.rows[4].line.line.in_hunk);
    try testing.expectEqual(@as(usize, 0), countKind(buf, .comment));
    try testing.expectEqual(SectionKind.pending, buf.rows[5].section.kind);
    try testing.expect(buf.rows[6] == .draft);

    const split = try buildWithComments(a, diff, .side_by_side, &.{}, .{ .whole_file = true, .blobs = &blobs });
    try testing.expect(split.rows[1].line_pair.left != null);
    try testing.expect(split.rows[1].line_pair.right == null);
    try testing.expect(split.rows[4].line_pair.left != null);
    try testing.expect(split.rows[4].line_pair.right == null);
}

test "whole_file with no blob falls back to the fetched per-hunk rendering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, whole_file_diff);
    // whole_file on, but no blobs loaded → per-hunk path (hunk header present).
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .whole_file = true });
    try testing.expectEqual(@as(usize, 1), countKind(buf, .hunk_header));
    // Only the fetched lines (b, c, CHANGED, d) — no blob gap lines.
    try testing.expectEqual(@as(usize, 4), countKind(buf, .line));
}

test "whole_file treats empty text content as a complete zero-Line File" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/empty.txt b/empty.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/empty.txt
        \\
    ;
    const diff = try parse(a, raw);
    const blobs = [_]model.FileBlob{.{ .new = "" }};
    const buf = try buildWithComments(a, diff, .unified, &.{}, .{ .whole_file = true, .blobs = &blobs });

    try testing.expectEqual(@as(usize, 1), countKind(buf, .file_header));
    try testing.expectEqual(@as(usize, 0), countKind(buf, .hunk_header));
    try testing.expectEqual(@as(usize, 0), countKind(buf, .line));
}

test "whole_file anchors bind only to hunk lines, never blob gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, whole_file_diff);
    const blobs = [_]model.FileBlob{.{ .new = whole_file_blob }};

    // A comment on new line 1 (a blob gap) must not attach; one on new line 3
    // (the added "CHANGED", a real Hunk line) must.
    const on_gap = [_]Comment{.{ .id = 1, .author = "Ada", .body = "gap?", .anchor = .{ .path = "a.txt", .to = 1 } }};
    const gap_threads = try bbr.review.thread.build(a, &on_gap);
    const gap_buf = try buildWithComments(a, diff, .unified, gap_threads, .{ .whole_file = true, .blobs = &blobs });
    try testing.expectEqual(@as(usize, 0), countKind(gap_buf, .comment));

    const on_hunk = [_]Comment{.{ .id = 1, .author = "Ada", .body = "here", .anchor = .{ .path = "a.txt", .to = 3 } }};
    const hunk_threads = try bbr.review.thread.build(a, &on_hunk);
    const hunk_buf = try buildWithComments(a, diff, .unified, hunk_threads, .{ .whole_file = true, .blobs = &blobs });
    try testing.expectEqual(@as(usize, 1), countKind(hunk_buf, .comment));
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
    const threads = try bbr.review.thread.build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});
    try testing.expectEqual(@as(usize, 0), countKind(buf, .comment));
}

test "a multi-line body emits one row per visual line, sharing one owner, is_first on the header only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    // A 3-line comment body and a 2-line pending Draft, both anchored on new line 2.
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "line one\nline two\nline three", .anchor = .{ .path = "a.txt", .to = 2 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "draft a\ndraft b", .anchor = .{ .path = "a.txt", .to = 2, .commit = "c0" } },
    };
    const buf = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts });

    // Three comment rows, all pointing at the same Comment; is_first only first.
    var comment_rows: usize = 0;
    var first_rows: usize = 0;
    for (buf.rows) |r| {
        if (r != .comment) continue;
        comment_rows += 1;
        try testing.expectEqual(&comments[0], r.comment.commentItem());
        if (r.comment.part == .header) {
            first_rows += 1;
            try testing.expectEqualStrings("▸ Ada", r.comment.text());
        }
    }
    try testing.expectEqual(@as(usize, 2), comment_rows);
    try testing.expectEqual(@as(usize, 1), first_rows);

    // Two draft rows for the 2-line body; only the header is_first.
    var draft_rows: usize = 0;
    var draft_first: usize = 0;
    for (buf.rows) |r| {
        if (r != .draft) continue;
        draft_rows += 1;
        if (r.draft.part == .header) {
            draft_first += 1;
            try testing.expectEqualStrings("✎ draft", r.draft.text());
        }
    }
    try testing.expectEqual(@as(usize, 2), draft_rows);
    try testing.expectEqual(@as(usize, 1), draft_first);
}

test "a trailing newline does not emit a spurious blank last row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, anchor_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "solo\n", .anchor = .{ .path = "a.txt", .to = 2 } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const buf = try buildWithComments(a, diff, .unified, threads, .{});
    // "solo\n" trims to one line, not two.
    try testing.expectEqual(@as(usize, 1), countKind(buf, .comment));
}

test "Line decoration selects old Spans for removed and new Spans for added and context Lines" {
    const old_spans = [_]decoration.Span{.{ .line = 4, .start = 0, .end = 3, .capture = .{ .name = "old.capture" } }};
    const new_spans = [_]decoration.Span{
        .{ .line = 7, .start = 0, .end = 3, .capture = .{ .name = "new.added" } },
        .{ .line = 8, .start = 0, .end = 3, .capture = .{ .name = "new.context" } },
    };
    const highlights = [_]bbr.highlight.highlighter.FileHighlights{.{
        .old = .{ .spans = &old_spans },
        .new = .{ .spans = &new_spans },
    }};

    const removed: model.Line = .{ .old_no = 4, .new_no = null, .kind = .removed, .text = "old" };
    const added: model.Line = .{ .old_no = null, .new_no = 7, .kind = .added, .text = "new" };
    const context: model.Line = .{ .old_no = 6, .new_no = 8, .kind = .context, .text = "ctx" };
    try testing.expectEqualStrings("old.capture", lineSpans(&highlights, 0, removed)[0].capture.name);
    try testing.expectEqualStrings("new.added", lineSpans(&highlights, 0, added)[0].capture.name);
    try testing.expectEqualStrings("new.context", lineSpans(&highlights, 0, context)[0].capture.name);
}

test "an incompatible blob Span leaves only that diff Line plain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const line: model.Line = .{ .old_no = null, .new_no = 52, .kind = .added, .text = "short" };
    const incompatible = [_]decoration.Span{.{
        .line = 52,
        .start = 5,
        .end = 6,
        .capture = .{ .name = "punctuation.bracket" },
    }};

    const row = try decoratedLine(arena.allocator(), &line, &incompatible, &.{});
    try testing.expectEqual(@as(usize, 1), row.decoration.runs.len);
    try testing.expect(row.decoration.runs[0].capture == null);
    try testing.expectEqualStrings("short", row.decoration.runs[0].text);
}

test "a moved local Draft is woven at its projected Anchor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{.{
        .local_id = 7,
        .kind = .comment,
        .target = .local,
        .body = "moved note",
        .anchor = .{ .path = "a.txt", .to = 2, .commit = "old" },
    }};
    const projections = [_]anchor_projection.ProjectionEntry{.{
        .temp_id = 7,
        .resolution = .{ .resolved = .{
            .state = .moved,
            .anchor = .{ .path = "a.txt", .to = 1, .commit = "old" },
        } },
    }};

    const buf = try buildWithComments(a, diff, .unified, &.{}, .{
        .drafts = &drafts,
        .anchor_projections = &projections,
    });
    for (buf.rows, 0..) |row, index| if (row == .draft and row.draft.part == .header) {
        try testing.expect(buf.rows[index - 1] == .line);
        try testing.expectEqual(@as(?u32, 1), buf.rows[index - 1].line.line.new_no);
    };
}

test "an outdated local Draft remains visible with its authored snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{.{
        .local_id = 8,
        .kind = .comment,
        .target = .local,
        .body = "stale note",
        .anchor = .{ .path = "a.txt", .to = 2, .commit = "old" },
        .snapshot = .{ .text = "keep\nold\nnew", .selection_start = 2, .selection_len = 1 },
    }};
    const projections = [_]anchor_projection.ProjectionEntry{.{
        .temp_id = 8,
        .resolution = .{ .resolved = .{
            .state = .outdated,
            .anchor = drafts[0].anchor.?,
        } },
    }};

    const buf = try buildWithComments(a, diff, .unified, &.{}, .{
        .drafts = &drafts,
        .anchor_projections = &projections,
        .expanded_disclosures = &.{.{ .outdated_file = &diff.files[0] }},
    });
    try testing.expectEqual(@as(usize, 3), countKind(buf, .snapshot));
    try testing.expectEqual(@as(usize, 1), countKind(buf, .draft));
    var saw_outdated = false;
    var saw_selected = false;
    for (buf.rows) |row| switch (row) {
        .disclosure => |disclosure| if (disclosure.kind == .outdated) {
            saw_outdated = true;
            try testing.expectEqualStrings("a.txt", disclosure.path);
        },
        .snapshot => |snapshot| if (snapshot.selected) {
            saw_selected = true;
            try testing.expectEqualStrings("new", snapshot.line);
        },
        else => {},
    };
    try testing.expect(saw_outdated and saw_selected);
}

test "a local Draft with unavailable Git evidence remains visible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, anchor_diff);
    const drafts = [_]Draft{.{
        .local_id = 9,
        .kind = .comment,
        .target = .local,
        .body = "cannot resolve",
        .anchor = .{ .path = "missing.txt", .to = 2, .commit = "missing" },
        .snapshot = .{ .text = "remembered", .selection_start = 0, .selection_len = 1 },
    }};
    const projections = [_]anchor_projection.ProjectionEntry{.{ .temp_id = 9, .resolution = .unavailable }};

    const buf = try buildWithComments(a, diff, .unified, &.{}, .{
        .drafts = &drafts,
        .anchor_projections = &projections,
    });
    try testing.expectEqual(@as(usize, 1), countKind(buf, .snapshot));
    try testing.expectEqual(@as(usize, 1), countKind(buf, .draft));
    var saw_unavailable = false;
    for (buf.rows) |row| {
        if (row == .section and row.section.kind == .unavailable) saw_unavailable = true;
    }
    try testing.expect(saw_unavailable);
}

test "single-file scope does not leak another File's outdated local Draft" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, two_file_diff);
    const drafts = [_]Draft{.{
        .local_id = 10,
        .kind = .comment,
        .target = .local,
        .body = "belongs to b",
        .anchor = .{ .path = "b.txt", .to = 5, .commit = "old" },
    }};
    const projections = [_]anchor_projection.ProjectionEntry{.{
        .temp_id = 10,
        .resolution = .{ .resolved = .{ .state = .outdated, .anchor = drafts[0].anchor.? } },
    }};

    const buf = try buildWithComments(a, diff, .unified, &.{}, .{
        .drafts = &drafts,
        .anchor_projections = &projections,
        .only_file = 0,
    });
    try testing.expectEqual(@as(usize, 0), countKind(buf, .draft));
    try testing.expectEqual(@as(usize, 0), countKind(buf, .section));
}

test "ScopeProjection places each root and Replies once and tallies roots per File" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, two_file_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "file root", .scope = .{ .file = .{ .path = "a.txt", .source_commit = "abc" } } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "file reply", .scope = null },
        .{ .id = 3, .author = "Cy", .body = "line root", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 1 } } },
    };
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{
        .{ .local_id = 10, .kind = .comment, .body = "file draft", .scope = .{ .file = .{ .path = "a.txt", .source_commit = "abc" } } },
        .{ .local_id = 11, .kind = .comment, .body = "draft reply", .parent = .{ .draft = 10 }, .scope = null },
    };

    for ([_]Layout{ .unified, .side_by_side }) |layout| {
        const buf = try buildWithComments(a, diff, layout, threads, .{ .drafts = &drafts, .only_file = 0 });
        try testing.expectEqual(@as(usize, 2), buf.file_tallies[0].comments);
        try testing.expectEqual(@as(usize, 1), buf.file_tallies[0].drafts);
        try testing.expectEqual(@as(usize, 0), buf.file_tallies[1].comments);
        try testing.expect(buf.rows[0] == .file_header);
        try testing.expect(buf.rows[1] == .comment and buf.rows[1].comment.commentItem().id == 1);
        try testing.expect(buf.rows[3] == .comment and buf.rows[3].comment.commentItem().id == 2);
        try testing.expect(buf.rows[5] == .draft and buf.rows[5].draft.draftItem().local_id == 10);
        try testing.expect(buf.rows[7] == .draft and buf.rows[7].draft.draftItem().local_id == 11);
        var roots: usize = 0;
        var replies: usize = 0;
        for (buf.rows) |row| switch (row) {
            .comment => |value| if (value.part == .header) {
                if (value.commentItem().id == 1 or value.commentItem().id == 3) roots += 1;
                if (value.commentItem().id == 2) replies += 1;
            },
            else => {},
        };
        try testing.expectEqual(@as(usize, 2), roots);
        try testing.expectEqual(@as(usize, 1), replies);
    }
}

test "scope fallbacks distinguish unmatched outdated from unavailable and do not leak into isolate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, two_file_diff);
    const comments = [_]Comment{.{
        .id = 20,
        .author = "Ada",
        .body = "removed file",
        .scope = .{ .file = .{ .path = "gone.txt", .source_commit = "old" } },
        .state = .outdated,
    }};
    const threads = try bbr.review.thread.build(a, &comments);
    const drafts = [_]Draft{.{
        .local_id = 21,
        .kind = .comment,
        .body = "no evidence",
        .scope = .{ .file = .{ .path = "unknown.txt", .source_commit = "missing" } },
    }};
    const projections = [_]anchor_projection.ScopeProjectionEntry{.{ .temp_id = 21, .resolution = .unavailable }};
    const all = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts, .scope_projections = &projections });
    var saw_outdated = false;
    var saw_unavailable = false;
    for (all.rows) |row| {
        if (row == .disclosure and row.disclosure.kind == .outdated) {
            if (row.disclosure.path.len == 0) saw_outdated = true;
        } else if (row == .section and row.section.kind == .unavailable) {
            saw_unavailable = true;
        }
    }
    try testing.expect(saw_outdated and saw_unavailable);
    try testing.expectEqual(@as(usize, 0), countKind(all, .comment));

    const isolated = try buildWithComments(a, diff, .unified, threads, .{ .drafts = &drafts, .scope_projections = &projections, .only_file = 0 });
    try testing.expectEqual(@as(usize, 0), countKind(isolated, .comment));
    try testing.expectEqual(@as(usize, 0), countKind(isolated, .draft));
}
