//! File Read Receipts: the File Review Fingerprint and the `FileReadStore`
//! seam, a ptr+vtable interface like `PendingReviewStore` (ADR-0003). The
//! store holds one receipt for each ReviewIdentity and canonical path. The
//! real implementation is `SqliteStore.fileReadStore()`. Tests use
//! `InMemoryFileReadStore`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const testing = std.testing;
const diff = @import("../diff/model.zig");
const ReviewIdentity = @import("store.zig").ReviewIdentity;

pub const FileReviewFingerprint = struct {
    bytes: [32]u8,

    pub fn eql(a: FileReviewFingerprint, b: FileReviewFingerprint) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// The digest of the review-visible change of `file`, or null when the File
/// is unverifiable. Hunk headers and line numbers do not participate, so a
/// pure line shift keeps the fingerprint.
pub fn fingerprint(file: diff.File) ?FileReviewFingerprint {
    const binary = isBinary(file.content.old) or isBinary(file.content.new);
    if (binary and file.blob_ids == null) return null;
    var hash = Sha256.init(.{});
    hash.update(&.{1}); // encoding version
    putText(&hash, file.old_path);
    putText(&hash, file.new_path);
    // Explicit tags keep stored receipts valid when an enum gains or reorders tags.
    hash.update(&.{switch (file.status) {
        .added => 0,
        .modified => 1,
        .removed => 2,
        .renamed => 3,
    }});
    hash.update(&.{ sideTag(file.content.old), sideTag(file.content.new) });
    // A binary File has no Lines, so its blob ids describe the change.
    if (binary) {
        putText(&hash, file.blob_ids.?.old);
        putText(&hash, file.blob_ids.?.new);
    }
    for (file.hunks) |hunk| {
        hash.update(&.{0}); // Hunk marker
        for (hunk.lines) |line| {
            hash.update(&.{switch (line.kind) {
                .context => 1,
                .added => 2,
                .removed => 3,
            }});
            putText(&hash, line.text);
        }
    }
    return .{ .bytes = hash.finalResult() };
}

fn isBinary(side: ?diff.FileContentStatus) bool {
    return if (side) |status| status == .binary else false;
}

fn sideTag(side: ?diff.FileContentStatus) u8 {
    const status = side orelse return 0;
    return switch (status) {
        .text => 1,
        .binary => 2,
        .unavailable => 3,
    };
}

fn putText(hash: *Sha256, text: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, text.len, .little);
    hash.update(&length);
    hash.update(text);
}

/// The canonical path is `File.displayPath()`.
pub const FileReadReceipt = struct {
    path: []const u8,
    fingerprint: FileReviewFingerprint,
};

pub const FileReadStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (ptr: *anyopaque, allocator: Allocator, identity: ReviewIdentity) anyerror![]FileReadReceipt,
        put: *const fn (ptr: *anyopaque, identity: ReviewIdentity, path: []const u8, fingerprint: FileReviewFingerprint) anyerror!void,
        delete: *const fn (ptr: *anyopaque, identity: ReviewIdentity, path: []const u8) anyerror!void,
    };

    /// Every receipt of `identity`, with each path copied into `allocator`.
    pub fn load(self: FileReadStore, allocator: Allocator, identity: ReviewIdentity) ![]FileReadReceipt {
        return self.vtable.load(self.ptr, allocator, identity);
    }

    /// Insert the receipt, or replace the receipt for the same identity and path.
    pub fn put(self: FileReadStore, identity: ReviewIdentity, path: []const u8, value: FileReviewFingerprint) !void {
        return self.vtable.put(self.ptr, identity, path, value);
    }

    /// Remove the receipt for `identity` and `path`. A missing receipt is not an error.
    pub fn delete(self: FileReadStore, identity: ReviewIdentity, path: []const u8) !void {
        return self.vtable.delete(self.ptr, identity, path);
    }
};

pub const InMemoryFileReadStore = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    fail_load: bool = false,
    load_error: ?anyerror = null,
    fail_put: bool = false,
    fail_delete: bool = false,
    /// Every `put` and `delete` call, failed calls included.
    writes: usize = 0,

    const Entry = struct { identity: ReviewIdentity, path: []const u8, fingerprint: FileReviewFingerprint };

    pub fn init(gpa: Allocator) InMemoryFileReadStore {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *InMemoryFileReadStore) void {
        self.entries.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn store(self: *InMemoryFileReadStore) FileReadStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: FileReadStore.VTable = .{ .load = loadImpl, .put = putImpl, .delete = deleteImpl };

    fn find(self: *InMemoryFileReadStore, identity: ReviewIdentity, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (ReviewIdentity.eql(entry.identity, identity) and std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }

    fn loadImpl(ptr: *anyopaque, allocator: Allocator, identity: ReviewIdentity) anyerror![]FileReadReceipt {
        const self: *InMemoryFileReadStore = @ptrCast(@alignCast(ptr));
        if (self.load_error) |err| return err;
        if (self.fail_load) return error.InjectedLoadFailure;
        var receipts: std.ArrayList(FileReadReceipt) = .empty;
        errdefer {
            for (receipts.items) |receipt| allocator.free(receipt.path);
            receipts.deinit(allocator);
        }
        for (self.entries.items) |entry| {
            if (!ReviewIdentity.eql(entry.identity, identity)) continue;
            try receipts.ensureUnusedCapacity(allocator, 1);
            receipts.appendAssumeCapacity(.{ .path = try allocator.dupe(u8, entry.path), .fingerprint = entry.fingerprint });
        }
        return receipts.toOwnedSlice(allocator);
    }

    fn putImpl(ptr: *anyopaque, identity: ReviewIdentity, path: []const u8, value: FileReviewFingerprint) anyerror!void {
        const self: *InMemoryFileReadStore = @ptrCast(@alignCast(ptr));
        self.writes += 1;
        if (self.fail_put) return error.InjectedPutFailure;
        if (self.find(identity, path)) |index| {
            self.entries.items[index].fingerprint = value;
            return;
        }
        const a = self.arena.allocator();
        const owned: ReviewIdentity = switch (identity) {
            .remote => |remote| .{ .remote = .{
                .workspace = try a.dupe(u8, remote.workspace),
                .repository = try a.dupe(u8, remote.repository),
                .pull_request_id = remote.pull_request_id,
            } },
            .local => |local| .{ .local = .{
                .repository_id = local.repository_id,
                .base_ref = try a.dupe(u8, local.base_ref),
                .source_ref = try a.dupe(u8, local.source_ref),
            } },
        };
        try self.entries.append(self.arena.child_allocator, .{ .identity = owned, .path = try a.dupe(u8, path), .fingerprint = value });
    }

    fn deleteImpl(ptr: *anyopaque, identity: ReviewIdentity, path: []const u8) anyerror!void {
        const self: *InMemoryFileReadStore = @ptrCast(@alignCast(ptr));
        self.writes += 1;
        if (self.fail_delete) return error.InjectedDeleteFailure;
        if (self.find(identity, path)) |index| _ = self.entries.swapRemove(index);
    }
};

/// The shared behavior of every `FileReadStore`. Each adapter runs it on an empty store.
pub fn expectStoreContract(reads: FileReadStore) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first: FileReviewFingerprint = .{ .bytes = @splat(1) };
    const second: FileReviewFingerprint = .{ .bytes = @splat(2) };
    const review: ReviewIdentity = .{ .remote = .{ .workspace = "workspace", .repository = "repo", .pull_request_id = 7 } };
    const other_repository: ReviewIdentity = .{ .remote = .{ .workspace = "workspace", .repository = "other", .pull_request_id = 7 } };
    const local: ReviewIdentity = .{ .local = .{ .repository_id = 7, .base_ref = "refs/heads/main", .source_ref = "refs/heads/feature" } };
    const other_base: ReviewIdentity = .{ .local = .{ .repository_id = 7, .base_ref = "refs/heads/release", .source_ref = "refs/heads/feature" } };
    const other_source: ReviewIdentity = .{ .local = .{ .repository_id = 7, .base_ref = "refs/heads/main", .source_ref = "refs/heads/topic" } };

    try reads.put(review, "src/a.zig", first);
    var loaded = try reads.load(a, review);
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expectEqualStrings("src/a.zig", loaded[0].path);
    try testing.expect(loaded[0].fingerprint.eql(first));

    try reads.put(review, "src/a.zig", second);
    loaded = try reads.load(a, review);
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expect(loaded[0].fingerprint.eql(second));

    try reads.put(local, "src/a.zig", first);
    for ([_]ReviewIdentity{ other_repository, other_base, other_source }) |isolated| {
        try testing.expectEqual(@as(usize, 0), (try reads.load(a, isolated)).len);
    }
    loaded = try reads.load(a, local);
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expect(loaded[0].fingerprint.eql(first));

    try reads.delete(review, "src/a.zig");
    try testing.expectEqual(@as(usize, 0), (try reads.load(a, review)).len);
    try testing.expectEqual(@as(usize, 1), (try reads.load(a, local)).len);
    try reads.delete(review, "src/a.zig");
    try reads.delete(other_repository, "missing.zig");
}

const parser = @import("../diff/parser.zig");

fn expectFingerprint(raw: []const u8) !FileReviewFingerprint {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parser.parse(arena.allocator(), raw);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
    return fingerprint(parsed.files[0]) orelse error.Unverifiable;
}

fn expectSame(a: []const u8, b: []const u8) !void {
    try testing.expect((try expectFingerprint(a)).eql(try expectFingerprint(b)));
}

fn expectDifferent(a: []const u8, b: []const u8) !void {
    try testing.expect(!(try expectFingerprint(a)).eql(try expectFingerprint(b)));
}

const base_diff =
    \\diff --git a/src/a.zig b/src/a.zig
    \\--- a/src/a.zig
    \\+++ b/src/a.zig
    \\@@ -1,2 +1,2 @@ fn main
    \\ keep
    \\-old
    \\+new
    \\@@ -10,2 +10,2 @@
    \\ tail
    \\-before
    \\+after
    \\
;

test "M22 read equal diff text gives equal fingerprints despite other line numbers or Hunk header text" {
    try expectSame(base_diff, base_diff);
    try expectSame(base_diff,
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -41,2 +45,2 @@ fn other_section
        \\ keep
        \\-old
        \\+new
        \\@@ -90,2 +94,2 @@ more text
        \\ tail
        \\-before
        \\+after
        \\
    );
}

test "M22 read a changed Line, Hunk boundary, path, or change kind gives a different fingerprint" {
    const changed = [_][]const u8{
        // added Line text
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\ keep
        \\-old
        \\+newer
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
        ,
        // removed Line text
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\ keep
        \\-older
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
        ,
        // context Line text
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\ kept
        \\-old
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
        ,
        // Line kind
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\+keep
        \\-old
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
        ,
        // Hunk boundary with the same Lines
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,4 +1,4 @@ fn main
        \\ keep
        \\-old
        \\+new
        \\ tail
        \\-before
        \\+after
        \\
        ,
        // old path
        \\diff --git a/src/b.zig b/src/a.zig
        \\--- a/src/b.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\ keep
        \\-old
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
        ,
        // new path
        \\diff --git a/src/a.zig b/src/c.zig
        \\--- a/src/a.zig
        \\+++ b/src/c.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\ keep
        \\-old
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
        ,
    };
    for (changed) |raw| try expectDifferent(base_diff, raw);

    const modified =
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\
    ;
    const renamed =
        \\diff --git a/src/a.zig b/src/a.zig
        \\similarity index 100%
        \\rename from src/a.zig
        \\rename to src/a.zig
        \\
    ;
    try expectDifferent(modified, renamed);
}

test "M22 read an added File, a removed File, and a pure rename each have a fingerprint" {
    const added = try expectFingerprint(
        \\diff --git a/src/new.zig b/src/new.zig
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/src/new.zig
        \\@@ -0,0 +1 @@
        \\+new
        \\
    );
    const removed = try expectFingerprint(
        \\diff --git a/src/gone.zig b/src/gone.zig
        \\deleted file mode 100644
        \\--- a/src/gone.zig
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-gone
        \\
    );
    const renamed = try expectFingerprint(
        \\diff --git a/src/old.zig b/src/new.zig
        \\similarity index 100%
        \\rename from src/old.zig
        \\rename to src/new.zig
        \\
    );
    try testing.expect(!added.eql(removed));
    try testing.expect(!added.eql(renamed));
    try testing.expect(!removed.eql(renamed));
}

const binary_diff =
    \\diff --git a/logo.png b/logo.png
    \\index 1111111..2222222 100644
    \\Binary files a/logo.png and b/logo.png differ
    \\
;

test "M22 read a binary File with blob ids has a fingerprint that follows each blob id" {
    try expectSame(binary_diff, binary_diff);
    try expectDifferent(binary_diff,
        \\diff --git a/logo.png b/logo.png
        \\index 3333333..2222222 100644
        \\Binary files a/logo.png and b/logo.png differ
        \\
    );
    try expectDifferent(binary_diff,
        \\diff --git a/logo.png b/logo.png
        \\index 1111111..3333333 100644
        \\Binary files a/logo.png and b/logo.png differ
        \\
    );
    // The length prefix keeps the boundary between the two ids.
    try expectDifferent(binary_diff,
        \\diff --git a/logo.png b/logo.png
        \\index 111111..12222222 100644
        \\Binary files a/logo.png and b/logo.png differ
        \\
    );
}

test "M22 read a binary File without blob ids is unverifiable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parser.parse(arena.allocator(),
        \\diff --git a/logo.png b/logo.png
        \\Binary files a/logo.png and b/logo.png differ
        \\
    );
    try testing.expectEqual(@as(?FileReviewFingerprint, null), fingerprint(parsed.files[0]));
}

test "M22 read a binary File with a space in its path is unverifiable" {
    // Git does not quote a space in a `diff --git` path, and a binary diff has
    // no `---` or `+++` line, so the parser cannot name these sides.
    const raws = [_][]const u8{
        \\diff --git a/my logo.png b/my logo.png
        \\index 1111111..2222222 100644
        \\Binary files a/my logo.png and b/my logo.png differ
        \\
        ,
        \\diff --git a/my logo.png b/my logo.png
        \\index 1111111..3333333 100644
        \\Binary files a/my logo.png and b/my logo.png differ
        \\
        ,
        \\diff --git a/my logo.png b/my logo.png
        \\new file mode 100644
        \\index 0000000..2222222
        \\Binary files /dev/null and b/my logo.png differ
        \\
        ,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (raws) |raw| {
        const parsed = try parser.parse(arena.allocator(), raw);
        try testing.expectEqual(@as(?FileReviewFingerprint, null), fingerprint(parsed.files[0]));
    }
}

test "M22 read a text File fingerprint ignores its index blob ids" {
    try expectSame(base_diff,
        \\diff --git a/src/a.zig b/src/a.zig
        \\index 1111111..2222222 100644
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,2 @@ fn main
        \\ keep
        \\-old
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ tail
        \\-before
        \\+after
        \\
    );
}

test "M22 read a refined byte size keeps the text and binary fingerprints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = (try parser.parse(arena.allocator(), base_diff)).files[0];
    var refined_text = text;
    refined_text.content = .{ .old = .{ .text = 120 }, .new = .{ .text = 140 } };
    try testing.expect(fingerprint(text).?.eql(fingerprint(refined_text).?));

    const binary = (try parser.parse(arena.allocator(), binary_diff)).files[0];
    var refined_binary = binary;
    refined_binary.content = .{ .old = .{ .binary = 120 }, .new = .{ .binary = 140 } };
    try testing.expect(fingerprint(binary).?.eql(fingerprint(refined_binary).?));
}

test "M22 read InMemoryFileReadStore keeps the FileReadStore contract" {
    var memory = InMemoryFileReadStore.init(testing.allocator);
    defer memory.deinit();
    try expectStoreContract(memory.store());
}
