//! The M28 File cache benchmark. It drives the production Presentation
//! through the scenarios S1 to S8 and prints only metadata and numbers.
//! `.scratch/m28-full-review-file-cache-evaluation/SPEC.md` defines the method.

const std = @import("std");
const builtin = @import("builtin");
const bbr = @import("bbr");
const harness = @import("harness.zig");
const presentation = @import("../tui/presentation.zig");
const runtime = @import("../tui/presentation_runtime.zig");
const file_enrichment = @import("../tui/file_enrichment.zig");
const session_mod = @import("../tui/session.zig");
const config = @import("../tui/config.zig");
const keymap = @import("../tui/keymap.zig");
const render = @import("../tui/render.zig");
const code_highlighting = @import("../tui/code_highlighting.zig");

const Allocator = std.mem.Allocator;
const OwnedInput = presentation.OwnedInput;
const OwnedCommand = presentation.OwnedCommand;

const hour_ns: u64 = std.time.ns_per_hour;
const frame_geometry: presentation.FrameGeometry = .{ .cols = 200, .rows = 50 };
const delay_threshold_ms = 300.0;
const sample_floor = 20;
const probe_count = 5;
const replacement_repeats = 3;
const replacement_jumps = 20;

pub const Scenario = enum {
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,

    const Spec = struct {
        /// Passes that can fetch every File.
        files: u8 = 0,
        /// File Jumps. Each can fetch the whole Enrichment Range.
        jumps: u16 = 0,
        /// Session loads. Each also fetches the Enrichment Range of its start.
        loads: u8 = 0,
        search: bool = false,
        first_result: bool = false,
        restart: bool = false,
        steps: *const fn (*Driver, *Recorder) anyerror!void,
    };

    const specs = std.EnumArray(Scenario, Spec).init(.{
        // S1 counts its `to_top` jump. S5 can open the Overlay before its three edits.
        .s1 = .{ .files = 1, .jumps = 1, .steps = sequentialReview },
        .s2 = .{ .jumps = 50, .steps = revisitAfterEviction },
        .s3 = .{ .jumps = 200, .steps = nonSequentialNavigation },
        .s4 = .{ .files = 1, .loads = 1, .search = true, .first_result = true, .steps = firstReviewSearch },
        .s5 = .{ .files = 4, .search = true, .steps = queryEdits },
        .s6 = .{ .files = 2, .jumps = 10, .search = true, .steps = overlayReopen },
        .s7 = .{ .loads = replacement_repeats, .jumps = replacement_repeats * replacement_jumps, .steps = sessionReplacement },
        .s8 = .{ .loads = replacement_repeats, .jumps = replacement_repeats * replacement_jumps, .restart = true, .steps = processRestart },
    });

    fn spec(self: Scenario) Spec {
        return specs.get(self);
    }

    /// An upper bound of the requests. Each File uses at most two `/src/` requests.
    fn requestEstimate(self: Scenario, shape: Shape) usize {
        const s = self.spec();
        return s.loads * shape.session_requests + 2 * (s.files * shape.files + (@as(usize, s.jumps) + s.loads) * shape.range_files);
    }
};

/// What a scenario's request estimate depends on in one PullRequest.
const Shape = struct {
    files: usize,
    range_files: usize,
    session_requests: usize,
};

pub const FetchClass = enum { hit, cold, refetch };

pub const SampleKind = enum {
    file_jump,
    search_first,
    search_complete,

    /// A Review Search first result is a second latency of the same Visible Action.
    fn isAction(self: SampleKind) bool {
        return self != .search_first;
    }
};

pub const Sample = struct {
    kind: SampleKind,
    latency_ns: u64,
    class: FetchClass,
};

pub const Stats = struct {
    samples: usize = 0,
    hits: usize = 0,
    cold_fetches: usize = 0,
    refetches: usize = 0,
    latency_median_ns: u64 = 0,
    latency_p95_ns: u64 = 0,
    added_delay_p95_ns: u64 = 0,
    first_result_ns: u64 = 0,
    complete_result_ns: u64 = 0,
    cache_hit_rate: ?f64 = null,
    low_samples: bool = true,
};

/// Counts and latencies of the Visible Actions in `samples`.
pub fn stats(allocator: Allocator, samples: []const Sample) Allocator.Error!Stats {
    var result: Stats = .{};
    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(allocator);
    var delays: std.ArrayList(u64) = .empty;
    defer delays.deinit(allocator);
    for (samples) |sample| if (sample.kind.isAction()) {
        try latencies.append(allocator, sample.latency_ns);
        switch (sample.class) {
            .hit => result.hits += 1,
            .cold => result.cold_fetches += 1,
            .refetch => {
                result.refetches += 1;
                const baseline = try medianOf(allocator, samples, sample.kind, .hit) orelse 0;
                try delays.append(allocator, sample.latency_ns -| baseline);
            },
        }
    };
    result.samples = latencies.items.len;
    result.latency_median_ns = median(latencies.items);
    result.latency_p95_ns = p95(latencies.items);
    result.added_delay_p95_ns = p95(delays.items);
    result.first_result_ns = try medianOf(allocator, samples, .search_first, null) orelse 0;
    result.complete_result_ns = try medianOf(allocator, samples, .search_complete, null) orelse 0;
    if (result.hits + result.refetches > 0)
        result.cache_hit_rate = @as(f64, @floatFromInt(result.hits)) / @as(f64, @floatFromInt(result.hits + result.refetches));
    result.low_samples = result.refetches < sample_floor;
    return result;
}

fn medianOf(allocator: Allocator, samples: []const Sample, kind: SampleKind, class: ?FetchClass) Allocator.Error!?u64 {
    var values: std.ArrayList(u64) = .empty;
    defer values.deinit(allocator);
    for (samples) |sample| if (sample.kind == kind and (class == null or sample.class == class.?))
        try values.append(allocator, sample.latency_ns);
    if (values.items.len == 0) return null;
    return median(values.items);
}

fn median(values: []u64) u64 {
    if (values.len == 0) return 0;
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn p95(values: []u64) u64 {
    if (values.len == 0) return 0;
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[harness.p95Index(values.len)];
}

pub const Traffic = struct {
    requests: usize = 0,
    src_requests: usize = 0,
    failures: usize = 0,
    rate_limited: usize = 0,
    request_median_ns: u64 = 0,
    request_p95_ns: u64 = 0,
    retries: usize = 0,
    paused_ns: u64 = 0,
};

pub const ScenarioReport = struct {
    scenario: Scenario,
    run_label: []const u8,
    pull_request: u64,
    stats: Stats,
    traffic: Traffic,
    request_estimate: usize,
    peak_retained_bytes: usize,
    retained_bytes: usize,
    full_review_bytes: usize,
    peak_rss_bytes: usize,
    candidate_session_ns: u64 = 0,
    paced_samples: usize = 0,
    enrichments: EnrichmentCounts = .{},

    pub fn write(self: ScenarioReport, out: *std.Io.Writer) !void {
        const s = self.stats;
        const spec = self.scenario.spec();
        try out.print("scenario={s} run_label={s} pull_request={d} samples={d} hits={d} cold_fetches={d} refetches={d}", .{
            @tagName(self.scenario), self.run_label, self.pull_request, s.samples, s.hits, s.cold_fetches, s.refetches,
        });
        try out.print(" latency_median_ms={d:.1} latency_p95_ms={d:.1} added_delay_p95_ms={d:.1}", .{
            ms(s.latency_median_ns), ms(s.latency_p95_ns), ms(s.added_delay_p95_ns),
        });
        if (spec.first_result) try out.print(" first_result_ms={d:.1}", .{ms(s.first_result_ns)});
        if (spec.search) try out.print(" complete_result_ms={d:.1}", .{ms(s.complete_result_ns)});
        const t = self.traffic;
        try out.print(" requests={d} request_estimate={d} src_requests={d} failures={d} rate_limited={d} request_median_ms={d:.1} request_p95_ms={d:.1}", .{
            t.requests, self.request_estimate, t.src_requests, t.failures, t.rate_limited, ms(t.request_median_ns), ms(t.request_p95_ns),
        });
        try out.print(" retries={d} paused_ms={d:.1} paced_samples={d}", .{ t.retries, ms(t.paused_ns), self.paced_samples });
        const e = self.enrichments;
        try out.print(" enrichments={d} enrichment_refetches={d} speculative_enrichments={d}", .{ e.all, e.refetches, e.speculative });
        try out.print(" peak_retained_bytes={d} retained_bytes={d} full_review_bytes={d} peak_rss_bytes={d}", .{
            self.peak_retained_bytes, self.retained_bytes, self.full_review_bytes, self.peak_rss_bytes,
        });
        if (s.cache_hit_rate) |rate| try out.print(" cache_hit_rate={d:.3}", .{rate}) else try out.writeAll(" cache_hit_rate=none");
        try out.print(" low_samples={}", .{s.low_samples});
        if (spec.restart) try out.print(" candidate_session_ms={d:.1}", .{ms(self.candidate_session_ns)});
        try out.writeAll("\n");
        try out.flush();
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// The time seam. `now` is awake time for latencies. `wall` is Unix time for the request window.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (*anyopaque) u64,
        wall: *const fn (*anyopaque) u64,
        sleep: *const fn (*anyopaque, u64) void,
        /// A virtual test clock reads the request state of the client, so it can
        /// advance only while every request sleeps.
        watch: ?*const fn (*anyopaque, ?*MeasuringHttpClient) void = null,
    };

    pub fn now(self: Clock) u64 {
        return self.vtable.now(self.ptr);
    }

    pub fn wall(self: Clock) u64 {
        return self.vtable.wall(self.ptr);
    }

    pub fn sleep(self: Clock, ns: u64) void {
        self.vtable.sleep(self.ptr, ns);
    }

    fn watch(self: Clock, measuring: ?*MeasuringHttpClient) void {
        if (self.vtable.watch) |watch_fn| watch_fn(self.ptr, measuring);
    }
};

pub const IoClock = struct {
    io: std.Io,

    pub fn clock(self: *IoClock) Clock {
        return .{ .ptr = self, .vtable = &.{ .now = now, .wall = wall, .sleep = sleep } };
    }

    fn now(ptr: *anyopaque) u64 {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        return @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds());
    }

    fn wall(ptr: *anyopaque) u64 {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        return @intCast(std.Io.Clock.real.now(self.io).toNanoseconds());
    }

    fn sleep(ptr: *anyopaque, ns: u64) void {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        self.io.sleep(.fromNanoseconds(ns), .awake) catch {};
    }
};

/// The `key=value` lines on stderr. They never hold a URL, a path, a header, a body, or the token.
const Notes = struct {
    writer: *std.Io.Writer,
    mutex: std.atomic.Mutex = .unlocked,

    fn print(self: *Notes, comptime format: []const u8, args: anytype) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.writer.print(format ++ "\n", args) catch {};
        self.writer.flush() catch {};
    }

    /// Notes a wait of `ns` that starts now. `what` is the reason and its details.
    fn wait(self: *Notes, clock: Clock, ns: u64, comptime what: []const u8, args: anytype) void {
        self.print("wait " ++ what ++ " seconds={d:.1} resume={f}", args ++ .{ seconds(ns), Utc{ .ns = clock.wall() +| ns } });
    }
};

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// Formats Unix nanoseconds as `YYYY-MM-DDTHH:MM:SSZ`.
const Utc = struct {
    ns: u64,

    pub fn format(self: Utc, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = self.ns / std.time.ns_per_s };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day = epoch_seconds.getDaySeconds();
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,         month_day.month.numeric(), month_day.day_index + 1,
            day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
        });
    }
};

/// The rolling request window of the last hour. It persists one decimal Unix
/// nanosecond timestamp per line in `requests.log`, so a restart keeps it.
/// Lines go to the page cache without a sync. A process kill keeps them, but
/// a power loss can lose the last lines.
pub const RequestWindow = struct {
    io: std.Io,
    clock: Clock,
    notes: *Notes,
    hourly: usize,
    file: std.Io.File,
    offset: u64,
    entries: std.ArrayList(u64) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    const file_name = "requests.log";

    /// Reads the log, keeps the entries of the last hour, and rewrites the log atomically.
    fn open(io: std.Io, dir: std.Io.Dir, clock: Clock, notes: *Notes, hourly: usize) !RequestWindow {
        const allocator = std.heap.page_allocator;
        const text = dir.readFileAlloc(io, file_name, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try allocator.alloc(u8, 0),
            else => return err,
        };
        defer allocator.free(text);
        var entries: std.ArrayList(u64) = .empty;
        errdefer entries.deinit(allocator);
        var kept: std.ArrayList(u8) = .empty;
        defer kept.deinit(allocator);
        const wall_now = clock.wall();
        // The text after the last newline is a partial line.
        const complete = text[0..if (std.mem.lastIndexOfScalar(u8, text, '\n')) |end| end + 1 else 0];
        var lines = std.mem.tokenizeScalar(u8, complete, '\n');
        // An entry in the future stays. Then a wall clock that goes back keeps the window conservative.
        while (lines.next()) |line| {
            const at = std.fmt.parseInt(u64, line, 10) catch continue;
            if (at +| hour_ns <= wall_now) continue;
            try entries.append(allocator, at);
            try kept.print(allocator, "{d}\n", .{at});
        }
        var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writePositionalAll(io, kept.items, 0);
        try atomic.file.sync(io);
        try atomic.replace(io);
        return .{
            .io = io,
            .clock = clock,
            .notes = notes,
            .hourly = hourly,
            .file = try dir.openFile(io, file_name, .{ .mode = .write_only }),
            .offset = kept.items.len,
            .entries = entries,
        };
    }

    fn deinit(self: *RequestWindow) void {
        self.file.close(self.io);
        self.entries.deinit(std.heap.page_allocator);
    }

    /// The wall time when `need` more requests fit, or null when they fit now.
    fn deadline(self: *RequestWindow, need: usize) ?u64 {
        const wall_now = self.clock.wall();
        var kept: usize = 0;
        for (self.entries.items) |at| if (at +| hour_ns > wall_now) {
            self.entries.items[kept] = at;
            kept += 1;
        };
        self.entries.shrinkRetainingCapacity(kept);
        const sorted = self.entries.items;
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
        if (sorted.len + need <= self.hourly) return null;
        std.debug.assert(need <= self.hourly);
        return sorted[sorted.len + need - self.hourly - 1] +| hour_ns;
    }

    fn append(self: *RequestWindow, at: u64) !void {
        var buffer: [24]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "{d}\n", .{at}) catch unreachable;
        try self.entries.append(std.heap.page_allocator, at);
        try self.file.writePositionalAll(self.io, line, self.offset);
        self.offset += line.len;
    }

    /// Records one request now and returns null, or returns the deadline and records nothing.
    /// One check and one record under one lock, so threads never overshoot the budget.
    fn tryAcquire(self: *RequestWindow) !?u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (self.deadline(1)) |until| return until;
        try self.append(self.clock.wall());
        return null;
    }

    /// A 429 response means the server counts more requests than the window. The marks fill it.
    fn fill(self: *RequestWindow) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        _ = self.deadline(0);
        const wall_now = self.clock.wall();
        while (self.entries.items.len < self.hourly) try self.append(wall_now);
    }

    /// Waits until `estimate` requests fit. The harness calls it only between scenarios.
    fn reserve(self: *RequestWindow, scenario: Scenario, estimate: usize) void {
        while (true) {
            const until = blk: {
                lock(&self.mutex);
                defer self.mutex.unlock();
                break :blk self.deadline(estimate) orelse return;
            };
            const ns = @max(until -| self.clock.wall(), 1);
            self.notes.wait(self.clock, ns, "reason=scenario scenario={s}", .{@tagName(scenario)});
            self.clock.sleep(ns);
        }
    }
};

pub const RetryPolicy = struct {
    base_ns: u64 = 2 * std.time.ns_per_s,
    factor: u64 = 2,
    cap_ns: u64 = 15 * std.time.ns_per_min,
    max_attempts: usize = 8,

    /// The full jitter range of the retry after failed attempt `attempt`, 1-based.
    fn ceiling(self: RetryPolicy, attempt: usize) u64 {
        var value = self.base_ns;
        for (1..attempt) |_| value *|= self.factor;
        return @min(value, self.cap_ns);
    }
};

/// Wraps an `HttpClient`, gates each request on the request window, retries a
/// failed GET, and counts its traffic. It never stores a URL, a header, or a
/// body. File Enrichments send from many threads at once.
pub const MeasuringHttpClient = struct {
    inner: bbr.http.HttpClient,
    clock: Clock,
    window: *RequestWindow,
    notes: *Notes,
    random: std.Random,
    policy: RetryPolicy = .{},
    gave_up: bool = false,
    traffic: Traffic = .{},
    latencies: std.ArrayList(u64) = .empty,
    out_of_memory: bool = false,
    in_flight: usize = 0,
    sleeping: usize = 0,
    stalled_since: u64 = 0,
    excluded_ns: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    const Mark = struct { traffic: Traffic, latency_count: usize, excluded_ns: u64 };
    const Counter = enum { in_flight, sleeping };

    pub fn deinit(self: *MeasuringHttpClient) void {
        self.latencies.deinit(std.heap.page_allocator);
    }

    pub fn httpClient(self: *MeasuringHttpClient) bbr.http.HttpClient {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, allocator: Allocator, request: bbr.http.client.Request) anyerror!bbr.http.client.Response {
        const self: *MeasuringHttpClient = @ptrCast(@alignCast(ptr));
        self.change(.in_flight, true);
        defer self.change(.in_flight, false);
        var attempt: usize = 0;
        while (true) {
            if (self.gaveUp()) return error.RetriesExhausted;
            attempt += 1;
            while (try self.window.tryAcquire()) |until| {
                const ns = @max(until -| self.clock.wall(), 1);
                self.notes.wait(self.clock, ns, "reason=window", .{});
                self.pause(ns);
            }
            const start = self.clock.now();
            const result = self.inner.send(allocator, request);
            const elapsed = self.clock.now() -| start;
            const retryable = request.method == .GET and if (result) |response|
                response.status == 429 or (response.status >= 500 and response.status <= 599)
            else |err|
                err != error.OutOfMemory and err != error.Canceled;
            const give_up = retryable and attempt >= self.policy.max_attempts;
            self.count(request, result, elapsed, retryable, give_up);
            if (!retryable) return result;
            var retry_after_ns: u64 = 0;
            if (result) |response| {
                allocator.free(response.body);
                retry_after_ns = (response.retry_after_ms orelse 0) *| std.time.ns_per_ms;
                if (response.status == 429) try self.window.fill();
            } else |_| {}
            if (give_up) {
                if (result) |response|
                    self.notes.print("give_up attempts={d} status={d}", .{ attempt, response.status })
                else |err|
                    self.notes.print("give_up attempts={d} error={s}", .{ attempt, @errorName(err) });
                return error.RetriesExhausted;
            }
            const ns = @max(self.jitter(attempt), retry_after_ns);
            if (result) |response|
                self.notes.wait(self.clock, ns, "reason=retry status={d} attempt={d}", .{ response.status, attempt })
            else |err|
                self.notes.wait(self.clock, ns, "reason=retry error={s} attempt={d}", .{ @errorName(err), attempt });
            self.pause(ns);
        }
    }

    /// Counts one attempt. `requests` counts attempts like the window, and `failures` counts final failures.
    fn count(self: *MeasuringHttpClient, request: bbr.http.client.Request, result: anyerror!bbr.http.client.Response, elapsed: u64, retryable: bool, give_up: bool) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.traffic.requests += 1;
        if (std.mem.indexOf(u8, request.url, "/src/") != null) self.traffic.src_requests += 1;
        if (result) |response| {
            if (response.status == 429) self.traffic.rate_limited += 1;
        } else |_| {}
        if (retryable) {
            self.traffic.retries += 1;
            if (give_up) {
                self.gave_up = true;
                self.traffic.failures += 1;
            }
        } else if (result) |response| {
            // A 404 is a missing side, which the merged PullRequest check counts.
            if (response.status >= 400 and response.status != 404) self.traffic.failures += 1;
        } else |_| self.traffic.failures += 1;
        self.latencies.append(std.heap.page_allocator, elapsed) catch {
            self.out_of_memory = true;
        };
    }

    /// Full jitter is a uniform wait up to the ceiling of the retry.
    fn jitter(self: *MeasuringHttpClient, attempt: usize) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.random.uintAtMost(u64, self.policy.ceiling(attempt));
    }

    /// True after one request used every attempt. Later requests then fail without a send.
    fn gaveUp(self: *MeasuringHttpClient) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.gave_up;
    }

    fn pause(self: *MeasuringHttpClient, ns: u64) void {
        self.change(.sleeping, true);
        defer self.change(.sleeping, false);
        self.clock.sleep(ns);
    }

    /// Every request in flight sleeps, so the reviewer waits only for the harness.
    /// A backoff of one request while others progress does not block the reviewer.
    fn stalled(self: *const MeasuringHttpClient) bool {
        return self.in_flight > 0 and self.sleeping == self.in_flight;
    }

    fn change(self: *MeasuringHttpClient, counter: Counter, up: bool) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const was = self.stalled();
        const value = switch (counter) {
            .in_flight => &self.in_flight,
            .sleeping => &self.sleeping,
        };
        if (up) value.* += 1 else value.* -= 1;
        const is = self.stalled();
        if (!was and is) self.stalled_since = self.clock.now();
        if (was and !is) self.excluded_ns += self.clock.now() -| self.stalled_since;
    }

    /// The stalled time so far. CPU work that overlaps a stall is also excluded.
    fn excludedNs(self: *MeasuringHttpClient) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.excludedLocked();
    }

    fn excludedLocked(self: *MeasuringHttpClient) u64 {
        if (!self.stalled()) return self.excluded_ns;
        return self.excluded_ns + (self.clock.now() -| self.stalled_since);
    }

    fn mark(self: *MeasuringHttpClient) Mark {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return .{ .traffic = self.traffic, .latency_count = self.latencies.items.len, .excluded_ns = self.excludedLocked() };
    }

    fn since(self: *MeasuringHttpClient, allocator: Allocator, start: Mark) !Traffic {
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (self.out_of_memory) return error.OutOfMemory;
        const latencies = try allocator.dupe(u64, self.latencies.items[start.latency_count..]);
        defer allocator.free(latencies);
        return .{
            .requests = self.traffic.requests - start.traffic.requests,
            .src_requests = self.traffic.src_requests - start.traffic.src_requests,
            .failures = self.traffic.failures - start.traffic.failures,
            .rate_limited = self.traffic.rate_limited - start.traffic.rate_limited,
            .retries = self.traffic.retries - start.traffic.retries,
            .request_median_ns = median(latencies),
            .request_p95_ns = p95(latencies),
            .paused_ns = self.excludedLocked() - start.excluded_ns,
        };
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Opens and closes the network client. S8 closes it and opens a new one.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (*anyopaque) anyerror!bbr.http.HttpClient,
        close: *const fn (*anyopaque) void,
    };

    fn open(self: Transport) !bbr.http.HttpClient {
        return self.vtable.open(self.ptr);
    }

    fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

/// Ends an attempt with `error.Timeout` after `timeout`. `StdHttpClient` has no request timeout,
/// so a server that never answers would stall the run forever.
const TimedHttpClient = struct {
    io: std.Io,
    inner: bbr.http.HttpClient,
    // A slow download of a large File must not time out.
    timeout: std.Io.Duration = .fromSeconds(120),

    const Race = union(enum) {
        response: anyerror!bbr.http.client.Response,
        timer: std.Io.Cancelable!void,
    };

    fn httpClient(self: *TimedHttpClient) bbr.http.HttpClient {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, allocator: Allocator, request: bbr.http.client.Request) anyerror!bbr.http.client.Response {
        const self: *TimedHttpClient = @ptrCast(@alignCast(ptr));
        var buffer: [2]Race = undefined;
        var select: std.Io.Select(Race) = .init(self.io, &buffer);
        // The cancel interrupts the blocked read. A response that completes after the timer is freed here.
        defer while (select.cancel()) |late| switch (late) {
            .response => |result| if (result) |response| allocator.free(response.body) else |_| {},
            .timer => {},
        };
        try select.concurrent(.response, sendInner, .{ self.inner, allocator, request });
        try select.concurrent(.timer, std.Io.sleep, .{ self.io, self.timeout, .awake });
        return switch (try select.await()) {
            .response => |result| result,
            .timer => |result| {
                try result;
                return error.Timeout;
            },
        };
    }

    fn sendInner(inner: bbr.http.HttpClient, allocator: Allocator, request: bbr.http.client.Request) anyerror!bbr.http.client.Response {
        return inner.vtable.send(inner.ptr, allocator, request);
    }
};

const StdTransport = struct {
    io: std.Io,
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
    client: ?bbr.http.StdHttpClient = null,
    timed: TimedHttpClient = undefined,

    fn transport(self: *StdTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .open = open, .close = close } };
    }

    fn open(ptr: *anyopaque) anyerror!bbr.http.HttpClient {
        const self: *StdTransport = @ptrCast(@alignCast(ptr));
        self.client = bbr.http.StdHttpClient.init(std.heap.page_allocator, self.io);
        errdefer close(ptr);
        try self.client.?.initDefaultProxies(self.arena, self.environ_map);
        self.timed = .{ .io = self.io, .inner = self.client.?.httpClient() };
        return self.timed.httpClient();
    }

    fn close(ptr: *anyopaque) void {
        const self: *StdTransport = @ptrCast(@alignCast(ptr));
        if (self.client) |*client| client.deinit();
        self.client = null;
    }
};

pub const Options = struct {
    cache_max_bytes: usize = config.Configuration.default_inactive_file_cache_max_bytes,
    dwell_ms: u64 = 1000,
    seed: u64 = 28,
    query: []const u8 = "return",
    second_query: []const u8 = "const",
    hourly_request_budget: usize = 900,
    run_label: []const u8 = "",
    network_label: []const u8 = "",
    output_dir: []const u8 = "",
    scenarios: std.EnumSet(Scenario) = .initFull(),

    const Flag = enum {
        @"--cache-max-bytes",
        @"--dwell-ms",
        @"--seed",
        @"--query",
        @"--second-query",
        @"--hourly-request-budget",
        @"--run-label",
        @"--network-label",
        @"--output-dir",
        @"--scenarios",
    };

    pub fn parse(args: []const []const u8) error{InvalidArguments}!Options {
        var options: Options = .{};
        var index: usize = 0;
        while (index < args.len) : (index += 2) {
            if (index + 1 == args.len) return error.InvalidArguments;
            const value = args[index + 1];
            switch (std.meta.stringToEnum(Flag, args[index]) orelse return error.InvalidArguments) {
                .@"--cache-max-bytes" => options.cache_max_bytes = try number(usize, value),
                .@"--dwell-ms" => options.dwell_ms = try number(u64, value),
                .@"--seed" => options.seed = try number(u64, value),
                .@"--query" => options.query = try queryText(value),
                .@"--second-query" => options.second_query = try queryText(value),
                .@"--hourly-request-budget" => options.hourly_request_budget = try number(usize, value),
                .@"--run-label" => options.run_label = try label(value),
                .@"--network-label" => options.network_label = try label(value),
                .@"--output-dir" => options.output_dir = value,
                .@"--scenarios" => {
                    options.scenarios = .initEmpty();
                    var ids = std.mem.splitScalar(u8, value, ',');
                    while (ids.next()) |id| options.scenarios.insert(std.meta.stringToEnum(Scenario, id) orelse return error.InvalidArguments);
                },
            }
        }
        if (options.hourly_request_budget == 0 or options.run_label.len == 0 or options.output_dir.len == 0) return error.InvalidArguments;
        // The run label names the checkpoint file in the output directory.
        if (std.mem.indexOfAny(u8, options.run_label, "/\\") != null) return error.InvalidArguments;
        try requireDependencies(options.scenarios);
        return options;
    }

    /// S2 revisits the Files that S1 focused. S7 and S8 revisit the Files that S1 or S4 admitted.
    fn requireDependencies(scenarios: std.EnumSet(Scenario)) error{InvalidArguments}!void {
        if (scenarios.contains(.s2) and !scenarios.contains(.s1)) return error.InvalidArguments;
        const admits = scenarios.contains(.s1) or scenarios.contains(.s4);
        if ((scenarios.contains(.s7) or scenarios.contains(.s8)) and !admits) return error.InvalidArguments;
    }

    fn number(comptime T: type, value: []const u8) error{InvalidArguments}!T {
        return std.fmt.parseInt(T, value, 10) catch error.InvalidArguments;
    }

    fn queryText(value: []const u8) error{InvalidArguments}![]const u8 {
        if (value.len == 0 or value.len > 64 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidArguments;
        return value;
    }

    /// A label is printed as one `key=value` token.
    fn label(value: []const u8) error{InvalidArguments}![]const u8 {
        for (value) |byte| if (byte <= ' ' or byte == '=' or byte == 0x7f) return error.InvalidArguments;
        return value;
    }
};

pub const Environment = struct {
    gpa: Allocator,
    io: std.Io,
    clock: Clock,
    transport: Transport,
    credential: bbr.bitbucket.Credential,
    highlighter: bbr.highlight.Highlighter,
    bbr_version: []const u8,
    out: *std.Io.Writer,
    notes: *std.Io.Writer,
    random: std.Random,
};

pub fn main(init: std.process.Init, highlighter: bbr.highlight.Highlighter, bbr_version: []const u8) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &stdout.interface;
    var notes_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &notes_buffer);

    if (std.mem.eql(u8, args[1], "summarize")) {
        if (args.len < 3) return usage();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(init.gpa);
        for (args[2..]) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024));
            defer init.gpa.free(bytes);
            try text.appendSlice(init.gpa, bytes);
            try text.append(init.gpa, '\n');
        }
        summarize(init.gpa, text.items, out) catch |err| switch (err) {
            error.InvalidRunCount => {
                std.debug.print("summarize needs the lines of two or three runs\n", .{});
                return err;
            },
            else => return err,
        };
        return out.flush();
    }

    if (!std.mem.eql(u8, args[1], "remote") or args.len < 4) return usage();
    const repository = args[2];
    const pull_request_id = std.fmt.parseInt(u64, args[3], 10) catch return usage();
    const rest: []const []const u8 = @ptrCast(args[4..]);
    const options = Options.parse(rest) catch return usage();
    var owned = bbr.bitbucket.auth.resolve(arena, init.io, init.environ_map, null) catch return error.MissingCredential;
    defer owned.deinit(arena);
    var transport: StdTransport = .{ .io = init.io, .arena = arena, .environ_map = init.environ_map };
    var clock: IoClock = .{ .io = init.io };
    var prng: std.Random.DefaultPrng = .init(clock.clock().wall());
    try run(.{
        .gpa = init.gpa,
        .io = init.io,
        .clock = clock.clock(),
        .transport = transport.transport(),
        .credential = owned.credential(),
        .highlighter = highlighter,
        .bbr_version = bbr_version,
        .out = out,
        .notes = &stderr.interface,
        .random = prng.random(),
    }, options, repository, pull_request_id);
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: zig build bench-file-cache -- remote <repository> <pull-request-id> [options]\n" ++
            "       zig build bench-file-cache -- summarize <file>...\n" ++
            "options:\n" ++
            "  --cache-max-bytes N        inactive File cache budget, 0 is unlimited (default 268435456)\n" ++
            "  --dwell-ms N               wait after each File Jump (default 1000)\n" ++
            "  --seed N                   seed of the random File Jumps (default 28)\n" ++
            "  --query TEXT               Review Search query (default return)\n" ++
            "  --second-query TEXT        replacement query in S5 (default const)\n" ++
            "  --hourly-request-budget N  requests in one hour (default 900)\n" ++
            "  --run-label LABEL          run label in every line (required)\n" ++
            "  --output-dir DIR           directory of the run files (required)\n" ++
            "  --network-label LABEL      network label in the header\n" ++
            "  --scenarios s1,...,s8      scenario subset (default all)\n" ++
            "                             s2 needs s1. s7 and s8 need s1 or s4.\n",
        .{},
    );
    return error.InvalidArguments;
}

/// Runs the scenario chain for one PullRequest and prints the header, one line
/// for each scenario, and the merged PullRequest check. A rerun with the same
/// options resumes at the first unfinished segment.
pub fn run(env: Environment, options: Options, repository: []const u8, pull_request_id: u64) !void {
    var notes: Notes = .{ .writer = env.notes };
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(env.io, options.output_dir);
    const dir = try cwd.openDir(env.io, options.output_dir, .{});
    defer dir.close(env.io);
    const lock_file = dir.createFile(env.io, "lock", .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch |err| switch (err) {
        error.WouldBlock => {
            notes.print("another harness uses this output directory", .{});
            return error.RunInProgress;
        },
        else => return err,
    };
    defer lock_file.close(env.io);
    var window: RequestWindow = try .open(env.io, dir, env.clock, &notes, options.hourly_request_budget);
    defer window.deinit();
    var measuring: MeasuringHttpClient = .{ .inner = try env.transport.open(), .clock = env.clock, .window = &window, .notes = &notes, .random = env.random };
    defer measuring.deinit();
    defer env.transport.close();
    env.clock.watch(&measuring);
    defer env.clock.watch(null);
    chain(env, options, .{ .measuring = &measuring, .window = &window, .notes = &notes, .dir = dir }, repository, pull_request_id) catch |err| {
        // The bbr Client can turn RetriesExhausted into its own error. The flag keeps the cause.
        if (!measuring.gaveUp()) return err;
        notes.print("checkpoint kept; rerun the same command to resume", .{});
        return error.RetriesExhausted;
    };
}

/// The run resources that `run` owns for the length of the chain.
const RunFiles = struct {
    measuring: *MeasuringHttpClient,
    window: *RequestWindow,
    notes: *Notes,
    dir: std.Io.Dir,
};

/// A resume unit. The selected scenarios among S1 to S6 measure the state that
/// the scenario before them left in memory, so they run as one segment. S7 and
/// S8 each start with a Session replacement and need only the admitted flags.
const segments = [_]std.EnumSet(Scenario){
    .initMany(&.{ .s1, .s2, .s3, .s4, .s5, .s6 }),
    .initOne(.s7),
    .initOne(.s8),
};

fn chain(env: Environment, options: Options, files: RunFiles, repository: []const u8, pull_request_id: u64) !void {
    const gpa = env.gpa;
    const out = env.out;
    var name_buffer: [256]u8 = undefined;
    var checkpoint: Checkpoint = try .load(gpa, env.io, files.dir, try Checkpoint.name(&name_buffer, options, pull_request_id));
    defer checkpoint.deinit(gpa);
    if (checkpoint.progress != null) {
        if (checkpoint.mismatch(env, options)) |key| {
            files.notes.print("checkpoint mismatch key={s}", .{key});
            return error.CheckpointMismatch;
        }
        if (checkpoint.check.items.len > 0) {
            try out.writeAll(checkpoint.header.items);
            try out.writeAll(checkpoint.lines.items);
            try out.writeAll(checkpoint.check.items);
            return out.flush();
        }
    }

    var driver: Driver = undefined;
    try driver.init(env, options, files.measuring, repository, pull_request_id);
    defer driver.deinit();
    if (checkpoint.progress) |progress| {
        try driver.restore(progress, lineValue(checkpoint.header.items, "state") orelse return error.InvalidCheckpoint);
        _ = try driver.start();
        files.notes.print("resume skip={f}", .{ScenarioList{ .set = checkpoint.done }});
    } else {
        const probe_ns = try probe(env, files.measuring, repository, pull_request_id);
        _ = try driver.start();
        try checkpoint.header.print(gpa, "header run_label={s} network_label={s} bbr_version={s} cache_max_bytes={d} pull_request={d} state={s} files={d} range_files={d} session_requests={d} probe_ms={d:.1}", .{
            options.run_label, options.network_label, env.bbr_version, options.cache_max_bytes, pull_request_id, driver.stateText(), driver.file_count, driver.range_files, driver.session_requests, ms(probe_ns),
        });
        try checkpoint.header.print(gpa, " dwell_ms={d} seed={d} query_bytes={d} second_query_bytes={d} hourly_request_budget={d} cols={d} rows={d}\n", .{
            options.dwell_ms, options.seed, options.query.len, options.second_query.len, options.hourly_request_budget, frame_geometry.cols, frame_geometry.rows,
        });
        try checkpoint.write(gpa, env.io, files.dir, &driver);
    }
    try out.writeAll(checkpoint.header.items);
    try out.writeAll(checkpoint.lines.items);
    try out.flush();

    for (segments) |all| {
        const segment = all.intersectWith(options.scenarios);
        if (segment.count() == 0 or checkpoint.done.supersetOf(segment)) continue;
        var lines: std.Io.Writer.Allocating = .init(gpa);
        defer lines.deinit();
        var scenarios = segment.iterator();
        while (scenarios.next()) |scenario| try runScenario(env, options, files, &driver, scenario, pull_request_id, &lines.writer);
        if (files.measuring.gaveUp()) return error.RetriesExhausted;
        try checkpoint.lines.appendSlice(gpa, lines.written());
        checkpoint.done.setUnion(segment);
        try checkpoint.write(gpa, env.io, files.dir, &driver);
        files.notes.print("segment done={f}", .{ScenarioList{ .set = segment }});
        try out.writeAll(lines.written());
        try out.flush();
    }
    try checkpoint.check.print(gpa, "check run_label={s} pull_request={d} state={s} not_found_sides={d} hunk_mismatch_files={d}\n", .{
        options.run_label, pull_request_id, driver.stateText(), driver.not_found_sides, driver.hunk_mismatch_files,
    });
    try checkpoint.write(gpa, env.io, files.dir, &driver);
    try out.writeAll(checkpoint.check.items);
    try out.flush();
}

fn runScenario(env: Environment, options: Options, files: RunFiles, driver: *Driver, scenario: Scenario, pull_request_id: u64, lines: *std.Io.Writer) !void {
    // An estimate above the budget gets no upfront wait. The request gate paces it.
    const estimate = scenario.requestEstimate(.{ .files = driver.file_count, .range_files = driver.range_files, .session_requests = driver.session_requests });
    if (estimate <= options.hourly_request_budget) files.window.reserve(scenario, estimate);
    const start = files.measuring.mark();
    const enrichments_start = driver.enrichments;
    driver.peak_retained = driver.retainedBytes();
    var recorder: Recorder = .{};
    defer recorder.deinit(env.gpa);
    scenario.spec().steps(driver, &recorder) catch |err| {
        if (driver.unsupported) |kind| {
            try env.out.print("error=unsupported_command scenario={s} kind={s}\n", .{ @tagName(scenario), @tagName(kind) });
            try env.out.flush();
        }
        return err;
    };
    const report: ScenarioReport = .{
        .scenario = scenario,
        .run_label = options.run_label,
        .pull_request = pull_request_id,
        .stats = try stats(env.gpa, recorder.samples.items),
        .traffic = try files.measuring.since(env.gpa, start),
        .request_estimate = estimate,
        .peak_retained_bytes = driver.peak_retained,
        .retained_bytes = driver.retainedBytes(),
        .full_review_bytes = driver.fullReviewBytes(),
        .peak_rss_bytes = peakRssBytes(),
        .candidate_session_ns = median(recorder.candidate_session_ns.items),
        .paced_samples = recorder.paced,
        .enrichments = driver.enrichments.since(enrichments_start),
    };
    try report.write(lines);
}

/// Formats a scenario set as ids joined by commas.
const ScenarioList = struct {
    set: std.EnumSet(Scenario),
    separator: []const u8 = ",",

    pub fn format(self: ScenarioList, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var iterator = self.set.iterator();
        var first = true;
        while (iterator.next()) |scenario| {
            if (!first) try writer.writeAll(self.separator);
            first = false;
            try writer.writeAll(@tagName(scenario));
        }
    }
};

/// The value of `key` in one `key=value` line.
fn lineValue(line: []const u8, key: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, line, " \n");
    while (tokens.next()) |token| if (std.mem.startsWith(u8, token, key) and token.len > key.len and token[key.len] == '=')
        return token[key.len + 1 ..];
    return null;
}

/// The result file of one run. It holds the header, the lines of the committed
/// segments, the per-file state after the last committed segment, and the
/// check line when every segment is done.
const Checkpoint = struct {
    file_name: []const u8,
    text: []u8 = &.{},
    header: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(u8) = .empty,
    check: std.ArrayList(u8) = .empty,
    done: std.EnumSet(Scenario) = .initEmpty(),
    /// The progress line of a loaded checkpoint. It points into `text`.
    progress: ?[]const u8 = null,

    /// The settings that a resumed run must share with the stored header.
    const settings = [_][]const u8{ "network_label", "bbr_version", "cache_max_bytes", "dwell_ms", "seed", "query_bytes", "second_query_bytes", "hourly_request_budget", "cols", "rows" };

    /// `<run-label>-<pull-request>-<selection>.txt`, with selection `all` or the scenario ids joined by `-`.
    fn name(buffer: []u8, options: Options, pull_request_id: u64) ![]const u8 {
        const selection: ScenarioList = .{ .set = options.scenarios, .separator = "-" };
        if (options.scenarios.eql(.initFull())) return std.fmt.bufPrint(buffer, "{s}-{d}-all.txt", .{ options.run_label, pull_request_id });
        return std.fmt.bufPrint(buffer, "{s}-{d}-{f}.txt", .{ options.run_label, pull_request_id, selection });
    }

    fn load(gpa: Allocator, io: std.Io, dir: std.Io.Dir, file_name: []const u8) !Checkpoint {
        var result: Checkpoint = .{ .file_name = file_name };
        errdefer result.deinit(gpa);
        result.text = dir.readFileAlloc(io, file_name, gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, result.text, start, '\n')) |end| : (start = end + 1) {
            const line = result.text[start .. end + 1];
            if (std.mem.startsWith(u8, line, "header ")) {
                try result.header.appendSlice(gpa, line);
            } else if (std.mem.startsWith(u8, line, "scenario=")) {
                try result.lines.appendSlice(gpa, line);
            } else if (std.mem.startsWith(u8, line, "check ")) {
                try result.check.appendSlice(gpa, line);
            } else if (std.mem.startsWith(u8, line, "progress ")) {
                result.progress = line;
                var ids = std.mem.tokenizeScalar(u8, lineValue(line, "done") orelse "", ',');
                while (ids.next()) |id| result.done.insert(std.meta.stringToEnum(Scenario, id) orelse return error.InvalidCheckpoint);
            } else return error.InvalidCheckpoint;
        }
        if (result.progress == null or result.header.items.len == 0) return error.InvalidCheckpoint;
        return result;
    }

    fn deinit(self: *Checkpoint, gpa: Allocator) void {
        gpa.free(self.text);
        self.header.deinit(gpa);
        self.lines.deinit(gpa);
        self.check.deinit(gpa);
    }

    /// The first setting whose stored value differs from the current options.
    fn mismatch(self: *const Checkpoint, env: Environment, options: Options) ?[]const u8 {
        var buffer: [512]u8 = undefined;
        const current = std.fmt.bufPrint(&buffer, "network_label={s} bbr_version={s} cache_max_bytes={d} dwell_ms={d} seed={d} query_bytes={d} second_query_bytes={d} hourly_request_budget={d} cols={d} rows={d}", .{
            options.network_label, env.bbr_version, options.cache_max_bytes, options.dwell_ms, options.seed, options.query.len, options.second_query.len, options.hourly_request_budget, frame_geometry.cols, frame_geometry.rows,
        }) catch return "bbr_version";
        for (settings) |key| {
            const stored = lineValue(self.header.items, key) orelse return key;
            if (!std.mem.eql(u8, stored, lineValue(current, key).?)) return key;
        }
        return null;
    }

    /// Rewrites the file atomically, so a crash keeps the last committed segment.
    fn write(self: *const Checkpoint, gpa: Allocator, io: std.Io, dir: std.Io.Dir, driver: *const Driver) !void {
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        const writer = &text.writer;
        try writer.writeAll(self.header.items);
        try writer.writeAll(self.lines.items);
        try driver.writeProgress(writer, self.done);
        try writer.writeAll(self.check.items);
        var atomic = try dir.createFileAtomic(io, self.file_name, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writePositionalAll(io, text.written(), 0);
        try atomic.file.sync(io);
        try atomic.replace(io);
    }
};

fn probe(env: Environment, measuring: *MeasuringHttpClient, repository: []const u8, pull_request_id: u64) !u64 {
    var arena = std.heap.ArenaAllocator.init(env.gpa);
    defer arena.deinit();
    const client = bbr.bitbucket.Client.init(measuring.httpClient(), env.credential);
    var latencies: [probe_count]u64 = undefined;
    for (&latencies) |*latency| {
        const span: Span = .begin(env.clock, measuring);
        _ = try client.getPullRequest(arena.allocator(), repository, pull_request_id);
        latency.* = span.end(env.clock, measuring).latency_ns;
    }
    return median(&latencies);
}

fn peakRssBytes() usize {
    const usage_value = std.posix.getrusage(std.posix.rusage.SELF);
    const max_rss: usize = @intCast(usage_value.maxrss);
    return if (builtin.os.tag == .linux) max_rss * 1024 else max_rss;
}

const Recorder = struct {
    samples: std.ArrayList(Sample) = .empty,
    candidate_session_ns: std.ArrayList(u64) = .empty,
    /// The Visible Actions whose span held a harness wait.
    paced: usize = 0,

    fn deinit(self: *Recorder, allocator: Allocator) void {
        self.samples.deinit(allocator);
        self.candidate_session_ns.deinit(allocator);
    }
};

/// A measured span. Its latency excludes the time when every request waited for the harness.
const Span = struct {
    begin_ns: u64,
    excluded_ns: u64,

    const End = struct { latency_ns: u64, paced: bool };

    fn begin(clock: Clock, measuring: *MeasuringHttpClient) Span {
        return .{ .begin_ns = clock.now(), .excluded_ns = measuring.excludedNs() };
    }

    fn end(self: Span, clock: Clock, measuring: *MeasuringHttpClient) End {
        const excluded = measuring.excludedNs() - self.excluded_ns;
        return .{ .latency_ns = (clock.now() -| self.begin_ns) -| excluded, .paced = excluded > 0 };
    }
};

/// One `enrich_file` command.
const Fetch = struct {
    work_id: presentation.WorkId,
    file_index: usize,
    admitted_before: bool,
};

/// The `enrich_file` commands that the Driver executed, inside or outside a span.
const EnrichmentCounts = struct {
    all: usize = 0,
    refetches: usize = 0,
    speculative: usize = 0,

    fn since(self: EnrichmentCounts, start: EnrichmentCounts) EnrichmentCounts {
        return .{ .all = self.all - start.all, .refetches = self.refetches - start.refetches, .speculative = self.speculative - start.speculative };
    }
};

/// Owns the Presentation, executes its commands on worker threads, and keeps
/// the run measurements. Every field outside `state` survives `refresh` and
/// the simulated restart.
const Driver = struct {
    env: Environment,
    options: Options,
    measuring: *MeasuringHttpClient,
    repository: []const u8,
    pull_request_id: u64,
    store: bbr.review.InMemoryStore,
    state: ?presentation.Presentation = null,
    queue: std.Io.Queue(OwnedInput),
    queue_buffer: []OwnedInput,
    group: std.Io.Group = .init,
    outstanding: usize = 0,
    file_count: usize = 0,
    /// The most Files that the production Enrichment Range holds at the Frame of a start.
    range_files: usize = 0,
    /// The most requests that one Session load of a start sent.
    session_requests: usize = 0,
    admitted: []bool = &.{},
    checked: []bool = &.{},
    largest_result: []usize = &.{},
    focus_tick: []u64 = &.{},
    tick: u64 = 0,
    not_found_sides: usize = 0,
    hunk_mismatch_files: usize = 0,
    /// The fetches that a span can wait for: those in flight at its start, then those it starts.
    span_fetches: std.ArrayList(Fetch) = .empty,
    in_flight: std.ArrayList(Fetch) = .empty,
    /// The Files whose File Enrichment was terminal when the span started.
    ready_at_span: []bool = &.{},
    enrichments: EnrichmentCounts = .{},
    peak_retained: usize = 0,
    unsupported: ?std.meta.Tag(OwnedCommand) = null,
    state_buffer: [32]u8 = undefined,
    state_len: usize = 0,

    fn init(self: *Driver, env: Environment, options: Options, measuring: *MeasuringHttpClient, repository: []const u8, pull_request_id: u64) !void {
        const queue_buffer = try env.gpa.alloc(OwnedInput, 64);
        self.* = .{
            .env = env,
            .options = options,
            .measuring = measuring,
            .repository = repository,
            .pull_request_id = pull_request_id,
            .store = bbr.review.InMemoryStore.init(env.gpa),
            .queue = .init(queue_buffer),
            .queue_buffer = queue_buffer,
        };
    }

    fn deinit(self: *Driver) void {
        self.quiesce();
        self.group.await(self.env.io) catch {};
        if (self.state) |*state| state.deinit();
        self.store.deinit();
        const gpa = self.env.gpa;
        gpa.free(self.queue_buffer);
        gpa.free(self.admitted);
        gpa.free(self.checked);
        gpa.free(self.largest_result);
        gpa.free(self.focus_tick);
        gpa.free(self.ready_at_span);
        self.span_fetches.deinit(gpa);
        self.in_flight.deinit(gpa);
    }

    fn client(self: *Driver) bbr.bitbucket.Client {
        return bbr.bitbucket.Client.init(self.measuring.httpClient(), self.env.credential);
    }

    fn ui(self: *Driver) *presentation.Presentation {
        return &self.state.?;
    }

    fn stateText(self: *const Driver) []const u8 {
        return self.state_buffer[0..self.state_len];
    }

    /// Loads a Candidate Session as the production startup does and returns its time.
    fn start(self: *Driver) !u64 {
        const span: Span = .begin(self.env.clock, self.measuring);
        const requests_before = self.measuring.mark().traffic.requests;
        const loaded = try session_mod.loadWith(self.env.io, std.heap.page_allocator, self.client(), self.repository, self.pull_request_id);
        self.session_requests = @max(self.session_requests, self.measuring.mark().traffic.requests - requests_before);
        self.state = presentation.Presentation.init(self.env.gpa, .{
            .reviews = self.store.store(),
            .highlight_max_file_bytes = config.Configuration.default_highlight_max_file_bytes,
            .file_cache_enabled = true,
            .inactive_file_cache_max_bytes = self.options.cache_max_bytes,
            .cell_metrics = render.terminal_cell_metrics,
        }, .{
            .initial = .{
                .key = try presentation.OwnedReviewIdentity.init(self.env.credential.workspace, self.repository, self.pull_request_id),
                .session = loaded,
            },
            .geometry = frame_geometry,
        }) catch |err| {
            loaded.destroy();
            return err;
        };
        const elapsed = span.end(self.env.clock, self.measuring).latency_ns;
        const files = loaded.diff.files.len;
        if (self.file_count == 0) {
            const gpa = self.env.gpa;
            self.file_count = files;
            self.admitted = try gpa.alloc(bool, files);
            @memset(self.admitted, false);
            self.checked = try gpa.alloc(bool, files);
            @memset(self.checked, false);
            self.largest_result = try gpa.alloc(usize, files);
            @memset(self.largest_result, 0);
            self.focus_tick = try gpa.alloc(u64, files);
            @memset(self.focus_tick, 0);
            self.ready_at_span = try gpa.alloc(bool, files);
            const state_text = if (loaded.remotePullRequestConst()) |pull_request| pull_request.state else "";
            self.state_len = @min(state_text.len, self.state_buffer.len);
            @memcpy(self.state_buffer[0..self.state_len], state_text[0..self.state_len]);
        } else if (files != self.file_count) return error.FileCountChanged;
        try self.pump();
        try self.waitUntil(FocusSettled{});
        self.noteFocus();
        self.range_files = @max(self.range_files, self.widestEnrichmentRange());
        return elapsed;
    }

    /// The most Files that the production Enrichment Range holds at any scroll of this Frame.
    fn widestEnrichmentRange(self: *Driver) usize {
        const published = self.ui().published orelse return 1;
        var copy = published.*;
        var widest: usize = 1;
        for (0..copy.visual_rows.len) |top| {
            copy.navigation.scroll = top;
            const range = presentation.Presentation.enrichmentRange(&copy, null, self.file_count);
            widest = @max(widest, range.focused.end - range.focused.first);
        }
        return widest;
    }

    /// Closes the Presentation and the network client, then starts both again.
    fn restart(self: *Driver) !u64 {
        self.quiesce();
        self.ui().deinit();
        self.state = null;
        self.env.transport.close();
        self.measuring.inner = try self.env.transport.open();
        return self.start();
    }

    fn executor(self: *Driver) runtime.CommandExecutor {
        return .{ .ptr = self, .execute_fn = execute };
    }

    fn sink(self: *Driver) runtime.CompletionSink {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, input: OwnedInput) anyerror!void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        try self.queue.putOne(self.env.io, input);
    }

    /// Runs each command kind through the production function that `app.zig` calls.
    fn execute(ptr: *anyopaque, completion: runtime.CompletionSink, command: *OwnedCommand) anyerror!void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        const io = self.env.io;
        const group = &self.group;
        switch (command.*) {
            .enrich_file => |enrich| {
                if (enrich.source != .remote) return self.unsupportedCommand(command.*);
                try self.span_fetches.ensureUnusedCapacity(self.env.gpa, 1);
                try self.in_flight.ensureUnusedCapacity(self.env.gpa, 1);
                try group.concurrent(io, enrichmentWorker, .{ completion, io, self.client(), self.env.highlighter, enrich });
                const fetch: Fetch = .{ .work_id = enrich.work_id, .file_index = enrich.file_index, .admitted_before = self.admitted[enrich.file_index] };
                self.span_fetches.appendAssumeCapacity(fetch);
                self.in_flight.appendAssumeCapacity(fetch);
                self.enrichments.all += 1;
                self.enrichments.refetches += @intFromBool(fetch.admitted_before);
                self.enrichments.speculative += @intFromBool(enrich.speculative);
            },
            .load_session => |load| {
                if (load.key.kind != .remote) return self.unsupportedCommand(command.*);
                try group.concurrent(io, loadWorker, .{ completion, io, self.client(), load });
            },
            .prepare_session => |job| try group.concurrent(io, prepareWorker, .{ completion, job }),
            .highlight_code => |job| try group.concurrent(io, highlightWorker, .{ completion, self.env.highlighter, job }),
            .scan_buffer_search => |scan| try group.concurrent(io, bufferSearchWorker, .{ completion, scan }),
            .build_buffer_disclosure => |job| try group.concurrent(io, disclosureWorker, .{ completion, job }),
            .scan_review_source => |scan| try group.concurrent(io, reviewSourceWorker, .{ completion, scan }),
            .post_draft,
            .update_comment,
            .delete_comment,
            .change_reviewer_verdict,
            .wait_submission,
            .check_recovery,
            .find_duplicate,
            .list_pull_requests,
            .copy_clipboard,
            .persist_theme,
            .external_edit,
            => return self.unsupportedCommand(command.*),
        }
    }

    fn unsupportedCommand(self: *Driver, command: OwnedCommand) error{UnsupportedCommand} {
        self.unsupported = std.meta.activeTag(command);
        return error.UnsupportedCommand;
    }

    fn drain(self: *Driver) !void {
        while (self.ui().takeCommand()) |value| {
            var command = value;
            self.executor().execute(self.sink(), &command) catch |err| {
                command.deinit();
                return err;
            };
            self.outstanding += 1;
        }
    }

    /// One pass of the `app.zig` event loop after an input. Its end is one Frame.
    fn pump(self: *Driver) !void {
        try self.drain();
        if (self.ui().projection().review != null) {
            try self.ui().dispatch(.ensure_focused_enrichment);
            try self.drain();
        }
        self.peak_retained = @max(self.peak_retained, self.retainedBytes());
    }

    fn send(self: *Driver, input: OwnedInput) !void {
        try self.ui().dispatch(input);
        try self.pump();
    }

    fn accept(self: *Driver, input: OwnedInput) !void {
        self.outstanding -= 1;
        self.observe(input);
        try self.send(input);
        if (self.measuring.gaveUp()) return error.RetriesExhausted;
    }

    fn waitUntil(self: *Driver, condition: anytype) !void {
        while (!condition.done(self)) {
            if (self.outstanding == 0) return error.ScenarioStalled;
            try self.accept(try self.queue.getOne(self.env.io));
        }
    }

    /// Accepts the completions that arrived while the reviewer read the File.
    fn dwell(self: *Driver) !void {
        if (self.options.dwell_ms > 0) self.env.clock.sleep(self.options.dwell_ms * std.time.ns_per_ms);
        var ready: [1]OwnedInput = undefined;
        while (self.outstanding > 0 and try self.queue.get(self.env.io, &ready, 0) == 1) try self.accept(ready[0]);
    }

    /// Accepts every outstanding completion and starts no new work.
    fn quiesce(self: *Driver) void {
        while (self.outstanding > 0) {
            var input = self.queue.getOneUncancelable(self.env.io) catch return;
            self.outstanding -= 1;
            self.observe(input);
            if (self.state) |*state| state.dispatch(input) catch {} else input.deinit();
        }
    }

    fn observe(self: *Driver, input: OwnedInput) void {
        if (input != .file_enrichment_completed) return;
        const completed = input.file_enrichment_completed;
        for (self.in_flight.items, 0..) |fetch, position| if (fetch.work_id == completed.work_id) {
            _ = self.in_flight.swapRemove(position);
            break;
        };
        if (completed.outcome != .completed) return;
        const result = &completed.outcome.completed;
        const index = completed.file_index;
        const view = result.view();
        if (view.old == .content or view.new == .content) self.admitted[index] = true;
        self.largest_result[index] = @max(self.largest_result[index], result.retainedBytes());
        if (self.checked[index] or !resolved(view.old) or !resolved(view.new)) return;
        const state = if (self.state) |*value| value else return;
        const published = state.published orelse return;
        if (published.epoch != completed.session_epoch) return;
        self.checked[index] = true;
        self.not_found_sides += @intFromBool(notFound(view.old)) + @intFromBool(notFound(view.new));
        if (hunkMismatch(published.session.diff.files[index], view)) self.hunk_mismatch_files += 1;
    }

    fn retainedBytes(self: *Driver) usize {
        const state = if (self.state) |*value| value else return 0;
        const published = state.published orelse return 0;
        return published.session.enrichment.retainedBytes();
    }

    fn fullReviewBytes(self: *const Driver) usize {
        var total: usize = 0;
        for (self.largest_result) |bytes| total +|= bytes;
        return total;
    }

    /// The per-file state that a later segment needs. It holds only bits and numbers.
    fn writeProgress(self: *const Driver, writer: *std.Io.Writer, done: std.EnumSet(Scenario)) !void {
        try writer.print("progress done={f} admitted=", .{ScenarioList{ .set = done }});
        for (self.admitted) |bit| try writer.writeByte(if (bit) '1' else '0');
        try writer.writeAll(" checked=");
        for (self.checked) |bit| try writer.writeByte(if (bit) '1' else '0');
        try writer.writeAll(" largest=");
        for (self.largest_result, 0..) |bytes, index| try writer.print("{s}{d}", .{ if (index == 0) "" else ",", bytes });
        try writer.print(" not_found_sides={d} hunk_mismatch_files={d}\n", .{ self.not_found_sides, self.hunk_mismatch_files });
    }

    /// Restores the state of `writeProgress` before `start`. Then `start` fails on another File count.
    fn restore(self: *Driver, progress: []const u8, state_text: []const u8) !void {
        const gpa = self.env.gpa;
        const admitted = lineValue(progress, "admitted") orelse return error.InvalidCheckpoint;
        const checked = lineValue(progress, "checked") orelse return error.InvalidCheckpoint;
        if (admitted.len == 0 or checked.len != admitted.len) return error.InvalidCheckpoint;
        self.file_count = admitted.len;
        self.admitted = try gpa.alloc(bool, admitted.len);
        self.checked = try gpa.alloc(bool, admitted.len);
        self.largest_result = try gpa.alloc(usize, admitted.len);
        self.focus_tick = try gpa.alloc(u64, admitted.len);
        @memset(self.focus_tick, 0);
        self.ready_at_span = try gpa.alloc(bool, admitted.len);
        for (admitted, checked, self.admitted, self.checked) |a, c, *admitted_bit, *checked_bit| {
            if (a != '0' and a != '1' or c != '0' and c != '1') return error.InvalidCheckpoint;
            admitted_bit.* = a == '1';
            checked_bit.* = c == '1';
        }
        var largest = std.mem.splitScalar(u8, lineValue(progress, "largest") orelse return error.InvalidCheckpoint, ',');
        for (self.largest_result) |*bytes| bytes.* = std.fmt.parseInt(usize, largest.next() orelse return error.InvalidCheckpoint, 10) catch return error.InvalidCheckpoint;
        if (largest.next() != null) return error.InvalidCheckpoint;
        self.not_found_sides = std.fmt.parseInt(usize, lineValue(progress, "not_found_sides") orelse return error.InvalidCheckpoint, 10) catch return error.InvalidCheckpoint;
        self.hunk_mismatch_files = std.fmt.parseInt(usize, lineValue(progress, "hunk_mismatch_files") orelse return error.InvalidCheckpoint, 10) catch return error.InvalidCheckpoint;
        self.state_len = @min(state_text.len, self.state_buffer.len);
        @memcpy(self.state_buffer[0..self.state_len], state_text[0..self.state_len]);
    }

    fn activeFile(self: *Driver) ?usize {
        const review = self.ui().projection().review orelse return null;
        const frame = review.frame;
        if (frame.navigation.cursor >= frame.visual_rows.len) return null;
        return frame.buffer.fileIndexForRow(frame.visual_rows[frame.navigation.cursor].buffer_index);
    }

    fn fileShown(self: *Driver, file: usize) bool {
        const published = self.ui().published orelse return false;
        return published.pending_view == null and self.activeFile() == file and published.session.enrichment.isTerminal(file);
    }

    fn noteFocus(self: *Driver) void {
        const file = self.activeFile() orelse return;
        self.tick += 1;
        self.focus_tick[file] = self.tick;
    }

    fn beginSpan(self: *Driver) !Span {
        self.span_fetches.clearRetainingCapacity();
        try self.span_fetches.appendSlice(self.env.gpa, self.in_flight.items);
        const enrichment = &self.ui().published.?.session.enrichment;
        for (self.ready_at_span, 0..) |*ready, index| ready.* = index < enrichment.len() and enrichment.isTerminal(index);
        return .begin(self.env.clock, self.measuring);
    }

    fn endSpan(self: *Driver, span: Span) Span.End {
        return span.end(self.env.clock, self.measuring);
    }

    /// A File that was ready at the span start is a hit, even when the span refetches it later.
    /// Else a refetch wins over a cold fetch. `file` limits the span to one File.
    fn classify(self: *const Driver, file: ?usize) FetchClass {
        if (file) |index| if (self.ready_at_span[index]) return .hit;
        var class: FetchClass = .hit;
        for (self.span_fetches.items) |fetch| if (file == null or fetch.file_index == file.?) {
            if (fetch.admitted_before) return .refetch;
            class = .cold;
        };
        return class;
    }

    fn reviewSearchOpen(self: *Driver) bool {
        return self.ui().projection().review_search != null;
    }

    fn closeReviewSearch(self: *Driver) !void {
        if (self.reviewSearchOpen()) try self.send(.{ .key = .{ .codepoint = keymap.special.escape } });
    }

    fn typeText(self: *Driver, text: []const u8) !void {
        try self.send(.{ .key = .{ .codepoint = text[0], .text = text } });
    }

    /// Opens Review Search with the query. A reopened Overlay keeps its query.
    fn openReviewSearch(self: *Driver) !void {
        try self.send(.{ .action = .open_review_search });
        const projection = self.ui().projection().review_search orelse return error.ReviewSearchUnavailable;
        if (projection.query.len == 0) try self.typeText(self.options.query);
    }

    fn ensureReviewSearch(self: *Driver) !void {
        if (self.reviewSearchOpen()) return;
        try self.openReviewSearch();
        try self.waitUntil(SearchComplete{});
    }

    fn recordSearch(self: *Driver, recorder: *Recorder, span: Span, first_result: bool) !void {
        if (first_result) {
            try self.waitUntil(SearchFirst{});
            try recorder.samples.append(self.env.gpa, .{ .kind = .search_first, .latency_ns = self.endSpan(span).latency_ns, .class = .hit });
        }
        try self.waitUntil(SearchComplete{});
        const class = self.classify(null);
        const ended = self.endSpan(span);
        if (first_result) recorder.samples.items[recorder.samples.items.len - 1].class = class;
        try recorder.samples.append(self.env.gpa, .{ .kind = .search_complete, .latency_ns = ended.latency_ns, .class = class });
        recorder.paced += @intFromBool(ended.paced);
    }

    /// Jumps through the File Finder. A null `recorder` keeps the jump out of the samples.
    fn finderJump(self: *Driver, recorder: ?*Recorder, file: usize) !void {
        try self.closeReviewSearch();
        try self.send(.{ .action = .open_file_finder });
        for (0..file) |_| try self.ui().dispatch(.{ .key = .{ .codepoint = keymap.special.down } });
        const span = try self.beginSpan();
        try self.send(.{ .key = .{ .codepoint = keymap.special.enter } });
        try self.waitUntil(FileShown{ .file = file });
        try self.finishJump(recorder, span, file);
    }

    /// Jumps to a random File of `files`, or of every File when `files` is null.
    /// The target is never the active File, because that jump would be a hit with no work.
    /// One draw per jump keeps the S7 and S8 targets on the same random sequence.
    fn randomJump(self: *Driver, recorder: ?*Recorder, random: std.Random, files: ?[]const usize) !void {
        const count = if (files) |subset| subset.len else self.file_count;
        const active: ?usize = if (self.activeFile()) |file|
            if (files) |subset| std.mem.indexOfScalar(usize, subset, file) else file
        else
            null;
        const choices = count - @intFromBool(active != null);
        if (choices == 0) return;
        var index = random.uintLessThan(usize, choices);
        if (active) |skipped| index += @intFromBool(index >= skipped);
        try self.finderJump(recorder, if (files) |subset| subset[index] else index);
    }

    /// Returns false when `next_file` finds no next File.
    fn nextFileJump(self: *Driver, recorder: *Recorder) !bool {
        const before = self.activeFile();
        const span = try self.beginSpan();
        try self.send(.{ .action = .next_file });
        if (self.ui().published.?.pending_view == null and self.activeFile() == before) return false;
        try self.waitUntil(MovedFrom{ .before = before });
        try self.finishJump(recorder, span, self.activeFile().?);
        return true;
    }

    fn finishJump(self: *Driver, recorder: ?*Recorder, span: Span, file: usize) !void {
        const ended = self.endSpan(span);
        if (recorder) |target| {
            try target.samples.append(self.env.gpa, .{ .kind = .file_jump, .latency_ns = ended.latency_ns, .class = self.classify(file) });
            target.paced += @intFromBool(ended.paced);
        }
        self.noteFocus();
        try self.dwell();
    }

    fn refresh(self: *Driver) !void {
        const epoch = self.ui().projection().review.?.session_epoch;
        try self.send(.{ .action = .refresh });
        try self.waitUntil(Replaced{ .epoch = epoch });
        if (self.ui().projection().replacement_error != null) return error.ReplacementFailed;
        try self.waitUntil(FocusSettled{});
        self.noteFocus();
    }

    fn admittedFiles(self: *const Driver, allocator: Allocator) ![]usize {
        var files: std.ArrayList(usize) = .empty;
        errdefer files.deinit(allocator);
        for (self.admitted, 0..) |admitted, index| if (admitted) try files.append(allocator, index);
        return files.toOwnedSlice(allocator);
    }

    /// Focused Files other than the current one, least recently focused first.
    fn leastRecentlyFocused(self: *Driver, allocator: Allocator, limit: usize) ![]usize {
        const current = self.activeFile();
        var files: std.ArrayList(usize) = .empty;
        errdefer files.deinit(allocator);
        for (self.focus_tick, 0..) |tick, index| if (tick > 0 and index != current) try files.append(allocator, index);
        std.mem.sort(usize, files.items, self.focus_tick, struct {
            fn lessThan(ticks: []const u64, a: usize, b: usize) bool {
                return ticks[a] < ticks[b];
            }
        }.lessThan);
        files.shrinkRetainingCapacity(@min(files.items.len, limit));
        return files.toOwnedSlice(allocator);
    }
};

const FocusSettled = struct {
    fn done(_: FocusSettled, driver: *Driver) bool {
        const file = driver.activeFile() orelse return true;
        return driver.fileShown(file);
    }
};

const FileShown = struct {
    file: usize,

    fn done(self: FileShown, driver: *Driver) bool {
        return driver.fileShown(self.file);
    }
};

const MovedFrom = struct {
    before: ?usize,

    fn done(self: MovedFrom, driver: *Driver) bool {
        const file = driver.activeFile() orelse return false;
        return file != self.before and driver.fileShown(file);
    }
};

const Replaced = struct {
    epoch: presentation.SessionEpoch,

    fn done(self: Replaced, driver: *Driver) bool {
        const projection = driver.ui().projection();
        if (projection.replacement_error != null) return true;
        return !projection.replacing and projection.review != null and projection.review.?.session_epoch != self.epoch;
    }
};

const SearchFirst = struct {
    fn done(_: SearchFirst, driver: *Driver) bool {
        const projection = driver.ui().projection().review_search orelse return false;
        return projection.occurrences.len > 0 or (SearchComplete{}).done(driver);
    }
};

/// The query is not pending, every File is source-scanned, and no Review
/// Search command is queued or running.
const SearchComplete = struct {
    fn done(_: SearchComplete, driver: *Driver) bool {
        const state = driver.ui();
        const published = state.published orelse return false;
        const search = &published.review_search;
        if (!search.open or search.pending or search.query == null) return false;
        for (search.source_scanned orelse return false) |scanned| if (!scanned) return false;
        for (state.commands.items) |command| if (command == .scan_review_source or command == .scan_buffer_search) return false;
        for (state.issued_commands.items) |issued| if (issued.target == .scan_review_source or issued.target == .scan_buffer_search) return false;
        return true;
    }
};

fn sequentialReview(driver: *Driver, recorder: *Recorder) !void {
    try driver.closeReviewSearch();
    try driver.send(.{ .action = .to_top });
    try driver.waitUntil(FocusSettled{});
    driver.noteFocus();
    while (try driver.nextFileJump(recorder)) {}
}

fn revisitAfterEviction(driver: *Driver, recorder: *Recorder) !void {
    const files = try driver.leastRecentlyFocused(driver.env.gpa, 50);
    defer driver.env.gpa.free(files);
    for (files) |file| try driver.finderJump(recorder, file);
}

fn nonSequentialNavigation(driver: *Driver, recorder: *Recorder) !void {
    var prng = std.Random.DefaultPrng.init(driver.options.seed);
    for (0..200) |_| try driver.randomJump(recorder, prng.random(), null);
}

/// The restart discards the content that S1 to S3 left, so rule 3 compares a cold Review Search with the warm S6 reopen.
fn firstReviewSearch(driver: *Driver, recorder: *Recorder) !void {
    _ = try driver.restart();
    const span = try driver.beginSpan();
    try driver.openReviewSearch();
    try driver.recordSearch(recorder, span, true);
}

fn queryEdits(driver: *Driver, recorder: *Recorder) !void {
    try driver.ensureReviewSearch();
    const edits = [_][]const OwnedInput{
        &.{.{ .key = .{ .codepoint = 's', .text = "s" } }},
        &.{.{ .key = .{ .codepoint = keymap.special.backspace } }},
        &.{
            .{ .key = .{ .codepoint = 'k', .mods = .{ .ctrl = true } } },
            .{ .key = .{ .codepoint = driver.options.second_query[0], .text = driver.options.second_query } },
        },
    };
    for (edits) |inputs| {
        const span = try driver.beginSpan();
        for (inputs) |input| try driver.send(input);
        try driver.recordSearch(recorder, span, false);
    }
}

fn overlayReopen(driver: *Driver, recorder: *Recorder) !void {
    try driver.ensureReviewSearch();
    try driver.closeReviewSearch();
    var prng = std.Random.DefaultPrng.init(driver.options.seed);
    for (0..10) |_| try driver.randomJump(null, prng.random(), null);
    const span = try driver.beginSpan();
    try driver.openReviewSearch();
    try driver.recordSearch(recorder, span, false);
}

fn sessionReplacement(driver: *Driver, recorder: *Recorder) !void {
    try driver.closeReviewSearch();
    try replacementJumps(driver, recorder, struct {
        fn replace(d: *Driver, _: *Recorder) !void {
            try d.refresh();
        }
    }.replace);
}

fn processRestart(driver: *Driver, recorder: *Recorder) !void {
    try replacementJumps(driver, recorder, struct {
        fn replace(d: *Driver, r: *Recorder) !void {
            const elapsed = try d.restart();
            try r.candidate_session_ns.append(d.env.gpa, elapsed);
        }
    }.replace);
}

/// S8 repeats the S7 jumps: both draw from the admitted Files with the same seed.
fn replacementJumps(driver: *Driver, recorder: *Recorder, comptime replace: fn (*Driver, *Recorder) anyerror!void) !void {
    const files = try driver.admittedFiles(driver.env.gpa);
    defer driver.env.gpa.free(files);
    var prng = std.Random.DefaultPrng.init(driver.options.seed);
    for (0..replacement_repeats) |_| {
        try replace(driver, recorder);
        if (files.len == 0) continue;
        for (0..replacement_jumps) |_| try driver.randomJump(recorder, prng.random(), files);
    }
}

fn resolved(side: file_enrichment.SideView) bool {
    return side != .fetch_failed or side.fetch_failed == error.NotFound;
}

fn notFound(side: file_enrichment.SideView) bool {
    return side == .fetch_failed and side.fetch_failed == error.NotFound;
}

/// A Hunk mismatch File has a Hunk Line whose text differs from the blob line at its number.
fn hunkMismatch(file: bbr.diff.File, view: file_enrichment.FileView) bool {
    var old: BlobLines = .{ .blob = if (view.old == .content) view.old.content.blob else null };
    var new: BlobLines = .{ .blob = if (view.new == .content) view.new.content.blob else null };
    for (file.hunks) |hunk| for (hunk.lines) |line| {
        if (line.oldNo()) |number| if (!old.matches(number, line.text)) return true;
        if (line.newNo()) |number| if (!new.matches(number, line.text)) return true;
    };
    return false;
}

/// Walks the lines of a blob forward. Hunk Lines arrive in line order.
const BlobLines = struct {
    blob: ?[]const u8,
    offset: usize = 0,
    number: u32 = 1,

    fn matches(self: *BlobLines, number: u32, text: []const u8) bool {
        const blob = self.blob orelse return true;
        if (number < self.number) {
            self.offset = 0;
            self.number = 1;
        }
        while (self.number < number) : (self.number += 1) {
            const end = std.mem.indexOfScalarPos(u8, blob, self.offset, '\n') orelse return false;
            self.offset = end + 1;
        }
        if (self.offset > blob.len) return false;
        const end = std.mem.indexOfScalarPos(u8, blob, self.offset, '\n') orelse blob.len;
        if (self.offset == blob.len and end == blob.len) return false;
        return std.mem.eql(u8, blob[self.offset..end], text);
    }
};

fn enrichmentWorker(
    completion: runtime.CompletionSink,
    io: std.Io,
    client: bbr.bitbucket.Client,
    highlighter: bbr.highlight.Highlighter,
    command: presentation.EnrichFile,
) void {
    const outcome: presentation.FileEnrichmentOutcome = if (file_enrichment.enrichConcurrent(
        io,
        std.heap.page_allocator,
        client,
        highlighter,
        command.request(),
    )) |result| .{ .completed = result } else |err| .{ .failed = if (err == error.OutOfMemory) .out_of_memory else .launch_failed };
    runtime.deliver(completion, .{ .file_enrichment_completed = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .session_epoch = command.session_epoch,
        .file_index = command.file_index,
        .outcome = outcome,
    } });
}

fn loadWorker(completion: runtime.CompletionSink, io: std.Io, client: bbr.bitbucket.Client, command: presentation.LoadSession) void {
    const outcome: presentation.SessionLoadOutcome = if (session_mod.loadWith(
        io,
        std.heap.page_allocator,
        client,
        command.key.repository(),
        command.key.pull_request_id,
    )) |loaded| .{ .loaded = loaded } else |err| .{ .failed = err };
    runtime.deliver(completion, .{ .session_loaded = .{ .command_id = command.command_id, .intent = command.intent, .outcome = outcome } });
}

fn prepareWorker(completion: runtime.CompletionSink, job: *presentation.PrepareSession) void {
    job.build();
    runtime.deliver(completion, .{ .session_prepared = job });
}

fn highlightWorker(completion: runtime.CompletionSink, highlighter: bbr.highlight.Highlighter, job: *code_highlighting.Analyze) void {
    runtime.deliver(completion, .{ .code_highlight_completed = job.execute(highlighter) });
}

fn bufferSearchWorker(completion: runtime.CompletionSink, value: presentation.ScanBufferSearch) void {
    var command = value;
    defer command.deinit();
    runtime.deliver(completion, .{ .buffer_search_scanned = presentation.executeBufferSearchScan(std.heap.page_allocator, &command) });
}

fn disclosureWorker(completion: runtime.CompletionSink, job: *presentation.DisclosureBuild) void {
    job.build();
    runtime.deliver(completion, .{ .buffer_disclosure_built = job });
}

fn reviewSourceWorker(completion: runtime.CompletionSink, value: presentation.ScanReviewSource) void {
    var command = value;
    defer command.deinit();
    runtime.deliver(completion, .{ .review_source_scanned = presentation.executeReviewSourceScan(std.heap.page_allocator, &command) });
}

pub const Outcome = enum {
    no_delay,
    delay,
    inconclusive,

    fn text(self: Outcome) []const u8 {
        return switch (self) {
            .no_delay => "No delay",
            .delay => "Delay",
            .inconclusive => "Inconclusive",
        };
    }
};

/// The causes of a delay: one scenario, or the restart Review Search estimate.
const Cause = enum { s1, s2, s3, s4, s5, s6, s7, s8, restart_review_search };

/// Applies the SPEC stop rule to two or three runs.
pub fn decide(delayed: []const bool) error{InvalidRunCount}!Outcome {
    if (delayed.len < 2 or delayed.len > 3) return error.InvalidRunCount;
    var count: usize = 0;
    for (delayed) |value| count += @intFromBool(value);
    if (delayed.len == 2 and count == 1) return .inconclusive;
    return if (count * 2 > delayed.len) .delay else .no_delay;
}

/// The result of one PullRequest in one run.
const RunKey = struct {
    run_label: []const u8,
    pull_request: []const u8,

    fn eql(self: RunKey, other: RunKey) bool {
        return std.mem.eql(u8, self.run_label, other.run_label) and std.mem.eql(u8, self.pull_request, other.pull_request);
    }
};

/// The first reason why a PullRequest result is not complete.
const Gap = union(enum) {
    check,
    missing: Scenario,
    failures: Scenario,
};

const ScenarioLine = struct {
    run_label: []const u8,
    pull_request: []const u8,
    scenario: Scenario,
    refetches: usize,
    failures: ?usize,
    added_delay_p95_ms: f64,
    complete_result_ms: ?f64,

    fn parse(line: []const u8) !?ScenarioLine {
        if (!std.mem.startsWith(u8, line, "scenario=")) return null;
        var parsed: ScenarioLine = .{ .run_label = "", .pull_request = "", .scenario = .s1, .refetches = 0, .failures = null, .added_delay_p95_ms = 0, .complete_result_ms = null };
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| {
            const split = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidLine;
            const key = token[0..split];
            const value = token[split + 1 ..];
            if (std.mem.eql(u8, key, "scenario")) parsed.scenario = std.meta.stringToEnum(Scenario, value) orelse return error.InvalidLine;
            if (std.mem.eql(u8, key, "run_label")) parsed.run_label = value;
            if (std.mem.eql(u8, key, "pull_request")) parsed.pull_request = value;
            if (std.mem.eql(u8, key, "refetches")) parsed.refetches = try std.fmt.parseInt(usize, value, 10);
            if (std.mem.eql(u8, key, "failures")) parsed.failures = try std.fmt.parseInt(usize, value, 10);
            if (std.mem.eql(u8, key, "added_delay_p95_ms")) parsed.added_delay_p95_ms = try std.fmt.parseFloat(f64, value);
            if (std.mem.eql(u8, key, "complete_result_ms")) parsed.complete_result_ms = try std.fmt.parseFloat(f64, value);
        }
        return parsed;
    }
};

/// Reads the checkpoint lines of two or three runs and prints the stop rule outcome.
/// A run that lacks a result for a PullRequest of another run makes the outcome Inconclusive.
pub fn summarize(allocator: Allocator, text: []const u8, out: *std.Io.Writer) !void {
    var lines: std.ArrayList(ScenarioLine) = .empty;
    defer lines.deinit(allocator);
    var checks: std.ArrayList(RunKey) = .empty;
    defer checks.deinit(allocator);
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);
    var pull_requests: std.ArrayList([]const u8) = .empty;
    defer pull_requests.deinit(allocator);
    var rows = std.mem.tokenizeScalar(u8, text, '\n');
    while (rows.next()) |row| {
        const text_line = std.mem.trimEnd(u8, row, "\r");
        const key: RunKey = if (try ScenarioLine.parse(text_line)) |line| key: {
            try lines.append(allocator, line);
            break :key .{ .run_label = line.run_label, .pull_request = line.pull_request };
        } else if (std.mem.startsWith(u8, text_line, "check ")) key: {
            const key: RunKey = .{
                .run_label = lineValue(text_line, "run_label") orelse return error.InvalidLine,
                .pull_request = lineValue(text_line, "pull_request") orelse return error.InvalidLine,
            };
            try checks.append(allocator, key);
            break :key key;
        } else continue;
        try appendNew(allocator, &labels, key.run_label);
        try appendNew(allocator, &pull_requests, key.pull_request);
    }
    if (labels.items.len < 2 or labels.items.len > 3) return error.InvalidRunCount;
    var complete = true;
    for (labels.items) |run_label| for (pull_requests.items) |pull_request| {
        const gap = firstGap(lines.items, checks.items, .{ .run_label = run_label, .pull_request = pull_request }) orelse continue;
        complete = false;
        try out.print("run_label={s} incomplete pull_request={s} ", .{ run_label, pull_request });
        switch (gap) {
            .check => try out.writeAll("missing=check\n"),
            .missing => |scenario| try out.print("missing={t}\n", .{scenario}),
            .failures => |scenario| try out.print("reason=failures scenario={t}\n", .{scenario}),
        }
        break;
    };
    if (!complete) return out.writeAll("outcome=Inconclusive scenarios=none\n");
    const delayed = try allocator.alloc(bool, labels.items.len);
    defer allocator.free(delayed);
    var all_causes: std.EnumSet(Cause) = .initEmpty();
    for (labels.items, delayed) |run_label, *run_delayed| {
        const causes = runCauses(lines.items, run_label);
        run_delayed.* = causes.count() > 0;
        all_causes.setUnion(causes);
        try out.print("run_label={s} delay={} scenarios=", .{ run_label, run_delayed.* });
        try writeCauses(out, causes);
    }
    const outcome = try decide(delayed);
    try out.print("outcome={s} scenarios=", .{outcome.text()});
    try writeCauses(out, all_causes);
}

fn appendNew(allocator: Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    for (values.items) |known| if (std.mem.eql(u8, known, value)) return;
    try values.append(allocator, value);
}

/// A complete result has a check line and one scenario line per scenario, each with `failures=0`.
fn firstGap(lines: []const ScenarioLine, checks: []const RunKey, key: RunKey) ?Gap {
    for (checks) |check| {
        if (check.eql(key)) break;
    } else return .check;
    var seen: std.EnumSet(Scenario) = .initEmpty();
    for (lines) |line| if (key.eql(.{ .run_label = line.run_label, .pull_request = line.pull_request })) {
        if ((line.failures orelse 1) != 0) return .{ .failures = line.scenario };
        seen.insert(line.scenario);
    };
    var missing = seen.complement().iterator();
    return if (missing.next()) |scenario| .{ .missing = scenario } else null;
}

fn runCauses(lines: []const ScenarioLine, run_label: []const u8) std.EnumSet(Cause) {
    var causes: std.EnumSet(Cause) = .initEmpty();
    for (lines) |line| if (std.mem.eql(u8, line.run_label, run_label)) {
        // The S4 sample has no hit baseline. Rule 3 gives its added delay.
        if (line.scenario != .s4 and line.added_delay_p95_ms > delay_threshold_ms) causes.insert(causeOf(line.scenario));
        if ((line.scenario == .s5 or line.scenario == .s6) and line.refetches > 0) causes.insert(causeOf(line.scenario));
        if (line.scenario != .s6 or line.refetches > 0) continue;
        const reopen = line.complete_result_ms orelse continue;
        for (lines) |first| if (first.scenario == .s4 and std.mem.eql(u8, first.run_label, run_label) and std.mem.eql(u8, first.pull_request, line.pull_request)) {
            if ((first.complete_result_ms orelse 0) - reopen > delay_threshold_ms) causes.insert(.restart_review_search);
        };
    };
    return causes;
}

fn causeOf(scenario: Scenario) Cause {
    return @enumFromInt(@intFromEnum(scenario));
}

fn writeCauses(out: *std.Io.Writer, causes: std.EnumSet(Cause)) !void {
    if (causes.count() == 0) try out.writeAll("none");
    var iterator = causes.iterator();
    var first = true;
    while (iterator.next()) |cause| {
        if (!first) try out.writeAll(",");
        first = false;
        try out.writeAll(@tagName(cause));
    }
    try out.writeAll("\n");
}

const testing = std.testing;

/// A virtual clock. Time moves only by `step_ns` on each `now` and by each sleep.
const FakeClock = struct {
    time: std.atomic.Value(u64) = .init(0),
    step_ns: u64 = 0,
    measuring: std.atomic.Value(?*MeasuringHttpClient) = .init(null),
    sleeps: [64]u64 = undefined,
    sleep_count: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    fn clock(self: *FakeClock) Clock {
        return .{ .ptr = self, .vtable = &.{ .now = now, .wall = wall, .sleep = sleep, .watch = watch } };
    }

    fn now(ptr: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.time.fetchAdd(self.step_ns, .monotonic);
    }

    fn wall(ptr: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.time.load(.monotonic);
    }

    fn watch(ptr: *anyopaque, measuring: ?*MeasuringHttpClient) void {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        self.measuring.store(measuring, .release);
    }

    /// A sleep waits until every request in flight sleeps, as if each request took no time.
    /// Else a request in flight would see the jump and count it as latency.
    fn sleep(ptr: *anyopaque, ns: u64) void {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        {
            lock(&self.mutex);
            defer self.mutex.unlock();
            if (self.sleep_count < self.sleeps.len) self.sleeps[self.sleep_count] = ns;
            self.sleep_count += 1;
        }
        const measuring = self.measuring.load(.acquire) orelse {
            _ = self.time.fetchAdd(ns, .monotonic);
            return;
        };
        while (true) {
            lock(&measuring.mutex);
            defer measuring.mutex.unlock();
            if (measuring.in_flight == measuring.sleeping) {
                _ = self.time.fetchAdd(ns, .monotonic);
                return;
            }
        }
    }

    fn recordedSleeps(self: *FakeClock) []const u64 {
        return self.sleeps[0..@min(self.sleep_count, self.sleeps.len)];
    }
};

const FakeTransport = struct {
    client: bbr.http.HttpClient,

    fn transport(self: *FakeTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .open = open, .close = close } };
    }

    fn open(ptr: *anyopaque) anyerror!bbr.http.HttpClient {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        return self.client;
    }

    fn close(_: *anyopaque) void {}
};

/// Wraps the fake. A request that matches `key` takes the next response of `script`.
/// After `healthy_calls` calls, every call fails with `error.ConnectionResetByPeer`.
const FlakyHttpClient = struct {
    fake: *bbr.http.FakeHttpClient,
    key: ?[]const u8 = null,
    script: []const bbr.http.Canned = &.{},
    healthy_calls: ?usize = null,
    calls: usize = 0,
    scripted: usize = 0,
    failed_urls: std.ArrayList([]u8) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    fn deinit(self: *FlakyHttpClient) void {
        for (self.failed_urls.items) |url| testing.allocator.free(url);
        self.failed_urls.deinit(testing.allocator);
    }

    /// The most failed calls of one URL.
    fn mostFailuresOfOneUrl(self: *const FlakyHttpClient) usize {
        var most: usize = 0;
        for (self.failed_urls.items) |url| {
            var count: usize = 0;
            for (self.failed_urls.items) |other| count += @intFromBool(std.mem.eql(u8, url, other));
            most = @max(most, count);
        }
        return most;
    }

    fn httpClient(self: *FlakyHttpClient) bbr.http.HttpClient {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, allocator: Allocator, request: bbr.http.client.Request) anyerror!bbr.http.client.Response {
        const self: *FlakyHttpClient = @ptrCast(@alignCast(ptr));
        const canned = blk: {
            lock(&self.mutex);
            defer self.mutex.unlock();
            self.calls += 1;
            if (self.healthy_calls) |healthy| if (self.calls > healthy) {
                try self.failed_urls.append(testing.allocator, try testing.allocator.dupe(u8, request.url));
                return error.ConnectionResetByPeer;
            };
            const key = self.key orelse break :blk null;
            if (self.scripted == self.script.len or std.mem.indexOf(u8, request.url, key) == null) break :blk null;
            self.scripted += 1;
            break :blk self.script[self.scripted - 1];
        };
        const response = canned orelse return self.fake.httpClient().send(allocator, request);
        return .{ .status = response.status, .body = try allocator.dupe(u8, response.body), .retry_after_ms = response.retry_after_ms };
    }
};

/// A Random that repeats one value. `uintAtMost` returns the bound for `maxInt(u64)` and 0 for 1.
const FixedRandom = struct {
    value: u64,

    fn random(self: *FixedRandom) std.Random {
        return .init(self, fill);
    }

    fn fill(self: *FixedRandom, buffer: []u8) void {
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, self.value));
        for (buffer, 0..) |*byte, index| byte.* = bytes[index % bytes.len];
    }
};

const fixture_pull_request =
    \\{ "id": 7, "title": "TITLESENTINEL", "state": "MERGED",
    \\  "author": { "display_name": "Ada", "uuid": "{ada}" },
    \\  "source": { "branch": { "name": "feature" }, "commit": { "hash": "aaaa" } },
    \\  "destination": { "branch": { "name": "main" }, "commit": { "hash": "bbbb" } },
    \\  "participants": [] }
;

const fixture_comments =
    \\{ "values": [ { "id": 1, "content": { "raw": "CMTSENTINEL qrysentinel" }, "user": { "display_name": "Ada" } } ] }
;

/// Each text File is taller than the 50-row Frame, so the Enrichment Range
/// never holds every File and the budget can evict a File outside it.
const tall = 60;

const modified_hunk = "@@ -1,61 +1,61 @@\n-old SRCSENTINEL\n" ++ "-oldtail\n" ** tall ++ "+qrysentinel new SRCSENTINEL\n" ++ "+newtail\n" ** tall;

const fixture_diff =
    "diff --git a/PATHSENTINEL/a.zig b/PATHSENTINEL/a.zig\n--- a/PATHSENTINEL/a.zig\n+++ b/PATHSENTINEL/a.zig\n" ++
    modified_hunk ++
    "diff --git a/PATHSENTINEL/b.zig b/PATHSENTINEL/b.zig\n--- a/PATHSENTINEL/b.zig\n+++ b/PATHSENTINEL/b.zig\n" ++
    modified_hunk ++
    "diff --git a/PATHSENTINEL/c.zig b/PATHSENTINEL/c.zig\nnew file mode 100644\n--- /dev/null\n+++ b/PATHSENTINEL/c.zig\n" ++
    "@@ -0,0 +1,61 @@\n+qrysentinel added SRCSENTINEL\n" ++ "+tail\n" ** tall ++
    "diff --git a/PATHSENTINEL/d.zig b/PATHSENTINEL/d.zig\ndeleted file mode 100644\n--- a/PATHSENTINEL/d.zig\n+++ /dev/null\n" ++
    "@@ -1,61 +0,0 @@\n-qrysentinel removed SRCSENTINEL\n" ++ "-tail\n" ** tall ++
    "diff --git a/PATHSENTINEL/e.png b/PATHSENTINEL/e.png\nindex 1111111..2222222 100644\n" ++
    "Binary files a/PATHSENTINEL/e.png and b/PATHSENTINEL/e.png differ\n" ++
    "diff --git a/PATHSENTINEL/f.zig b/PATHSENTINEL/f.zig\n--- a/PATHSENTINEL/f.zig\n+++ b/PATHSENTINEL/f.zig\n" ++
    modified_hunk;

const old_blob = "old SRCSENTINEL\n" ++ "oldtail\n" ** tall;
const new_blob = "qrysentinel new SRCSENTINEL\n" ++ "newtail\n" ** tall;
const added_blob = "qrysentinel added SRCSENTINEL\n" ++ "tail\n" ** tall;
const removed_blob = "qrysentinel removed SRCSENTINEL\n" ++ "tail\n" ** tall;

fn fixtureResponses(comptime blob_b_new: bbr.http.Canned) [12]bbr.http.Canned {
    return .{
        .{ .request_key = "/src/bbbb/PATHSENTINEL/a.zig", .body = old_blob },
        .{ .request_key = "/src/aaaa/PATHSENTINEL/a.zig", .body = new_blob },
        .{ .request_key = "/src/bbbb/PATHSENTINEL/b.zig", .body = old_blob },
        blob_b_new,
        .{ .request_key = "/src/aaaa/PATHSENTINEL/c.zig", .body = added_blob },
        .{ .request_key = "/src/bbbb/PATHSENTINEL/d.zig", .body = removed_blob },
        .{ .request_key = "/src/bbbb/PATHSENTINEL/f.zig", .body = old_blob },
        .{ .request_key = "/src/aaaa/PATHSENTINEL/f.zig", .body = new_blob },
        .{ .request_key = "/pullrequests/7/diff", .body = fixture_diff },
        .{ .request_key = "/pullrequests/7/comments", .body = fixture_comments },
        .{ .request_key = "/pullrequests/7", .body = fixture_pull_request },
        .{ .request_key = "/user", .body = "{ \"uuid\": \"{ada}\" }" },
    };
}

const matching_b: bbr.http.Canned = .{ .request_key = "/src/aaaa/PATHSENTINEL/b.zig", .body = new_blob };

/// Many short Files fit the 50-row Frame, so the Enrichment Range holds many Files.
const short_files = 20;

fn shortPath(comptime index: usize) []const u8 {
    return std.fmt.comptimePrint("PATHSENTINEL/s{d:0>2}.zig", .{index});
}

const short_diff = diff: {
    var text: []const u8 = "";
    for (0..short_files) |index| {
        const path = shortPath(index);
        text = text ++ "diff --git a/" ++ path ++ " b/" ++ path ++ "\n--- a/" ++ path ++ "\n+++ b/" ++ path ++
            "\n@@ -1,1 +1,1 @@\n-old SRCSENTINEL\n+qrysentinel new SRCSENTINEL\n";
    }
    break :diff text;
};

/// More Comment pages than the requests of the start Enrichment Range, so the
/// request estimate needs its Session-load term.
const short_comment_pages = 40;

fn commentPageUrl(comptime page: usize) []const u8 {
    return std.fmt.comptimePrint("/commentpage/{d:0>2}", .{page});
}

fn commentPage(comptime page: usize) []const u8 {
    return std.fmt.comptimePrint("{{ \"values\": [], \"next\": \"https://api.bitbucket.org/2.0{s}\" }}", .{commentPageUrl(page)});
}

const short_responses = responses: {
    var responses: [2 * short_files + short_comment_pages + 4]bbr.http.Canned = undefined;
    for (0..short_files) |index| {
        responses[2 * index] = .{ .request_key = "/src/bbbb/" ++ shortPath(index), .body = "old SRCSENTINEL\n" };
        responses[2 * index + 1] = .{ .request_key = "/src/aaaa/" ++ shortPath(index), .body = "qrysentinel new SRCSENTINEL\n" };
    }
    for (1..short_comment_pages) |page|
        responses[2 * short_files + page - 1] = .{ .request_key = commentPageUrl(page), .body = commentPage(page + 1) };
    responses[2 * short_files + short_comment_pages - 1] = .{ .request_key = commentPageUrl(short_comment_pages), .body = fixture_comments };
    responses[2 * short_files + short_comment_pages ..].* = .{
        .{ .request_key = "/pullrequests/7/diff", .body = short_diff },
        .{ .request_key = "/pullrequests/7/comments", .body = commentPage(1) },
        .{ .request_key = "/pullrequests/7", .body = fixture_pull_request },
        .{ .request_key = "/user", .body = "{ \"uuid\": \"{ada}\" }" },
    };
    break :responses responses;
};

const fixture_options: Options = .{ .dwell_ms = 0, .query = "qrysentinel", .second_query = "qrytwo", .run_label = "fixture" };

/// The path of a test directory, relative to the working directory of the test.
fn tmpPath(tmp: *const testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

/// Runs the chain with the run files in `output_dir` and returns the printed output.
fn runIn(transport: *FakeTransport, output_dir: []const u8, options: Options, clock: *FakeClock, notes: *std.Io.Writer) ![]u8 {
    var plain: bbr.highlight.PlainHighlighter = .{};
    var prng: std.Random.DefaultPrng = .init(28);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    var with_dir = options;
    with_dir.output_dir = output_dir;
    try run(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .clock = clock.clock(),
        .transport = transport.transport(),
        .credential = .{ .username = "u", .token = "TOKENSENTINEL", .workspace = "ws" },
        .highlighter = plain.highlighter(),
        .bbr_version = "test",
        .out = &output.writer,
        .notes = notes,
        .random = prng.random(),
    }, with_dir, "repo", 7);
    return output.toOwnedSlice();
}

/// Runs the chain on the fixture in a new output directory and returns the printed output.
fn runFixture(responses: []const bbr.http.Canned, options: Options, clock: *FakeClock) ![]u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    var fake: bbr.http.FakeHttpClient = .{ .responses = responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    return runIn(&transport, path, options, clock, &notes.writer);
}

/// The value of `key` in the line that starts with `prefix`.
fn field(output: []const u8, prefix: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| if (std.mem.startsWith(u8, token, key) and token.len > key.len and token[key.len] == '=')
            return token[key.len + 1 ..];
        return error.MissingKey;
    };
    return error.MissingLine;
}

fn intField(output: []const u8, prefix: []const u8, key: []const u8) !usize {
    return std.fmt.parseInt(usize, try field(output, prefix, key), 10);
}

fn withBudget(options: Options, cache_max_bytes: usize) Options {
    var result = options;
    result.cache_max_bytes = cache_max_bytes;
    return result;
}

test "M28 cache p95 of 1, 19, 20, and 100 samples matches the nearest rank" {
    // Nearest rank: the sample at rank ceil(0.95 * n). Samples are 1 ms to n ms.
    const cases = [_]struct { n: u64, p95_ms: u64 }{ .{ .n = 1, .p95_ms = 1 }, .{ .n = 19, .p95_ms = 19 }, .{ .n = 20, .p95_ms = 19 }, .{ .n = 100, .p95_ms = 95 } };
    for (cases) |case| {
        var samples: std.ArrayList(Sample) = .empty;
        defer samples.deinit(testing.allocator);
        var value = case.n;
        while (value > 0) : (value -= 1) try samples.append(testing.allocator, .{ .kind = .file_jump, .latency_ns = value * std.time.ns_per_ms, .class = .refetch });
        const result = try stats(testing.allocator, samples.items);
        try testing.expectEqual(case.p95_ms * std.time.ns_per_ms, result.latency_p95_ns);
        try testing.expectEqual(case.p95_ms * std.time.ns_per_ms, result.added_delay_p95_ns);
    }
}

fn reportText(samples: []const Sample) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    const report: ScenarioReport = .{
        .scenario = .s2,
        .run_label = "a",
        .pull_request = 1,
        .stats = try stats(testing.allocator, samples),
        .traffic = .{},
        .request_estimate = 0,
        .peak_retained_bytes = 0,
        .retained_bytes = 0,
        .full_review_bytes = 0,
        .peak_rss_bytes = 0,
    };
    try report.write(&output.writer);
    return output.toOwnedSlice();
}

test "M28 cache fewer than 20 refetch samples print low_samples=true" {
    const refetch: Sample = .{ .kind = .file_jump, .latency_ns = std.time.ns_per_ms, .class = .refetch };
    const hit: Sample = .{ .kind = .file_jump, .latency_ns = std.time.ns_per_ms, .class = .hit };
    const nineteen = [_]Sample{refetch} ** 19 ++ [_]Sample{hit} ** 5;
    const low = try reportText(&nineteen);
    defer testing.allocator.free(low);
    try testing.expectEqualStrings("true", try field(low, "scenario=", "low_samples"));
    const twenty = [_]Sample{refetch} ** 20;
    const enough = try reportText(&twenty);
    defer testing.allocator.free(enough);
    try testing.expectEqualStrings("false", try field(enough, "scenario=", "low_samples"));
}

test "M28 cache added delay subtracts the hit median, or is the full latency without a hit" {
    const ms_ns = std.time.ns_per_ms;
    const with_hits = [_]Sample{
        .{ .kind = .file_jump, .latency_ns = 10 * ms_ns, .class = .hit },
        .{ .kind = .file_jump, .latency_ns = 20 * ms_ns, .class = .hit },
        .{ .kind = .file_jump, .latency_ns = 30 * ms_ns, .class = .hit },
        .{ .kind = .file_jump, .latency_ns = 420 * ms_ns, .class = .refetch },
        // A hit of another kind does not change the File Jump baseline.
        .{ .kind = .search_complete, .latency_ns = 400 * ms_ns, .class = .hit },
    };
    const delayed = try reportText(&with_hits);
    defer testing.allocator.free(delayed);
    try testing.expectEqualStrings("400.0", try field(delayed, "scenario=", "added_delay_p95_ms"));
    const without_hits = [_]Sample{.{ .kind = .file_jump, .latency_ns = 250 * ms_ns, .class = .refetch }};
    const full = try reportText(&without_hits);
    defer testing.allocator.free(full);
    try testing.expectEqualStrings("250.0", try field(full, "scenario=", "added_delay_p95_ms"));
}

test "M28 cache hit rate excludes cold fetches" {
    const samples = [_]Sample{.{ .kind = .file_jump, .latency_ns = 1, .class = .hit }} ** 3 ++
        [_]Sample{.{ .kind = .file_jump, .latency_ns = 1, .class = .cold }} ** 5 ++
        [_]Sample{.{ .kind = .file_jump, .latency_ns = 1, .class = .refetch }};
    const text = try reportText(&samples);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("0.750", try field(text, "scenario=", "cache_hit_rate"));
    try testing.expectEqual(@as(usize, 5), try intField(text, "scenario=", "cold_fetches"));
}

test "M28 cache every scenario runs to the end with text, binary, added, and removed Files" {
    const responses = fixtureResponses(matching_b);
    var clock: FakeClock = .{};
    const output = try runFixture(&responses, withBudget(fixture_options, 1), &clock);
    defer testing.allocator.free(output);
    for (std.enums.values(Scenario)) |scenario| {
        var prefix_buffer: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "scenario={s} ", .{@tagName(scenario)});
        try testing.expect(try intField(output, prefix, "samples") > 0);
        try testing.expectEqual(@as(usize, 0), try intField(output, prefix, "failures"));
    }
    try testing.expectEqualStrings("6", try field(output, "header", "files"));
    try testing.expectEqualStrings("MERGED", try field(output, "header", "state"));
    // The Frame size sets the Enrichment Range, so the header names it.
    try testing.expectEqualStrings("200", try field(output, "header", "cols"));
    try testing.expectEqualStrings("50", try field(output, "header", "rows"));
    // The first fetch of a File is cold.
    try testing.expect(try intField(output, "scenario=s1 ", "cold_fetches") > 0);
    // S2 revisits the Files that S1 left, and the budget evicted them. The overscan refetches the
    // next revisited File inside the span of the jump before it, so only some samples are refetches.
    try testing.expect(try intField(output, "scenario=s2 ", "refetches") > 0);
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s2 ", "cold_fetches"));
    // A refetch outside a span still counts: S2 refetches each of the four evicted text Files.
    try testing.expect(try intField(output, "scenario=s2 ", "enrichment_refetches") >= 4);
    try testing.expect(try intField(output, "scenario=s5 ", "refetches") > 0);
    try testing.expect(try intField(output, "scenario=s6 ", "refetches") > 0);
    // After refresh and after the restart, every fetch is of an admitted File.
    for ([_][]const u8{ "scenario=s7 ", "scenario=s8 " }) |prefix| {
        try testing.expect(try intField(output, prefix, "refetches") > 0);
        try testing.expectEqual(@as(usize, 0), try intField(output, prefix, "cold_fetches"));
    }
}

test "M28 cache S4 is a cold Review Search after a restart, also when every File fits the budget" {
    const responses = fixtureResponses(matching_b);
    var clock: FakeClock = .{};
    var options = fixture_options;
    options.scenarios = .initMany(&.{ .s1, .s2, .s3, .s4, .s5, .s6 });
    const output = try runFixture(&responses, options, &clock);
    defer testing.allocator.free(output);
    // S1 admits every File, and the default budget keeps them. Only the restart makes S4 cold.
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s3 ", "requests"));
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s4 ", "hits"));
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s4 ", "refetches"));
    try testing.expect(try intField(output, "scenario=s4 ", "src_requests") > 0);
    // S6 reopens the Overlay on content that S4 acquired, so rule 3 compares a cold and a warm Review Search.
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s6 ", "requests"));
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s6 ", "hits"));
}

test "M28 cache an unlimited budget refetches nothing in S2, S3, S5, and S6" {
    const responses = fixtureResponses(matching_b);
    var clock: FakeClock = .{};
    const output = try runFixture(&responses, withBudget(fixture_options, 0), &clock);
    defer testing.allocator.free(output);
    for ([_][]const u8{ "scenario=s1 ", "scenario=s2 ", "scenario=s3 ", "scenario=s5 ", "scenario=s6 " }) |prefix|
        try testing.expectEqual(@as(usize, 0), try intField(output, prefix, "refetches"));
    try testing.expect(try intField(output, "scenario=s8 ", "refetches") > 0);
}

test "M28 cache a 429 response counts in rate_limited, also after the retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var flaky: FlakyHttpClient = .{ .fake = &fake, .key = "/src/aaaa/PATHSENTINEL/c.zig", .script = &.{.{ .status = 429, .retry_after_ms = 1 }} };
    var transport: FakeTransport = .{ .client = flaky.httpClient() };
    var clock: FakeClock = .{};
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var options = fixture_options;
    options.scenarios = .initOne(.s1);
    const output = try runIn(&transport, path, options, &clock, &notes.writer);
    defer testing.allocator.free(output);
    // The overscan fetches b.zig before S1. S1 fetches c.zig once. The harness retries the 429 below
    // RemoteBlobSource, so the retry succeeds.
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s1 ", "rate_limited"));
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s1 ", "retries"));
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s1 ", "failures"));
    try testing.expect(std.mem.indexOf(u8, notes.written(), "wait reason=retry status=429 attempt=1 seconds=") != null);
}

/// One GET through a MeasuringHttpClient on a fresh request window.
const RetryProbe = struct {
    tmp: testing.TmpDir,
    clock: FakeClock = .{},
    notes_text: std.Io.Writer.Allocating,
    notes: Notes,
    window: RequestWindow,
    measuring: MeasuringHttpClient,

    fn init(self: *RetryProbe, inner: bbr.http.HttpClient, random: std.Random, policy: RetryPolicy, hourly: usize) !void {
        self.tmp = testing.tmpDir(.{});
        self.clock = .{};
        self.notes_text = .init(testing.allocator);
        self.notes = .{ .writer = &self.notes_text.writer };
        self.window = try .open(testing.io, self.tmp.dir, self.clock.clock(), &self.notes, hourly);
        self.measuring = .{ .inner = inner, .clock = self.clock.clock(), .window = &self.window, .notes = &self.notes, .random = random, .policy = policy };
    }

    fn deinit(self: *RetryProbe) void {
        self.measuring.deinit();
        self.window.deinit();
        self.notes_text.deinit();
        self.tmp.cleanup();
    }

    fn get(self: *RetryProbe) !u16 {
        const response = try self.measuring.httpClient().send(testing.allocator, .{ .method = .GET, .url = "https://example.test/x" });
        defer testing.allocator.free(response.body);
        return response.status;
    }
};

test "M28 cache retries back off with full jitter up to the cap and honour Retry-After" {
    const s = std.time.ns_per_s;
    var max_jitter: FixedRandom = .{ .value = std.math.maxInt(u64) };
    var zero_jitter: FixedRandom = .{ .value = 1 };
    const cases = [_]struct {
        responses: []const bbr.http.Canned,
        random: *FixedRandom,
        policy: RetryPolicy = .{},
        sleeps: []const u64,
        retries: usize,
        rate_limited: usize = 0,
    }{
        .{ .responses = &.{ .{ .status = 503 }, .{ .status = 503 }, .{ .status = 503 }, .{ .status = 200 } }, .random = &max_jitter, .sleeps = &.{ 2 * s, 4 * s, 8 * s }, .retries = 3 },
        .{ .responses = &.{ .{ .status = 503 }, .{ .status = 503 }, .{ .status = 503 }, .{ .status = 503 }, .{ .status = 200 } }, .random = &max_jitter, .policy = .{ .cap_ns = 5 * s }, .sleeps = &.{ 2 * s, 4 * s, 5 * s, 5 * s }, .retries = 4 },
        // The 429 also fills the window, so the retry then waits at the request gate.
        .{ .responses = &.{ .{ .status = 429, .retry_after_ms = 7000 }, .{ .status = 200 } }, .random = &zero_jitter, .sleeps = &.{ 7 * s, hour_ns - 7 * s }, .retries = 1, .rate_limited = 1 },
    };
    for (cases) |case| {
        var fake: bbr.http.FakeHttpClient = .{ .responses = case.responses };
        var probe_client: RetryProbe = undefined;
        try probe_client.init(fake.httpClient(), case.random.random(), case.policy, 900);
        defer probe_client.deinit();
        try testing.expectEqual(@as(u16, 200), try probe_client.get());
        try testing.expectEqualSlices(u64, case.sleeps, probe_client.clock.recordedSleeps());
        const traffic = try probe_client.measuring.since(testing.allocator, .{ .traffic = .{}, .latency_count = 0, .excluded_ns = 0 });
        try testing.expectEqual(case.retries, traffic.retries);
        try testing.expectEqual(case.retries + 1, traffic.requests);
        try testing.expectEqual(case.rate_limited, traffic.rate_limited);
        try testing.expectEqual(@as(usize, 0), traffic.failures);
    }
}

test "M28 cache a request that hangs times out and the harness retries it" {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    // The server never accepts. The kernel completes the handshake, so the request waits for a head that never comes.
    var server = try address.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/hang", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);
    var std_client = bbr.http.StdHttpClient.init(testing.allocator, testing.io);
    defer std_client.deinit();
    var timed: TimedHttpClient = .{ .io = testing.io, .inner = std_client.httpClient(), .timeout = .fromMilliseconds(200) };

    const start = std.Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.Timeout, timed.httpClient().send(testing.allocator, .{ .method = .GET, .url = url }));
    try testing.expect(start.untilNow(testing.io, .awake).toSeconds() < 5);

    var zero_jitter: FixedRandom = .{ .value = 1 };
    var probe_client: RetryProbe = undefined;
    try probe_client.init(timed.httpClient(), zero_jitter.random(), .{ .max_attempts = 2 }, 900);
    defer probe_client.deinit();
    try testing.expectError(error.RetriesExhausted, probe_client.measuring.httpClient().send(testing.allocator, .{ .method = .GET, .url = url }));
    try testing.expect(std.mem.indexOf(u8, probe_client.notes_text.written(), "wait reason=retry error=Timeout attempt=1") != null);
    try testing.expectEqual(@as(usize, 2), (try probe_client.measuring.since(testing.allocator, .{ .traffic = .{}, .latency_count = 0, .excluded_ns = 0 })).retries);
}

test "M28 cache a 429 marks the request window full" {
    var fake: bbr.http.FakeHttpClient = .{ .responses = &.{ .{ .status = 429 }, .{ .status = 200 } } };
    var max_jitter: FixedRandom = .{ .value = std.math.maxInt(u64) };
    var probe_client: RetryProbe = undefined;
    try probe_client.init(fake.httpClient(), max_jitter.random(), .{}, 5);
    defer probe_client.deinit();
    try testing.expectEqual(@as(u16, 200), try probe_client.get());
    const notes = probe_client.notes_text.written();
    const retry_at = std.mem.indexOf(u8, notes, "wait reason=retry status=429 attempt=1 seconds=2.0") orelse return error.MissingNote;
    try testing.expect(std.mem.indexOfPos(u8, notes, retry_at, "wait reason=window seconds=3598.0") != null);
    // The 429 and its marks hold the whole budget at time 0. The retry comes one hour later.
    const log = try probe_client.tmp.dir.readFileAlloc(testing.io, "requests.log", testing.allocator, .unlimited);
    defer testing.allocator.free(log);
    const expected = "0\n" ** 5 ++ std.fmt.comptimePrint("{d}\n", .{hour_ns});
    try testing.expectEqualStrings(expected, log);
}

test "M28 cache merged PullRequest check counts Hunk mismatch Files" {
    var options = fixture_options;
    options.scenarios = .initOne(.s1);
    const matching = fixtureResponses(matching_b);
    var clock: FakeClock = .{};
    const clean = try runFixture(&matching, options, &clock);
    defer testing.allocator.free(clean);
    try testing.expectEqual(@as(usize, 0), try intField(clean, "check", "hunk_mismatch_files"));
    try testing.expectEqual(@as(usize, 0), try intField(clean, "check", "not_found_sides"));
    const changed = fixtureResponses(.{ .request_key = "/src/aaaa/PATHSENTINEL/b.zig", .body = "qrysentinel CHANGED SRCSENTINEL\n" ++ "newtail\n" ** tall });
    const mismatch = try runFixture(&changed, options, &clock);
    defer testing.allocator.free(mismatch);
    try testing.expectEqual(@as(usize, 1), try intField(mismatch, "check", "hunk_mismatch_files"));
}

/// Runs the fixture in a new output directory and returns the output and the notes.
fn runWithNotes(responses: []const bbr.http.Canned, options: Options, clock: *FakeClock, notes: *std.Io.Writer.Allocating) ![]u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    var fake: bbr.http.FakeHttpClient = .{ .responses = responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    return runIn(&transport, path, options, clock, &notes.writer);
}

fn floatField(output: []const u8, prefix: []const u8, key: []const u8) !f64 {
    return std.fmt.parseFloat(f64, try field(output, prefix, key));
}

test "M28 cache the request budget waits before a scenario and never inside a measured span" {
    const responses = fixtureResponses(matching_b);
    // The clock moves only when the harness sleeps, so a wait inside a span would show as latency.
    var clock: FakeClock = .{};
    var options = withBudget(fixture_options, 1);
    options.scenarios = .initMany(&.{ .s1, .s2 });
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var first_clock: FakeClock = .{};
    const first = try runWithNotes(&responses, options, &first_clock, &notes);
    defer testing.allocator.free(first);
    // The budget equals the S2 estimate. The window holds the earlier requests, so S2 waits before it starts.
    options.hourly_request_budget = try intField(first, "scenario=s2 ", "request_estimate");
    try testing.expect(try intField(first, "scenario=s1 ", "request_estimate") < options.hourly_request_budget);
    notes.clearRetainingCapacity();
    const output = try runWithNotes(&responses, options, &clock, &notes);
    defer testing.allocator.free(output);
    try testing.expect(clock.time.load(.monotonic) >= hour_ns);
    try testing.expect(std.mem.indexOf(u8, notes.written(), "wait reason=scenario scenario=s2 seconds=") != null);
    try testing.expect(std.mem.indexOf(u8, notes.written(), "reason=window") == null);
    for ([_][]const u8{ "scenario=s1 ", "scenario=s2 " }) |prefix| {
        try testing.expect(try intField(output, prefix, "samples") > 0);
        try testing.expectEqualStrings("0.0", try field(output, prefix, "latency_p95_ms"));
        try testing.expectEqualStrings("0.0", try field(output, prefix, "paused_ms"));
        try testing.expectEqual(@as(usize, 0), try intField(output, prefix, "paced_samples"));
    }
}

/// The requests of one Session load of the fixture on a fake client of its own.
fn sessionLoadRequests(responses: []const bbr.http.Canned) !usize {
    var fake: bbr.http.FakeHttpClient = .{ .responses = responses };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "ws" });
    const loaded = try session_mod.loadWith(testing.io, std.heap.page_allocator, client, "repo", 7);
    loaded.destroy();
    return fake.callCount();
}

test "M28 cache the request estimate bounds the requests of each scenario" {
    const tall_responses = fixtureResponses(matching_b);
    var exceeded = false;
    for ([_][]const bbr.http.Canned{ &tall_responses, &short_responses }) |responses| {
        for ([_]usize{ 1, fixture_options.cache_max_bytes }) |budget| {
            var clock: FakeClock = .{};
            const output = try runFixture(responses, withBudget(fixture_options, budget), &clock);
            defer testing.allocator.free(output);
            for (std.enums.values(Scenario)) |scenario| {
                var prefix_buffer: [16]u8 = undefined;
                const prefix = try std.fmt.bufPrint(&prefix_buffer, "scenario={s} ", .{@tagName(scenario)});
                const requests = try intField(output, prefix, "requests");
                const estimate = try intField(output, prefix, "request_estimate");
                if (requests > estimate) {
                    std.debug.print("files={s} cache_max_bytes={d} scenario={s} requests={d} request_estimate={d}\n", .{
                        try field(output, "header", "files"), budget, @tagName(scenario), requests, estimate,
                    });
                    exceeded = true;
                }
            }
            if (responses.ptr != &short_responses) continue;
            const session_requests = try intField(output, "header", "session_requests");
            const range_files = try intField(output, "header", "range_files");
            try testing.expectEqual(try sessionLoadRequests(responses), session_requests);
            // Several short Files share the Frame, so each File Jump can fetch more than one File.
            try testing.expect(range_files > 3);
            // The start Enrichment Range alone cannot cover the Session load.
            try testing.expect(session_requests > 2 * range_files);
            // One File for each of the 200 S3 jumps would allow only 400 requests.
            if (budget == 1) try testing.expect(try intField(output, "scenario=s3 ", "requests") > 400);
        }
    }
    try testing.expect(!exceeded);
}

test "M28 cache a harness wait inside a span is not latency" {
    const responses = fixtureResponses(matching_b);
    var clock: FakeClock = .{};
    var options = fixture_options;
    // Each scenario estimates more requests than the budget, so the request gate waits. In S1 it waits
    // inside a span. In S2 it waits for an overscan fetch outside the spans.
    options.hourly_request_budget = 4;
    options.scenarios = .initMany(&.{ .s1, .s2 });
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    const output = try runWithNotes(&responses, withBudget(options, 1), &clock, &notes);
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, notes.written(), "wait reason=window seconds=") != null);
    try testing.expect(std.mem.indexOf(u8, notes.written(), "reason=scenario") == null);
    for ([_][]const u8{ "scenario=s1 ", "scenario=s2 " }) |prefix| {
        try testing.expect(try intField(output, prefix, "samples") > 0);
        try testing.expectEqualStrings("0.0", try field(output, prefix, "latency_p95_ms"));
        try testing.expect(try floatField(output, prefix, "paused_ms") > 0);
    }
    try testing.expect(try intField(output, "scenario=s1 ", "paced_samples") > 0);
}

test "M28 cache the request window survives a restart and never exceeds the budget in any hour" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var clock: FakeClock = .{};
    var options = withBudget(fixture_options, 1);
    options.hourly_request_budget = 30;
    options.scenarios = .initMany(&.{ .s1, .s2, .s3 });
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var last_hour: std.ArrayList(u8) = .empty;
    defer last_hour.deinit(testing.allocator);
    for ([_][]const u8{ "first", "second" }, 0..) |run_label, index| {
        notes.clearRetainingCapacity();
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        var transport: FakeTransport = .{ .client = fake.httpClient() };
        options.run_label = run_label;
        const output = try runIn(&transport, path, options, &clock, &notes.writer);
        testing.allocator.free(output);
        if (index > 0) continue;
        const first_log = try tmp.dir.readFileAlloc(testing.io, "requests.log", testing.allocator, .unlimited);
        defer testing.allocator.free(first_log);
        var first_lines = std.mem.tokenizeScalar(u8, first_log, '\n');
        while (first_lines.next()) |line| if (try std.fmt.parseInt(u64, line, 10) + hour_ns > clock.time.load(.monotonic))
            try last_hour.print(testing.allocator, "{s}\n", .{line});
    }
    // The second run keeps the requests of the last hour of the first run, and its own requests follow them.
    try testing.expect(last_hour.items.len > 0);
    const log = try tmp.dir.readFileAlloc(testing.io, "requests.log", testing.allocator, .unlimited);
    defer testing.allocator.free(log);
    try testing.expect(std.mem.startsWith(u8, log, last_hour.items));
    var entries: std.ArrayList(u64) = .empty;
    defer entries.deinit(testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| try entries.append(testing.allocator, try std.fmt.parseInt(u64, line, 10));
    try testing.expect(entries.items.len > options.hourly_request_budget);
    std.mem.sort(u64, entries.items, {}, std.sort.asc(u64));
    for (entries.items, 0..) |at, first| {
        var count: usize = 0;
        for (entries.items[first..]) |later| count += @intFromBool(later < at + hour_ns);
        try testing.expect(count <= options.hourly_request_budget);
    }
}

test "M28 cache a second harness on the same output directory fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const held = try tmp.dir.createFile(testing.io, "lock", .{ .lock = .exclusive, .truncate = false });
    defer held.close(testing.io);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var clock: FakeClock = .{};
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    try testing.expectError(error.RunInProgress, runIn(&transport, path, fixture_options, &clock, &notes.writer));
    try testing.expectEqualStrings("another harness uses this output directory\n", notes.written());
    try testing.expectEqual(@as(usize, 0), fake.callCount());
}

test "M28 cache a scenario subset keeps the scenarios that it depends on" {
    for ([_][]const u8{ "s1,s2,s3", "s4,s5,s6,s7,s8", "s1,s7", "s3", "s5,s6" }) |subset|
        _ = try Options.parse(&.{ "--run-label", "a", "--output-dir", "out", "--scenarios", subset });
    for ([_][]const u8{ "s2", "s2,s3", "s7", "s8", "s5,s6,s7,s8" }) |subset|
        try testing.expectError(error.InvalidArguments, Options.parse(&.{ "--run-label", "a", "--output-dir", "out", "--scenarios", subset }));
}

test "M28 cache a remote run needs a run label and an output directory" {
    _ = try Options.parse(&.{ "--run-label", "a", "--output-dir", "out" });
    try testing.expectError(error.InvalidArguments, Options.parse(&.{ "--output-dir", "out" }));
    try testing.expectError(error.InvalidArguments, Options.parse(&.{ "--run-label", "", "--output-dir", "out" }));
    try testing.expectError(error.InvalidArguments, Options.parse(&.{ "--run-label", "a" }));
    try testing.expectError(error.InvalidArguments, Options.parse(&.{ "--run-label", "a/b", "--output-dir", "out" }));
}

test "M28 cache an unsupported command kind fails the run and names the kind" {
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var clock: FakeClock = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var notes_text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes_text.deinit();
    var notes: Notes = .{ .writer = &notes_text.writer };
    var window: RequestWindow = try .open(testing.io, tmp.dir, clock.clock(), &notes, 900);
    defer window.deinit();
    var prng: std.Random.DefaultPrng = .init(28);
    var measuring: MeasuringHttpClient = .{ .inner = try transport.transport().open(), .clock = clock.clock(), .window = &window, .notes = &notes, .random = prng.random() };
    defer measuring.deinit();
    const env: Environment = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .clock = clock.clock(),
        .transport = transport.transport(),
        .credential = .{ .username = "u", .token = "t", .workspace = "ws" },
        .highlighter = plain.highlighter(),
        .bbr_version = "test",
        .out = undefined,
        .notes = undefined,
        .random = prng.random(),
    };
    var driver: Driver = undefined;
    try driver.init(env, fixture_options, &measuring, "repo", 7);
    defer driver.deinit();
    _ = try driver.start();
    const clipboard = try testing.allocator.create(presentation.ClipboardCopy);
    clipboard.* = .{ .allocator = testing.allocator, .text = try testing.allocator.dupe(u8, "copy") };
    var command: OwnedCommand = .{ .copy_clipboard = clipboard };
    defer command.deinit();
    try testing.expectError(error.UnsupportedCommand, driver.executor().execute(driver.sink(), &command));
    try testing.expectEqual(std.meta.Tag(OwnedCommand).copy_clipboard, driver.unsupported.?);
}

test "M28 cache a random File Jump never targets the active File" {
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var clock: FakeClock = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var notes_text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes_text.deinit();
    var notes: Notes = .{ .writer = &notes_text.writer };
    var window: RequestWindow = try .open(testing.io, tmp.dir, clock.clock(), &notes, 900);
    defer window.deinit();
    var prng: std.Random.DefaultPrng = .init(28);
    var measuring: MeasuringHttpClient = .{ .inner = try transport.transport().open(), .clock = clock.clock(), .window = &window, .notes = &notes, .random = prng.random() };
    defer measuring.deinit();
    const env: Environment = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .clock = clock.clock(),
        .transport = transport.transport(),
        .credential = .{ .username = "u", .token = "t", .workspace = "ws" },
        .highlighter = plain.highlighter(),
        .bbr_version = "test",
        .out = undefined,
        .notes = undefined,
        .random = prng.random(),
    };
    var driver: Driver = undefined;
    try driver.init(env, fixture_options, &measuring, "repo", 7);
    defer driver.deinit();
    _ = try driver.start();
    var recorder: Recorder = .{};
    defer recorder.deinit(testing.allocator);
    var jumps: std.Random.DefaultPrng = .init(28);
    for (0..30) |_| {
        const before = driver.activeFile();
        try driver.randomJump(&recorder, jumps.random(), null);
        try testing.expect(driver.activeFile() != before);
    }
    for (0..10) |_| {
        const before = driver.activeFile().?;
        const other = (before + 1) % driver.file_count;
        try driver.randomJump(&recorder, jumps.random(), &.{ @min(before, other), @max(before, other) });
        try testing.expectEqual(other, driver.activeFile().?);
    }
    try testing.expectEqual(@as(usize, 40), recorder.samples.items.len);
    // A subset with only the active File has no target, so it records no sample.
    try driver.randomJump(&recorder, jumps.random(), &.{driver.activeFile().?});
    try testing.expectEqual(@as(usize, 40), recorder.samples.items.len);
}

/// Fails when a forbidden text is in `text`.
fn expectNone(text: []const u8, forbidden: []const []const u8) !void {
    for (forbidden) |needle| if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("forbidden text {s} in:\n{s}\n", .{ needle, text });
        return error.ForbiddenText;
    };
}

/// Fails when a forbidden text is in a file of `dir`. Returns the file count.
fn expectNoneInFiles(dir: std.Io.Dir, forbidden: []const []const u8) !usize {
    var files: usize = 0;
    var entries = dir.iterate();
    while (try entries.next(testing.io)) |entry| if (entry.kind == .file) {
        const bytes = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .unlimited);
        defer testing.allocator.free(bytes);
        try expectNone(bytes, forbidden);
        files += 1;
    };
    return files;
}

test "M28 cache benchmark output holds no source, path, query, or Comment text" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var clock: FakeClock = .{ .step_ns = 1000 };
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var options = withBudget(fixture_options, 1);
    options.network_label = "office";
    const output = try runIn(&transport, path, options, &clock, &notes.writer);
    defer testing.allocator.free(output);
    try testing.expect(try intField(output, "scenario=s4 ", "samples") > 0);
    const forbidden = [_][]const u8{ "SRCSENTINEL", "PATHSENTINEL", "qrysentinel", "qrytwo", "CMTSENTINEL", "TITLESENTINEL", "/src/", "repo" };
    try expectNone(output, &forbidden);
    try expectNone(notes.written(), &forbidden);
    // The lock, the request log, and the checkpoint.
    try testing.expectEqual(@as(usize, 3), try expectNoneInFiles(tmp.dir, &forbidden));
}

test "M28 cache the Credential token never reaches the output, the notes, or the run files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var flaky: FlakyHttpClient = .{ .fake = &fake, .key = "/src/aaaa/PATHSENTINEL/c.zig", .script = &.{.{ .status = 503 }} };
    defer flaky.deinit();
    var transport: FakeTransport = .{ .client = flaky.httpClient() };
    var clock: FakeClock = .{};
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var options = fixture_options;
    options.hourly_request_budget = 4;
    options.scenarios = .initMany(&.{ .s1, .s2 });
    const output = try runIn(&transport, path, options, &clock, &notes.writer);
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, notes.written(), "wait reason=window") != null);
    try testing.expect(std.mem.indexOf(u8, notes.written(), "wait reason=retry status=503") != null);
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s1 ", "retries"));
    const forbidden = [_][]const u8{"TOKENSENTINEL"};
    try expectNone(output, &forbidden);
    try expectNone(notes.written(), &forbidden);
    try testing.expectEqual(@as(usize, 3), try expectNoneInFiles(tmp.dir, &forbidden));
}

/// The number of transport calls in a healthy run of `scenarios`.
fn healthyCalls(base: Options, scenarios: []const Scenario) !usize {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var clock: FakeClock = .{};
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var options = base;
    options.scenarios = .initMany(scenarios);
    const output = try runIn(&transport, path, options, &clock, &notes.writer);
    testing.allocator.free(output);
    return fake.callCount();
}

/// Runs every scenario in `path` and fails each transport call after `healthy_calls`.
fn failingRun(path: []const u8, options: Options, healthy_calls: usize, notes: *std.Io.Writer.Allocating) !usize {
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var flaky: FlakyHttpClient = .{ .fake = &fake, .healthy_calls = healthy_calls };
    defer flaky.deinit();
    var transport: FakeTransport = .{ .client = flaky.httpClient() };
    var clock: FakeClock = .{};
    try testing.expectError(error.RetriesExhausted, runIn(&transport, path, options, &clock, &notes.writer));
    return flaky.mostFailuresOfOneUrl();
}

/// Runs every scenario in `path` on a healthy fake and returns the output.
fn healthyRun(path: []const u8, options: Options, notes: *std.Io.Writer.Allocating) ![]u8 {
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var clock: FakeClock = .{};
    return runIn(&transport, path, options, &clock, &notes.writer);
}

fn scenarioLineCount(text: []const u8) usize {
    return std.mem.count(u8, text, "\nscenario=") + @intFromBool(std.mem.startsWith(u8, text, "scenario="));
}

test "M28 cache gives up after 8 attempts and a rerun resumes at the first unfinished segment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    // Each call after S6 fails, so the first failure is inside S7.
    const through_s6 = try healthyCalls(fixture_options, &.{ .s1, .s2, .s3, .s4, .s5, .s6 });
    try testing.expectEqual(@as(usize, 8), try failingRun(path, fixture_options, through_s6, &notes));
    // Another request can note its own wait between the two notes.
    const give_up = std.mem.indexOf(u8, notes.written(), "give_up attempts=8 error=ConnectionResetByPeer\n") orelse return error.MissingNote;
    try testing.expect(std.mem.indexOfPos(u8, notes.written(), give_up, "\ncheckpoint kept; rerun the same command to resume\n") != null);
    const kept = try tmp.dir.readFileAlloc(testing.io, "fixture-7-all.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 6), scenarioLineCount(kept));
    try testing.expect(std.mem.indexOf(u8, kept, "scenario=s7 ") == null);
    try testing.expect(std.mem.indexOf(u8, kept, "\ncheck ") == null);

    notes.clearRetainingCapacity();
    const output = try healthyRun(path, fixture_options, &notes);
    defer testing.allocator.free(output);
    try testing.expect(std.mem.startsWith(u8, notes.written(), "resume skip=s1,s2,s3,s4,s5,s6\n"));
    // The rerun repeats the header and the S1 to S6 lines byte for byte.
    const progress_at = std.mem.indexOf(u8, kept, "progress ") orelse return error.MissingProgress;
    try testing.expect(std.mem.startsWith(u8, output, kept[0..progress_at]));
    try testing.expectEqual(@as(usize, 8), scenarioLineCount(output));
    try testing.expect(std.mem.indexOf(u8, output, "progress ") == null);
    // The restored admitted flags make every S7 fetch a refetch.
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s7 ", "cold_fetches"));
    try testing.expect(try intField(output, "scenario=s7 ", "refetches") > 0);
    try testing.expect(try intField(output, "scenario=s8 ", "refetches") > 0);
}

test "M28 cache a rerun of a finished run sends no request" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    const first = try healthyRun(path, fixture_options, &notes);
    defer testing.allocator.free(first);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var clock: FakeClock = .{};
    const second = try runIn(&transport, path, fixture_options, &clock, &notes.writer);
    defer testing.allocator.free(second);
    try testing.expectEqual(@as(usize, 0), fake.callCount());
    try testing.expectEqualStrings(first, second);
    try testing.expectEqual(@as(usize, 8), scenarioLineCount(second));
}

test "M28 cache a failure inside S1 to S6 restarts that segment from S1" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    // The budget evicts each File, so S4 fetches again. Each call after S3 fails, so the first failure is inside S4.
    const options = withBudget(fixture_options, 1);
    const through_s3 = try healthyCalls(options, &.{ .s1, .s2, .s3 });
    try testing.expectEqual(@as(usize, 8), try failingRun(path, options, through_s3, &notes));
    const kept = try tmp.dir.readFileAlloc(testing.io, "fixture-7-all.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 0), scenarioLineCount(kept));

    notes.clearRetainingCapacity();
    const output = try healthyRun(path, options, &notes);
    defer testing.allocator.free(output);
    try testing.expect(std.mem.startsWith(u8, notes.written(), "resume skip=\n"));
    try testing.expectEqual(@as(usize, 8), scenarioLineCount(output));
    // S1 starts again from the state after the header, so its first fetches are cold.
    // A restored S1 state would make every S1 fetch a refetch. The budget of 1 can evict a
    // prefetched File before its jump, so S1 can also hold a refetch.
    try testing.expect(try intField(output, "scenario=s1 ", "cold_fetches") > 0);
}

test "M28 cache a rerun with other options fails on the checkpoint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .client = fake.httpClient() };
    var clock: FakeClock = .{};
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var options = fixture_options;
    options.scenarios = .initOne(.s1);
    const output = try runIn(&transport, path, options, &clock, &notes.writer);
    testing.allocator.free(output);
    const calls = fake.callCount();
    notes.clearRetainingCapacity();
    options.seed = 29;
    try testing.expectError(error.CheckpointMismatch, runIn(&transport, path, options, &clock, &notes.writer));
    try testing.expectEqualStrings("checkpoint mismatch key=seed\n", notes.written());
    try testing.expectEqual(calls, fake.callCount());
}

fn summaryText(input: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    try summarize(testing.allocator, input, &output.writer);
    return output.toOwnedSlice();
}

const RunFixture = struct {
    /// Scenario lines with one `{s}` for the run label. Each replaces the default line of its scenario.
    lines: []const []const u8 = &.{},
    omit: ?Scenario = null,
    check: bool = true,
};

/// The checkpoint lines of one complete run for PullRequest 12, changed by `fixture`.
inline fn fullRun(comptime label: []const u8, comptime fixture: RunFixture) []const u8 {
    return comptime text: {
        var text: []const u8 = if (fixture.check) "check run_label=" ++ label ++ " pull_request=12 state=ok not_found_sides=0 hunk_mismatch_files=0\n" else "";
        scenarios: for (std.enums.values(Scenario)) |scenario| {
            if (fixture.omit == scenario) continue;
            const prefix = "scenario=" ++ @tagName(scenario) ++ " ";
            for (fixture.lines) |line| if (std.mem.startsWith(u8, line, prefix)) {
                text = text ++ std.fmt.comptimePrint(line, .{label});
                continue :scenarios;
            };
            text = text ++ prefix ++ "run_label=" ++ label ++ " pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0\n";
        }
        break :text text;
    };
}

const quiet_run: RunFixture = .{ .lines = &.{
    "scenario=s2 run_label={s} pull_request=12 refetches=3 failures=0 added_delay_p95_ms=120.0\n",
    "scenario=s4 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=900.0\n",
    "scenario=s5 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=100.0\n",
    "scenario=s6 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=700.0\n",
} };
const slow_run: RunFixture = .{ .lines = &.{"scenario=s3 run_label={s} pull_request=12 refetches=40 failures=0 added_delay_p95_ms=450.0\n"} };

test "M28 cache summarize gives Inconclusive for a partial or failed run" {
    const failed = "scenario=s1 run_label={s} pull_request=12 refetches=0 failures=3 added_delay_p95_ms=0.0\n";
    const other = "scenario=s1 run_label={s} pull_request=15 refetches=0 failures=0 added_delay_p95_ms=0.0\n";
    const cases = [_]struct { input: []const u8, gap: []const u8 }{
        .{ .input = fullRun("a", .{}) ++ fullRun("b", .{ .omit = .s7 }), .gap = "run_label=b incomplete pull_request=12 missing=s7\n" },
        .{ .input = fullRun("a", .{}) ++ fullRun("b", .{ .lines = &.{failed} }), .gap = "run_label=b incomplete pull_request=12 reason=failures scenario=s1\n" },
        .{ .input = fullRun("a", .{}) ++ fullRun("b", .{ .check = false }), .gap = "run_label=b incomplete pull_request=12 missing=check\n" },
        .{ .input = std.fmt.comptimePrint(failed, .{"a"}) ++ std.fmt.comptimePrint(other, .{"b"}), .gap = "run_label=a incomplete pull_request=12 missing=check\nrun_label=b incomplete pull_request=12 missing=check\n" },
    };
    inline for (cases) |case| {
        const text = try summaryText(case.input);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.gap ++ "outcome=Inconclusive scenarios=none\n", text);
    }
}

test "M28 cache summarize gives No delay, Delay, and Inconclusive" {
    const cases = [_]struct { input: []const u8, outcome: []const u8 }{
        .{ .input = fullRun("a", quiet_run) ++ fullRun("b", quiet_run), .outcome = "outcome=No delay scenarios=none\n" },
        .{ .input = fullRun("a", slow_run) ++ fullRun("b", slow_run), .outcome = "outcome=Delay scenarios=s3\n" },
        .{ .input = fullRun("a", slow_run) ++ fullRun("b", quiet_run), .outcome = "outcome=Inconclusive scenarios=s3\n" },
        .{ .input = fullRun("a", slow_run) ++ fullRun("b", quiet_run) ++ fullRun("c", slow_run), .outcome = "outcome=Delay scenarios=s3\n" },
    };
    for (cases) |case| {
        const text = try summaryText(case.input);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.endsWith(u8, text, case.outcome));
    }
}

test "M28 cache summarize treats one refetch in S5 or S6 as a delay" {
    const s5: RunFixture = .{ .lines = &.{"scenario=s5 run_label={s} pull_request=12 refetches=1 failures=0 added_delay_p95_ms=2.0 complete_result_ms=30.0\n"} };
    const s6: RunFixture = .{ .lines = &.{"scenario=s6 run_label={s} pull_request=12 refetches=1 failures=0 added_delay_p95_ms=2.0 complete_result_ms=30.0\n"} };
    for ([_][]const u8{ fullRun("a", s5) ++ fullRun("b", s5), fullRun("a", s6) ++ fullRun("b", s6) }) |input| {
        const text = try summaryText(input);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "outcome=Delay scenarios=s") != null);
    }
}

test "M28 cache summarize reports the restart Review Search delay only when S6 has no refetch" {
    const restart: RunFixture = .{ .lines = &.{
        "scenario=s4 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=900.0\n",
        "scenario=s6 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=100.0\n",
    } };
    const text = try summaryText(fullRun("a", restart) ++ fullRun("b", restart));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "outcome=Delay scenarios=restart_review_search\n"));
}

test "M28 cache summarize applies rule 3, not rule 1, to the S4 restart Review Search" {
    // The S4 sample refetches every File after a restart and has no hit baseline, so its added
    // delay is its full latency. Rule 3 subtracts the warm S6 reopen instead.
    const slow_scan: RunFixture = .{ .lines = &.{
        "scenario=s4 run_label={s} pull_request=12 refetches=1 failures=0 added_delay_p95_ms=900.0 complete_result_ms=900.0\n",
        "scenario=s6 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=700.0\n",
    } };
    const quiet = try summaryText(fullRun("a", slow_scan) ++ fullRun("b", slow_scan));
    defer testing.allocator.free(quiet);
    try testing.expect(std.mem.endsWith(u8, quiet, "outcome=No delay scenarios=none\n"));
    const slow_restart: RunFixture = .{ .lines = &.{
        "scenario=s4 run_label={s} pull_request=12 refetches=1 failures=0 added_delay_p95_ms=1200.0 complete_result_ms=1200.0\n",
        "scenario=s6 run_label={s} pull_request=12 refetches=0 failures=0 added_delay_p95_ms=0.0 complete_result_ms=700.0\n",
    } };
    const delayed = try summaryText(fullRun("a", slow_restart) ++ fullRun("b", slow_restart));
    defer testing.allocator.free(delayed);
    try testing.expect(std.mem.endsWith(u8, delayed, "outcome=Delay scenarios=restart_review_search\n"));
}

/// Delays each `/src/` request in real time, so a File fetch is still in flight
/// when the next File Jump starts. The fake clock does not see the delay.
const SlowSourceHttpClient = struct {
    fake: *bbr.http.FakeHttpClient,
    delay_ms: i64 = 500,

    fn httpClient(self: *SlowSourceHttpClient) bbr.http.HttpClient {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, allocator: Allocator, request: bbr.http.client.Request) anyerror!bbr.http.client.Response {
        const self: *SlowSourceHttpClient = @ptrCast(@alignCast(ptr));
        if (std.mem.indexOf(u8, request.url, "/src/") != null) testing.io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch {};
        return self.fake.httpClient().send(allocator, request);
    }
};

test "M28 cache a File Jump to a File whose fetch is still in flight is a fetch, not a hit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer testing.allocator.free(path);
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var slow: SlowSourceHttpClient = .{ .fake = &fake };
    var transport: FakeTransport = .{ .client = slow.httpClient() };
    var clock: FakeClock = .{};
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var options = withBudget(fixture_options, 1);
    options.scenarios = .initMany(&.{ .s1, .s2 });
    const output = try runIn(&transport, path, options, &clock, &notes.writer);
    defer testing.allocator.free(output);
    // The Enrichment Range starts each next File before the jump to it. The slow source keeps
    // that fetch in flight when the jump starts, so the reviewer waits for it. Only the first
    // File, which the start loaded, and the binary File are ready.
    try testing.expectEqual(@as(usize, 6), try intField(output, "scenario=s1 ", "samples"));
    try testing.expectEqual(@as(usize, 2), try intField(output, "scenario=s1 ", "hits"));
    try testing.expectEqual(@as(usize, 4), try intField(output, "scenario=s1 ", "cold_fetches"));
    // S2 revisits the five Files before the last one. The budget evicted the four text Files.
    try testing.expectEqual(@as(usize, 5), try intField(output, "scenario=s2 ", "samples"));
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s2 ", "hits"));
    try testing.expectEqual(@as(usize, 4), try intField(output, "scenario=s2 ", "refetches"));
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s2 ", "cold_fetches"));
}
