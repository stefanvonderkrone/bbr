//! Typed Bitbucket domain values and the API error taxonomy. See
//! `src/bitbucket/CONTEXT.md` for the ubiquitous language.

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
};

/// The commit pair identifying a PR's current diff revision. A comment whose
/// anchored `links.code` range differs from this is outdated.
pub const HeadCommits = struct {
    source: []const u8 = "",
    destination: []const u8 = "",
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
