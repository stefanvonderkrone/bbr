//! Local process ownership for a durable SubmissionRun (ADR-0011).
//!
//! The durable row says what work exists; this advisory lock says whether a
//! live local process owns it. A Guard identifies one lease: its first matching
//! `release` ends the lease and later releases of copied Guards are no-ops.
//! Lock-file existence carries no meaning.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const RemoteReviewIdentity = @import("store.zig").RemoteReviewIdentity;

pub const Guard = struct {
    ptr: ?*anyopaque,
    lease_id: u64,
    release_fn: *const fn (*anyopaque, u64) void,

    pub fn release(self: *Guard) void {
        const ptr = self.ptr orelse return;
        self.ptr = null;
        self.release_fn(ptr, self.lease_id);
    }
};

pub const SubmissionLocks = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        try_acquire: *const fn (*anyopaque, RemoteReviewIdentity) anyerror!?Guard,
    };

    /// Returns null when another live owner holds this PullRequest's lock.
    pub fn tryAcquire(self: SubmissionLocks, identity: RemoteReviewIdentity) !?Guard {
        return self.vtable.try_acquire(self.ptr, identity);
    }
};

pub const InMemorySubmissionLocks = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    next_lease_id: u64 = 1,

    const Entry = struct {
        identity: RemoteReviewIdentity,
        lease_id: ?u64,
    };

    pub fn init(allocator: Allocator) InMemorySubmissionLocks {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *InMemorySubmissionLocks) void {
        self.entries.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn locks(self: *InMemorySubmissionLocks) SubmissionLocks {
        return .{ .ptr = self, .vtable = &.{ .try_acquire = tryAcquireImpl } };
    }

    fn tryAcquireImpl(ptr: *anyopaque, identity: RemoteReviewIdentity) anyerror!?Guard {
        const self: *InMemorySubmissionLocks = @ptrCast(@alignCast(ptr));
        var entry: ?*Entry = null;
        for (self.entries.items) |*candidate| {
            if (RemoteReviewIdentity.eql(candidate.identity, identity)) {
                entry = candidate;
                break;
            }
        }
        if (entry) |existing| {
            if (existing.lease_id != null) return null;
        } else {
            const owned: RemoteReviewIdentity = .{
                .workspace = try self.arena.allocator().dupe(u8, identity.workspace),
                .repository = try self.arena.allocator().dupe(u8, identity.repository),
                .pull_request_id = identity.pull_request_id,
            };
            try self.entries.append(self.allocator, .{ .identity = owned, .lease_id = null });
            entry = &self.entries.items[self.entries.items.len - 1];
        }

        const lease_id = self.next_lease_id;
        self.next_lease_id += 1;
        entry.?.lease_id = lease_id;
        return .{ .ptr = self, .lease_id = lease_id, .release_fn = releaseLease };
    }

    fn releaseLease(ptr: *anyopaque, lease_id: u64) void {
        const self: *InMemorySubmissionLocks = @ptrCast(@alignCast(ptr));
        for (self.entries.items) |*entry| {
            if (entry.lease_id == lease_id) {
                entry.lease_id = null;
                break;
            }
        }
    }
};

pub const OsSubmissionLocks = struct {
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    active: std.ArrayList(Lease) = .empty,
    next_lease_id: u64 = 1,

    const Lease = struct {
        id: u64,
        file: std.Io.File,
    };

    /// `dir` is borrowed and must outlive every acquired Guard.
    pub fn init(allocator: Allocator, io: std.Io, dir: std.Io.Dir) OsSubmissionLocks {
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }

    pub fn deinit(self: *OsSubmissionLocks) void {
        for (self.active.items) |lease| lease.file.close(self.io);
        self.active.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn locks(self: *OsSubmissionLocks) SubmissionLocks {
        return .{ .ptr = self, .vtable = &.{ .try_acquire = tryAcquireImpl } };
    }

    fn tryAcquireImpl(ptr: *anyopaque, identity: RemoteReviewIdentity) anyerror!?Guard {
        const self: *OsSubmissionLocks = @ptrCast(@alignCast(ptr));
        const name = lockName(identity);
        const file = self.dir.createFile(self.io, &name, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        errdefer file.close(self.io);
        const lease_id = self.next_lease_id;
        self.next_lease_id += 1;
        try self.active.append(self.allocator, .{ .id = lease_id, .file = file });
        return .{ .ptr = self, .lease_id = lease_id, .release_fn = releaseLease };
    }

    fn releaseLease(ptr: *anyopaque, lease_id: u64) void {
        const self: *OsSubmissionLocks = @ptrCast(@alignCast(ptr));
        for (self.active.items, 0..) |lease, i| {
            if (lease.id != lease_id) continue;
            const removed = self.active.orderedRemove(i);
            removed.file.close(self.io);
            return;
        }
    }

    fn lockName(identity: RemoteReviewIdentity) [64]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(identity.workspace);
        hash.update(&.{0});
        hash.update(identity.repository);
        hash.update(&.{0});
        hash.update(std.mem.asBytes(&identity.pull_request_id));
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }
};

const testing = std.testing;

fn testKey(repository: []const u8, pull_request_id: u64) RemoteReviewIdentity {
    return .{ .workspace = "workspace", .repository = repository, .pull_request_id = pull_request_id };
}

test "in-memory lock reports live ownership and releases exactly by key" {
    var table = InMemorySubmissionLocks.init(testing.allocator);
    defer table.deinit();
    const locks = table.locks();
    var first = (try locks.tryAcquire(testKey("repo", 7))).?;
    var copied = first;
    try testing.expect((try locks.tryAcquire(testKey("repo", 7))) == null);

    var other = (try locks.tryAcquire(testKey("other", 7))).?;
    other.release();
    first.release();
    copied.release(); // same lease id: harmless after the authoritative release
    var reacquired = (try locks.tryAcquire(testKey("repo", 7))).?;
    reacquired.release();
}

test "OS lock is authoritative across adapters; file existence is not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var first_table = OsSubmissionLocks.init(testing.allocator, testing.io, tmp.dir);
    defer first_table.deinit();
    var second_table = OsSubmissionLocks.init(testing.allocator, testing.io, tmp.dir);
    defer second_table.deinit();
    const first_locks = first_table.locks();
    const second_locks = second_table.locks();

    var first = (try first_locks.tryAcquire(testKey("repo", 7))).?;
    try testing.expect((try second_locks.tryAcquire(testKey("repo", 7))) == null);
    first.release();

    // The lock file still exists, but the released kernel lock is acquirable.
    var second = (try second_locks.tryAcquire(testKey("repo", 7))).?;
    second.release();
}

test "OS releases an inherited Submission lock when the owning process exits" {
    if (!builtin.link_libc) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var owner = OsSubmissionLocks.init(testing.allocator, testing.io, tmp.dir);
    defer owner.deinit();
    var observer = OsSubmissionLocks.init(testing.allocator, testing.io, tmp.dir);
    defer observer.deinit();
    var guard = (try owner.locks().tryAcquire(testKey("repo", 7))).?;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // The child inherits the locked file description and deliberately
        // exits without running Guard.release, modeling abrupt termination.
        const delay: std.c.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.c.nanosleep(&delay, null);
        std.c._exit(0);
    }

    guard.release();
    try testing.expect((try observer.locks().tryAcquire(testKey("repo", 7))) == null);
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    var after_exit = (try observer.locks().tryAcquire(testKey("repo", 7))).?;
    after_exit.release();
}
