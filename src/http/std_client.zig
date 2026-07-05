//! `HttpClient` backed by `std.http.Client` (Zig 0.16). Owns the std client and
//! its TLS/connection state. Proxy config is read from the environment via
//! `initDefaultProxies`. This is the only file that touches `std.http`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const client = @import("client.zig");
const HttpClient = client.HttpClient;
const Request = client.Request;
const Response = client.Response;

pub const StdHttpClient = struct {
    inner: http.Client,

    /// `gpa` must be thread-safe (std.http.Client requires it). `io` is the
    /// runtime's `Io` (the default is backed by `std.Io.Threaded`).
    pub fn init(gpa: Allocator, io: Io) StdHttpClient {
        return .{ .inner = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *StdHttpClient) void {
        self.inner.deinit();
    }

    /// Read `http_proxy` / `https_proxy` (and `ALL_PROXY`, …) from the environment.
    /// `arena` must outlive the client — the proxy structs are allocated in it.
    pub fn initDefaultProxies(
        self: *StdHttpClient,
        arena: Allocator,
        environ_map: *const std.process.Environ.Map,
    ) !void {
        try self.inner.initDefaultProxies(arena, environ_map);
    }

    pub fn httpClient(self: *StdHttpClient) HttpClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: HttpClient.VTable = .{ .send = send };

    fn send(ptr: *anyopaque, allocator: Allocator, req: Request) anyerror!Response {
        const self: *StdHttpClient = @ptrCast(@alignCast(ptr));

        // Translate our headers into std's borrowed-header slice.
        const extra = try allocator.alloc(http.Header, req.headers.len);
        defer allocator.free(extra);
        for (req.headers, extra) |h, *out| out.* = .{ .name = h.name, .value = h.value };

        // fetch() writes the body into a writer; capture it into an owned slice.
        var body: Io.Writer.Allocating = .init(allocator);
        errdefer body.deinit();

        const result = try self.inner.fetch(.{
            .location = .{ .url = req.url },
            .method = toStdMethod(req.method),
            .payload = req.body,
            .extra_headers = extra,
            .response_writer = &body.writer,
        });

        return .{
            .status = @intFromEnum(result.status),
            .body = try body.toOwnedSlice(),
        };
    }

    fn toStdMethod(m: client.Method) http.Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        };
    }
};
