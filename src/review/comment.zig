//! The read-side comment model — the `src/review/CONTEXT.md` vocabulary as data.
//!
//! A `Comment` is one authored piece of prose on a PullRequest. It may be a root
//! comment or a Reply (`parent_id`), and it may be anchored to a diff line
//! (`anchor`) or float at PR level (`anchor == null`). For remote comments we
//! trust Bitbucket's own `AnchorState` verdict (ADR-0001); we never recompute it.
//!
//! Strings are owned by whatever allocator built the comment (the Bitbucket
//! adapter dupes them into the caller's PR-scoped arena). Pure — no network.

const std = @import("std");

/// Server-assigned comment identifier (unique within a PullRequest).
pub const CommentId = u64;

/// Where a Comment resolves against the currently-viewed diff. Remote comments
/// carry Bitbucket's verdict; `moved` is only ever computed locally (M6+), so a
/// parsed remote comment is `current` or `outdated`.
pub const ScopeState = enum { current, moved, outdated };
pub const AnchorState = ScopeState;

/// The diff location a Comment attaches to. `from`/`to` are the anchor line
/// itself: `from` is an old-file (left) line, `to` a new-file (right) line — a
/// single-sided comment sets exactly one. `start_from`/`start_to` are the *top*
/// of a multi-line range whose bottom is `from`/`to` on the same side (the shape
/// Bitbucket returns and accepts: `{start_to, to}` for a new-side range,
/// `{start_from, from}` for an old-side one). A single-line anchor leaves the
/// `start_*` fields null.
pub const Anchor = struct {
    path: []const u8,
    /// Old-file (left) line number, 1-based — the bottom of an old-side range.
    from: ?u32 = null,
    /// New-file (right) line number, 1-based — the bottom of a new-side range.
    to: ?u32 = null,
    /// Old-file (left) top line of a multi-line range; null for a single line.
    start_from: ?u32 = null,
    /// New-file (right) top line of a multi-line range; null for a single line.
    start_to: ?u32 = null,
    /// The source commit this anchor was authored against, or null for a remote
    /// comment (Bitbucket owns its verdict, ADR-0001). A local Draft records it
    /// so its AnchorState can be recomputed by diff-walking later (ADR-0005).
    commit: ?[]const u8 = null,

    /// The line this anchor renders against in the unified diff, preferring the
    /// new side (where an added/context comment lives) then the old side. For a
    /// range this is the bottom line (`from`/`to`), matching Bitbucket.
    pub fn line(self: Anchor) ?u32 {
        return self.to orelse self.from;
    }

    /// True when this anchor spans more than one line (a `start_*` is set).
    pub fn isRange(self: Anchor) bool {
        return self.start_to != null or self.start_from != null;
    }
};

/// Durable authored identity of a File-level root.
pub const FileScope = struct {
    path: []const u8,
    source_commit: []const u8,
};

/// Exhaustive scope carried by roots. Replies carry only `parent_id` and use
/// their Thread root's scope.
pub const CommentScope = union(enum) {
    review,
    file: FileScope,
    @"inline": Anchor,

    pub fn isReview(self: CommentScope) bool {
        return self == .review;
    }
    pub fn isFile(self: CommentScope) bool {
        return self == .file;
    }
    pub fn isInline(self: CommentScope) bool {
        return self == .@"inline";
    }
};

/// Immutable fallback evidence captured when a local root Draft is authored.
/// `text` contains the selected range plus up to three surrounding lines;
/// `selection_start` is the zero-based first selected line within that text.
pub const AnchorSnapshot = struct {
    text: []const u8,
    selection_start: u32,
    selection_len: u32,
};

/// A piece of authored prose on a PullRequest, optionally anchored and optionally
/// a Reply. The generic term; a Thread gives it its display role.
pub const Comment = struct {
    id: CommentId,
    /// The comment this one replies to, or null for a root comment.
    parent_id: ?CommentId = null,
    author: []const u8,
    /// Raw markdown body, as authored. Not rendered as markdown yet (M11).
    body: []const u8,
    /// Roots carry one exhaustive scope; Replies carry null and inherit it.
    scope: ?CommentScope = null,
    /// Transitional source compatibility for pre-CommentScope callers. New
    /// code writes `scope`; `effectiveScope` maps old root values losslessly.
    anchor: ?Anchor = null,
    /// Bitbucket's thread-resolution flag (set on the root comment).
    resolved: bool = false,
    /// Bitbucket's anchor verdict against the current diff.
    state: ScopeState = .current,

    pub fn isReply(self: Comment) bool {
        return self.parent_id != null;
    }

    pub fn isInline(self: Comment) bool {
        return self.effectiveScope() == .@"inline";
    }

    pub fn isFile(self: Comment) bool {
        return self.effectiveScope() == .file;
    }

    pub fn isReview(self: Comment) bool {
        return self.effectiveScope() == .review;
    }

    pub fn effectiveScope(self: Comment) CommentScope {
        if (self.scope) |scope| return scope;
        if (self.anchor) |anchor| return .{ .@"inline" = anchor };
        return .review;
    }

    pub fn validate(self: Comment) error{InvalidCommentScope}!void {
        if (self.isReply()) {
            if (self.scope != null or self.anchor != null) return error.InvalidCommentScope;
            return;
        }
        const scope = self.effectiveScope();
        if (scope == .@"inline" and scope.@"inline".line() == null) return error.InvalidCommentScope;
    }

    /// If the body contains a fenced ```suggestion block, return the proposed
    /// replacement text (the block's inner lines, newline-joined, no trailing
    /// newline). Suggestions are authored/displayed here; *applying* them stays
    /// in the Bitbucket web UI (design §6). Returns null when there is none.
    pub fn suggestion(self: Comment) ?[]const u8 {
        return suggestionBody(self.body);
    }
};

/// The replacement code inside `body`'s fenced ```suggestion block, or null
/// when the body carries none. Shared by Comments and Drafts so authoring,
/// display, and editing all read the same fenced storage representation.
pub fn suggestionBody(body: []const u8) ?[]const u8 {
    const fence = "```suggestion";
    const open = std.mem.indexOf(u8, body, fence) orelse return null;
    // The content starts after the fence line's newline.
    const after_fence = open + fence.len;
    const nl = std.mem.indexOfScalarPos(u8, body, after_fence, '\n') orelse return null;
    const body_start = nl + 1;
    // Closing fence is the next ``` at a line start.
    const rest = body[body_start..];
    const close_rel = std.mem.indexOf(u8, rest, "```") orelse return null;
    var content = rest[0..close_rel];
    // Drop the newline that precedes the closing fence, if any.
    if (content.len > 0 and content[content.len - 1] == '\n') {
        content = content[0 .. content.len - 1];
    }
    return content;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "role predicates: reply and inline" {
    const root: Comment = .{ .id = 1, .author = "a", .body = "hi" };
    try testing.expect(!root.isReply());
    try testing.expect(!root.isInline());

    const reply: Comment = .{ .id = 2, .parent_id = 1, .author = "b", .body = "re" };
    try testing.expect(reply.isReply());

    const inline_c: Comment = .{ .id = 3, .author = "c", .body = "x", .scope = .{ .@"inline" = .{ .path = "f.zig", .to = 10 } } };
    try testing.expect(inline_c.isInline());
}

test "root scopes are exhaustive and Replies carry only parentage" {
    const review_root: Comment = .{ .id = 1, .author = "a", .body = "review", .scope = .review };
    const file_root: Comment = .{ .id = 2, .author = "a", .body = "file", .scope = .{ .file = .{ .path = "f.zig", .source_commit = "abc" } } };
    const reply: Comment = .{ .id = 3, .parent_id = 2, .author = "b", .body = "reply", .scope = null };
    try testing.expect(review_root.isReview());
    try testing.expect(file_root.isFile());
    try testing.expect(reply.scope == null);
}

test "invalid root and Reply scope combinations are rejected" {
    try testing.expectError(error.InvalidCommentScope, (Comment{ .id = 1, .author = "a", .body = "bad", .scope = .{ .@"inline" = .{ .path = "f" } } }).validate());
    try testing.expectError(error.InvalidCommentScope, (Comment{ .id = 2, .parent_id = 1, .author = "b", .body = "bad reply", .scope = .review }).validate());
}

test "anchor line prefers the new side" {
    try testing.expectEqual(@as(?u32, 10), (Anchor{ .path = "f", .to = 10, .from = 3 }).line());
    try testing.expectEqual(@as(?u32, 3), (Anchor{ .path = "f", .from = 3 }).line());
    try testing.expectEqual(@as(?u32, null), (Anchor{ .path = "f" }).line());
}

test "anchor isRange reflects a start_* bound; line stays the bottom" {
    const single = Anchor{ .path = "f", .to = 69 };
    try testing.expect(!single.isRange());

    const new_range = Anchor{ .path = "f", .start_to = 67, .to = 69 };
    try testing.expect(new_range.isRange());
    try testing.expectEqual(@as(?u32, 69), new_range.line());

    const old_range = Anchor{ .path = "f", .start_from = 3, .from = 19 };
    try testing.expect(old_range.isRange());
    try testing.expectEqual(@as(?u32, 19), old_range.line());
}

test "suggestion extracts the fenced block body" {
    const c: Comment = .{
        .id = 1,
        .author = "a",
        .body = "How about:\n```suggestion\nconst x = 1;\nconst y = 2;\n```\nthanks",
    };
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;", c.suggestion().?);
}

test "suggestion is null without a fenced block" {
    const c: Comment = .{ .id = 1, .author = "a", .body = "plain prose, no fence" };
    try testing.expect(c.suggestion() == null);
    // A generic code fence is not a suggestion.
    const c2: Comment = .{ .id = 2, .author = "a", .body = "```\ncode\n```" };
    try testing.expect(c2.suggestion() == null);
}

test "suggestion with an empty block yields empty replacement" {
    const c: Comment = .{ .id = 1, .author = "a", .body = "```suggestion\n```" };
    try testing.expectEqualStrings("", c.suggestion().?);
}
