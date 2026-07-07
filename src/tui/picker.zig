//! The PR Picker's state machine: a fuzzy-filtered, navigable list of pull
//! requests. Pure — it owns no terminal, only the query string, the ranked set
//! of visible matches, and the cursor. `app.zig` drives it from key events and
//! renders `matches()`; ranking is delegated to zf so it matches the finder
//! feel reviewers expect.
//!
//! Each PR is flattened into one searchable haystack ("#id title branch author")
//! so a query hits any of those. Haystacks and the match buffers are owned by
//! the allocator passed to `init` (free with `deinit`, or pass an arena).

const std = @import("std");
const zf = @import("zf");
const bbr = @import("bbr");

const PullRequestSummary = bbr.bitbucket.PullRequestSummary;

/// Max whitespace-separated needles honored in a query; extra words are ignored.
const max_needles = 8;

pub const Picker = struct {
    allocator: std.mem.Allocator,
    prs: []const PullRequestSummary,
    /// One searchable string per PR, index-aligned with `prs`.
    haystacks: [][]const u8,

    /// Indices into `prs`, in rank order (best first). Length `match_count`.
    match_buf: []usize,
    /// zf score of each surviving match, parallel to `match_buf`.
    score_buf: []f64,
    match_count: usize,

    /// Cursor within `match_buf[0..match_count]`.
    selected: usize = 0,

    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    /// True until the background summaries fetch arrives (async open, app.zig).
    /// A loading Picker shows a placeholder; it still accepts query input, which
    /// is applied against the list the moment `populate` runs.
    loading: bool = false,
    /// Whether `haystacks`/`match_buf`/`score_buf` are heap allocations we own.
    /// A loading Picker that is never populated owns nothing to free.
    populated: bool = false,

    /// A ready Picker over `prs` (the synchronous path; also used by tests).
    pub fn init(allocator: std.mem.Allocator, prs: []const PullRequestSummary) !Picker {
        var self = initLoading(allocator);
        try self.populate(prs);
        return self;
    }

    /// An empty Picker in the loading state — no allocation, so it cannot fail.
    /// `populate` fills it once the summaries fetch returns.
    pub fn initLoading(allocator: std.mem.Allocator) Picker {
        return .{
            .allocator = allocator,
            .prs = &.{},
            .haystacks = &.{},
            .match_buf = &.{},
            .score_buf = &.{},
            .match_count = 0,
            .loading = true,
        };
    }

    /// Fill a (loading) Picker with the fetched summaries: build the haystacks
    /// and match buffers, clear the loading flag, and re-filter with any query
    /// the reviewer typed while it was loading. `prs` must outlive the Picker.
    pub fn populate(self: *Picker, prs: []const PullRequestSummary) !void {
        const haystacks = try self.allocator.alloc([]const u8, prs.len);
        errdefer self.allocator.free(haystacks);
        var built: usize = 0;
        errdefer for (haystacks[0..built]) |h| self.allocator.free(h);
        for (prs, 0..) |pr, i| {
            haystacks[i] = try std.fmt.allocPrint(self.allocator, "#{d} {s} {s} {s}", .{
                pr.id, pr.title, pr.source_branch, pr.author_display_name,
            });
            built += 1;
        }

        const match_buf = try self.allocator.alloc(usize, prs.len);
        errdefer self.allocator.free(match_buf);
        const score_buf = try self.allocator.alloc(f64, prs.len);
        errdefer self.allocator.free(score_buf);

        self.prs = prs;
        self.haystacks = haystacks;
        self.match_buf = match_buf;
        self.score_buf = score_buf;
        self.populated = true;
        self.loading = false;
        self.refilter();
    }

    pub fn deinit(self: *Picker) void {
        if (self.populated) {
            for (self.haystacks) |h| self.allocator.free(h);
            self.allocator.free(self.haystacks);
            self.allocator.free(self.match_buf);
            self.allocator.free(self.score_buf);
        }
        self.* = undefined;
    }

    pub fn query(self: *const Picker) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// Indices (into `prs`) of the currently visible matches, best-ranked first.
    pub fn matches(self: *const Picker) []const usize {
        return self.match_buf[0..self.match_count];
    }

    /// The PR under the cursor, or null when nothing matches.
    pub fn selection(self: *const Picker) ?PullRequestSummary {
        if (self.match_count == 0) return null;
        return self.prs[self.match_buf[self.selected]];
    }

    pub fn moveDown(self: *Picker) void {
        if (self.match_count == 0) return;
        if (self.selected + 1 < self.match_count) self.selected += 1;
    }

    pub fn moveUp(self: *Picker) void {
        if (self.selected > 0) self.selected -= 1;
    }

    /// Append typed bytes to the query and re-filter.
    pub fn insert(self: *Picker, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.query_len == self.query_buf.len) break;
            self.query_buf[self.query_len] = b;
            self.query_len += 1;
        }
        self.refilter();
    }

    /// Delete the last query byte and re-filter. No-op on an empty query.
    pub fn backspace(self: *Picker) void {
        if (self.query_len == 0) return;
        self.query_len -= 1;
        self.refilter();
    }

    /// Recompute `match_buf` from the current query. An empty (or blank) query
    /// matches every PR in input order; otherwise entries are ranked by zf and
    /// sorted best-first. The cursor is clamped into the new match set.
    fn refilter(self: *Picker) void {
        const q = std.mem.trim(u8, self.query(), " \t");

        if (q.len == 0) {
            for (self.prs, 0..) |_, i| self.match_buf[i] = i;
            self.match_count = self.prs.len;
            self.clampSelection();
            return;
        }

        // Split the query into needles on whitespace (bounded).
        var needles: [max_needles][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, q, ' ');
        while (it.next()) |tok| {
            if (n == needles.len) break;
            needles[n] = tok;
            n += 1;
        }

        // Rank every haystack; keep those that match, tracking their score.
        var count: usize = 0;
        for (self.haystacks, 0..) |h, i| {
            if (zf.rank(h, needles[0..n], .{ .plain = true, .case_sensitive = false })) |r| {
                self.match_buf[count] = i;
                self.score_buf[count] = r;
                count += 1;
            }
        }
        self.match_count = count;

        // Sort indices by score descending (insertion sort — the set is small:
        // the open PRs of one repo).
        var a: usize = 1;
        while (a < count) : (a += 1) {
            const idx = self.match_buf[a];
            const sc = self.score_buf[a];
            var b: usize = a;
            while (b > 0 and self.score_buf[b - 1] < sc) : (b -= 1) {
                self.match_buf[b] = self.match_buf[b - 1];
                self.score_buf[b] = self.score_buf[b - 1];
            }
            self.match_buf[b] = idx;
            self.score_buf[b] = sc;
        }

        self.clampSelection();
    }

    fn clampSelection(self: *Picker) void {
        if (self.match_count == 0) {
            self.selected = 0;
        } else if (self.selected >= self.match_count) {
            self.selected = self.match_count - 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn samplePrs() []const PullRequestSummary {
    return &.{
        .{ .id = 10, .title = "Add diff parser", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/diff", .destination_branch = "main" },
        .{ .id = 11, .title = "Fix navigation", .state = "OPEN", .author_display_name = "Grace", .source_branch = "feature/nav", .destination_branch = "main" },
        .{ .id = 12, .title = "Comment threads", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/comments", .destination_branch = "main" },
    };
}

test "empty query matches every PR in order" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.matches().len);
    try testing.expectEqual(@as(u64, 10), p.selection().?.id);
}

test "a query narrows to fuzzy matches" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    p.insert("nav");
    try testing.expectEqual(@as(usize, 1), p.matches().len);
    try testing.expectEqual(@as(u64, 11), p.selection().?.id);
}

test "matching by id and by author" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    p.insert("12");
    try testing.expectEqual(@as(u64, 12), p.selection().?.id);

    p.backspace();
    p.backspace();
    p.insert("Grace");
    try testing.expectEqual(@as(u64, 11), p.selection().?.id);
}

test "no match yields a null selection" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    p.insert("zzzznope");
    try testing.expectEqual(@as(usize, 0), p.matches().len);
    try testing.expect(p.selection() == null);
}

test "navigation clamps at both ends" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    p.moveUp(); // already at top
    try testing.expectEqual(@as(usize, 0), p.selected);
    p.moveDown();
    p.moveDown();
    p.moveDown(); // clamps at 2 (three matches)
    try testing.expectEqual(@as(usize, 2), p.selected);
}

test "a loading picker has no matches until populated" {
    var p = Picker.initLoading(testing.allocator);
    defer p.deinit();
    try testing.expect(p.loading);
    try testing.expectEqual(@as(usize, 0), p.matches().len);
    try testing.expect(p.selection() == null);

    // A query typed while loading is retained and applied on populate.
    p.insert("nav");
    try testing.expectEqual(@as(usize, 0), p.matches().len);

    try p.populate(samplePrs());
    try testing.expect(!p.loading);
    try testing.expectEqual(@as(usize, 1), p.matches().len);
    try testing.expectEqual(@as(u64, 11), p.selection().?.id);
}

test "populate with an empty list leaves a ready, empty picker" {
    var p = Picker.initLoading(testing.allocator);
    defer p.deinit();
    try p.populate(&.{});
    try testing.expect(!p.loading);
    try testing.expectEqual(@as(usize, 0), p.matches().len);
    try testing.expect(p.selection() == null);
}

test "selection is clamped when the query shrinks the match set" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    p.moveDown();
    p.moveDown(); // selected = 2
    p.insert("diff"); // now only one match
    try testing.expectEqual(@as(usize, 0), p.selected);
    try testing.expectEqual(@as(u64, 10), p.selection().?.id);
}
