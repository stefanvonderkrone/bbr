//! In-memory `HttpClient` for tests: returns a canned status + body and records
//! the last request so tests can assert URL / method. No network.
//!
//! Captured request data is copied into a fixed buffer, so it stays valid after
//! the caller frees the request's slices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const client = @import("client.zig");
const HttpClient = client.HttpClient;
const Request = client.Request;
const Response = client.Response;

/// One canned response in a scripted sequence.
pub const Canned = struct {
    status: u16 = 200,
    body: []const u8 = "",
};

pub const FakeHttpClient = struct {
    /// Status returned by `send` (when `responses` is null).
    status: u16 = 200,
    /// Body returned by `send` (copied into the caller's allocator).
    body: []const u8 = "",
    /// Optional scripted sequence: the Nth `send` returns `responses[N]`, so a
    /// paginated fetch can be driven page by page. Falls back to `status`/`body`
    /// once exhausted (or when null).
    responses: ?[]const Canned = null,

    /// Snapshot of the most recent request.
    last_method: ?client.Method = null,
    url_buf: [1024]u8 = undefined,
    url_len: usize = 0,
    call_count: usize = 0,

    pub fn httpClient(self: *FakeHttpClient) HttpClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The URL of the most recent request, or null if none yet.
    pub fn lastUrl(self: *const FakeHttpClient) ?[]const u8 {
        if (self.call_count == 0) return null;
        return self.url_buf[0..self.url_len];
    }

    const vtable: HttpClient.VTable = .{ .send = send };

    fn send(ptr: *anyopaque, allocator: Allocator, req: Request) anyerror!Response {
        const self: *FakeHttpClient = @ptrCast(@alignCast(ptr));
        self.last_method = req.method;
        self.url_len = @min(req.url.len, self.url_buf.len);
        @memcpy(self.url_buf[0..self.url_len], req.url[0..self.url_len]);

        const canned: Canned = if (self.responses) |seq|
            (if (self.call_count < seq.len) seq[self.call_count] else .{ .status = self.status, .body = self.body })
        else
            .{ .status = self.status, .body = self.body };

        self.call_count += 1;
        return .{
            .status = canned.status,
            .body = try allocator.dupe(u8, canned.body),
        };
    }
};
