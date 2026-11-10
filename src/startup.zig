//! Startup Detection: the lookup that plain `bbr`, `bbr <repo-slug>`, and
//! `bbr detect` run.
//!
//! It has two steps. `inspect` reads only the GitClient, so it runs before the
//! TUI starts and never waits for the network. `detect` lists the
//! AdjacentPullRequests and runs on a worker after the TUI starts. Exactly one
//! AdjacentPullRequest opens its review Session. Every other result opens the
//! Browser with a Browser Start.
//!
//! The pasted URL path and the `<repo> <id>` path skip Startup Detection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("bitbucket/client.zig").Client;
const gitmod = @import("git/client.zig");
const GitClient = gitmod.GitClient;
const url = @import("bitbucket/url.zig");
const diagnostics = @import("diagnostics.zig");

/// What the caller passes through from argv.
pub const Input = struct {
    /// A pasted Bitbucket PR URL (highest precedence).
    url: ?[]const u8 = null,
    /// Explicit repo slug (else taken from the git remote).
    repo_slug: ?[]const u8 = null,
    /// Explicit PR id (with `repo_slug`, opens directly).
    id: ?u64 = null,
};

/// One PullRequest to open.
pub const Target = struct {
    repository: []const u8,
    id: u64,
};

/// The Repository that `detect` searches and the branch it searches for.
pub const Detection = struct {
    repository: []const u8,
    branch: []const u8,
    /// True when `<repo-slug>` named the Repository. A failed list then keeps
    /// that Repository expanded.
    named: bool,
};

/// A Browser Start: the expanded Repository and the focused PullRequest. The
/// Browser focuses an expanded Repository until its PullRequest row appears.
pub const Browse = struct {
    repository: ?[]const u8 = null,
    pull_request_id: ?u64 = null,
};

/// The local step: a Repository and branch to search, or a Browser Start.
pub const Inspection = union(enum) {
    detect: Detection,
    browse: Browse,
};

/// The remote step.
pub const Outcome = union(enum) {
    /// Exactly one AdjacentPullRequest.
    open: Target,
    browse: Browse,
    /// The list request failed. The Browser starts with `browse`.
    failed: struct { reason: anyerror, browse: Browse },
};

/// What the TUI starts with.
pub const Start = union(enum) {
    /// The URL path and the `<repo> <id>` path.
    open: Target,
    /// The TUI shows the Detecting Frame and runs `detect` on a worker.
    detect: Detection,
    browse: Browse,
};

/// The Start for argv. Only plain `bbr` and `bbr <repo-slug>` inspect Git.
/// The URL Workspace must match the Credential Workspace; the Client enforces
/// that on fetch.
pub fn start(allocator: Allocator, git: GitClient, workspace: []const u8, input: Input, diagnostic: diagnostics.Handle) !Start {
    if (input.url) |text| {
        const ref = try url.parse(text);
        return .{ .open = .{ .repository = try allocator.dupe(u8, ref.repo_slug), .id = ref.id } };
    }
    if (input.id) |id| return .{ .open = .{ .repository = input.repo_slug orelse return error.MissingRepository, .id = id } };
    return switch (inspect(allocator, git, workspace, input, diagnostic)) {
        .detect => |detection| .{ .detect = detection },
        .browse => |browse| .{ .browse = browse },
    };
}

/// Reads the current branch and the Remote. It takes no Client, so it sends
/// no request. Every Git error gives a Browser Start. The Start drops the
/// cause, so `inspect` records it once. The strings belong to `allocator`.
pub fn inspect(allocator: Allocator, git: GitClient, workspace: []const u8, input: Input, diagnostic: diagnostics.Handle) Inspection {
    if (input.repo_slug) |repository| {
        const branch = git.currentBranch(allocator) catch |err| return browseAfter(diagnostic, err, .{ .repository = repository });
        return .{ .detect = .{ .repository = repository, .branch = branch, .named = true } };
    }
    const remote = git.remote(allocator) catch |err| return browseAfter(diagnostic, err, .{});
    if (!std.ascii.eqlIgnoreCase(remote.workspace, workspace)) return .{ .browse = .{} };
    const branch = git.currentBranch(allocator) catch |err| return browseAfter(diagnostic, err, .{ .repository = remote.repo_slug });
    return .{ .detect = .{ .repository = remote.repo_slug, .branch = branch, .named = false } };
}

fn browseAfter(diagnostic: diagnostics.Handle, cause: anyerror, browse: Browse) Inspection {
    _ = diagnostic.failure(.read, .{ .zig = cause }, @src());
    return .{ .browse = browse };
}

/// Lists the open PullRequests whose source Branch is `detection.branch`. The
/// newest AdjacentPullRequest has the highest PullRequestId, because Bitbucket
/// assigns ids in creation order. The strings belong to `allocator`.
pub fn detect(allocator: Allocator, bb: Client, detection: Detection) Outcome {
    const matches = bb.listPullRequests(allocator, detection.repository, .{ .source_branch = detection.branch }) catch |err|
        return .{ .failed = .{
            .reason = err,
            .browse = if (detection.named) .{ .repository = detection.repository } else .{},
        } };
    if (matches.len == 1) return .{ .open = .{ .repository = detection.repository, .id = matches[0].id } };
    var newest: ?u64 = null;
    for (matches) |pr| newest = @max(newest orelse pr.id, pr.id);
    return .{ .browse = .{ .repository = detection.repository, .pull_request_id = newest } };
}

/// Prints the `bbr detect` outcome line. A failure adds its reason above it.
pub fn describe(outcome: Outcome, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const browse = switch (outcome) {
        .open => |target| return writer.print("resolved: open {s} #{d}\n", .{ target.repository, target.id }),
        .browse => |browse| browse,
        .failed => |failed| blk: {
            try writer.print("reason: {s}\n", .{@errorName(failed.reason)});
            break :blk failed.browse;
        },
    };
    const repository = browse.repository orelse return writer.writeAll("resolved: browser\n");
    if (browse.pull_request_id) |id| return writer.print("resolved: browser {s} expanded, focus #{d}\n", .{ repository, id });
    try writer.print("resolved: browser {s} expanded\n", .{repository});
}

// ---------------------------------------------------------------------------
// Tests: FakeGitClient and FakeHttpClient drive every Startup Detection path.
// ---------------------------------------------------------------------------
const testing = std.testing;
const FakeGitClient = gitmod.FakeGitClient;
const GitError = gitmod.GitError;
const FakeHttpClient = @import("http/fake_client.zig").FakeHttpClient;
const Credential = @import("bitbucket/credential.zig").Credential;

fn testCred() Credential {
    return .{ .username = "u", .token = "t", .workspace = "check24" };
}

const one_match =
    \\{ "values": [
    \\  { "id": 99, "title": "t", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } } ] }
;
const two_matches =
    \\{ "values": [
    \\  { "id": 100, "title": "a", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } },
    \\  { "id": 104, "title": "b", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } },
    \\  { "id": 99, "title": "c", "state": "OPEN",
    \\    "source": { "branch": { "name": "feature/x" } },
    \\    "destination": { "branch": { "name": "main" } } } ] }
;
const no_values = "{ \"values\": [] }";

fn expectBrowse(expected: Browse, actual: Browse) !void {
    if (expected.repository) |repository| try testing.expectEqualStrings(repository, actual.repository.?) else try testing.expect(actual.repository == null);
    try testing.expectEqual(expected.pull_request_id, actual.pull_request_id);
}

fn expectDetect(repository: []const u8, named: bool, inspection: Inspection) !void {
    try testing.expectEqualStrings(repository, inspection.detect.repository);
    try testing.expectEqualStrings("feature/x", inspection.detect.branch);
    try testing.expectEqual(named, inspection.detect.named);
}

test "M24 startup every Inspection and Outcome" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const remote: @import("git/remote.zig").Remote = .{ .workspace = "check24", .repo_slug = "pr-webapp" };

    // Inspection: a named Repository with a branch, then with each Git error.
    var git: FakeGitClient = .{ .branch = "feature/x" };
    try expectDetect("named", true, inspect(a, git.gitClient(), "check24", .{ .repo_slug = "named" }, .{}));
    for ([_]anyerror{ GitError.DetachedHead, GitError.NotAGitRepo, error.GitFailed }) |err| {
        git = .{ .branch = err, .remote_result = remote };
        try expectBrowse(.{ .repository = "named" }, (inspect(a, git.gitClient(), "check24", .{ .repo_slug = "named" }, .{})).browse);
    }
    // No argument: the Remote Repository, a detached HEAD, and no Remote.
    git = .{ .branch = "feature/x", .remote_result = remote };
    try expectDetect("pr-webapp", false, inspect(a, git.gitClient(), "check24", .{}, .{}));
    git = .{ .branch = GitError.DetachedHead, .remote_result = remote };
    try expectBrowse(.{ .repository = "pr-webapp" }, (inspect(a, git.gitClient(), "check24", .{}, .{})).browse);
    for ([_]anyerror{ GitError.NotAGitRepo, GitError.NoRemote }) |err| {
        git = .{ .branch = "feature/x", .remote_result = err };
        try expectBrowse(.{}, (inspect(a, git.gitClient(), "check24", .{}, .{})).browse);
    }

    // Outcome: one, several, and no AdjacentPullRequest.
    const detection: Detection = .{ .repository = "pr-webapp", .branch = "feature/x", .named = false };
    var http: FakeHttpClient = .{ .body = one_match };
    var outcome = detect(a, Client.init(http.httpClient(), testCred()), detection);
    try testing.expectEqualStrings("pr-webapp", outcome.open.repository);
    try testing.expectEqual(@as(u64, 99), outcome.open.id);

    http = .{ .body = two_matches };
    outcome = detect(a, Client.init(http.httpClient(), testCred()), detection);
    try expectBrowse(.{ .repository = "pr-webapp", .pull_request_id = 104 }, outcome.browse);

    http = .{ .body = no_values };
    outcome = detect(a, Client.init(http.httpClient(), testCred()), detection);
    try expectBrowse(.{ .repository = "pr-webapp" }, outcome.browse);

    // A failed list request: plain without an argument, expanded with one.
    http = .{ .status = 404, .body = "{}" };
    outcome = detect(a, Client.init(http.httpClient(), testCred()), detection);
    try testing.expectEqual(@as(anyerror, error.NotFound), outcome.failed.reason);
    try expectBrowse(.{}, outcome.failed.browse);
    var named = detection;
    named.named = true;
    outcome = detect(a, Client.init(http.httpClient(), testCred()), named);
    try expectBrowse(.{ .repository = "pr-webapp" }, outcome.failed.browse);
}

test "M24 startup a Remote in another Workspace gives a plain Browser, and ASCII case does not matter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var git: FakeGitClient = .{ .branch = "feature/x", .remote_result = .{ .workspace = "elsewhere", .repo_slug = "pr-webapp" } };
    try expectBrowse(.{}, (inspect(a, git.gitClient(), "check24", .{}, .{})).browse);
    git.branch = GitError.DetachedHead;
    try expectBrowse(.{}, (inspect(a, git.gitClient(), "check24", .{}, .{})).browse);

    git = .{ .branch = "feature/x", .remote_result = .{ .workspace = "Check24", .repo_slug = "pr-webapp" } };
    try expectDetect("pr-webapp", false, inspect(a, git.gitClient(), "CHECK24", .{}, .{}));
}

test "M24 startup the URL and the <repo> <id> paths open directly without Git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var git: FakeGitClient = .{ .branch = GitError.NotAGitRepo };

    const pasted = try start(a, git.gitClient(), "check24", .{ .url = "https://bitbucket.org/check24/pr-webapp/pull-requests/1726" }, .{});
    try testing.expectEqualStrings("pr-webapp", pasted.open.repository);
    try testing.expectEqual(@as(u64, 1726), pasted.open.id);

    const explicit = try start(a, git.gitClient(), "check24", .{ .repo_slug = "myrepo", .id = 7 }, .{});
    try testing.expectEqualStrings("myrepo", explicit.open.repository);
    try testing.expectEqual(@as(u64, 7), explicit.open.id);

    try expectBrowse(.{}, (try start(a, git.gitClient(), "check24", .{}, .{})).browse);
    git = .{ .branch = "feature/x" };
    try testing.expectEqualStrings("feature/x", (try start(a, git.gitClient(), "check24", .{ .repo_slug = "myrepo" }, .{})).detect.branch);
}

test "M24 startup describe prints each bbr detect line" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try describe(.{ .open = .{ .repository = "pr-webapp", .id = 99 } }, &writer);
    try describe(.{ .browse = .{ .repository = "pr-webapp", .pull_request_id = 104 } }, &writer);
    try describe(.{ .browse = .{ .repository = "pr-webapp" } }, &writer);
    try describe(.{ .browse = .{} }, &writer);
    try describe(.{ .failed = .{ .reason = error.NotFound, .browse = .{ .repository = "named" } } }, &writer);
    try describe(.{ .failed = .{ .reason = error.Unauthorized, .browse = .{} } }, &writer);
    try testing.expectEqualStrings(
        \\resolved: open pr-webapp #99
        \\resolved: browser pr-webapp expanded, focus #104
        \\resolved: browser pr-webapp expanded
        \\resolved: browser
        \\reason: NotFound
        \\resolved: browser named expanded
        \\reason: Unauthorized
        \\resolved: browser
        \\
    , writer.buffered());
}
