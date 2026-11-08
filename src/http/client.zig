//! The `HttpClient` seam: a ptr+vtable interface (idiomatic Zig, same shape as
//! `std.mem.Allocator` / `std.Io`) that the Bitbucket adapter talks to. Real
//! network access lives behind `StdHttpClient`; tests use `FakeHttpClient`.
//! Callers never see the `std.http.Client` shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    /// Absolute URL.
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
};

pub const Response = struct {
    /// Raw HTTP status code (200, 401, …). The Bitbucket adapter classifies it.
    status: u16,
    /// Response body, owned by the allocator passed to `send`.
    body: []u8,
    /// Normalized Retry-After guidance. Raw response headers never cross this
    /// seam, and only definite 429/5xx responses may populate this field.
    retry_after_ms: ?u64 = null,
};

pub const HttpClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The returned `Response.body` is allocated with `allocator`; the caller frees it.
        send: *const fn (ptr: *anyopaque, allocator: Allocator, req: Request) anyerror!Response,
    };

    pub fn send(self: HttpClient, allocator: Allocator, req: Request) !Response {
        return self.vtable.send(self.ptr, allocator, req);
    }
};
