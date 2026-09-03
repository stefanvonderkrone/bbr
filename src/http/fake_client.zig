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
    /// Optional URL substring used instead of call order.
    request_key: ?[]const u8 = null,
    status: u16 = 200,
    body: []const u8 = "",
    retry_after_ms: ?u64 = null,
    send_error: ?anyerror = null,
    /// A request waits until this flag becomes true. Tests use it to choose
    /// completion order without coupling responses to start order.
    released: ?*std.atomic.Value(bool) = null,
};

pub const FakeHttpClient = struct {
    /// Status returned by `send` (when `responses` is null).
    status: u16 = 200,
    /// Body returned by `send` (copied into the caller's allocator).
    body: []const u8 = "",
    retry_after_ms: ?u64 = null,
    /// Optional scripted sequence: the Nth `send` returns `responses[N]`, so a
    /// paginated fetch can be driven page by page. Falls back to `status`/`body`
    /// once exhausted (or when null).
    responses: ?[]const Canned = null,
    /// When set, `send` returns this error instead of a response — simulating a
    /// transport failure (connection reset, timeout) so callers can exercise the
    /// "did it post or not?" ambiguous path.
    send_error: ?anyerror = null,

    /// Snapshot of the most recent request.
    last_method: ?client.Method = null,
    url_buf: [1024]u8 = undefined,
    url_len: usize = 0,
    body_buf: [4096]u8 = undefined,
    body_len: usize = 0,
    method_history: [32]client.Method = undefined,
    url_history: [32][1024]u8 = undefined,
    url_history_len: [32]usize = @splat(0),
    call_count: usize = 0,
    active_requests: usize = 0,
    max_active_requests: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn httpClient(self: *FakeHttpClient) HttpClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The URL of the most recent request, or null if none yet.
    pub fn lastUrl(self: *const FakeHttpClient) ?[]const u8 {
        if (self.call_count == 0) return null;
        return self.url_buf[0..self.url_len];
    }

    pub fn lastBody(self: *const FakeHttpClient) ?[]const u8 {
        if (self.call_count == 0) return null;
        return self.body_buf[0..self.body_len];
    }

    pub fn methodAt(self: *const FakeHttpClient, index: usize) ?client.Method {
        if (index >= @min(self.call_count, self.method_history.len)) return null;
        return self.method_history[index];
    }

    pub fn urlAt(self: *const FakeHttpClient, index: usize) ?[]const u8 {
        if (index >= @min(self.call_count, self.url_history.len)) return null;
        return self.url_history[index][0..self.url_history_len[index]];
    }

    pub fn callCount(self: *FakeHttpClient) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.call_count;
    }

    pub fn maxActiveRequests(self: *FakeHttpClient) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.max_active_requests;
    }

    pub fn activeRequestCount(self: *FakeHttpClient) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.active_requests;
    }

    const vtable: HttpClient.VTable = .{ .send = send };

    fn send(ptr: *anyopaque, allocator: Allocator, req: Request) anyerror!Response {
        const self: *FakeHttpClient = @ptrCast(@alignCast(ptr));
        var canned: Canned = undefined;
        var send_error: ?anyerror = null;
        {
            self.lock();
            defer self.mutex.unlock();
            self.last_method = req.method;
            self.url_len = @min(req.url.len, self.url_buf.len);
            @memcpy(self.url_buf[0..self.url_len], req.url[0..self.url_len]);
            if (self.call_count < self.method_history.len) {
                self.method_history[self.call_count] = req.method;
                self.url_history_len[self.call_count] = @min(req.url.len, self.url_history[self.call_count].len);
                @memcpy(self.url_history[self.call_count][0..self.url_history_len[self.call_count]], req.url[0..self.url_history_len[self.call_count]]);
            }
            if (req.body) |body| {
                self.body_len = @min(body.len, self.body_buf.len);
                @memcpy(self.body_buf[0..self.body_len], body[0..self.body_len]);
            } else self.body_len = 0;

            const call_index = self.call_count;
            self.call_count += 1;
            self.active_requests += 1;
            self.max_active_requests = @max(self.max_active_requests, self.active_requests);
            canned = self.responseFor(req.url, call_index);
            send_error = if (canned.send_error) |err| err else self.send_error;
        }
        defer {
            self.lock();
            defer self.mutex.unlock();
            self.active_requests -= 1;
        }

        if (canned.released) |released|
            while (!released.load(.acquire)) std.atomic.spinLoopHint();
        if (send_error) |e| return e;
        return .{
            .status = canned.status,
            .body = try allocator.dupe(u8, canned.body),
            .retry_after_ms = if (canned.status == 429 or canned.status >= 500 and canned.status <= 599) canned.retry_after_ms else null,
        };
    }

    fn responseFor(self: *const FakeHttpClient, url: []const u8, call_index: usize) Canned {
        if (self.responses) |seq| {
            for (seq) |canned| {
                const key = canned.request_key orelse continue;
                if (std.mem.indexOf(u8, url, key) != null) return canned;
            }
            if (call_index < seq.len and seq[call_index].request_key == null) return seq[call_index];
        }
        return .{ .status = self.status, .body = self.body, .retry_after_ms = self.retry_after_ms };
    }

    fn lock(self: *FakeHttpClient) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

test "request-keyed responses do not depend on call order" {
    const responses = [_]Canned{
        .{ .request_key = "/slow", .status = 201, .body = "slow" },
        .{ .request_key = "/fast", .status = 202, .body = "fast" },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const http = fake.httpClient();
    const fast = try http.send(std.testing.allocator, .{ .method = .GET, .url = "https://example.test/fast" });
    defer std.testing.allocator.free(fast.body);
    const slow = try http.send(std.testing.allocator, .{ .method = .GET, .url = "https://example.test/slow" });
    defer std.testing.allocator.free(slow.body);

    try std.testing.expectEqual(@as(u16, 202), fast.status);
    try std.testing.expectEqualStrings("slow", slow.body);
}
