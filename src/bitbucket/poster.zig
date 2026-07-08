//! The Bitbucket implementation of the `CommentPoster` seam (M10): it bridges a
//! `Submission`'s post/dedupe steps to the REST adapter. Kept out of `client.zig`
//! so the pure engine's seam and the wire adapter stay separate files, mirroring
//! how `SqliteStore` implements `PendingReviewStore`.
//!
//! `post` maps a draft (+ its resolved parent id) to a `NewComment`, POSTs it,
//! and classifies the result: a classified `ApiError` is a definite `rejected`
//! (no comment created); any other failure — a transport error before a response
//! — is `ambiguous` (the request may have posted). `findExisting` is the dedupe
//! lookup an ambiguous retry uses: it fetches the PR's comments and returns the
//! id of one already matching this draft's anchor and body.
//!
//! `allocator` is per-call scratch; pass an arena (the worker's page-allocator
//! arena in production) since neither method frees incrementally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const NewComment = client_mod.NewComment;
const deinitComments = client_mod.deinitComments;
const types = @import("types.zig");
const HeadCommits = types.HeadCommits;
const ApiError = types.ApiError;
const submission = @import("../review/submission.zig");
const CommentPoster = submission.CommentPoster;
const PostOutcome = submission.PostOutcome;
const Draft = @import("../review/draft.zig").Draft;
const comment = @import("../review/comment.zig");
const CommentId = comment.CommentId;
const Anchor = comment.Anchor;

pub const Poster = struct {
    client: Client,
    allocator: Allocator,
    repo_slug: []const u8,
    pr_id: u64,
    /// The PR's current head, for the dedupe fetch's outdated detection (unused
    /// by the match itself; safe to leave default).
    head: HeadCommits = .{},

    pub fn poster(self: *Poster) CommentPoster {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: CommentPoster.VTable = .{ .post = postImpl, .findExisting = findImpl };

    fn postImpl(ptr: *anyopaque, d: Draft, parent: ?CommentId) anyerror!PostOutcome {
        const self: *Poster = @ptrCast(@alignCast(ptr));
        const nc = NewComment{
            .body = d.body,
            // A reply inherits its parent's anchor server-side; send inline only
            // for a root anchored comment.
            .anchor = if (parent == null) d.anchor else null,
            .parent = parent,
        };
        const cid = self.client.createComment(self.allocator, self.repo_slug, self.pr_id, nc) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Unauthorized => return .{ .rejected = error.Unauthorized },
            error.Forbidden => return .{ .rejected = error.Forbidden },
            error.NotFound => return .{ .rejected = error.NotFound },
            error.RateLimited => return .{ .rejected = error.RateLimited },
            error.ServerError => return .{ .rejected = error.ServerError },
            error.UnexpectedStatus => return .{ .rejected = error.UnexpectedStatus },
            error.MalformedResponse => return .{ .rejected = error.MalformedResponse },
            // Any other error is a transport failure before a response arrived:
            // the POST may or may not have landed → ambiguous (dedupe on retry).
            else => return .ambiguous,
        };
        return .{ .posted = cid };
    }

    fn findImpl(ptr: *anyopaque, d: Draft) anyerror!?CommentId {
        const self: *Poster = @ptrCast(@alignCast(ptr));
        const comments = try self.client.getComments(self.allocator, self.repo_slug, self.pr_id, self.head);
        defer deinitComments(self.allocator, comments);
        for (comments) |c| {
            if (!std.mem.eql(u8, c.body, d.body)) continue;
            if (!anchorsMatch(c.anchor, d.anchor)) continue;
            return c.id;
        }
        return null;
    }
};

/// Two anchors match if both are absent, or both name the same path and the
/// same span — bottom (`from`/`to`) *and* top (`start_from`/`start_to`), so a
/// ranged draft doesn't dedupe against a single-line comment on its end line.
fn anchorsMatch(a: ?Anchor, b: ?Anchor) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.path, b.?.path) and
        a.?.from == b.?.from and a.?.to == b.?.to and
        a.?.start_from == b.?.start_from and a.?.start_to == b.?.start_to;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const FakeHttpClient = @import("../http/fake_client.zig").FakeHttpClient;

fn testClient(fake: *FakeHttpClient) Client {
    return Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "check24" });
}

test "post maps a successful POST to .posted with the new id" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 201, .body =
        \\{ "id": 4242 }
    };
    var p = Poster{ .client = testClient(&fake), .allocator = a, .repo_slug = "myrepo", .pr_id = 7 };
    const outcome = try p.poster().post(.{ .local_id = 1, .kind = .top_level, .body = "hi" }, null);
    try testing.expectEqual(@as(CommentId, 4242), outcome.posted);
}

test "post maps a classified non-2xx to .rejected" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 401, .body = "nope" };
    var p = Poster{ .client = testClient(&fake), .allocator = a, .repo_slug = "myrepo", .pr_id = 7 };
    const outcome = try p.poster().post(.{ .local_id = 1, .kind = .top_level, .body = "hi" }, null);
    try testing.expectEqual(ApiError.Unauthorized, outcome.rejected);
}

test "post maps a transport failure to .ambiguous" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .send_error = error.ConnectionResetByPeer };
    var p = Poster{ .client = testClient(&fake), .allocator = a, .repo_slug = "myrepo", .pr_id = 7 };
    const outcome = try p.poster().post(.{ .local_id = 1, .kind = .top_level, .body = "hi" }, null);
    try testing.expect(outcome == .ambiguous);
}

test "findExisting returns the id of a matching comment (dedupe)" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\  { "id": 11, "content": { "raw": "other" }, "user": { "display_name": "X" } },
        \\  { "id": 12, "content": { "raw": "needs a test" }, "user": { "display_name": "Y" },
        \\    "inline": { "path": "src/foo.zig", "to": 42 } } ] }
    };
    var p = Poster{ .client = testClient(&fake), .allocator = a, .repo_slug = "myrepo", .pr_id = 7 };

    const draft = Draft{ .local_id = 1, .kind = .inline_comment, .body = "needs a test", .anchor = .{ .path = "src/foo.zig", .to = 42 } };
    const hit = try p.poster().findExisting(draft);
    try testing.expectEqual(@as(?CommentId, 12), hit);

    // A body that isn't present yields no match.
    const miss = try p.poster().findExisting(.{ .local_id = 2, .kind = .top_level, .body = "unseen" });
    try testing.expect(miss == null);
}
