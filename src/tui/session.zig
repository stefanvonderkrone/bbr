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
    acquisition_arenas: [4]?std.heap.ArenaAllocator = @splat(null),
    header: ReviewHeader,
    source: SourceContext,
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    enrichment: file_enrichment.Storage,
    /// Independently acquired mutation capability. A missing UUID never makes
    /// the read-only Session unusable.
    authenticated_account_uuid: ?[]const u8 = null,
    authenticated_account_unauthorized: bool = false,

    /// Free transferred File Enrichment sides, the Session arena, and finally
    /// the Session struct itself.
    pub fn destroy(self: *Session) void {
        const backing = self.arena.child_allocator;
        self.enrichment.deinit();
        self.arena.deinit();
        for (&self.acquisition_arenas) |*arena| if (arena.*) |*owned| owned.deinit();
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
    s.acquisition_arenas = @splat(null);
    errdefer s.arena.deinit();
    s.threads = &.{};
    s.enrichment = try file_enrichment.Storage.init(s.arena.allocator(), &.{});
    return s;
}

/// Build a Session for `repo`/`id` over an existing Bitbucket client. Fetches
/// the PR, its diff, and its comments, parses the diff, and nests the comment
/// threads — all into the Session's own arena. On any error the partial Session
/// is torn down and the error propagates.
pub fn loadWith(io: Io, backing: Allocator, bb: Client, repo: []const u8, id: u64) !*Session {
    var pr_branch: Branch(PullRequest) = .init(backing);
    var account_branch: Branch([]u8) = .init(backing);
    var diff_branch: Branch([]u8) = .init(backing);
    var comments_branch: Branch([]bbr.review.Comment) = .init(backing);
    var transfer = false;
    defer if (!transfer) {
        pr_branch.arena.deinit();
        account_branch.arena.deinit();
        diff_branch.arena.deinit();
        comments_branch.arena.deinit();
    };

    const Completion = union(enum) { pull_request: void, account: void, raw_diff: void, comments: void };
    var completion_buffer: [4]Completion = undefined;
    var select = Io.Select(Completion).init(io, &completion_buffer);
    defer select.group.await(io) catch {};
    var active: usize = 0;
    var comments_ready = false;
    var raw_diff_started = false;
    var comments_started = false;
    var required_failed = false;

    try select.concurrent(.pull_request, acquirePullRequest, .{ &pr_branch, bb, repo, id });
    active += 1;
    try select.concurrent(.account, acquireAccount, .{ &account_branch, bb });
    active += 1;

    while (active > 0) {
        switch (try select.await()) {
            .pull_request => {
                active -= 1;
                if (pr_branch.err != null) required_failed = true else comments_ready = true;
            },
            .account => active -= 1,
            .raw_diff => {
                active -= 1;
                if (diff_branch.err != null) required_failed = true;
            },
            .comments => {
                active -= 1;
                if (comments_branch.err != null) required_failed = true;
            },
        }
        while (active < 2 and !required_failed) {
            if (comments_ready and !comments_started) {
                const pr = pr_branch.value.?;
                try select.concurrent(.comments, acquireComments, .{ &comments_branch, bb, repo, id, pr.source_commit, pr.destination_commit });
                comments_started = true;
                active += 1;
            } else if (!raw_diff_started) {
                try select.concurrent(.raw_diff, acquireRawDiff, .{ &diff_branch, bb, repo, id });
                raw_diff_started = true;
                active += 1;
            } else break;
        }
    }

    if (pr_branch.err) |err| return err;
    if (diff_branch.err) |err| return err;
    if (comments_branch.err) |err| return err;

    const s = try backing.create(Session);
    errdefer backing.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(backing);
    s.acquisition_arenas = @splat(null);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    s.authenticated_account_uuid = account_branch.value;
    s.authenticated_account_unauthorized = if (account_branch.err) |err| err == error.Unauthorized else false;

    const pr = pr_branch.value.?;
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
    const raw = diff_branch.value.?;
    var diff_source: bbr.diff.TextDiffSource = .{ .text = raw };
    s.diff = try bbr.diff.loadFromSource(a, diff_source.source());
    s.enrichment = try file_enrichment.Storage.init(a, s.diff.files);
    errdefer s.enrichment.deinit();
    const comments = comments_branch.value.?;
    s.threads = try bbr.review.buildThreads(a, comments);
    const account_arena: ?std.heap.ArenaAllocator = if (account_branch.err == null)
        account_branch.arena
    else blk: {
        account_branch.arena.deinit();
        break :blk null;
    };
    s.acquisition_arenas = .{ pr_branch.arena, account_arena, diff_branch.arena, comments_branch.arena };
    transfer = true;

    return s;
}

/// Benchmark control for the opt-in acquisition gate. Production calls only
/// `loadWith`, so the repository has one production policy.
pub fn loadSequentialWith(backing: Allocator, bb: Client, repo: []const u8, id: u64) !*Session {
    const s = try backing.create(Session);
    errdefer backing.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(backing);
    s.acquisition_arenas = @splat(null);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    s.authenticated_account_uuid = bb.getAuthenticatedAccountUuid(a) catch |err| blk: {
        s.authenticated_account_unauthorized = err == error.Unauthorized;
        break :blk null;
    };
    const pr = try bb.getPullRequest(a, repo, id);
    s.source = .{ .remote = pr };
    s.header = remoteHeader(pr, repo);
    const raw = try bb.getDiff(a, repo, id);
    var diff_source: bbr.diff.TextDiffSource = .{ .text = raw };
    s.diff = try bbr.diff.loadFromSource(a, diff_source.source());
    s.enrichment = try file_enrichment.Storage.init(a, s.diff.files);
    errdefer s.enrichment.deinit();
    const comments = try bb.getComments(a, repo, id, .{ .source = pr.source_commit, .destination = pr.destination_commit });
    s.threads = try bbr.review.buildThreads(a, comments);
    return s;
}

fn remoteHeader(pr: PullRequest, repo: []const u8) ReviewHeader {
    return .{
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
}

fn Branch(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: ?T = null,
        err: ?anyerror = null,

        fn init(backing: Allocator) @This() {
            return .{ .arena = std.heap.ArenaAllocator.init(backing) };
        }
    };
}

fn acquirePullRequest(branch: *Branch(PullRequest), bb: Client, repo: []const u8, id: u64) void {
    branch.value = bb.getPullRequest(branch.arena.allocator(), repo, id) catch |err| {
        branch.err = err;
        return;
    };
}

fn acquireAccount(branch: *Branch([]u8), bb: Client) void {
    branch.value = bb.getAuthenticatedAccountUuid(branch.arena.allocator()) catch |err| {
        branch.err = err;
        return;
    };
}

fn acquireRawDiff(branch: *Branch([]u8), bb: Client, repo: []const u8, id: u64) void {
    branch.value = bb.getDiff(branch.arena.allocator(), repo, id) catch |err| {
        branch.err = err;
        return;
    };
}

fn acquireComments(branch: *Branch([]bbr.review.Comment), bb: Client, repo: []const u8, id: u64, source: []const u8, destination: []const u8) void {
    branch.value = bb.getComments(branch.arena.allocator(), repo, id, .{ .source = source, .destination = destination }) catch |err| {
        branch.err = err;
        return;
    };
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
    s.acquisition_arenas = @splat(null);
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
    return loadWith(io, backing, bb, repo, id);
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
        \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature/x" }, "commit": { "hash": "aaaa" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "bbbb" } },
        \\  "participants": [] }
    ;
    const diff_text =
        "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n@@ -1 +1 @@\n-a\n+b\n";
    const comments_json =
        \\{ "values": [
        \\  { "id": 1, "content": { "raw": "nice" },
        \\    "user": { "display_name": "Ada" } } ] }
    ;
    // Authenticated Account capability is independent, then the read-only load.
    const responses = [_]Canned{
        .{ .request_key = "/user", .status = 200, .body = "{ \"uuid\": \"{ada}\" }" },
        .{ .request_key = "/pullrequests/7/diff", .status = 200, .body = diff_text },
        .{ .request_key = "/pullrequests/7/comments", .status = 200, .body = comments_json },
        .{ .request_key = "/pullrequests/7", .status = 200, .body = pr_json },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });

    const s = try loadWith(testing.io, std.heap.page_allocator, bb, "repo", 7);
    defer s.destroy();

    try testing.expectEqual(@as(?u64, 7), s.header.pull_request_id);
    try testing.expectEqualStrings("feature/x", s.header.source_ref);
    try testing.expect(s.remotePullRequestConst() != null);
    try testing.expectEqual(@as(usize, 1), s.diff.files.len);
    try testing.expectEqual(@as(usize, 1), s.threads.len);
    try testing.expectEqualStrings("{ada}", s.authenticated_account_uuid.?);
    try testing.expectEqual(@as(usize, 4), fake.call_count);
    try testing.expect(fake.maxActiveRequests() <= 2);

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
    const responses = [_]Canned{
        .{ .request_key = "/user", .status = 200, .body = "{}" },
        .{ .request_key = "/pullrequests/7", .status = 404 },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    try testing.expectError(error.NotFound, loadWith(testing.io, std.heap.page_allocator, bb, "repo", 7));
    try testing.expect(fake.callCount() >= 2);
    try testing.expect(fake.callCount() <= 3);
}

test "Authenticated Account failure preserves a read-only Candidate Session" {
    const responses = testRemoteResponses(401);
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });

    const s = try loadWith(testing.io, std.heap.page_allocator, bb, "repo", 7);
    defer s.destroy();

    try testing.expect(s.authenticated_account_uuid == null);
    try testing.expect(s.authenticated_account_unauthorized);
    try testing.expectEqual(@as(usize, 1), s.diff.files.len);
}

test "each required acquisition failure rejects the Candidate Session" {
    for ([_]usize{ 1, 2, 3 }) |failed_index| {
        var responses = testRemoteResponses(200);
        responses[failed_index].status = 404;
        var fake: FakeHttpClient = .{ .responses = &responses };
        const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
        try testing.expectError(error.NotFound, loadWith(testing.io, std.heap.page_allocator, bb, "repo", 7));
    }
}

test "required failure reporting follows logical acquisition order" {
    var responses = testRemoteResponses(200);
    responses[1].status = 403;
    responses[2].status = 404;
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    try testing.expectError(error.Forbidden, loadWith(testing.io, std.heap.page_allocator, bb, "repo", 7));
}

test "required failure awaits started Authenticated Account acquisition" {
    var release_pr: std.atomic.Value(bool) = .init(false);
    var release_account: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var responses = testRemoteResponses(200);
    responses[0].released = &release_account;
    responses[3].released = &release_pr;
    responses[3].status = 404;
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var future = try testing.io.concurrent(loadFailureAndSignal, .{ testing.io, bb, &done });
    defer future.await(testing.io);
    defer {
        release_pr.store(true, .release);
        release_account.store(true, .release);
    }

    while (fake.callCount() < 2) std.atomic.spinLoopHint();
    release_pr.store(true, .release);
    while (fake.activeRequestCount() == 2) std.atomic.spinLoopHint();
    try testing.expect(!done.load(.acquire));
    release_account.store(true, .release);
    future.await(testing.io);
    try testing.expect(done.load(.acquire));
}

test "PullRequest completion gives Comments priority over RawDiff" {
    var release_pr: std.atomic.Value(bool) = .init(false);
    var release_account: std.atomic.Value(bool) = .init(false);
    var release_comments: std.atomic.Value(bool) = .init(false);
    var release_diff: std.atomic.Value(bool) = .init(false);
    const base = testRemoteResponses(200);
    const responses = [_]Canned{
        withRelease(base[0], &release_account),
        withRelease(base[1], &release_diff),
        withRelease(base[2], &release_comments),
        withRelease(base[3], &release_pr),
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    var claimed = false;
    var future = try testing.io.concurrent(loadTestSession, .{ testing.io, bb });
    defer {
        release_pr.store(true, .release);
        release_account.store(true, .release);
        release_comments.store(true, .release);
        release_diff.store(true, .release);
        if (future.await(testing.io)) |candidate| {
            if (!claimed) candidate.destroy();
        } else |_| {}
    }

    while (fake.callCount() < 2) std.atomic.spinLoopHint();
    release_pr.store(true, .release);
    while (fake.callCount() < 3) std.atomic.spinLoopHint();
    try testing.expect(std.mem.indexOf(u8, fake.lastUrl().?, "/comments") != null);
    release_account.store(true, .release);
    release_comments.store(true, .release);
    while (fake.callCount() < 4) std.atomic.spinLoopHint();
    release_diff.store(true, .release);

    const s = try future.await(testing.io);
    claimed = true;
    defer s.destroy();
    try testing.expectEqual(@as(usize, 2), fake.maxActiveRequests());
}

fn loadTestSession(io: Io, bb: Client) !*Session {
    return loadWith(io, std.heap.page_allocator, bb, "repo", 7);
}

fn loadFailureAndSignal(io: Io, bb: Client, done: *std.atomic.Value(bool)) void {
    if (loadWith(io, std.heap.page_allocator, bb, "repo", 7)) |candidate| candidate.destroy() else |_| {}
    done.store(true, .release);
}

fn withRelease(canned: Canned, released: *std.atomic.Value(bool)) Canned {
    var controlled = canned;
    controlled.released = released;
    return controlled;
}

fn testRemoteResponses(account_status: u16) [4]Canned {
    const pr_json =
        \\{ "id": 7, "title": "T", "state": "OPEN", "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature/x" }, "commit": { "hash": "aaaa" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "bbbb" } },
        \\  "participants": [] }
    ;
    const diff_text = "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n@@ -1 +1 @@\n-a\n+b\n";
    return .{
        .{ .request_key = "/user", .status = account_status, .body = "{ \"uuid\": \"{ada}\" }" },
        .{ .request_key = "/pullrequests/7/diff", .body = diff_text },
        .{ .request_key = "/pullrequests/7/comments", .body = "{ \"values\": [] }" },
        .{ .request_key = "/pullrequests/7", .body = pr_json },
    };
}
