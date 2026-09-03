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
    max_connection_count: std.atomic.Value(usize) = .init(0),
    track_connection_count: bool = false,

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
        try validateProxyEnvironment(environ_map);
        try self.inner.initDefaultProxies(arena, environ_map);
    }

    pub fn httpClient(self: *StdHttpClient) HttpClient {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn maxConnectionCount(self: *StdHttpClient) usize {
        return self.max_connection_count.load(.acquire);
    }

    /// Enable Zig-internal pool inspection for the opt-in acquisition check.
    pub fn enableConnectionCountTracking(self: *StdHttpClient) void {
        self.track_connection_count = true;
    }

    const vtable: HttpClient.VTable = .{ .send = sendLogged };

    fn sendLogged(ptr: *anyopaque, allocator: Allocator, req: Request) anyerror!Response {
        return send(ptr, allocator, req) catch |err| {
            if (isSubmissionRequest(req)) {
                const self: *StdHttpClient = @ptrCast(@alignCast(ptr));
                writeSubmitError(self.inner.io, .cwd(), req.method, req.url, err) catch {};
            }
            return err;
        };
    }

    fn send(ptr: *anyopaque, allocator: Allocator, req: Request) anyerror!Response {
        const self: *StdHttpClient = @ptrCast(@alignCast(ptr));

        // Translate our headers into std's borrowed-header slice.
        const extra = try allocator.alloc(http.Header, req.headers.len);
        defer allocator.free(extra);
        for (req.headers, extra) |h, *out| out.* = .{ .name = h.name, .value = h.value };

        const uri = try std.Uri.parse(req.url);
        var request = try self.inner.request(toStdMethod(req.method), uri, .{
            .extra_headers = extra,
            .headers = .{ .accept_encoding = .omit },
            .redirect_behavior = if (req.body == null) @enumFromInt(3) else .unhandled,
        });
        if (self.track_connection_count) self.recordConnectionCount();
        defer request.deinit();
        request.accept_encoding = @splat(false);
        request.accept_encoding[@intFromEnum(http.ContentEncoding.identity)] = true;
        if (req.body) |payload| {
            request.transfer_encoding = .{ .content_length = payload.len };
            var request_body = try request.sendBodyUnflushed(&.{});
            try request_body.writer.writeAll(payload);
            try request_body.end();
            try request.connection.?.flush();
        } else {
            try request.sendBodiless();
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const status: u16 = @intFromEnum(response.head.status);
        const retry_after_ms = if (status == 429 or status >= 500 and status <= 599)
            retryAfterFromHead(response.head, Io.Clock.real.now(self.inner.io).toSeconds())
        else
            null;

        var body: Io.Writer.Allocating = .init(allocator);
        errdefer body.deinit();
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        _ = reader.streamRemaining(&body.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };

        const response_body = try body.toOwnedSlice();
        if (isSubmissionRequest(req))
            writeSubmitResponse(self.inner.io, .cwd(), req.method, req.url, status) catch {};

        return .{
            .status = status,
            .body = response_body,
            .retry_after_ms = retry_after_ms,
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

    fn recordConnectionCount(self: *StdHttpClient) void {
        const pool = &self.inner.connection_pool;
        pool.mutex.lockUncancelable(self.inner.io);
        defer pool.mutex.unlock(self.inner.io);
        var count = pool.free_len;
        var node = pool.used.first;
        while (node) |current| : (node = current.next) count += 1;
        const previous = self.max_connection_count.load(.monotonic);
        if (count > previous) self.max_connection_count.store(count, .release);
    }
};

fn validateProxyEnvironment(environ_map: *const std.process.Environ.Map) !void {
    const proxy_names = [_][]const u8{
        "http_proxy",
        "HTTP_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "all_proxy",
        "ALL_PROXY",
    };
    var proxy_configured = false;
    for (proxy_names) |name| {
        const value = environ_map.get(name) orelse continue;
        if (value.len == 0) continue;
        proxy_configured = true;
        const uri = std.Uri.parse(value) catch std.Uri.parseAfterScheme("http", value) catch
            return error.InvalidProxyConfiguration;
        if (uri.host == null or
            !(std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")))
            return error.InvalidProxyConfiguration;
    }
    const bypass_names = [_][]const u8{ "no_proxy", "NO_PROXY" };
    for (bypass_names) |name| {
        if (environ_map.get(name)) |value| {
            if (proxy_configured and value.len != 0) return error.InvalidProxyConfiguration;
        }
    }
}

fn isSubmissionRequest(req: Request) bool {
    return std.mem.indexOf(u8, req.url, "/comments") != null and (req.method == .POST or req.method == .GET);
}

fn methodName(method: client.Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
    };
}

fn writeSubmitResponse(io: Io, dir: Io.Dir, method: client.Method, url: []const u8, status: u16) !void {
    var file = try dir.createFile(io, "bbr-submit-response.log", .{ .truncate = false, .lock = .exclusive, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    var offset = try file.length(io);
    try appendLog(file, io, &offset, methodName(method));
    try appendLog(file, io, &offset, " ");
    try appendRequestLocation(file, io, &offset, url);
    var status_buffer: [32]u8 = undefined;
    const status_line = try std.fmt.bufPrint(&status_buffer, "\nstatus: {d}\n", .{status});
    try appendLog(file, io, &offset, status_line);
}

fn writeSubmitError(io: Io, dir: Io.Dir, method: client.Method, url: []const u8, err: anyerror) !void {
    var file = try dir.createFile(io, "bbr-submit-response.log", .{ .truncate = false, .lock = .exclusive, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    var offset = try file.length(io);
    try appendLog(file, io, &offset, methodName(method));
    try appendLog(file, io, &offset, " ");
    try appendRequestLocation(file, io, &offset, url);
    try appendLog(file, io, &offset, "\ntransport error: ");
    try appendLog(file, io, &offset, @errorName(err));
    try appendLog(file, io, &offset, "\n");
}

fn appendRequestLocation(file: Io.File, io: Io, offset: *u64, url: []const u8) !void {
    const uri = std.Uri.parse(url) catch {
        return appendLog(file, io, offset, "<invalid request location>");
    };
    try appendLog(file, io, offset, uri.scheme);
    try appendLog(file, io, offset, "://");
    try appendLog(file, io, offset, componentText(uri.host orelse return error.InvalidRequestLocation));
    if (uri.port) |port| {
        var port_buffer: [8]u8 = undefined;
        try appendLog(file, io, offset, try std.fmt.bufPrint(&port_buffer, ":{d}", .{port}));
    }
    try appendLog(file, io, offset, componentText(uri.path));
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |text| text,
    };
}

fn appendLog(file: Io.File, io: Io, offset: *u64, bytes: []const u8) !void {
    try file.writePositionalAll(io, bytes, offset.*);
    offset.* += bytes.len;
}

fn retryAfterFromHead(head: http.Client.Response.Head, now_seconds: i64) ?u64 {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after"))
            return parseRetryAfter(header.value, now_seconds);
    }
    return null;
}

/// Parse the two Retry-After wire forms from RFC 9110. `now_seconds` is passed
/// in so parsing remains deterministic and the HTTP adapter is the only clock
/// reader. Expired dates and values that cannot be represented in milliseconds
/// are deliberately ignored.
pub fn parseRetryAfter(value: []const u8, now_seconds: i64) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(u64, trimmed, 10)) |seconds| {
        const milliseconds = std.math.mul(u64, seconds, std.time.ms_per_s) catch return null;
        return if (milliseconds <= std.math.maxInt(i64)) milliseconds else null;
    } else |_| {}

    const target = parseHttpDate(trimmed) orelse return null;
    if (target <= now_seconds) return null;
    const delay: u64 = @intCast(target - now_seconds);
    const milliseconds = std.math.mul(u64, delay, std.time.ms_per_s) catch return null;
    return if (milliseconds <= std.math.maxInt(i64)) milliseconds else null;
}

fn parseHttpDate(value: []const u8) ?i64 {
    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
    if (value.len != 29 or !std.mem.eql(u8, value[3..5], ", ") or
        value[7] != ' ' or value[11] != ' ' or value[16] != ' ' or
        value[19] != ':' or value[22] != ':' or !std.mem.eql(u8, value[25..], " GMT")) return null;
    const weekday = parseWeekday(value[0..3]) orelse return null;
    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const month = parseMonth(value[8..11]) orelse return null;
    const year = std.fmt.parseInt(u16, value[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return null;
    if (year < 1970 or day == 0 or day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 59) return null;

    var days: i64 = 0;
    var current_year: u16 = 1970;
    while (current_year < year) : (current_year += 1) days += if (isLeap(current_year)) 366 else 365;
    var current_month: u8 = 1;
    while (current_month < month) : (current_month += 1) days += daysInMonth(year, current_month);
    days += day - 1;
    if (@as(u8, @intCast(@mod(days + 4, 7))) != weekday) return null;
    return days * std.time.s_per_day + @as(i64, hour) * std.time.s_per_hour + @as(i64, minute) * std.time.s_per_min + second;
}

fn parseWeekday(value: []const u8) ?u8 {
    const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    for (names, 0..) |name, weekday| if (std.mem.eql(u8, value, name)) return @intCast(weekday);
    return null;
}

fn parseMonth(value: []const u8) ?u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |name, month| if (std.mem.eql(u8, value, name)) return @intCast(month);
    return null;
}

fn isLeap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(year)) 29 else 28,
        else => 0,
    };
}

test "Retry-After parses delay-seconds and HTTP-date forms" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u64, 12_000), parseRetryAfter("12", 0));
    const now = parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT").?;
    try testing.expectEqual(@as(?u64, 3_000), parseRetryAfter("Sun, 06 Nov 1994 08:49:40 GMT", now));
}

test "Retry-After rejects malformed overflowing and expired guidance" {
    const testing = std.testing;
    const now = parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT").?;
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("-1", now));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("18446744073709551615", now));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("tomorrow", now));
}

test "Retry-After header matching is case-insensitive" {
    const head = try http.Client.Response.Head.parse(
        "HTTP/1.1 503 Service Unavailable\r\nrEtRy-AfTeR: 7\r\ncontent-length: 0\r\n\r\n",
    );
    try std.testing.expectEqual(@as(?u64, 7_000), retryAfterFromHead(head, 0));
}

test "default proxies load lowercase and uppercase standard variables" {
    const testing = std.testing;
    const cases = [_]struct { name: []const u8, http: bool, https: bool }{
        .{ .name = "http_proxy", .http = true, .https = false },
        .{ .name = "HTTP_PROXY", .http = true, .https = false },
        .{ .name = "https_proxy", .http = false, .https = true },
        .{ .name = "HTTPS_PROXY", .http = false, .https = true },
        .{ .name = "all_proxy", .http = true, .https = true },
        .{ .name = "ALL_PROXY", .http = true, .https = true },
    };
    for (cases) |case| {
        var environment = std.process.Environ.Map.init(testing.allocator);
        defer environment.deinit();
        try environment.put(case.name, "http://proxy.example:8080");
        var transport = StdHttpClient.init(testing.allocator, testing.io);
        defer transport.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        try transport.initDefaultProxies(arena.allocator(), &environment);

        try testing.expectEqual(case.http, transport.inner.http_proxy != null);
        try testing.expectEqual(case.https, transport.inner.https_proxy != null);
        if (transport.inner.http_proxy) |proxy|
            try testing.expectEqualStrings("proxy.example", proxy.host.bytes);
        if (transport.inner.https_proxy) |proxy|
            try testing.expectEqualStrings("proxy.example", proxy.host.bytes);
    }
}

test "invalid and unsupported proxy configuration stops without a direct fallback" {
    const testing = std.testing;
    const cases = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "HTTP_PROXY", .value = "ftp://proxy.example" },
        .{ .name = "https_proxy", .value = "http://[" },
    };
    for (cases) |case| {
        var environment = std.process.Environ.Map.init(testing.allocator);
        defer environment.deinit();
        try environment.put(case.name, case.value);
        var transport = StdHttpClient.init(testing.allocator, testing.io);
        defer transport.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        try testing.expectError(
            error.InvalidProxyConfiguration,
            transport.initDefaultProxies(arena.allocator(), &environment),
        );
        try testing.expect(transport.inner.http_proxy == null);
        try testing.expect(transport.inner.https_proxy == null);
    }
}

test "bypass-only proxy environment permits direct access" {
    const testing = std.testing;
    for ([_][]const u8{ "no_proxy", "NO_PROXY" }) |name| {
        var environment = std.process.Environ.Map.init(testing.allocator);
        defer environment.deinit();
        try environment.put(name, "localhost,127.0.0.1");
        var transport = StdHttpClient.init(testing.allocator, testing.io);
        defer transport.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        try transport.initDefaultProxies(arena.allocator(), &environment);
        try testing.expect(transport.inner.http_proxy == null);
        try testing.expect(transport.inner.https_proxy == null);
    }
}

test "proxy with unsupported bypass list stops without a direct fallback" {
    const testing = std.testing;
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("HTTP_PROXY", "http://proxy.example:8080");
    try environment.put("NO_PROXY", "api.bitbucket.org");
    var transport = StdHttpClient.init(testing.allocator, testing.io);
    defer transport.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.InvalidProxyConfiguration,
        transport.initDefaultProxies(arena.allocator(), &environment),
    );
    try testing.expect(transport.inner.http_proxy == null);
    try testing.expect(transport.inner.https_proxy == null);
}

test "submission diagnostics omit credentials query values and response bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSubmitResponse(std.testing.io, tmp.dir, .POST, "https://account:credential@api.bitbucket.org/2.0/comments?token=credential", 201);
    try writeSubmitError(std.testing.io, tmp.dir, .GET, "https://api.bitbucket.org/2.0/comments?access_token=credential", error.ConnectionResetByPeer);
    const logged = try tmp.dir.readFileAlloc(std.testing.io, "bbr-submit-response.log", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(logged);
    try std.testing.expectEqualStrings(
        "POST https://api.bitbucket.org/2.0/comments\nstatus: 201\nGET https://api.bitbucket.org/2.0/comments\ntransport error: ConnectionResetByPeer\n",
        logged,
    );
    try std.testing.expect(std.mem.indexOf(u8, logged, "credential") == null);
}

test "one StdHttpClient overlaps two local requests and cleans up" {
    const net = std.Io.net;
    var address = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    var release: std.atomic.Value(bool) = .init(false);
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = try std.testing.io.concurrent(serveTwo, .{ &server, &release, &accepted, std.testing.io });
    defer server_future.await(std.testing.io) catch {};

    var transport = StdHttpClient.init(std.testing.allocator, std.testing.io);
    defer transport.deinit();
    transport.enableConnectionCountTracking();
    const port = server.socket.address.getPort();
    const first_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/first", .{port});
    defer std.testing.allocator.free(first_url);
    const second_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/second", .{port});
    defer std.testing.allocator.free(second_url);
    const http_client = transport.httpClient();
    var first = try std.testing.io.concurrent(localGet, .{ http_client, first_url });
    defer first.await(std.testing.io) catch {};
    var second = try std.testing.io.concurrent(localGet, .{ http_client, second_url });
    defer second.await(std.testing.io) catch {};
    defer release.store(true, .release);

    try spinUntilAtLeast(&accepted, 2);
    release.store(true, .release);
    try first.await(std.testing.io);
    try second.await(std.testing.io);
    try server_future.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), transport.maxConnectionCount());
}

fn localGet(http_client: HttpClient, url: []const u8) !void {
    const response = try http_client.send(std.heap.page_allocator, .{ .method = .GET, .url = url });
    defer std.heap.page_allocator.free(response.body);
    if (response.status != 200) return error.UnexpectedStatus;
}

fn spinUntilAtLeast(value: *std.atomic.Value(usize), minimum: usize) !void {
    for (0..100_000_000) |_| {
        if (value.load(.acquire) >= minimum) return;
        std.atomic.spinLoopHint();
    }
    return error.TestTimeout;
}

fn serveTwo(server: *std.Io.net.Server, release: *std.atomic.Value(bool), accepted: *std.atomic.Value(usize), io: Io) !void {
    var first = try io.concurrent(serveOne, .{ try server.accept(io), release, accepted, io });
    var second = try io.concurrent(serveOne, .{ try server.accept(io), release, accepted, io });
    try first.await(io);
    try second.await(io);
}

fn serveOne(stream: std.Io.net.Stream, release: *std.atomic.Value(bool), accepted: *std.atomic.Value(usize), io: Io) !void {
    defer stream.close(io);
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (std.mem.eql(u8, line, "\r\n")) break;
    }
    _ = accepted.fetchAdd(1, .release);
    while (!release.load(.acquire)) std.atomic.spinLoopHint();
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    try writer.interface.flush();
}
