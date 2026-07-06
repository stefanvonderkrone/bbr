//! Startup resolution: decide what the reviewer lands on when `bbr` launches.
//! The precedence (design doc §startup) is
//!
//!   pasted PR URL  →  explicit repo+id arg  →  auto-detect from the worktree.
//!
//! Auto-detect resolves the repo from the tracking Remote and lists the open
//! PRs opened from the current branch (the AdjacentPullRequest): exactly one
//! opens straight away, several raise a pre-filtered Picker, none falls back to
//! a Picker over *all* open PRs (the no-PR chooser). An empty repo yields
//! `empty`. The orchestration talks only to the GitClient and Bitbucket Client
//! seams, so it is exercised end to end with fakes — no git, no network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bitbucket = @import("bitbucket/client.zig");
const Client = bitbucket.Client;
const PullRequestSummary = @import("bitbucket/types.zig").PullRequestSummary;
const gitmod = @import("git/client.zig");
const GitClient = gitmod.GitClient;
const GitError = gitmod.GitError;
const url = @import("bitbucket/url.zig");

/// What the caller passes through from argv.
pub const Input = struct {
    /// A pasted Bitbucket PR URL (highest precedence).
    url: ?[]const u8 = null,
    /// Explicit repo slug (else taken from the git remote).
    repo_slug: ?[]const u8 = null,
    /// Explicit PR id (with `repo_slug`, opens directly).
    id: ?u64 = null,
};

/// The resolved landing point. All owned strings/slices belong to the allocator
/// passed to `resolve`; pass a session-scoped arena and none of it needs freeing.
pub const Entry = union(enum) {
    /// Open this PR directly.
    open: Target,
    /// Present a Picker; `prefiltered` distinguishes "PRs from your branch"
    /// from "all open PRs" (the no-PR fallback).
    pick: Picker,
    /// No open PRs in the repo at all; the field is the repo slug.
    empty: []const u8,
};

pub const Target = struct {
    repo_slug: []const u8,
    id: u64,
};

pub const Picker = struct {
    repo_slug: []const u8,
    /// True: filtered to the current branch. False: every open PR (fallback).
    prefiltered: bool,
    /// The current branch, or "" when detached/unknown (for the picker header).
    branch: []const u8,
    prs: []PullRequestSummary,
};

/// Resolve the startup entry. `git` and `bb` are seams; in tests they are fakes.
pub fn resolve(allocator: Allocator, git: GitClient, bb: Client, input: Input) !Entry {
    // 1. A pasted URL wins. We open by (repo, id); the URL's workspace must
    //    match the configured credential's workspace (cross-workspace review is
    //    out of scope for the MVP), which the caller's Client enforces on fetch.
    if (input.url) |u| {
        const ref = try url.parse(u);
        return .{ .open = .{
            .repo_slug = try allocator.dupe(u8, ref.repo_slug),
            .id = ref.id,
        } };
    }

    // 2. Explicit repo + id opens directly.
    if (input.id) |id| {
        const repo = try resolveRepo(allocator, git, input.repo_slug);
        return .{ .open = .{ .repo_slug = repo, .id = id } };
    }

    // 3. Auto-detect from the worktree.
    const repo = try resolveRepo(allocator, git, input.repo_slug);

    // The current branch drives the AdjacentPullRequest lookup. A detached HEAD
    // (or any branch error) just means "no branch to filter by" — fall through
    // to the all-open picker rather than failing.
    const branch: []const u8 = git.currentBranch(allocator) catch |err| switch (err) {
        GitError.DetachedHead => "",
        else => return err,
    };

    if (branch.len > 0) {
        const matches = try bb.listPullRequests(allocator, repo, .{ .source_branch = branch });
        switch (matches.len) {
            0 => {}, // fall through to the all-open picker
            1 => return .{ .open = .{ .repo_slug = repo, .id = matches[0].id } },
            else => return .{ .pick = .{
                .repo_slug = repo,
                .prefiltered = true,
                .branch = branch,
                .prs = matches,
            } },
        }
    }

    // 0 adjacent PRs (or detached HEAD): offer every open PR.
    const all = try bb.listPullRequests(allocator, repo, .{});
    if (all.len == 0) return .{ .empty = repo };
    return .{ .pick = .{
        .repo_slug = repo,
        .prefiltered = false,
        .branch = branch,
        .prs = all,
    } };
}

/// The repo slug: the explicit arg if given, else the tracking Remote's slug.
fn resolveRepo(allocator: Allocator, git: GitClient, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |r| return allocator.dupe(u8, r);
    const remote = try git.remote(allocator);
    // We only need the slug here; free the workspace copy the seam handed us.
    allocator.free(remote.workspace);
    return remote.repo_slug;
}

// ---------------------------------------------------------------------------
// Tests — FakeGitClient + FakeHttpClient drive every resolution branch.
// ---------------------------------------------------------------------------
const testing = std.testing;
const FakeGitClient = gitmod.FakeGitClient;
const FakeHttpClient = @import("http/fake_client.zig").FakeHttpClient;
const Credential = @import("bitbucket/credential.zig").Credential;

fn testCred() Credential {
    return .{ .username = "u", .token = "t", .workspace = "check24" };
}

test "a pasted URL opens that PR directly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{}; // untouched by the URL path
    var http: FakeHttpClient = .{};
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{
        .url = "https://bitbucket.org/check24/pr-webapp/pull-requests/1726",
    });
    try testing.expect(entry == .open);
    try testing.expectEqualStrings("pr-webapp", entry.open.repo_slug);
    try testing.expectEqual(@as(u64, 1726), entry.open.id);
    try testing.expectEqual(@as(usize, 0), http.call_count); // no listing needed
}

test "explicit repo + id opens directly without touching the remote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{ .remote_result = GitError.NoRemote };
    var http: FakeHttpClient = .{};
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{ .repo_slug = "myrepo", .id = 7 });
    try testing.expect(entry == .open);
    try testing.expectEqualStrings("myrepo", entry.open.repo_slug);
    try testing.expectEqual(@as(u64, 7), entry.open.id);
}

const one_match =
    \\{ "values": [
    \\  { "id": 99, "title": "t", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } } ] }
;
const two_matches =
    \\{ "values": [
    \\  { "id": 99, "title": "a", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } },
    \\  { "id": 100, "title": "b", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } } ] }
;
const no_values = "{ \"values\": [] }";

test "one adjacent PR opens directly, repo from the remote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{
        .branch = "feature/x",
        .remote_result = .{ .workspace = "check24", .repo_slug = "pr-webapp" },
    };
    var http: FakeHttpClient = .{ .status = 200, .body = one_match };
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{});
    try testing.expect(entry == .open);
    try testing.expectEqualStrings("pr-webapp", entry.open.repo_slug);
    try testing.expectEqual(@as(u64, 99), entry.open.id);
}

test "several adjacent PRs raise a pre-filtered picker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{
        .branch = "feature/x",
        .remote_result = .{ .workspace = "check24", .repo_slug = "pr-webapp" },
    };
    var http: FakeHttpClient = .{ .status = 200, .body = two_matches };
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{});
    try testing.expect(entry == .pick);
    try testing.expect(entry.pick.prefiltered);
    try testing.expectEqualStrings("feature/x", entry.pick.branch);
    try testing.expectEqual(@as(usize, 2), entry.pick.prs.len);
}

test "no adjacent PR falls back to a picker over all open PRs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{
        .branch = "feature/x",
        .remote_result = .{ .workspace = "check24", .repo_slug = "pr-webapp" },
    };
    // 1st list (filtered) is empty; 2nd list (all open) returns two.
    const Canned = @import("http/fake_client.zig").Canned;
    const responses = [_]Canned{
        .{ .status = 200, .body = no_values },
        .{ .status = 200, .body = two_matches },
    };
    var http: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{});
    try testing.expect(entry == .pick);
    try testing.expect(!entry.pick.prefiltered);
    try testing.expectEqual(@as(usize, 2), entry.pick.prs.len);
    try testing.expectEqual(@as(usize, 2), http.call_count);
}

test "detached HEAD skips the branch filter and lists all open PRs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{
        .branch = GitError.DetachedHead,
        .remote_result = .{ .workspace = "check24", .repo_slug = "pr-webapp" },
    };
    var http: FakeHttpClient = .{ .status = 200, .body = two_matches };
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{});
    try testing.expect(entry == .pick);
    try testing.expect(!entry.pick.prefiltered);
    try testing.expectEqualStrings("", entry.pick.branch);
    try testing.expectEqual(@as(usize, 1), http.call_count); // only the all-open list
}

test "an empty repo yields empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{
        .branch = "feature/x",
        .remote_result = .{ .workspace = "check24", .repo_slug = "pr-webapp" },
    };
    var http: FakeHttpClient = .{ .status = 200, .body = no_values };
    const bb = Client.init(http.httpClient(), testCred());

    const entry = try resolve(a, git.gitClient(), bb, .{});
    try testing.expect(entry == .empty);
    try testing.expectEqualStrings("pr-webapp", entry.empty);
}
