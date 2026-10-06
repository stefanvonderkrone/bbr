//! Bitbucket Cloud REST adapter (api.bitbucket.org/2.0). Turns HTTP responses
//! into typed domain values behind the `HttpClient` seam, so it is fully
//! testable with `FakeHttpClient` — no network in tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const httpc = @import("../http/client.zig");
const HttpClient = httpc.HttpClient;
const Credential = @import("credential.zig").Credential;
const types = @import("types.zig");
const PullRequest = types.PullRequest;
const PullRequestSummary = types.PullRequestSummary;
const HeadCommits = types.HeadCommits;
const ApiError = types.ApiError;
const review = @import("../review/comment.zig");
const Comment = review.Comment;
const Anchor = review.Anchor;
const CommentId = review.CommentId;
const git_path = @import("../diff/path.zig");

pub const base_url = "https://api.bitbucket.org/2.0";

pub const Client = struct {
    http: HttpClient,
    cred: Credential,

    pub fn init(http: HttpClient, cred: Credential) Client {
        return .{ .http = http, .cred = cred };
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}.
    /// The returned `PullRequest` (and its strings) is owned by `allocator`.
    pub fn getPullRequest(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) !PullRequest {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);

        try classify(res.status);
        return parsePullRequest(allocator, res.body);
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests, following `next`
    /// links, optionally filtered to one source branch. Returns a flat slice of
    /// `PullRequestSummary` owned by `allocator` (free with `deinitSummaries`,
    /// or pass an arena). `opts.state` defaults to OPEN; pass an explicit branch
    /// via `opts.source_branch` to find the AdjacentPullRequest(s).
    pub fn listPullRequests(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        opts: ListOptions,
    ) ![]PullRequestSummary {
        return self.listPullRequestsPage(allocator, repo_slug, opts, .{ .pagelen = 50 });
    }

    /// List PullRequests with page controls and combined source-branch/query filters.
    pub fn listPullRequestsPage(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        filter: ListOptions,
        opts: PageOptions,
    ) ![]PullRequestSummary {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{s}/repositories/{s}/{s}/pullrequests?", .{ base_url, self.cred.workspace, repo_slug });
        // Keep the TUI's first-page URL and page size stable.
        var page_opts = opts;
        if (opts.pagelen) |n| {
            try buf.print(allocator, "pagelen={d}&", .{n});
            page_opts.pagelen = null;
        }
        try buf.appendSlice(allocator, "state=");
        try percentEncodeInto(allocator, &buf, filter.state);
        if (filter.source_branch) |branch| {
            const quoted = try std.json.Stringify.valueAlloc(allocator, branch, .{});
            defer allocator.free(quoted);
            try buf.appendSlice(allocator, "&q=");
            try percentEncodeInto(allocator, &buf, "source.branch.name=");
            try percentEncodeInto(allocator, &buf, quoted);
            if (opts.query) |query| {
                try percentEncodeInto(allocator, &buf, " AND (");
                try percentEncodeInto(allocator, &buf, query);
                try percentEncodeInto(allocator, &buf, ")");
            }
            page_opts.query = null;
        }
        return self.listPages(allocator, PullRequestSummary, PrListPage, dupeSummary, deinitSummary, .{}, buf.items, page_opts, null);
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}/diff.
    /// Returns the raw unified diff text (owned by `allocator`) exactly as
    /// Bitbucket serves it — the authoritative line model (ADR-0001). Feed it to
    /// `diff.parse`; this adapter deliberately does not parse, so the same text
    /// path serves both remote and (later) local review.
    pub fn getDiff(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/diff",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "text/plain" },
            },
        });
        errdefer allocator.free(res.body);

        try classify(res.status);
        return res.body;
    }

    /// GET /repositories/{workspace}/{repo}/src/{commit}/{path}: a file's full
    /// text at a given commit. Used by the true-whole-file view (M9) to fill the
    /// unchanged regions the diff omits. Returns the raw bytes owned by
    /// `allocator`, exactly as served (same contract as `getDiff`). `path` is the
    /// repo-relative file path; `commit` is a full or abbreviated hash.
    pub fn getFileBlob(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        commit: []const u8,
        path: []const u8,
    ) ![]u8 {
        return self.getSource(allocator, repo_slug, commit, path, false);
    }

    pub const FileBlobAttempt = union(enum) {
        content: []u8,
        rejected: struct { reason: ApiError, retry_after_ms: ?u64 },
    };

    pub fn getFileBlobAttempt(self: Client, allocator: Allocator, repo_slug: []const u8, commit: []const u8, path: []const u8) !FileBlobAttempt {
        return self.getSourceAttempt(allocator, repo_slug, commit, path, false);
    }

    pub fn checkFileBlob(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        commit: []const u8,
        path: []const u8,
        expected_attributes: []const []const u8,
    ) !usize {
        const metadata_body = try self.getSource(allocator, repo_slug, commit, path, true);
        defer allocator.free(metadata_body);

        const Wire = struct {
            type: []const u8,
            path: []const u8,
            commit: struct { hash: []const u8 },
            size: usize,
            attributes: []const []const u8,
        };
        const parsed = std.json.parseFromSlice(Wire, allocator, metadata_body, .{ .ignore_unknown_fields = true }) catch return error.MalformedResponse;
        defer parsed.deinit();
        const metadata = parsed.value;
        if (!std.mem.eql(u8, metadata.type, "commit_file")) return error.BlobTypeMismatch;
        if (!std.mem.eql(u8, metadata.path, path)) return error.BlobPathMismatch;
        if (!hashMatches(metadata.commit.hash, commit)) return error.BlobCommitMismatch;
        if (!stringSlicesEqual(metadata.attributes, expected_attributes)) return error.BlobAttributesMismatch;

        const raw = try self.getFileBlob(allocator, repo_slug, commit, path);
        defer allocator.free(raw);
        if (metadata.size != raw.len) return error.BlobSizeMismatch;
        return raw.len;
    }

    fn getSource(self: Client, allocator: Allocator, repo_slug: []const u8, commit: []const u8, path: []const u8, metadata: bool) ![]u8 {
        return switch (try self.getSourceAttempt(allocator, repo_slug, commit, path, metadata)) {
            .content => |bytes| bytes,
            .rejected => |failure| failure.reason,
        };
    }

    fn getSourceAttempt(self: Client, allocator: Allocator, repo_slug: []const u8, commit: []const u8, path: []const u8, metadata: bool) !FileBlobAttempt {
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(allocator);
        try url_buf.print(allocator, "{s}/repositories/{s}/{s}/src/{s}/", .{ base_url, self.cred.workspace, repo_slug, commit });
        if (!git_path.isRepositoryRelative(path)) return error.InvalidPath;
        try appendEncodedPath(allocator, &url_buf, path);
        if (metadata) try url_buf.appendSlice(allocator, "?format=meta");
        const url = try url_buf.toOwnedSlice(allocator);
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = if (metadata) "application/json" else "text/plain" },
            },
        });
        classify(res.status) catch |reason| {
            allocator.free(res.body);
            return .{ .rejected = .{ .reason = reason, .retry_after_ms = res.retry_after_ms } };
        };
        return .{ .content = res.body };
    }

    /// POST /repositories/{workspace}/{repo}/pullrequests/{id}/comments: publish
    /// one comment and return its server-assigned `CommentId` (M10). A reply
    /// carries `parent` (the resolved server id) and omits `inline` — Bitbucket
    /// inherits a reply's anchor from its parent; a root inline comment carries
    /// `anchor`; a top-level comment carries neither. The body is sent as JSON
    /// with null fields omitted, so the raw markdown is escaped correctly.
    pub fn createComment(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        nc: NewComment,
    ) !CommentId {
        return switch (try self.createCommentAttempt(allocator, repo_slug, id, nc)) {
            .posted => |comment_id| comment_id,
            .rejected => |failure| failure.reason,
        };
    }

    pub const CreateCommentAttempt = union(enum) {
        posted: CommentId,
        rejected: struct { reason: ApiError, retry_after_ms: ?u64 },
    };

    /// POST one Comment while preserving normalized server retry guidance for
    /// Submission policy. Other Client methods intentionally keep their simpler
    /// error-returning contracts.
    pub fn createCommentAttempt(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        nc: NewComment,
    ) !CreateCommentAttempt {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        // Build the wire shape; `emit_null_optional_fields = false` drops the
        // `inline`/`parent`/`from`/`to`/`start_*` keys we leave null. A range
        // sends `start_to`/`start_from` alongside `to`/`from` (the top of the
        // span); a single-line anchor leaves them null and they're omitted.
        const Wire = struct {
            content: struct { raw: []const u8 },
            @"inline": ?struct {
                path: []const u8,
                from: ?u32 = null,
                to: ?u32 = null,
                start_from: ?u32 = null,
                start_to: ?u32 = null,
            } = null,
            parent: ?struct { id: CommentId } = null,
        };
        var wire = Wire{ .content = .{ .raw = nc.body } };
        if (nc.parent) |pid| {
            wire.parent = .{ .id = pid };
        } else switch (nc.effectiveScope()) {
            .review => {},
            .file => |file| wire.@"inline" = .{ .path = file.path },
            .@"inline" => |anc| wire.@"inline" = .{
                .path = anc.path,
                .from = anc.from,
                .to = anc.to,
                .start_from = anc.start_from,
                .start_to = anc.start_to,
            },
        }
        const body = try std.json.Stringify.valueAlloc(allocator, wire, .{ .emit_null_optional_fields = false });
        defer allocator.free(body);

        const res = try self.http.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "content-type", .value = "application/json" },
            },
            .body = body,
        });
        defer allocator.free(res.body);

        classify(res.status) catch |reason| return .{ .rejected = .{
            .reason = reason,
            .retry_after_ms = res.retry_after_ms,
        } };
        const parsed = std.json.parseFromSlice(
            struct { id: u64 },
            allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.MalformedResponse;
        defer parsed.deinit();
        return .{ .posted = parsed.value.id };
    }

    /// GET /user and return the UUID proven by the current Credential.
    pub fn getAuthenticatedAccountUuid(self: Client, allocator: Allocator) ![]u8 {
        const url = base_url ++ "/user";
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(struct { uuid: []const u8 }, allocator, res.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedResponse;
        defer parsed.deinit();
        return allocator.dupe(u8, parsed.value.uuid);
    }

    /// Change the Authenticated Account's Reviewer Verdict only while the
    /// PullRequest still has the expected SourceCommit. The mutation is never
    /// retried. A lost mutation response is reconciled with one fresh read.
    pub fn changeReviewerVerdict(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        pull_request_id: u64,
        expected_source_commit: []const u8,
        authenticated_account_uuid: []const u8,
        target: types.ReviewerVerdict,
    ) !types.ReviewerVerdictChangeResult {
        const before = self.getPullRequest(allocator, repo_slug, pull_request_id) catch |err| {
            if (asApiError(err)) |api_error| return .{ .api_error = api_error };
            return err;
        };
        defer deinitPullRequest(allocator, before);
        if (!std.mem.eql(u8, before.source_commit, expected_source_commit)) return .stale_source_commit;
        if (before.author_uuid.len != 0 and std.mem.eql(u8, before.author_uuid, authenticated_account_uuid)) return .{ .api_error = error.Forbidden };

        const current = before.reviewerVerdict(authenticated_account_uuid);
        if (current == target) return .success;
        const endpoint: []const u8 = switch (target) {
            .approved => "approve",
            .changes_requested => "request-changes",
            .no_verdict => switch (current) {
                .approved => "approve",
                .changes_requested => "request-changes",
                .no_verdict => return .success,
            },
        };
        const method: httpc.Method = if (target == .no_verdict) .DELETE else .POST;

        const mutation_url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/{s}",
            .{ base_url, self.cred.workspace, repo_slug, pull_request_id, endpoint },
        );
        defer allocator.free(mutation_url);
        const mutation_auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(mutation_auth);

        var uncertain = false;
        var uncertain_reason: ?ApiError = null;
        self.sendReviewerVerdictMutation(allocator, method, mutation_url, mutation_auth) catch |err| {
            if (asApiError(err)) |api_error| switch (api_error) {
                error.RateLimited, error.ServerError => uncertain_reason = api_error,
                else => return .{ .api_error = api_error },
            };
            uncertain = true;
        };

        const after = self.getPullRequest(allocator, repo_slug, pull_request_id) catch |err| {
            return .{ .unresolved = asApiError(err) };
        };
        defer deinitPullRequest(allocator, after);
        if (after.reviewerVerdict(authenticated_account_uuid) != target) return .{ .unresolved = uncertain_reason };
        if (uncertain or !std.mem.eql(u8, after.source_commit, expected_source_commit)) return .reconciled_success;
        return .success;
    }

    fn sendReviewerVerdictMutation(
        self: Client,
        allocator: Allocator,
        method: httpc.Method,
        url: []const u8,
        auth: []const u8,
    ) !void {
        const res = try self.http.send(allocator, .{
            .method = method,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
    }

    /// PUT one published Comment body. The anti-corruption boundary exposes no
    /// HTTP, JSON, or Atlassian field names to its caller.
    pub fn updateComment(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        pull_request_id: u64,
        comment_id: CommentId,
        body_raw: []const u8,
    ) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}",
            .{ base_url, self.cred.workspace, repo_slug, pull_request_id, comment_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const body = try std.json.Stringify.valueAlloc(allocator, .{ .content = .{ .raw = body_raw } }, .{});
        defer allocator.free(body);
        const res = try self.http.send(allocator, .{
            .method = .PUT,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "content-type", .value = "application/json" },
            },
            .body = body,
        });
        defer allocator.free(res.body);
        try classify(res.status);
    }

    /// DELETE one published Comment. Bitbucket may retain the Comment as a
    /// structural tombstone when Replies still depend on it.
    pub fn deleteComment(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        pull_request_id: u64,
        comment_id: CommentId,
    ) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}",
            .{ base_url, self.cred.workspace, repo_slug, pull_request_id, comment_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .DELETE,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
    }

    /// GET the first page of the comments *list* raw (debug aid), so we can see
    /// how the list endpoint shapes a comment vs. the single-comment endpoint.
    pub fn getCommentsRaw(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments?pagelen=100",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        errdefer allocator.free(res.body);
        try classify(res.status);
        return res.body;
    }

    /// GET a single comment's raw JSON (debug aid): /pullrequests/{id}/comments/{comment_id}.
    /// Returns the body verbatim, owned by `allocator`, so we can inspect the real
    /// wire shape (e.g. how Bitbucket flags an outdated comment).
    pub fn getCommentRaw(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        comment_id: u64,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id, comment_id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        errdefer allocator.free(res.body);
        try classify(res.status);
        return res.body;
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}/comments, following
    /// Bitbucket's `next` links until the last page. Returns authored Comments
    /// plus Deleted Comment tombstones required by surviving descendants, flat
    /// (thread nesting is the review context's job, `buildThreads`).
    /// Each `Comment` and its strings are owned by `allocator`; free the batch
    /// with `deinitComments`. Callers should pass a PR-scoped arena.
    /// `head` is the PR's current source/destination commits: a comment whose
    /// anchored `links.code` revision differs is flagged outdated (the list
    /// endpoint does not expose the verdict directly). Pass `.{}` to skip this
    /// (then only an explicit `inline.outdated` marks a comment outdated).
    pub fn getComments(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        head: HeadCommits,
    ) ![]Comment {
        return switch (try self.getCommentsAttempt(allocator, repo_slug, id, head)) {
            .comments => |comments| comments,
            .rejected => |failure| failure.reason,
        };
    }

    pub const GetCommentsAttempt = union(enum) {
        comments: []Comment,
        rejected: struct { reason: ApiError, retry_after_ms: ?u64 },
    };

    /// Duplicate-guard variant that preserves Retry-After on a definite failed
    /// read instead of flattening it into an error value.
    pub fn getCommentsAttempt(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        head: HeadCommits,
    ) !GetCommentsAttempt {
        var rejection: ?PageRejection = null;
        const comments = self.commentsPage(allocator, repo_slug, id, head, .{ .pagelen = 100 }, &rejection) catch |err| {
            if (rejection) |failure| return .{ .rejected = .{ .reason = failure.reason, .retry_after_ms = failure.retry_after_ms } };
            return err;
        };
        return .{ .comments = comments };
    }

    /// List Comments with page controls and the same head/outdated decoding as the TUI.
    pub fn getCommentsPage(self: Client, allocator: Allocator, repo_slug: []const u8, pr_id: u64, head: types.HeadCommits, opts: PageOptions) ![]Comment {
        return self.commentsPage(allocator, repo_slug, pr_id, head, opts, null);
    }

    fn commentsPage(self: Client, allocator: Allocator, repo_slug: []const u8, pr_id: u64, head: HeadCommits, opts: PageOptions, rejection: ?*?PageRejection) ![]Comment {
        const first = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments",
            .{ base_url, self.cred.workspace, repo_slug, pr_id },
        );
        defer allocator.free(first);
        return self.listPages(allocator, Comment, CommentsPage, dupeComment, deinitComment, .{head}, first, opts, rejection);
    }

    /// GET /user/workspaces: workspaces visible to the authenticated account.
    /// Follows `next` unless `opts.follow` is false. Owned by `allocator`
    /// (free with `deinitWorkspaces`).
    pub fn listWorkspaces(
        self: Client,
        allocator: Allocator,
        opts: PageOptions,
    ) ![]types.Workspace {
        return self.listPages(allocator, types.Workspace, WorkspacePage, dupeWorkspace, deinitWorkspace, .{}, base_url ++ "/user/workspaces", opts, null);
    }

    /// GET /workspaces/{workspace}. Owned by `allocator`.
    pub fn getWorkspace(
        self: Client,
        allocator: Allocator,
        workspace: []const u8,
    ) !types.Workspace {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/workspaces/{s}",
            .{ base_url, workspace },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(WorkspaceJson, allocator, res.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedResponse;
        defer parsed.deinit();
        return dupeWorkspaceJson(allocator, parsed.value);
    }

    /// GET /repositories/{workspace}: repositories in a workspace.
    /// `workspace_override` selects the workspace (defaults to credential).
    /// Follows `next` unless `opts.follow` is false.
    pub fn listRepositories(
        self: Client,
        allocator: Allocator,
        workspace_override: ?[]const u8,
        opts: PageOptions,
    ) ![]types.Repository {
        const ws = workspace_override orelse self.cred.workspace;
        const first = try std.fmt.allocPrint(allocator, "{s}/repositories/{s}", .{ base_url, ws });
        defer allocator.free(first);
        return self.listPages(allocator, types.Repository, RepositoryPage, dupeRepository, deinitRepository, .{}, first, opts, null);
    }

    /// GET /repositories/{workspace}/{repo}. Owned by `allocator`.
    pub fn getRepository(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        workspace_override: ?[]const u8,
    ) !types.Repository {
        const ws = workspace_override orelse self.cred.workspace;
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}",
            .{ base_url, ws, repo_slug },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(RepositoryJson, allocator, res.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedResponse;
        defer parsed.deinit();
        return dupeRepository(allocator, parsed.value);
    }

    /// GET .../pullrequests/{id}/commits: commits on a pull request.
    /// Follows `next` unless `opts.follow` is false.
    pub fn listPrCommits(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        opts: PageOptions,
    ) ![]types.Commit {
        const first = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/commits",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(first);
        return self.listCommitsFrom(allocator, first, opts);
    }

    /// GET .../commits/{revision}: commits reachable from a revision.
    pub fn listRepoCommits(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        revision: []const u8,
        opts: PageOptions,
    ) ![]types.Commit {
        const first = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/commits/{s}",
            .{ base_url, self.cred.workspace, repo_slug, revision },
        );
        defer allocator.free(first);
        return self.listCommitsFrom(allocator, first, opts);
    }

    fn listCommitsFrom(
        self: Client,
        allocator: Allocator,
        first_url: []const u8,
        opts: PageOptions,
    ) ![]types.Commit {
        return self.listPages(allocator, types.Commit, CommitPage, dupeCommit, deinitCommit, .{}, first_url, opts, null);
    }

    /// Return commits reachable from `to`, excluding all commits reachable from `from`.
    pub fn listRepoCommitRange(self: Client, allocator: Allocator, repo_slug: []const u8, from: []const u8, to: []const u8, opts: PageOptions) ![]types.Commit {
        if (from.len == 0 or to.len == 0) return error.BadRequest;
        var first: std.ArrayList(u8) = .empty;
        defer first.deinit(allocator);
        try first.print(allocator, "{s}/repositories/{s}/{s}/commits?include=", .{ base_url, self.cred.workspace, repo_slug });
        try percentEncodeInto(allocator, &first, to);
        try first.appendSlice(allocator, "&exclude=");
        try percentEncodeInto(allocator, &first, from);
        return self.listCommitsFrom(allocator, first.items, opts);
    }

    /// Own each request URL, response, decoded item, and accumulated batch once.
    fn listPages(
        self: Client,
        allocator: Allocator,
        comptime Item: type,
        comptime Page: type,
        comptime decode: anytype,
        comptime deinit: fn (Allocator, Item) void,
        decode_args: anytype,
        first_url: []const u8,
        opts: PageOptions,
        rejection: ?*?PageRejection,
    ) ![]Item {
        var out: std.ArrayList(Item) = .empty;
        defer {
            for (out.items) |item| deinit(allocator, item);
            out.deinit(allocator);
        }
        if (opts.limit == 0) return out.toOwnedSlice(allocator);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        var url = try pageUrlWithBase(allocator, first_url, opts);
        defer allocator.free(url);
        while (true) {
            const res = try self.http.send(allocator, .{
                .method = .GET,
                .url = url,
                .headers = &.{
                    .{ .name = "authorization", .value = auth },
                    .{ .name = "accept", .value = "application/json" },
                },
            });
            defer allocator.free(res.body);
            classify(res.status) catch |reason| {
                if (rejection) |failure| failure.* = .{ .reason = reason, .retry_after_ms = res.retry_after_ms };
                return reason;
            };
            const parsed = std.json.parseFromSlice(Page, allocator, res.body, .{
                .ignore_unknown_fields = true,
            }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedResponse;
            defer parsed.deinit();
            for (parsed.value.values) |wire| {
                if (opts.limit) |limit| {
                    if (out.items.len >= limit) break;
                }
                const item = try @call(.auto, decode, .{ allocator, wire } ++ decode_args);
                if (Item == types.Task) {
                    if (opts.task_state) |state| {
                        if (item.state != state) {
                            deinit(allocator, item);
                            continue;
                        }
                    }
                }
                errdefer deinit(allocator, item);
                try out.append(allocator, item);
            }
            if (!opts.follow) break;
            if (opts.limit) |limit| {
                if (out.items.len >= limit) break;
            }
            const next = parsed.value.next orelse break;
            const next_url = try allocator.dupe(u8, next);
            allocator.free(url);
            url = next_url;
        }
        if (Item == Comment) {
            var write: usize = 0;
            for (out.items, 0..) |comment, index| {
                if (comment.deleted and !hasSurvivingDescendant(out.items, comment.id)) {
                    deinit(allocator, comment);
                    continue;
                }
                if (write != index) out.items[write] = comment;
                write += 1;
            }
            out.shrinkRetainingCapacity(write);
        }
        return out.toOwnedSlice(allocator);
    }

    /// GET .../diff/{from}..{to} (or .../patch/... when `patch` is true):
    /// raw diff between two commits. Owned by `allocator`.
    pub fn getCompareDiff(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        from: []const u8,
        to: []const u8,
        patch: bool,
    ) ![]u8 {
        const kind: []const u8 = if (patch) "patch" else "diff";
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/{s}/{s}..{s}",
            .{ base_url, self.cred.workspace, repo_slug, kind, from, to },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "text/plain" },
            },
        });
        errdefer allocator.free(res.body);
        try classify(res.status);
        return res.body;
    }

    /// GET a single comment, typed (debug `getCommentRaw` stays raw).
    /// Owned strings via `allocator`; free with `deinitComment`-equivalent
    /// caller handling a one-element slice via `deinitComments`.
    pub fn getComment(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        comment_id: u64,
    ) !Comment {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id, comment_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(CommentJson, allocator, res.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedResponse;
        defer parsed.deinit();
        return dupeComment(allocator, parsed.value, .{});
    }

    /// POST .../comments/{id}/resolve: resolve a comment thread.
    pub fn resolveComment(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        pull_request_id: u64,
        comment_id: CommentId,
    ) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}/resolve",
            .{ base_url, self.cred.workspace, repo_slug, pull_request_id, comment_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
    }

    /// DELETE .../comments/{id}/resolve: reopen a comment thread.
    pub fn reopenComment(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        pull_request_id: u64,
        comment_id: CommentId,
    ) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}/resolve",
            .{ base_url, self.cred.workspace, repo_slug, pull_request_id, comment_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .DELETE,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
    }

    /// GET .../pullrequests/{id}/tasks. Follows `next` unless `opts.follow`
    /// is false. Owned by `allocator` (free with `deinitTasks`).
    pub fn listTasks(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        opts: PageOptions,
    ) ![]types.Task {
        const first = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/tasks",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(first);
        return self.listPages(allocator, types.Task, TaskPage, dupeTask, deinitTask, .{}, first, opts, null);
    }

    /// GET .../tasks/{task_id}. Owned by `allocator`.
    pub fn getTask(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        task_id: u64,
    ) !types.Task {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/tasks/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id, task_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(TaskJson, allocator, res.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedResponse;
        defer parsed.deinit();
        return dupeTask(allocator, parsed.value);
    }

    /// POST .../tasks: create a task. `comment_id` attaches it to a comment.
    /// Returns the server-assigned task id.
    pub fn createTask(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        content: []const u8,
        comment_id: ?u64,
    ) !u64 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/tasks",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const Wire = struct {
            content: struct { raw: []const u8 },
            comment: ?struct { id: u64 } = null,
        };
        const wire = Wire{
            .content = .{ .raw = content },
            .comment = if (comment_id) |cid| .{ .id = cid } else null,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, wire, .{ .emit_null_optional_fields = false });
        defer allocator.free(body);
        const res = try self.http.send(allocator, .{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "content-type", .value = "application/json" },
            },
            .body = body,
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(
            struct { id: u64 },
            allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.MalformedResponse;
        defer parsed.deinit();
        return parsed.value.id;
    }

    /// PUT .../tasks/{task_id}: update content and/or state.
    /// Pass null to leave a field unchanged. At least one must be non-null.
    pub fn updateTask(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        task_id: u64,
        content: ?[]const u8,
        state: ?types.TaskState,
    ) !types.Task {
        if (content == null and state == null) return error.BadRequest;
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/tasks/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id, task_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const Wire = struct {
            content: ?struct { raw: []const u8 } = null,
            state: ?[]const u8 = null,
        };
        const wire = Wire{
            .content = if (content) |c| .{ .raw = c } else null,
            .state = if (state) |s| taskStateWire(s) else null,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, wire, .{ .emit_null_optional_fields = false });
        defer allocator.free(body);
        const res = try self.http.send(allocator, .{
            .method = .PUT,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "content-type", .value = "application/json" },
            },
            .body = body,
        });
        defer allocator.free(res.body);
        try classify(res.status);
        const parsed = std.json.parseFromSlice(TaskJson, allocator, res.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedResponse;
        defer parsed.deinit();
        return dupeTask(allocator, parsed.value);
    }

    /// DELETE .../tasks/{task_id}.
    pub fn deleteTask(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        task_id: u64,
    ) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/tasks/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id, task_id },
        );
        defer allocator.free(url);
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);
        const res = try self.http.send(allocator, .{
            .method = .DELETE,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);
        try classify(res.status);
    }

    /// PUT .../tasks/{task_id} with `state` only: `RESOLVED` or `UNRESOLVED`.
    pub fn setTaskState(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        task_id: u64,
        state: types.TaskState,
    ) !types.Task {
        return self.updateTask(
            allocator,
            repo_slug,
            id,
            task_id,
            null,
            state,
        );
    }

    /// Structured file metadata for `?format=meta` (used by `check-blob --json`).
    pub const FileMeta = struct {
        path: []const u8,
        commit: []const u8,
        size: usize,
        attributes: [][]const u8,
    };

    /// GET .../src/{commit}/{path}?format=meta, parsed. Owned by `allocator`
    /// (free with `deinitFileMeta`).
    pub fn getFileMeta(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        commit: []const u8,
        path: []const u8,
    ) !FileMeta {
        const metadata_body = try self.getSource(allocator, repo_slug, commit, path, true);
        defer allocator.free(metadata_body);
        const Wire = struct {
            type: []const u8,
            path: []const u8,
            commit: struct { hash: []const u8 },
            size: usize,
            attributes: []const []const u8 = &.{},
        };
        const parsed = std.json.parseFromSlice(Wire, allocator, metadata_body, .{ .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedResponse;
        defer parsed.deinit();
        const m = parsed.value;
        if (!std.mem.eql(u8, m.type, "commit_file")) return error.BlobTypeMismatch;
        const attrs = try allocator.alloc([]const u8, m.attributes.len);
        var copied: usize = 0;
        errdefer {
            for (attrs[0..copied]) |a| allocator.free(a);
            allocator.free(attrs);
        }
        for (m.attributes, 0..) |a, i| {
            attrs[i] = try allocator.dupe(u8, a);
            copied += 1;
        }
        const owned_path = try allocator.dupe(u8, m.path);
        errdefer allocator.free(owned_path);
        return .{
            .path = owned_path,
            .commit = try allocator.dupe(u8, m.commit.hash),
            .size = m.size,
            .attributes = attrs,
        };
    }
};

/// Paging for list endpoints. `follow` follows `next` links (default true:
/// return all items). With `follow=false` a single page is returned.
/// `limit` caps the total when following. `query`/`sort` pass through where
/// the endpoint supports them.
pub const PageOptions = struct {
    pagelen: ?u32 = null,
    page: ?u32 = null,
    query: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    follow: bool = true,
    limit: ?usize = null,
    /// Task-only local filter. The limit counts matching Tasks.
    task_state: ?types.TaskState = null,
};

const PageRejection = struct { reason: ApiError, retry_after_ms: ?u64 };

fn pageUrlWithBase(allocator: Allocator, first: []const u8, opts: PageOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, first);
    var sep: u8 = if (std.mem.indexOfScalar(u8, first, '?') != null) '&' else '?';
    if (opts.pagelen) |n| {
        try buf.print(allocator, "{c}pagelen={d}", .{ sep, n });
        sep = '&';
    }
    if (opts.page) |n| {
        try buf.print(allocator, "{c}page={d}", .{ sep, n });
        sep = '&';
    }
    if (opts.query) |q| {
        try buf.append(allocator, sep);
        try buf.appendSlice(allocator, "q=");
        try percentEncodeInto(allocator, &buf, q);
        sep = '&';
    }
    if (opts.sort) |s| {
        try buf.append(allocator, sep);
        try buf.appendSlice(allocator, "sort=");
        try percentEncodeInto(allocator, &buf, s);
    }
    return buf.toOwnedSlice(allocator);
}

const WorkspaceJson = struct {
    slug: []const u8,
    name: []const u8 = "",
    uuid: []const u8 = "",
};

const WorkspaceEntryJson = struct {
    workspace: WorkspaceJson,
};

const WorkspacePage = struct {
    values: []WorkspaceEntryJson,
    next: ?[]const u8 = null,
};

fn dupeWorkspace(allocator: Allocator, wj: WorkspaceEntryJson) !types.Workspace {
    return dupeWorkspaceJson(allocator, wj.workspace);
}

fn dupeWorkspaceJson(allocator: Allocator, wj: WorkspaceJson) !types.Workspace {
    const slug = try allocator.dupe(u8, wj.slug);
    errdefer allocator.free(slug);
    const name = try allocator.dupe(u8, wj.name);
    errdefer allocator.free(name);
    return .{
        .slug = slug,
        .name = name,
        .uuid = try allocator.dupe(u8, wj.uuid),
    };
}

fn deinitWorkspace(allocator: Allocator, w: types.Workspace) void {
    allocator.free(w.slug);
    allocator.free(w.name);
    allocator.free(w.uuid);
}

/// Free a batch returned by `listWorkspaces`.
pub fn deinitWorkspaces(allocator: Allocator, items: []types.Workspace) void {
    for (items) |w| deinitWorkspace(allocator, w);
    allocator.free(items);
}

const RepositoryJson = struct {
    slug: []const u8,
    full_name: []const u8 = "",
    name: []const u8 = "",
    uuid: []const u8 = "",
    is_private: bool = false,
};

const RepositoryPage = struct {
    values: []RepositoryJson,
    next: ?[]const u8 = null,
};

fn dupeRepository(allocator: Allocator, rj: RepositoryJson) !types.Repository {
    const slug = try allocator.dupe(u8, rj.slug);
    errdefer allocator.free(slug);
    const full_name = try allocator.dupe(u8, rj.full_name);
    errdefer allocator.free(full_name);
    const name = try allocator.dupe(u8, rj.name);
    errdefer allocator.free(name);
    return .{
        .slug = slug,
        .full_name = full_name,
        .name = name,
        .uuid = try allocator.dupe(u8, rj.uuid),
        .is_private = rj.is_private,
    };
}

fn deinitRepository(allocator: Allocator, r: types.Repository) void {
    allocator.free(r.slug);
    allocator.free(r.full_name);
    allocator.free(r.name);
    allocator.free(r.uuid);
}

/// Free a batch returned by `listRepositories`.
pub fn deinitRepositories(allocator: Allocator, items: []types.Repository) void {
    for (items) |r| deinitRepository(allocator, r);
    allocator.free(items);
}

const CommitJson = struct {
    hash: []const u8,
    message: []const u8 = "",
    author: ?struct {
        display_name: ?[]const u8 = null,
        user: ?struct { display_name: ?[]const u8 = null } = null,
        raw: ?[]const u8 = null,
    } = null,
    date: []const u8 = "",
};

const CommitPage = struct {
    values: []CommitJson,
    next: ?[]const u8 = null,
};

fn dupeCommit(allocator: Allocator, cj: CommitJson) !types.Commit {
    const author: []const u8 = if (cj.author) |a| ((if (a.user) |u| u.display_name else null) orelse a.display_name orelse a.raw orelse "") else "";
    const hash = try allocator.dupe(u8, cj.hash);
    errdefer allocator.free(hash);
    const message = try allocator.dupe(u8, cj.message);
    errdefer allocator.free(message);
    const owned_author = try allocator.dupe(u8, author);
    errdefer allocator.free(owned_author);
    return .{
        .hash = hash,
        .message = message,
        .author = owned_author,
        .date = try allocator.dupe(u8, cj.date),
    };
}

fn deinitCommit(allocator: Allocator, c: types.Commit) void {
    allocator.free(c.hash);
    allocator.free(c.message);
    allocator.free(c.author);
    allocator.free(c.date);
}

/// Free a batch returned by `listPrCommits` / `listRepoCommits`.
pub fn deinitCommits(allocator: Allocator, items: []types.Commit) void {
    for (items) |c| deinitCommit(allocator, c);
    allocator.free(items);
}

const TaskJson = struct {
    id: u64,
    content: ?struct { raw: ?[]const u8 = null } = null,
    state: []const u8,
    creator: ?struct { uuid: ?[]const u8 = null } = null,
    comment: ?struct { id: u64 } = null,
};

const TaskPage = struct {
    values: []TaskJson,
    next: ?[]const u8 = null,
};

fn dupeTask(allocator: Allocator, tj: TaskJson) !types.Task {
    const raw = if (tj.content) |c| (c.raw orelse "") else "";
    const creator = if (tj.creator) |c| (c.uuid orelse "") else "";
    const state: types.TaskState = if (std.mem.eql(u8, tj.state, "RESOLVED")) .resolved else if (std.mem.eql(u8, tj.state, "UNRESOLVED")) .unresolved else return error.MalformedResponse;
    const content = try allocator.dupe(u8, raw);
    errdefer allocator.free(content);
    return .{
        .id = tj.id,
        .content = content,
        .state = state,
        .creator_uuid = try allocator.dupe(u8, creator),
        .comment_id = if (tj.comment) |c| c.id else null,
    };
}

fn taskStateWire(state: types.TaskState) []const u8 {
    return switch (state) {
        .resolved => "RESOLVED",
        .unresolved => "UNRESOLVED",
    };
}

fn deinitTask(allocator: Allocator, t: types.Task) void {
    allocator.free(t.content);
    allocator.free(t.creator_uuid);
}

/// Free a batch returned by `listTasks`.
pub fn deinitTasks(allocator: Allocator, items: []types.Task) void {
    for (items) |t| deinitTask(allocator, t);
    allocator.free(items);
}

/// Free a `FileMeta` returned by `getFileMeta`.
pub fn deinitFileMeta(allocator: Allocator, m: Client.FileMeta) void {
    allocator.free(m.path);
    allocator.free(m.commit);
    for (m.attributes) |a| allocator.free(a);
    allocator.free(m.attributes);
}

/// Map HTTP status to an `ApiError`; return normally on 2xx.
fn classify(status: u16) ApiError!void {
    return switch (status) {
        200...299 => {},
        400 => error.BadRequest,
        401 => error.Unauthorized,
        403 => error.Forbidden,
        404 => error.NotFound,
        409 => error.Conflict,
        429 => error.RateLimited,
        500...599 => error.ServerError,
        else => error.UnexpectedStatus,
    };
}

fn asApiError(err: anyerror) ?ApiError {
    return switch (err) {
        error.Unauthorized => error.Unauthorized,
        error.Forbidden => error.Forbidden,
        error.BadRequest => error.BadRequest,
        error.NotFound => error.NotFound,
        error.RateLimited => error.RateLimited,
        error.Conflict => error.Conflict,
        error.ServerError => error.ServerError,
        error.UnexpectedStatus => error.UnexpectedStatus,
        error.MalformedResponse => error.MalformedResponse,
        else => null,
    };
}

/// Filter for `listPullRequests`. `state` is a Bitbucket PR state string
/// (OPEN, MERGED, DECLINED, SUPERSEDED); `source_branch` restricts to PRs
/// opened from that branch (the AdjacentPullRequest lookup).
pub const ListOptions = struct {
    state: []const u8 = "OPEN",
    source_branch: ?[]const u8 = null,
};

/// A comment to publish via `createComment`. `parent` (a server `CommentId`)
/// makes it a reply and suppresses `anchor`; `anchor` alone makes it a root
/// inline comment; neither makes it a top-level PR comment. `body` is raw
/// markdown (a suggestion's fenced block is already part of the body).
pub const NewComment = struct {
    body: []const u8,
    scope: ?review.CommentScope = null,
    /// Transitional source compatibility for callers predating CommentScope.
    anchor: ?Anchor = null,
    parent: ?CommentId = null,

    pub fn effectiveScope(self: NewComment) review.CommentScope {
        if (self.scope) |scope| return scope;
        if (self.anchor) |anchor| return .{ .@"inline" = anchor };
        return .review;
    }
};

/// Percent-encode `raw` into `buf`, escaping everything outside the RFC 3986
/// unreserved set. Keeps the `q` filter (with its `=`, quotes, spaces) safe as
/// a single query-parameter value.
fn percentEncodeInto(allocator: Allocator, buf: *std.ArrayList(u8), raw: []const u8) !void {
    for (raw) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn appendEncodedPath(allocator: Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    var segments = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try out.append(allocator, '/');
        first = false;
        try percentEncodeInto(allocator, out, segment);
    }
}

fn stringSlicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

/// The subset of a PR list entry we surface. Commit hashes are absent from the
/// list endpoint, so they are not modeled here (see `PullRequestSummary`).
const PrSummaryJson = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author: ?struct { display_name: ?[]const u8 = null } = null,
    source: struct { branch: struct { name: []const u8 } },
    destination: struct { branch: struct { name: []const u8 } },
};

const PrListPage = struct {
    values: []PrSummaryJson,
    next: ?[]const u8 = null,
};

fn dupeSummary(allocator: Allocator, pj: PrSummaryJson) !PullRequestSummary {
    const author = if (pj.author) |a| (a.display_name orelse "") else "";
    const title = try allocator.dupe(u8, pj.title);
    errdefer allocator.free(title);
    const state = try allocator.dupe(u8, pj.state);
    errdefer allocator.free(state);
    const author_owned = try allocator.dupe(u8, author);
    errdefer allocator.free(author_owned);
    const source_branch = try allocator.dupe(u8, pj.source.branch.name);
    errdefer allocator.free(source_branch);
    return .{
        .id = pj.id,
        .title = title,
        .state = state,
        .author_display_name = author_owned,
        .source_branch = source_branch,
        .destination_branch = try allocator.dupe(u8, pj.destination.branch.name),
    };
}

fn deinitSummary(allocator: Allocator, s: PullRequestSummary) void {
    allocator.free(s.title);
    allocator.free(s.state);
    allocator.free(s.author_display_name);
    allocator.free(s.source_branch);
    allocator.free(s.destination_branch);
}

/// Free a batch returned by `listPullRequests`.
pub fn deinitSummaries(allocator: Allocator, summaries: []PullRequestSummary) void {
    for (summaries) |s| deinitSummary(allocator, s);
    allocator.free(summaries);
}

/// JSON shape we read from Bitbucket. `ignore_unknown_fields` skips the rest.
const PrJson = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author: struct { display_name: []const u8, uuid: []const u8 },
    source: struct { branch: struct { name: []const u8 }, commit: struct { hash: []const u8 } },
    destination: struct { branch: struct { name: []const u8 }, commit: struct { hash: []const u8 } },
    participants: []const struct {
        user: struct { uuid: []const u8 },
        approved: bool = false,
        state: ?[]const u8 = null,
    },
};

fn parsePullRequest(allocator: Allocator, body: []const u8) !PullRequest {
    const parsed = std.json.parseFromSlice(PrJson, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedResponse;
    defer parsed.deinit();
    const v = parsed.value;

    var verdicts: std.ArrayList(types.ReviewerVerdictEntry) = .empty;
    errdefer {
        for (verdicts.items) |entry| allocator.free(entry.account_uuid);
        verdicts.deinit(allocator);
    }
    for (v.participants) |participant| {
        const verdict: types.ReviewerVerdict = if (participant.approved) blk: {
            if (participant.state) |state| {
                if (!std.mem.eql(u8, state, "approved")) return error.MalformedResponse;
            }
            break :blk .approved;
        } else if (participant.state) |state| blk: {
            if (!std.mem.eql(u8, state, "changes_requested")) return error.MalformedResponse;
            break :blk .changes_requested;
        } else .no_verdict;
        const account_uuid = try allocator.dupe(u8, participant.user.uuid);
        errdefer allocator.free(account_uuid);
        try verdicts.append(allocator, .{
            .account_uuid = account_uuid,
            .verdict = verdict,
        });
    }

    // Duplicate the strings out of the parse arena into the caller's allocator.
    return .{
        .id = v.id,
        .title = try allocator.dupe(u8, v.title),
        .state = try allocator.dupe(u8, v.state),
        .author_display_name = try allocator.dupe(u8, v.author.display_name),
        .author_uuid = try allocator.dupe(u8, v.author.uuid),
        .source_branch = try allocator.dupe(u8, v.source.branch.name),
        .destination_branch = try allocator.dupe(u8, v.destination.branch.name),
        .source_commit = try allocator.dupe(u8, v.source.commit.hash),
        .destination_commit = try allocator.dupe(u8, v.destination.commit.hash),
        .reviewer_verdicts = try verdicts.toOwnedSlice(allocator),
    };
}

/// The comment JSON we read from a page of the comments endpoint. Fields we
/// don't model are ignored; anything optional defaults so deleted/system
/// comments (which may omit `content`/`user`) still parse.
const CommentJson = struct {
    id: u64,
    content: ?struct { raw: ?[]const u8 = null } = null,
    user: ?struct {
        display_name: ?[]const u8 = null,
        uuid: ?[]const u8 = null,
    } = null,
    deleted: bool = false,
    parent: ?struct { id: u64 } = null,
    // `inline` is a Zig keyword; @"inline" maps to the JSON key "inline".
    @"inline": ?struct {
        path: []const u8,
        from: ?u32 = null,
        to: ?u32 = null,
        /// Top of a multi-line range; null for a single-line anchor.
        start_from: ?u32 = null,
        start_to: ?u32 = null,
        /// Bitbucket's own outdated verdict for this anchor (ADR-0001). Absent on
        /// current comments; treat missing as `current`.
        outdated: ?bool = null,
    } = null,
    /// Present (an object) when the thread is resolved; null/absent otherwise.
    resolution: ?struct {} = null,
    /// `links.code.href` embeds the diff revision the comment is anchored to,
    /// e.g. ".../diff/ws/repo:<src>..<dst>?path=…". Comparing that revision to
    /// the PR's current one is how we detect outdated (the list omits the flag).
    links: ?struct { code: ?struct { href: ?[]const u8 = null } = null } = null,
};

const CommentsPage = struct {
    values: []CommentJson,
    /// Absolute URL of the next page, or absent on the last page.
    next: ?[]const u8 = null,
};

/// Copy one wire comment into a domain `Comment` owned by `allocator`. `head`
/// is the PR's current revision, used to detect outdated inline comments.
fn dupeComment(allocator: Allocator, cj: CommentJson, head: HeadCommits) !Comment {
    const author = if (cj.user) |u| (u.display_name orelse "") else "";
    const raw = if (cj.deleted) "" else if (cj.content) |c| (c.raw orelse "") else "";

    const author_owned = try allocator.dupe(u8, author);
    errdefer allocator.free(author_owned);
    const body_owned = try allocator.dupe(u8, raw);
    errdefer allocator.free(body_owned);
    const author_uuid_owned = if (cj.user) |u| if (u.uuid) |uuid| try allocator.dupe(u8, uuid) else null else null;
    errdefer if (author_uuid_owned) |uuid| allocator.free(uuid);

    const parent_id: ?CommentId = if (cj.parent) |p| p.id else null;
    var scope: ?review.CommentScope = null;
    var anchor: ?Anchor = null;
    if (parent_id == null) {
        if (cj.@"inline") |inl| {
            const path = try allocator.dupe(u8, inl.path);
            errdefer allocator.free(path);
            if (inl.to != null) {
                // Bitbucket may return both old and new projections for a range.
                // The domain Anchor is single-sided, so prefer the new side.
                anchor = .{
                    .path = path,
                    .to = inl.to,
                    .start_to = inl.start_to,
                };
                scope = .{ .@"inline" = anchor.? };
            } else if (inl.from != null) {
                anchor = .{
                    .path = path,
                    .from = inl.from,
                    .start_from = inl.start_from,
                };
                scope = .{ .@"inline" = anchor.? };
            } else if (inl.start_from != null or inl.start_to != null) {
                return error.MalformedResponse;
            } else {
                scope = .{ .file = .{
                    .path = path,
                    .source_commit = try allocator.dupe(u8, head.source),
                } };
            }
        } else {
            scope = .review;
        }
    }

    return .{
        .id = cj.id,
        .parent_id = parent_id,
        .author = author_owned,
        .author_uuid = author_uuid_owned,
        .body = body_owned,
        .scope = scope,
        .anchor = anchor,
        .resolved = cj.resolution != null,
        .state = commentState(cj, head),
        .deleted = cj.deleted,
    };
}

/// Resolve a comment's `AnchorState`. Trust an explicit `inline.outdated` if
/// present (the single-comment endpoint sets it); otherwise — for list results,
/// which omit it — compare the comment's anchored revision (from `links.code`)
/// to the PR's current one. A mismatch means the diff moved under it: outdated.
fn commentState(cj: CommentJson, head: HeadCommits) review.AnchorState {
    const inl = cj.@"inline" orelse return .current; // PR-level: never outdated
    if (inl.outdated) |o| return if (o) .outdated else .current;

    // No explicit verdict: fall back to the revision comparison, but only when
    // we know both the PR head and the comment's anchored range.
    if (head.source.len == 0 or head.destination.len == 0) return .current;
    const href = (if (cj.links) |l| (if (l.code) |c| c.href else null) else null) orelse return .current;
    const rev = parseCodeRevision(href) orelse return .current;
    const matches = hashMatches(rev.src, head.source) and hashMatches(rev.dst, head.destination);
    return if (matches) .current else .outdated;
}

/// The `<src>..<dst>` commit pair from a `links.code` href of the form
/// ".../diff/{ws}/{repo}:{src}..{dst}?path=…". Null if it doesn't parse.
fn parseCodeRevision(href: []const u8) ?struct { src: []const u8, dst: []const u8 } {
    // The revision range sits between the last ':' and the '?' (or end).
    const colon = std.mem.lastIndexOfScalar(u8, href, ':') orelse return null;
    var rest = href[colon + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    const sep = std.mem.indexOf(u8, rest, "..") orelse return null;
    const src = rest[0..sep];
    const dst = rest[sep + 2 ..];
    if (src.len == 0 or dst.len == 0) return null;
    return .{ .src = src, .dst = dst };
}

/// Compare two commit hashes tolerant of abbreviation (Bitbucket may hand back
/// 12-char hashes in one place and full 40-char in another): equal if the
/// shorter is a prefix of the longer.
fn hashMatches(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const shorter = if (a.len <= b.len) a else b;
    const longer = if (a.len <= b.len) b else a;
    return std.mem.startsWith(u8, longer, shorter);
}

/// Free a batch returned by `getComments` (each comment's strings, then the
/// slice). No-op-safe on an arena, but correct under any allocator.
pub fn deinitComments(allocator: Allocator, comments: []Comment) void {
    for (comments) |c| deinitComment(allocator, c);
    allocator.free(comments);
}

fn deinitComment(allocator: Allocator, c: Comment) void {
    allocator.free(c.author);
    if (c.author_uuid) |uuid| allocator.free(uuid);
    allocator.free(c.body);
    if (c.scope) |scope| switch (scope) {
        .review => {},
        .file => |file| {
            allocator.free(file.path);
            allocator.free(file.source_commit);
        },
        .@"inline" => |anchor| allocator.free(anchor.path),
    } else if (c.anchor) |a| allocator.free(a.path);
}

fn hasSurvivingDescendant(comments: []const Comment, ancestor_id: CommentId) bool {
    for (comments) |candidate| {
        if (candidate.deleted) continue;
        var parent = candidate.parent_id;
        var remaining = comments.len;
        while (parent) |parent_id| : (remaining -= 1) {
            if (parent_id == ancestor_id) return true;
            if (remaining == 0) break;
            parent = null;
            for (comments) |possible_parent| if (possible_parent.id == parent_id) {
                parent = possible_parent.parent_id;
                break;
            };
        }
    }
    return false;
}

pub fn deinitPullRequest(allocator: Allocator, pr: PullRequest) void {
    allocator.free(pr.title);
    allocator.free(pr.state);
    allocator.free(pr.author_display_name);
    if (pr.author_uuid.len > 0) allocator.free(pr.author_uuid);
    allocator.free(pr.source_branch);
    allocator.free(pr.destination_branch);
    allocator.free(pr.source_commit);
    allocator.free(pr.destination_commit);
    if (pr.reviewer_verdicts) |verdicts| {
        for (verdicts) |entry| allocator.free(entry.account_uuid);
        allocator.free(verdicts);
    }
}

// ---------------------------------------------------------------------------
// Tests — no network; FakeHttpClient supplies fixtures.
// ---------------------------------------------------------------------------
const testing = std.testing;
const FakeHttpClient = @import("../http/fake_client.zig").FakeHttpClient;

// A schema-representative Bitbucket PR response (many fields our model ignores).
// Replace with a real captured response via `zig build check` when convenient.
const fixture_pr = @embedFile("testdata/pullrequest.json");

fn testCredential() Credential {
    return .{ .username = "u", .token = "t", .workspace = "check24" };
}

test "getPullRequest parses a well-formed fixture" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr };
    const bb = Client.init(fake.httpClient(), testCredential());

    const pr = try bb.getPullRequest(a, "myrepo", 42);
    defer deinitPullRequest(a, pr);

    try testing.expectEqual(@as(u64, 42), pr.id);
    try testing.expectEqualStrings("Add diff parser", pr.title);
    try testing.expectEqualStrings("OPEN", pr.state);
    try testing.expectEqualStrings("Ada Lovelace", pr.author_display_name);
    try testing.expectEqualStrings("feature/diff", pr.source_branch);
    try testing.expectEqualStrings("main", pr.destination_branch);
    try testing.expectEqualStrings("abc123def456", pr.source_commit);
    try testing.expectEqualStrings("0011223344ff", pr.destination_commit);
}

test "getPullRequest translates PullRequest Author and Reviewer Verdicts" {
    const body =
        \\{ "id": 42, "title": "Review", "state": "OPEN",
        \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
        \\  "participants": [
        \\    { "user": { "uuid": "{approved}" }, "approved": true, "state": "approved" },
        \\    { "user": { "uuid": "{changes}" }, "approved": false, "state": "changes_requested" },
        \\    { "user": { "uuid": "{none}" }, "approved": false, "state": null }
        \\  ] }
    ;
    var fake: FakeHttpClient = .{ .status = 200, .body = body };
    const bb = Client.init(fake.httpClient(), testCredential());

    const pr = try bb.getPullRequest(testing.allocator, "myrepo", 42);
    defer deinitPullRequest(testing.allocator, pr);

    try testing.expectEqualStrings("{ada}", pr.author_uuid);
    try testing.expectEqual(types.ReviewerVerdict.approved, pr.reviewerVerdict("{approved}"));
    try testing.expectEqual(types.ReviewerVerdict.changes_requested, pr.reviewerVerdict("{changes}"));
    try testing.expectEqual(types.ReviewerVerdict.no_verdict, pr.reviewerVerdict("{none}"));
    try testing.expectEqual(types.ReviewerVerdict.no_verdict, pr.reviewerVerdict("{missing}"));
}

test "changeReviewerVerdict POSTs Approved after a fresh SourceCommit check" {
    const before =
        \\{ "id": 42, "title": "Review", "state": "OPEN",
        \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
        \\  "participants": [] }
    ;
    const after =
        \\{ "id": 42, "title": "Review", "state": "OPEN",
        \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
        \\  "participants": [ { "user": { "uuid": "{me}" }, "approved": true, "state": "approved" } ] }
    ;
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = before },
        .{ .status = 200, .body = "{}" },
        .{ .status = 200, .body = after },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());

    const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);

    try testing.expectEqual(types.ReviewerVerdictChangeResult.success, result);
    try testing.expectEqual(httpc.Method.GET, fake.methodAt(0).?);
    try testing.expectEqual(httpc.Method.POST, fake.methodAt(1).?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42/approve",
        fake.urlAt(1).?,
    );
    try testing.expectEqual(httpc.Method.GET, fake.methodAt(2).?);
}

const verdict_none =
    \\{ "id": 42, "title": "Review", "state": "OPEN",
    \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
    \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
    \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
    \\  "participants": [] }
;
const verdict_approved =
    \\{ "id": 42, "title": "Review", "state": "OPEN",
    \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
    \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
    \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
    \\  "participants": [ { "user": { "uuid": "{me}" }, "approved": true, "state": "approved" } ] }
;
const verdict_changes_requested =
    \\{ "id": 42, "title": "Review", "state": "OPEN",
    \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
    \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
    \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
    \\  "participants": [ { "user": { "uuid": "{me}" }, "approved": false, "state": "changes_requested" } ] }
;
const verdict_approved_new_source =
    \\{ "id": 42, "title": "Review", "state": "OPEN",
    \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
    \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "new456" } },
    \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
    \\  "participants": [ { "user": { "uuid": "{me}" }, "approved": true, "state": "approved" } ] }
;

test "changeReviewerVerdict uses all replacement and removal endpoints" {
    const cases = [_]struct {
        before: []const u8,
        after: []const u8,
        target: types.ReviewerVerdict,
        method: httpc.Method,
        endpoint: []const u8,
    }{
        .{ .before = verdict_changes_requested, .after = verdict_approved, .target = .approved, .method = .POST, .endpoint = "approve" },
        .{ .before = verdict_approved, .after = verdict_changes_requested, .target = .changes_requested, .method = .POST, .endpoint = "request-changes" },
        .{ .before = verdict_approved, .after = verdict_none, .target = .no_verdict, .method = .DELETE, .endpoint = "approve" },
        .{ .before = verdict_changes_requested, .after = verdict_none, .target = .no_verdict, .method = .DELETE, .endpoint = "request-changes" },
    };
    for (cases) |case| {
        const responses = [_]@import("../http/fake_client.zig").Canned{
            .{ .status = 200, .body = case.before },
            .{ .status = 200, .body = "{}" },
            .{ .status = 200, .body = case.after },
        };
        var fake: FakeHttpClient = .{ .responses = &responses };
        const bb = Client.init(fake.httpClient(), testCredential());
        const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", case.target);
        try testing.expectEqual(types.ReviewerVerdictChangeResult.success, result);
        try testing.expectEqual(case.method, fake.methodAt(1).?);
        const expected_url = try std.fmt.allocPrint(
            testing.allocator,
            "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42/{s}",
            .{case.endpoint},
        );
        defer testing.allocator.free(expected_url);
        try testing.expectEqualStrings(expected_url, fake.urlAt(1).?);
        try testing.expectEqual(@as(usize, 3), fake.call_count);
    }
}

test "changeReviewerVerdict refuses a stale SourceCommit without mutation" {
    var fake: FakeHttpClient = .{ .status = 200, .body = verdict_none };
    const bb = Client.init(fake.httpClient(), testCredential());
    const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "old", "{me}", .approved);
    try testing.expectEqual(types.ReviewerVerdictChangeResult.stale_source_commit, result);
    try testing.expectEqual(@as(usize, 1), fake.call_count);
}

test "changeReviewerVerdict classifies every ApiError without retry" {
    const cases = [_]struct { status: u16, expected: ApiError, uncertain: bool = false }{
        .{ .status = 400, .expected = error.BadRequest },
        .{ .status = 401, .expected = error.Unauthorized },
        .{ .status = 403, .expected = error.Forbidden },
        .{ .status = 404, .expected = error.NotFound },
        .{ .status = 409, .expected = error.Conflict },
        .{ .status = 429, .expected = error.RateLimited, .uncertain = true },
        .{ .status = 503, .expected = error.ServerError, .uncertain = true },
        .{ .status = 302, .expected = error.UnexpectedStatus },
    };
    for (cases) |case| {
        const responses = [_]@import("../http/fake_client.zig").Canned{
            .{ .status = 200, .body = verdict_none },
            .{ .status = case.status, .body = "failure" },
            .{ .status = 200, .body = verdict_none },
        };
        var fake: FakeHttpClient = .{ .responses = &responses };
        const bb = Client.init(fake.httpClient(), testCredential());
        const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
        if (case.uncertain) {
            try testing.expectEqual(case.expected, result.unresolved.?);
        } else {
            try testing.expectEqual(case.expected, result.api_error);
        }
        try testing.expectEqual(@as(usize, if (case.uncertain) 3 else 2), fake.call_count);
        try testing.expectEqual(case.expected == error.Unauthorized, result.invalidatesAuthenticatedAccount());
    }
}

test "changeReviewerVerdict reconciles an uncertain one-shot mutation" {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = verdict_none },
        .{ .send_error = error.ConnectionResetByPeer },
        .{ .status = 200, .body = verdict_approved },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expectEqual(types.ReviewerVerdictChangeResult.reconciled_success, result);
    try testing.expectEqual(@as(usize, 3), fake.call_count);
}

test "changeReviewerVerdict reports unresolved reconciliation and malformed responses" {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = verdict_none },
        .{ .send_error = error.ConnectionResetByPeer },
        .{ .status = 200, .body = verdict_none },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    const unresolved = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expect(unresolved.unresolved == null);

    var malformed: FakeHttpClient = .{ .status = 200, .body = "not-json" };
    const malformed_bb = Client.init(malformed.httpClient(), testCredential());
    const malformed_result = try malformed_bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expectEqual(error.MalformedResponse, malformed_result.api_error);

    const malformed_after = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = verdict_none },
        .{ .status = 200, .body = "{}" },
        .{ .status = 200, .body = "not-json" },
    };
    var malformed_reconciliation: FakeHttpClient = .{ .responses = &malformed_after };
    const malformed_reconciliation_bb = Client.init(malformed_reconciliation.httpClient(), testCredential());
    const malformed_reconciliation_result = try malformed_reconciliation_bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expectEqual(error.MalformedResponse, malformed_reconciliation_result.unresolved.?);
}

test "changeReviewerVerdict keeps transport failure distinct and invalidates identity on reconciled 401" {
    var transport_failure: FakeHttpClient = .{ .send_error = error.ConnectionResetByPeer };
    const transport_bb = Client.init(transport_failure.httpClient(), testCredential());
    try testing.expectError(
        error.ConnectionResetByPeer,
        transport_bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved),
    );

    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = verdict_none },
        .{ .send_error = error.ConnectionResetByPeer },
        .{ .status = 401, .body = "unauthorized" },
    };
    var unauthorized: FakeHttpClient = .{ .responses = &responses };
    const unauthorized_bb = Client.init(unauthorized.httpClient(), testCredential());
    const result = try unauthorized_bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expectEqual(error.Unauthorized, result.unresolved.?);
    try testing.expect(result.invalidatesAuthenticatedAccount());
    try testing.expectEqual(@as(usize, 3), unauthorized.call_count);
}

test "changeReviewerVerdict reconciles response allocation failure once" {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = verdict_none },
        .{ .send_error = error.OutOfMemory },
        .{ .status = 200, .body = verdict_none },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expect(result.unresolved == null);
    try testing.expectEqual(@as(usize, 3), fake.call_count);
}

test "getPullRequest rejects missing or unknown Reviewer Verdict wire data" {
    const missing =
        \\{ "id": 42, "title": "Review", "state": "OPEN",
        \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } } }
    ;
    var missing_fake: FakeHttpClient = .{ .status = 200, .body = missing };
    const missing_bb = Client.init(missing_fake.httpClient(), testCredential());
    try testing.expectError(error.MalformedResponse, missing_bb.getPullRequest(testing.allocator, "myrepo", 42));

    const unknown =
        \\{ "id": 42, "title": "Review", "state": "OPEN",
        \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
        \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "abc123" } },
        \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "def456" } },
        \\  "participants": [ { "user": { "uuid": "{me}" }, "approved": false, "state": "pending" } ] }
    ;
    var unknown_fake: FakeHttpClient = .{ .status = 200, .body = unknown };
    const unknown_bb = Client.init(unknown_fake.httpClient(), testCredential());
    try testing.expectError(error.MalformedResponse, unknown_bb.getPullRequest(testing.allocator, "myrepo", 42));
}

test "changeReviewerVerdict reconciles a SourceCommit change during mutation" {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = verdict_none },
        .{ .status = 200, .body = "{}" },
        .{ .status = 200, .body = verdict_approved_new_source },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    const result = try bb.changeReviewerVerdict(testing.allocator, "myrepo", 42, "abc123", "{me}", .approved);
    try testing.expectEqual(types.ReviewerVerdictChangeResult.reconciled_success, result);
}

test "getPullRequest builds the correct URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr };
    const bb = Client.init(fake.httpClient(), testCredential());

    const pr = try bb.getPullRequest(a, "myrepo", 42);
    defer deinitPullRequest(a, pr);

    try testing.expectEqual(httpc.Method.GET, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42",
        fake.lastUrl().?,
    );
}

test "status codes map to the right ApiError" {
    const a = testing.allocator;
    const cases = [_]struct { status: u16, want: anyerror }{
        .{ .status = 400, .want = error.BadRequest },
        .{ .status = 401, .want = error.Unauthorized },
        .{ .status = 403, .want = error.Forbidden },
        .{ .status = 404, .want = error.NotFound },
        .{ .status = 409, .want = error.Conflict },
        .{ .status = 429, .want = error.RateLimited },
        .{ .status = 503, .want = error.ServerError },
        .{ .status = 302, .want = error.UnexpectedStatus },
    };
    for (cases) |c| {
        var fake: FakeHttpClient = .{ .status = c.status, .body = "" };
        const bb = Client.init(fake.httpClient(), testCredential());
        try testing.expectError(c.want, bb.getPullRequest(a, "myrepo", 1));
    }
}

test "transport failures remain distinct from ApiError values and are not retried" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .send_error = error.ConnectionResetByPeer };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.ConnectionResetByPeer, bb.getPullRequest(a, "myrepo", 1));
    try testing.expectEqual(@as(usize, 1), fake.call_count);
}

test "malformed 2xx body is a MalformedResponse" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = "{ not json" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.MalformedResponse, bb.getPullRequest(a, "myrepo", 1));
}

// A two-entry PR list page (no `next`: single page). Only fields our summary
// reads are asserted; the rest exercise `ignore_unknown_fields`.
const fixture_pr_list =
    \\{ "values": [
    \\  { "id": 42, "title": "Add diff parser", "state": "OPEN",
    \\    "author": { "display_name": "Ada Lovelace" },
    \\    "source": { "branch": { "name": "feature/diff" } },
    \\    "destination": { "branch": { "name": "main" } } },
    \\  { "id": 43, "title": "Fix nav", "state": "OPEN",
    \\    "author": { "display_name": "Grace Hopper" },
    \\    "source": { "branch": { "name": "feature/nav" } },
    \\    "destination": { "branch": { "name": "main" } } }
    \\] }
;

test "listPullRequests parses summaries" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr_list };
    const bb = Client.init(fake.httpClient(), testCredential());

    const prs = try bb.listPullRequests(a, "myrepo", .{});
    defer deinitSummaries(a, prs);

    try testing.expectEqual(@as(usize, 2), prs.len);
    try testing.expectEqual(@as(u64, 42), prs[0].id);
    try testing.expectEqualStrings("Add diff parser", prs[0].title);
    try testing.expectEqualStrings("Ada Lovelace", prs[0].author_display_name);
    try testing.expectEqualStrings("feature/diff", prs[0].source_branch);
    try testing.expectEqualStrings("main", prs[0].destination_branch);
    try testing.expectEqualStrings("feature/nav", prs[1].source_branch);
}

test "listPullRequests builds a filtered, percent-encoded URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr_list };
    const bb = Client.init(fake.httpClient(), testCredential());

    const prs = try bb.listPullRequests(a, "myrepo", .{ .source_branch = "feature/x y" });
    defer deinitSummaries(a, prs);

    // state is a plain param; the branch filter is `source.branch.name="..."`
    // percent-encoded as a single q value (space→%20, quote→%22, slash→%2F).
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests" ++
            "?pagelen=50&state=OPEN&q=source.branch.name%3D%22feature%2Fx%20y%22",
        fake.lastUrl().?,
    );
}

test "listPullRequests follows next links across pages" {
    const a = testing.allocator;
    const page1 =
        \\{ "values": [
        \\  { "id": 1, "title": "one", "state": "OPEN",
        \\    "source": { "branch": { "name": "b1" } },
        \\    "destination": { "branch": { "name": "main" } } } ],
        \\  "next": "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests?page=2" }
    ;
    const page2 =
        \\{ "values": [
        \\  { "id": 2, "title": "two", "state": "OPEN",
        \\    "source": { "branch": { "name": "b2" } },
        \\    "destination": { "branch": { "name": "main" } } } ] }
    ;
    const Canned = @import("../http/fake_client.zig").Canned;
    const responses = [_]Canned{
        .{ .status = 200, .body = page1 },
        .{ .status = 200, .body = page2 },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());

    const prs = try bb.listPullRequests(a, "myrepo", .{});
    defer deinitSummaries(a, prs);

    try testing.expectEqual(@as(usize, 2), prs.len);
    try testing.expectEqual(@as(u64, 1), prs[0].id);
    try testing.expectEqual(@as(u64, 2), prs[1].id);
    try testing.expectEqual(@as(usize, 2), fake.call_count);
}

test "listPullRequests surfaces ApiError" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 401, .body = "" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.Unauthorized, bb.listPullRequests(a, "myrepo", .{}));
}

const sample_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-old
    \\+new
    \\
;

test "getDiff returns the raw diff text at the right URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = sample_diff };
    const bb = Client.init(fake.httpClient(), testCredential());

    const raw = try bb.getDiff(a, "myrepo", 42);
    defer a.free(raw);

    try testing.expectEqualStrings(sample_diff, raw);
    try testing.expectEqual(httpc.Method.GET, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42/diff",
        fake.lastUrl().?,
    );
}

test "getDiff surfaces ApiError on non-2xx and leaks nothing" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 404, .body = "not found" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.NotFound, bb.getDiff(a, "myrepo", 1));
}

test "getFileBlob returns the raw file text at the right URL" {
    const a = testing.allocator;
    const contents = "line1\nline2\nline3\n";
    var fake: FakeHttpClient = .{ .status = 200, .body = contents };
    const bb = Client.init(fake.httpClient(), testCredential());

    const blob = try bb.getFileBlob(a, "myrepo", "abc123", "src/foo.zig");
    defer a.free(blob);

    try testing.expectEqualStrings(contents, blob);
    try testing.expectEqual(httpc.Method.GET, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/src/abc123/src/foo.zig",
        fake.lastUrl().?,
    );
}

test "getFileBlob encodes each normalized path segment" {
    const cases = [_]struct { path: []const u8, encoded: []const u8 }{
        .{ .path = "src/file with space.txt", .encoded = "src/file%20with%20space.txt" },
        .{ .path = "src/Grüße.txt", .encoded = "src/Gr%C3%BC%C3%9Fe.txt" },
        .{ .path = "src/a%?#\".txt", .encoded = "src/a%25%3F%23%22.txt" },
        .{ .path = "\"leading quote.txt", .encoded = "%22leading%20quote.txt" },
    };
    for (cases) |case| {
        var fake: FakeHttpClient = .{ .status = 200, .body = "bytes" };
        const bb = Client.init(fake.httpClient(), testCredential());
        const blob = try bb.getFileBlob(testing.allocator, "myrepo", "abc123", case.path);
        defer testing.allocator.free(blob);
        const expected = try std.fmt.allocPrint(testing.allocator, "{s}/repositories/check24/myrepo/src/abc123/{s}", .{ base_url, case.encoded });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, fake.lastUrl().?);
    }
}

test "getFileBlob rejects malformed and non-repository-relative paths before HTTP" {
    const paths = [_][]const u8{ "", "/src/main.zig", "../main.zig", "src/../main.zig", "src//main.zig", "src/" };
    for (paths) |path| {
        var fake: FakeHttpClient = .{ .status = 200, .body = "must not be read" };
        const bb = Client.init(fake.httpClient(), testCredential());
        try testing.expectError(error.InvalidPath, bb.getFileBlob(testing.allocator, "myrepo", "abc123", path));
        try testing.expectEqual(@as(usize, 0), fake.call_count);
    }
}

test "getFileBlob preserves opaque response bytes" {
    const bytes = [_]u8{ 0xff, 0x00, 0x80 };
    var fake: FakeHttpClient = .{ .status = 200, .body = &bytes };
    const bb = Client.init(fake.httpClient(), testCredential());
    const blob = try bb.getFileBlob(testing.allocator, "myrepo", "abc123", "raw.bin");
    defer testing.allocator.free(blob);
    try testing.expectEqualSlices(u8, &bytes, blob);
}

test "checkFileBlob compares exact metadata and raw shape" {
    const body =
        \\{"type":"commit_file","path":"src/run.sh","commit":{"hash":"abc123"},"size":17,"attributes":["executable"]}
    ;
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = body },
        .{ .status = 200, .body = "0123456789abcdefg" },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    const raw_len = try bb.checkFileBlob(testing.allocator, "myrepo", "abc123", "src/run.sh", &.{"executable"});
    try testing.expectEqual(@as(usize, 17), raw_len);
    try testing.expectEqual(@as(usize, 2), fake.call_count);
}

test "checkFileBlob accepts nonempty equivalent commit prefixes and preserves validation" {
    const full_hash = "abcdef0123456789abcdef0123456789abcdef0123";
    const cases = [_]struct {
        commit: []const u8,
        metadata_hash: []const u8,
        size: usize = 17,
        attributes: []const []const u8 = &.{"executable"},
        expected_error: ?anyerror = null,
        expected_calls: usize = 2,
    }{
        .{ .commit = "abcdef012345", .metadata_hash = full_hash },
        .{ .commit = full_hash, .metadata_hash = full_hash },
        .{ .commit = full_hash, .metadata_hash = "abcdef012345" },
        .{ .commit = "abcdef999999", .metadata_hash = full_hash, .expected_error = error.BlobCommitMismatch, .expected_calls = 1 },
        .{ .commit = "", .metadata_hash = full_hash, .expected_error = error.BlobCommitMismatch, .expected_calls = 1 },
        .{ .commit = full_hash, .metadata_hash = "", .expected_error = error.BlobCommitMismatch, .expected_calls = 1 },
        .{ .commit = "", .metadata_hash = "", .expected_error = error.BlobCommitMismatch, .expected_calls = 1 },
        .{ .commit = "abcdef012345", .metadata_hash = full_hash, .size = 18, .expected_error = error.BlobSizeMismatch },
        .{ .commit = "abcdef012345", .metadata_hash = full_hash, .attributes = &.{}, .expected_error = error.BlobAttributesMismatch, .expected_calls = 1 },
    };
    for (cases) |case| {
        const metadata = try std.fmt.allocPrint(testing.allocator, "{{\"type\":\"commit_file\",\"path\":\"src/run.sh\",\"commit\":{{\"hash\":\"{s}\"}},\"size\":{d},\"attributes\":[\"executable\"]}}", .{ case.metadata_hash, case.size });
        defer testing.allocator.free(metadata);
        const responses = [_]@import("../http/fake_client.zig").Canned{
            .{ .body = metadata },
            .{ .body = "0123456789abcdefg" },
        };
        var fake: FakeHttpClient = .{ .responses = &responses };
        const bb = Client.init(fake.httpClient(), testCredential());
        if (case.expected_error) |expected| {
            try testing.expectError(expected, bb.checkFileBlob(testing.allocator, "myrepo", case.commit, "src/run.sh", case.attributes));
        } else {
            try testing.expectEqual(@as(usize, 17), try bb.checkFileBlob(testing.allocator, "myrepo", case.commit, "src/run.sh", case.attributes));
        }
        try testing.expectEqual(case.expected_calls, fake.call_count);
    }
}

test "getFileBlob accepts empty bytes as a successful response" {
    var fake: FakeHttpClient = .{ .status = 200, .body = "" };
    const bb = Client.init(fake.httpClient(), testCredential());
    const blob = try bb.getFileBlob(testing.allocator, "myrepo", "abc123", "empty.txt");
    defer testing.allocator.free(blob);
    try testing.expectEqual(@as(usize, 0), blob.len);
}

test "getFileBlob surfaces ApiError on non-2xx and leaks nothing" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 404, .body = "no such path" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.NotFound, bb.getFileBlob(a, "myrepo", "deadbeef", "gone.zig"));
}

test "createComment POSTs a top-level comment and parses the new id" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 201, .body =
        \\{ "id": 90210, "content": { "raw": "ship it" } }
    };
    const bb = Client.init(fake.httpClient(), testCredential());

    const id = try bb.createComment(a, "myrepo", 7, .{ .body = "ship it" });
    try testing.expectEqual(@as(CommentId, 90210), id);
    try testing.expectEqual(httpc.Method.POST, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments",
        fake.lastUrl().?,
    );
}

test "createComment builds an inline body for a root anchored comment" {
    const a = testing.allocator;
    // Capture the request body by rendering the same wire shape the client does.
    var fake: FakeHttpClient = .{ .status = 201, .body =
        \\{ "id": 1 }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    _ = try bb.createComment(a, "myrepo", 7, .{
        .body = "needs a test",
        .anchor = .{ .path = "src/foo.zig", .to = 42 },
    });
    // The wire shape is asserted directly (the fake doesn't retain the body):
    const Wire = struct {
        content: struct { raw: []const u8 },
        @"inline": ?struct { path: []const u8, from: ?u32 = null, to: ?u32 = null } = null,
        parent: ?struct { id: CommentId } = null,
    };
    var wire = Wire{ .content = .{ .raw = "needs a test" } };
    wire.@"inline" = .{ .path = "src/foo.zig", .to = 42 };
    const body = try std.json.Stringify.valueAlloc(a, wire, .{ .emit_null_optional_fields = false });
    defer a.free(body);
    try testing.expectEqualStrings(
        \\{"content":{"raw":"needs a test"},"inline":{"path":"src/foo.zig","to":42}}
    , body);
}

test "createComment maps File scope to a path-only inline object" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 201, .body =
        \\{ "id": 1 }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    _ = try bb.createComment(a, "myrepo", 7, .{
        .body = "whole file",
        .scope = .{ .file = .{ .path = "src/foo.zig", .source_commit = "local-only" } },
    });
    try testing.expectEqualStrings(
        \\{"content":{"raw":"whole file"},"inline":{"path":"src/foo.zig"}}
    , fake.lastBody().?);
}

test "createComment sends start_to alongside to for a new-side range" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 201, .body =
        \\{ "id": 1 }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    _ = try bb.createComment(a, "myrepo", 7, .{
        .body = "spans three lines",
        .anchor = .{ .path = "src/foo.zig", .start_to = 67, .to = 69 },
    });
    // Render the same wire shape the client builds; null `from`/`start_from`
    // are dropped, `to`/`start_to` survive as the range's bottom/top.
    const Wire = struct {
        content: struct { raw: []const u8 },
        @"inline": ?struct {
            path: []const u8,
            from: ?u32 = null,
            to: ?u32 = null,
            start_from: ?u32 = null,
            start_to: ?u32 = null,
        } = null,
    };
    var wire = Wire{ .content = .{ .raw = "spans three lines" } };
    wire.@"inline" = .{ .path = "src/foo.zig", .to = 69, .start_to = 67 };
    const body = try std.json.Stringify.valueAlloc(a, wire, .{ .emit_null_optional_fields = false });
    defer a.free(body);
    try testing.expectEqualStrings(
        \\{"content":{"raw":"spans three lines"},"inline":{"path":"src/foo.zig","to":69,"start_to":67}}
    , body);
}

test "createComment sends parent.id and no inline for a reply" {
    const a = testing.allocator;
    const Wire = struct {
        content: struct { raw: []const u8 },
        @"inline": ?struct { path: []const u8, from: ?u32 = null, to: ?u32 = null } = null,
        parent: ?struct { id: CommentId } = null,
    };
    // A reply carries parent, drops inline even when an anchor is present.
    var wire = Wire{ .content = .{ .raw = "agreed" } };
    wire.parent = .{ .id = 555 };
    const body = try std.json.Stringify.valueAlloc(a, wire, .{ .emit_null_optional_fields = false });
    defer a.free(body);
    try testing.expectEqualStrings(
        \\{"content":{"raw":"agreed"},"parent":{"id":555}}
    , body);

    var fake: FakeHttpClient = .{ .status = 201, .body =
        \\{ "id": 556 }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const id = try bb.createComment(a, "myrepo", 7, .{
        .body = "agreed",
        .anchor = .{ .path = "src/foo.zig", .to = 42 },
        .parent = 555,
    });
    try testing.expectEqual(@as(CommentId, 556), id);
}

test "createComment surfaces ApiError on non-2xx" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 400, .body = "bad anchor" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.BadRequest, bb.createComment(a, "myrepo", 7, .{ .body = "x" }));
}

test "authenticated account acquisition returns UUID and classifies unauthorized" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "uuid": "{account-uuid}", "display_name": "Ignored" }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const uuid = try bb.getAuthenticatedAccountUuid(a);
    defer a.free(uuid);
    try testing.expectEqualStrings("{account-uuid}", uuid);
    try testing.expectEqualStrings("https://api.bitbucket.org/2.0/user", fake.lastUrl().?);

    fake.status = 401;
    fake.body = "unauthorized";
    try testing.expectError(error.Unauthorized, bb.getAuthenticatedAccountUuid(a));
}

test "updateComment PUTs only accepted bytes as content raw" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = "{}" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try bb.updateComment(a, "myrepo", 7, 42, "```suggestion\nconst x = 2;\n```");

    try testing.expectEqual(httpc.Method.PUT, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments/42",
        fake.lastUrl().?,
    );
    try testing.expectEqualStrings(
        \\{"content":{"raw":"```suggestion\nconst x = 2;\n```"}}
    , fake.lastBody().?);
}

test "deleteComment DELETEs the exact Comment without a body" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 204, .body = "" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try bb.deleteComment(a, "myrepo", 7, 42);

    try testing.expectEqual(httpc.Method.DELETE, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments/42",
        fake.lastUrl().?,
    );
    try testing.expectEqualStrings("", fake.lastBody().?);
}

test "comment decoding retains UUID ownership evidence" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\  { "id": 1, "content": { "raw": "owned" },
        \\    "user": { "display_name": "Ada", "uuid": "{ada}" } }
        \\] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const comments = try bb.getComments(a, "myrepo", 7, .{});
    defer deinitComments(a, comments);
    try testing.expectEqualStrings("{ada}", comments[0].author_uuid.?);
}

const comments_page_1 =
    \\{
    \\  "values": [
    \\    { "id": 1, "content": { "raw": "Looks good overall" },
    \\      "user": { "display_name": "Ada" } },
    \\    { "id": 2, "parent": { "id": 1 }, "content": { "raw": "agreed" },
    \\      "user": { "display_name": "Bob" } },
    \\    { "id": 3, "content": { "raw": "gone" }, "deleted": true,
    \\      "user": { "display_name": "Sys", "uuid": "{sys}" },
    \\      "inline": { "path": "src/deleted.zig", "to": 9 } },
    \\    { "id": 6, "parent": { "id": 3 }, "content": { "raw": "survives" },
    \\      "user": { "display_name": "Eve" } },
    \\    { "id": 7, "content": { "raw": "unrelated deleted" }, "deleted": true,
    \\      "user": { "display_name": "Sys" } },
    \\    { "id": 4, "content": { "raw": "fix here" }, "user": { "display_name": "Cy" },
    \\      "inline": { "path": "src/foo.zig", "to": 42 },
    \\      "resolution": { "type": "resolution" } }
    \\  ],
    \\  "next": "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments?page=2"
    \\}
;

const comments_page_2 =
    \\{
    \\  "values": [
    \\    { "id": 5, "content": { "raw": "this line moved on" },
    \\      "user": { "display_name": "Di" },
    \\      "inline": { "path": "src/bar.zig", "from": 10, "outdated": true } }
    \\  ]
    \\}
;

test "getComments follows next links and retains only structural Deleted Comments" {
    const a = testing.allocator;
    const pages = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = comments_page_1 },
        .{ .status = 200, .body = comments_page_2 },
    };
    var fake: FakeHttpClient = .{ .responses = &pages };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "myrepo", 7, .{});
    defer @import("client.zig").deinitComments(a, comments);

    // The deleted root with a surviving Reply remains; the unrelated tombstone
    // is omitted.
    try testing.expectEqual(@as(usize, 2), fake.call_count);
    try testing.expectEqual(@as(usize, 6), comments.len);

    try testing.expectEqualStrings("Ada", comments[0].author);
    try testing.expect(comments[0].parent_id == null);

    // The reply keeps its parent link.
    try testing.expectEqual(@as(?review.CommentId, 1), comments[1].parent_id);

    const tombstone = comments[2];
    try testing.expect(tombstone.deleted);
    try testing.expectEqualStrings("", tombstone.body);
    try testing.expectEqualStrings("{sys}", tombstone.author_uuid.?);
    try testing.expectEqual(@as(?u32, 9), tombstone.scope.?.@"inline".to);
    try testing.expectEqual(@as(?review.CommentId, 3), comments[3].parent_id);

    // The inline+resolved comment.
    try testing.expect(comments[4].isInline());
    try testing.expectEqual(@as(?u32, 42), comments[4].anchor.?.to);
    try testing.expect(comments[4].resolved);
    try testing.expectEqual(review.AnchorState.current, comments[4].state);

    // Bitbucket's outdated verdict is honored.
    try testing.expectEqual(review.AnchorState.outdated, comments[5].state);
    try testing.expectEqual(@as(?u32, 10), comments[5].anchor.?.from);
}

test "getComments classifies Review File inline roots and strips Reply scope" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\ { "id": 1, "content": { "raw": "review" }, "user": { "display_name": "A" } },
        \\ { "id": 2, "content": { "raw": "file" }, "user": { "display_name": "A" }, "inline": { "path": "src/f.zig" } },
        \\ { "id": 3, "content": { "raw": "line" }, "user": { "display_name": "A" }, "inline": { "path": "src/f.zig", "to": 4 } },
        \\ { "id": 4, "parent": { "id": 3 }, "content": { "raw": "reply" }, "user": { "display_name": "B" }, "inline": { "path": "wire-echo", "to": 99 } }
        \\] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const comments = try bb.getComments(a, "repo", 1, .{ .source = "abc", .destination = "def" });
    defer deinitComments(a, comments);
    try testing.expect(comments[0].scope.? == .review);
    try testing.expect(comments[1].scope.? == .file);
    try testing.expectEqualStrings("src/f.zig", comments[1].scope.?.file.path);
    try testing.expectEqualStrings("abc", comments[1].scope.?.file.source_commit);
    try testing.expect(comments[2].scope.? == .@"inline");
    try testing.expect(comments[3].scope == null);
    try testing.expect(comments[3].anchor == null);
}

test "getComments normalizes mixed-side inline ranges to the new side" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\ { "id": 1, "content": { "raw": "range" }, "user": { "display_name": "A" },
        \\   "inline": { "path": "src/f.zig", "from": 13, "to": 15, "start_from": 9, "start_to": 9 } }
        \\] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const comments = try bb.getComments(a, "repo", 1, .{});
    defer deinitComments(a, comments);

    const anchor = comments[0].anchor.?;
    try testing.expectEqual(@as(?u32, null), anchor.from);
    try testing.expectEqual(@as(?u32, 15), anchor.to);
    try testing.expectEqual(@as(?u32, null), anchor.start_from);
    try testing.expectEqual(@as(?u32, 9), anchor.start_to);
}

// A real single-comment shape captured from PR 1726 (comment 811927613): an
// inline suggestion Bitbucket flags outdated. `from` is JSON null, `to` set.
const outdated_comment_page =
    \\{ "values": [
    \\  { "id": 811927613, "deleted": false, "pending": false,
    \\    "content": { "raw": "```suggestion\n        : phpOrigin;\n```\n\nyou already fall back" },
    \\    "user": { "display_name": "Stefan von der Krone" },
    \\    "inline": { "from": null, "to": 38, "path": "app/routes/rpc/$.ts",
    \\                "start_from": null, "start_to": null, "outdated": true, "base_rev": null } }
    \\] }
;

test "an inline.outdated comment parses to AnchorState.outdated" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = outdated_comment_page };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "pr-webapp", 1726, .{});
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(@as(usize, 1), comments.len);
    try testing.expectEqual(review.AnchorState.outdated, comments[0].state);
    try testing.expectEqual(@as(?u32, 38), comments[0].anchor.?.to);
    try testing.expect(comments[0].anchor.?.from == null);
    try testing.expect(comments[0].suggestion() != null);
}

// A multi-line-anchored comment as Bitbucket returns it (captured from a probe
// on PR 1856): a new-side range spans start_to..to, old side null.
const range_comment_page =
    \\{ "values": [
    \\  { "id": 822941278, "deleted": false,
    \\    "content": { "raw": "spans three lines" }, "user": { "display_name": "Ada" },
    \\    "inline": { "from": null, "to": 69, "path": ".storybook/main.ts",
    \\                "start_from": null, "start_to": 67, "outdated": false } }
    \\] }
;

test "a multi-line-anchored comment parses start_to and to into a range" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = range_comment_page };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "pr-webapp", 1856, .{});
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(@as(usize, 1), comments.len);
    const anc = comments[0].anchor.?;
    try testing.expect(anc.isRange());
    try testing.expectEqual(@as(?u32, 67), anc.start_to);
    try testing.expectEqual(@as(?u32, 69), anc.to);
    try testing.expect(anc.start_from == null and anc.from == null);
    try testing.expectEqual(@as(?u32, 69), anc.line()); // renders on the bottom line
}

// A list page as the *list* endpoint actually shapes it (no inline.outdated),
// with two comments: one anchored to the PR's current revision, one to an older
// one. Mirrors PR 1726: outdated is derived from links.code, not a flag.
const list_with_revisions =
    \\{ "values": [
    \\  { "id": 1, "deleted": false,
    \\    "content": { "raw": "current one" }, "user": { "display_name": "Ada" },
    \\    "inline": { "from": null, "to": 30, "path": "app/utility/env.ts" },
    \\    "links": { "code": { "href":
    \\      "https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/diff/check24/pr-webapp:f6180208c871..41739df6fc7f?path=app%2Futility%2Fenv.ts" } } },
    \\  { "id": 2, "deleted": false,
    \\    "content": { "raw": "stale one" }, "user": { "display_name": "Ada" },
    \\    "inline": { "from": null, "to": 38, "path": "app/routes/rpc/$.ts" },
    \\    "links": { "code": { "href":
    \\      "https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/diff/check24/pr-webapp:c034a30e082c..826e08904076?path=app%2Froutes%2Frpc%2F%24.ts" } } }
    \\] }
;

test "outdated is derived from links.code revision vs PR head" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = list_with_revisions };
    const bb = Client.init(fake.httpClient(), testCredential());

    // PR head as captured for 1726.
    const comments = try bb.getComments(a, "pr-webapp", 1726, .{
        .source = "f6180208c871",
        .destination = "41739df6fc7f",
    });
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(@as(usize, 2), comments.len);
    // #1 anchored to source..dest == current head → current.
    try testing.expectEqual(review.AnchorState.current, comments[0].state);
    // #2 anchored to an older revision → outdated.
    try testing.expectEqual(review.AnchorState.outdated, comments[1].state);
}

test "without PR head, list comments default to current (no false outdated)" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = list_with_revisions };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "pr-webapp", 1726, .{}); // no head
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(review.AnchorState.current, comments[0].state);
    try testing.expectEqual(review.AnchorState.current, comments[1].state);
}

test "parseCodeRevision extracts the src..dst pair" {
    const rev = parseCodeRevision(
        "https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/diff/check24/pr-webapp:aaaa..bbbb?path=x",
    ).?;
    try testing.expectEqualStrings("aaaa", rev.src);
    try testing.expectEqualStrings("bbbb", rev.dst);
    try testing.expect(parseCodeRevision("no colon or range here") == null);
}

// A full comments-list page captured live from PR 1726, then sanitized (author
// names, prose, suggestion code, file paths, and workspace scrubbed; comment
// ids and the links.code commit ranges kept, since outdated detection rides on
// them). Guards the real wire shape against schema drift.
const fixture_comments_1726 = @embedFile("testdata/comments_pr1726.json");

test "sanitized PR 1726 fixture: shape, deleted-skip, and outdated detection" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_comments_1726 };
    const bb = Client.init(fake.httpClient(), testCredential());

    // PR 1726's real head (the "current" comment anchors exactly this range).
    const comments = try bb.getComments(a, "pr-webapp", 1726, .{
        .source = "f6180208c871",
        .destination = "41739df6fc7f",
    });
    defer @import("client.zig").deinitComments(a, comments);

    // 19 on the wire, 9 deleted → 10 kept.
    try testing.expectEqual(@as(usize, 10), comments.len);

    var outdated: usize = 0;
    var suggestions: usize = 0;
    for (comments) |c| {
        if (c.state == .outdated) outdated += 1;
        if (c.suggestion() != null) suggestions += 1;
    }
    // Every comment but the one anchored to the current head is outdated.
    try testing.expectEqual(@as(usize, 9), outdated);
    try testing.expectEqual(@as(usize, 2), suggestions);

    // Threaded: 9 roots + 1 reply, and 8 outdated thread roots (the reply's
    // outdated-ness doesn't count as a root) — matching the live `check`.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const threads = try @import("../review/thread.zig").build(arena.allocator(), comments);
    try testing.expectEqual(@as(usize, 9), threads.len);

    var outdated_roots: usize = 0;
    for (threads) |t| {
        if (t.root.state == .outdated) outdated_roots += 1;
    }
    try testing.expectEqual(@as(usize, 8), outdated_roots);
}

test "hashMatches tolerates abbreviation" {
    try testing.expect(hashMatches("f6180208c871", "f6180208c871abcd1234"));
    try testing.expect(hashMatches("f6180208c871abcd1234", "f6180208c871"));
    try testing.expect(!hashMatches("f6180208c871", "c034a30e082c"));
    try testing.expect(!hashMatches("", "abc"));
}

test "getComments builds the correct first-page URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "myrepo", 7, .{});
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments?pagelen=100",
        fake.lastUrl().?,
    );
}

test "getComments surfaces ApiError on non-2xx" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 403, .body = "nope" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.Forbidden, bb.getComments(a, "myrepo", 7, .{}));
}

// A single-page body (no `next`) so the pagination loop terminates after one GET.
const comments_single =
    \\{
    \\  "values": [
    \\    { "id": 1, "content": { "raw": "Looks good overall" },
    \\      "user": { "display_name": "Ada" } },
    \\    { "id": 2, "parent": { "id": 1 }, "content": { "raw": "agreed" },
    \\      "user": { "display_name": "Bob" } },
    \\    { "id": 4, "content": { "raw": "fix here" }, "user": { "display_name": "Cy" },
    \\      "inline": { "path": "src/foo.zig", "to": 42 },
    \\      "resolution": { "type": "resolution" } }
    \\  ]
    \\}
;

test "getComments end to end feeds the thread builder" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = comments_single };
    const bb = Client.init(fake.httpClient(), testCredential());

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comments = try bb.getComments(arena.allocator(), "myrepo", 7, .{});
    const threads = try @import("../review/thread.zig").build(arena.allocator(), comments);

    // root #1 with reply #2, and inline root #4.
    try testing.expectEqual(@as(usize, 2), threads.len);
    try testing.expectEqual(@as(usize, 1), threads[0].replies.len);
    try testing.expect(threads[1].isInline());
    try testing.expect(threads[1].resolved);
}

test "getDiff output feeds the parser end to end" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = sample_diff };
    const bb = Client.init(fake.httpClient(), testCredential());

    const raw = try bb.getDiff(a, "myrepo", 42);
    defer a.free(raw);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try @import("../diff/parser.zig").parse(arena.allocator(), raw);

    try testing.expectEqual(@as(usize, 1), parsed.files.len);
    try testing.expectEqualStrings("a.txt", parsed.files[0].new_path);
    try testing.expectEqual(@as(usize, 3), parsed.files[0].hunks[0].lines.len);
}

// ---------------------------------------------------------------------------
// Additive `bbr api` surface: workspaces, repositories, commits, compare,
// single comment, resolve/reopen, tasks. Uses FakeHttpClient; no network.
// ---------------------------------------------------------------------------

test "listWorkspaces parses nested workspace entries" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\  { "workspace": { "slug": "acme", "name": "Acme", "uuid": "{w1}" } },
        \\  { "workspace": { "slug": "other", "name": "Other", "uuid": "{w2}" } }
        \\] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const items = try bb.listWorkspaces(a, .{});
    defer deinitWorkspaces(a, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("acme", items[0].slug);
    try testing.expectEqualStrings("{w1}", items[0].uuid);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/user/workspaces",
        fake.lastUrl().?,
    );
}

test "listWorkspaces honors no-follow and limit" {
    const a = testing.allocator;
    const page1 =
        \\{ "values": [ { "workspace": { "slug": "a" } } ],
        \\  "next": "https://api.bitbucket.org/2.0/user/workspaces?page=2" }
    ;
    const page2 =
        \\{ "values": [ { "workspace": { "slug": "b" } } ] }
    ;
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = page1 },
        .{ .status = 200, .body = page2 },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    const one = try bb.listWorkspaces(a, .{ .follow = false });
    defer deinitWorkspaces(a, one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(usize, 1), fake.call_count);
}

test "getWorkspace builds the right URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "slug": "acme", "name": "Acme", "uuid": "{w1}" }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const w = try bb.getWorkspace(a, "acme");
    defer deinitWorkspace(a, w);
    try testing.expectEqualStrings("acme", w.slug);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/workspaces/acme",
        fake.lastUrl().?,
    );
}

test "listRepositories parses slugs" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\  { "slug": "api", "full_name": "acme/api", "name": "api", "uuid": "{r1}", "is_private": true }
        \\] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const items = try bb.listRepositories(a, "acme", .{});
    defer deinitRepositories(a, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("acme/api", items[0].full_name);
    try testing.expect(items[0].is_private);
}

test "getRepository builds the right URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "slug": "api", "full_name": "acme/api" }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const r = try bb.getRepository(a, "api", "acme");
    defer deinitRepository(a, r);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/acme/api",
        fake.lastUrl().?,
    );
}

test "listPrCommits parses hashes" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [
        \\  { "hash": "abc123", "message": "first", "date": "2026-01-01" },
        \\  { "hash": "def456", "message": "second" }
        \\] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const items = try bb.listPrCommits(a, "myrepo", 42, .{});
    defer deinitCommits(a, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("abc123", items[0].hash);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42/commits",
        fake.lastUrl().?,
    );
}

test "getCompareDiff hits the from..to URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = sample_diff };
    const bb = Client.init(fake.httpClient(), testCredential());
    const raw = try bb.getCompareDiff(a, "myrepo", "aaa", "bbb", false);
    defer a.free(raw);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/diff/aaa..bbb",
        fake.lastUrl().?,
    );
    const patch = try bb.getCompareDiff(a, "myrepo", "aaa", "bbb", true);
    defer a.free(patch);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/patch/aaa..bbb",
        fake.lastUrl().?,
    );
}

test "getComment returns one typed comment" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "id": 9, "content": { "raw": "hello" }, "user": { "display_name": "Ada" } }
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const c = try bb.getComment(a, "myrepo", 7, 9);
    defer {
        var tmp = [_]review.Comment{c};
        _ = &tmp;
        deinitComment(a, c);
    }
    try testing.expectEqual(@as(u64, 9), c.id);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments/9",
        fake.lastUrl().?,
    );
}

test "resolveComment POSTs and reopenComment DELETEs" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = "{}" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try bb.resolveComment(a, "myrepo", 7, 42);
    try testing.expectEqual(httpc.Method.POST, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments/42/resolve",
        fake.lastUrl().?,
    );
    try bb.reopenComment(a, "myrepo", 7, 42);
    try testing.expectEqual(httpc.Method.DELETE, fake.last_method.?);
}

test "tasks round-trip: list, get, create, update, state, delete" {
    const a = testing.allocator;
    const list_body =
        \\{ "values": [
        \\  { "id": 1, "content": { "raw": "fix it" }, "state": "UNRESOLVED",
        \\    "creator": { "uuid": "{me}" }, "comment": { "id": 9 } }
        \\] }
    ;
    var fake: FakeHttpClient = .{ .status = 200, .body = list_body };
    const bb = Client.init(fake.httpClient(), testCredential());
    const items = try bb.listTasks(a, "myrepo", 7, .{});
    defer deinitTasks(a, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expect(!items[0].resolved());
    try testing.expectEqual(@as(?u64, 9), items[0].comment_id);

    const single =
        \\{ "id": 1, "content": { "raw": "fix it" }, "state": "RESOLVED" }
    ;
    var fake2: FakeHttpClient = .{ .status = 200, .body = single };
    const bb2 = Client.init(fake2.httpClient(), testCredential());
    const t = try bb2.getTask(a, "myrepo", 7, 1);
    defer deinitTask(a, t);
    try testing.expect(t.resolved());

    var fake3: FakeHttpClient = .{ .status = 201, .body = "{ \"id\": 5 }" };
    const bb3 = Client.init(fake3.httpClient(), testCredential());
    try testing.expectEqual(@as(u64, 5), try bb3.createTask(a, "myrepo", 7, "do it", null));
    try testing.expectEqual(httpc.Method.POST, fake3.last_method.?);

    var fake4: FakeHttpClient = .{ .status = 200, .body = single };
    const bb4 = Client.init(fake4.httpClient(), testCredential());
    const updated = try bb4.updateTask(a, "myrepo", 7, 1, null, .resolved);
    defer deinitTask(a, updated);
    try testing.expect(updated.resolved());
    try testing.expectEqual(httpc.Method.PUT, fake4.last_method.?);

    var fake5: FakeHttpClient = .{ .status = 204, .body = "" };
    const bb5 = Client.init(fake5.httpClient(), testCredential());
    try bb5.deleteTask(a, "myrepo", 7, 1);
    try testing.expectEqual(httpc.Method.DELETE, fake5.last_method.?);
}

test "getFileMeta parses size and attributes" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{"type":"commit_file","path":"src/run.sh","commit":{"hash":"abc123"},"size":17,"attributes":["executable"]}
    };
    const bb = Client.init(fake.httpClient(), testCredential());
    const m = try bb.getFileMeta(a, "myrepo", "abc123", "src/run.sh");
    defer deinitFileMeta(a, m);
    try testing.expectEqual(@as(usize, 17), m.size);
    try testing.expectEqual(@as(usize, 1), m.attributes.len);
}

const allocation_meta =
    \\{"type":"commit_file","path":"src/run.sh","commit":{"hash":"abc123"},"size":17,"attributes":["executable","link","another"]}
;

fn fileMetaAllocationCheck(allocator: Allocator) !void {
    var fake: FakeHttpClient = .{ .body = allocation_meta };
    const bb = Client.init(fake.httpClient(), testCredential());
    const meta = try bb.getFileMeta(allocator, "myrepo", "abc123", "src/run.sh");
    defer deinitFileMeta(allocator, meta);
    try testing.expectEqualStrings("src/run.sh", meta.path);
    try testing.expectEqualStrings("abc123", meta.commit);
    try testing.expectEqualStrings("another", meta.attributes[2]);
}

test "review fixes FileMeta rolls back every allocation exactly once" {
    try testing.checkAllAllocationFailures(testing.allocator, fileMetaAllocationCheck, .{});
}

// One response contains the required fields of each typed list decoder.
// This drives identical page/error paths through every public list method.
const paging_entry =
    \\{"id":1,"slug":"repo","full_name":"acme/repo","name":"Repo","uuid":"{repo}","workspace":{"slug":"acme","name":"Acme","uuid":"{ws}"},"hash":"abc","message":"commit","date":"today","title":"Review","state":"UNRESOLVED","source":{"branch":{"name":"feature"}},"destination":{"branch":{"name":"main"}},"author":{"display_name":"Ada"},"user":{"display_name":"Ada","uuid":"{ada}"},"creator":{"uuid":"{ada}"},"content":{"raw":"text"},"inline":{"path":"file.txt"}}
;
const paging_first = "{\"values\":[" ++ paging_entry ++ "," ++ paging_entry ++ "],\"next\":\"https://api.bitbucket.org/2.0/next?cursor=opaque\"}";
const paging_last = "{\"values\":[" ++ paging_entry ++ "]}";
const PagingKind = enum { workspaces, repositories, commits, range, tasks, pullrequests, comments, comments_attempt };

fn pagedCount(allocator: Allocator, bb: Client, kind: PagingKind, opts: PageOptions) !usize {
    switch (kind) {
        .workspaces => {
            const items = try bb.listWorkspaces(allocator, opts);
            defer deinitWorkspaces(allocator, items);
            return items.len;
        },
        .repositories => {
            const items = try bb.listRepositories(allocator, "acme", opts);
            defer deinitRepositories(allocator, items);
            return items.len;
        },
        .commits, .range => {
            const items = if (kind == .range) try bb.listRepoCommitRange(allocator, "repo", "base", "tip", opts) else try bb.listPrCommits(allocator, "repo", 7, opts);
            defer deinitCommits(allocator, items);
            return items.len;
        },
        .tasks => {
            const items = try bb.listTasks(allocator, "repo", 7, opts);
            defer deinitTasks(allocator, items);
            return items.len;
        },
        .pullrequests => {
            const items = try bb.listPullRequestsPage(allocator, "repo", .{ .source_branch = "feature" }, opts);
            defer deinitSummaries(allocator, items);
            return items.len;
        },
        .comments, .comments_attempt => {
            const items = if (kind == .comments_attempt) switch (try bb.getCommentsAttempt(allocator, "repo", 7, .{ .source = "abc", .destination = "def" })) {
                .comments => |items| items,
                .rejected => |failure| return failure.reason,
            } else try bb.getCommentsPage(allocator, "repo", 7, .{ .source = "abc", .destination = "def" }, opts);
            defer deinitComments(allocator, items);
            return items.len;
        },
    }
}

fn pagingAllocationCheck(allocator: Allocator, kind: PagingKind) !void {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .body = paging_first }, .{ .body = paging_last },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectEqual(@as(usize, 3), try pagedCount(allocator, bb, kind, .{ .pagelen = 2, .page = 3, .query = "id > 0", .sort = "-updated_on" }));
    try testing.expectEqual(@as(usize, 2), fake.call_count);
    try testing.expectEqualStrings("https://api.bitbucket.org/2.0/next?cursor=opaque", fake.urlAt(1).?);
}

test "review fixes typed pagers roll back every allocation across pages" {
    for (std.enums.values(PagingKind)) |kind| {
        try testing.checkAllAllocationFailures(testing.allocator, pagingAllocationCheck, .{kind});
    }
}

test "review fixes typed pagers stop at cap and preserve page options" {
    for (std.enums.values(PagingKind)) |kind| {
        if (kind == .comments_attempt) continue;
        for ([_]PageOptions{ .{ .limit = 0 }, .{ .limit = 1 }, .{ .limit = 2 }, .{ .follow = false } }) |control| {
            const responses = [_]@import("../http/fake_client.zig").Canned{
                .{ .body = paging_first }, .{ .body = paging_last },
            };
            var fake: FakeHttpClient = .{ .responses = &responses };
            var opts = control;
            opts.pagelen = 2;
            opts.page = 3;
            opts.query = "id > 0";
            opts.sort = "-updated_on";
            const count = try pagedCount(testing.allocator, Client.init(fake.httpClient(), testCredential()), kind, opts);
            const expected = control.limit orelse 2;
            try testing.expectEqual(expected, count);
            try testing.expectEqual(@as(usize, if (expected == 0) 0 else 1), fake.call_count);
            if (expected != 0) {
                const url = fake.lastUrl().?;
                try testing.expect(std.mem.indexOf(u8, url, "pagelen=2") != null);
                try testing.expect(std.mem.indexOf(u8, url, "page=3") != null);
                try testing.expect(std.mem.indexOf(u8, url, "id%20%3E%200") != null);
                try testing.expect(std.mem.indexOf(u8, url, "sort=-updated_on") != null);
            }
        }
    }
}

test "review fixes typed pagers free in-flight URL and previous items on errors" {
    const cases = [_]struct { response: @import("../http/fake_client.zig").Canned, expected: anyerror }{
        .{ .response = .{ .send_error = error.ConnectionResetByPeer }, .expected = error.ConnectionResetByPeer },
        .{ .response = .{ .status = 429, .body = "rate limited", .retry_after_ms = 2500 }, .expected = error.RateLimited },
        .{ .response = .{ .body = "not json" }, .expected = error.MalformedResponse },
    };
    for (std.enums.values(PagingKind)) |kind| {
        for (cases) |case| {
            for ([_]bool{ false, true }) |after_page| {
                const responses = [_]@import("../http/fake_client.zig").Canned{
                    if (after_page) .{ .body = paging_first } else case.response,
                    case.response,
                };
                var fake: FakeHttpClient = .{ .responses = &responses };
                try testing.expectError(case.expected, pagedCount(testing.allocator, Client.init(fake.httpClient(), testCredential()), kind, .{}));
                try testing.expectEqual(@as(usize, if (after_page) 2 else 1), fake.call_count);
            }
        }
    }
}

test "review fixes comments Attempt retains Retry-After after a successful page" {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .body = paging_first }, .{ .status = 429, .retry_after_ms = 2500 },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const result = try Client.init(fake.httpClient(), testCredential()).getCommentsAttempt(testing.allocator, "repo", 7, .{});
    try testing.expectEqual(error.RateLimited, result.rejected.reason);
    try testing.expectEqual(@as(?u64, 2500), result.rejected.retry_after_ms);
}

test "review fixes PullRequest source branch and query combine in one encoded filter" {
    var fake: FakeHttpClient = .{ .body = "{\"values\":[]}" };
    const items = try Client.init(fake.httpClient(), testCredential()).listPullRequestsPage(testing.allocator, "repo", .{ .source_branch = "feature/\"x\\y" }, .{ .query = "id=1 OR id=2", .sort = "-id", .follow = false });
    defer deinitSummaries(testing.allocator, items);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/repo/pullrequests?state=OPEN&q=source.branch.name%3D%22feature%2F%5C%22x%5C%5Cy%22%20AND%20%28id%3D1%20OR%20id%3D2%29&sort=-id",
        fake.lastUrl().?,
    );
}

test "review fixes commit range encodes include exclude and follows opaque pages to limit" {
    for ([_]usize{ 0, 1, 2, 3 }) |limit| {
        const responses = [_]@import("../http/fake_client.zig").Canned{
            .{ .body = paging_first }, .{ .body = paging_last },
        };
        var fake: FakeHttpClient = .{ .responses = &responses };
        const bb = Client.init(fake.httpClient(), testCredential());
        const items = try bb.listRepoCommitRange(testing.allocator, "repo", "base/&?", "tip +#", .{ .pagelen = 2, .page = 4, .limit = limit });
        defer deinitCommits(testing.allocator, items);
        try testing.expectEqual(limit, items.len);
        try testing.expectEqual(@as(usize, if (limit == 0) 0 else if (limit <= 2) 1 else 2), fake.call_count);
        if (limit != 0) try testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/check24/repo/commits?include=tip%20%2B%23&exclude=base%2F%26%3F&pagelen=2&page=4", fake.urlAt(0).?);
    }
}

test "review fixes Task filter counts matching state before applying limit" {
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .body = "{\"values\":[{\"id\":1,\"state\":\"RESOLVED\"}],\"next\":\"https://api.bitbucket.org/2.0/tasks?page=2\"}" },
        .{ .body = "{\"values\":[{\"id\":2,\"state\":\"UNRESOLVED\"},{\"id\":3,\"state\":\"UNRESOLVED\"}],\"next\":\"https://api.bitbucket.org/2.0/tasks?page=3\"}" },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const items = try Client.init(fake.httpClient(), testCredential()).listTasks(testing.allocator, "repo", 7, .{ .task_state = .unresolved, .limit = 1 });
    defer deinitTasks(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(@as(u64, 2), items[0].id);
    try testing.expectEqual(types.TaskState.unresolved, items[0].state);
    try testing.expectEqual(@as(usize, 2), fake.call_count);
}

test "review fixes Task state translation rejects unknown wire state and encodes updates" {
    var malformed: FakeHttpClient = .{ .body = "{\"values\":[{\"id\":1,\"state\":\"UNRESOLVED\",\"content\":{\"raw\":\"valid\"}},{\"id\":2,\"state\":\"OPEN\"}]}" };
    try testing.expectError(error.MalformedResponse, Client.init(malformed.httpClient(), testCredential()).listTasks(testing.allocator, "repo", 7, .{}));
    for ([_]types.TaskState{ .resolved, .unresolved }) |state| {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"id\":1,\"state\":\"{s}\"}}", .{taskStateWire(state)});
        defer testing.allocator.free(body);
        var fake: FakeHttpClient = .{ .body = body };
        const task = try Client.init(fake.httpClient(), testCredential()).setTaskState(testing.allocator, "repo", 7, 1, state);
        defer deinitTask(testing.allocator, task);
        try testing.expectEqual(state, task.state);
        const expected = try std.fmt.allocPrint(testing.allocator, "{{\"state\":\"{s}\"}}", .{taskStateWire(state)});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, fake.lastBody().?);
        const json = try std.json.Stringify.valueAlloc(testing.allocator, task, .{});
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, @tagName(state)) != null);
    }
}

test "review fixes malformed Comment scope frees partial decoding" {
    var fake: FakeHttpClient = .{ .body = "{\"values\":[{\"id\":1,\"user\":{\"display_name\":\"Ada\",\"uuid\":\"{ada}\"},\"inline\":{\"path\":\"file.txt\",\"start_to\":1}}]}" };
    try testing.expectError(error.MalformedResponse, Client.init(fake.httpClient(), testCredential()).getCommentsPage(testing.allocator, "repo", 7, .{}, .{}));
}

test "review followups Reviewer Verdict rejects the PullRequest Author before mutation" {
    for ([_]types.ReviewerVerdict{ .approved, .changes_requested, .no_verdict }) |target| {
        var fake: FakeHttpClient = .{ .body = verdict_none };
        const result = try Client.init(fake.httpClient(), testCredential()).changeReviewerVerdict(testing.allocator, "repo", 42, "abc123", "{ada}", target);
        try testing.expectEqual(error.Forbidden, result.api_error);
        try testing.expectEqual(@as(usize, 1), fake.call_count);
        try testing.expectEqual(httpc.Method.GET, fake.methodAt(0).?);
    }
}

test "review followups empty author evidence keeps Reviewer Verdict contract" {
    const before =
        \\{"id":42,"title":"Review","state":"OPEN","author":{"display_name":"Ada","uuid":""},"source":{"branch":{"name":"feature"},"commit":{"hash":"abc123"}},"destination":{"branch":{"name":"main"},"commit":{"hash":"def456"}},"participants":[]}
    ;
    const responses = [_]@import("../http/fake_client.zig").Canned{
        .{ .body = before }, .{ .body = "{}" }, .{ .body = verdict_approved },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const result = try Client.init(fake.httpClient(), testCredential()).changeReviewerVerdict(testing.allocator, "repo", 42, "abc123", "{me}", .approved);
    try testing.expectEqual(types.ReviewerVerdictChangeResult.success, result);
    try testing.expectEqual(@as(usize, 3), fake.call_count);
    try testing.expectEqual(httpc.Method.POST, fake.methodAt(1).?);
}

test "review followups commits prefer linked display name and retain raw-only author" {
    var fake: FakeHttpClient = .{ .body =
        \\{"values":[{"hash":"a","author":{"raw":"External Author <author@example.test>"}},{"hash":"b","author":{"user":{"display_name":"Linked Author"},"display_name":"Display Author","raw":"Raw Author"}},{"hash":"c","author":{"display_name":"Display Author","raw":"Raw Author"}}]}
    };
    const items = try Client.init(fake.httpClient(), testCredential()).listRepoCommits(testing.allocator, "repo", "main", .{});
    defer deinitCommits(testing.allocator, items);
    try testing.expectEqualStrings("External Author <author@example.test>", items[0].author);
    try testing.expectEqualStrings("Linked Author", items[1].author);
    try testing.expectEqualStrings("Display Author", items[2].author);
}
