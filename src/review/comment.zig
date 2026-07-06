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
pub const AnchorState = enum { current, moved, outdated };

/// The diff location a Comment attaches to. Exactly one of `from`/`to` is set
/// for a single-sided comment: `from` is an old-file line, `to` a new-file line.
/// `start_*` bound a multi-line range (deferred to authoring, M5+).
pub const Anchor = struct {
    path: []const u8,
    /// Old-file (left) line number, 1-based.
    from: ?u32 = null,
    /// New-file (right) line number, 1-based.
    to: ?u32 = null,

    /// The line this anchor renders against in the unified diff, preferring the
    /// new side (where an added/context comment lives) then the old side.
    pub fn line(self: Anchor) ?u32 {
        return self.to orelse self.from;
    }
};

/// A piece of authored prose on a PullRequest, optionally anchored and optionally
/// a Reply. The generic term; a Thread gives it its display role.
pub const Comment = struct {
    id: CommentId,
    /// The comment this one replies to, or null for a root comment.
    parent_id: ?CommentId = null,
    author: []const u8,
    /// Raw markdown body, as authored. Not rendered as markdown yet (M8).
    body: []const u8,
    /// The diff anchor, or null for a PR-level comment.
    anchor: ?Anchor = null,
    /// Bitbucket's thread-resolution flag (set on the root comment).
    resolved: bool = false,
    /// Bitbucket's anchor verdict against the current diff.
    state: AnchorState = .current,

    pub fn isReply(self: Comment) bool {
        return self.parent_id != null;
    }

    pub fn isInline(self: Comment) bool {
        return self.anchor != null;
    }

    /// If the body contains a fenced ```suggestion block, return the proposed
    /// replacement text (the block's inner lines, newline-joined, no trailing
    /// newline). Suggestions are authored/displayed here; *applying* them stays
    /// in the Bitbucket web UI (design §6). Returns null when there is none.
    pub fn suggestion(self: Comment) ?[]const u8 {
        const fence = "```suggestion";
        const open = std.mem.indexOf(u8, self.body, fence) orelse return null;
        // The content starts after the fence line's newline.
        const after_fence = open + fence.len;
        const nl = std.mem.indexOfScalarPos(u8, self.body, after_fence, '\n') orelse return null;
        const body_start = nl + 1;
        // Closing fence is the next ``` at a line start.
        const rest = self.body[body_start..];
        const close_rel = std.mem.indexOf(u8, rest, "```") orelse return null;
        var content = rest[0..close_rel];
        // Drop the newline that precedes the closing fence, if any.
        if (content.len > 0 and content[content.len - 1] == '\n') {
            content = content[0 .. content.len - 1];
        }
        return content;
    }
};

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

    const inline_c: Comment = .{ .id = 3, .author = "c", .body = "x", .anchor = .{ .path = "f.zig", .to = 10 } };
    try testing.expect(inline_c.isInline());
}

test "anchor line prefers the new side" {
    try testing.expectEqual(@as(?u32, 10), (Anchor{ .path = "f", .to = 10, .from = 3 }).line());
    try testing.expectEqual(@as(?u32, 3), (Anchor{ .path = "f", .from = 3 }).line());
    try testing.expectEqual(@as(?u32, null), (Anchor{ .path = "f" }).line());
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
