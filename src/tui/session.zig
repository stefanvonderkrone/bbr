//! A loaded PR review session and the (blocking) fetch that builds one. Each
//! Session owns everything the viewer renders. PullRequest, Diff, and Threads
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

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    pr: PullRequest,
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
};

/// Allocate an empty Session (arena initialized, fields unset) so a caller can
/// fill it from data it owns — used by the offline `demo`, which has no network
/// fetch. Fill `pr`, `diff`, and `threads` using `s.arena.allocator()`.
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

    s.pr = try bb.getPullRequest(a, repo, id);
    const raw = try bb.getDiff(a, repo, id);
    s.diff = try bbr.diff.parse(a, raw);
    s.enrichment = try file_enrichment.Storage.init(a, s.diff.files);
    errdefer s.enrichment.deinit();
    const comments = try bb.getComments(a, repo, id, .{
        .source = s.pr.source_commit,
        .destination = s.pr.destination_commit,
    });
    s.threads = try bbr.review.buildThreads(a, comments);

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

    try testing.expectEqual(@as(u64, 7), s.pr.id);
    try testing.expectEqualStrings("feature/x", s.pr.source_branch);
    try testing.expectEqual(@as(usize, 1), s.diff.files.len);
    try testing.expectEqual(@as(usize, 1), s.threads.len);
    try testing.expectEqual(@as(usize, 3), fake.call_count);

    try testing.expectEqual(@as(usize, 1), s.enrichment.len());
    const projection = s.enrichment.projection();
    try testing.expect(projection.blobs[0].new == null);
    try testing.expect(s.enrichment.status(0).old == .pending);
    try testing.expect(s.enrichment.status(0).new == .pending);
}

test "loadWith surfaces an error and leaks nothing" {
    var fake: FakeHttpClient = .{ .status = 404, .body = "" };
    const bb = Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    try testing.expectError(error.NotFound, loadWith(std.heap.page_allocator, bb, "repo", 7));
}
