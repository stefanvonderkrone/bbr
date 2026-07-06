//! The `GitClient` seam: a ptr+vtable interface (same shape as `HttpClient`)
//! over the local `git` binary. M4 needs only the read-only inspection subset —
//! the current branch and the tracking Remote — to drive startup PR detection.
//! Diffing and ref resolution (for local review) land in M6.
//!
//! `ShellGitClient` shells out via `std.process.run`; `FakeGitClient` returns
//! canned values so resolution logic is testable without a real repo.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const remote_mod = @import("remote.zig");
const Remote = remote_mod.Remote;
const Rewrite = remote_mod.Rewrite;

pub const GitError = error{
    /// The working directory is not inside a git worktree.
    NotAGitRepo,
    /// No `origin` remote is configured.
    NoRemote,
    /// HEAD is detached — there is no current branch to match a PR against.
    DetachedHead,
};

pub const GitClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The current worktree's branch name, owned by `allocator`.
        currentBranch: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]u8,
        /// The tracking `origin` remote resolved to a Bitbucket workspace/repo.
        /// Both `Remote` slices are owned by `allocator`.
        remote: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!Remote,
    };

    pub fn currentBranch(self: GitClient, allocator: Allocator) ![]u8 {
        return self.vtable.currentBranch(self.ptr, allocator);
    }

    pub fn remote(self: GitClient, allocator: Allocator) !Remote {
        return self.vtable.remote(self.ptr, allocator);
    }
};

/// Real implementation: runs `git` in `cwd` (default: the process CWD).
pub const ShellGitClient = struct {
    gpa: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd = .inherit,

    pub fn init(gpa: Allocator, io: Io) ShellGitClient {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn gitClient(self: *ShellGitClient) GitClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: GitClient.VTable = .{
        .currentBranch = currentBranch,
        .remote = remote,
    };

    /// Run `git <args>` and return trimmed stdout owned by `allocator`. A
    /// non-zero exit maps to `on_fail` (so the caller distinguishes "not a repo"
    /// from "no remote"). Stderr is discarded.
    fn run(self: *ShellGitClient, allocator: Allocator, args: []const []const u8, on_fail: anyerror) ![]u8 {
        const res = std.process.run(allocator, self.io, .{
            .argv = args,
            .cwd = self.cwd,
        }) catch return on_fail;
        defer allocator.free(res.stderr);
        errdefer allocator.free(res.stdout);

        switch (res.term) {
            .exited => |code| if (code != 0) {
                allocator.free(res.stdout);
                return on_fail;
            },
            else => {
                allocator.free(res.stdout);
                return on_fail;
            },
        }

        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        // Shrink to the trimmed extent so the caller owns exactly what it sees.
        if (trimmed.len != res.stdout.len) {
            const owned = try allocator.dupe(u8, trimmed);
            allocator.free(res.stdout);
            return owned;
        }
        return res.stdout;
    }

    fn currentBranch(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        const branch = try self.run(
            allocator,
            &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
            error.NotAGitRepo,
        );
        errdefer allocator.free(branch);
        // `rev-parse --abbrev-ref HEAD` prints "HEAD" verbatim when detached.
        if (std.mem.eql(u8, branch, "HEAD")) {
            allocator.free(branch);
            return GitError.DetachedHead;
        }
        return branch;
    }

    fn remote(ptr: *anyopaque, allocator: Allocator) anyerror!Remote {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));

        // Everything transient (raw URL, config output, parsed rewrites) lives in
        // a scratch arena; only the final Remote is duped into `allocator`.
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const url = try self.run(sa, &.{ "git", "remote", "get-url", "origin" }, error.NoRemote);
        const rewrites = try self.readInsteadOf(sa);

        const r = try remote_mod.parse(url, rewrites);
        return .{
            .workspace = try allocator.dupe(u8, r.workspace),
            .repo_slug = try allocator.dupe(u8, r.repo_slug),
        };
    }

    /// Read `url.<base>.insteadOf` rewrites via `git config --get-regexp`. Git
    /// lowercases the key, so the output lines read `url.<base>.insteadof <alias>`.
    /// Returns an empty slice when none are configured. All memory is `sa`-owned.
    fn readInsteadOf(self: *ShellGitClient, sa: Allocator) ![]Rewrite {
        // A missing key makes git exit 1; treat that as "no rewrites".
        const out = self.run(sa, &.{ "git", "config", "--get-regexp", "url\\..*\\.insteadof" }, error.NoRemote) catch
            return &.{};

        var list: std.ArrayList(Rewrite) = .empty;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = line[0..sp];
            const alias = line[sp + 1 ..];
            const prefix = "url.";
            const suffix = ".insteadof";
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            if (!std.mem.endsWith(u8, key, suffix)) continue;
            const base = key[prefix.len .. key.len - suffix.len];
            if (base.len == 0 or alias.len == 0) continue;
            try list.append(sa, .{ .alias = alias, .base = base });
        }
        return list.toOwnedSlice(sa);
    }
};

/// Test double: returns canned values (or errors) for each seam call.
pub const FakeGitClient = struct {
    branch: anyerror![]const u8 = error.NotAGitRepo,
    remote_result: anyerror!Remote = error.NoRemote,

    pub fn gitClient(self: *FakeGitClient) GitClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: GitClient.VTable = .{
        .currentBranch = currentBranch,
        .remote = remote,
    };

    fn currentBranch(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        const b = try self.branch;
        return allocator.dupe(u8, b);
    }

    fn remote(ptr: *anyopaque, allocator: Allocator) anyerror!Remote {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        const r = try self.remote_result;
        return .{
            .workspace = try allocator.dupe(u8, r.workspace),
            .repo_slug = try allocator.dupe(u8, r.repo_slug),
        };
    }
};

const testing = std.testing;

test "fake reports the current branch" {
    var fake: FakeGitClient = .{ .branch = "feature/timeout" };
    const gc = fake.gitClient();
    const b = try gc.currentBranch(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("feature/timeout", b);
}

test "fake surfaces a detached-head error" {
    var fake: FakeGitClient = .{ .branch = GitError.DetachedHead };
    const gc = fake.gitClient();
    try testing.expectError(GitError.DetachedHead, gc.currentBranch(testing.allocator));
}

test "fake resolves a remote, caller owns the strings" {
    var fake: FakeGitClient = .{ .remote_result = .{ .workspace = "check24", .repo_slug = "pr-webapp" } };
    const gc = fake.gitClient();
    const r = try gc.remote(testing.allocator);
    defer testing.allocator.free(r.workspace);
    defer testing.allocator.free(r.repo_slug);
    try testing.expectEqualStrings("check24", r.workspace);
    try testing.expectEqualStrings("pr-webapp", r.repo_slug);
}

test "fake surfaces a missing remote" {
    var fake: FakeGitClient = .{ .remote_result = GitError.NoRemote };
    const gc = fake.gitClient();
    try testing.expectError(GitError.NoRemote, gc.remote(testing.allocator));
}
