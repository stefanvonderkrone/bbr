//! The `bbr` library module: the network-free core (credential, HTTP seam,
//! Bitbucket adapter). The executable (`src/main.zig`) imports this and adds
//! the TUI. Tests for every file run via the aggregating `test` block below.

pub const http = struct {
    pub const client = @import("http/client.zig");
    pub const HttpClient = client.HttpClient;
    pub const StdHttpClient = @import("http/std_client.zig").StdHttpClient;
    pub const FakeHttpClient = @import("http/fake_client.zig").FakeHttpClient;
};

pub const bitbucket = struct {
    const client_mod = @import("bitbucket/client.zig");
    pub const Client = client_mod.Client;
    pub const deinitPullRequest = client_mod.deinitPullRequest;
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
}
