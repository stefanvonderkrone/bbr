//! `SqliteStore` — the durable `PendingReviewStore` (ADR-0002, ADR-0006). Backed
//! by the vendored SQLite amalgamation, compiled into the executable; the pure
//! `bbr` module never sees C, so its domain tests stay toolchain-free (ADR-0003).
//!
//! One row per Draft, keyed `(workspace, repository, pr_id, local_id)`. `put` is INSERT OR REPLACE,
//! `remove` a keyed DELETE, `load` a per-PR SELECT that dupes every string into
//! the caller's allocator. Schema versioning rides SQLite's `PRAGMA user_version`
//! so migrations are a simple forward switch (see `migrate`).
//!
//! Concurrency: the store is touched only on the main thread (design §10/§11);
//! the amalgamation is compiled `SQLITE_THREADSAFE=0` to match. The Bitbucket
//! token is never written here (design §12) — only Draft prose and anchors.

const std = @import("std");
const bbr = @import("bbr");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const Draft = bbr.review.Draft;
const TempId = bbr.review.TempId;
const DraftKind = bbr.review.DraftKind;
const DraftState = bbr.review.DraftState;
const CommentTarget = bbr.review.CommentTarget;
const Parent = bbr.review.draft.Parent;
const Anchor = bbr.review.Anchor;
const CommentId = bbr.review.CommentId;
const ApiError = bbr.bitbucket.ApiError;
const PendingReviewStore = bbr.review.PendingReviewStore;
const ReviewKey = bbr.review.ReviewKey;

pub const SqliteError = error{ Open, Exec, Prepare, Step };

const schema_v1 =
    \\CREATE TABLE IF NOT EXISTS drafts (
    \\  pr_id         INTEGER NOT NULL,
    \\  local_id      INTEGER NOT NULL,
    \\  kind          INTEGER NOT NULL,
    \\  target        INTEGER NOT NULL,
    \\  parent_kind   INTEGER NOT NULL,
    \\  parent_id     INTEGER,
    \\  anchor_path   TEXT,
    \\  anchor_from   INTEGER,
    \\  anchor_to     INTEGER,
    \\  anchor_commit TEXT,
    \\  body          TEXT NOT NULL,
    \\  state_kind    INTEGER NOT NULL,
    \\  state_id      INTEGER,
    \\  state_err     TEXT,
    \\  PRIMARY KEY (pr_id, local_id)
    \\) WITHOUT ROWID;
;

pub const SqliteStore = struct {
    db: *c.sqlite3,

    /// Open (creating if needed) the database at `path`, a NUL-terminated path or
    /// `":memory:"`. Applies pending migrations before returning.
    pub fn open(path: [:0]const u8) SqliteError!SqliteStore {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.Open;
        }
        var self: SqliteStore = .{ .db = db.? };
        errdefer _ = c.sqlite3_close(self.db);
        try self.migrate();
        return self;
    }

    pub fn deinit(self: *SqliteStore) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    pub fn store(self: *SqliteStore) PendingReviewStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- migrations ---------------------------------------------------------

    fn migrate(self: *SqliteStore) SqliteError!void {
        if (try self.userVersion() < 1) {
            try self.exec(schema_v1);
            try self.exec("PRAGMA user_version = 1;");
        }
        // v2 (M10b): multi-line anchors. Add the range's top-line columns. They
        // append at the end of the row, so v1 column indices are unaffected.
        if (try self.userVersion() < 2) {
            try self.exec(
                \\ALTER TABLE drafts ADD COLUMN anchor_start_from INTEGER;
                \\ALTER TABLE drafts ADD COLUMN anchor_start_to   INTEGER;
            );
            try self.exec("PRAGMA user_version = 2;");
        }
        // v3: PullRequestId is only Repository-unique. Rebuild the table so
        // Workspace + Repository participate in the primary key. Legacy rows
        // retain an empty scope because the old schema did not record it.
        if (try self.userVersion() < 3) {
            try self.exec(
                \\BEGIN;
                \\ALTER TABLE drafts RENAME TO drafts_v2;
                \\CREATE TABLE drafts (
                \\  pr_id INTEGER NOT NULL, local_id INTEGER NOT NULL,
                \\  kind INTEGER NOT NULL, target INTEGER NOT NULL,
                \\  parent_kind INTEGER NOT NULL, parent_id INTEGER,
                \\  anchor_path TEXT, anchor_from INTEGER, anchor_to INTEGER,
                \\  anchor_commit TEXT, body TEXT NOT NULL,
                \\  state_kind INTEGER NOT NULL, state_id INTEGER, state_err TEXT,
                \\  anchor_start_from INTEGER, anchor_start_to INTEGER,
                \\  workspace TEXT NOT NULL, repository TEXT NOT NULL,
                \\  PRIMARY KEY (workspace, repository, pr_id, local_id)
                \\) WITHOUT ROWID;
                \\INSERT INTO drafts
                \\ SELECT pr_id, local_id, kind, target, parent_kind, parent_id,
                \\        anchor_path, anchor_from, anchor_to, anchor_commit,
                \\        body, state_kind, state_id, state_err,
                \\        anchor_start_from, anchor_start_to, '', ''
                \\ FROM drafts_v2;
                \\DROP TABLE drafts_v2;
                \\COMMIT;
            );
            try self.exec("PRAGMA user_version = 3;");
        }
    }

    fn userVersion(self: *SqliteStore) SqliteError!i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA user_version;", -1, &stmt, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => c.sqlite3_column_int64(stmt, 0),
            else => error.Step,
        };
    }

    fn exec(self: *SqliteStore, sql: [*:0]const u8) SqliteError!void {
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) return error.Exec;
    }

    // --- vtable -------------------------------------------------------------

    const vtable: PendingReviewStore.VTable = .{
        .put = putImpl,
        .remove = removeImpl,
        .load = loadImpl,
    };

    fn putImpl(ptr: *anyopaque, key: ReviewKey, d: Draft) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        const sql =
            \\INSERT OR REPLACE INTO drafts
            \\ (pr_id, local_id, kind, target, parent_kind, parent_id,
            \\  anchor_path, anchor_from, anchor_to, anchor_commit,
            \\  body, state_kind, state_id, state_err,
            \\  anchor_start_from, anchor_start_to, workspace, repository)
            \\ VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        bindInt(stmt, 1, @intCast(key.pull_request_id));
        bindInt(stmt, 2, @intCast(d.local_id));
        bindInt(stmt, 3, @intFromEnum(d.kind));
        bindInt(stmt, 4, @intFromEnum(d.target));

        // parent: kind 0 none / 1 draft / 2 comment.
        if (d.parent) |p| switch (p) {
            .draft => |t| {
                bindInt(stmt, 5, 1);
                bindInt(stmt, 6, @intCast(t));
            },
            .comment => |cid| {
                bindInt(stmt, 5, 2);
                bindInt(stmt, 6, @intCast(cid));
            },
        } else {
            bindInt(stmt, 5, 0);
            bindNull(stmt, 6);
        }

        // anchor: NULL path means no anchor. Range top lines (15/16) append
        // after the state columns, matching the v2 ALTER TABLE order.
        if (d.anchor) |a| {
            bindText(stmt, 7, a.path);
            bindOptU32(stmt, 8, a.from);
            bindOptU32(stmt, 9, a.to);
            bindOptText(stmt, 10, a.commit);
            bindOptU32(stmt, 15, a.start_from);
            bindOptU32(stmt, 16, a.start_to);
        } else {
            bindNull(stmt, 7);
            bindNull(stmt, 8);
            bindNull(stmt, 9);
            bindNull(stmt, 10);
            bindNull(stmt, 15);
            bindNull(stmt, 16);
        }

        bindText(stmt, 11, d.body);

        // state: 0 draft / 1 submitting / 2 posted(id) / 3 failed(err name).
        switch (d.state) {
            .draft => {
                bindInt(stmt, 12, 0);
                bindNull(stmt, 13);
                bindNull(stmt, 14);
            },
            .submitting => {
                bindInt(stmt, 12, 1);
                bindNull(stmt, 13);
                bindNull(stmt, 14);
            },
            .posted => |id| {
                bindInt(stmt, 12, 2);
                bindInt(stmt, 13, @intCast(id));
                bindNull(stmt, 14);
            },
            .failed => |e| {
                bindInt(stmt, 12, 3);
                bindNull(stmt, 13);
                bindText(stmt, 14, @errorName(e));
            },
        }
        bindText(stmt, 17, key.workspace);
        bindText(stmt, 18, key.repository);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
    }

    fn removeImpl(ptr: *anyopaque, key: ReviewKey, local_id: TempId) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM drafts WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?;", -1, &stmt, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key.workspace);
        bindText(stmt, 2, key.repository);
        bindInt(stmt, 3, @intCast(key.pull_request_id));
        bindInt(stmt, 4, @intCast(local_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
    }

    fn loadImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: ReviewKey) anyerror![]Draft {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        // v2 and older could not record repository identity. The first load of
        // an upgraded PR claims those otherwise-unreachable rows for the
        // repository the user actually opened.
        try self.claimLegacyRows(key);
        const sql =
            \\SELECT local_id, kind, target, parent_kind, parent_id,
            \\ anchor_path, anchor_from, anchor_to, anchor_commit,
            \\ body, state_kind, state_id, state_err,
            \\ anchor_start_from, anchor_start_to
            \\ FROM drafts
            \\ WHERE workspace=? AND repository=? AND pr_id=? ORDER BY local_id;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key.workspace);
        bindText(stmt, 2, key.repository);
        bindInt(stmt, 3, @intCast(key.pull_request_id));

        var out: std.ArrayList(Draft) = .empty;
        errdefer out.deinit(allocator);

        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => try out.append(allocator, try rowToDraft(allocator, stmt)),
                c.SQLITE_DONE => break,
                else => return error.Step,
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn claimLegacyRows(self: *SqliteStore, key: ReviewKey) SqliteError!void {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql =
            \\UPDATE drafts SET workspace=?, repository=?
            \\ WHERE workspace='' AND repository='' AND pr_id=?;
        ;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key.workspace);
        bindText(stmt, 2, key.repository);
        bindInt(stmt, 3, @intCast(key.pull_request_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
    }

    fn rowToDraft(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt) !Draft {
        const parent: ?Parent = switch (columnInt(stmt, 3)) {
            1 => .{ .draft = @intCast(columnInt(stmt, 4)) },
            2 => .{ .comment = @intCast(columnInt(stmt, 4)) },
            else => null,
        };

        var anchor: ?Anchor = null;
        if (try columnTextDup(allocator, stmt, 5)) |path| {
            anchor = .{
                .path = path,
                .from = columnOptU32(stmt, 6),
                .to = columnOptU32(stmt, 7),
                .commit = try columnTextDup(allocator, stmt, 8),
                .start_from = columnOptU32(stmt, 13),
                .start_to = columnOptU32(stmt, 14),
            };
        }

        const state: DraftState = switch (columnInt(stmt, 10)) {
            2 => .{ .posted = @intCast(columnInt(stmt, 11)) },
            3 => .{ .failed = apiErrorFromName((try columnTextDup(allocator, stmt, 12)) orelse "") },
            1 => .submitting,
            else => .draft,
        };

        return .{
            .local_id = @intCast(columnInt(stmt, 0)),
            .kind = @enumFromInt(columnInt(stmt, 1)),
            .target = @enumFromInt(columnInt(stmt, 2)),
            .anchor = anchor,
            .parent = parent,
            .body = (try columnTextDup(allocator, stmt, 9)) orelse "",
            .state = state,
        };
    }
};

// --- binding helpers --------------------------------------------------------

fn bindInt(stmt: ?*c.sqlite3_stmt, idx: c_int, v: i64) void {
    _ = c.sqlite3_bind_int64(stmt, idx, v);
}
fn bindNull(stmt: ?*c.sqlite3_stmt, idx: c_int) void {
    _ = c.sqlite3_bind_null(stmt, idx);
}
fn bindText(stmt: ?*c.sqlite3_stmt, idx: c_int, s: []const u8) void {
    // SQLITE_STATIC: don't copy. Safe here — `s` (a Draft's borrowed slice)
    // stays valid through the `step` that reads it, before we finalize/return.
    _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), null);
}
fn bindOptText(stmt: ?*c.sqlite3_stmt, idx: c_int, s: ?[]const u8) void {
    if (s) |v| bindText(stmt, idx, v) else bindNull(stmt, idx);
}
fn bindOptU32(stmt: ?*c.sqlite3_stmt, idx: c_int, v: ?u32) void {
    if (v) |x| bindInt(stmt, idx, @intCast(x)) else bindNull(stmt, idx);
}

// --- column helpers ---------------------------------------------------------

fn columnInt(stmt: ?*c.sqlite3_stmt, col: c_int) i64 {
    return c.sqlite3_column_int64(stmt, col);
}
fn columnOptU32(stmt: ?*c.sqlite3_stmt, col: c_int) ?u32 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return @intCast(c.sqlite3_column_int64(stmt, col));
}
/// Dupe a TEXT column into `allocator`, or null if the column is NULL.
fn columnTextDup(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) !?[]const u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null) return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, ptr[0..len]);
}

/// Map a persisted ApiError name back to the error value. Unknown names (a
/// forward-incompatible db) degrade to `UnexpectedStatus` rather than crashing.
fn apiErrorFromName(name: []const u8) ApiError {
    const table = [_]struct { n: []const u8, e: ApiError }{
        .{ .n = "Unauthorized", .e = error.Unauthorized },
        .{ .n = "Forbidden", .e = error.Forbidden },
        .{ .n = "NotFound", .e = error.NotFound },
        .{ .n = "RateLimited", .e = error.RateLimited },
        .{ .n = "ServerError", .e = error.ServerError },
        .{ .n = "MalformedResponse", .e = error.MalformedResponse },
        .{ .n = "UnexpectedStatus", .e = error.UnexpectedStatus },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.n, name)) return row.e;
    }
    return error.UnexpectedStatus;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn testReviewKey(pull_request_id: u64) ReviewKey {
    return .{ .workspace = "workspace", .repository = "repo", .pull_request_id = pull_request_id };
}

test "in-memory round-trip preserves fields, anchor, parent, and state" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();

    try store.put(testReviewKey(7), .{
        .local_id = 1,
        .kind = .inline_comment,
        .target = .bitbucket,
        .anchor = .{ .path = "src/f.zig", .from = 3, .to = 12, .start_to = 9, .commit = "deadbeef" },
        .body = "needs a test",
        .state = .{ .posted = 555 },
    });
    try store.put(testReviewKey(7), .{
        .local_id = 2,
        .kind = .reply,
        .parent = .{ .draft = 1 },
        .body = "agreed",
        .state = .{ .failed = error.RateLimited },
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.load(arena.allocator(), testReviewKey(7));

    try testing.expectEqual(@as(usize, 2), drafts.len);
    const d0 = drafts[0];
    try testing.expect(d0.kind == .inline_comment);
    try testing.expectEqualStrings("src/f.zig", d0.anchor.?.path);
    try testing.expectEqual(@as(?u32, 3), d0.anchor.?.from);
    try testing.expectEqual(@as(?u32, 12), d0.anchor.?.to);
    try testing.expectEqual(@as(?u32, 9), d0.anchor.?.start_to); // range top round-trips
    try testing.expect(d0.anchor.?.start_from == null);
    try testing.expect(d0.anchor.?.isRange());
    try testing.expectEqualStrings("deadbeef", d0.anchor.?.commit.?);
    try testing.expectEqualStrings("needs a test", d0.body);
    try testing.expectEqual(@as(CommentId, 555), d0.state.posted);

    const d1 = drafts[1];
    try testing.expect(d1.kind == .reply);
    try testing.expect(d1.parent.? == .draft and d1.parent.?.draft == 1);
    try testing.expect(d1.anchor == null);
    try testing.expectEqual(ApiError.RateLimited, d1.state.failed);
}

test "put replaces on key; remove deletes; both scope to the PR" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();

    try store.put(testReviewKey(1), .{ .local_id = 1, .kind = .top_level, .body = "first" });
    try store.put(testReviewKey(1), .{ .local_id = 1, .kind = .top_level, .body = "edited" }); // replace
    try store.put(testReviewKey(1), .{ .local_id = 2, .kind = .top_level, .body = "second" });
    try store.put(testReviewKey(2), .{ .local_id = 1, .kind = .top_level, .body = "other pr" });
    try store.remove(testReviewKey(1), 2);
    try store.remove(testReviewKey(1), 999); // idempotent

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.load(arena.allocator(), testReviewKey(1));
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqualStrings("edited", drafts[0].body);
}

test "identical PullRequestIds remain isolated by Repository in SQLite" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const alpha: ReviewKey = .{ .workspace = "ws", .repository = "alpha", .pull_request_id = 7 };
    const beta: ReviewKey = .{ .workspace = "ws", .repository = "beta", .pull_request_id = 7 };

    try store.put(alpha, .{ .local_id = 1, .kind = .top_level, .body = "alpha" });
    try store.put(beta, .{ .local_id = 1, .kind = .top_level, .body = "beta" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alpha_drafts = try store.load(arena.allocator(), alpha);
    const beta_drafts = try store.load(arena.allocator(), beta);
    try testing.expectEqual(@as(usize, 1), alpha_drafts.len);
    try testing.expectEqual(@as(usize, 1), beta_drafts.len);
    try testing.expectEqualStrings("alpha", alpha_drafts[0].body);
    try testing.expectEqualStrings("beta", beta_drafts[0].body);
}

test "v2 rows are migrated and claimed by the first repository load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}/v2.db", .{&tmp.sub_path}, 0);

    var legacy: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(path.ptr, &legacy, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    defer {
        if (legacy) |db| _ = c.sqlite3_close(db);
    }
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(legacy, schema_v1, null, null, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(legacy,
        \\ALTER TABLE drafts ADD COLUMN anchor_start_from INTEGER;
        \\ALTER TABLE drafts ADD COLUMN anchor_start_to INTEGER;
        \\INSERT INTO drafts (pr_id, local_id, kind, target, parent_kind, body, state_kind)
        \\ VALUES (42, 1, 0, 0, 0, 'legacy draft', 0);
        \\PRAGMA user_version = 2;
    , null, null, null));
    _ = c.sqlite3_close(legacy.?);
    legacy = null;

    var upgraded = try SqliteStore.open(path);
    defer upgraded.deinit();
    const key: ReviewKey = .{ .workspace = "ws", .repository = "repo", .pull_request_id = 42 };
    const drafts = try upgraded.store().load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqualStrings("legacy draft", drafts[0].body);

    const other: ReviewKey = .{ .workspace = "ws", .repository = "other", .pull_request_id = 42 };
    const other_drafts = try upgraded.store().load(arena.allocator(), other);
    try testing.expectEqual(@as(usize, 0), other_drafts.len);
}

test "drafts survive closing and reopening the database (resume)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // tmpDir lives at .zig-cache/tmp/<sub_path> relative to cwd; SQLite opens
    // the file relative to cwd, and tmp.cleanup() removes the whole subtree.
    const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/pending.db", .{&tmp.sub_path}, 0);

    {
        var s = try SqliteStore.open(path);
        defer s.deinit();
        const store = s.store();
        try store.put(testReviewKey(42), .{ .local_id = 1, .kind = .top_level, .body = "persist me" });
        try store.put(testReviewKey(42), .{ .local_id = 2, .kind = .reply, .parent = .{ .comment = 900 }, .body = "reply to remote" });
    }

    // Reopen: a fresh handle over the same file resumes the review.
    var s2 = try SqliteStore.open(path);
    defer s2.deinit();
    var review = try s2.store().loadReview(a, testReviewKey(42));
    try testing.expectEqual(@as(usize, 2), review.drafts.items.len);
    try testing.expectEqualStrings("persist me", review.get(1).?.body);
    try testing.expect(review.get(2).?.parent.? == .comment);
    // next_id resumes past the loaded drafts.
    const fresh = try review.add(a, .{ .kind = .top_level, .body = "new" });
    try testing.expectEqual(@as(TempId, 3), fresh);
}
