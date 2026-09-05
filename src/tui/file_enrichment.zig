//! File Enrichment owns the old/new full-file content and Highlighting attached
//! lazily to a File during a Session. See ADR-0010.

const std = @import("std");
const bbr = @import("bbr");

const Allocator = std.mem.Allocator;

pub const BlobSource = struct {
    ptr: *anyopaque,
    read_fn: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror![]u8,

    pub fn read(self: BlobSource, allocator: Allocator, commit: []const u8, path: []const u8) ![]u8 {
        return self.read_fn(self.ptr, allocator, commit, path);
    }
};

pub const RemoteBlobSource = struct {
    client: bbr.bitbucket.Client,
    repo: []const u8,

    pub fn source(self: *RemoteBlobSource) BlobSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, allocator: Allocator, commit: []const u8, path: []const u8) anyerror![]u8 {
        const self: *RemoteBlobSource = @ptrCast(@alignCast(ptr));
        return self.client.getFileBlob(allocator, self.repo, commit, path);
    }
};

pub const GitBlobSource = struct {
    client: bbr.git.GitClient,

    pub fn source(self: *GitBlobSource) BlobSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, allocator: Allocator, commit: []const u8, path: []const u8) anyerror![]u8 {
        const self: *GitBlobSource = @ptrCast(@alignCast(ptr));
        return self.client.blob(allocator, commit, path);
    }
};

pub const Request = struct {
    repo: []const u8,
    status: bbr.diff.FileStatus,
    source_commit: []const u8,
    destination_commit: []const u8,
    old_path: []const u8,
    new_path: []const u8,
    max_file_bytes: usize,
    content: bbr.diff.FileContent = .{ .old = .{ .text = null }, .new = .{ .text = null } },
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
    binary: ?usize,
    unavailable: bbr.diff.FileContentStatus,
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
    content_statuses: []const bbr.diff.FileContent,
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
    binary: ?usize,
    unavailable: bbr.diff.FileContentStatus,
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
    var remote: RemoteBlobSource = .{ .client = bb, .repo = req.repo };
    return enrichFrom(backing, remote.source(), highlighter, req);
}

pub fn enrichFrom(backing: Allocator, source: BlobSource, highlighter: bbr.highlight.Highlighter, req: Request) error{OutOfMemory}!Result {
    var result: Result = .{ .old = .absent, .new = .absent };
    errdefer result.deinit();
    if (req.status != .added) {
        result.old = try enrichExpectedSide(backing, source, highlighter, req.max_file_bytes, req.destination_commit, req.old_path, req.content.old);
    }
    if (req.status != .removed) {
        result.new = try enrichExpectedSide(backing, source, highlighter, req.max_file_bytes, req.source_commit, req.new_path, req.content.new);
    }
    return result;
}

fn enrichExpectedSide(backing: Allocator, source: BlobSource, highlighter: bbr.highlight.Highlighter, max_file_bytes: usize, commit: []const u8, path: []const u8, known: ?bbr.diff.FileContentStatus) error{OutOfMemory}!SideResult {
    const status: bbr.diff.FileContentStatus = known orelse .{ .text = null };
    return switch (status) {
        .binary => |size| .{ .binary = size },
        .unavailable => .{ .unavailable = status },
        .text => enrichSide(backing, source, highlighter, max_file_bytes, commit, path),
    };
}

fn enrichSide(backing: Allocator, source: BlobSource, highlighter: bbr.highlight.Highlighter, max_file_bytes: usize, commit: []const u8, path: []const u8) error{OutOfMemory}!SideResult {
    const side = try backing.create(OwnedSide);
    errdefer backing.destroy(side);
    side.arena = std.heap.ArenaAllocator.init(backing);
    errdefer side.arena.deinit();
    const allocator = side.arena.allocator();

    side.blob = source.read(allocator, commit, path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        side.destroy();
        if (err == error.InvalidPath) return .{ .unavailable = .{ .unavailable = .{ .reason = .invalid_path } } };
        return .{ .fetch_failed = err };
    };
    if (!std.unicode.utf8ValidateSlice(side.blob)) {
        const byte_size = side.blob.len;
        side.destroy();
        return .{ .unavailable = .{ .unavailable = .{ .reason = .invalid_utf8, .byte_size = byte_size } } };
    }
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
    // output and any scratch capacity not individually freed.
    return side.arena.queryCapacity();
}

const StoredSide = union(enum) {
    pending,
    absent,
    binary: ?usize,
    unavailable: bbr.diff.FileContentStatus,
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
            .binary => |size| .{ .binary = size },
            .unavailable => |status| .{ .unavailable = status },
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
    content_statuses: []bbr.diff.FileContent,
    statuses: []bbr.highlight.FileHighlightStatus,
    errors: []SideErrors,
    cache: CachePolicy = .{},
    focused_file: ?usize = null,
    recency: u64 = 0,
    retired: std.ArrayList(RetiredFile) = .empty,

    pub fn init(allocator: Allocator, diff_files: []const bbr.diff.File) !Storage {
        const files = try allocator.alloc(StoredFile, diff_files.len);
        errdefer allocator.free(files);
        for (diff_files, 0..) |diff_file, i| {
            files[i] = .{
                .old = initialStoredSide(diff_file, .old),
                .new = initialStoredSide(diff_file, .new),
            };
        }
        const blobs = try allocator.alloc(bbr.diff.FileBlob, diff_files.len);
        errdefer allocator.free(blobs);
        @memset(blobs, .{});
        const highlights = try allocator.alloc(bbr.highlight.FileHighlights, diff_files.len);
        errdefer allocator.free(highlights);
        @memset(highlights, .{});
        const content_statuses = try allocator.alloc(bbr.diff.FileContent, diff_files.len);
        errdefer allocator.free(content_statuses);
        for (diff_files, 0..) |diff_file, i| {
            content_statuses[i] = .{
                .old = if (diff_file.status == .added) null else diff_file.content.old,
                .new = if (diff_file.status == .removed) null else diff_file.content.new,
            };
        }
        const statuses = try allocator.alloc(bbr.highlight.FileHighlightStatus, diff_files.len);
        errdefer allocator.free(statuses);
        for (diff_files, 0..) |_, i| {
            statuses[i] = .{
                .old = initialHighlightState(files[i].old),
                .new = initialHighlightState(files[i].new),
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
            .content_statuses = content_statuses,
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
        self.allocator.free(self.content_statuses);
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
        if ((stored.old != .pending and stored.old != .absent and stored.old != .binary and stored.old != .unavailable) or
            (stored.new != .pending and stored.new != .absent and stored.new != .binary and stored.new != .unavailable)) return error.AlreadyAdmitted;

        stored.old = transfer(&result.old);
        stored.new = transfer(&result.new);
        self.projectSide(file_idx, .old);
        self.projectSide(file_idx, .new);
        return self.stageCacheEnforcement();
    }

    pub fn configureCache(self: *Storage, policy: CachePolicy) void {
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

    pub fn isTerminal(self: *const Storage, file_idx: usize) bool {
        std.debug.assert(file_idx < self.statuses.len);
        const file_status = self.statuses[file_idx];
        return sideIsTerminal(file_status.old) and sideIsTerminal(file_status.new);
    }

    pub fn projection(self: *const Storage) Projection {
        return .{ .blobs = self.blobs, .highlights = self.highlights, .content_statuses = self.content_statuses };
    }

    fn projectSide(self: *Storage, file_idx: usize, comptime which: enum { old, new }) void {
        const stored = @field(self.files[file_idx], @tagName(which));
        const blob_slot = &@field(self.blobs[file_idx], @tagName(which));
        const highlight_slot = &@field(self.highlights[file_idx], @tagName(which));
        const content_status_slot = &@field(self.content_statuses[file_idx], @tagName(which));
        const status_slot = &@field(self.statuses[file_idx], @tagName(which));
        const error_slot = &@field(self.errors[file_idx], @tagName(which));
        blob_slot.* = null;
        highlight_slot.* = null;
        error_slot.* = null;
        switch (stored) {
            .pending => {
                content_status_slot.* = .{ .text = null };
                status_slot.* = .pending;
            },
            .absent => {
                content_status_slot.* = null;
                status_slot.* = .absent;
            },
            .binary => |size| {
                content_status_slot.* = .{ .binary = size };
                status_slot.* = .absent;
            },
            .unavailable => |known_status| {
                content_status_slot.* = known_status;
                status_slot.* = .absent;
            },
            .fetch_failed => |err| {
                content_status_slot.* = .{ .unavailable = .{ .reason = .{ .acquisition_failed = err } } };
                status_slot.* = .fetch_failed;
                error_slot.* = err;
            },
            .content => |content| {
                blob_slot.* = content.blob;
                content_status_slot.* = .{ .text = content.blob.len };
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
        const budget = if (!self.cache.enabled)
            0
        else if (self.cache.max_retained_bytes == 0)
            std.math.maxInt(usize)
        else
            self.cache.max_retained_bytes;
        var changed = false;
        while (self.inactiveRetainedBytes() > budget) {
            const victim = self.leastRecentlyUsedInactive() orelse break;
            self.retired.appendAssumeCapacity(.{ .index = victim, .file = self.files[victim] });
            self.files[victim] = .{
                .old = retainedTerminalSide(self.files[victim].old),
                .new = retainedTerminalSide(self.files[victim].new),
                .last_used = self.files[victim].last_used,
            };
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

fn sideIsTerminal(state: bbr.highlight.SideState) bool {
    return switch (state) {
        .pending, .loading => false,
        .absent, .ready, .skipped_too_large, .fetch_failed, .highlight_failed => true,
    };
}

fn transfer(side: *SideResult) StoredSide {
    const stored: StoredSide = switch (side.*) {
        .absent => .absent,
        .binary => |size| .{ .binary = size },
        .unavailable => |status| .{ .unavailable = status },
        .fetch_failed => |err| .{ .fetch_failed = err },
        .owned => |owned| .{ .content = owned },
        .transferred => unreachable,
    };
    side.* = .transferred;
    return stored;
}

fn initialStoredSide(file: bbr.diff.File, comptime which: enum { old, new }) StoredSide {
    if (which == .old and file.status == .added or which == .new and file.status == .removed) return .absent;
    const status = @field(file.content, @tagName(which)) orelse return .pending;
    return switch (status) {
        .binary => |size| .{ .binary = size },
        .text => .pending,
        .unavailable => .{ .unavailable = status },
    };
}

fn initialHighlightState(side: StoredSide) bbr.highlight.SideState {
    return switch (side) {
        .absent, .binary, .unavailable => .absent,
        .pending => .pending,
        .fetch_failed => .fetch_failed,
        .content => .ready,
    };
}

fn retainedTerminalSide(side: StoredSide) StoredSide {
    return switch (side) {
        .absent => .absent,
        .binary => |size| .{ .binary = size },
        .unavailable => |status| .{ .unavailable = status },
        else => .pending,
    };
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
    calls: usize = 0,

    fn highlighter(self: *ScriptedHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.highlight.Highlighter.VTable = .{ .highlight = highlight };

    fn highlight(ptr: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!bbr.highlight.HighlightResult {
        const self: *ScriptedHighlighter = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const spans = try allocator.alloc(bbr.highlight.Span, 1);
        spans[0] = .{
            .line = 1,
            .start = 0,
            .end = 5,
            .capture = bbr.highlight.Capture.init(0, "keyword"),
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

const CountingBlobSource = struct {
    calls: usize = 0,

    fn source(self: *CountingBlobSource) BlobSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
        const self: *CountingBlobSource = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return error.UnexpectedRead;
    }
};

const ExpectedBlob = struct { commit: []const u8, path: []const u8, bytes: []const u8 };

const ExpectedBlobSource = struct {
    expected: []const ExpectedBlob,
    calls: usize = 0,

    fn source(self: *ExpectedBlobSource) BlobSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, allocator: Allocator, commit: []const u8, path: []const u8) anyerror![]u8 {
        const self: *ExpectedBlobSource = @ptrCast(@alignCast(ptr));
        if (self.calls >= self.expected.len) return error.UnexpectedRead;
        const expected = self.expected[self.calls];
        self.calls += 1;
        if (!std.mem.eql(u8, expected.commit, commit)) return error.UnexpectedCommit;
        if (!std.mem.eql(u8, expected.path, path)) return error.UnexpectedPath;
        return allocator.dupe(u8, expected.bytes);
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
    try testing.expectEqual(bbr.highlight.CaptureRole.keyword, projected.new.content.highlighting.ready.spans[0].capture.role);
    try testing.expectError(error.AlreadyTransferred, storage.admit(0, &result));
}

test "local Git blob source uses the same File Enrichment pipeline" {
    const added_fixtures = [_]bbr.git.FakeGitClient.BlobFixture{.{
        .commit = "source",
        .path = "src/local.zig",
        .outcome = .{ .content = "const local = true;\n" },
    }};
    var fake_git: bbr.git.FakeGitClient = .{ .blob_fixtures = &added_fixtures };
    var source: GitBlobSource = .{ .client = fake_git.gitClient() };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var result = try enrichFrom(testing.allocator, source.source(), plain.highlighter(), .{
        .repo = "",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "/dev/null",
        .new_path = "src/local.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = [_]bbr.diff.File{.{ .old_path = "/dev/null", .new_path = "src/local.zig", .status = .added, .hunks = &.{} }};
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);
    try testing.expectEqualStrings("const local = true;\n", storage.file(0).new.content.blob);
    try testing.expectEqual(@as(usize, 1), fake_git.blob_calls);

    const removed_fixtures = [_]bbr.git.FakeGitClient.BlobFixture{.{
        .commit = "destination",
        .path = "src/removed.zig",
        .outcome = .{ .content = "removed\n" },
    }};
    var removed_git: bbr.git.FakeGitClient = .{ .blob_fixtures = &removed_fixtures };
    var removed_source: GitBlobSource = .{ .client = removed_git.gitClient() };
    var removed = try enrichFrom(testing.allocator, removed_source.source(), plain.highlighter(), .{
        .repo = "",
        .status = .removed,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "src/removed.zig",
        .new_path = "/dev/null",
        .max_file_bytes = 0,
    });
    defer removed.deinit();
    try testing.expectEqualStrings("removed\n", removed.old.owned.blob);
    try testing.expect(removed.new == .absent);
    try testing.expectEqual(@as(usize, 1), removed_git.blob_calls);

    const removed_files = [_]bbr.diff.File{.{ .old_path = "src/removed.zig", .new_path = "/dev/null", .status = .removed, .hunks = &.{} }};
    var removed_storage = try Storage.init(testing.allocator, &removed_files);
    defer removed_storage.deinit();
    try removed_storage.admit(0, &removed);
    try testing.expectEqual(@as(?usize, "removed\n".len), removed_storage.projection().content_statuses[0].old.?.text);
}

test "empty local Git content is text with a zero byte size" {
    const fixtures = [_]bbr.git.FakeGitClient.BlobFixture{.{
        .commit = "source",
        .path = "empty.txt",
        .outcome = .{ .content = "" },
    }};
    var fake_git: bbr.git.FakeGitClient = .{ .blob_fixtures = &fixtures };
    var source: GitBlobSource = .{ .client = fake_git.gitClient() };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var result = try enrichFrom(testing.allocator, source.source(), plain.highlighter(), .{
        .repo = "",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "base",
        .old_path = "/dev/null",
        .new_path = "empty.txt",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = [_]bbr.diff.File{.{ .old_path = "/dev/null", .new_path = "empty.txt", .status = .added, .hunks = &.{} }};
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);
    try testing.expectEqual(@as(?usize, 0), storage.projection().content_statuses[0].new.?.text);
    try testing.expectEqual(@as(usize, 0), storage.file(0).new.content.blob.len);
}

test "local Git content keeps each side independent and uses exact commits and paths" {
    const invalid = [_]u8{ 0xff, 0x80, 0x00 };
    const fixtures = [_]bbr.git.FakeGitClient.BlobFixture{
        .{ .commit = "base", .path = "src/old name.zig", .outcome = .{ .content = invalid[0..] } },
        .{ .commit = "source", .path = "src/new name.zig", .outcome = .{ .content = "const current = true;\n" } },
    };
    var fake_git: bbr.git.FakeGitClient = .{ .blob_fixtures = &fixtures };
    var source: GitBlobSource = .{ .client = fake_git.gitClient() };
    var scripted = ScriptedHighlighter{};
    var result = try enrichFrom(testing.allocator, source.source(), scripted.highlighter(), .{
        .repo = "",
        .status = .renamed,
        .source_commit = "source",
        .destination_commit = "base",
        .old_path = "src/old name.zig",
        .new_path = "src/new name.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = [_]bbr.diff.File{.{
        .old_path = "src/old name.zig",
        .new_path = "src/new name.zig",
        .status = .renamed,
        .hunks = &.{},
    }};
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);

    const content = storage.projection().content_statuses[0];
    try testing.expect(content.old.? == .unavailable);
    try testing.expect(content.old.?.unavailable.reason == .invalid_utf8);
    try testing.expectEqual(@as(?usize, invalid.len), content.old.?.unavailable.byte_size);
    try testing.expectEqual(@as(?usize, "const current = true;\n".len), content.new.?.text);
    try testing.expectEqualStrings("const current = true;\n", storage.file(0).new.content.blob);
    try testing.expectEqual(@as(usize, 1), scripted.calls);
    try testing.expectEqual(@as(usize, 2), fake_git.blob_calls);
}

test "local Git acquisition failure becomes a placeholder while readable text survives Highlighting failure" {
    const fixtures = [_]bbr.git.FakeGitClient.BlobFixture{
        .{ .commit = "base", .path = "src/main.zig", .outcome = .{ .failure = error.BlobNotFound } },
        .{ .commit = "source", .path = "src/main.zig", .outcome = .{ .content = "readable\n" } },
    };
    var fake_git: bbr.git.FakeGitClient = .{ .blob_fixtures = &fixtures };
    var source: GitBlobSource = .{ .client = fake_git.gitClient() };
    var failing = FailingHighlighter{};
    var result = try enrichFrom(testing.allocator, source.source(), failing.highlighter(), .{
        .repo = "",
        .status = .modified,
        .source_commit = "source",
        .destination_commit = "base",
        .old_path = "src/main.zig",
        .new_path = "src/main.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();

    const files = oneTestFile(.modified);
    var storage = try Storage.init(testing.allocator, &files);
    defer storage.deinit();
    try storage.admit(0, &result);

    const content = storage.projection().content_statuses[0];
    try testing.expect(content.old.? == .unavailable);
    try testing.expect(content.old.?.unavailable.reason == .acquisition_failed);
    try testing.expectEqual(error.BlobNotFound, content.old.?.unavailable.reason.acquisition_failed);
    try testing.expectEqual(@as(?usize, "readable\n".len), content.new.?.text);
    try testing.expectEqualStrings("readable\n", storage.file(0).new.content.blob);
    try testing.expect(storage.file(0).new.content.highlighting == .failed);
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

test "File Enrichment requests each present side from its exact commit and path" {
    const expected = [_]ExpectedBlob{
        .{ .commit = "destination", .path = "src/old name.zig", .bytes = "old\n" },
        .{ .commit = "source", .path = "src/new name.zig", .bytes = "new\n" },
    };
    var source: ExpectedBlobSource = .{ .expected = &expected };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var result = try enrichFrom(testing.allocator, source.source(), plain.highlighter(), .{
        .repo = "",
        .status = .renamed,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "src/old name.zig",
        .new_path = "src/new name.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), source.calls);
    try testing.expectEqualStrings("old\n", result.old.owned.blob);
    try testing.expectEqualStrings("new\n", result.new.owned.blob);
}

test "File Enrichment does not request absent sides" {
    const added_expected = [_]ExpectedBlob{.{ .commit = "source", .path = "new.zig", .bytes = "new" }};
    var added_source: ExpectedBlobSource = .{ .expected = &added_expected };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var added = try enrichFrom(testing.allocator, added_source.source(), plain.highlighter(), .{
        .repo = "",
        .status = .added,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "/dev/null",
        .new_path = "new.zig",
        .max_file_bytes = 0,
    });
    defer added.deinit();
    try testing.expect(added.old == .absent);
    try testing.expectEqual(@as(usize, 1), added_source.calls);

    const removed_expected = [_]ExpectedBlob{.{ .commit = "destination", .path = "old.zig", .bytes = "old" }};
    var removed_source: ExpectedBlobSource = .{ .expected = &removed_expected };
    var removed = try enrichFrom(testing.allocator, removed_source.source(), plain.highlighter(), .{
        .repo = "",
        .status = .removed,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "old.zig",
        .new_path = "/dev/null",
        .max_file_bytes = 0,
    });
    defer removed.deinit();
    try testing.expect(removed.new == .absent);
    try testing.expectEqual(@as(usize, 1), removed_source.calls);
}

test "invalid UTF-8 makes only its side unavailable with exact byte size" {
    const invalid = [_]u8{ 0xff, 0x80, 0x00 };
    const expected = [_]ExpectedBlob{
        .{ .commit = "destination", .path = "old.zig", .bytes = invalid[0..] },
        .{ .commit = "source", .path = "new.zig", .bytes = "" },
    };
    var source: ExpectedBlobSource = .{ .expected = &expected };
    var scripted = ScriptedHighlighter{};
    var result = try enrichFrom(testing.allocator, source.source(), scripted.highlighter(), .{
        .repo = "",
        .status = .renamed,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "old.zig",
        .new_path = "new.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();
    try testing.expect(result.old == .unavailable);
    try testing.expect(result.old.unavailable.unavailable.reason == .invalid_utf8);
    try testing.expectEqual(@as(?usize, 3), result.old.unavailable.unavailable.byte_size);
    try testing.expectEqual(@as(usize, 0), result.new.owned.blob.len);
    try testing.expectEqual(@as(usize, 1), scripted.calls);
}

test "invalid remote paths become typed unavailable sides" {
    var fake: bbr.http.FakeHttpClient = .{ .body = "must not be read" };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var plain: bbr.highlight.PlainHighlighter = .{};
    var result = try enrich(testing.allocator, bb, plain.highlighter(), .{
        .repo = "repo",
        .status = .renamed,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "../old.zig",
        .new_path = "new.zig",
        .max_file_bytes = 0,
    });
    defer result.deinit();
    try testing.expect(result.old == .unavailable);
    try testing.expect(result.old.unavailable.unavailable.reason == .invalid_path);
    try testing.expectEqualStrings("must not be read", result.new.owned.blob);
    try testing.expectEqual(@as(usize, 1), fake.call_count);
}

test "each classified ApiError stays on its failed side" {
    const cases = [_]struct { status: u16, expected: anyerror }{
        .{ .status = 400, .expected = error.BadRequest },
        .{ .status = 401, .expected = error.Unauthorized },
        .{ .status = 403, .expected = error.Forbidden },
        .{ .status = 404, .expected = error.NotFound },
        .{ .status = 409, .expected = error.Conflict },
        .{ .status = 429, .expected = error.RateLimited },
        .{ .status = 503, .expected = error.ServerError },
        .{ .status = 302, .expected = error.UnexpectedStatus },
    };
    for (cases) |case| {
        const responses = [_]bbr.http.Canned{
            .{ .status = case.status, .body = "failure" },
            .{ .status = 200, .body = "new" },
        };
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
        var plain: bbr.highlight.PlainHighlighter = .{};
        var result = try enrich(testing.allocator, bb, plain.highlighter(), .{
            .repo = "repo",
            .status = .modified,
            .source_commit = "source",
            .destination_commit = "destination",
            .old_path = "file.zig",
            .new_path = "file.zig",
            .max_file_bytes = 0,
        });
        defer result.deinit();
        try testing.expect(result.old == .fetch_failed);
        try testing.expectEqual(case.expected, result.old.fetch_failed);
        try testing.expectEqualStrings("new", result.new.owned.blob);
    }
}

test "File Content Status is independent per expected side and from Highlighting" {
    const responses = [_]bbr.http.Canned{
        .{ .status = 404, .body = "" },
        .{ .status = 200, .body = "const current = true;\n" },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var failing = FailingHighlighter{};
    var result = try enrich(testing.allocator, bb, failing.highlighter(), .{
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

    const content = storage.projection().content_statuses[0];
    try testing.expect(content.old.? == .unavailable);
    try testing.expect(content.old.?.unavailable.byte_size == null);
    try testing.expect(content.old.?.unavailable.reason == .acquisition_failed);
    try testing.expectEqual(error.NotFound, content.old.?.unavailable.reason.acquisition_failed);
    try testing.expect(content.new.? == .text);
    try testing.expectEqual(@as(?usize, "const current = true;\n".len), content.new.?.text);
    try testing.expect(storage.file(0).new.content.highlighting == .failed);
}

test "remote and local RawDiff binary sides skip File Enrichment reads and Highlighting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diff = try bbr.diff.parse(arena.allocator(), "diff --git a/image.bin b/image.bin\n" ++
        "GIT binary patch\n" ++
        "literal 4\nencoded\n" ++
        "\n" ++
        "literal 3\nencoded\n");
    const file = diff.files[0];

    var storage = try Storage.init(testing.allocator, diff.files);
    defer storage.deinit();
    try testing.expect(!storage.needsEnrichment(0));
    try testing.expect(storage.file(0).old == .binary);
    try testing.expect(storage.file(0).new == .binary);
    try testing.expectEqual(@as(?usize, 3), storage.projection().content_statuses[0].old.?.binary);
    try testing.expectEqual(@as(?usize, 4), storage.projection().content_statuses[0].new.?.binary);

    var fake: bbr.http.FakeHttpClient = .{ .body = "must not be read" };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var scripted = ScriptedHighlighter{};
    const req: Request = .{
        .repo = "repo",
        .status = file.status,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = file.old_path,
        .new_path = file.new_path,
        .max_file_bytes = 0,
        .content = file.content,
    };
    var remote_result = try enrich(testing.allocator, bb, scripted.highlighter(), req);
    defer remote_result.deinit();
    var local_source = CountingBlobSource{};
    var local_result = try enrichFrom(testing.allocator, local_source.source(), scripted.highlighter(), req);
    defer local_result.deinit();
    try testing.expectEqual(@as(?usize, 3), remote_result.old.binary);
    try testing.expectEqual(@as(?usize, 4), remote_result.new.binary);
    try testing.expectEqual(@as(?usize, 3), local_result.old.binary);
    try testing.expectEqual(@as(?usize, 4), local_result.new.binary);
    try testing.expectEqual(@as(usize, 0), fake.call_count);
    try testing.expectEqual(@as(usize, 0), local_source.calls);
    try testing.expectEqual(@as(usize, 0), scripted.calls);

    var unavailable_result = try enrich(testing.allocator, bb, scripted.highlighter(), .{
        .repo = req.repo,
        .status = req.status,
        .source_commit = req.source_commit,
        .destination_commit = req.destination_commit,
        .old_path = req.old_path,
        .new_path = req.new_path,
        .max_file_bytes = req.max_file_bytes,
        .content = .{
            .old = .{ .unavailable = .{ .reason = .invalid_utf8, .byte_size = 3 } },
            .new = req.content.new,
        },
    });
    defer unavailable_result.deinit();
    try testing.expect(unavailable_result.old == .unavailable);
    try testing.expectEqual(@as(usize, 0), fake.call_count);
    try testing.expectEqual(@as(usize, 0), scripted.calls);
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

test "File content cache budget includes Highlight Spans" {
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
    try testing.expectEqual(bbr.highlight.CaptureRole.keyword, storage.file(0).new.content.highlighting.ready.spans[0].capture.role);

    storage.focus(1);
    try testing.expect(storage.file(0).new == .pending);
}

test "zero File cache budget retains unlimited inactive content and excludes the focused File" {
    var storage = try Storage.init(testing.allocator, test_files[0..3]);
    defer storage.deinit();
    storage.configureCache(.{ .enabled = true, .max_retained_bytes = 0 });

    storage.focus(0);
    var first = try ownedAddedResult(testing.allocator, "aaaaaa");
    defer first.deinit();
    try storage.admit(0, &first);

    storage.focus(1);
    var second = try ownedAddedResult(testing.allocator, "bbbbbb");
    defer second.deinit();
    try storage.admit(1, &second);

    storage.focus(2);
    try testing.expectEqualStrings("aaaaaa", storage.file(0).new.content.blob);
    try testing.expectEqualStrings("bbbbbb", storage.file(1).new.content.blob);
}

test "equal-recency inactive Files evict in stable File order" {
    var storage = try Storage.init(testing.allocator, test_files[0..3]);
    defer storage.deinit();
    storage.configureCache(.{ .enabled = true, .max_retained_bytes = 6 });
    storage.focus(2);

    var first = try ownedAddedResult(testing.allocator, "aaaaaa");
    defer first.deinit();
    try storage.admit(0, &first);
    var second = try ownedAddedResult(testing.allocator, "bbbbbb");
    defer second.deinit();
    try storage.admit(1, &second);

    try testing.expect(storage.file(0).new == .pending);
    try testing.expectEqualStrings("bbbbbb", storage.file(1).new.content.blob);
}
