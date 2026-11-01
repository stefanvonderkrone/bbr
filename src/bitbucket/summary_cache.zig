//! The Summary Cache: the local file of Repository Summaries and PullRequest
//! Summaries for one account and one Workspace. This module is pure. It
//! encodes and decodes the file, and the adapter reads and writes it.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
pub const RepositorySummary = types.RepositorySummary;
pub const PullRequestSummary = types.PullRequestSummary;

pub const version: u32 = 2;
/// `decode` refuses a larger file.
pub const max_bytes: usize = 16 * 1024 * 1024;

/// The SHA-256 digest of the Credential email, in lowercase hex. Another
/// account can lack access to the cached Repositories, so the file names its
/// account without the email itself.
pub const Account = struct {
    hex: [64]u8,

    pub fn of(email: []const u8) Account {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(email, &digest, .{});
        return .{ .hex = std.fmt.bytesToHex(digest, .lower) };
    }
};

pub const Repository = struct {
    summary: RepositorySummary,
    /// Null when bbr never loaded the PullRequests of this Repository.
    pull_requests: ?[]const PullRequestSummary,
};

pub const Snapshot = struct {
    workspace: []const u8,
    repositories: []const Repository,
};

const FileRecord = struct {
    version: u32,
    account: []const u8,
    workspace: []const u8,
    repositories: []const RepositoryRecord,
};

const RepositoryRecord = struct {
    slug: []const u8,
    name: []const u8,
    updated_on: ?i64,
    pull_requests: ?[]const PullRequestRecord,
};

const PullRequestRecord = struct {
    id: u64,
    title: []const u8,
    author: []const u8,
    updated_on: ?i64,
    source: []const u8,
    destination: []const u8,
    approvals: u32,
    changes_requested: u32,
};

/// Every JSON key that the file can hold. A record field outside this list is
/// a compile error, so no Credential, description, Comment, or URL gets in.
const allowlist = .{
    .{ FileRecord, .{ "version", "account", "workspace", "repositories" } },
    .{ RepositoryRecord, .{ "slug", "name", "updated_on", "pull_requests" } },
    .{ PullRequestRecord, .{ "id", "title", "author", "updated_on", "source", "destination", "approvals", "changes_requested" } },
};

comptime {
    for (allowlist) |entry| {
        for (@typeInfo(entry[0]).@"struct".fields) |field| {
            if (!allowed(entry[1], field.name)) @compileError(@typeName(entry[0]) ++ "." ++ field.name ++
                " is not in the Summary Cache allowlist. The Summary Cache holds only Repository Summary and PullRequest Summary fields.");
        }
    }
}

fn allowed(comptime names: anytype, name: []const u8) bool {
    inline for (names) |allowed_name| if (std.mem.eql(u8, allowed_name, name)) return true;
    return false;
}

/// Writes the Snapshot of `account` as JSON. The caller owns the bytes.
pub fn encode(allocator: Allocator, account: Account, snapshot: Snapshot) Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repositories = try a.alloc(RepositoryRecord, snapshot.repositories.len);
    for (snapshot.repositories, repositories) |repository, *record| {
        record.* = .{
            .slug = repository.summary.slug,
            .name = repository.summary.name,
            .updated_on = repository.summary.updated_on,
            .pull_requests = null,
        };
        const prs = repository.pull_requests orelse continue;
        const records = try a.alloc(PullRequestRecord, prs.len);
        for (prs, records) |pr, *pr_record| pr_record.* = .{
            .id = pr.id,
            .title = pr.title,
            .author = pr.author_display_name,
            .updated_on = pr.updated_on,
            .source = pr.source_branch,
            .destination = pr.destination_branch,
            .approvals = pr.approval_count,
            .changes_requested = pr.changes_requested_count,
        };
        record.pull_requests = records;
    }
    return std.json.Stringify.valueAlloc(allocator, FileRecord{
        .version = version,
        .account = &account.hex,
        .workspace = snapshot.workspace,
        .repositories = repositories,
    }, .{});
}

/// Reads the Snapshot of `account` into `arena`. Returns null for every parse
/// error, a wrong version, another account, and input larger than
/// `max_bytes`. The Snapshot does not borrow `bytes`.
pub fn decode(arena: Allocator, bytes: []const u8, account: Account) ?Snapshot {
    if (bytes.len > max_bytes) return null;
    const file = std.json.parseFromSliceLeaky(FileRecord, arena, bytes, .{ .allocate = .alloc_always }) catch return null;
    _ = account;
    if (file.version != version) return null;
    const repositories = arena.alloc(Repository, file.repositories.len) catch return null;
    for (file.repositories, repositories) |record, *repository| {
        repository.* = .{
            .summary = .{ .slug = record.slug, .name = record.name, .updated_on = record.updated_on },
            .pull_requests = null,
        };
        const records = record.pull_requests orelse continue;
        const prs = arena.alloc(PullRequestSummary, records.len) catch return null;
        for (records, prs) |pr_record, *pr| pr.* = .{
            .id = pr_record.id,
            .title = pr_record.title,
            // The Browser lists only open PullRequests.
            .state = "OPEN",
            .author_display_name = pr_record.author,
            .source_branch = pr_record.source,
            .destination_branch = pr_record.destination,
            .updated_on = pr_record.updated_on,
            .approval_count = pr_record.approvals,
            .changes_requested_count = pr_record.changes_requested,
        };
        repository.pull_requests = prs;
    }
    return .{ .workspace = file.workspace, .repositories = repositories };
}

const testing = std.testing;

const test_prs = [_]PullRequestSummary{
    .{ .id = 1726, .title = "Fix the cart", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/cart", .destination_branch = "main", .updated_on = 1761720000, .approval_count = 1, .changes_requested_count = 0 },
    .{ .id = 9, .title = "Quote \"this\"", .state = "OPEN", .author_display_name = "Bo", .source_branch = "b", .destination_branch = "main", .updated_on = null, .approval_count = 0, .changes_requested_count = 2 },
};

const test_snapshot: Snapshot = .{
    .workspace = "check24",
    .repositories = &.{
        .{ .summary = .{ .slug = "pr-webapp", .name = "PR Webapp", .updated_on = 1761730000 }, .pull_requests = &test_prs },
        .{ .summary = .{ .slug = "api", .name = "API", .updated_on = null }, .pull_requests = null },
        .{ .summary = .{ .slug = "empty", .name = "Empty", .updated_on = 1 }, .pull_requests = &.{} },
    },
};

const test_email = "ada@example.com";

test "M24 cache encode then decode returns an equal Snapshot" {
    const account: Account = .of(test_email);
    const bytes = try encode(testing.allocator, account, test_snapshot);
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = decode(arena.allocator(), bytes, account).?;
    try testing.expectEqualDeep(test_snapshot, decoded);
}

test "M24 cache decode returns null for truncated JSON, a wrong version, another account, and an oversized file" {
    const account: Account = .of(test_email);
    const bytes = try encode(testing.allocator, account, test_snapshot);
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(decode(a, bytes[0 .. bytes.len - 1], account) == null);
    try testing.expect(decode(a, "", account) == null);
    try testing.expect(decode(a, bytes, .of("bo@example.com")) == null);
    try testing.expect(decode(a, "{\"version\":1,\"workspace\":\"check24\",\"repositories\":[]}", account) == null);
    const valid = try std.fmt.allocPrint(a, "{{\"version\":2,\"account\":\"{s}\",\"workspace\":\"check24\",\"repositories\":[]}}", .{&account.hex});
    try testing.expect(decode(a, valid, account) != null);
    const with_token = try std.fmt.allocPrint(a, "{s},\"token\":\"x\"}}", .{valid[0 .. valid.len - 1]});
    try testing.expect(decode(a, with_token, account) == null);

    const oversized = try testing.allocator.alloc(u8, max_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0..valid.len], valid);
    try testing.expect(decode(a, oversized, account) == null);
}

fn expectAllowedKeys(value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                var known = false;
                inline for (allowlist) |list| known = known or allowed(list[1], entry.key_ptr.*);
                if (!known) {
                    std.debug.print("Summary Cache key outside the allowlist: {s}\n", .{entry.key_ptr.*});
                    return error.UnexpectedKey;
                }
                try expectAllowedKeys(entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |item| try expectAllowedKeys(item),
        else => {},
    }
}

test "M24 cache a saved Summary Cache holds no Credential or description" {
    const bytes = try encode(testing.allocator, .of(test_email), test_snapshot);
    defer testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try expectAllowedKeys(parsed.value);
    inline for (.{ "token", "password", "username", "description", "http", "comment", test_email }) |word| {
        try testing.expect(std.ascii.indexOfIgnoreCase(bytes, word) == null);
    }
}
