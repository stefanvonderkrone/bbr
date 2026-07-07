//! The Composer overlay's state machine: a small multi-line text buffer for
//! authoring one Draft. Pure — it owns no terminal, only the growing body text
//! and the `Request` describing *what* is being authored (kind, target, anchor,
//! reply parent, and a human label for the header). `app.zig` drives it from key
//! events, renders `body()`, and on submit turns it into a `NewDraft`.
//!
//! Editing is deliberately minimal (append + newline + backspace at the end, no
//! mid-text cursor): enough to write a comment/reply/suggestion. The body is
//! owned by the allocator passed to `init` (the app's composer arena); the app
//! dupes it into the PR-scoped arena when it commits the Draft.

const std = @import("std");
const bbr = @import("bbr");

const DraftKind = bbr.review.DraftKind;
const CommentTarget = bbr.review.CommentTarget;
const Anchor = bbr.review.Anchor;
const Parent = bbr.review.draft.Parent;
const NewDraft = bbr.review.NewDraft;

/// The context an authoring action carries in from `app.zig`: everything a
/// `NewDraft` needs except the body the reviewer types. `label` is a short
/// header line ("New comment", "Reply", "Comment on f.zig:12").
pub const Request = struct {
    kind: DraftKind,
    target: CommentTarget = .bitbucket,
    anchor: ?Anchor = null,
    parent: ?Parent = null,
    label: []const u8,
};

pub const Composer = struct {
    allocator: std.mem.Allocator,
    request: Request,
    body_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, request: Request) Composer {
        return .{ .allocator = allocator, .request = request };
    }

    pub fn deinit(self: *Composer) void {
        self.body_buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// The body typed so far.
    pub fn body(self: *const Composer) []const u8 {
        return self.body_buf.items;
    }

    /// True when the body is empty or only whitespace — nothing worth saving.
    pub fn isBlank(self: *const Composer) bool {
        return std.mem.trim(u8, self.body_buf.items, " \t\r\n").len == 0;
    }

    /// Append typed bytes (a key's text) at the end.
    pub fn insert(self: *Composer, bytes: []const u8) !void {
        try self.body_buf.appendSlice(self.allocator, bytes);
    }

    /// Insert a newline (Enter inside the composer edits, it does not submit).
    pub fn newline(self: *Composer) !void {
        try self.body_buf.append(self.allocator, '\n');
    }

    /// Delete the last byte. No-op on an empty body.
    pub fn backspace(self: *Composer) void {
        if (self.body_buf.items.len > 0) self.body_buf.items.len -= 1;
    }

    /// The Draft to create from the current body. The body slice borrows the
    /// composer's buffer, so the caller must dupe it into durable storage before
    /// tearing the composer down.
    pub fn toNewDraft(self: *const Composer) NewDraft {
        return .{
            .kind = self.request.kind,
            .target = self.request.target,
            .anchor = self.request.anchor,
            .parent = self.request.parent,
            .body = self.body(),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "typing, newline, and backspace build the body" {
    var comp = Composer.init(testing.allocator, .{ .kind = .top_level, .label = "New comment" });
    defer comp.deinit();

    try testing.expect(comp.isBlank());
    try comp.insert("hello");
    try comp.newline();
    try comp.insert("world");
    try testing.expectEqualStrings("hello\nworld", comp.body());
    try testing.expect(!comp.isBlank());

    comp.backspace();
    try testing.expectEqualStrings("hello\nworl", comp.body());
}

test "blank detection ignores whitespace-only bodies" {
    var comp = Composer.init(testing.allocator, .{ .kind = .top_level, .label = "x" });
    defer comp.deinit();
    try comp.insert("  \t");
    try comp.newline();
    try testing.expect(comp.isBlank());
}

test "toNewDraft carries the request's kind, anchor, and parent" {
    var comp = Composer.init(testing.allocator, .{
        .kind = .reply,
        .anchor = .{ .path = "f.zig", .to = 12, .commit = "abc" },
        .parent = .{ .draft = 3 },
        .label = "Reply",
    });
    defer comp.deinit();
    try comp.insert("agreed");

    const nd = comp.toNewDraft();
    try testing.expect(nd.kind == .reply);
    try testing.expectEqualStrings("f.zig", nd.anchor.?.path);
    try testing.expectEqualStrings("abc", nd.anchor.?.commit.?);
    try testing.expect(nd.parent.? == .draft and nd.parent.?.draft == 3);
    try testing.expectEqualStrings("agreed", nd.body);
}

test "backspace on an empty body is a no-op" {
    var comp = Composer.init(testing.allocator, .{ .kind = .top_level, .label = "x" });
    defer comp.deinit();
    comp.backspace();
    try testing.expectEqual(@as(usize, 0), comp.body().len);
}
