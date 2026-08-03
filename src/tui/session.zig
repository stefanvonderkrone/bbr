//! A loaded review session and the blocking acquisition that builds one. Each
//! Session owns everything the viewer renders. ReviewHeader, Diff, and Threads
//! live in its private arena; lazily acquired File Enrichment sides retain
//! their transferred arenas so switching PRs is still "build, swap, destroy".
//!
//! The arena is backed by a caller-supplied allocator. When a Session is built
//! off-thread (the async Picker switch, app.zig), that backing is the stateless
//! `page_allocator` so the worker never races the main thread's allocator.
//!
//! `loadWith` takes an HttpClient seam and is therefore testable with a fake;
//! `load` wraps it with a real StdHttpClient for production use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const bbr = @import("bbr");
const file_enrichment = @import("file_enrichment.zig");

const PullRequest = bbr.bitbucket.PullRequest;
const Client = bbr.bitbucket.Client;
const Credential = bbr.bitbucket.Credential;

pub const ReviewHeader = struct {
    title: []const u8,
    source_ref: []const u8,
    base_ref: []const u8,
    source_commit: []const u8,
    base_commit: []const u8,
    author: ?[]const u8 = null,
    locator: []const u8,
    source_label: []const u8,
    pull_request_id: ?u64 = null,
};

pub const LocalContext = struct {
    common_dir: []const u8,
};

pub const SourceContext = union(enum) {
    remote: PullRequest,
    local: LocalContext,
};

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    header: ReviewHeader,
    source: SourceContext,
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    enrichment: file_enrichment.Storage,

    /// Free transferred File Enrichment sides, the Session arena, and finally
    /// the Session struct itself.
    pub fn destroy(self: *Session) void {
        const backing = self.arena.child_allocator;
        self.enrichment.deinit();
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn initializeEnrichment(self: *Session) !void {
        const next = try file_enrichment.Storage.init(self.arena.allocator(), self.diff.files);
        self.enrichment.deinit();
        self.enrichment = next;
    }

    pub fn remotePullRequest(self: *Session) ?*PullRequest {
        return switch (self.source) {
            .remote => |*pr| pr,
            .local => null,
        };
    }

    pub fn remotePullRequestConst(self: *const Session) ?*const PullRequest {
        return switch (self.source) {
            .remote => |*pr| pr,
            .local => null,
        };
    }
};

/// Allocate an empty Session (arena initialized, fields unset) so a caller can
/// fill it from data it owns — used by the offline `demo`, which has no network
/// fetch. Fill `header`, `source`, `diff`, and `threads` using its arena.
pub fn create(backing: Allocator) !*Session {
    const s = try backing.create(Session);
    errdefer backing.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(backing);
    errdefer s.arena.deinit();
    s.threads = &.{};
    s.enrichment = try file_enrichment.Storage.init(s.arena.allocator(), &.{});
    return s;
}

/// Build a Session for `repo`/`id` over an existing Bitbucket client. Fetches
/// the PR, its diff, and its comments, parses the diff, and nests the comment
/// threads — all into the Session's own arena. On any error the partial Session
/// is torn down and the error propagates.
pub fn loadWith(backing: Allocator, bb: Client, repo: []const u8, id: u64) !*Session {
    const s = try backing.create(Session);
    errdefer backing.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(backing);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    const pr = try bb.getPullRequest(a, repo, id);
    s.source = .{ .remote = pr };
    s.header = .{
        .title = pr.title,
        .source_ref = pr.source_branch,
        .base_ref = pr.destination_branch,
        .source_commit = pr.source_commit,
        .base_commit = pr.destination_commit,
        .author = pr.author_display_name,
        .locator = repo,
        .source_label = "Bitbucket",
        .pull_request_id = pr.id,
    };
    const raw = try bb.getDiff(a, repo, id);
    var diff_source: bbr.diff.TextDiffSource = .{ .text = raw };
    s.diff = try bbr.diff.loadFromSource(a, diff_source.source());
    s.enrichment = try file_enrichment.Storage.init(a, s.diff.files);
    errdefer s.enrichment.deinit();
    const comments = try bb.getComments(a, repo, id, .{
        .source = pr.source_commit,
        .destination = pr.destination_commit,
    });
    s.threads = try bbr.review.buildThreads(a, comments);

    return s;
}

/// Build a committed local Session through the same DiffSource/parser path.
/// `source_ref` defaults to the current Worktree branch; `base_ref` defaults to
/// the selected Remote's locally recorded HEAD and is never guessed otherwise.
pub fn loadLocalWith(
    backing: Allocator,
    git: bbr.git.GitClient,
    base_ref: ?[]const u8,
    source_ref: ?[]const u8,
) !*Session {
    const s = try backing.create(Session);
    errdefer backing.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(backing);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    const source_input = if (source_ref) |ref| try a.dupe(u8, ref) else try git.currentBranch(a);
    const source = try git.resolveRef(a, source_input);
    const base_input = if (base_ref) |ref| try a.dupe(u8, ref) else try git.defaultBaseRef(a, source.canonical);
    const base = try git.resolveRef(a, base_input);
    const common_dir = try git.commonDir(a);

    var diff_source: bbr.diff.GitDiffSource = .{
        .git = git,
        .base_commit = base.commit,
        .source_commit = source.commit,
    };
    s.diff = try bbr.diff.loadFromSource(a, diff_source.source());
    s.enrichment = try file_enrichment.Storage.init(a, s.diff.files);
    errdefer s.enrichment.deinit();
    s.threads = &.{};
    s.source = .{ .local = .{ .common_dir = common_dir } };
    s.header = .{
        .title = "Local review",
        .source_ref = source.canonical,
        .base_ref = base.canonical,
        .source_commit = source.commit,
        .base_commit = base.commit,
        .locator = common_dir,
        .source_label = "Git",
    };
    return s;
}

/// Production entry: construct a real StdHttpClient (backed by `backing`, which
/// must be thread-safe — pass `std.heap.page_allocator` from a worker) and load.
pub fn load(
    io: Io,
    backing: Allocator,
    env_map: *const std.process.Environ.Map,
    cred: Credential,
    repo: []const u8,
    id: u64,
) !*Session {
    var stdhttp = bbr.http.StdHttpClient.init(backing, io);
    defer stdhttp.deinit();

    // Proxy structs must outlive the client; a short-lived arena spanning the
    // fetch is enough (the client is deinited before we return).
    var proxy_arena = std.heap.ArenaAllocator.init(backing);
    defer proxy_arena.deinit();
    try stdhttp.initDefaultProxies(proxy_arena.allocator(), env_map);

    const bb = Client.init(stdhttp.httpClient(), cred);
    return loadWith(backing, bb, repo, id);
}

// ---------------------------------------------------------------------------
// Tests — loadWith over a scripted FakeHttpClient (no network).
// ---------------------------------------------------------------------------
const testing = std.testing;
const FakeHttpClient = bbr.http.FakeHttpClient;
const Canned = bbr.http.Canned;

test "loadWith builds a session in order and owns everything" {
    const pr_json =
        \\{ "id": 7, "title": "T", "state": "OPEN",
        \\  "author": { "display_name": "Ada" },
        \\  "source": { "branch": { "name": "feature/x" }, "commit": { "hash": "aaaa" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "bbbb" } } }
    ;
    const diff_text =
        "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n@@ -1 +1 @@\n-a\n+b\n";
    const comments_json =
        \\{ "values": [
        \\  { "id": 1, "content": { "raw": "nice" },
        \\    "user": { "display_name": "Ada" } } ] }
    ;
    // getPullRequest, getDiff, getComments (one page) in that order.
    const responses = [_]Canned{
        .{ .status = 200, .body = pr_json },
        .{ .status = 200, .body = diff_text },
        .{ .status = 200, .body = comments_json },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });

    const s = try loadWith(std.heap.page_allocator, bb, "repo", 7);
    defer s.destroy();

    try testing.expectEqual(@as(?u64, 7), s.header.pull_request_id);
    try testing.expectEqualStrings("feature/x", s.header.source_ref);
    try testing.expect(s.remotePullRequestConst() != null);
    try testing.expectEqual(@as(usize, 1), s.diff.files.len);
    try testing.expectEqual(@as(usize, 1), s.threads.len);
    try testing.expectEqual(@as(usize, 3), fake.call_count);

    try testing.expectEqual(@as(usize, 1), s.enrichment.len());
    const projection = s.enrichment.projection();
    try testing.expect(projection.blobs[0].new == null);
    try testing.expect(s.enrichment.status(0).old == .pending);
    try testing.expect(s.enrichment.status(0).new == .pending);
}

test "loadLocalWith resolves defaults and builds a source-neutral Session" {
    const raw =
        "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n" ++
        "@@ -1 +1 @@\n-old\n+new\n";
    var fake: bbr.git.FakeGitClient = .{
        .branch = "feature",
        .resolved_ref = .{ .canonical = "refs/heads/feature", .commit = "source-hash" },
        .default_base = "refs/remotes/origin/main",
        .common_dir_result = "/repo/.git",
        .diff_result = raw,
    };
    // The fake returns one canned resolution, so pass a base spelling whose
    // identity is not asserted here; the shell integration test covers both.
    const s = try loadLocalWith(std.heap.page_allocator, fake.gitClient(), "main", null);
    defer s.destroy();

    try testing.expectEqualStrings("Git", s.header.source_label);
    try testing.expectEqualStrings("refs/heads/feature", s.header.source_ref);
    try testing.expectEqualStrings("source-hash", s.header.source_commit);
    try testing.expect(s.header.pull_request_id == null);
    try testing.expect(s.remotePullRequestConst() == null);
    try testing.expectEqual(@as(usize, 1), s.diff.files.len);
    try testing.expectEqual(@as(usize, 0), s.threads.len);
}

test "loadWith surfaces an error and leaks nothing" {
    var fake: FakeHttpClient = .{ .status = 404, .body = "" };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    try testing.expectError(error.NotFound, loadWith(std.heap.page_allocator, bb, "repo", 7));
}
