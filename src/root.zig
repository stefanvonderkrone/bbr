//! The `bbr` library module: the network-free core (credential, HTTP seam,
//! Bitbucket adapter). The executable (`src/main.zig`) imports this and adds
//! the TUI. Tests for every file run via the aggregating `test` block below.

pub const http = struct {
    pub const client = @import("http/client.zig");
    pub const HttpClient = client.HttpClient;
    pub const StdHttpClient = @import("http/std_client.zig").StdHttpClient;
    pub const FakeHttpClient = @import("http/fake_client.zig").FakeHttpClient;
    pub const Canned = @import("http/fake_client.zig").Canned;
};

pub const diff = struct {
    pub const model = @import("diff/model.zig");
    pub const parser = @import("diff/parser.zig");
    pub const buffer = @import("diff/buffer.zig");
    pub const intraline = @import("diff/intraline.zig");
    pub const parse = parser.parse;
    pub const Buffer = buffer.Buffer;
    pub const Layout = buffer.Layout;
    pub const BuildOptions = buffer.BuildOptions;
    pub const Fold = buffer.Fold;
    pub const Diff = model.Diff;
    pub const File = model.File;
    pub const FileBlob = model.FileBlob;
    pub const FileStatus = model.FileStatus;
    pub const Hunk = model.Hunk;
    pub const Line = model.Line;
    pub const LineKind = model.LineKind;
};

pub const highlight = struct {
    pub const highlighter = @import("highlight/highlighter.zig");
    pub const decoration = @import("highlight/decoration.zig");
    pub const Highlighter = highlighter.Highlighter;
    pub const PlainHighlighter = highlighter.PlainHighlighter;
    pub const Capture = highlighter.Capture;
    pub const Span = highlighter.Span;
    pub const HighlightResult = highlighter.Result;
    pub const FileHighlights = highlighter.FileHighlights;
    pub const SideState = highlighter.SideState;
    pub const FileHighlightStatus = highlighter.FileHighlightStatus;
    pub const LineDecoration = decoration.LineDecoration;
    pub const DecorationRun = decoration.Run;
    pub const decorate = decoration.decorate;
};

pub const review = struct {
    pub const comment = @import("review/comment.zig");
    pub const thread = @import("review/thread.zig");
    pub const draft = @import("review/draft.zig");
    pub const store = @import("review/store.zig");
    pub const submission = @import("review/submission.zig");
    pub const submission_lock = @import("review/submission_lock.zig");
    pub const Comment = comment.Comment;
    pub const CommentId = comment.CommentId;
    pub const Anchor = comment.Anchor;
    pub const AnchorState = comment.AnchorState;
    pub const Thread = thread.Thread;
    pub const buildThreads = thread.build;
    pub const Draft = draft.Draft;
    pub const DraftKind = draft.DraftKind;
    pub const DraftState = draft.DraftState;
    pub const CommentTarget = draft.CommentTarget;
    pub const TempId = draft.TempId;
    pub const NewDraft = draft.NewDraft;
    pub const PendingReview = draft.PendingReview;
    pub const PendingReviewStore = store.PendingReviewStore;
    pub const ReviewKey = store.ReviewKey;
    pub const OperationId = store.OperationId;
    pub const ActiveSubmissionRun = store.ActiveSubmissionRun;
    pub const SubmissionOutcome = store.SubmissionOutcome;
    pub const SubmissionPendingState = store.SubmissionPendingState;
    pub const SubmissionCompletion = store.SubmissionCompletion;
    pub const InMemoryStore = store.InMemoryStore;
    pub const Submission = submission.Submission;
    pub const CommentPoster = submission.CommentPoster;
    pub const PostOutcome = submission.PostOutcome;
    pub const SubmissionStep = submission.Step;
    pub const SubmissionSummary = submission.Summary;
    pub const ItemResult = submission.ItemResult;
    pub const ItemStatus = submission.ItemStatus;
    pub const SubmissionLocks = submission_lock.SubmissionLocks;
    pub const SubmissionLockGuard = submission_lock.Guard;
    pub const InMemorySubmissionLocks = submission_lock.InMemorySubmissionLocks;
    pub const OsSubmissionLocks = submission_lock.OsSubmissionLocks;
    pub const headChanged = submission.headChanged;
};

pub const git = struct {
    pub const remote = @import("git/remote.zig");
    pub const Remote = remote.Remote;
    pub const Rewrite = remote.Rewrite;
    const client_mod = @import("git/client.zig");
    pub const GitClient = client_mod.GitClient;
    pub const ShellGitClient = client_mod.ShellGitClient;
    pub const FakeGitClient = client_mod.FakeGitClient;
    pub const GitError = client_mod.GitError;
};

pub const bitbucket = struct {
    const client_mod = @import("bitbucket/client.zig");
    pub const Client = client_mod.Client;
    pub const NewComment = client_mod.NewComment;
    pub const Poster = @import("bitbucket/poster.zig").Poster;
    pub const deinitPullRequest = client_mod.deinitPullRequest;
    pub const deinitComments = client_mod.deinitComments;
    pub const deinitSummaries = client_mod.deinitSummaries;
    pub const ListOptions = client_mod.ListOptions;
    pub const base_url = client_mod.base_url;
    pub const Credential = @import("bitbucket/credential.zig").Credential;
    pub const types = @import("bitbucket/types.zig");
    pub const PullRequest = types.PullRequest;
    pub const PullRequestSummary = types.PullRequestSummary;
    pub const ApiError = types.ApiError;
    pub const url = @import("bitbucket/url.zig");
};

pub const startup = @import("startup.zig");

test {
    _ = @import("http/client.zig");
    _ = @import("http/fake_client.zig");
    _ = @import("http/std_client.zig");
    _ = @import("bitbucket/credential.zig");
    _ = @import("bitbucket/client.zig");
    _ = @import("bitbucket/poster.zig");
    _ = @import("bitbucket/types.zig");
    _ = @import("diff/model.zig");
    _ = @import("diff/parser.zig");
    _ = @import("diff/buffer.zig");
    _ = @import("diff/intraline.zig");
    _ = @import("highlight/highlighter.zig");
    _ = @import("highlight/decoration.zig");
    _ = @import("review/comment.zig");
    _ = @import("review/thread.zig");
    _ = @import("review/draft.zig");
    _ = @import("review/store.zig");
    _ = @import("review/submission.zig");
    _ = @import("review/submission_lock.zig");
    _ = @import("git/remote.zig");
    _ = @import("git/client.zig");
    _ = @import("bitbucket/url.zig");
    _ = @import("startup.zig");
}
