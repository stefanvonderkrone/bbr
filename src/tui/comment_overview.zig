//! The Comment Overview projection: one Overview Entry for each Comment,
//! Reply, and Draft that the DiffPane shows as a ReviewCard. Pure, so
//! fixtures prove it without a terminal. It imports neither vaxis nor
//! theme.zig.

const std = @import("std");
const bbr = @import("bbr");
const buffer_mod = @import("buffer.zig");
const file_tree = @import("file_tree.zig");
const review_card = @import("review_card.zig");
const review_body = @import("review_body.zig");
const list_overlay = @import("list_overlay.zig");
const CellMetrics = @import("cell_metrics.zig").CellMetrics;

pub const Order = enum { review, newest_first };

/// The longest query in bytes.
pub const max_query_bytes = 256;

/// The Overview State. It belongs to the Session, so a Session replacement
/// resets it.
pub const State = struct {
    query_buf: [max_query_bytes]u8 = undefined,
    query_len: usize = 0,
    unresolved_only: bool = false,
    drafts_only: bool = false,
    mine_only: bool = false,
    order: Order = .review,
    file_tree_filter: ?file_tree.Identity = null,
    selected: ?review_card.Owner = null,
    scroll: usize = 0,

    pub fn query(self: *const State) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// Keeps the whole UTF-8 scalars of `text` that fit in the query buffer.
    pub fn setQuery(self: *State, text: []const u8) void {
        var len: usize = 0;
        while (len < text.len) {
            const size = std.unicode.utf8ByteSequenceLength(text[len]) catch break;
            if (len + size > text.len or len + size > self.query_buf.len) break;
            len += size;
        }
        std.mem.copyForwards(u8, self.query_buf[0..len], text[0..len]);
        self.query_len = len;
    }

    pub fn apply(self: *State, change: Change) void {
        switch (change) {
            .unresolved_only => self.unresolved_only = !self.unresolved_only,
            .drafts_only => self.drafts_only = !self.drafts_only,
            .mine_only => self.mine_only = !self.mine_only,
            .order => self.order = switch (self.order) {
                .review => .newest_first,
                .newest_first => .review,
            },
            .query => |text| self.setQuery(text),
            .file_tree_filter => |identity| self.file_tree_filter = if (identity) |value| switch (value) {
                .root => null,
                .directory, .file => value,
            } else null,
        }
    }
};

/// One Overview State change that rebuilds the listing.
pub const Change = union(enum) {
    unresolved_only,
    drafts_only,
    mine_only,
    order,
    /// The whole new query text. It can alias the current query.
    query: []const u8,
    /// The File Tree entry under the cursor. The root entry clears the
    /// filter. A Directory path can borrow from the File Tree, because
    /// `Published.rebuildOverview` copies it into the listing arena.
    file_tree_filter: ?file_tree.Identity,
};

/// The open query input. Escape restores the saved query.
pub const QueryInput = struct {
    saved_buf: [max_query_bytes]u8 = undefined,
    saved_len: usize = 0,

    pub fn init(state: *const State) QueryInput {
        var input: QueryInput = .{ .saved_len = state.query_len };
        @memcpy(input.saved_buf[0..state.query_len], state.query());
        return input;
    }

    pub fn saved(self: *const QueryInput) []const u8 {
        return self.saved_buf[0..self.saved_len];
    }
};

pub const IndexInputs = struct {
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    scope_projections: []const bbr.review.ScopeProjectionEntry,
    mention_names: *const review_body.MentionNames,
    authenticated_account_uuid: ?[]const u8,
    emphasis_cache: ?*const buffer_mod.EmphasisCache = null,
};

pub const Record = struct {
    owner: review_card.Owner,
    parent: ?review_card.Owner,
    /// 0 for a root.
    depth: usize,
    role: review_card.CardRole,
    /// The ReviewCard Title format without ancestry, as in `Ada (deleted)`.
    author: []const u8,
    /// The projected scope of the Thread root.
    scope: bbr.review.CommentScope,
    /// The first File whose paths `scope` matches, as in the File tallies.
    /// Null for a Review-level item and a path outside the Diff.
    file: ?usize,
    /// Null for `unavailable`.
    scope_state: ?bbr.review.ScopeState,
    resolved: bool,
    mine: bool,
    excerpt: []const u8,
    /// The author, the scope path, and the authored body, joined with newlines.
    haystack: []const u8,
    review_rank: usize,
    /// The position in newest first. A Thread sorts by its newest member,
    /// and its Replies keep their Review order.
    recency_rank: usize,
};

/// Every record in Review order. The index owns every string.
pub const Index = struct {
    records: []const Record = &.{},
};

pub const Entry = struct {
    record: usize,
    context: bool,
};

pub const Listing = struct {
    entries: []const Entry = &.{},
    matches: usize = 0,
    records: usize = 0,
};

/// What the renderer and hit testing read from a published Presentation
/// Frame while the Comment Overview shows.
const empty_state: State = .{};

pub const Frame = struct {
    records: []const Record = &.{},
    listing: Listing = .{},
    /// Borrowed from `Published`, so the query bytes outlive the paint.
    /// vaxis cells keep their text until render, so a by-value copy of the
    /// query buffer on a stack would leave dangling cells.
    state: *const State = &empty_state,
    /// The listing entry of `state.selected`.
    selected: ?usize = null,
    query_input: bool = false,
    /// The path of the File Tree Filter, or empty without one.
    filter_path: []const u8 = "",
    cell_metrics: CellMetrics = .bytes,
};

/// The longest excerpt in bytes. The cut keeps whole UTF-8 scalars.
const excerpt_bytes = 200;

pub fn buildIndex(allocator: std.mem.Allocator, inputs: IndexInputs) !Index {
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const options: buffer_mod.BuildOptions = .{
        .drafts = inputs.drafts,
        .scope_projections = inputs.scope_projections,
        .mention_names = inputs.mention_names,
        .emphasis_cache = inputs.emphasis_cache,
    };
    const nodes = try buffer_mod.reviewCardNodes(scratch, inputs.diff, inputs.threads, options);

    var threads_by_root: std.AutoHashMapUnmanaged(bbr.review.CommentId, *const bbr.review.Thread) = .empty;
    try threads_by_root.ensureTotalCapacity(scratch, @intCast(inputs.threads.len));
    for (inputs.threads) |*thread| threads_by_root.putAssumeCapacity(thread.root.id, thread);
    const file_order = try file_tree.fileOrder(scratch, inputs.diff);

    var trees: std.ArrayList(Tree) = .empty;
    for (nodes, 0..) |node, index| {
        if (node.parent != null) {
            trees.items[trees.items.len - 1].end = index + 1;
            continue;
        }
        try trees.append(scratch, .{
            .key = treeKey(node, inputs.diff, file_order, threads_by_root),
            .start = index,
            .end = index + 1,
        });
    }
    std.mem.sort(Tree, trees.items, {}, Tree.lessThan);

    const records = try allocator.alloc(Record, nodes.len);
    var rank: usize = 0;
    for (trees.items) |*tree| {
        const root = nodes[tree.start];
        tree.newest = 0;
        for (nodes[tree.start..tree.end]) |node| tree.newest = @max(tree.newest, recency(node.owner));
        const scope = try copyScope(allocator, root.scope);
        const file: ?usize = for (inputs.diff.files, 0..) |diff_file, file_index| {
            if (buffer_mod.scopeMatchesFile(root.scope, diff_file)) break file_index;
        } else null;
        const scope_state: ?bbr.review.ScopeState, const resolved = switch (root.source) {
            .comment => |comment| .{ comment.state, threads_by_root.get(comment.id).?.resolved },
            .draft => |draft| .{ switch (buffer_mod.draftResolution(draft, options)) {
                .unavailable => null,
                .resolved => |value| value.state,
            }, false },
        };
        for (nodes[tree.start..tree.end]) |node| {
            const author = try buffer_mod.reviewCardAuthor(allocator, node.source);
            const body = node.source.body();
            const parsed = try review_body.ReviewBody.parseWithMentions(scratch, body, inputs.mention_names);
            records[rank] = .{
                .owner = node.owner,
                .parent = node.parent,
                .depth = node.depth,
                .role = node.role,
                .author = author,
                .scope = scope,
                .file = file,
                .scope_state = scope_state,
                .resolved = resolved,
                .mine = switch (node.source) {
                    .comment => |comment| if (inputs.authenticated_account_uuid) |account|
                        if (comment.author_uuid) |uuid| std.mem.eql(u8, uuid, account) else false
                    else
                        false,
                    .draft => true,
                },
                .excerpt = try allocator.dupe(u8, try review_body.excerpt(scratch, parsed, excerpt_bytes)),
                .haystack = try std.mem.join(allocator, "\n", &.{ author, scopePath(scope), body }),
                .review_rank = rank,
                .recency_rank = undefined,
            };
            rank += 1;
        }
    }

    var review_start: usize = 0;
    for (trees.items) |*tree| {
        const len = tree.end - tree.start;
        tree.start = review_start;
        tree.end = review_start + len;
        review_start = tree.end;
    }
    std.mem.sort(Tree, trees.items, {}, Tree.newerThan);
    rank = 0;
    for (trees.items) |tree| for (records[tree.start..tree.end]) |*record| {
        record.recency_rank = rank;
        rank += 1;
    };
    return .{ .records = records };
}

/// A larger value is newer. A Draft is newer than every Comment, and a
/// larger TempId or CommentId is newer than a smaller one.
fn recency(owner: review_card.Owner) u128 {
    return switch (owner) {
        .comment => |id| id,
        .draft => |id| (@as(u128, 1) << 64) | id,
    };
}

/// The matching entries in the Overview State order, each under its
/// ancestors. An ancestor that does not match is a context entry.
pub fn buildListing(allocator: std.mem.Allocator, index: *const Index, state: *const State) !Listing {
    const records = index.records;
    var needles: list_overlay.Query.Needles = undefined;
    const query = list_overlay.Query.parse(state.query(), &needles);

    const Shown = enum { hidden, context, match };
    const shown = try allocator.alloc(Shown, records.len);
    defer allocator.free(shown);
    var ancestors: std.ArrayList(usize) = .empty;
    defer ancestors.deinit(allocator);
    var matches: usize = 0;
    for (records, 0..) |record, position| {
        std.debug.assert(record.depth <= ancestors.items.len);
        ancestors.shrinkRetainingCapacity(record.depth);
        try ancestors.append(allocator, position);
        shown[position] = .hidden;
        if (!keeps(record, state, query)) continue;
        shown[position] = .match;
        matches += 1;
        for (ancestors.items[0..record.depth]) |ancestor| {
            if (shown[ancestor] == .hidden) shown[ancestor] = .context;
        }
    }

    const ordered = try allocator.alloc(usize, records.len);
    defer allocator.free(ordered);
    for (records, 0..) |record, position| ordered[
        switch (state.order) {
            .review => record.review_rank,
            .newest_first => record.recency_rank,
        }
    ] = position;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    for (ordered) |position| if (shown[position] != .hidden)
        try entries.append(allocator, .{ .record = position, .context = shown[position] == .context });
    return .{ .entries = try entries.toOwnedSlice(allocator), .matches = matches, .records = records.len };
}

/// Every active filter keeps the record. A blank query keeps every record.
fn keeps(record: Record, state: *const State, query: ?list_overlay.Query) bool {
    if (state.unresolved_only and record.resolved) return false;
    if (state.drafts_only and record.owner != .draft) return false;
    if (state.mine_only and !record.mine) return false;
    if (state.file_tree_filter) |filter| switch (filter) {
        .root => {},
        .file => |file_index| if (record.file != file_index) return false,
        .directory => |path| {
            const scope_path = scopePath(record.scope);
            if (record.scope == .review or !(scope_path.len > path.len and std.mem.startsWith(u8, scope_path, path) and scope_path[path.len] == '/')) return false;
        },
    };
    if (query) |value| if (value.rank(record.haystack) == null) return false;
    return true;
}

/// One Thread root and its Replies, in Buffer order.
const Tree = struct {
    key: TreeKey,
    start: usize,
    end: usize,
    /// The `recency` of the newest member.
    newest: u128 = 0,

    fn lessThan(_: void, lhs: Tree, rhs: Tree) bool {
        return lhs.key.order(rhs.key) == .lt;
    }

    fn newerThan(_: void, lhs: Tree, rhs: Tree) bool {
        return lhs.newest > rhs.newest;
    }
};

/// The place of a Thread in Review order. `order` compares the fields from
/// the first to the last.
const TreeKey = struct {
    region: enum { review, file, unknown_path },
    file_rank: usize = 0,
    path: []const u8 = "",
    level: enum { file, @"inline" } = .file,
    line: u32 = 0,
    side: enum { old, new } = .old,
    origin: enum { comment, draft },
    rank: u64,

    fn order(lhs: TreeKey, rhs: TreeKey) std.math.Order {
        const orders = [_]std.math.Order{
            std.math.order(@intFromEnum(lhs.region), @intFromEnum(rhs.region)),
            std.math.order(lhs.file_rank, rhs.file_rank),
            std.mem.order(u8, lhs.path, rhs.path),
            std.math.order(@intFromEnum(lhs.level), @intFromEnum(rhs.level)),
            std.math.order(lhs.line, rhs.line),
            std.math.order(@intFromEnum(lhs.side), @intFromEnum(rhs.side)),
            std.math.order(@intFromEnum(lhs.origin), @intFromEnum(rhs.origin)),
            std.math.order(lhs.rank, rhs.rank),
        };
        for (orders) |value| if (value != .eq) return value;
        return .eq;
    }
};

fn treeKey(
    root: buffer_mod.ReviewCardNode,
    diff: bbr.diff.Diff,
    file_order: []const usize,
    threads_by_root: std.AutoHashMapUnmanaged(bbr.review.CommentId, *const bbr.review.Thread),
) TreeKey {
    var key: TreeKey = switch (root.source) {
        .comment => |comment| .{ .region = .review, .origin = .comment, .rank = threads_by_root.get(comment.id).?.root_input_order },
        .draft => |draft| .{ .region = .review, .origin = .draft, .rank = draft.local_id },
    };
    if (root.scope == .review) return key;
    key.region = .unknown_path;
    key.path = scopePath(root.scope);
    for (file_order, 0..) |file_index, file_rank| if (buffer_mod.scopeMatchesFile(root.scope, diff.files[file_index])) {
        key.region = .file;
        key.file_rank = file_rank;
        key.path = "";
        break;
    };
    if (root.scope == .@"inline") {
        const anchor = root.scope.@"inline";
        key.level = .@"inline";
        key.line = anchor.top() orelse 0;
        key.side = if (anchor.to != null) .new else .old;
    }
    return key;
}

fn scopePath(scope: bbr.review.CommentScope) []const u8 {
    return switch (scope) {
        .review => "",
        .file => |file| file.path,
        .@"inline" => |anchor| anchor.path,
    };
}

fn copyScope(allocator: std.mem.Allocator, scope: bbr.review.CommentScope) !bbr.review.CommentScope {
    return switch (scope) {
        .review => .review,
        .file => |file| .{ .file = .{
            .path = try allocator.dupe(u8, file.path),
            .source_commit = try allocator.dupe(u8, file.source_commit),
        } },
        .@"inline" => |anchor| blk: {
            var copy = anchor;
            copy.path = try allocator.dupe(u8, anchor.path);
            copy.commit = if (anchor.commit) |commit| try allocator.dupe(u8, commit) else null;
            break :blk .{ .@"inline" = copy };
        },
    };
}

const testing = std.testing;
const Comment = bbr.review.Comment;
const Draft = bbr.review.Draft;
const Owner = review_card.Owner;

/// `a.txt` sorts before `a/b.txt` by path, but the File Tree lists the
/// Directory `a/` first.
const fixture_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,3 +1,3 @@
    \\ one
    \\-two
    \\+TWO
    \\ three
    \\diff --git a/a/b.txt b/a/b.txt
    \\--- a/a/b.txt
    \\+++ b/a/b.txt
    \\@@ -1 +1 @@
    \\-x
    \\+y
    \\
;

const Fixture = struct {
    comments: []const Comment = &.{},
    drafts: []const Draft = &.{},
    scope_projections: []const bbr.review.ScopeProjectionEntry = &.{},
    account: ?[]const u8 = null,

    fn index(self: Fixture, a: std.mem.Allocator) !Index {
        const diff = try bbr.diff.parse(a, fixture_diff);
        const threads = try bbr.review.buildThreads(a, self.comments);
        return buildIndex(a, .{
            .diff = diff,
            .threads = threads,
            .drafts = self.drafts,
            .scope_projections = self.scope_projections,
            .mention_names = &.empty,
            .authenticated_account_uuid = self.account,
        });
    }
};

fn expectOwners(expected: []const Owner, index: Index) !void {
    try testing.expectEqual(expected.len, index.records.len);
    for (expected, index.records, 0..) |owner, record, rank| {
        try testing.expectEqualDeep(owner, record.owner);
        try testing.expectEqual(rank, record.review_rank);
    }
}

fn recordOf(index: Index, owner: Owner) !Record {
    for (index.records) |record| if (std.meta.eql(record.owner, owner)) return record;
    return error.TestExpectedRecord;
}

test "M29 overview the index lists Review-level, File-level, new-side, old-side, and range Comments with their scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scopes = [_]bbr.review.CommentScope{
        .review,
        .{ .file = .{ .path = "a.txt", .source_commit = "abc" } },
        .{ .@"inline" = .{ .path = "a.txt", .to = 2 } },
        .{ .@"inline" = .{ .path = "a.txt", .from = 2 } },
        .{ .@"inline" = .{ .path = "a.txt", .start_to = 1, .to = 3 } },
    };
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "review  body\nmore", .scope = scopes[0] },
        .{ .id = 2, .author = "Ada", .body = "file", .scope = scopes[1] },
        .{ .id = 3, .author = "Ada", .body = "new", .scope = scopes[2] },
        .{ .id = 4, .author = "Ada", .body = "old", .scope = scopes[3] },
        .{ .id = 5, .author = "Ada", .body = "range", .scope = scopes[4] },
    };
    const index = try (Fixture{ .comments = &comments }).index(a);
    try expectOwners(&.{ .{ .comment = 1 }, .{ .comment = 2 }, .{ .comment = 5 }, .{ .comment = 4 }, .{ .comment = 3 } }, index);
    for ([_]usize{ 0, 1, 4, 3, 2 }, index.records) |comment, record| {
        try testing.expectEqualDeep(scopes[comment], record.scope);
        try testing.expectEqual(@as(?Owner, null), record.parent);
        try testing.expectEqual(@as(usize, 0), record.depth);
        try testing.expectEqual(review_card.CardRole.comment, record.role);
        try testing.expectEqualStrings("Ada", record.author);
        try testing.expectEqual(@as(?bbr.review.ScopeState, .current), record.scope_state);
        try testing.expect(!record.resolved);
    }
    try testing.expectEqualStrings("review body", index.records[0].excerpt);
    try testing.expectEqualStrings("Ada\n\nreview  body\nmore", index.records[0].haystack);
    try testing.expectEqualStrings("Ada\na.txt\nfile", index.records[1].haystack);
    try testing.expect(index.records[1].scope.file.path.ptr != scopes[1].file.path.ptr);
    try testing.expect(index.records[1].scope.file.source_commit.ptr != scopes[1].file.source_commit.ptr);
    try testing.expect(index.records[2].scope.@"inline".path.ptr != scopes[4].@"inline".path.ptr);
}

test "M29 overview the index lists Replies at their depth and Drafts under their parents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scope: bbr.review.CommentScope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } };
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "root", .scope = scope },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
        .{ .id = 3, .parent_id = 2, .author = "Cy", .body = "nested" },
    };
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "draft root" },
        .{ .local_id = 2, .kind = .suggestion, .body = "```suggestion\nx\n```", .parent = .{ .comment = 3 } },
        .{ .local_id = 3, .kind = .comment, .body = "draft reply", .parent = .{ .draft = 1 } },
    };
    const index = try (Fixture{ .comments = &comments, .drafts = &drafts }).index(a);
    try expectOwners(&.{ .{ .draft = 1 }, .{ .draft = 3 }, .{ .comment = 1 }, .{ .comment = 2 }, .{ .comment = 3 }, .{ .draft = 2 } }, index);
    const parents = [_]?Owner{ null, .{ .draft = 1 }, null, .{ .comment = 1 }, .{ .comment = 2 }, .{ .comment = 3 } };
    const depths = [_]usize{ 0, 1, 0, 1, 2, 3 };
    const roles = [_]review_card.CardRole{ .draft, .draft_reply, .comment, .comment_reply, .comment_reply, .draft_reply };
    const authors = [_][]const u8{ "✎ draft", "✎ draft", "Ada", "Bob", "Cy", "✎ draft (suggestion)" };
    for (index.records, parents, depths, roles, authors, 0..) |record, parent, depth, role, author, position| {
        try testing.expectEqualDeep(parent, record.parent);
        try testing.expectEqual(depth, record.depth);
        try testing.expectEqual(role, record.role);
        try testing.expectEqualStrings(author, record.author);
        try testing.expectEqualDeep(if (position < 2) bbr.review.CommentScope.review else scope, record.scope);
    }
    try testing.expectEqualStrings("suggestion", index.records[5].excerpt);
}

test "M29 overview the index lists resolved Threads, Deleted Comments, and outdated, moved, and unavailable items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "resolved", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } }, .resolved = true },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
        .{ .id = 3, .author = "Ann", .body = "", .deleted = true },
        .{ .id = 4, .author = "Ada", .body = "outdated", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 9 } }, .state = .outdated },
        .{ .id = 5, .author = "Ada", .body = "moved", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 3 } }, .state = .moved },
    };
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "unavailable", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 1 } } },
        .{ .local_id = 2, .kind = .comment, .body = "outdated draft", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 1 } } },
        .{ .local_id = 3, .kind = .comment, .body = "outcome", .state = .outcome_unknown },
    };
    const projections = [_]bbr.review.ScopeProjectionEntry{
        .{ .temp_id = 1, .resolution = .unavailable },
        .{ .temp_id = 2, .resolution = .{ .resolved = .{ .state = .outdated, .scope = drafts[1].scope.? } } },
    };
    const index = try (Fixture{ .comments = &comments, .drafts = &drafts, .scope_projections = &projections }).index(a);
    try testing.expectEqual(@as(usize, 8), index.records.len);
    for ([_]Owner{ .{ .comment = 1 }, .{ .comment = 2 } }) |owner| try testing.expect((try recordOf(index, owner)).resolved);
    const deleted = try recordOf(index, .{ .comment = 3 });
    try testing.expectEqualStrings("Ann (deleted)", deleted.author);
    try testing.expectEqualStrings("", deleted.excerpt);
    try testing.expectEqual(review_card.CardRole.deleted_comment, deleted.role);
    try testing.expect(!deleted.resolved);
    const states = [_]struct { owner: Owner, state: ?bbr.review.ScopeState }{
        .{ .owner = .{ .comment = 2 }, .state = .current },
        .{ .owner = .{ .comment = 4 }, .state = .outdated },
        .{ .owner = .{ .comment = 5 }, .state = .moved },
        .{ .owner = .{ .draft = 1 }, .state = null },
        .{ .owner = .{ .draft = 2 }, .state = .outdated },
        .{ .owner = .{ .draft = 3 }, .state = .current },
    };
    for (states) |case| try testing.expectEqual(case.state, (try recordOf(index, case.owner)).scope_state);
    const outcome = try recordOf(index, .{ .draft = 3 });
    try testing.expectEqualStrings("✎ draft (outcome unknown)", outcome.author);
    try testing.expectEqual(review_card.CardRole.outcome_unknown, outcome.role);
}

test "M29 overview the index hides a submitting Draft and lists a posted Draft until its Comment is fetched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "submitting", .state = .submitting },
        .{ .local_id = 2, .kind = .comment, .body = "posted", .state = .{ .posted = 50 } },
    };
    const pending = try (Fixture{ .drafts = &drafts }).index(a);
    try expectOwners(&.{.{ .draft = 2 }}, pending);
    try testing.expectEqualStrings("✎ draft (posted)", pending.records[0].author);
    const comments = [_]Comment{.{ .id = 50, .author = "Ada", .body = "posted" }};
    const fetched = try (Fixture{ .comments = &comments, .drafts = &drafts }).index(a);
    try expectOwners(&.{.{ .comment = 50 }}, fetched);
}

const OwnerPair = struct { owner: Owner, parent: ?Owner };

fn pairLessThan(_: void, lhs: OwnerPair, rhs: OwnerPair) bool {
    return recency(lhs.owner) < recency(rhs.owner);
}

test "M29 overview the index lists the DiffPane ReviewCards with every disclosure open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a, fixture_diff);
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "resolved", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } }, .resolved = true },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
        .{ .id = 3, .author = "Ada", .body = "outdated", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 7 } }, .state = .outdated },
        .{ .id = 4, .parent_id = 3, .author = "Bob", .body = "outdated reply" },
        .{ .id = 5, .author = "Ada", .body = "review" },
        .{ .id = 6, .parent_id = 99, .author = "Cy", .body = "orphan Reply" },
        .{ .id = 7, .author = "Ada", .body = "outdated file", .scope = .{ .file = .{ .path = "a/b.txt", .source_commit = "abc" } }, .state = .outdated, .resolved = true },
        .{ .id = 8, .author = "Ada", .body = "unknown path", .scope = .{ .@"inline" = .{ .path = "gone.txt", .to = 1 } }, .state = .outdated },
        .{ .id = 100, .author = "Ada", .body = "fetched", .scope = .{ .@"inline" = .{ .path = "a.txt", .from = 2 } } },
    };
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "posted alias", .scope = .{ .@"inline" = .{ .path = "a.txt", .from = 2 } }, .state = .{ .posted = 100 } },
        .{ .local_id = 2, .kind = .comment, .body = "under alias", .parent = .{ .draft = 1 } },
        .{ .local_id = 3, .kind = .comment, .body = "posted unfetched", .state = .{ .posted = 200 } },
        .{ .local_id = 4, .kind = .comment, .body = "under unfetched", .parent = .{ .draft = 3 } },
        .{ .local_id = 5, .kind = .comment, .body = "orphan Draft", .parent = .{ .draft = 99 } },
        .{ .local_id = 6, .kind = .comment, .body = "outdated Draft", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 3 } } },
        .{ .local_id = 7, .kind = .comment, .body = "submitting", .state = .submitting },
        .{ .local_id = 8, .kind = .comment, .body = "resolved reply", .parent = .{ .comment = 2 } },
        .{ .local_id = 9, .kind = .comment, .body = "orphan Comment parent", .parent = .{ .comment = 999 } },
    };
    const projections = [_]bbr.review.ScopeProjectionEntry{
        .{ .temp_id = 6, .resolution = .{ .resolved = .{ .state = .outdated, .scope = drafts[5].scope.? } } },
    };
    const threads = try bbr.review.buildThreads(a, &comments);
    const index = try buildIndex(a, .{
        .diff = diff,
        .threads = threads,
        .drafts = &drafts,
        .scope_projections = &projections,
        .mention_names = &.empty,
        .authenticated_account_uuid = null,
    });

    var keys: std.ArrayList(buffer_mod.DisclosureKey) = .empty;
    try keys.append(a, .outdated_review);
    for (diff.files) |*file| try keys.appendSlice(a, &.{ .{ .outdated_file = file }, .{ .opposite_version = file } });
    for (threads) |thread| if (thread.resolved) try keys.append(a, .{ .resolved_thread = thread.root.id });
    const buf = try buffer_mod.buildWithComments(a, diff, .unified, threads, .{
        .drafts = &drafts,
        .scope_projections = &projections,
        .expanded_disclosures = keys.items,
    });
    var expected: std.ArrayList(OwnerPair) = .empty;
    for (buf.rows) |row| switch (row) {
        .comment, .draft => |card| if (card.part == .header) {
            const parent = if (card.card.?.parent) |value| switch (buf.rows[value.rows.start]) {
                .comment, .draft => |parent_card| parent_card.owner,
                else => unreachable,
            } else null;
            try expected.append(a, .{ .owner = card.owner, .parent = parent });
        },
        else => {},
    };
    var actual: std.ArrayList(OwnerPair) = .empty;
    for (index.records) |record| try actual.append(a, .{ .owner = record.owner, .parent = record.parent });
    std.mem.sort(OwnerPair, expected.items, {}, pairLessThan);
    std.mem.sort(OwnerPair, actual.items, {}, pairLessThan);
    try testing.expectEqualDeep(expected.items, actual.items);
    try testing.expect(expected.items.len >= 14);
    try testing.expect(!std.meta.eql((try recordOf(index, .{ .comment = 100 })).owner, Owner{ .draft = 1 }));
    try testing.expectError(error.TestExpectedRecord, recordOf(index, .{ .draft = 1 }));
    try testing.expectError(error.TestExpectedRecord, recordOf(index, .{ .draft = 7 }));
}

test "M29 overview Review order puts Review-level Threads first, then Files in File Tree order, then Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const new2: bbr.review.CommentScope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } };
    const comments = [_]Comment{
        .{ .id = 10, .author = "Ada", .body = "review" },
        .{ .id = 34, .author = "Ada", .body = "new 3", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 3 } } },
        .{ .id = 32, .author = "Ada", .body = "new 2 first", .scope = new2 },
        .{ .id = 33, .author = "Ada", .body = "new 2 second", .scope = new2 },
        .{ .id = 35, .parent_id = 32, .author = "Bob", .body = "reply" },
        .{ .id = 30, .author = "Ada", .body = "file", .scope = .{ .file = .{ .path = "a.txt", .source_commit = "abc" } } },
        .{ .id = 31, .author = "Ada", .body = "old 2", .scope = .{ .@"inline" = .{ .path = "a.txt", .from = 2 } } },
        .{ .id = 20, .author = "Ada", .body = "nested File", .scope = .{ .@"inline" = .{ .path = "a/b.txt", .to = 1 } } },
        .{ .id = 40, .author = "Ada", .body = "zzz", .scope = .{ .@"inline" = .{ .path = "zzz.txt", .to = 1 } }, .state = .outdated },
        .{ .id = 41, .author = "Ada", .body = "c", .scope = .{ .file = .{ .path = "c.txt", .source_commit = "abc" } }, .state = .outdated },
    };
    const drafts = [_]Draft{
        .{ .local_id = 3, .kind = .comment, .body = "draft 3", .scope = new2 },
        .{ .local_id = 1, .kind = .comment, .body = "review draft" },
        .{ .local_id = 2, .kind = .comment, .body = "draft 2", .scope = new2 },
    };
    const index = try (Fixture{ .comments = &comments, .drafts = &drafts }).index(a);
    try expectOwners(&.{
        .{ .comment = 10 }, .{ .draft = 1 },
        .{ .comment = 20 }, .{ .comment = 30 },
        .{ .comment = 31 }, .{ .comment = 32 },
        .{ .comment = 35 }, .{ .comment = 33 },
        .{ .draft = 2 },    .{ .draft = 3 },
        .{ .comment = 34 }, .{ .comment = 41 },
        .{ .comment = 40 },
    }, index);
}

test "M29 overview the listing lists every record in Review order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "inline", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
        .{ .id = 3, .author = "Ada", .body = "review" },
    };
    const drafts = [_]Draft{.{ .local_id = 1, .kind = .comment, .body = "draft" }};
    const index = try (Fixture{ .comments = &comments, .drafts = &drafts }).index(a);
    const listing = try buildListing(a, &index, &.{});
    try testing.expectEqual(@as(usize, 4), listing.records);
    try testing.expectEqual(@as(usize, 4), listing.matches);
    try testing.expectEqual(@as(usize, 4), listing.entries.len);
    const owners = [_]Owner{ .{ .comment = 3 }, .{ .draft = 1 }, .{ .comment = 1 }, .{ .comment = 2 } };
    for (listing.entries, owners) |entry, owner| {
        try testing.expect(!entry.context);
        try testing.expectEqualDeep(owner, index.records[entry.record].owner);
    }
}

test "M29 overview Comments are mine only for the Authenticated Account and Drafts are always mine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Me", .author_uuid = "{me}", .body = "mine" },
        .{ .id = 2, .author = "Other", .author_uuid = "{other}", .body = "other" },
        .{ .id = 3, .author = "Unknown", .body = "unknown" },
    };
    const drafts = [_]Draft{.{ .local_id = 1, .kind = .comment, .body = "draft" }};
    for ([_]?[]const u8{ "{me}", null }) |account| {
        const index = try (Fixture{ .comments = &comments, .drafts = &drafts, .account = account }).index(a);
        try testing.expectEqual(account != null, (try recordOf(index, .{ .comment = 1 })).mine);
        try testing.expect(!(try recordOf(index, .{ .comment = 2 })).mine);
        try testing.expect(!(try recordOf(index, .{ .comment = 3 })).mine);
        try testing.expect((try recordOf(index, .{ .draft = 1 })).mine);
    }
}

test "M29 overview the index and listing builds release every failed arena" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(backing: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(backing);
            defer arena.deinit();
            const comments = [_]Comment{
                .{ .id = 1, .author = "Ada", .body = "root **body**", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } }, .resolved = true },
                .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "reply" },
                .{ .id = 3, .author = "Cy", .body = "file", .scope = .{ .file = .{ .path = "a/b.txt", .source_commit = "abc" } } },
            };
            const drafts = [_]Draft{
                .{ .local_id = 1, .kind = .comment, .body = "draft", .parent = .{ .comment = 2 } },
                .{ .local_id = 2, .kind = .comment, .body = "review draft" },
            };
            const index = try (Fixture{ .comments = &comments, .drafts = &drafts }).index(arena.allocator());
            const listing = try buildListing(arena.allocator(), &index, &.{});
            try testing.expectEqual(@as(usize, 5), listing.entries.len);
        }
    }.run, .{});
}

const Listed = struct { owner: Owner, context: bool = false };

fn expectListing(expected: []const Listed, index: Index, state: State) !void {
    const listing = try buildListing(testing.allocator, &index, &state);
    defer testing.allocator.free(listing.entries);
    var actual: std.ArrayList(Listed) = .empty;
    defer actual.deinit(testing.allocator);
    var matches: usize = 0;
    for (listing.entries) |entry| {
        try actual.append(testing.allocator, .{ .owner = index.records[entry.record].owner, .context = entry.context });
        matches += @intFromBool(!entry.context);
    }
    try testing.expectEqualDeep(expected, actual.items);
    try testing.expectEqual(matches, listing.matches);
    try testing.expectEqual(index.records.len, listing.records);
}

fn queried(text: []const u8) State {
    var state: State = .{};
    state.setQuery(text);
    return state;
}

/// A resolved Comment Thread on `a.txt` with a Reply, a Review-level Comment
/// of the Authenticated Account, a File-level Comment on `a/b.txt`, and a
/// Draft root with a Draft Reply.
const filter_comments = [_]Comment{
    .{ .id = 1, .author = "Ada", .author_uuid = "{ada}", .body = "review wide", .scope = .review },
    .{ .id = 2, .author = "Bob", .author_uuid = "{bob}", .body = "inline root", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } }, .resolved = true },
    .{ .id = 3, .parent_id = 2, .author = "Cy", .author_uuid = "{cy}", .body = "zebra reply" },
    .{ .id = 4, .author = "Bob", .author_uuid = "{bob}", .body = "nested file", .scope = .{ .file = .{ .path = "a/b.txt", .source_commit = "abc" } } },
};
const filter_drafts = [_]Draft{
    .{ .local_id = 1, .kind = .comment, .body = "draft root" },
    .{ .local_id = 2, .kind = .comment, .body = "draft reply", .parent = .{ .comment = 4 } },
};

test "M29 overview the query matches the author, the body, and the path and keeps the order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const index = try (Fixture{ .comments = &filter_comments, .drafts = &filter_drafts, .account = "{ada}" }).index(arena.allocator());
    const all = [_]Listed{ .{ .owner = .{ .comment = 1 } }, .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .draft = 2 } }, .{ .owner = .{ .comment = 2 } }, .{ .owner = .{ .comment = 3 } } };
    try expectListing(&all, index, .{});
    try expectListing(&all, index, queried("  \t "));
    try expectListing(&.{ .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .comment = 2 } } }, index, queried("bob"));
    try expectListing(&.{ .{ .owner = .{ .comment = 2 }, .context = true }, .{ .owner = .{ .comment = 3 } } }, index, queried("zebra"));
    try expectListing(&.{ .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .draft = 2 } } }, index, queried("a/b.txt"));
    try expectListing(&.{ .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 }, .context = true }, .{ .owner = .{ .draft = 2 } } }, index, queried("draft"));
    try expectListing(&.{}, index, queried("zzzz"));
}

test "M29 overview each toggle keeps only matching items and the toggles combine with AND" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const index = try (Fixture{ .comments = &filter_comments, .drafts = &filter_drafts, .account = "{ada}" }).index(arena.allocator());
    try expectListing(&.{ .{ .owner = .{ .comment = 1 } }, .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .draft = 2 } } }, index, .{ .unresolved_only = true });
    try expectListing(&.{ .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 }, .context = true }, .{ .owner = .{ .draft = 2 } } }, index, .{ .drafts_only = true });
    try expectListing(&.{ .{ .owner = .{ .comment = 1 } }, .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 }, .context = true }, .{ .owner = .{ .draft = 2 } } }, index, .{ .mine_only = true });
    try expectListing(&.{ .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 }, .context = true }, .{ .owner = .{ .draft = 2 } } }, index, .{ .unresolved_only = true, .drafts_only = true, .mine_only = true });
    var draft_root = queried("root");
    draft_root.unresolved_only = true;
    try expectListing(&.{.{ .owner = .{ .draft = 1 } }}, index, draft_root);
}

test "M29 overview mine only keeps every Draft and only the Comments of the Authenticated Account" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts_only = [_]Listed{ .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 }, .context = true }, .{ .owner = .{ .draft = 2 } } };
    const cases = [_]struct { account: ?[]const u8, expected: []const Listed }{
        .{ .account = null, .expected = &drafts_only },
        .{ .account = "{nobody}", .expected = &drafts_only },
        .{ .account = "{ada}", .expected = &.{ .{ .owner = .{ .comment = 1 } }, .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 }, .context = true }, .{ .owner = .{ .draft = 2 } } } },
        .{ .account = "{bob}", .expected = &.{ .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .draft = 2 } }, .{ .owner = .{ .comment = 2 } } } },
    };
    for (cases) |case| {
        const index = try (Fixture{ .comments = &filter_comments, .drafts = &filter_drafts, .account = case.account }).index(arena.allocator());
        try expectListing(case.expected, index, .{ .mine_only = true });
    }
}

test "M29 overview a matching Reply keeps its ancestors as context entries outside the Title count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "root", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } } },
        .{ .id = 2, .parent_id = 1, .author = "Bob", .body = "middle" },
        .{ .id = 3, .parent_id = 2, .author = "Cy", .body = "zebra" },
        .{ .id = 4, .parent_id = 1, .author = "Dee", .body = "sibling" },
    };
    const index = try (Fixture{ .comments = &comments }).index(arena.allocator());
    try expectListing(&.{ .{ .owner = .{ .comment = 1 }, .context = true }, .{ .owner = .{ .comment = 2 }, .context = true }, .{ .owner = .{ .comment = 3 } } }, index, queried("zebra"));
    const listing = try buildListing(arena.allocator(), &index, &queried("zebra"));
    try testing.expectEqual(@as(usize, 1), listing.matches);
    try testing.expectEqual(@as(usize, 4), listing.records);
}

test "M29 overview newest first puts Draft Threads first, sorts Comment Threads by their newest CommentId, and keeps Replies under their parents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comments = [_]Comment{
        .{ .id = 10, .author = "Ada", .body = "old review" },
        .{ .id = 40, .parent_id = 10, .author = "Bob", .body = "newest reply" },
        .{ .id = 20, .author = "Ada", .body = "inline", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 2 } } },
        .{ .id = 30, .author = "Ada", .body = "file", .scope = .{ .file = .{ .path = "a/b.txt", .source_commit = "abc" } } },
        .{ .id = 21, .parent_id = 20, .author = "Bob", .body = "reply" },
        .{ .id = 22, .parent_id = 20, .author = "Cy", .body = "second reply" },
    };
    const drafts = [_]Draft{
        .{ .local_id = 1, .kind = .comment, .body = "older Draft root", .scope = .{ .@"inline" = .{ .path = "a.txt", .to = 3 } } },
        .{ .local_id = 2, .kind = .comment, .body = "newer Draft root" },
        .{ .local_id = 3, .kind = .comment, .body = "Draft Reply", .parent = .{ .comment = 30 } },
    };
    const index = try (Fixture{ .comments = &comments, .drafts = &drafts }).index(arena.allocator());
    try expectListing(&.{
        .{ .owner = .{ .comment = 10 } }, .{ .owner = .{ .comment = 40 } },
        .{ .owner = .{ .draft = 2 } },    .{ .owner = .{ .comment = 30 } },
        .{ .owner = .{ .draft = 3 } },    .{ .owner = .{ .comment = 20 } },
        .{ .owner = .{ .comment = 21 } }, .{ .owner = .{ .comment = 22 } },
        .{ .owner = .{ .draft = 1 } },
    }, index, .{});
    try expectListing(&.{
        .{ .owner = .{ .comment = 30 } }, .{ .owner = .{ .draft = 3 } },
        .{ .owner = .{ .draft = 2 } },    .{ .owner = .{ .draft = 1 } },
        .{ .owner = .{ .comment = 10 } }, .{ .owner = .{ .comment = 40 } },
        .{ .owner = .{ .comment = 20 } }, .{ .owner = .{ .comment = 21 } },
        .{ .owner = .{ .comment = 22 } },
    }, index, .{ .order = .newest_first });
    var replies = queried("reply");
    replies.order = .newest_first;
    try expectListing(&.{
        .{ .owner = .{ .comment = 30 }, .context = true }, .{ .owner = .{ .draft = 3 } },
        .{ .owner = .{ .comment = 10 }, .context = true }, .{ .owner = .{ .comment = 40 } },
        .{ .owner = .{ .comment = 20 }, .context = true }, .{ .owner = .{ .comment = 21 } },
        .{ .owner = .{ .comment = 22 } },
    }, index, replies);
}

test "M29 overview the File Tree Filter keeps the items of its File or of every File under its Directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const index = try (Fixture{ .comments = &filter_comments, .drafts = &filter_drafts }).index(arena.allocator());
    const nested = [_]Listed{ .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .draft = 2 } } };
    try expectListing(&.{ .{ .owner = .{ .comment = 2 } }, .{ .owner = .{ .comment = 3 } } }, index, .{ .file_tree_filter = .{ .file = 0 } });
    try expectListing(&nested, index, .{ .file_tree_filter = .{ .file = 1 } });
    try expectListing(&nested, index, .{ .file_tree_filter = .{ .directory = "a" } });
    try expectListing(&.{}, index, .{ .file_tree_filter = .{ .directory = "a/b" } });

    var state: State = .{ .file_tree_filter = .{ .file = 0 } };
    state.apply(.{ .file_tree_filter = .root });
    try testing.expectEqual(@as(?file_tree.Identity, null), state.file_tree_filter);
    try expectListing(&.{ .{ .owner = .{ .comment = 1 } }, .{ .owner = .{ .draft = 1 } }, .{ .owner = .{ .comment = 4 } }, .{ .owner = .{ .draft = 2 } }, .{ .owner = .{ .comment = 2 } }, .{ .owner = .{ .comment = 3 } } }, index, state);
}
