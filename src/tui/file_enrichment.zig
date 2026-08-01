//! File Enrichment owns the old/new full-file content and Highlighting attached
//! lazily to a File during a Session. See ADR-0010.

const std = @import("std");
const bbr = @import("bbr");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    repo: []const u8,
    status: bbr.diff.FileStatus,
    source_commit: []const u8,
    destination_commit: []const u8,
    old_path: []const u8,
    new_path: []const u8,
    max_file_bytes: usize,
};

pub const HighlightingView = union(enum) {
    ready: bbr.highlight.HighlightResult,
    skipped_too_large,
    failed: anyerror,
};

pub const ContentView = struct {
    blob: []const u8,
    highlighting: HighlightingView,
};

pub const SideView = union(enum) {
    pending,
    absent,
    fetch_failed: anyerror,
    content: ContentView,
};

pub const FileView = struct {
    old: SideView,
    new: SideView,
};

pub const SideErrors = struct { old: ?anyerror = null, new: ?anyerror = null };

pub const Projection = struct {
    blobs: []const bbr.diff.FileBlob,
    highlights: []const bbr.highlight.FileHighlights,
};

const OwnedSide = struct {
    arena: std.heap.ArenaAllocator,
    blob: []const u8,
    highlighting: HighlightingView,
    retained_bytes: usize,

    fn destroy(self: *OwnedSide) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }

    fn view(self: *const OwnedSide) ContentView {
        return .{ .blob = self.blob, .highlighting = self.highlighting };
    }
};

const SideResult = union(enum) {
    absent,
    fetch_failed: anyerror,
    owned: *OwnedSide,
    transferred,

    fn deinit(self: *SideResult) void {
        if (self.* == .owned) self.owned.destroy();
        self.* = .transferred;
    }
};

pub const Result = struct {
    old: SideResult,
    new: SideResult,

    pub fn deinit(self: *Result) void {
        self.old.deinit();
        self.new.deinit();
    }
};

pub fn enrich(backing: Allocator, bb: bbr.bitbucket.Client, highlighter: bbr.highlight.Highlighter, req: Request) error{OutOfMemory}!Result {
    var result: Result = .{ .old = .absent, .new = .absent };
    errdefer result.deinit();
    if (req.status != .added) {
        result.old = try enrichSide(backing, bb, highlighter, req.max_file_bytes, req.repo, req.destination_commit, req.old_path);
    }
    if (req.status != .removed) {
        result.new = try enrichSide(backing, bb, highlighter, req.max_file_bytes, req.repo, req.source_commit, req.new_path);
    }
    return result;
}

fn enrichSide(backing: Allocator, bb: bbr.bitbucket.Client, highlighter: bbr.highlight.Highlighter, max_file_bytes: usize, repo: []const u8, commit: []const u8, path: []const u8) error{OutOfMemory}!SideResult {
    const side = try backing.create(OwnedSide);
    errdefer backing.destroy(side);
    side.arena = std.heap.ArenaAllocator.init(backing);
    errdefer side.arena.deinit();
    const allocator = side.arena.allocator();

    side.blob = bb.getFileBlob(allocator, repo, commit, path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        side.destroy();
        return .{ .fetch_failed = err };
    };
    if (max_file_bytes != 0 and side.blob.len > max_file_bytes) {
        side.highlighting = .skipped_too_large;
        side.retained_bytes = retainedBytes(side);
        return .{ .owned = side };
    }
    const highlights = highlighter.highlight(allocator, path, side.blob) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        side.highlighting = .{ .failed = err };
        side.retained_bytes = retainedBytes(side);
        return .{ .owned = side };
    };
    side.highlighting = .{ .ready = highlights };
    side.retained_bytes = retainedBytes(side);
    return .{ .owned = side };
}

fn retainedBytes(side: *const OwnedSide) usize {
    // ArenaAllocator.queryCapacity excludes its internal linked-list nodes but
    // includes every allocation the owned side keeps alive: blob, Highlight
    // output, Capture names, and any scratch capacity not individually freed.
    return side.arena.queryCapacity();
}

const StoredSide = union(enum) {
    pending,
    absent,
    fetch_failed: anyerror,
    content: *OwnedSide,

    fn deinit(self: *StoredSide) void {
        if (self.* == .content) self.content.destroy();
        self.* = .pending;
    }

    fn view(self: StoredSide) SideView {
        return switch (self) {
            .pending => .pending,
            .absent => .absent,
            .fetch_failed => |err| .{ .fetch_failed = err },
            .content => |content| .{ .content = content.view() },
        };
    }
};

const StoredFile = struct {
    old: StoredSide = .pending,
    new: StoredSide = .pending,
    last_used: u64 = 0,

    fn deinit(self: *StoredFile) void {
        self.old.deinit();
        self.new.deinit();
    }

    fn retainedBytes(self: *const StoredFile) usize {
        var total: usize = 0;
        if (self.old == .content) total +|= self.old.content.retained_bytes;
        if (self.new == .content) total +|= self.new.content.retained_bytes;
        return total;
    }
};

pub const CachePolicy = struct {
    enabled: bool = true,
    max_retained_bytes: usize = std.math.maxInt(usize),
};

pub const Storage = struct {
    allocator: Allocator,
    files: []StoredFile,
    blobs: []bbr.diff.FileBlob,
    highlights: []bbr.highlight.FileHighlights,
    statuses: []bbr.highlight.FileHighlightStatus,
    errors: []SideErrors,
    cache: CachePolicy = .{},
    focused_file: ?usize = null,
    recency: u64 = 0,
    retired: std.ArrayList(RetiredFile) = .empty,

    pub fn init(allocator: Allocator, diff_files: []const bbr.diff.File) !Storage {
        const files = try allocator.alloc(StoredFile, diff_files.len);
        errdefer allocator.free(files);
        @memset(files, .{});
        const blobs = try allocator.alloc(bbr.diff.FileBlob, diff_files.len);
        errdefer allocator.free(blobs);
        @memset(blobs, .{});
        const highlights = try allocator.alloc(bbr.highlight.FileHighlights, diff_files.len);
        errdefer allocator.free(highlights);
        @memset(highlights, .{});
        const statuses = try allocator.alloc(bbr.highlight.FileHighlightStatus, diff_files.len);
        errdefer allocator.free(statuses);
        for (diff_files, 0..) |diff_file, i| {
            statuses[i] = .{
                .old = if (diff_file.status == .added) .absent else .pending,
                .new = if (diff_file.status == .removed) .absent else .pending,
            };
        }
        const errors = try allocator.alloc(SideErrors, diff_files.len);
        errdefer allocator.free(errors);
        @memset(errors, .{});
        var storage: Storage = .{
            .allocator = allocator,
            .files = files,
            .blobs = blobs,
            .highlights = highlights,
            .statuses = statuses,
            .errors = errors,
        };
        errdefer storage.retired.deinit(allocator);
        try storage.retired.ensureTotalCapacity(allocator, diff_files.len);
        return storage;
    }

    pub fn deinit(self: *Storage) void {
        for (self.retired.items) |*retired| retired.file.deinit();
        self.retired.deinit(self.allocator);
        for (self.files) |*stored_file| stored_file.deinit();
        self.allocator.free(self.files);
        self.allocator.free(self.blobs);
        self.allocator.free(self.highlights);
        self.allocator.free(self.statuses);
        self.allocator.free(self.errors);
        self.* = undefined;
    }

    pub fn admit(self: *Storage, file_idx: usize, result: *Result) error{ AlreadyTransferred, AlreadyAdmitted, FileOutOfRange }!void {
        _ = try self.stageAdmission(file_idx, result);
        self.commitCacheUpdate();
    }

    pub fn stageAdmission(self: *Storage, file_idx: usize, result: *Result) error{ AlreadyTransferred, AlreadyAdmitted, FileOutOfRange }!bool {
        std.debug.assert(self.retired.items.len == 0);
        if (file_idx >= self.files.len) return error.FileOutOfRange;
        if (result.old == .transferred or result.new == .transferred) return error.AlreadyTransferred;
        const stored = &self.files[file_idx];
        if (stored.old != .pending or stored.new != .pending) return error.AlreadyAdmitted;

        stored.old = transfer(&result.old);
        stored.new = transfer(&result.new);
        self.projectSide(file_idx, .old);
        self.projectSide(file_idx, .new);
        return self.stageCacheEnforcement();
    }

    pub fn configureCache(self: *Storage, policy: CachePolicy) void {
        std.debug.assert(!policy.enabled or policy.max_retained_bytes > 0);
        self.cache = policy;
        _ = self.stageCacheEnforcement();
        self.commitCacheUpdate();
    }

    pub fn focus(self: *Storage, file_idx: usize) void {
        _ = self.stageFocus(file_idx);
        self.commitCacheUpdate();
    }

    pub fn stageFocus(self: *Storage, file_idx: usize) bool {
        std.debug.assert(self.retired.items.len == 0);
        std.debug.assert(file_idx < self.files.len);
        self.recency +|= 1;
        self.files[file_idx].last_used = self.recency;
        self.focused_file = file_idx;
        return self.stageCacheEnforcement();
    }

    pub fn commitCacheUpdate(self: *Storage) void {
        for (self.retired.items) |*retired| retired.file.deinit();
        self.retired.clearRetainingCapacity();
    }

    pub fn rollbackCacheUpdate(self: *Storage) void {
        while (self.retired.pop()) |retired| {
            std.debug.assert(self.files[retired.index].retainedBytes() == 0);
            self.files[retired.index] = retired.file;
            self.projectSide(retired.index, .old);
            self.projectSide(retired.index, .new);
        }
    }

    pub fn file(self: *const Storage, file_idx: usize) FileView {
        std.debug.assert(file_idx < self.files.len);
        return .{ .old = self.files[file_idx].old.view(), .new = self.files[file_idx].new.view() };
    }

    pub fn len(self: *const Storage) usize {
        return self.files.len;
    }

    pub fn status(self: *const Storage, file_idx: usize) bbr.highlight.FileHighlightStatus {
        std.debug.assert(file_idx < self.statuses.len);
        return self.statuses[file_idx];
    }

    pub fn sideErrors(self: *const Storage, file_idx: usize) SideErrors {
        std.debug.assert(file_idx < self.errors.len);
        return self.errors[file_idx];
    }

    pub fn markLoading(self: *Storage, file_idx: usize) void {
        std.debug.assert(file_idx < self.statuses.len);
        if (self.statuses[file_idx].old == .pending) self.statuses[file_idx].old = .loading;
        if (self.statuses[file_idx].new == .pending) self.statuses[file_idx].new = .loading;
    }

    pub fn resetLoading(self: *Storage, file_idx: usize) void {
        std.debug.assert(file_idx < self.statuses.len);
        if (self.statuses[file_idx].old == .loading) self.statuses[file_idx].old = .pending;
        if (self.statuses[file_idx].new == .loading) self.statuses[file_idx].new = .pending;
    }

    pub fn needsEnrichment(self: *const Storage, file_idx: usize) bool {
        std.debug.assert(file_idx < self.statuses.len);
        const file_status = self.statuses[file_idx];
        return sideNeedsEnrichment(file_status.old) or sideNeedsEnrichment(file_status.new);
    }

    pub fn projection(self: *const Storage) Projection {
        return .{ .blobs = self.blobs, .highlights = self.highlights };
    }

    fn projectSide(self: *Storage, file_idx: usize, comptime which: enum { old, new }) void {
        const stored = @field(self.files[file_idx], @tagName(which));
        const blob_slot = &@field(self.blobs[file_idx], @tagName(which));
        const highlight_slot = &@field(self.highlights[file_idx], @tagName(which));
        const status_slot = &@field(self.statuses[file_idx], @tagName(which));
        const error_slot = &@field(self.errors[file_idx], @tagName(which));
        blob_slot.* = null;
        highlight_slot.* = null;
        error_slot.* = null;
        switch (stored) {
            .pending => status_slot.* = .pending,
            .absent => status_slot.* = .absent,
            .fetch_failed => |err| {
                status_slot.* = .fetch_failed;
                error_slot.* = err;
            },
            .content => |content| {
                blob_slot.* = content.blob;
                switch (content.highlighting) {
                    .ready => |ready| {
                        highlight_slot.* = ready;
                        status_slot.* = .ready;
                    },
                    .skipped_too_large => status_slot.* = .skipped_too_large,
                    .failed => |err| {
                        status_slot.* = .highlight_failed;
                        error_slot.* = err;
                    },
                }
            },
        }
    }

    fn stageCacheEnforcement(self: *Storage) bool {
        const budget = if (self.cache.enabled) self.cache.max_retained_bytes else 0;
        var changed = false;
        while (self.inactiveRetainedBytes() > budget) {
            const victim = self.leastRecentlyUsedInactive() orelse break;
            self.retired.appendAssumeCapacity(.{ .index = victim, .file = self.files[victim] });
            self.files[victim] = .{ .last_used = self.files[victim].last_used };
            self.projectSide(victim, .old);
            self.projectSide(victim, .new);
            changed = true;
        }
        return changed;
    }

    fn inactiveRetainedBytes(self: *const Storage) usize {
        var total: usize = 0;
        for (self.files, 0..) |*stored_file, file_idx| {
            if (self.focused_file != null and self.focused_file.? == file_idx) continue;
            total +|= stored_file.retainedBytes();
        }
        return total;
    }

    fn leastRecentlyUsedInactive(self: *const Storage) ?usize {
        var victim: ?usize = null;
        for (self.files, 0..) |*stored_file, file_idx| {
            if (self.focused_file != null and self.focused_file.? == file_idx) continue;
            if (stored_file.retainedBytes() == 0) continue;
            if (victim == null or stored_file.last_used < self.files[victim.?].last_used) victim = file_idx;
        }
        return victim;
    }
};

const RetiredFile = struct {
    index: usize,
    file: StoredFile,
};

fn sideNeedsEnrichment(state: bbr.highlight.SideState) bool {
    return switch (state) {
        .pending => true,
        .loading, .absent, .ready, .skipped_too_large, .fetch_failed, .highlight_failed => false,
    };
}

fn transfer(side: *SideResult) StoredSide {
    const stored: StoredSide = switch (side.*) {
        .absent => .absent,
        .fetch_failed => |err| .{ .fetch_failed = err },
        .owned => |owned| .{ .content = owned },
        .transferred => unreachable,
    };
    side.* = .transferred;
    return stored;
}

const testing = std.testing;

fn oneTestFile(status: bbr.diff.FileStatus) [1]bbr.diff.File {
    return .{.{ .old_path = "src/main.ts", .new_path = "src/main.ts", .status = status, .hunks = &.{} }};
}

const test_files = [_]bbr.diff.File{
    .{ .old_path = "/dev/null", .new_path = "a.zig", .status = .added, .hunks = &.{} },
    .{ .old_path = "/dev/null", .new_path = "b.zig", .status = .added, .hunks = &.{} },
    .{ .old_path = "/dev/null", .new_path = "c.zig", .status = .added, .hunks = &.{} },
};

fn ownedAddedResult(backing: Allocator, blob: []const u8) !Result {
    const side = try backing.create(OwnedSide);
    errdefer backing.destroy(side);
    side.arena = std.heap.ArenaAllocator.init(backing);
    errdefer side.arena.deinit();
    side.blob = try side.arena.allocator().dupe(u8, blob);
    side.highlighting = .{ .ready = .{ .spans = &.{} } };
    side.retained_bytes = side.blob.len;
    return .{ .old = .absent, .new = .{ .owned = side } };
}

const ScriptedHighlighter = struct {
    fn highlighter(self: *ScriptedHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlight };

    fn highlight(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!bbr.highlight.HighlightResult {
        const spans = try allocator.alloc(bbr.highlight.Span, 1);
        spans[0] = .{
            .line = 1,
            .start = 0,
            .end = 5,
            .capture = .{ .name = try allocator.dupe(u8, "keyword") },
        };
        return .{ .spans = spans };
    }
};

const FailingHighlighter = struct {
    fn highlighter(self: *FailingHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlight };

    fn highlight(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!bbr.highlight.HighlightResult {
        return error.InvalidCapture;
    }
};

test "an added File transfers its enriched new side into Session storage" {
    const responses = [_]bbr.http.Canned{.{ .status = 200, .body = "const answer = 42;\n" }};
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var scripted = ScriptedHighlighter{};

    var result = try enrich(testing.allocator, bb, scripted.highlighter(), .{
        .repo = "repo",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "/dev/null",
        .new_path = "src/main.ts",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = oneTestFile(.added);
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);

    const projected = storage.file(0);
    try testing.expect(projected.old == .absent);
    try testing.expectEqualStrings("const answer = 42;\n", projected.new.content.blob);
    try testing.expectEqual(@as(usize, 1), projected.new.content.highlighting.ready.spans.len);
    try testing.expectEqualStrings("keyword", projected.new.content.highlighting.ready.spans[0].capture.name);
    try testing.expectError(error.AlreadyTransferred, storage.admit(0, &result));
}

test "fetched content remains usable when Highlighting fails" {
    const responses = [_]bbr.http.Canned{.{ .status = 200, .body = "const answer = 42;\n" }};
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var failing = FailingHighlighter{};

    var result = try enrich(testing.allocator, bb, failing.highlighter(), .{
        .repo = "repo",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "/dev/null",
        .new_path = "src/main.ts",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = oneTestFile(.added);
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);

    const projected = storage.file(0);
    try testing.expectEqualStrings("const answer = 42;\n", projected.new.content.blob);
    try testing.expect(projected.new.content.highlighting == .failed);
    try testing.expectEqual(error.InvalidCapture, projected.new.content.highlighting.failed);
}

test "a failed old-side fetch does not suppress the enriched new side" {
    const responses = [_]bbr.http.Canned{
        .{ .status = 404, .body = "" },
        .{ .status = 200, .body = "const current = true;\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var scripted = ScriptedHighlighter{};

    var result = try enrich(testing.allocator, bb, scripted.highlighter(), .{
        .repo = "repo",
        .status = .modified,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "src/main.ts",
        .new_path = "src/main.ts",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = oneTestFile(.modified);
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);

    const projected = storage.file(0);
    try testing.expect(projected.old == .fetch_failed);
    try testing.expectEqual(error.NotFound, projected.old.fetch_failed);
    try testing.expectEqualStrings("const current = true;\n", projected.new.content.blob);
    try testing.expect(projected.new.content.highlighting == .ready);
}

fn exerciseAddedFileOwnership(allocator: Allocator) !void {
    const responses = [_]bbr.http.Canned{.{ .status = 200, .body = "const answer = 42;\n" }};
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var scripted = ScriptedHighlighter{};

    var result = try enrich(allocator, bb, scripted.highlighter(), .{
        .repo = "repo",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "/dev/null",
        .new_path = "src/main.ts",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = oneTestFile(.added);
    var storage = try Storage.init(allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);
}

test "File Enrichment reclaims ownership at every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseAddedFileOwnership, .{});
}

test "File content cache evicts the least-recently-focused whole File and refetches it on revisit" {
    var storage = try Storage.init(testing.allocator, test_files[0..3]);
    defer storage.deinit();
    storage.configureCache(.{ .enabled = true, .max_retained_bytes = 10 });

    storage.focus(0);
    var first = try ownedAddedResult(testing.allocator, "aaaaaa");
    defer first.deinit();
    try storage.admit(0, &first);

    storage.focus(1);
    var second = try ownedAddedResult(testing.allocator, "bbbbbb");
    defer second.deinit();
    try storage.admit(1, &second);

    storage.focus(2);
    try testing.expect(storage.file(0).new == .pending);
    try testing.expect(storage.needsEnrichment(0));
    try testing.expectEqualStrings("bbbbbb", storage.file(1).new.content.blob);

    storage.focus(0);
    var revisited = try ownedAddedResult(testing.allocator, "AAAAAA");
    defer revisited.deinit();
    try storage.admit(0, &revisited);
    try testing.expectEqualStrings("AAAAAA", storage.file(0).new.content.blob);
}

test "File content cache budget includes Highlight Spans and Capture names" {
    const responses = [_]bbr.http.Canned{.{ .status = 200, .body = "const" }};
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var scripted = ScriptedHighlighter{};
    var result = try enrich(testing.allocator, bb, scripted.highlighter(), .{
        .repo = "repo",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "/dev/null",
        .new_path = "a.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    var storage = try Storage.init(testing.allocator, test_files[0..2]);
    defer storage.deinit();
    storage.configureCache(.{ .enabled = true, .max_retained_bytes = "const".len });
    storage.focus(0);
    try storage.admit(0, &result);
    try testing.expectEqualStrings("keyword", storage.file(0).new.content.highlighting.ready.spans[0].capture.name);

    storage.focus(1);
    try testing.expect(storage.file(0).new == .pending);
}
