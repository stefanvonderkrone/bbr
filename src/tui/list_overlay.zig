//! List Overlays: Overlays made of one query line and one fuzzy-ranked list
//! with one selection. `FuzzyList` owns the query, the ranked matches, and the
//! selection for every one of them. It never owns or borrows items: each list
//! passes a haystack value on refilter, so a borrow stays visible in the list
//! that holds it.
//!
//! A haystack is any value with:
//!     fn len(self) usize
//!     fn score(self, index: usize, query: Query) ?f64
//! `score` returns null to exclude the item. Higher scores rank first, and
//! ties keep item order.

const std = @import("std");
const zf = @import("zf");
const bbr = @import("bbr");

const Allocator = std.mem.Allocator;
const PullRequestSummary = bbr.bitbucket.PullRequestSummary;
const File = bbr.diff.File;

/// Max whitespace-separated needles honored in a query; extra words are ignored.
const max_needles = 8;

pub const FuzzyList = struct {
    allocator: Allocator,
    /// Item indices in rank order, best first. Length `match_count`.
    match_buf: []usize = &.{},
    /// Score of each match, parallel to `match_buf`.
    score_buf: []f64 = &.{},
    match_count: usize = 0,
    /// Cursor into `match_buf[0..match_count]`.
    selected: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    pub fn query(self: *const FuzzyList) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// Item indices of the visible matches, best first.
    pub fn matches(self: *const FuzzyList) []const usize {
        return self.match_buf[0..self.match_count];
    }

    /// The item index under the cursor, or null when nothing matches.
    pub fn selectedItem(self: *const FuzzyList) ?usize {
        return if (self.match_count == 0) null else self.match_buf[self.selected];
    }

    /// First visible match row for a viewport of `rows` rows. Paint and
    /// hit-testing both call this, so they cannot disagree.
    pub fn scrollTop(self: *const FuzzyList, rows: usize) usize {
        if (rows == 0 or self.selected < rows) return 0;
        return self.selected - rows + 1;
    }

    fn init(allocator: Allocator, item_count: usize) Allocator.Error!FuzzyList {
        var self: FuzzyList = .{ .allocator = allocator };
        try self.resize(item_count);
        return self;
    }

    /// Size the buffers for a new item set and keep the query. On failure the
    /// old buffers stay intact.
    fn resize(self: *FuzzyList, item_count: usize) Allocator.Error!void {
        const match_buf = try self.allocator.alloc(usize, item_count);
        errdefer self.allocator.free(match_buf);
        const score_buf = try self.allocator.alloc(f64, item_count);
        self.allocator.free(self.match_buf);
        self.allocator.free(self.score_buf);
        self.match_buf = match_buf;
        self.score_buf = score_buf;
        self.match_count = 0;
    }

    fn deinit(self: *FuzzyList) void {
        self.allocator.free(self.match_buf);
        self.allocator.free(self.score_buf);
        self.* = undefined;
    }

    fn appendQuery(self: *FuzzyList, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.query_len == self.query_buf.len) break;
            self.query_buf[self.query_len] = byte;
            self.query_len += 1;
        }
    }

    fn popQuery(self: *FuzzyList) void {
        if (self.query_len > 0) self.query_len -= 1;
    }

    fn moveUp(self: *FuzzyList) void {
        if (self.selected > 0) self.selected -= 1;
    }

    fn moveDown(self: *FuzzyList) void {
        if (self.selected + 1 < self.match_count) self.selected += 1;
    }

    /// Select match row `row`. Out of range is a no-op.
    fn selectRow(self: *FuzzyList, row: usize) void {
        if (row < self.match_count) self.selected = row;
    }

    /// Put the cursor on the match row that shows item `item`, if visible.
    fn selectItem(self: *FuzzyList, item: usize) void {
        for (self.matches(), 0..) |candidate, row| if (candidate == item) {
            self.selected = row;
            return;
        };
    }

    /// Recompute the matches from the current query. A blank query matches
    /// every item in item order. The cursor is clamped into the new set.
    fn refilter(self: *FuzzyList, haystack: anytype) void {
        const text = std.mem.trim(u8, self.query(), " \t");
        const item_count = haystack.len();
        std.debug.assert(item_count <= self.match_buf.len);
        if (text.len == 0) {
            for (0..item_count) |index| self.match_buf[index] = index;
            self.match_count = item_count;
            self.clamp();
            return;
        }

        var needles: [max_needles][]const u8 = undefined;
        var needle_count: usize = 0;
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        while (words.next()) |word| {
            if (needle_count == needles.len) break;
            needles[needle_count] = word;
            needle_count += 1;
        }
        const parsed: Query = .{ .text = text, .needles = needles[0..needle_count] };

        var count: usize = 0;
        for (0..item_count) |index| {
            const score = haystack.score(index, parsed) orelse continue;
            self.match_buf[count] = index;
            self.score_buf[count] = score;
            count += 1;
        }
        self.match_count = count;

        // Stable insertion sort, best first: every list is small.
        var unsorted: usize = 1;
        while (unsorted < count) : (unsorted += 1) {
            const item = self.match_buf[unsorted];
            const score = self.score_buf[unsorted];
            var slot = unsorted;
            while (slot > 0 and self.score_buf[slot - 1] < score) : (slot -= 1) {
                self.match_buf[slot] = self.match_buf[slot - 1];
                self.score_buf[slot] = self.score_buf[slot - 1];
            }
            self.match_buf[slot] = item;
            self.score_buf[slot] = score;
        }
        self.clamp();
    }

    fn clamp(self: *FuzzyList) void {
        if (self.match_count == 0) {
            self.selected = 0;
        } else if (self.selected >= self.match_count) {
            self.selected = self.match_count - 1;
        }
    }
};

/// A trimmed, non-blank query and its whitespace-separated needles.
pub const Query = struct {
    text: []const u8,
    needles: []const []const u8,

    /// Rank `haystack` against every needle.
    pub fn rank(self: Query, haystack: []const u8) ?f64 {
        return zf.rank(haystack, self.needles, .{ .plain = true, .case_sensitive = false });
    }

    /// Rank `haystack` against the whole query as one needle.
    pub fn rankText(self: Query, haystack: []const u8) ?f64 {
        return zf.rank(haystack, &.{self.text}, .{ .plain = true, .case_sensitive = false });
    }
};

/// The PullRequest Picker. While its summaries load it shows a spinner and
/// still accepts a query, which applies the moment `populate` runs.
pub const Picker = struct {
    list: FuzzyList,
    prs: []const PullRequestSummary = &.{},
    loading: bool = false,
    spinner_phase: u3 = 0,

    /// A ready Picker over `prs`. `prs` must outlive the Picker.
    pub fn init(allocator: Allocator, prs: []const PullRequestSummary) Allocator.Error!Picker {
        var self = initLoading(allocator);
        try self.populate(prs);
        return self;
    }

    /// An empty loading Picker. It allocates nothing, so it cannot fail.
    pub fn initLoading(allocator: Allocator) Picker {
        return .{ .list = .{ .allocator = allocator }, .loading = true };
    }

    /// Fill a loading Picker and refilter with any query typed while it
    /// loaded. `prs` must outlive the Picker.
    pub fn populate(self: *Picker, prs: []const PullRequestSummary) Allocator.Error!void {
        try self.list.resize(prs.len);
        self.prs = prs;
        self.loading = false;
        self.refilter();
    }

    pub fn deinit(self: *Picker) void {
        self.list.deinit();
        self.* = undefined;
    }

    pub fn query(self: *const Picker) []const u8 {
        return self.list.query();
    }

    pub fn matches(self: *const Picker) []const usize {
        return self.list.matches();
    }

    /// The PullRequest under the cursor, or null when nothing matches.
    pub fn selection(self: *const Picker) ?PullRequestSummary {
        return self.prs[self.list.selectedItem() orelse return null];
    }

    pub fn moveDown(self: *Picker) void {
        self.list.moveDown();
    }

    pub fn moveUp(self: *Picker) void {
        self.list.moveUp();
    }

    pub fn select(self: *Picker, row: usize) void {
        self.list.selectRow(row);
    }

    pub fn insert(self: *Picker, bytes: []const u8) void {
        self.list.appendQuery(bytes);
        self.refilter();
    }

    pub fn backspace(self: *Picker) void {
        self.list.popQuery();
        self.refilter();
    }

    pub fn tick(self: *Picker) void {
        if (self.loading) self.spinner_phase +%= 1;
    }

    pub fn spinnerGlyph(self: *const Picker) []const u8 {
        return spinner_glyphs[self.spinner_phase];
    }

    fn refilter(self: *Picker) void {
        self.list.refilter(PullRequestHaystack{ .prs = self.prs });
    }
};

const spinner_glyphs = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };

/// Ranks semantic fields independently so title relevance wins over an
/// incidental bare id, branch, or author hit. `#N` is the explicit direct-id
/// route and bypasses title-first ranking.
const PullRequestHaystack = struct {
    prs: []const PullRequestSummary,

    fn len(self: PullRequestHaystack) usize {
        return self.prs.len;
    }

    fn score(self: PullRequestHaystack, index: usize, q: Query) ?f64 {
        const pr = self.prs[index];
        var id_buf: [32]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{pr.id}) catch return null;
        if (q.text.len > 1 and q.text[0] == '#') return if (std.mem.eql(u8, q.text[1..], id_text)) 10000 else null;
        if (q.rank(pr.title)) |rank| return rank + 3000;
        if (q.rank(pr.source_branch)) |rank| return rank + 2000;
        if (q.rank(pr.author_display_name)) |rank| return rank + 1000;
        return q.rank(id_text);
    }
};

/// The Session-local File finder. It borrows the Diff's Files, so it must
/// close before the Session that owns them is destroyed.
pub const FileFinder = struct {
    list: FuzzyList,
    files: []const File,

    pub fn init(allocator: Allocator, files: []const File) Allocator.Error!FileFinder {
        var self: FileFinder = .{ .list = try FuzzyList.init(allocator, files.len), .files = files };
        self.refilter();
        return self;
    }

    pub fn deinit(self: *FileFinder) void {
        self.list.deinit();
        self.* = undefined;
    }

    pub fn query(self: *const FileFinder) []const u8 {
        return self.list.query();
    }

    pub fn matches(self: *const FileFinder) []const usize {
        return self.list.matches();
    }

    pub fn selection(self: *const FileFinder) ?usize {
        return self.list.selectedItem();
    }

    pub fn moveDown(self: *FileFinder) void {
        self.list.moveDown();
    }

    pub fn moveUp(self: *FileFinder) void {
        self.list.moveUp();
    }

    pub fn select(self: *FileFinder, row: usize) void {
        self.list.selectRow(row);
    }

    pub fn insert(self: *FileFinder, bytes: []const u8) void {
        self.list.appendQuery(bytes);
        self.refilter();
    }

    pub fn backspace(self: *FileFinder) void {
        self.list.popQuery();
        self.refilter();
    }

    fn refilter(self: *FileFinder) void {
        self.list.refilter(FileHaystack{ .files = self.files });
    }
};

/// A basename match ranks above any match found only in the full path.
const FileHaystack = struct {
    files: []const File,

    fn len(self: FileHaystack) usize {
        return self.files.len;
    }

    fn score(self: FileHaystack, index: usize, q: Query) ?f64 {
        const path = self.files[index].displayPath();
        if (q.rankText(std.fs.path.basename(path))) |rank| return rank + 1000;
        return q.rankText(path);
    }
};

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

test "title ranks ahead of bare id while hash id is direct" {
    const prs = [_]PullRequestSummary{
        .{ .id = 15, .title = "Routine cleanup", .state = "OPEN", .author_display_name = "Ada", .source_branch = "cleanup", .destination_branch = "main" },
        .{ .id = 42, .title = "M15 navigation polish", .state = "OPEN", .author_display_name = "Grace", .source_branch = "navigation", .destination_branch = "main" },
    };
    var p = try Picker.init(testing.allocator, &prs);
    defer p.deinit();
    p.insert("15");
    try testing.expectEqual(@as(u64, 42), p.selection().?.id);
    p.backspace();
    p.backspace();
    p.insert("#15");
    try testing.expectEqual(@as(u64, 15), p.selection().?.id);
    try testing.expectEqual(@as(usize, 1), p.matches().len);
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
    p.moveUp();
    try testing.expectEqual(@as(usize, 0), p.list.selected);
    p.moveDown();
    p.moveDown();
    p.moveDown();
    try testing.expectEqual(@as(usize, 2), p.list.selected);
}

test "a loading picker has no matches until populated" {
    var p = Picker.initLoading(testing.allocator);
    defer p.deinit();
    try testing.expect(p.loading);
    try testing.expectEqual(@as(usize, 0), p.matches().len);
    try testing.expect(p.selection() == null);

    p.insert("nav");
    try testing.expectEqual(@as(usize, 0), p.matches().len);

    try p.populate(samplePrs());
    try testing.expect(!p.loading);
    try testing.expectEqual(@as(usize, 1), p.matches().len);
    try testing.expectEqual(@as(u64, 11), p.selection().?.id);
}

test "loading Picker spinner advances one fixed-width glyph per scoped tick" {
    var p = Picker.initLoading(testing.allocator);
    defer p.deinit();
    try testing.expectEqualStrings("\xe2\xa0\x8b", p.spinnerGlyph());
    p.tick();
    try testing.expectEqualStrings("\xe2\xa0\x99", p.spinnerGlyph());
    try p.populate(&.{});
    p.tick();
    try testing.expectEqualStrings("\xe2\xa0\x99", p.spinnerGlyph());
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
    p.moveDown();
    p.insert("diff");
    try testing.expectEqual(@as(usize, 0), p.list.selected);
    try testing.expectEqual(@as(u64, 10), p.selection().?.id);
}

test "File finder ranks a basename match above a path-only match" {
    const files = [_]File{
        .{ .old_path = "src/finder/main.zig", .new_path = "src/finder/main.zig", .status = .modified, .hunks = &.{} },
        .{ .old_path = "src/finder.zig", .new_path = "src/finder.zig", .status = .modified, .hunks = &.{} },
    };
    var finder = try FileFinder.init(testing.allocator, &files);
    defer finder.deinit();
    try testing.expectEqual(@as(usize, 2), finder.matches().len);
    finder.insert("finder");
    try testing.expectEqual(@as(usize, 1), finder.selection().?);
    try testing.expectEqual(@as(usize, 2), finder.matches().len);
}

test "scroll top keeps the selected row inside the viewport" {
    var p = try Picker.init(testing.allocator, samplePrs());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.list.scrollTop(2));
    p.moveDown();
    p.moveDown();
    try testing.expectEqual(@as(usize, 1), p.list.scrollTop(2));
    try testing.expectEqual(@as(usize, 0), p.list.scrollTop(0));
}
