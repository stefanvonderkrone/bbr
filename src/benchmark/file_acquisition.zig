const std = @import("std");
const bbr = @import("bbr");
const file_enrichment = @import("file_enrichment");

const sample_count = 5;
const limits = [_]usize{ 1, 2, 4, 8 };

const Fixture = struct {
    name: []const u8,
    diff: bbr.diff.Diff,
    source_commit: []const u8,
    destination_commit: []const u8,
    source: file_enrichment.BlobSource,
    remote: bool,
    repo: []const u8 = "",
};

const Sample = struct {
    first_file_ms: u64,
    complete_ms: u64,
    max_reads: usize,
    failures: usize,
    rate_limited: usize,
    retained_bytes: usize,
};

const Completion = struct {
    file_index: usize,
    outcome: union(enum) {
        completed: file_enrichment.Result,
        failed: anyerror,
    },
};

const CountingSource = struct {
    inner: file_enrichment.BlobSource,
    active: std.atomic.Value(usize) = .init(0),
    max_active: std.atomic.Value(usize) = .init(0),

    fn source(self: *CountingSource) file_enrichment.BlobSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, commit: []const u8, path: []const u8) anyerror![]u8 {
        const self: *CountingSource = @ptrCast(@alignCast(ptr));
        const active = self.active.fetchAdd(1, .acq_rel) + 1;
        defer _ = self.active.fetchSub(1, .acq_rel);
        var previous = self.max_active.load(.monotonic);
        while (active > previous) {
            previous = self.max_active.cmpxchgWeak(previous, active, .release, .monotonic) orelse break;
        }
        return self.inner.read(allocator, commit, path);
    }
};

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const kind = arguments.next() orelse return usage();

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (std.mem.eql(u8, kind, "remote")) {
        const repo = arguments.next() orelse return usage();
        const id = std.fmt.parseInt(u64, arguments.next() orelse return usage(), 10) catch return usage();
        if (arguments.next() != null) return usage();
        var owned = bbr.bitbucket.auth.resolve(allocator, init.io, init.environ_map, null) catch return error.MissingCredential;
        defer owned.deinit(allocator);
        const credential = owned.credential();
        var transport = bbr.http.StdHttpClient.init(std.heap.page_allocator, init.io);
        defer transport.deinit();
        try transport.initDefaultProxies(allocator, init.environ_map);
        const client = bbr.bitbucket.Client.init(transport.httpClient(), credential);
        const pull_request = try client.getPullRequest(allocator, repo, id);
        const raw_diff = try client.getDiff(allocator, repo, id);
        const diff = try bbr.diff.parse(allocator, raw_diff);
        var remote_source: file_enrichment.RemoteBlobSource = .{ .client = client, .repo = repo };
        const name = try std.fmt.allocPrint(allocator, "{s} PullRequest {d}", .{ repo, id });
        try runFixture(init.io, allocator, .{
            .name = name,
            .diff = diff,
            .source_commit = pull_request.source_commit,
            .destination_commit = pull_request.destination_commit,
            .source = remote_source.source(),
            .remote = true,
            .repo = repo,
        });
        return;
    }

    if (std.mem.eql(u8, kind, "local")) {
        const base_ref = arguments.next() orelse return usage();
        const source_ref = arguments.next() orelse return usage();
        if (arguments.next() != null) return usage();
        var git = bbr.git.ShellGitClient.init(std.heap.page_allocator, init.io);
        const base = try git.gitClient().resolveRef(allocator, base_ref);
        const source = try git.gitClient().resolveRef(allocator, source_ref);
        const raw_diff = try git.gitClient().diff(allocator, base.commit, source.commit);
        const diff = try bbr.diff.parse(allocator, raw_diff);
        var git_source: file_enrichment.GitBlobSource = .{ .client = git.gitClient() };
        const name = try std.fmt.allocPrint(allocator, "LocalReview {s}..{s}", .{ base_ref, source_ref });
        try runFixture(init.io, allocator, .{
            .name = name,
            .diff = diff,
            .source_commit = source.commit,
            .destination_commit = base.commit,
            .source = git_source.source(),
            .remote = false,
        });
        return;
    }

    return usage();
}

fn runFixture(io: std.Io, allocator: std.mem.Allocator, fixture: Fixture) !void {
    const order = try allocator.alloc(usize, fixture.diff.files.len);
    for (order, 0..) |*file_index, index| file_index.* = index;
    std.mem.sort(usize, order, fixture.diff.files, lessThanFilePath);

    const samples_per_limit: usize = if (fixture.remote) 3 else sample_count;
    var samples: [limits.len][sample_count]Sample = undefined;
    var run_count: usize = 0;
    for (0..samples_per_limit) |sample_index| {
        for (0..limits.len) |offset| {
            const limit_index = (sample_index + offset) % limits.len;
            samples[limit_index][sample_index] = try runSample(io, allocator, fixture, order, limits[limit_index]);
            run_count += 1;
            if (fixture.remote and run_count < samples_per_limit * limits.len)
                io.sleep(std.Io.Duration.fromSeconds(10), .awake) catch return error.SleepFailed;
        }
    }

    std.debug.print("fixture={s} files={d} samples={d}\n", .{ fixture.name, fixture.diff.files.len, samples_per_limit });
    std.debug.print("limit first_file_ms complete_ms max_reads failures rate_limited retained_bytes\n", .{});
    for (limits, 0..) |limit, limit_index| {
        const limit_samples = samples[limit_index][0..samples_per_limit];
        const first = medianField(limit_samples, .first_file_ms);
        const complete = medianField(limit_samples, .complete_ms);
        const retained = medianField(limit_samples, .retained_bytes);
        var max_reads: usize = 0;
        var failures: usize = 0;
        var rate_limited: usize = 0;
        for (limit_samples) |sample| {
            max_reads = @max(max_reads, sample.max_reads);
            failures += sample.failures;
            rate_limited += sample.rate_limited;
        }
        std.debug.print("{d} {d} {d} {d} {d} {d} {d}\n", .{ limit, first, complete, max_reads, failures, rate_limited, retained });
    }
}

fn runSample(io: std.Io, allocator: std.mem.Allocator, fixture: Fixture, order: []const usize, limit: usize) !Sample {
    var storage = try file_enrichment.Storage.init(allocator, fixture.diff.files);
    defer storage.deinit();
    var plain: bbr.highlight.PlainHighlighter = .{};
    var counting_source: CountingSource = .{ .inner = fixture.source };

    const Selected = union(enum) { file: Completion };
    var completion_buffer: [limits[limits.len - 1]]Selected = undefined;
    var select = std.Io.Select(Selected).init(io, &completion_buffer);
    defer select.group.await(io) catch {};
    const start = std.Io.Clock.awake.now(io);
    var first_file_ms: u64 = 0;
    var next: usize = 0;
    var active: usize = 0;
    var completed: usize = 0;
    var failures: usize = 0;
    var rate_limited: usize = 0;

    while (active < limit and next < order.len) : (next += 1) {
        const file_index = order[next];
        try select.concurrent(.file, enrichFile, .{ io, fixture, counting_source.source(), plain.highlighter(), file_index });
        active += 1;
    }
    while (active > 0) {
        const completion = (try select.await()).file;
        active -= 1;
        completed += 1;
        if (completed == 1) first_file_ms = elapsedMs(start, io);
        switch (completion.outcome) {
            .completed => |result_value| {
                var result = result_value;
                defer result.deinit();
                try storage.admit(completion.file_index, &result);
                const view = storage.file(completion.file_index);
                countFailure(view.old, &failures, &rate_limited);
                countFailure(view.new, &failures, &rate_limited);
            },
            .failed => |err| {
                failures += 1;
                if (err == error.RateLimited) rate_limited += 1;
            },
        }
        if (next < order.len) {
            const file_index = order[next];
            next += 1;
            try select.concurrent(.file, enrichFile, .{ io, fixture, counting_source.source(), plain.highlighter(), file_index });
            active += 1;
        }
    }

    return .{
        .first_file_ms = first_file_ms,
        .complete_ms = elapsedMs(start, io),
        .max_reads = counting_source.max_active.load(.acquire),
        .failures = failures,
        .rate_limited = rate_limited,
        .retained_bytes = storage.retainedBytes(),
    };
}

fn enrichFile(io: std.Io, fixture: Fixture, source: file_enrichment.BlobSource, highlighter: bbr.highlight.Highlighter, file_index: usize) Completion {
    const file = fixture.diff.files[file_index];
    const request: file_enrichment.Request = .{
        .repo = fixture.repo,
        .status = file.status,
        .source_commit = fixture.source_commit,
        .destination_commit = fixture.destination_commit,
        .old_path = file.old_path,
        .new_path = file.new_path,
        .max_file_bytes = 0,
        .content = file.content,
    };
    const result = if (fixture.remote)
        file_enrichment.enrichFromConcurrent(io, std.heap.page_allocator, source, highlighter, request)
    else
        file_enrichment.enrichFrom(std.heap.page_allocator, source, highlighter, request);
    return .{
        .file_index = file_index,
        .outcome = if (result) |completed| .{ .completed = completed } else |err| .{ .failed = err },
    };
}

fn lessThanFilePath(files: []const bbr.diff.File, lhs: usize, rhs: usize) bool {
    return std.mem.lessThan(u8, files[lhs].displayPath(), files[rhs].displayPath());
}

fn countFailure(side: file_enrichment.SideView, failures: *usize, rate_limited: *usize) void {
    if (side == .fetch_failed) {
        failures.* += 1;
        if (side.fetch_failed == error.RateLimited) rate_limited.* += 1;
    }
}

fn elapsedMs(start: std.Io.Timestamp, io: std.Io) u64 {
    return @intCast(@divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_ms));
}

fn medianField(samples: []const Sample, comptime field: std.meta.FieldEnum(Sample)) usize {
    var values: [sample_count]usize = undefined;
    for (samples, 0..) |sample, index| values[index] = @intCast(@field(sample, @tagName(field)));
    std.mem.sort(usize, values[0..samples.len], {}, std.sort.asc(usize));
    return values[samples.len / 2];
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: zig build bench-file-acquisition -- remote <repository> <pull-request-id>\n" ++
            "       zig build bench-file-acquisition -- local <base-ref> <source-ref>\n",
        .{},
    );
    return error.InvalidArguments;
}
