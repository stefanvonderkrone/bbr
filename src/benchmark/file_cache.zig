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
        /// The Files the scenario can fetch: this multiple of every File, plus `fetch_fixed`.
        fetch_all: u8 = 0,
        fetch_fixed: u16 = 0,
        search: bool = false,
        first_result: bool = false,
        restart: bool = false,
        steps: *const fn (*Driver, *Recorder) anyerror!void,
    };

    const specs = std.EnumArray(Scenario, Spec).init(.{
        .s1 = .{ .fetch_all = 1, .steps = sequentialReview },
        .s2 = .{ .fetch_fixed = 50, .steps = revisitAfterEviction },
        .s3 = .{ .fetch_fixed = 200, .steps = nonSequentialNavigation },
        .s4 = .{ .fetch_all = 1, .search = true, .first_result = true, .steps = firstReviewSearch },
        .s5 = .{ .fetch_all = 3, .search = true, .steps = queryEdits },
        .s6 = .{ .fetch_all = 1, .fetch_fixed = 10, .search = true, .steps = overlayReopen },
        .s7 = .{ .fetch_fixed = replacement_repeats * replacement_jumps, .steps = sessionReplacement },
        .s8 = .{ .fetch_fixed = replacement_repeats * replacement_jumps, .restart = true, .steps = processRestart },
    });

    fn spec(self: Scenario) Spec {
        return specs.get(self);
    }

    /// Each File uses at most two `/src/` requests.
    fn requestEstimate(self: Scenario, file_count: usize) usize {
        const s = self.spec();
        return 2 * (s.fetch_all * file_count + s.fetch_fixed);
    }
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
};

pub const ScenarioReport = struct {
    scenario: Scenario,
    run_label: []const u8,
    pull_request: u64,
    stats: Stats,
    traffic: Traffic,
    peak_retained_bytes: usize,
    retained_bytes: usize,
    full_review_bytes: usize,
    peak_rss_bytes: usize,
    candidate_session_ns: u64 = 0,

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
        try out.print(" requests={d} src_requests={d} failures={d} rate_limited={d} request_median_ms={d:.1} request_p95_ms={d:.1}", .{
            t.requests, t.src_requests, t.failures, t.rate_limited, ms(t.request_median_ns), ms(t.request_p95_ns),
        });
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

/// The time seam for latencies, request timestamps, the dwell, and the request budget.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (*anyopaque) u64,
        sleep: *const fn (*anyopaque, u64) void,
    };

    pub fn now(self: Clock) u64 {
        return self.vtable.now(self.ptr);
    }

    pub fn sleep(self: Clock, ns: u64) void {
        self.vtable.sleep(self.ptr, ns);
    }
};

pub const IoClock = struct {
    io: std.Io,

    pub fn clock(self: *IoClock) Clock {
        return .{ .ptr = self, .vtable = &.{ .now = now, .sleep = sleep } };
    }

    fn now(ptr: *anyopaque) u64 {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        return @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds());
    }

    fn sleep(ptr: *anyopaque, ns: u64) void {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        self.io.sleep(.fromNanoseconds(ns), .awake) catch {};
    }
};

/// Keeps the request timestamps of the last hour. The harness calls
/// `waitBefore` only between scenarios, never inside a measured span.
pub const RequestBudget = struct {
    clock: Clock,
    hourly: usize,
    timestamps: std.ArrayList(u64) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn deinit(self: *RequestBudget) void {
        self.timestamps.deinit(std.heap.page_allocator);
    }

    pub fn record(self: *RequestBudget, at: u64) Allocator.Error!void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.timestamps.append(std.heap.page_allocator, at);
    }

    /// Waits until the hour log and `estimate` fit in the budget. An estimate
    /// above the budget waits for an empty hour.
    pub fn waitBefore(self: *RequestBudget, estimate: usize) void {
        while (true) {
            const now = self.clock.now();
            const until = self.expiryNeeded(now, estimate) orelse return;
            self.clock.sleep(@max(until -| now, 1));
        }
    }

    fn expiryNeeded(self: *RequestBudget, now: u64, estimate: usize) ?u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var kept: usize = 0;
        for (self.timestamps.items) |at| if (at + hour_ns > now) {
            self.timestamps.items[kept] = at;
            kept += 1;
        };
        self.timestamps.shrinkRetainingCapacity(kept);
        const log = self.timestamps.items;
        std.mem.sort(u64, log, {}, std.sort.asc(u64));
        if (estimate > self.hourly) return if (log.len == 0) null else log[log.len - 1] + hour_ns;
        if (log.len + estimate <= self.hourly) return null;
        return log[log.len + estimate - self.hourly - 1] + hour_ns;
    }
};

/// Wraps an `HttpClient` and counts its traffic. It never stores a URL, a
/// header, or a body. File Enrichments send from many threads at once.
pub const MeasuringHttpClient = struct {
    inner: bbr.http.HttpClient,
    clock: Clock,
    budget: *RequestBudget,
    traffic: Traffic = .{},
    latencies: std.ArrayList(u64) = .empty,
    out_of_memory: bool = false,
    mutex: std.atomic.Mutex = .unlocked,

    const Mark = struct { traffic: Traffic, latency_count: usize };

    pub fn deinit(self: *MeasuringHttpClient) void {
        self.latencies.deinit(std.heap.page_allocator);
    }

    pub fn httpClient(self: *MeasuringHttpClient) bbr.http.HttpClient {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, allocator: Allocator, request: bbr.http.client.Request) anyerror!bbr.http.client.Response {
        const self: *MeasuringHttpClient = @ptrCast(@alignCast(ptr));
        const start = self.clock.now();
        const result = self.inner.send(allocator, request);
        const elapsed = self.clock.now() -| start;
        const src = std.mem.indexOf(u8, request.url, "/src/") != null;
        self.budget.record(start) catch {
            self.out_of_memory = true;
        };
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.traffic.requests += 1;
        if (src) self.traffic.src_requests += 1;
        if (result) |response| {
            // A 404 is a missing side, which the merged PullRequest check counts.
            if (response.status == 429) {
                self.traffic.rate_limited += 1;
            } else if (response.status >= 400 and response.status != 404) self.traffic.failures += 1;
        } else |_| self.traffic.failures += 1;
        self.latencies.append(std.heap.page_allocator, elapsed) catch {
            self.out_of_memory = true;
        };
        return result;
    }

    fn mark(self: *MeasuringHttpClient) Mark {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return .{ .traffic = self.traffic, .latency_count = self.latencies.items.len };
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
            .request_median_ns = median(latencies),
            .request_p95_ns = p95(latencies),
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

const StdTransport = struct {
    io: std.Io,
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
    client: ?bbr.http.StdHttpClient = null,

    fn transport(self: *StdTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .open = open, .close = close } };
    }

    fn open(ptr: *anyopaque) anyerror!bbr.http.HttpClient {
        const self: *StdTransport = @ptrCast(@alignCast(ptr));
        self.client = bbr.http.StdHttpClient.init(std.heap.page_allocator, self.io);
        errdefer close(ptr);
        try self.client.?.initDefaultProxies(self.arena, self.environ_map);
        return self.client.?.httpClient();
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
                .@"--scenarios" => {
                    options.scenarios = .initEmpty();
                    var ids = std.mem.splitScalar(u8, value, ',');
                    while (ids.next()) |id| options.scenarios.insert(std.meta.stringToEnum(Scenario, id) orelse return error.InvalidArguments);
                },
            }
        }
        if (options.hourly_request_budget == 0) return error.InvalidArguments;
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
};

pub fn main(init: std.process.Init, highlighter: bbr.highlight.Highlighter, bbr_version: []const u8) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &stdout.interface;

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
    try run(.{
        .gpa = init.gpa,
        .io = init.io,
        .clock = clock.clock(),
        .transport = transport.transport(),
        .credential = owned.credential(),
        .highlighter = highlighter,
        .bbr_version = bbr_version,
        .out = out,
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
            "  --run-label LABEL          run label in every line\n" ++
            "  --network-label LABEL      network label in the header\n" ++
            "  --scenarios s1,...,s8      scenario subset (default all)\n" ++
            "                             s2 needs s1. s7 and s8 need s1 or s4.\n",
        .{},
    );
    return error.InvalidArguments;
}

/// Runs the scenario chain for one PullRequest and prints the header, one line
/// for each scenario, and the merged PullRequest check.
pub fn run(env: Environment, options: Options, repository: []const u8, pull_request_id: u64) !void {
    var budget: RequestBudget = .{ .clock = env.clock, .hourly = options.hourly_request_budget };
    defer budget.deinit();
    var measuring: MeasuringHttpClient = .{ .inner = try env.transport.open(), .clock = env.clock, .budget = &budget };
    defer measuring.deinit();
    defer env.transport.close();

    const probe_ns = try probe(env, &measuring, repository, pull_request_id);
    var driver: Driver = undefined;
    try driver.init(env, options, &measuring, repository, pull_request_id);
    defer driver.deinit();
    _ = try driver.start();

    const out = env.out;
    try out.print("header run_label={s} network_label={s} bbr_version={s} cache_max_bytes={d} pull_request={d} state={s} files={d} probe_ms={d:.1}", .{
        options.run_label, options.network_label, env.bbr_version, options.cache_max_bytes, pull_request_id, driver.stateText(), driver.file_count, ms(probe_ns),
    });
    try out.print(" dwell_ms={d} seed={d} query_bytes={d} second_query_bytes={d} hourly_request_budget={d}\n", .{
        options.dwell_ms, options.seed, options.query.len, options.second_query.len, options.hourly_request_budget,
    });
    try out.flush();

    for (std.enums.values(Scenario)) |scenario| if (options.scenarios.contains(scenario)) {
        budget.waitBefore(scenario.requestEstimate(driver.file_count));
        const start = measuring.mark();
        driver.peak_retained = driver.retainedBytes();
        var recorder: Recorder = .{};
        defer recorder.deinit(env.gpa);
        scenario.spec().steps(&driver, &recorder) catch |err| {
            if (driver.unsupported) |kind| try out.print("error=unsupported_command scenario={s} kind={s}\n", .{ @tagName(scenario), @tagName(kind) });
            try out.flush();
            return err;
        };
        const report: ScenarioReport = .{
            .scenario = scenario,
            .run_label = options.run_label,
            .pull_request = pull_request_id,
            .stats = try stats(env.gpa, recorder.samples.items),
            .traffic = try measuring.since(env.gpa, start),
            .peak_retained_bytes = driver.peak_retained,
            .retained_bytes = driver.retainedBytes(),
            .full_review_bytes = driver.fullReviewBytes(),
            .peak_rss_bytes = peakRssBytes(),
            .candidate_session_ns = median(recorder.candidate_session_ns.items),
        };
        try report.write(out);
    };
    try out.print("check run_label={s} pull_request={d} state={s} not_found_sides={d} hunk_mismatch_files={d}\n", .{
        options.run_label, pull_request_id, driver.stateText(), driver.not_found_sides, driver.hunk_mismatch_files,
    });
    try out.flush();
}

fn probe(env: Environment, measuring: *MeasuringHttpClient, repository: []const u8, pull_request_id: u64) !u64 {
    var arena = std.heap.ArenaAllocator.init(env.gpa);
    defer arena.deinit();
    const client = bbr.bitbucket.Client.init(measuring.httpClient(), env.credential);
    var latencies: [probe_count]u64 = undefined;
    for (&latencies) |*latency| {
        const start = env.clock.now();
        _ = try client.getPullRequest(arena.allocator(), repository, pull_request_id);
        latency.* = env.clock.now() -| start;
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

    fn deinit(self: *Recorder, allocator: Allocator) void {
        self.samples.deinit(allocator);
        self.candidate_session_ns.deinit(allocator);
    }
};

/// One `enrich_file` command that started inside the measured span.
const Fetch = struct {
    file_index: usize,
    admitted_before: bool,
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
    admitted: []bool = &.{},
    checked: []bool = &.{},
    largest_result: []usize = &.{},
    focus_tick: []u64 = &.{},
    tick: u64 = 0,
    not_found_sides: usize = 0,
    hunk_mismatch_files: usize = 0,
    span_fetches: std.ArrayList(Fetch) = .empty,
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
        self.span_fetches.deinit(gpa);
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
        const begin = self.env.clock.now();
        const loaded = try session_mod.loadWith(self.env.io, std.heap.page_allocator, self.client(), self.repository, self.pull_request_id);
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
        const elapsed = self.env.clock.now() -| begin;
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
            const state_text = if (loaded.remotePullRequestConst()) |pull_request| pull_request.state else "";
            self.state_len = @min(state_text.len, self.state_buffer.len);
            @memcpy(self.state_buffer[0..self.state_len], state_text[0..self.state_len]);
        } else if (files != self.file_count) return error.FileCountChanged;
        try self.pump();
        try self.waitUntil(FocusSettled{});
        self.noteFocus();
        return elapsed;
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
                try group.concurrent(io, enrichmentWorker, .{ completion, io, self.client(), self.env.highlighter, enrich });
                self.span_fetches.appendAssumeCapacity(.{ .file_index = enrich.file_index, .admitted_before = self.admitted[enrich.file_index] });
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

    fn beginSpan(self: *Driver) u64 {
        self.span_fetches.clearRetainingCapacity();
        return self.env.clock.now();
    }

    /// A refetch wins over a cold fetch. `file` limits the span to one File.
    fn classify(self: *const Driver, file: ?usize) FetchClass {
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

    fn recordSearch(self: *Driver, recorder: *Recorder, begin: u64, first_result: bool) !void {
        if (first_result) {
            try self.waitUntil(SearchFirst{});
            try recorder.samples.append(self.env.gpa, .{ .kind = .search_first, .latency_ns = self.env.clock.now() -| begin, .class = .hit });
        }
        try self.waitUntil(SearchComplete{});
        const class = self.classify(null);
        const latency = self.env.clock.now() -| begin;
        if (first_result) recorder.samples.items[recorder.samples.items.len - 1].class = class;
        try recorder.samples.append(self.env.gpa, .{ .kind = .search_complete, .latency_ns = latency, .class = class });
    }

    /// Jumps through the File Finder. A null `recorder` keeps the jump out of the samples.
    fn finderJump(self: *Driver, recorder: ?*Recorder, file: usize) !void {
        try self.closeReviewSearch();
        try self.send(.{ .action = .open_file_finder });
        for (0..file) |_| try self.ui().dispatch(.{ .key = .{ .codepoint = keymap.special.down } });
        const begin = self.beginSpan();
        try self.send(.{ .key = .{ .codepoint = keymap.special.enter } });
        try self.waitUntil(FileShown{ .file = file });
        try self.finishJump(recorder, begin, file);
    }

    /// Returns false when `next_file` finds no next File.
    fn nextFileJump(self: *Driver, recorder: *Recorder) !bool {
        const before = self.activeFile();
        const begin = self.beginSpan();
        try self.send(.{ .action = .next_file });
        if (self.ui().published.?.pending_view == null and self.activeFile() == before) return false;
        try self.waitUntil(MovedFrom{ .before = before });
        try self.finishJump(recorder, begin, self.activeFile().?);
        return true;
    }

    fn finishJump(self: *Driver, recorder: ?*Recorder, begin: u64, file: usize) !void {
        const latency = self.env.clock.now() -| begin;
        if (recorder) |target| try target.samples.append(self.env.gpa, .{ .kind = .file_jump, .latency_ns = latency, .class = self.classify(file) });
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
    for (0..200) |_| try driver.finderJump(recorder, prng.random().uintLessThan(usize, driver.file_count));
}

fn firstReviewSearch(driver: *Driver, recorder: *Recorder) !void {
    const begin = driver.beginSpan();
    try driver.openReviewSearch();
    try driver.recordSearch(recorder, begin, true);
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
        const begin = driver.beginSpan();
        for (inputs) |input| try driver.send(input);
        try driver.recordSearch(recorder, begin, false);
    }
}

fn overlayReopen(driver: *Driver, recorder: *Recorder) !void {
    try driver.ensureReviewSearch();
    try driver.closeReviewSearch();
    var prng = std.Random.DefaultPrng.init(driver.options.seed);
    for (0..10) |_| try driver.finderJump(null, prng.random().uintLessThan(usize, driver.file_count));
    const begin = driver.beginSpan();
    try driver.openReviewSearch();
    try driver.recordSearch(recorder, begin, false);
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
        for (0..replacement_jumps) |_| try driver.finderJump(recorder, files[prng.random().uintLessThan(usize, files.len)]);
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

const ScenarioLine = struct {
    run_label: []const u8,
    pull_request: []const u8,
    scenario: Scenario,
    refetches: usize,
    added_delay_p95_ms: f64,
    complete_result_ms: ?f64,

    fn parse(line: []const u8) !?ScenarioLine {
        if (!std.mem.startsWith(u8, line, "scenario=")) return null;
        var parsed: ScenarioLine = .{ .run_label = "", .pull_request = "", .scenario = .s1, .refetches = 0, .added_delay_p95_ms = 0, .complete_result_ms = null };
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| {
            const split = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidLine;
            const key = token[0..split];
            const value = token[split + 1 ..];
            if (std.mem.eql(u8, key, "scenario")) parsed.scenario = std.meta.stringToEnum(Scenario, value) orelse return error.InvalidLine;
            if (std.mem.eql(u8, key, "run_label")) parsed.run_label = value;
            if (std.mem.eql(u8, key, "pull_request")) parsed.pull_request = value;
            if (std.mem.eql(u8, key, "refetches")) parsed.refetches = try std.fmt.parseInt(usize, value, 10);
            if (std.mem.eql(u8, key, "added_delay_p95_ms")) parsed.added_delay_p95_ms = try std.fmt.parseFloat(f64, value);
            if (std.mem.eql(u8, key, "complete_result_ms")) parsed.complete_result_ms = try std.fmt.parseFloat(f64, value);
        }
        return parsed;
    }
};

/// Reads the scenario lines of two or three runs and prints the stop rule outcome.
pub fn summarize(allocator: Allocator, text: []const u8, out: *std.Io.Writer) !void {
    var lines: std.ArrayList(ScenarioLine) = .empty;
    defer lines.deinit(allocator);
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);
    var rows = std.mem.tokenizeScalar(u8, text, '\n');
    while (rows.next()) |row| {
        const line = try ScenarioLine.parse(std.mem.trimEnd(u8, row, "\r")) orelse continue;
        try lines.append(allocator, line);
        for (labels.items) |known| {
            if (std.mem.eql(u8, known, line.run_label)) break;
        } else try labels.append(allocator, line.run_label);
    }
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

fn runCauses(lines: []const ScenarioLine, run_label: []const u8) std.EnumSet(Cause) {
    var causes: std.EnumSet(Cause) = .initEmpty();
    for (lines) |line| if (std.mem.eql(u8, line.run_label, run_label)) {
        if (line.added_delay_p95_ms > delay_threshold_ms) causes.insert(causeOf(line.scenario));
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

const FakeClock = struct {
    time: std.atomic.Value(u64) = .init(0),
    step_ns: u64 = 0,

    fn clock(self: *FakeClock) Clock {
        return .{ .ptr = self, .vtable = &.{ .now = now, .sleep = sleep } };
    }

    fn now(ptr: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.time.fetchAdd(self.step_ns, .monotonic);
    }

    fn sleep(ptr: *anyopaque, ns: u64) void {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        _ = self.time.fetchAdd(ns, .monotonic);
    }
};

const FakeTransport = struct {
    fake: *bbr.http.FakeHttpClient,

    fn transport(self: *FakeTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .open = open, .close = close } };
    }

    fn open(ptr: *anyopaque) anyerror!bbr.http.HttpClient {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        return self.fake.httpClient();
    }

    fn close(_: *anyopaque) void {}
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

const fixture_diff =
    "diff --git a/PATHSENTINEL/a.zig b/PATHSENTINEL/a.zig\n--- a/PATHSENTINEL/a.zig\n+++ b/PATHSENTINEL/a.zig\n" ++
    "@@ -1,2 +1,2 @@\n-old SRCSENTINEL\n+qrysentinel new SRCSENTINEL\n keep\n" ++
    "diff --git a/PATHSENTINEL/b.zig b/PATHSENTINEL/b.zig\n--- a/PATHSENTINEL/b.zig\n+++ b/PATHSENTINEL/b.zig\n" ++
    "@@ -1,2 +1,2 @@\n-old SRCSENTINEL\n+qrysentinel new SRCSENTINEL\n keep\n" ++
    "diff --git a/PATHSENTINEL/c.zig b/PATHSENTINEL/c.zig\nnew file mode 100644\n--- /dev/null\n+++ b/PATHSENTINEL/c.zig\n" ++
    "@@ -0,0 +1,2 @@\n+qrysentinel added SRCSENTINEL\n+tail\n" ++
    "diff --git a/PATHSENTINEL/d.zig b/PATHSENTINEL/d.zig\ndeleted file mode 100644\n--- a/PATHSENTINEL/d.zig\n+++ /dev/null\n" ++
    "@@ -1,2 +0,0 @@\n-qrysentinel removed SRCSENTINEL\n-tail\n" ++
    "diff --git a/PATHSENTINEL/e.png b/PATHSENTINEL/e.png\nindex 1111111..2222222 100644\n" ++
    "Binary files a/PATHSENTINEL/e.png and b/PATHSENTINEL/e.png differ\n" ++
    "diff --git a/PATHSENTINEL/f.zig b/PATHSENTINEL/f.zig\n--- a/PATHSENTINEL/f.zig\n+++ b/PATHSENTINEL/f.zig\n" ++
    "@@ -1,2 +1,2 @@\n-old SRCSENTINEL\n+qrysentinel new SRCSENTINEL\n keep\n";

const old_blob = "old SRCSENTINEL\nkeep\n";
const new_blob = "qrysentinel new SRCSENTINEL\nkeep\n";

fn fixtureResponses(comptime blob_b_new: bbr.http.Canned) [12]bbr.http.Canned {
    return .{
        .{ .request_key = "/src/bbbb/PATHSENTINEL/a.zig", .body = old_blob },
        .{ .request_key = "/src/aaaa/PATHSENTINEL/a.zig", .body = new_blob },
        .{ .request_key = "/src/bbbb/PATHSENTINEL/b.zig", .body = old_blob },
        blob_b_new,
        .{ .request_key = "/src/aaaa/PATHSENTINEL/c.zig", .body = "qrysentinel added SRCSENTINEL\ntail\n" },
        .{ .request_key = "/src/bbbb/PATHSENTINEL/d.zig", .body = "qrysentinel removed SRCSENTINEL\ntail\n" },
        .{ .request_key = "/src/bbbb/PATHSENTINEL/f.zig", .body = old_blob },
        .{ .request_key = "/src/aaaa/PATHSENTINEL/f.zig", .body = new_blob },
        .{ .request_key = "/pullrequests/7/diff", .body = fixture_diff },
        .{ .request_key = "/pullrequests/7/comments", .body = fixture_comments },
        .{ .request_key = "/pullrequests/7", .body = fixture_pull_request },
        .{ .request_key = "/user", .body = "{ \"uuid\": \"{ada}\" }" },
    };
}

const matching_b: bbr.http.Canned = .{ .request_key = "/src/aaaa/PATHSENTINEL/b.zig", .body = new_blob };

const fixture_options: Options = .{ .dwell_ms = 0, .query = "qrysentinel", .second_query = "qrytwo", .run_label = "fixture" };

/// Runs the chain on the fixture and returns the printed output.
fn runFixture(responses: []const bbr.http.Canned, options: Options, clock: *FakeClock) ![]u8 {
    var fake: bbr.http.FakeHttpClient = .{ .responses = responses };
    var transport: FakeTransport = .{ .fake = &fake };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    try run(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .clock = clock.clock(),
        .transport = transport.transport(),
        .credential = .{ .username = "u", .token = "t", .workspace = "ws" },
        .highlighter = plain.highlighter(),
        .bbr_version = "test",
        .out = &output.writer,
    }, options, "repo", 7);
    return output.toOwnedSlice();
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
    // The first fetch of a File is cold.
    try testing.expect(try intField(output, "scenario=s1 ", "cold_fetches") > 0);
    // S2 revisits the four text Files that S1 left, and the budget evicted them. The binary File never fetches.
    try testing.expectEqual(@as(usize, 4), try intField(output, "scenario=s2 ", "refetches"));
    try testing.expectEqual(@as(usize, 1), try intField(output, "scenario=s2 ", "hits"));
    try testing.expect(try intField(output, "scenario=s5 ", "refetches") > 0);
    try testing.expect(try intField(output, "scenario=s6 ", "refetches") > 0);
    // After refresh and after the restart, every fetch is of an admitted File.
    for ([_][]const u8{ "scenario=s7 ", "scenario=s8 " }) |prefix| {
        try testing.expect(try intField(output, prefix, "refetches") > 0);
        try testing.expectEqual(@as(usize, 0), try intField(output, prefix, "cold_fetches"));
    }
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
    const responses = fixtureResponses(.{ .request_key = "/src/aaaa/PATHSENTINEL/b.zig", .status = 429, .retry_after_ms = 1 });
    var clock: FakeClock = .{};
    var options = fixture_options;
    options.scenarios = .initOne(.s1);
    const output = try runFixture(&responses, options, &clock);
    defer testing.allocator.free(output);
    // S1 fetches b.zig once. RemoteBlobSource retries the new side once.
    try testing.expectEqual(@as(usize, 2), try intField(output, "scenario=s1 ", "rate_limited"));
    try testing.expectEqual(@as(usize, 0), try intField(output, "scenario=s1 ", "failures"));
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
    const changed = fixtureResponses(.{ .request_key = "/src/aaaa/PATHSENTINEL/b.zig", .body = "qrysentinel CHANGED SRCSENTINEL\nkeep\n" });
    const mismatch = try runFixture(&changed, options, &clock);
    defer testing.allocator.free(mismatch);
    try testing.expectEqual(@as(usize, 1), try intField(mismatch, "check", "hunk_mismatch_files"));
}

test "M28 cache the request budget waits before a scenario and never inside a measured span" {
    const responses = fixtureResponses(matching_b);
    // The clock moves only when the harness sleeps, so a wait inside a span would show as latency.
    var clock: FakeClock = .{};
    var options = fixture_options;
    options.hourly_request_budget = 20;
    options.scenarios = .initMany(&.{ .s1, .s2 });
    const output = try runFixture(&responses, withBudget(options, 1), &clock);
    defer testing.allocator.free(output);
    try testing.expect(clock.time.load(.monotonic) >= hour_ns);
    for ([_][]const u8{ "scenario=s1 ", "scenario=s2 " }) |prefix| {
        try testing.expect(try intField(output, prefix, "samples") > 0);
        try testing.expectEqualStrings("0.0", try field(output, prefix, "latency_p95_ms"));
    }
}

test "M28 cache a scenario subset keeps the scenarios that it depends on" {
    for ([_][]const u8{ "s1,s2,s3", "s4,s5,s6,s7,s8", "s1,s7", "s3", "s5,s6" }) |subset|
        _ = try Options.parse(&.{ "--scenarios", subset });
    for ([_][]const u8{ "s2", "s2,s3", "s7", "s8", "s5,s6,s7,s8" }) |subset|
        try testing.expectError(error.InvalidArguments, Options.parse(&.{ "--scenarios", subset }));
}

test "M28 cache an estimate above the budget waits for an empty hour" {
    var clock: FakeClock = .{};
    var budget: RequestBudget = .{ .clock = clock.clock(), .hourly = 5 };
    defer budget.deinit();
    for ([_]u64{ 0, 10, 20 }) |at| try budget.record(at);
    clock.time.store(30, .monotonic);
    budget.waitBefore(2);
    try testing.expectEqual(@as(u64, 30), clock.time.load(.monotonic));
    budget.waitBefore(6);
    try testing.expectEqual(20 + hour_ns, clock.time.load(.monotonic));
}

test "M28 cache an unsupported command kind fails the run and names the kind" {
    const responses = fixtureResponses(matching_b);
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    var transport: FakeTransport = .{ .fake = &fake };
    var plain: bbr.highlight.PlainHighlighter = .{};
    var clock: FakeClock = .{};
    var budget: RequestBudget = .{ .clock = clock.clock(), .hourly = 900 };
    defer budget.deinit();
    var measuring: MeasuringHttpClient = .{ .inner = try transport.transport().open(), .clock = clock.clock(), .budget = &budget };
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

test "M28 cache benchmark output holds no source, path, query, or Comment text" {
    const responses = fixtureResponses(matching_b);
    var clock: FakeClock = .{ .step_ns = 1000 };
    var options = withBudget(fixture_options, 1);
    options.network_label = "office";
    const output = try runFixture(&responses, options, &clock);
    defer testing.allocator.free(output);
    try testing.expect(try intField(output, "scenario=s4 ", "samples") > 0);
    for ([_][]const u8{ "SRCSENTINEL", "PATHSENTINEL", "qrysentinel", "qrytwo", "CMTSENTINEL", "TITLESENTINEL", "/src/", "repo" }) |forbidden|
        try testing.expect(std.mem.indexOf(u8, output, forbidden) == null);
}

fn summaryText(input: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    try summarize(testing.allocator, input, &output.writer);
    return output.toOwnedSlice();
}

const quiet_run =
    "scenario=s2 run_label={s} pull_request=12 refetches=3 added_delay_p95_ms=120.0\n" ++
    "scenario=s4 run_label={s} pull_request=12 refetches=0 added_delay_p95_ms=0.0 complete_result_ms=900.0\n" ++
    "scenario=s5 run_label={s} pull_request=12 refetches=0 added_delay_p95_ms=0.0 complete_result_ms=100.0\n" ++
    "scenario=s6 run_label={s} pull_request=12 refetches=0 added_delay_p95_ms=0.0 complete_result_ms=700.0\n";
const slow_run = "scenario=s3 run_label={s} pull_request=12 refetches=40 added_delay_p95_ms=450.0\n";

test "M28 cache summarize gives No delay, Delay, and Inconclusive" {
    const cases = [_]struct { input: []const u8, outcome: []const u8 }{
        .{ .input = std.fmt.comptimePrint(quiet_run, .{ "a", "a", "a", "a" }) ++ std.fmt.comptimePrint(quiet_run, .{ "b", "b", "b", "b" }), .outcome = "outcome=No delay scenarios=none\n" },
        .{ .input = std.fmt.comptimePrint(slow_run, .{"a"}) ++ std.fmt.comptimePrint(slow_run, .{"b"}), .outcome = "outcome=Delay scenarios=s3\n" },
        .{ .input = std.fmt.comptimePrint(slow_run, .{"a"}) ++ std.fmt.comptimePrint(quiet_run, .{ "b", "b", "b", "b" }), .outcome = "outcome=Inconclusive scenarios=s3\n" },
        .{ .input = std.fmt.comptimePrint(slow_run, .{"a"}) ++ std.fmt.comptimePrint(quiet_run, .{ "b", "b", "b", "b" }) ++ std.fmt.comptimePrint(slow_run, .{"c"}), .outcome = "outcome=Delay scenarios=s3\n" },
    };
    for (cases) |case| {
        const text = try summaryText(case.input);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.endsWith(u8, text, case.outcome));
    }
}

test "M28 cache summarize treats one refetch in S5 or S6 as a delay" {
    const s5 = "scenario=s5 run_label={s} pull_request=12 refetches=1 added_delay_p95_ms=2.0 complete_result_ms=30.0\n";
    const s6 = "scenario=s6 run_label={s} pull_request=12 refetches=1 added_delay_p95_ms=2.0 complete_result_ms=30.0\n";
    for ([_][]const u8{ std.fmt.comptimePrint(s5, .{"a"}) ++ std.fmt.comptimePrint(s5, .{"b"}), std.fmt.comptimePrint(s6, .{"a"}) ++ std.fmt.comptimePrint(s6, .{"b"}) }) |input| {
        const text = try summaryText(input);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "outcome=Delay scenarios=s") != null);
    }
}

test "M28 cache summarize reports the restart Review Search delay only when S6 has no refetch" {
    const run_lines =
        "scenario=s4 run_label={s} pull_request=12 refetches=0 added_delay_p95_ms=0.0 complete_result_ms=900.0\n" ++
        "scenario=s6 run_label={s} pull_request=12 refetches=0 added_delay_p95_ms=0.0 complete_result_ms=100.0\n";
    const text = try summaryText(std.fmt.comptimePrint(run_lines, .{ "a", "a" }) ++ std.fmt.comptimePrint(run_lines, .{ "b", "b" }));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "outcome=Delay scenarios=restart_review_search\n"));
}
