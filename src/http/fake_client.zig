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

pub const FakeHttpClient = struct {
    /// Status returned by the next `send`.
    status: u16 = 200,
    /// Body returned by the next `send` (copied into the caller's allocator).
    body: []const u8 = "",

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
        self.call_count += 1;
        return .{
            .status = self.status,
            .body = try allocator.dupe(u8, self.body),
        };
    }
};
