//! The `GitClient` seam: a ptr+vtable interface (same shape as `HttpClient`)
//! over the local `git` binary. M4 needs only the read-only inspection subset —
//! the current branch and the tracking Remote — to drive startup PR detection.
//! M14 extends that seam with the committed-data subset used by local review.
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
    /// A requested revision cannot be resolved to a commit.
    UnknownRef,
    /// Git has no locally recorded default branch for the selected Remote.
    NoDefaultBaseRef,
    /// A requested blob does not exist at the resolved commit.
    BlobNotFound,
};

/// Canonical Ref identity plus the commit captured for one Session.
pub const ResolvedRef = struct {
    canonical: []const u8,
    commit: []const u8,
};

pub const Worktree = struct {
    path: []const u8,
    head: []const u8,
    branch: ?[]const u8 = null,
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
        resolve_ref: *const fn (ptr: *anyopaque, allocator: Allocator, ref: []const u8) anyerror!ResolvedRef,
        default_base_ref: *const fn (ptr: *anyopaque, allocator: Allocator, source_ref: []const u8) anyerror![]u8,
        common_dir: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]u8,
        worktrees: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]Worktree,
        diff: *const fn (ptr: *anyopaque, allocator: Allocator, base_commit: []const u8, source_commit: []const u8) anyerror![]u8,
        blob: *const fn (ptr: *anyopaque, allocator: Allocator, commit: []const u8, path: []const u8) anyerror![]u8,
        repository_remote: *const fn (ptr: *anyopaque, allocator: Allocator, source_ref: []const u8) anyerror![]u8,
    };

    pub fn currentBranch(self: GitClient, allocator: Allocator) ![]u8 {
        return self.vtable.currentBranch(self.ptr, allocator);
    }

    pub fn remote(self: GitClient, allocator: Allocator) !Remote {
        return self.vtable.remote(self.ptr, allocator);
    }

    pub fn resolveRef(self: GitClient, allocator: Allocator, ref: []const u8) !ResolvedRef {
        return self.vtable.resolve_ref(self.ptr, allocator, ref);
    }

    pub fn defaultBaseRef(self: GitClient, allocator: Allocator, source_ref: []const u8) ![]u8 {
        return self.vtable.default_base_ref(self.ptr, allocator, source_ref);
    }

    pub fn commonDir(self: GitClient, allocator: Allocator) ![]u8 {
        return self.vtable.common_dir(self.ptr, allocator);
    }

    pub fn worktrees(self: GitClient, allocator: Allocator) ![]Worktree {
        return self.vtable.worktrees(self.ptr, allocator);
    }

    pub fn diff(self: GitClient, allocator: Allocator, base_commit: []const u8, source_commit: []const u8) ![]u8 {
        return self.vtable.diff(self.ptr, allocator, base_commit, source_commit);
    }

    pub fn blob(self: GitClient, allocator: Allocator, commit: []const u8, path: []const u8) ![]u8 {
        return self.vtable.blob(self.ptr, allocator, commit, path);
    }

    pub fn repositoryRemote(self: GitClient, allocator: Allocator, source_ref: []const u8) ![]u8 {
        return self.vtable.repository_remote(self.ptr, allocator, source_ref);
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
        .resolve_ref = resolveRef,
        .default_base_ref = defaultBaseRef,
        .common_dir = commonDir,
        .worktrees = worktrees,
        .diff = diff,
        .blob = blob,
        .repository_remote = repositoryRemote,
    };

    /// Run `git <args>` and return trimmed stdout owned by `allocator`. A
    /// non-zero exit maps to `on_fail` (so the caller distinguishes "not a repo"
    /// from "no remote"). Stderr is discarded.
    fn run(self: *ShellGitClient, allocator: Allocator, args: []const []const u8, on_fail: anyerror) ![]u8 {
        const stdout = try self.runRaw(allocator, args, on_fail);
        errdefer allocator.free(stdout);
        const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
        // Shrink to the trimmed extent so the caller owns exactly what it sees.
        if (trimmed.len != stdout.len) {
            const owned = try allocator.dupe(u8, trimmed);
            allocator.free(stdout);
            return owned;
        }
        return stdout;
    }

    /// Run Git while preserving stdout byte-for-byte. Diff and blob content use
    /// this path; metadata commands use `run`, which trims line endings.
    fn runRaw(self: *ShellGitClient, allocator: Allocator, args: []const []const u8, on_fail: anyerror) ![]u8 {
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

    fn resolveRef(ptr: *anyopaque, allocator: Allocator, ref: []const u8) anyerror!ResolvedRef {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const commit_expr = try std.fmt.allocPrint(sa, "{s}^{{commit}}", .{ref});
        const commit = try self.run(sa, &.{ "git", "rev-parse", "--verify", "--end-of-options", commit_expr }, error.UnknownRef);
        const symbolic = try self.run(sa, &.{ "git", "rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", ref }, error.UnknownRef);
        return .{
            .canonical = try allocator.dupe(u8, if (symbolic.len > 0) symbolic else commit),
            .commit = try allocator.dupe(u8, commit),
        };
    }

    fn defaultBaseRef(ptr: *anyopaque, allocator: Allocator, source_ref: []const u8) anyerror![]u8 {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        var remote_name: []const u8 = "origin";
        const heads = "refs/heads/";
        if (std.mem.startsWith(u8, source_ref, heads)) {
            const branch = source_ref[heads.len..];
            const key = try std.fmt.allocPrint(sa, "branch.{s}.remote", .{branch});
            remote_name = self.run(sa, &.{ "git", "config", "--get", key }, error.NoRemote) catch "origin";
            if (std.mem.eql(u8, remote_name, ".")) return error.NoDefaultBaseRef;
        }
        const remote_head = try std.fmt.allocPrint(sa, "refs/remotes/{s}/HEAD", .{remote_name});
        const base = try self.run(sa, &.{ "git", "symbolic-ref", remote_head }, error.NoDefaultBaseRef);
        return allocator.dupe(u8, base);
    }

    fn commonDir(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        return self.run(allocator, &.{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, error.NotAGitRepo);
    }

    fn worktrees(ptr: *anyopaque, allocator: Allocator) anyerror![]Worktree {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const raw = try self.run(scratch.allocator(), &.{ "git", "worktree", "list", "--porcelain" }, error.NotAGitRepo);

        var result: std.ArrayList(Worktree) = .empty;
        errdefer {
            for (result.items) |tree| {
                allocator.free(tree.path);
                allocator.free(tree.head);
                if (tree.branch) |branch| allocator.free(branch);
            }
            result.deinit(allocator);
        }
        var path: ?[]const u8 = null;
        var head: ?[]const u8 = null;
        var branch: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                if (path != null and head != null) {
                    try result.append(allocator, .{
                        .path = try allocator.dupe(u8, path.?),
                        .head = try allocator.dupe(u8, head.?),
                        .branch = if (branch) |name| try allocator.dupe(u8, name) else null,
                    });
                }
                path = null;
                head = null;
                branch = null;
            } else if (std.mem.startsWith(u8, line, "worktree ")) {
                path = line["worktree ".len..];
            } else if (std.mem.startsWith(u8, line, "HEAD ")) {
                head = line["HEAD ".len..];
            } else if (std.mem.startsWith(u8, line, "branch ")) {
                branch = line["branch ".len..];
            }
        }
        if (path != null and head != null) {
            try result.append(allocator, .{
                .path = try allocator.dupe(u8, path.?),
                .head = try allocator.dupe(u8, head.?),
                .branch = if (branch) |name| try allocator.dupe(u8, name) else null,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    fn diff(ptr: *anyopaque, allocator: Allocator, base_commit: []const u8, source_commit: []const u8) anyerror![]u8 {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        return self.runRaw(allocator, &.{ "git", "diff", "--find-renames", "--no-ext-diff", "--no-color", base_commit, source_commit }, error.UnknownRef);
    }

    fn blob(ptr: *anyopaque, allocator: Allocator, commit: []const u8, path: []const u8) anyerror![]u8 {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const spec = try std.fmt.allocPrint(scratch.allocator(), "{s}:{s}", .{ commit, path });
        const contents = try self.runRaw(scratch.allocator(), &.{ "git", "show", spec }, error.BlobNotFound);
        return allocator.dupe(u8, contents);
    }

    fn repositoryRemote(ptr: *anyopaque, allocator: Allocator, source_ref: []const u8) anyerror![]u8 {
        const self: *ShellGitClient = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var remote_name: []const u8 = "origin";
        const heads = "refs/heads/";
        if (std.mem.startsWith(u8, source_ref, heads)) {
            const branch = source_ref[heads.len..];
            const key = try std.fmt.allocPrint(sa, "branch.{s}.remote", .{branch});
            remote_name = self.run(sa, &.{ "git", "config", "--get", key }, error.NoRemote) catch "origin";
            if (std.mem.eql(u8, remote_name, ".")) return error.NoRemote;
        }
        const url = try self.run(sa, &.{ "git", "remote", "get-url", remote_name }, error.NoRemote);
        return remote_mod.normalize(allocator, url, try self.readInsteadOf(sa));
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
    resolved_ref: anyerror!ResolvedRef = error.UnknownRef,
    default_base: anyerror![]const u8 = error.NoDefaultBaseRef,
    common_dir_result: anyerror![]const u8 = error.NotAGitRepo,
    worktree_result: anyerror![]const Worktree = error.NotAGitRepo,
    diff_result: anyerror![]const u8 = error.UnknownRef,
    blob_result: anyerror![]const u8 = error.BlobNotFound,
    repository_remote_result: anyerror![]const u8 = error.NoRemote,
    diff_calls: usize = 0,

    pub fn gitClient(self: *FakeGitClient) GitClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: GitClient.VTable = .{
        .currentBranch = currentBranch,
        .remote = remote,
        .resolve_ref = resolveRef,
        .default_base_ref = defaultBaseRef,
        .common_dir = commonDir,
        .worktrees = worktrees,
        .diff = diff,
        .blob = blob,
        .repository_remote = repositoryRemote,
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

    fn resolveRef(ptr: *anyopaque, allocator: Allocator, _: []const u8) anyerror!ResolvedRef {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        const ref = try self.resolved_ref;
        return .{ .canonical = try allocator.dupe(u8, ref.canonical), .commit = try allocator.dupe(u8, ref.commit) };
    }

    fn defaultBaseRef(ptr: *anyopaque, allocator: Allocator, _: []const u8) anyerror![]u8 {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, try self.default_base);
    }

    fn commonDir(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, try self.common_dir_result);
    }

    fn worktrees(ptr: *anyopaque, allocator: Allocator) anyerror![]Worktree {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        const source = try self.worktree_result;
        const copy = try allocator.alloc(Worktree, source.len);
        errdefer allocator.free(copy);
        for (source, 0..) |tree, i| copy[i] = .{
            .path = try allocator.dupe(u8, tree.path),
            .head = try allocator.dupe(u8, tree.head),
            .branch = if (tree.branch) |branch| try allocator.dupe(u8, branch) else null,
        };
        return copy;
    }

    fn diff(ptr: *anyopaque, allocator: Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        self.diff_calls += 1;
        return allocator.dupe(u8, try self.diff_result);
    }

    fn blob(ptr: *anyopaque, allocator: Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, try self.blob_result);
    }

    fn repositoryRemote(ptr: *anyopaque, allocator: Allocator, _: []const u8) anyerror![]u8 {
        const self: *FakeGitClient = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, try self.repository_remote_result);
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

test "shell client resolves refs and acquires committed review material" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(repo_path);

    try runTestProcess(repo_path, &.{ "git", "init", "-b", "main" });
    try runTestProcess(repo_path, &.{ "git", "config", "user.email", "reviewer@example.test" });
    try runTestProcess(repo_path, &.{ "git", "config", "user.name", "Reviewer" });
    try runTestProcess(repo_path, &.{ "sh", "-c", "printf 'old\\n' > f.zig" });
    try runTestProcess(repo_path, &.{ "git", "add", "f.zig" });
    try runTestProcess(repo_path, &.{ "git", "commit", "-m", "base" });
    try runTestProcess(repo_path, &.{ "git", "remote", "add", "origin", "https://example.test/team/repo.git" });
    try runTestProcess(repo_path, &.{ "git", "update-ref", "refs/remotes/origin/main", "HEAD" });
    try runTestProcess(repo_path, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    try runTestProcess(repo_path, &.{ "git", "switch", "-c", "feature" });
    try runTestProcess(repo_path, &.{ "git", "config", "branch.feature.remote", "origin" });
    try runTestProcess(repo_path, &.{ "git", "config", "branch.feature.merge", "refs/heads/feature" });
    try runTestProcess(repo_path, &.{ "sh", "-c", "printf 'new\\n' > f.zig" });
    try runTestProcess(repo_path, &.{ "git", "commit", "-am", "feature" });

    var shell = ShellGitClient.init(testing.allocator, testing.io);
    shell.cwd = .{ .path = repo_path };
    const client = shell.gitClient();

    const source = try client.resolveRef(testing.allocator, "feature");
    defer testing.allocator.free(source.canonical);
    defer testing.allocator.free(source.commit);
    try testing.expectEqualStrings("refs/heads/feature", source.canonical);
    try testing.expectEqual(@as(usize, 40), source.commit.len);

    const base_name = try client.defaultBaseRef(testing.allocator, source.canonical);
    defer testing.allocator.free(base_name);
    try testing.expectEqualStrings("refs/remotes/origin/main", base_name);
    const base = try client.resolveRef(testing.allocator, base_name);
    defer testing.allocator.free(base.canonical);
    defer testing.allocator.free(base.commit);

    const raw = try client.diff(testing.allocator, base.commit, source.commit);
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "-old") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "+new") != null);

    const contents = try client.blob(testing.allocator, source.commit, "f.zig");
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("new\n", contents);

    const common = try client.commonDir(testing.allocator);
    defer testing.allocator.free(common);
    try testing.expect(std.mem.endsWith(u8, common, "/.git"));
    const normalized_remote = try client.repositoryRemote(testing.allocator, source.canonical);
    defer testing.allocator.free(normalized_remote);
    try testing.expectEqualStrings("example.test/team/repo", normalized_remote);
    const trees = try client.worktrees(testing.allocator);
    defer {
        for (trees) |tree| {
            testing.allocator.free(tree.path);
            testing.allocator.free(tree.head);
            if (tree.branch) |branch| testing.allocator.free(branch);
        }
        testing.allocator.free(trees);
    }
    try testing.expectEqual(@as(usize, 1), trees.len);
    try testing.expectEqualStrings("refs/heads/feature", trees[0].branch.?);

    try runTestProcess(repo_path, &.{ "git", "config", "branch.feature.remote", "." });
    try testing.expectError(error.NoDefaultBaseRef, client.defaultBaseRef(testing.allocator, source.canonical));
}

fn runTestProcess(cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.TestProcessFailed,
        else => return error.TestProcessFailed,
    }
}
