//! The `bbr` library module: the network-free core (credential, HTTP seam,
//! Bitbucket adapter). The executable (`src/main.zig`) imports this and adds
//! the TUI. Tests for every file run via the aggregating `test` block below.

pub const http = struct {
    pub const client = @import("http/client.zig");
    pub const HttpClient = client.HttpClient;
    pub const StdHttpClient = @import("http/std_client.zig").StdHttpClient;
    pub const FakeHttpClient = @import("http/fake_client.zig").FakeHttpClient;
};

pub const diff = struct {
    pub const model = @import("diff/model.zig");
    pub const parser = @import("diff/parser.zig");
    pub const buffer = @import("diff/buffer.zig");
    pub const parse = parser.parse;
    pub const Buffer = buffer.Buffer;
    pub const Layout = buffer.Layout;
    pub const Diff = model.Diff;
    pub const File = model.File;
    pub const FileStatus = model.FileStatus;
    pub const Hunk = model.Hunk;
    pub const Line = model.Line;
    pub const LineKind = model.LineKind;
};

pub const review = struct {
    pub const comment = @import("review/comment.zig");
    pub const thread = @import("review/thread.zig");
    pub const Comment = comment.Comment;
    pub const CommentId = comment.CommentId;
    pub const Anchor = comment.Anchor;
    pub const AnchorState = comment.AnchorState;
    pub const Thread = thread.Thread;
    pub const buildThreads = thread.build;
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
    pub const deinitPullRequest = client_mod.deinitPullRequest;
    pub const deinitComments = client_mod.deinitComments;
    pub const base_url = client_mod.base_url;
    pub const Credential = @import("bitbucket/credential.zig").Credential;
    pub const types = @import("bitbucket/types.zig");
    pub const PullRequest = types.PullRequest;
    pub const ApiError = types.ApiError;
};

test {
    _ = @import("http/client.zig");
    _ = @import("http/fake_client.zig");
    _ = @import("http/std_client.zig");
    _ = @import("bitbucket/credential.zig");
    _ = @import("bitbucket/client.zig");
    _ = @import("bitbucket/types.zig");
    _ = @import("diff/model.zig");
    _ = @import("diff/parser.zig");
    _ = @import("diff/buffer.zig");
    _ = @import("review/comment.zig");
    _ = @import("review/thread.zig");
    _ = @import("git/remote.zig");
    _ = @import("git/client.zig");
}
