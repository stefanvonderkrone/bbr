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
            writeSubmitResponse(self.inner.io, .cwd(), req.method, req.url, status, response_body) catch {};

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
};

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

fn writeSubmitResponse(io: Io, dir: Io.Dir, method: client.Method, url: []const u8, status: u16, body: []const u8) !void {
    var file = try dir.createFile(io, "bbr-submit-response.log", .{ .truncate = false, .lock = .exclusive, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    var offset = try file.length(io);
    try appendLog(file, io, &offset, methodName(method));
    try appendLog(file, io, &offset, " ");
    try appendLog(file, io, &offset, url);
    var status_buffer: [32]u8 = undefined;
    const status_line = try std.fmt.bufPrint(&status_buffer, "\nstatus: {d}\n", .{status});
    try appendLog(file, io, &offset, status_line);
    try appendLog(file, io, &offset, body);
    try appendLog(file, io, &offset, "\n");
}

fn writeSubmitError(io: Io, dir: Io.Dir, method: client.Method, url: []const u8, err: anyerror) !void {
    var file = try dir.createFile(io, "bbr-submit-response.log", .{ .truncate = false, .lock = .exclusive, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    var offset = try file.length(io);
    try appendLog(file, io, &offset, methodName(method));
    try appendLog(file, io, &offset, " ");
    try appendLog(file, io, &offset, url);
    try appendLog(file, io, &offset, "\ntransport error: ");
    try appendLog(file, io, &offset, @errorName(err));
    try appendLog(file, io, &offset, "\n");
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

test "Comment POST response is written to the submit response log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSubmitResponse(std.testing.io, tmp.dir, .POST, "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/1/comments", 201, "{\"id\":42}");
    try writeSubmitResponse(std.testing.io, tmp.dir, .GET, "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/1/comments?page=2", 200, "{\"values\":[]}");
    const logged = try tmp.dir.readFileAlloc(std.testing.io, "bbr-submit-response.log", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(logged);
    try std.testing.expectEqualStrings(
        "POST https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/1/comments\nstatus: 201\n{\"id\":42}\nGET https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/1/comments?page=2\nstatus: 200\n{\"values\":[]}\n",
        logged,
    );
}
