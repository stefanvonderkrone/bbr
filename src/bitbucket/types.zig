//! Typed Bitbucket domain values and the API error taxonomy. See
//! `src/bitbucket/GLOSSARY.md` for the ubiquitous language.

/// A pull request, reduced to what M0 renders. All slices are owned by the
/// allocator passed to the adapter call that produced it.
pub const PullRequest = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author_display_name: []const u8,
    author_uuid: []const u8 = "",
    source_branch: []const u8,
    destination_branch: []const u8,
    /// Head commit of the source branch as we loaded it. Combined with
    /// `destination_commit` it identifies the PR's *current* diff revision; a
    /// comment anchored against a different revision is outdated (ADR-0001).
    source_commit: []const u8,
    /// Head commit of the destination branch as we loaded it.
    destination_commit: []const u8,
    reviewer_verdicts: ?[]const ReviewerVerdictEntry = null,
    draft: bool = false,
    description: []const u8 = "",
    close_source_branch: bool = false,
    source_repository: []const u8 = "",
    destination_repository: []const u8 = "",
    url: []const u8 = "",
    reviewers: ?[]const Reviewer = null,

    pub fn reviewerVerdict(self: PullRequest, authenticated_account_uuid: []const u8) ReviewerVerdict {
        for (self.reviewer_verdicts orelse &.{}) |entry| {
            if (std.mem.eql(u8, entry.account_uuid, authenticated_account_uuid)) return entry.verdict;
        }
        return .no_verdict;
    }
};

const std = @import("std");

pub const ReviewerVerdict = enum {
    approved,
    changes_requested,
    no_verdict,
};

pub const ReviewerVerdictEntry = struct {
    account_uuid: []const u8,
    verdict: ReviewerVerdict,
};

pub const Reviewer = struct {
    uuid: []const u8,
    display_name: []const u8 = "",
};

/// Optional values distinguish unchanged fields from explicit false or empty values.
pub const PullRequestOptions = struct {
    title: ?[]const u8 = null,
    source_branch: ?[]const u8 = null,
    source_repository: ?[]const u8 = null,
    destination_branch: ?[]const u8 = null,
    description: ?[]const u8 = null,
    reviewers: ?[]const []const u8 = null,
    draft: ?bool = null,
    close_source_branch: ?bool = null,

    pub fn validate(self: PullRequestOptions, create: bool) !void {
        if (create and (self.title == null or self.source_branch == null)) return error.MissingRequired;
        if (!create and self.source_repository != null) return error.BadRequest;
        if (!create and self.title == null and self.source_branch == null and
            self.destination_branch == null and self.description == null and self.reviewers == null and
            self.draft == null and self.close_source_branch == null) return error.BadRequest;
        for ([_]?[]const u8{ self.title, self.source_branch, self.destination_branch }) |value| {
            if (value) |text| if (text.len == 0) return error.BadRequest;
        }
        if (self.source_repository) |full_name| {
            const slash = std.mem.indexOfScalar(u8, full_name, '/') orelse return error.BadRequest;
            if (slash == 0 or slash + 1 == full_name.len or
                std.mem.indexOfScalar(u8, full_name[slash + 1 ..], '/') != null) return error.BadRequest;
        }
        if (self.reviewers) |reviewers| {
            for (reviewers) |uuid| if (uuid.len == 0) return error.BadRequest;
        }
    }
};

pub const ReviewerVerdictChangeResult = union(enum) {
    success,
    reconciled_success,
    api_error: ApiError,
    stale_source_commit,
    unresolved: ?ApiError,

    pub fn invalidatesAuthenticatedAccount(self: ReviewerVerdictChangeResult) bool {
        return switch (self) {
            .api_error => |err| err == error.Unauthorized,
            .unresolved => |err| if (err) |api_error| api_error == error.Unauthorized else false,
            else => false,
        };
    }
};

/// A pull request as it appears in a *list* result — enough to populate the
/// picker and decide the startup entry. The list endpoint omits the commit
/// hashes, so those live only on the full `PullRequest` (fetched on open). All
/// slices are owned by the allocator that produced the summary.
pub const PullRequestSummary = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author_display_name: []const u8,
    source_branch: []const u8,
    destination_branch: []const u8,
    draft: bool = false,
};

/// The commit pair identifying a PR's current diff revision. A comment whose
/// anchored `links.code` range differs from this is outdated.
pub const HeadCommits = struct {
    source: []const u8 = "",
    destination: []const u8 = "",
};

/// A Bitbucket workspace: owns repositories. All slices owned by the
/// allocator that produced the value.
pub const Workspace = struct {
    slug: []const u8,
    name: []const u8 = "",
    uuid: []const u8 = "",
};

/// A Bitbucket account in a Workspace. The producing allocator owns all strings.
pub const WorkspaceMember = struct {
    uuid: []const u8,
    display_name: []const u8,
    nickname: []const u8 = "",
};

/// A public Bitbucket account profile. The producing allocator owns all strings.
pub const User = struct {
    uuid: []const u8,
    account_id: []const u8 = "",
    display_name: []const u8 = "",
    nickname: []const u8 = "",
};

/// A repository within a workspace. All slices owned by the allocator that
/// produced the value.
pub const Repository = struct {
    slug: []const u8,
    full_name: []const u8 = "",
    name: []const u8 = "",
    uuid: []const u8 = "",
    is_private: bool = false,
};

pub const TaskState = enum { resolved, unresolved };

/// A task on a pull request: actionable prose distinct from a `Comment`.
/// `comment_id` links the task to a comment when created against one.
/// All slices owned by the allocator that produced the value.
pub const Task = struct {
    id: u64,
    content: []const u8,
    state: TaskState,
    creator_uuid: []const u8 = "",
    comment_id: ?u64 = null,

    pub fn resolved(self: Task) bool {
        return self.state == .resolved;
    }
};

/// A commit as listed on a pull request or repository. All slices owned by
/// the allocator that produced the value.
pub const Commit = struct {
    hash: []const u8,
    message: []const u8 = "",
    author: []const u8 = "",
    date: []const u8 = "",
};

/// A named reference to a Commit. All slices belong to the adapter's allocator.
pub const Branch = struct {
    name: []const u8,
    target: Commit,
    url: []const u8 = "",
    merge_strategies: []const []const u8 = &.{},
    default_merge_strategy: []const u8 = "",
};

/// Classified API failures. The adapter maps HTTP status → one of these so the
/// UI can react (re-auth, back off, report) without knowing HTTP.
pub const ApiError = error{
    /// 401 — bad or missing credentials.
    Unauthorized,
    /// 403 — authenticated but not permitted.
    Forbidden,
    /// 400 — the request shape or value is invalid.
    BadRequest,
    /// 404 — no such workspace/repo/PR.
    NotFound,
    /// 429 — rate limited; caller should back off.
    RateLimited,
    /// 409 — the request conflicts with current server state.
    Conflict,
    /// 5xx — Bitbucket-side failure; retryable.
    ServerError,
    /// Any other unexpected status.
    UnexpectedStatus,
    /// 2xx body did not match the expected shape.
    MalformedResponse,
};
