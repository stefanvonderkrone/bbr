//! `bbr api get-diff | get-compare-diff | get-blob | check-blob`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");

pub const diff_help =
    \\usage: bbr api get-diff --repository SLUG --pull-request-id N [--out PATH] [--json]
    \\
    \\Raw unified diff of a pull request (GET .../pullrequests/{id}/diff).
    \\
;

pub const compare_help =
    \\usage: bbr api get-compare-diff --repository SLUG --from HASH --to HASH [--patch] [--out PATH] [--json]
    \\
    \\Raw diff between two commits (GET .../diff/{from}..{to}).
    \\--patch returns the patch form instead.
    \\
;

pub const blob_help =
    \\usage: bbr api get-blob --repository SLUG --commit HASH --path PATH [--out FILE] [--json]
    \\
;

pub const check_help =
    \\usage: bbr api check-blob --repository SLUG --commit HASH --path PATH [--attributes a,b|-] [--json]
    \\
    \\Verify file metadata (type/path/commit/size/attributes) then report size.
    \\
;

fn parseRepoPr(args: []const []const u8) !struct { repository: []const u8, pr_id: u64, out_path: ?[]const u8 } {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var out_path: ?[]const u8 = null;
    while (cur.next()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "repository")) {
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "out")) {
            out_path = try arg.takeValue(&cur, f);
        } else return error.UnknownFlag;
    }
    return .{
        .repository = repository orelse return error.MissingRequired,
        .pr_id = pr_id orelse return error.MissingRequired,
        .out_path = out_path,
    };
}

pub fn runDiff(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseRepoPr(args);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const raw = try bb.getDiff(arena.allocator(), p.repository, p.pr_id);
    if (json) {
        try out.printJsonFile(init, .{ .repository = p.repository, .pull_request_id = p.pr_id, .diff = raw }, raw, p.out_path);
    } else {
        try out.printRaw(init, raw, p.out_path);
    }
}

fn parseCompareArgs(args: []const []const u8) !struct {
    repository: []const u8,
    from: []const u8,
    to: []const u8,
    patch: bool,
    out_path: ?[]const u8,
} {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var patch = false;
    var out_path: ?[]const u8 = null;
    while (cur.next()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "repository")) {
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "from")) {
            from = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "to")) {
            to = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "patch")) {
            patch = true;
        } else if (std.mem.eql(u8, f.name, "out")) {
            out_path = try arg.takeValue(&cur, f);
        } else return error.UnknownFlag;
    }
    return .{
        .repository = repository orelse return error.MissingRequired,
        .from = from orelse return error.MissingRequired,
        .to = to orelse return error.MissingRequired,
        .patch = patch,
        .out_path = out_path,
    };
}

pub fn runCompare(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseCompareArgs(args);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const raw = try bb.getCompareDiff(arena.allocator(), p.repository, p.from, p.to, p.patch);
    if (json) {
        try out.printJsonFile(init, .{ .repository = p.repository, .from = p.from, .to = p.to, .diff = raw }, raw, p.out_path);
    } else {
        try out.printRaw(init, raw, p.out_path);
    }
}

fn parseBlobArgs(args: []const []const u8, comptime kind: enum { blob, check }) !struct {
    repository: []const u8,
    commit: []const u8,
    path: []const u8,
    out_path: ?[]const u8,
    attributes: ?[]const u8,
} {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var attributes: ?[]const u8 = null;
    while (cur.next()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "repository")) {
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "commit")) {
            commit = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "path")) {
            path = try arg.takeValue(&cur, f);
        } else if (kind == .blob and std.mem.eql(u8, f.name, "out")) {
            out_path = try arg.takeValue(&cur, f);
        } else if (kind == .check and std.mem.eql(u8, f.name, "attributes")) {
            attributes = try arg.takeValue(&cur, f);
        } else return error.UnknownFlag;
    }
    return .{
        .repository = repository orelse return error.MissingRequired,
        .commit = commit orelse return error.MissingRequired,
        .path = path orelse return error.MissingRequired,
        .out_path = out_path,
        .attributes = attributes,
    };
}

pub fn runBlob(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBlobArgs(args, .blob);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const raw = try bb.getFileBlob(arena.allocator(), p.repository, p.commit, p.path);
    if (json) {
        // Bytes may not be UTF-8; report size rather than embedding content.
        try out.printJsonFile(init, .{ .repository = p.repository, .commit = p.commit, .path = p.path, .size = raw.len }, raw, p.out_path);
    } else {
        try out.printRaw(init, raw, p.out_path);
    }
}

pub fn runCheck(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBlobArgs(args, .check);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);
    if (p.attributes) |attrs_s| {
        if (!std.mem.eql(u8, attrs_s, "-")) {
            var it = std.mem.splitScalar(u8, attrs_s, ',');
            while (it.next()) |attr| {
                if (attr.len == 0) return error.BadRequest;
                try list.append(a, attr);
            }
        }
    }
    const checked = try checkBlob(a, bb, p.repository, p.commit, p.path, if (p.attributes != null) list.items else null);
    if (json) {
        if (p.attributes != null) {
            try out.printJson(init, .{ .path = checked.path, .commit = checked.commit, .size = checked.size, .attributes = checked.attributes, .raw = checked.size });
        } else {
            try out.printJson(init, checked);
        }
    } else if (p.attributes) |attrs_s| {
        try out.printLine(init, "ok: {s} size={d} attributes={s}", .{ checked.path, checked.size, attrs_s });
    } else {
        try out.printLine(init, "ok: {s} size={d}", .{ checked.path, checked.size });
    }
}

const CheckedBlob = struct {
    path: []const u8,
    commit: []const u8,
    size: usize,
    attributes: []const []const u8,
};

// Returned slices borrow arguments or the caller's arena.
fn checkBlob(a: std.mem.Allocator, bb: bbr.bitbucket.Client, repository: []const u8, commit: []const u8, path: []const u8, attributes: ?[]const []const u8) !CheckedBlob {
    if (attributes) |expected| {
        const size = try bb.checkFileBlob(a, repository, commit, path, expected);
        return .{ .path = path, .commit = commit, .size = size, .attributes = expected };
    }
    const meta = try bb.getFileMeta(a, repository, commit, path);
    if (!std.mem.eql(u8, meta.path, path)) return error.BlobPathMismatch;
    const hash_len = @min(meta.commit.len, commit.len);
    if (hash_len == 0 or !std.mem.eql(u8, meta.commit[0..hash_len], commit[0..hash_len])) return error.BlobCommitMismatch;
    const raw = try bb.getFileBlob(a, repository, commit, path);
    defer a.free(raw);
    if (meta.size != raw.len) return error.BlobSizeMismatch;
    return .{ .path = meta.path, .commit = meta.commit, .size = meta.size, .attributes = meta.attributes };
}

test "blob check compares raw size with metadata with or without expected attributes" {
    const metadata =
        \\{"type":"commit_file","path":"src/run.sh","commit":{"hash":"abc123"},"size":3,"attributes":["executable"]}
    ;
    const empty_metadata =
        \\{"type":"commit_file","path":"src/run.sh","commit":{"hash":"abc123"},"size":0,"attributes":["executable"]}
    ;
    for ([_]?[]const []const u8{ null, &.{"executable"} }) |attributes| {
        for ([_]struct { meta: []const u8, raw: []const u8, matches: bool }{
            .{ .meta = metadata, .raw = "abc", .matches = true },
            .{ .meta = empty_metadata, .raw = "", .matches = true },
            .{ .meta = metadata, .raw = "", .matches = false },
            .{ .meta = empty_metadata, .raw = "abc", .matches = false },
        }) |case| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const responses = [_]bbr.http.Canned{ .{ .body = case.meta }, .{ .body = case.raw } };
            var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
            const bb: bbr.bitbucket.Client = .{ .http = fake.httpClient(), .cred = .{ .username = "u", .token = "t", .workspace = "ws" } };
            const result = checkBlob(arena.allocator(), bb, "myrepo", "abc123", "src/run.sh", attributes);
            if (case.matches) {
                const checked = try result;
                try std.testing.expectEqual(case.raw.len, checked.size);
                try std.testing.expectEqualStrings("executable", checked.attributes[0]);
            } else {
                try std.testing.expectError(error.BlobSizeMismatch, result);
            }
            try std.testing.expectEqual(@as(usize, 2), fake.call_count);
        }
    }
}

test "blob check rejects incorrect expected attributes before fetching raw bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: bbr.http.FakeHttpClient = .{ .body =
        \\{"type":"commit_file","path":"src/run.sh","commit":{"hash":"abc123"},"size":0,"attributes":["executable"]}
    };
    const bb: bbr.bitbucket.Client = .{ .http = fake.httpClient(), .cred = .{ .username = "u", .token = "t", .workspace = "ws" } };
    try std.testing.expectError(error.BlobAttributesMismatch, checkBlob(arena.allocator(), bb, "myrepo", "abc123", "src/run.sh", &.{}));
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
}

test "blob check without attributes rejects invalid metadata before fetching raw bytes" {
    for ([_]struct { body: []const u8, err: anyerror }{
        .{ .body = "{\"type\":\"commit_directory\",\"path\":\"src/run.sh\",\"commit\":{\"hash\":\"abc123\"},\"size\":0}", .err = error.BlobTypeMismatch },
        .{ .body = "{\"type\":\"commit_file\",\"path\":\"other\",\"commit\":{\"hash\":\"abc123\"},\"size\":0}", .err = error.BlobPathMismatch },
        .{ .body = "{\"type\":\"commit_file\",\"path\":\"src/run.sh\",\"commit\":{\"hash\":\"other\"},\"size\":0}", .err = error.BlobCommitMismatch },
        .{ .body = "{\"type\":\"commit_file\",\"path\":\"src/run.sh\",\"commit\":{\"hash\":\"abc123\"}}", .err = error.MalformedResponse },
        .{ .body = "{\"type\":\"commit_file\",\"path\":\"src/run.sh\",\"commit\":{\"hash\":\"abc123\"},\"size\":-1}", .err = error.MalformedResponse },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: bbr.http.FakeHttpClient = .{ .body = case.body };
        const bb: bbr.bitbucket.Client = .{ .http = fake.httpClient(), .cred = .{ .username = "u", .token = "t", .workspace = "ws" } };
        try std.testing.expectError(case.err, checkBlob(arena.allocator(), bb, "myrepo", "abc123", "src/run.sh", null));
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    }
}

test "blob check command returns size mismatch for human and JSON output" {
    const init: std.process.Init = .{
        .gpa = std.testing.allocator,
        .io = .failing,
        .minimal = undefined,
        .arena = undefined,
        .environ_map = undefined,
        .preopens = undefined,
    };
    for ([_][]const []const u8{
        &.{ "--repository", "myrepo", "--commit", "abc123", "--path", "src/run.sh" },
        &.{ "--attributes", "executable", "--path", "src/run.sh", "--repository", "myrepo", "--commit", "abc123" },
    }) |args| {
        for ([_]bool{ false, true }) |json| {
            const responses = [_]bbr.http.Canned{
                .{ .body = "{\"type\":\"commit_file\",\"path\":\"src/run.sh\",\"commit\":{\"hash\":\"abc123\"},\"size\":3,\"attributes\":[\"executable\"]}" },
                .{ .body = "" },
            };
            var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
            const bb: bbr.bitbucket.Client = .{ .http = fake.httpClient(), .cred = .{ .username = "u", .token = "t", .workspace = "ws" } };
            try std.testing.expectError(error.BlobSizeMismatch, runCheck(init, bb, args, json));
            try std.testing.expectEqual(@as(usize, 2), fake.call_count);
        }
    }
}

test "blob check accepts equivalent nonempty hash prefixes and still checks size" {
    const full_hash = "abc1234567890123456789012345678901234567";
    for ([_]struct { requested: []const u8, returned: []const u8, raw: []const u8 = "abc", err: ?anyerror = null }{
        .{ .requested = "abc123", .returned = full_hash },
        .{ .requested = full_hash, .returned = "abc123" },
        .{ .requested = "abc124", .returned = full_hash, .err = error.BlobCommitMismatch },
        .{ .requested = "", .returned = full_hash, .err = error.BlobCommitMismatch },
        .{ .requested = "abc123", .returned = "", .err = error.BlobCommitMismatch },
        .{ .requested = "", .returned = "", .err = error.BlobCommitMismatch },
        .{ .requested = "abc123", .returned = full_hash, .raw = "", .err = error.BlobSizeMismatch },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const metadata = try std.fmt.allocPrint(a, "{{\"type\":\"commit_file\",\"path\":\"src/run.sh\",\"commit\":{{\"hash\":\"{s}\"}},\"size\":3}}", .{case.returned});
        const responses = [_]bbr.http.Canned{ .{ .body = metadata }, .{ .body = case.raw } };
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const bb: bbr.bitbucket.Client = .{ .http = fake.httpClient(), .cred = .{ .username = "u", .token = "t", .workspace = "ws" } };
        const result = checkBlob(a, bb, "myrepo", case.requested, "src/run.sh", null);
        if (case.err) |err| {
            try std.testing.expectError(err, result);
            try std.testing.expectEqual(@as(usize, if (err == error.BlobCommitMismatch) 1 else 2), fake.call_count);
        } else {
            const checked = try result;
            try std.testing.expectEqualStrings(case.returned, checked.commit);
            try std.testing.expectEqual(@as(usize, 3), checked.size);
            try std.testing.expectEqual(@as(usize, 2), fake.call_count);
        }
    }
}

test "file commands accept output and attributes before or between required flags" {
    for ([_][]const []const u8{
        &.{ "--out=diff.txt", "--pull-request-id", "42", "--repository", "myrepo" },
        &.{ "--repository=myrepo", "--out", "diff.txt", "--pull-request-id=42" },
    }) |args| {
        const p = try parseRepoPr(args);
        try std.testing.expectEqualStrings("myrepo", p.repository);
        try std.testing.expectEqual(@as(u64, 42), p.pr_id);
        try std.testing.expectEqualStrings("diff.txt", p.out_path.?);
    }
    for ([_][]const []const u8{
        &.{ "--out=blob.bin", "--path", "src/run.sh", "--repository", "myrepo", "--commit", "abc123" },
        &.{ "--commit=abc123", "--out", "blob.bin", "--repository=myrepo", "--path=src/run.sh" },
    }) |args| {
        const p = try parseBlobArgs(args, .blob);
        try std.testing.expectEqualStrings("myrepo", p.repository);
        try std.testing.expectEqualStrings("abc123", p.commit);
        try std.testing.expectEqualStrings("src/run.sh", p.path);
        try std.testing.expectEqualStrings("blob.bin", p.out_path.?);
    }
    for ([_][]const []const u8{
        &.{ "--attributes=executable", "--path", "src/run.sh", "--repository", "myrepo", "--commit", "abc123" },
        &.{ "--commit=abc123", "--attributes", "executable", "--repository=myrepo", "--path=src/run.sh" },
    }) |args| {
        const p = try parseBlobArgs(args, .check);
        try std.testing.expectEqualStrings("myrepo", p.repository);
        try std.testing.expectEqualStrings("abc123", p.commit);
        try std.testing.expectEqualStrings("src/run.sh", p.path);
        try std.testing.expectEqualStrings("executable", p.attributes.?);
    }
    const compare = try parseCompareArgs(&.{ "--patch", "--out=diff.txt", "--to", "def456", "--repository=myrepo", "--from", "abc123" });
    try std.testing.expectEqualStrings("myrepo", compare.repository);
    try std.testing.expectEqualStrings("abc123", compare.from);
    try std.testing.expectEqualStrings("def456", compare.to);
    try std.testing.expectEqualStrings("diff.txt", compare.out_path.?);
    try std.testing.expect(compare.patch);
}

test "file commands reject unknown options and missing required flags in any order" {
    try std.testing.expectError(error.UnknownFlag, parseRepoPr(&.{ "--out", "diff.txt", "--unknown" }));
    try std.testing.expectError(error.MissingRequired, parseRepoPr(&.{ "--out", "diff.txt", "--repository", "myrepo" }));
    try std.testing.expectError(error.MissingValue, parseRepoPr(&.{"--out"}));
    try std.testing.expectError(error.UnknownFlag, parseBlobArgs(&.{ "--attributes", "-" }, .blob));
    try std.testing.expectError(error.UnknownFlag, parseBlobArgs(&.{ "--out", "blob.bin" }, .check));
    try std.testing.expectError(error.MissingRequired, parseBlobArgs(&.{ "--out", "blob.bin", "--commit", "abc123", "--repository", "myrepo" }, .blob));
    try std.testing.expectError(error.MissingValue, parseBlobArgs(&.{"--attributes"}, .check));
    try std.testing.expectError(error.UnknownFlag, parseCompareArgs(&.{"--unknown"}));
    try std.testing.expectError(error.MissingRequired, parseCompareArgs(&.{ "--out", "diff.txt", "--to", "def456", "--repository", "myrepo" }));
}

test {
    _ = @import("output.zig");
}
