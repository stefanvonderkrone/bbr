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
const AnchorSnapshot = bbr.review.comment.AnchorSnapshot;
const Parent = bbr.review.draft.Parent;
const NewDraft = bbr.review.NewDraft;
const CommentScope = bbr.review.CommentScope;

/// What an accepted Composer save mutates, when it is not creating something
/// new. The two identities stay distinct all the way through the interaction:
/// a local Draft is named by its TempId, a published Comment by its CommentId.
pub const MutationTarget = union(enum) {
    draft: bbr.review.TempId,
    comment: bbr.review.CommentId,
};

/// The context an authoring action carries in from `app.zig`: everything a
/// `NewDraft` needs except the body the reviewer types. `label` is a short
/// header line ("New comment", "Reply", "Edit local Draft"). `mutation` names
/// an existing item to replace instead of creating one; editing reuses this
/// same Composer, so its interaction and validation are creation's.
pub const Request = struct {
    kind: DraftKind,
    target: CommentTarget = .bitbucket,
    anchor: ?Anchor = null,
    scope: ?CommentScope = null,
    snapshot: ?AnchorSnapshot = null,
    parent: ?Parent = null,
    label: []const u8,
    mutation: ?MutationTarget = null,
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

    /// Replace the whole body with initial text — a prefill seed, e.g. the
    /// source lines a suggestion proposes to rewrite (M10b). The planned
    /// `$EDITOR` handoff will write its result back through this same seam.
    pub fn seed(self: *Composer, text: []const u8) !void {
        var replacement: std.ArrayList(u8) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.appendSlice(self.allocator, text);
        self.body_buf.deinit(self.allocator);
        self.body_buf = replacement;
    }

    /// Insert a newline (Enter inside the composer edits, it does not submit).
    pub fn newline(self: *Composer) !void {
        try self.body_buf.append(self.allocator, '\n');
    }

    /// Delete the last byte. No-op on an empty body.
    pub fn backspace(self: *Composer) void {
        if (self.body_buf.items.len > 0) self.body_buf.items.len -= 1;
    }

    /// Delete the word before the end (vim insert-mode `ctrl-w`): drop trailing
    /// spaces/tabs, then the run of word bytes. At the start of a line (only a
    /// newline behind), remove that newline so it joins onto the previous line.
    pub fn deleteWord(self: *Composer) void {
        const items = self.body_buf.items;
        var i = items.len;
        while (i > 0 and (items[i - 1] == ' ' or items[i - 1] == '\t')) i -= 1;
        if (i > 0 and items[i - 1] == '\n') {
            self.body_buf.items.len = i - 1;
            return;
        }
        while (i > 0 and items[i - 1] != ' ' and items[i - 1] != '\t' and items[i - 1] != '\n') i -= 1;
        self.body_buf.items.len = i;
    }

    /// Delete back to the start of the current line (vim insert-mode `ctrl-u`):
    /// everything after the last newline. On the first line, clears it.
    pub fn deleteToLineStart(self: *Composer) void {
        const items = self.body_buf.items;
        var i = items.len;
        while (i > 0 and items[i - 1] != '\n') i -= 1;
        self.body_buf.items.len = i;
    }

    /// The Draft to create from the current body. The body slice borrows the
    /// composer's buffer, so the caller must dupe it into durable storage before
    /// tearing the composer down.
    pub fn toNewDraft(self: *const Composer) NewDraft {
        return .{
            .kind = self.request.kind,
            .target = self.request.target,
            .anchor = self.request.anchor,
            .scope = self.request.scope,
            .snapshot = self.request.snapshot,
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
    var comp = Composer.init(testing.allocator, .{ .kind = .comment, .label = "New comment" });
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

test "seed prefills the body and can then be edited from the end" {
    var comp = Composer.init(testing.allocator, .{ .kind = .suggestion, .label = "Suggest" });
    defer comp.deinit();

    try comp.seed("const a = 1;\nconst b = 2;");
    try testing.expectEqualStrings("const a = 1;\nconst b = 2;", comp.body());
    // Seeding twice replaces rather than appends.
    try comp.seed("just one line");
    try testing.expectEqualStrings("just one line", comp.body());
    // The prefill is editable at the tail (append-only composer).
    try comp.insert(" more");
    try testing.expectEqualStrings("just one line more", comp.body());
}

test "seed preserves the old body when replacement allocation fails" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var comp = Composer.init(failing.allocator(), .{ .kind = .comment, .label = "x" });
    comp.body_buf = .empty;
    try comp.body_buf.appendSlice(testing.allocator, "old body");
    comp.allocator = failing.allocator();
    defer {
        comp.allocator = testing.allocator;
        comp.deinit();
    }

    try testing.expectError(error.OutOfMemory, comp.seed("replacement that needs storage"));
    try testing.expectEqualStrings("old body", comp.body());
}

test "blank detection ignores whitespace-only bodies" {
    var comp = Composer.init(testing.allocator, .{ .kind = .comment, .label = "x" });
    defer comp.deinit();
    try comp.insert("  \t");
    try comp.newline();
    try testing.expect(comp.isBlank());
}

test "toNewDraft carries the request's kind, anchor, and parent" {
    var comp = Composer.init(testing.allocator, .{
        .kind = .comment,
        .anchor = .{ .path = "f.zig", .to = 12, .commit = "abc" },
        .parent = .{ .draft = 3 },
        .label = "Reply",
    });
    defer comp.deinit();
    try comp.insert("agreed");

    const nd = comp.toNewDraft();
    try testing.expect(nd.kind == .comment);
    try testing.expectEqualStrings("f.zig", nd.anchor.?.path);
    try testing.expectEqualStrings("abc", nd.anchor.?.commit.?);
    try testing.expect(nd.parent.? == .draft and nd.parent.?.draft == 3);
    try testing.expectEqualStrings("agreed", nd.body);
}

test "an edit request carries its typed mutation target through the interaction" {
    var comp = Composer.init(testing.allocator, .{
        .kind = .suggestion,
        .parent = .{ .draft = 3 },
        .label = "Edit local Draft",
        .mutation = .{ .draft = 9 },
    });
    defer comp.deinit();
    try comp.seed("const x = 1;");
    try comp.insert("\nconst y = 2;");

    try testing.expect(comp.request.mutation.? == .draft);
    try testing.expectEqual(@as(bbr.review.TempId, 9), comp.request.mutation.?.draft);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;", comp.body());
    // The mutation target does not disturb the NewDraft shape the body implies.
    try testing.expect(comp.toNewDraft().parent.? == .draft);
}

test "backspace on an empty body is a no-op" {
    var comp = Composer.init(testing.allocator, .{ .kind = .comment, .label = "x" });
    defer comp.deinit();
    comp.backspace();
    try testing.expectEqual(@as(usize, 0), comp.body().len);
}

test "deleteWord drops trailing spaces then the last word" {
    var comp = Composer.init(testing.allocator, .{ .kind = .comment, .label = "x" });
    defer comp.deinit();
    try comp.insert("hello world  ");
    comp.deleteWord();
    try testing.expectEqualStrings("hello ", comp.body());
    comp.deleteWord();
    try testing.expectEqualStrings("", comp.body());
    comp.deleteWord(); // no-op on empty
    try testing.expectEqualStrings("", comp.body());
}

test "deleteWord at a line start joins to the previous line" {
    var comp = Composer.init(testing.allocator, .{ .kind = .comment, .label = "x" });
    defer comp.deinit();
    try comp.insert("first");
    try comp.newline();
    comp.deleteWord(); // only a newline behind → remove it
    try testing.expectEqualStrings("first", comp.body());
}

test "deleteToLineStart clears the current line, keeping earlier ones" {
    var comp = Composer.init(testing.allocator, .{ .kind = .comment, .label = "x" });
    defer comp.deinit();
    try comp.insert("line one");
    try comp.newline();
    try comp.insert("line two text");
    comp.deleteToLineStart();
    try testing.expectEqualStrings("line one\n", comp.body());
    // Again: nothing after the newline, so it's a no-op (does not cross lines).
    comp.deleteToLineStart();
    try testing.expectEqualStrings("line one\n", comp.body());
}
