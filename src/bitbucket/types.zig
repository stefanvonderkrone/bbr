//! Typed Bitbucket domain values and the API error taxonomy. See
//! `src/bitbucket/CONTEXT.md` for the ubiquitous language.

/// A pull request, reduced to what M0 renders. All slices are owned by the
/// allocator passed to the adapter call that produced it.
pub const PullRequest = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author_display_name: []const u8,
    source_branch: []const u8,
    destination_branch: []const u8,
    /// Head commit of the source branch as we loaded it. Combined with
    /// `destination_commit` it identifies the PR's *current* diff revision; a
    /// comment anchored against a different revision is outdated (ADR-0001).
    source_commit: []const u8,
    /// Head commit of the destination branch as we loaded it.
    destination_commit: []const u8,
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
    /// 404 — no such workspace/repo/PR.
    NotFound,
    /// 429 — rate limited; caller should back off.
    RateLimited,
    /// 5xx — Bitbucket-side failure; retryable.
    ServerError,
    /// Any other unexpected status.
    UnexpectedStatus,
    /// 2xx body did not match the expected shape.
    MalformedResponse,
};
