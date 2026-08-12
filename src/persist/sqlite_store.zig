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
const RemoteReviewIdentity = bbr.review.RemoteReviewIdentity;
const OperationId = bbr.review.OperationId;
const ActiveSubmissionRun = bbr.review.ActiveSubmissionRun;
const SubmissionRunItem = bbr.review.SubmissionRunItem;
const SubmissionOutcome = bbr.review.SubmissionOutcome;
const SubmissionPendingState = bbr.review.SubmissionPendingState;
const UnknownResolution = bbr.review.UnknownResolution;
const DraftBodyEdit = bbr.review.DraftBodyEdit;
const parentEql = bbr.review.parentEql;
const SubmissionCompletion = bbr.review.SubmissionCompletion;

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
        // v4: durable Submission recovery state. A partial unique index makes
        // the agreed single active Submission structural across processes.
        if (try self.userVersion() < 4) {
            try self.exec(
                \\BEGIN;
                \\CREATE TABLE submission_runs (
                \\  operation_id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  workspace TEXT NOT NULL, repository TEXT NOT NULL,
                \\  pr_id INTEGER NOT NULL, source_commit TEXT NOT NULL,
                \\  current_temp_id INTEGER, state INTEGER NOT NULL DEFAULT 0
                \\);
                \\CREATE UNIQUE INDEX one_active_submission
                \\  ON submission_runs(state) WHERE state=0;
                \\PRAGMA user_version = 4;
                \\COMMIT;
            );
        }
        // v5 (M14): stable logical-repository aliases and transactional Draft
        // identifiers shared by concurrent bbr processes.
        if (try self.userVersion() < 5) {
            try self.exec(
                \\BEGIN;
                \\CREATE TABLE review_repositories (
                \\  repository_id INTEGER PRIMARY KEY AUTOINCREMENT
                \\);
                \\CREATE TABLE review_repository_aliases (
                \\  alias TEXT PRIMARY KEY,
                \\  repository_id INTEGER NOT NULL REFERENCES review_repositories(repository_id)
                \\);
                \\CREATE TABLE draft_temp_ids (
                \\  workspace TEXT NOT NULL, repository TEXT NOT NULL, pr_id INTEGER NOT NULL,
                \\  next_id INTEGER NOT NULL,
                \\  PRIMARY KEY (workspace, repository, pr_id)
                \\) WITHOUT ROWID;
                \\PRAGMA user_version = 5;
                \\COMMIT;
            );
        }
        // v6 (M14): immutable fallback context for local root Draft Anchors.
        if (try self.userVersion() < 6) {
            try self.exec(
                \\BEGIN;
                \\ALTER TABLE drafts ADD COLUMN snapshot_text TEXT;
                \\ALTER TABLE drafts ADD COLUMN snapshot_selection_start INTEGER;
                \\ALTER TABLE drafts ADD COLUMN snapshot_selection_len INTEGER;
                \\PRAGMA user_version = 6;
                \\COMMIT;
            );
        }
        // v7 (M15): exhaustive root CommentScope. Legacy parentless rows map
        // from optional anchors; Replies discard echoed scope and inherit.
        if (try self.userVersion() < 7) {
            try self.exec(
                \\BEGIN;
                \\ALTER TABLE drafts ADD COLUMN scope_kind INTEGER;
                \\ALTER TABLE drafts ADD COLUMN file_source_commit TEXT;
                \\UPDATE drafts SET scope_kind = CASE
                \\  WHEN parent_kind != 0 THEN NULL
                \\  WHEN anchor_path IS NULL THEN 0
                \\  ELSE 2 END;
                \\UPDATE drafts SET kind = CASE WHEN kind = 3 THEN 1 ELSE 0 END;
                \\PRAGMA user_version = 7;
                \\COMMIT;
            );
        }
        // v8 (M16): freeze each SubmissionRun's ordered dependency graph.
        if (try self.userVersion() < 8) {
            try self.exec(
                \\BEGIN;
                \\CREATE TABLE submission_run_items (
                \\  operation_id INTEGER NOT NULL REFERENCES submission_runs(operation_id) ON DELETE CASCADE,
                \\  ordinal INTEGER NOT NULL, temp_id INTEGER NOT NULL,
                \\  parent_kind INTEGER NOT NULL, parent_id INTEGER,
                \\  PRIMARY KEY (operation_id, ordinal),
                \\  UNIQUE (operation_id, temp_id)
                \\) WITHOUT ROWID;
                // Legacy active runs did not record membership. Preserve their
                // current item as the only participant that can be recovered safely.
                \\INSERT INTO submission_run_items(operation_id, ordinal, temp_id, parent_kind, parent_id)
                \\ SELECT r.operation_id, 0, r.current_temp_id, d.parent_kind, d.parent_id
                \\ FROM submission_runs r JOIN drafts d
                \\   ON d.workspace=r.workspace AND d.repository=r.repository
                \\  AND d.pr_id=r.pr_id AND d.local_id=r.current_temp_id
                \\ WHERE r.state=0 AND r.current_temp_id IS NOT NULL;
                \\PRAGMA user_version = 8;
                \\COMMIT;
            );
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
        .edit_draft_body = editDraftBodyImpl,
        .load = loadImpl,
        .begin_submission = beginSubmissionImpl,
        .checkpoint_submission = checkpointSubmissionImpl,
        .complete_submission = completeSubmissionImpl,
        .abandon_submission = abandonSubmissionImpl,
        .active_submission = activeSubmissionImpl,
        .resolve_unknown = resolveUnknownImpl,
        .resolve_repository = resolveRepositoryImpl,
        .reserve_temp_id = reserveTempIdImpl,
    };

    fn resolveRepositoryImpl(ptr: *anyopaque, aliases: []const []const u8) anyerror!bbr.review.ReviewRepositoryId {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        if (aliases.len == 0) return error.NoRepositoryAlias;
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var resolved: ?bbr.review.ReviewRepositoryId = null;
        for (aliases) |alias| {
            var query: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT repository_id FROM review_repository_aliases WHERE alias=?;", -1, &query, null) != c.SQLITE_OK)
                return error.Prepare;
            defer _ = c.sqlite3_finalize(query);
            bindText(query, 1, alias);
            switch (c.sqlite3_step(query)) {
                c.SQLITE_ROW => {
                    const id: bbr.review.ReviewRepositoryId = @intCast(c.sqlite3_column_int64(query, 0));
                    if (resolved != null and resolved.? != id) return error.RepositoryIdentityConflict;
                    resolved = id;
                },
                c.SQLITE_DONE => {},
                else => return error.Step,
            }
        }

        const repository_id = resolved orelse blk: {
            if (c.sqlite3_exec(self.db, "INSERT INTO review_repositories DEFAULT VALUES;", null, null, null) != c.SQLITE_OK)
                return error.Exec;
            break :blk @as(bbr.review.ReviewRepositoryId, @intCast(c.sqlite3_last_insert_rowid(self.db)));
        };
        for (aliases) |alias| {
            var insert: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO review_repository_aliases(alias, repository_id) VALUES (?,?);", -1, &insert, null) != c.SQLITE_OK)
                return error.Prepare;
            defer _ = c.sqlite3_finalize(insert);
            bindText(insert, 1, alias);
            bindInt(insert, 2, @intCast(repository_id));
            if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.Step;
        }
        try self.exec("COMMIT;");
        return repository_id;
    }

    fn reserveTempIdImpl(ptr: *anyopaque, key: RemoteReviewIdentity) anyerror!TempId {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var query: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT next_id FROM draft_temp_ids WHERE workspace=? AND repository=? AND pr_id=?;", -1, &query, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(query);
        bindText(query, 1, key.workspace);
        bindText(query, 2, key.repository);
        bindInt(query, 3, @intCast(key.pull_request_id));
        const reserved: TempId = switch (c.sqlite3_step(query)) {
            c.SQLITE_ROW => @intCast(c.sqlite3_column_int64(query, 0)),
            c.SQLITE_DONE => blk: {
                var maximum: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT COALESCE(MAX(local_id),0)+1 FROM drafts WHERE workspace=? AND repository=? AND pr_id=?;", -1, &maximum, null) != c.SQLITE_OK)
                    return error.Prepare;
                defer _ = c.sqlite3_finalize(maximum);
                bindText(maximum, 1, key.workspace);
                bindText(maximum, 2, key.repository);
                bindInt(maximum, 3, @intCast(key.pull_request_id));
                if (c.sqlite3_step(maximum) != c.SQLITE_ROW) return error.Step;
                break :blk @intCast(c.sqlite3_column_int64(maximum, 0));
            },
            else => return error.Step,
        };

        var upsert: ?*c.sqlite3_stmt = null;
        const sql =
            \\INSERT INTO draft_temp_ids(workspace,repository,pr_id,next_id) VALUES (?,?,?,?)
            \\ON CONFLICT(workspace,repository,pr_id) DO UPDATE SET next_id=excluded.next_id;
        ;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &upsert, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(upsert);
        bindText(upsert, 1, key.workspace);
        bindText(upsert, 2, key.repository);
        bindInt(upsert, 3, @intCast(key.pull_request_id));
        bindInt(upsert, 4, @intCast(reserved + 1));
        if (c.sqlite3_step(upsert) != c.SQLITE_DONE) return error.Step;
        try self.exec("COMMIT;");
        return reserved;
    }

    fn putImpl(ptr: *anyopaque, key: RemoteReviewIdentity, d: Draft) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        if (try self.draftMutationLocked(key, d.local_id, d.target)) return error.DraftLocked;
        const sql =
            \\INSERT OR REPLACE INTO drafts
            \\ (pr_id, local_id, kind, target, parent_kind, parent_id,
            \\  anchor_path, anchor_from, anchor_to, anchor_commit,
            \\  body, state_kind, state_id, state_err,
            \\  anchor_start_from, anchor_start_to, workspace, repository,
            \\  snapshot_text, snapshot_selection_start, snapshot_selection_len,
            \\  scope_kind, file_source_commit)
            \\ VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
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

        const root_scope = if (d.parent == null) d.effectiveScope() else null;
        const inline_anchor: ?Anchor = if (root_scope) |scope| switch (scope) {
            .@"inline" => |anchor| anchor,
            else => null,
        } else null;
        // Inline scope retains the legacy anchor columns so v6 data migrates
        // losslessly. File scope uses path plus its authored source commit.
        if (inline_anchor) |a| {
            bindText(stmt, 7, a.path);
            bindOptU32(stmt, 8, a.from);
            bindOptU32(stmt, 9, a.to);
            bindOptText(stmt, 10, a.commit);
            bindOptU32(stmt, 15, a.start_from);
            bindOptU32(stmt, 16, a.start_to);
        } else {
            if (root_scope) |scope| switch (scope) {
                .file => |file| bindText(stmt, 7, file.path),
                else => bindNull(stmt, 7),
            } else bindNull(stmt, 7);
            bindNull(stmt, 8);
            bindNull(stmt, 9);
            bindNull(stmt, 10);
            bindNull(stmt, 15);
            bindNull(stmt, 16);
        }

        bindText(stmt, 11, d.body);

        // state: 0 draft / 1 submitting / 2 posted(id) / 3 failed(err) / 4 outcome unknown.
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
            .outcome_unknown => {
                bindInt(stmt, 12, 4);
                bindNull(stmt, 13);
                bindNull(stmt, 14);
            },
        }
        bindText(stmt, 17, key.workspace);
        bindText(stmt, 18, key.repository);
        if (d.snapshot) |snapshot| {
            bindText(stmt, 19, snapshot.text);
            bindInt(stmt, 20, @intCast(snapshot.selection_start));
            bindInt(stmt, 21, @intCast(snapshot.selection_len));
        } else {
            bindNull(stmt, 19);
            bindNull(stmt, 20);
            bindNull(stmt, 21);
        }
        if (root_scope) |scope| {
            bindInt(stmt, 22, switch (scope) {
                .review => 0,
                .file => 1,
                .@"inline" => 2,
            });
            switch (scope) {
                .file => |file| bindText(stmt, 23, file.source_commit),
                else => bindNull(stmt, 23),
            }
        } else {
            bindNull(stmt, 22);
            bindNull(stmt, 23);
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
        try self.exec("COMMIT;");
    }

    fn removeImpl(ptr: *anyopaque, key: RemoteReviewIdentity, local_id: TempId) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        if (try self.draftMutationLocked(key, local_id, null)) return error.DraftLocked;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM drafts WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?;", -1, &stmt, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key.workspace);
        bindText(stmt, 2, key.repository);
        bindInt(stmt, 3, @intCast(key.pull_request_id));
        bindInt(stmt, 4, @intCast(local_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
        try self.exec("COMMIT;");
    }

    /// One transaction: recheck identity, expected shape, editable state, and
    /// SubmissionRun participation, then replace the body. Nothing else about
    /// the row — kind, parent, scope, anchor, snapshot — is touched.
    fn editDraftBodyImpl(ptr: *anyopaque, key: RemoteReviewIdentity, edit: DraftBodyEdit) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        if (try self.draftMutationLocked(key, edit.temp_id, null)) return error.DraftLocked;

        var query: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT kind, parent_kind, parent_id, state_kind FROM drafts WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?;", -1, &query, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(query);
        bindText(query, 1, key.workspace);
        bindText(query, 2, key.repository);
        bindInt(query, 3, @intCast(key.pull_request_id));
        bindInt(query, 4, @intCast(edit.temp_id));
        switch (c.sqlite3_step(query)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return error.DraftNotFound,
            else => return error.Step,
        }
        const state_kind = columnInt(query, 3);
        switch (state_kind) {
            0, 3 => {},
            1, 2 => return error.DraftNotEditable,
            else => return error.DraftLocked,
        }
        if (columnInt(query, 0) != @intFromEnum(edit.expected_kind)) return error.DraftEditConflict;
        const stored_parent: ?Parent = switch (columnInt(query, 1)) {
            1 => .{ .draft = @intCast(columnInt(query, 2)) },
            2 => .{ .comment = @intCast(columnInt(query, 2)) },
            else => null,
        };
        if (!parentEql(stored_parent, edit.expected_parent)) return error.DraftEditConflict;

        // A changed body is a new attempt, so a confirmed failure resets.
        var update: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE drafts SET body=?, state_kind=?, state_err=NULL WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?;", -1, &update, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(update);
        bindText(update, 1, edit.body);
        bindInt(update, 2, 0);
        bindText(update, 3, key.workspace);
        bindText(update, 4, key.repository);
        bindInt(update, 5, @intCast(key.pull_request_id));
        bindInt(update, 6, @intCast(edit.temp_id));
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.DraftNotFound;
        try self.exec("COMMIT;");
    }

    fn loadImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: RemoteReviewIdentity) anyerror![]Draft {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        // v2 and older could not record repository identity. The first load of
        // an upgraded PR claims those otherwise-unreachable rows for the
        // repository the user actually opened.
        try self.claimLegacyRows(key);
        const sql =
            \\SELECT local_id, kind, target, parent_kind, parent_id,
            \\ anchor_path, anchor_from, anchor_to, anchor_commit,
            \\ body, state_kind, state_id, state_err,
            \\ anchor_start_from, anchor_start_to,
            \\ snapshot_text, snapshot_selection_start, snapshot_selection_len,
            \\ scope_kind, file_source_commit
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

    fn beginSubmissionImpl(ptr: *anyopaque, key: RemoteReviewIdentity, source_commit: []const u8, items: []const SubmissionRunItem) anyerror!OperationId {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        if (items.len == 0) return error.EmptySubmission;
        const first_temp_id = items[0].temp_id;
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        if (try self.hasActiveSubmission()) return error.SubmissionAlreadyActive;

        var insert: ?*c.sqlite3_stmt = null;
        const insert_sql =
            \\INSERT INTO submission_runs
            \\ (workspace, repository, pr_id, source_commit, current_temp_id, state)
            \\ VALUES (?, ?, ?, ?, ?, 0);
        ;
        if (c.sqlite3_prepare_v2(self.db, insert_sql, -1, &insert, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(insert);
        bindText(insert, 1, key.workspace);
        bindText(insert, 2, key.repository);
        bindInt(insert, 3, @intCast(key.pull_request_id));
        bindText(insert, 4, source_commit);
        bindInt(insert, 5, @intCast(first_temp_id));
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.Step;
        const operation_id: OperationId = @intCast(c.sqlite3_last_insert_rowid(self.db));

        for (items, 0..) |item, ordinal| {
            var participant: ?*c.sqlite3_stmt = null;
            const participant_sql =
                \\INSERT INTO submission_run_items(operation_id, ordinal, temp_id, parent_kind, parent_id)
                \\ SELECT ?, ?, local_id, parent_kind, parent_id FROM drafts
                \\ WHERE workspace=? AND repository=? AND pr_id=? AND local_id=? AND target=0
                \\   AND parent_kind=? AND (parent_id IS ? OR parent_id=?);
            ;
            if (c.sqlite3_prepare_v2(self.db, participant_sql, -1, &participant, null) != c.SQLITE_OK) return error.Prepare;
            defer _ = c.sqlite3_finalize(participant);
            bindInt(participant, 1, @intCast(operation_id));
            bindInt(participant, 2, @intCast(ordinal));
            bindText(participant, 3, key.workspace);
            bindText(participant, 4, key.repository);
            bindInt(participant, 5, @intCast(key.pull_request_id));
            bindInt(participant, 6, @intCast(item.temp_id));
            const parent_kind: i64 = if (item.parent) |parent| switch (parent) {
                .draft => 1,
                .comment => 2,
            } else 0;
            bindInt(participant, 7, parent_kind);
            if (item.parent) |parent| {
                const parent_id = switch (parent) {
                    .draft => |id| id,
                    .comment => |id| id,
                };
                bindInt(participant, 8, @intCast(parent_id));
                bindInt(participant, 9, @intCast(parent_id));
            } else {
                bindNull(participant, 8);
                bindNull(participant, 9);
            }
            if (c.sqlite3_step(participant) != c.SQLITE_DONE) return error.Step;
            if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionGraph;
        }

        var update: ?*c.sqlite3_stmt = null;
        const update_sql =
            \\UPDATE drafts SET state_kind=1, state_id=NULL, state_err=NULL
            \\ WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?
            \\   AND target=0 AND state_kind IN (0,3);
        ;
        if (c.sqlite3_prepare_v2(self.db, update_sql, -1, &update, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(update);
        bindText(update, 1, key.workspace);
        bindText(update, 2, key.repository);
        bindInt(update, 3, @intCast(key.pull_request_id));
        bindInt(update, 4, @intCast(first_temp_id));
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.DraftNotSubmittable;

        try self.exec("COMMIT;");
        return operation_id;
    }

    fn hasActiveSubmission(self: *SqliteStore) SqliteError!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT EXISTS(SELECT 1 FROM submission_runs WHERE state=0);", -1, &stmt, null) != c.SQLITE_OK)
            return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Step;
        return columnInt(stmt, 0) != 0;
    }

    fn activeSubmissionImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?ActiveSubmissionRun {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        var stmt: ?*c.sqlite3_stmt = null;
        const sql =
            \\SELECT operation_id, workspace, repository, pr_id,
            \\       source_commit, current_temp_id
            \\ FROM submission_runs WHERE state=0 LIMIT 1;
        ;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_DONE => null,
            c.SQLITE_ROW => blk: {
                const operation_id: OperationId = @intCast(columnInt(stmt, 0));
                var items_stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT temp_id,parent_kind,parent_id FROM submission_run_items WHERE operation_id=? ORDER BY ordinal;", -1, &items_stmt, null) != c.SQLITE_OK) return error.Prepare;
                defer _ = c.sqlite3_finalize(items_stmt);
                bindInt(items_stmt, 1, @intCast(operation_id));
                var items: std.ArrayList(SubmissionRunItem) = .empty;
                errdefer items.deinit(allocator);
                while (true) switch (c.sqlite3_step(items_stmt)) {
                    c.SQLITE_ROW => try items.append(allocator, .{
                        .temp_id = @intCast(columnInt(items_stmt, 0)),
                        .parent = switch (columnInt(items_stmt, 1)) {
                            1 => .{ .draft = @intCast(columnInt(items_stmt, 2)) },
                            2 => .{ .comment = @intCast(columnInt(items_stmt, 2)) },
                            else => null,
                        },
                    }),
                    c.SQLITE_DONE => break,
                    else => return error.Step,
                };
                break :blk .{
                    .operation_id = operation_id,
                    .key = .{
                        .workspace = (try columnTextDup(allocator, stmt, 1)).?,
                        .repository = (try columnTextDup(allocator, stmt, 2)).?,
                        .pull_request_id = @intCast(columnInt(stmt, 3)),
                    },
                    .source_commit = (try columnTextDup(allocator, stmt, 4)).?,
                    .current_temp_id = if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) null else @intCast(columnInt(stmt, 5)),
                    .items = try items.toOwnedSlice(allocator),
                };
            },
            else => error.Step,
        };
    }

    fn resolveUnknownImpl(ptr: *anyopaque, key: RemoteReviewIdentity, temp_id: TempId, resolution: UnknownResolution) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        const sql =
            \\UPDATE drafts SET state_kind=?, state_id=?, state_err=NULL
            \\ WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?
            \\   AND state_kind=4
            \\   AND NOT EXISTS(SELECT 1 FROM submission_runs r
            \\     JOIN submission_run_items i ON i.operation_id=r.operation_id
            \\     WHERE r.workspace=? AND r.repository=? AND r.pr_id=? AND r.state=0 AND i.temp_id=?);
        ;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        switch (resolution) {
            .posted => |id| {
                bindInt(stmt, 1, 2);
                bindInt(stmt, 2, @intCast(id));
            },
            .unpublished => {
                bindInt(stmt, 1, 0);
                if (c.sqlite3_bind_null(stmt, 2) != c.SQLITE_OK) return error.Bind;
            },
        }
        bindText(stmt, 3, key.workspace);
        bindText(stmt, 4, key.repository);
        bindInt(stmt, 5, @intCast(key.pull_request_id));
        bindInt(stmt, 6, @intCast(temp_id));
        bindText(stmt, 7, key.workspace);
        bindText(stmt, 8, key.repository);
        bindInt(stmt, 9, @intCast(key.pull_request_id));
        bindInt(stmt, 10, @intCast(temp_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.InvalidUnknownResolution;
        try self.exec("COMMIT;");
    }

    fn checkpointSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, completed_temp_id: TempId, outcome: SubmissionOutcome, next_temp_id: ?TempId) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        if (next_temp_id == completed_temp_id) return error.InvalidSubmissionCheckpoint;
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        if (next_temp_id) |next_id| {
            var order: ?*c.sqlite3_stmt = null;
            const order_sql =
                \\SELECT (SELECT ordinal FROM submission_run_items WHERE operation_id=? AND temp_id=?),
                \\       (SELECT ordinal FROM submission_run_items WHERE operation_id=? AND temp_id=?);
            ;
            if (c.sqlite3_prepare_v2(self.db, order_sql, -1, &order, null) != c.SQLITE_OK) return error.Prepare;
            defer _ = c.sqlite3_finalize(order);
            bindInt(order, 1, @intCast(operation_id));
            bindInt(order, 2, @intCast(completed_temp_id));
            bindInt(order, 3, @intCast(operation_id));
            bindInt(order, 4, @intCast(next_id));
            if (c.sqlite3_step(order) != c.SQLITE_ROW or c.sqlite3_column_type(order, 0) == c.SQLITE_NULL or c.sqlite3_column_type(order, 1) == c.SQLITE_NULL or columnInt(order, 1) <= columnInt(order, 0))
                return error.InvalidSubmissionCheckpoint;
        }

        var completed: ?*c.sqlite3_stmt = null;
        const completed_sql =
            \\UPDATE drafts SET state_kind=?, state_id=?, state_err=?
            \\ WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?
            \\   AND state_kind=1;
        ;
        if (c.sqlite3_prepare_v2(self.db, completed_sql, -1, &completed, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(completed);
        bindSubmissionOutcome(completed, outcome);
        bindText(completed, 4, key.workspace);
        bindText(completed, 5, key.repository);
        bindInt(completed, 6, @intCast(key.pull_request_id));
        bindInt(completed, 7, @intCast(completed_temp_id));
        if (c.sqlite3_step(completed) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCheckpoint;

        if (next_temp_id) |next_id| {
            var next: ?*c.sqlite3_stmt = null;
            const next_sql =
                \\UPDATE drafts SET state_kind=1, state_id=NULL, state_err=NULL
                \\ WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?
                \\   AND target=0 AND state_kind IN (0,3);
            ;
            if (c.sqlite3_prepare_v2(self.db, next_sql, -1, &next, null) != c.SQLITE_OK) return error.Prepare;
            defer _ = c.sqlite3_finalize(next);
            bindText(next, 1, key.workspace);
            bindText(next, 2, key.repository);
            bindInt(next, 3, @intCast(key.pull_request_id));
            bindInt(next, 4, @intCast(next_id));
            if (c.sqlite3_step(next) != c.SQLITE_DONE) return error.Step;
            if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCheckpoint;
        }

        var run: ?*c.sqlite3_stmt = null;
        const run_sql =
            \\UPDATE submission_runs SET current_temp_id=?
            \\ WHERE operation_id=? AND workspace=? AND repository=? AND pr_id=?
            \\   AND current_temp_id=? AND state=0;
        ;
        if (c.sqlite3_prepare_v2(self.db, run_sql, -1, &run, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(run);
        if (next_temp_id) |next_id| bindInt(run, 1, @intCast(next_id)) else bindNull(run, 1);
        bindInt(run, 2, @intCast(operation_id));
        bindText(run, 3, key.workspace);
        bindText(run, 4, key.repository);
        bindInt(run, 5, @intCast(key.pull_request_id));
        bindInt(run, 6, @intCast(completed_temp_id));
        if (c.sqlite3_step(run) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCheckpoint;

        try self.exec("COMMIT;");
    }

    fn completeSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity, completion: SubmissionCompletion) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        if (completion == .aborted) {
            var restore: ?*c.sqlite3_stmt = null;
            const restore_sql =
                \\UPDATE drafts SET state_kind=?, state_id=?, state_err=?
                \\ WHERE workspace=? AND repository=? AND pr_id=? AND state_kind=1
                \\   AND local_id=(SELECT current_temp_id FROM submission_runs
                \\     WHERE operation_id=? AND workspace=? AND repository=? AND pr_id=?
                \\       AND current_temp_id IS NOT NULL AND state=0);
            ;
            if (c.sqlite3_prepare_v2(self.db, restore_sql, -1, &restore, null) != c.SQLITE_OK) return error.Prepare;
            defer _ = c.sqlite3_finalize(restore);
            bindSubmissionPendingState(restore, completion.aborted);
            bindText(restore, 4, key.workspace);
            bindText(restore, 5, key.repository);
            bindInt(restore, 6, @intCast(key.pull_request_id));
            bindInt(restore, 7, @intCast(operation_id));
            bindText(restore, 8, key.workspace);
            bindText(restore, 9, key.repository);
            bindInt(restore, 10, @intCast(key.pull_request_id));
            if (c.sqlite3_step(restore) != c.SQLITE_DONE) return error.Step;
            if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCompletion;
        }

        var run: ?*c.sqlite3_stmt = null;
        const run_sql = if (completion == .aborted)
            \\UPDATE submission_runs SET state=?, current_temp_id=NULL
            \\ WHERE operation_id=? AND workspace=? AND repository=? AND pr_id=?
            \\   AND current_temp_id IS NOT NULL AND state=0;
        else
            \\UPDATE submission_runs SET state=?, current_temp_id=NULL
            \\ WHERE operation_id=? AND workspace=? AND repository=? AND pr_id=?
            \\   AND current_temp_id IS NULL AND state=0;
        ;
        if (c.sqlite3_prepare_v2(self.db, run_sql, -1, &run, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(run);
        bindInt(run, 1, switch (completion) {
            .clean => 1,
            .partial, .aborted => 2,
        });
        bindInt(run, 2, @intCast(operation_id));
        bindText(run, 3, key.workspace);
        bindText(run, 4, key.repository);
        bindInt(run, 5, @intCast(key.pull_request_id));
        if (c.sqlite3_step(run) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCompletion;

        if (completion == .clean) {
            var dirty: ?*c.sqlite3_stmt = null;
            const dirty_sql =
                \\SELECT EXISTS(
                \\  SELECT 1 FROM drafts
                \\  WHERE workspace=? AND repository=? AND pr_id=?
                \\    AND local_id IN (SELECT temp_id FROM submission_run_items WHERE operation_id=?)
                \\    AND state_kind!=2
                \\);
            ;
            if (c.sqlite3_prepare_v2(self.db, dirty_sql, -1, &dirty, null) != c.SQLITE_OK) return error.Prepare;
            defer _ = c.sqlite3_finalize(dirty);
            bindText(dirty, 1, key.workspace);
            bindText(dirty, 2, key.repository);
            bindInt(dirty, 3, @intCast(key.pull_request_id));
            bindInt(dirty, 4, @intCast(operation_id));
            if (c.sqlite3_step(dirty) != c.SQLITE_ROW) return error.Step;
            if (columnInt(dirty, 0) != 0) return error.SubmissionNotClean;

            var remove: ?*c.sqlite3_stmt = null;
            const remove_sql =
                \\DELETE FROM drafts
                \\ WHERE workspace=? AND repository=? AND pr_id=?
                \\   AND local_id IN (SELECT temp_id FROM submission_run_items WHERE operation_id=?)
                \\   AND state_kind=2;
            ;
            if (c.sqlite3_prepare_v2(self.db, remove_sql, -1, &remove, null) != c.SQLITE_OK) return error.Prepare;
            defer _ = c.sqlite3_finalize(remove);
            bindText(remove, 1, key.workspace);
            bindText(remove, 2, key.repository);
            bindInt(remove, 3, @intCast(key.pull_request_id));
            bindInt(remove, 4, @intCast(operation_id));
            if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.Step;
        }

        var cleanup_items: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM submission_run_items WHERE operation_id=?;", -1, &cleanup_items, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(cleanup_items);
        bindInt(cleanup_items, 1, @intCast(operation_id));
        if (c.sqlite3_step(cleanup_items) != c.SQLITE_DONE) return error.Step;

        var cleanup_run: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM submission_runs WHERE operation_id=? AND state!=0;", -1, &cleanup_run, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(cleanup_run);
        bindInt(cleanup_run, 1, @intCast(operation_id));
        if (c.sqlite3_step(cleanup_run) != c.SQLITE_DONE) return error.Step;

        try self.exec("COMMIT;");
    }

    fn abandonSubmissionImpl(ptr: *anyopaque, operation_id: OperationId, key: RemoteReviewIdentity) anyerror!void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        var draft: ?*c.sqlite3_stmt = null;
        const draft_sql =
            \\UPDATE drafts SET state_kind=4, state_id=NULL, state_err=NULL
            \\ WHERE workspace=? AND repository=? AND pr_id=? AND state_kind=1
            \\   AND local_id=(SELECT current_temp_id FROM submission_runs
            \\     WHERE operation_id=? AND workspace=? AND repository=? AND pr_id=? AND state=0);
        ;
        if (c.sqlite3_prepare_v2(self.db, draft_sql, -1, &draft, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(draft);
        bindText(draft, 1, key.workspace);
        bindText(draft, 2, key.repository);
        bindInt(draft, 3, @intCast(key.pull_request_id));
        bindInt(draft, 4, @intCast(operation_id));
        bindText(draft, 5, key.workspace);
        bindText(draft, 6, key.repository);
        bindInt(draft, 7, @intCast(key.pull_request_id));
        if (c.sqlite3_step(draft) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCompletion;

        var items: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM submission_run_items WHERE operation_id=?;", -1, &items, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(items);
        bindInt(items, 1, @intCast(operation_id));
        if (c.sqlite3_step(items) != c.SQLITE_DONE) return error.Step;

        var run: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM submission_runs WHERE operation_id=? AND workspace=? AND repository=? AND pr_id=? AND state=0;", -1, &run, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(run);
        bindInt(run, 1, @intCast(operation_id));
        bindText(run, 2, key.workspace);
        bindText(run, 3, key.repository);
        bindInt(run, 4, @intCast(key.pull_request_id));
        if (c.sqlite3_step(run) != c.SQLITE_DONE) return error.Step;
        if (c.sqlite3_changes(self.db) != 1) return error.InvalidSubmissionCompletion;
        try self.exec("COMMIT;");
    }

    /// Must be called inside a write transaction so an active SubmissionRun
    /// cannot appear between this check and the mutation.
    fn draftMutationLocked(self: *SqliteStore, key: RemoteReviewIdentity, local_id: TempId, incoming_target: ?CommentTarget) SqliteError!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql =
            \\SELECT
            \\  EXISTS(SELECT 1 FROM submission_runs r
            \\    JOIN submission_run_items i ON i.operation_id=r.operation_id
            \\    WHERE r.workspace=? AND r.repository=? AND r.pr_id=? AND r.state=0 AND i.temp_id=?),
            \\  COALESCE((SELECT target FROM drafts
            \\    WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?), -1),
            \\  COALESCE((SELECT state_kind FROM drafts
            \\    WHERE workspace=? AND repository=? AND pr_id=? AND local_id=?), -1);
        ;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key.workspace);
        bindText(stmt, 2, key.repository);
        bindInt(stmt, 3, @intCast(key.pull_request_id));
        bindInt(stmt, 4, @intCast(local_id));
        bindText(stmt, 5, key.workspace);
        bindText(stmt, 6, key.repository);
        bindInt(stmt, 7, @intCast(key.pull_request_id));
        bindInt(stmt, 8, @intCast(local_id));
        bindText(stmt, 9, key.workspace);
        bindText(stmt, 10, key.repository);
        bindInt(stmt, 11, @intCast(key.pull_request_id));
        bindInt(stmt, 12, @intCast(local_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Step;
        if (columnInt(stmt, 2) == 4) return true;
        _ = incoming_target;
        return columnInt(stmt, 0) != 0;
    }

    fn claimLegacyRows(self: *SqliteStore, key: RemoteReviewIdentity) SqliteError!void {
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

        const path = if (parent == null) try columnTextDup(allocator, stmt, 5) else null;
        const scope_kind = if (c.sqlite3_column_type(stmt, 18) == c.SQLITE_NULL) null else columnInt(stmt, 18);
        var scope: ?bbr.review.CommentScope = null;
        var anchor: ?Anchor = null;
        if (parent == null) if (scope_kind) |kind| switch (kind) {
            0 => scope = .review,
            1 => scope = .{ .file = .{
                .path = path orelse return error.Step,
                .source_commit = (try columnTextDup(allocator, stmt, 19)) orelse return error.Step,
            } },
            2 => {
                anchor = .{
                    .path = path orelse return error.Step,
                    .from = columnOptU32(stmt, 6),
                    .to = columnOptU32(stmt, 7),
                    .commit = try columnTextDup(allocator, stmt, 8),
                    .start_from = columnOptU32(stmt, 13),
                    .start_to = columnOptU32(stmt, 14),
                };
                scope = .{ .@"inline" = anchor.? };
            },
            else => return error.Step,
        };

        const state: DraftState = switch (columnInt(stmt, 10)) {
            2 => .{ .posted = @intCast(columnInt(stmt, 11)) },
            3 => .{ .failed = apiErrorFromName((try columnTextDup(allocator, stmt, 12)) orelse "") },
            4 => .outcome_unknown,
            1 => .submitting,
            else => .draft,
        };

        const snapshot = if (try columnTextDup(allocator, stmt, 15)) |text| bbr.review.AnchorSnapshot{
            .text = text,
            .selection_start = @intCast(columnInt(stmt, 16)),
            .selection_len = @intCast(columnInt(stmt, 17)),
        } else null;

        return .{
            .local_id = @intCast(columnInt(stmt, 0)),
            .kind = @enumFromInt(columnInt(stmt, 1)),
            .target = @enumFromInt(columnInt(stmt, 2)),
            .scope = scope,
            .anchor = anchor,
            .snapshot = snapshot,
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
fn bindSubmissionOutcome(stmt: ?*c.sqlite3_stmt, outcome: SubmissionOutcome) void {
    switch (outcome) {
        .posted => |id| {
            bindInt(stmt, 1, 2);
            bindInt(stmt, 2, @intCast(id));
            bindNull(stmt, 3);
        },
        .failed => |err| {
            bindInt(stmt, 1, 3);
            bindNull(stmt, 2);
            bindText(stmt, 3, @errorName(err));
        },
        .outcome_unknown => {
            bindInt(stmt, 1, 4);
            bindNull(stmt, 2);
            bindNull(stmt, 3);
        },
    }
}
fn bindSubmissionPendingState(stmt: ?*c.sqlite3_stmt, state: SubmissionPendingState) void {
    switch (state) {
        .draft => {
            bindInt(stmt, 1, 0);
            bindNull(stmt, 2);
            bindNull(stmt, 3);
        },
        .failed => |err| {
            bindInt(stmt, 1, 3);
            bindNull(stmt, 2);
            bindText(stmt, 3, @errorName(err));
        },
        .outcome_unknown => {
            bindInt(stmt, 1, 4);
            bindNull(stmt, 2);
            bindNull(stmt, 3);
        },
    }
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

fn testReviewKey(pull_request_id: u64) RemoteReviewIdentity {
    return .{ .workspace = "workspace", .repository = "repo", .pull_request_id = pull_request_id };
}

test "in-memory round-trip preserves fields, anchor, parent, and state" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();

    try store.put(testReviewKey(7), .{
        .local_id = 1,
        .kind = .comment,
        .target = .bitbucket,
        .anchor = .{ .path = "src/f.zig", .from = 3, .to = 12, .start_to = 9, .commit = "deadbeef" },
        .snapshot = .{ .text = "before\nselected\nafter", .selection_start = 1, .selection_len = 1 },
        .body = "needs a test",
        .state = .{ .posted = 555 },
    });
    try store.put(testReviewKey(7), .{
        .local_id = 2,
        .kind = .comment,
        .parent = .{ .draft = 1 },
        .body = "agreed",
        .state = .{ .failed = error.RateLimited },
    });
    try store.put(testReviewKey(7), .{
        .local_id = 3,
        .kind = .comment,
        .body = "unknown outcome",
        .state = .outcome_unknown,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.load(arena.allocator(), testReviewKey(7));

    try testing.expectEqual(@as(usize, 3), drafts.len);
    const d0 = drafts[0];
    try testing.expect(d0.kind == .comment);
    try testing.expectEqualStrings("src/f.zig", d0.anchor.?.path);
    try testing.expectEqual(@as(?u32, 3), d0.anchor.?.from);
    try testing.expectEqual(@as(?u32, 12), d0.anchor.?.to);
    try testing.expectEqual(@as(?u32, 9), d0.anchor.?.start_to); // range top round-trips
    try testing.expect(d0.anchor.?.start_from == null);
    try testing.expect(d0.anchor.?.isRange());
    try testing.expectEqualStrings("deadbeef", d0.anchor.?.commit.?);
    try testing.expectEqualStrings("before\nselected\nafter", d0.snapshot.?.text);
    try testing.expectEqual(@as(u32, 1), d0.snapshot.?.selection_start);
    try testing.expectEqual(@as(u32, 1), d0.snapshot.?.selection_len);
    try testing.expectEqualStrings("needs a test", d0.body);
    try testing.expectEqual(@as(CommentId, 555), d0.state.posted);

    const d1 = drafts[1];
    try testing.expect(d1.kind == .comment);
    try testing.expect(d1.parent.? == .draft and d1.parent.?.draft == 1);
    try testing.expect(d1.anchor == null);
    try testing.expectEqual(ApiError.RateLimited, d1.state.failed);
    try testing.expect(drafts[2].state == .outcome_unknown);
}

test "editing a persisted Draft body keeps every other authored fact" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(11);
    try store.put(key, .{
        .local_id = 3,
        .kind = .suggestion,
        .scope = .{ .@"inline" = .{ .path = "src/f.zig", .to = 12, .start_to = 9, .commit = "deadbeef" } },
        .snapshot = .{ .text = "before\nselected\nafter", .selection_start = 1, .selection_len = 1 },
        .body = "```suggestion\nold\n```",
        .state = .{ .failed = error.ServerError },
    });
    try store.put(key, .{ .local_id = 4, .kind = .comment, .parent = .{ .draft = 3 }, .body = "reply" });

    try store.editDraftBody(key, .{
        .temp_id = 3,
        .expected_kind = .suggestion,
        .expected_parent = null,
        .body = "```suggestion\nnew\n```",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.load(arena.allocator(), key);
    const edited = drafts[0];
    try testing.expectEqual(@as(TempId, 3), edited.local_id);
    try testing.expect(edited.kind == .suggestion);
    try testing.expectEqualStrings("```suggestion\nnew\n```", edited.body);
    try testing.expect(edited.state == .draft); // a real change retries as a fresh Draft
    try testing.expectEqualStrings("src/f.zig", edited.scope.?.@"inline".path);
    try testing.expectEqual(@as(?u32, 12), edited.scope.?.@"inline".to);
    try testing.expectEqual(@as(?u32, 9), edited.scope.?.@"inline".start_to);
    try testing.expectEqualStrings("deadbeef", edited.scope.?.@"inline".commit.?);
    try testing.expectEqualStrings("before\nselected\nafter", edited.snapshot.?.text);
    try testing.expectEqualStrings("reply", drafts[1].body);
    try testing.expect(drafts[1].parent.? == .draft and drafts[1].parent.?.draft == 3);
}

test "a persisted edit refuses unknown, mismatched, in-flight, and run-owned Drafts" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(12);
    const other: RemoteReviewIdentity = .{ .workspace = "workspace", .repository = "other", .pull_request_id = 12 };
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "participant" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .body = "bystander" });
    try store.put(key, .{ .local_id = 3, .kind = .comment, .body = "posted", .state = .{ .posted = 90 } });
    const edit: DraftBodyEdit = .{ .temp_id = 1, .expected_kind = .comment, .expected_parent = null, .body = "changed" };

    try testing.expectError(error.DraftNotFound, store.editDraftBody(key, .{
        .temp_id = 77,
        .expected_kind = .comment,
        .expected_parent = null,
        .body = "changed",
    }));
    try testing.expectError(error.DraftNotFound, store.editDraftBody(other, edit));
    try testing.expectError(error.DraftEditConflict, store.editDraftBody(key, .{
        .temp_id = 1,
        .expected_kind = .comment,
        .expected_parent = .{ .draft = 2 },
        .body = "changed",
    }));
    try testing.expectError(error.DraftNotEditable, store.editDraftBody(key, .{
        .temp_id = 3,
        .expected_kind = .comment,
        .expected_parent = null,
        .body = "changed",
    }));

    _ = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try testing.expectError(error.DraftLocked, store.editDraftBody(key, edit));
    try store.editDraftBody(key, .{ .temp_id = 2, .expected_kind = .comment, .expected_parent = null, .body = "still mine" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqualStrings("participant", drafts[0].body);
    try testing.expectEqualStrings("still mine", drafts[1].body);
}

test "a persisted edit survives reopening the database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(testing.allocator, ".zig-cache/tmp/{s}/edit.db", .{&tmp.sub_path}, 0);
    defer testing.allocator.free(path);
    const key = testReviewKey(13);
    {
        var s = try SqliteStore.open(path);
        defer s.deinit();
        try s.store().put(key, .{ .local_id = 1, .kind = .comment, .body = "original" });
        try s.store().editDraftBody(key, .{
            .temp_id = 1,
            .expected_kind = .comment,
            .expected_parent = null,
            .body = "persisted edit",
        });
    }
    var reopened = try SqliteStore.open(path);
    defer reopened.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try reopened.store().load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 1), drafts.len);
    try testing.expectEqualStrings("persisted edit", drafts[0].body);
}

test "SQLite round-trip preserves exhaustive root scope and File authored commit" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    try store.put(testReviewKey(8), .{ .local_id = 1, .kind = .comment, .scope = .review, .body = "review" });
    try store.put(testReviewKey(8), .{ .local_id = 2, .kind = .comment, .scope = .{ .file = .{ .path = "src/f.zig", .source_commit = "source-abc" } }, .body = "file" });
    try store.put(testReviewKey(8), .{ .local_id = 3, .kind = .comment, .scope = .{ .@"inline" = .{ .path = "src/f.zig", .to = 7, .commit = "source-abc" } }, .body = "line" });
    try store.put(testReviewKey(8), .{ .local_id = 4, .kind = .comment, .scope = .review, .parent = .{ .draft = 2 }, .body = "reply" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const drafts = try store.load(arena.allocator(), testReviewKey(8));
    try testing.expect(drafts[0].scope.? == .review);
    try testing.expect(drafts[1].scope.? == .file);
    try testing.expectEqualStrings("src/f.zig", drafts[1].scope.?.file.path);
    try testing.expectEqualStrings("source-abc", drafts[1].scope.?.file.source_commit);
    try testing.expect(drafts[2].scope.? == .@"inline");
    try testing.expectEqual(@as(?u32, 7), drafts[2].scope.?.@"inline".to);
    try testing.expect(drafts[3].scope == null);
}

test "put replaces on key; remove deletes; both scope to the PR" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();

    try store.put(testReviewKey(1), .{ .local_id = 1, .kind = .comment, .body = "first" });
    try store.put(testReviewKey(1), .{ .local_id = 1, .kind = .comment, .body = "edited" }); // replace
    try store.put(testReviewKey(1), .{ .local_id = 2, .kind = .comment, .body = "second" });
    try store.put(testReviewKey(2), .{ .local_id = 1, .kind = .comment, .body = "other pr" });
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
    const alpha: RemoteReviewIdentity = .{ .workspace = "ws", .repository = "alpha", .pull_request_id = 7 };
    const beta: RemoteReviewIdentity = .{ .workspace = "ws", .repository = "beta", .pull_request_id = 7 };

    try store.put(alpha, .{ .local_id = 1, .kind = .comment, .body = "alpha" });
    try store.put(beta, .{ .local_id = 1, .kind = .comment, .body = "beta" });

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
        \\ VALUES (42, 1, 0, 0, 0, 'legacy review', 0);
        \\INSERT INTO drafts (pr_id, local_id, kind, target, parent_kind, body, state_kind, anchor_path, anchor_to, anchor_commit)
        \\ VALUES (42, 2, 1, 0, 0, 'legacy inline', 0, 'src/f.zig', 9, 'old-source');
        \\INSERT INTO drafts (pr_id, local_id, kind, target, parent_kind, parent_id, body, state_kind, anchor_path, anchor_to)
        \\ VALUES (42, 3, 2, 0, 1, 2, 'legacy reply', 0, 'wire-echo', 99);
        \\PRAGMA user_version = 2;
    , null, null, null));
    _ = c.sqlite3_close(legacy.?);
    legacy = null;

    var upgraded = try SqliteStore.open(path);
    defer upgraded.deinit();
    const key: RemoteReviewIdentity = .{ .workspace = "ws", .repository = "repo", .pull_request_id = 42 };
    const drafts = try upgraded.store().load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 3), drafts.len);
    try testing.expectEqualStrings("legacy review", drafts[0].body);
    try testing.expect(drafts[0].scope.? == .review);
    try testing.expect(drafts[1].scope.? == .@"inline");
    try testing.expectEqualStrings("src/f.zig", drafts[1].scope.?.@"inline".path);
    try testing.expectEqualStrings("old-source", drafts[1].scope.?.@"inline".commit.?);
    try testing.expect(drafts[2].scope == null);

    const other: RemoteReviewIdentity = .{ .workspace = "ws", .repository = "other", .pull_request_id = 42 };
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
        try store.put(testReviewKey(42), .{ .local_id = 1, .kind = .comment, .body = "persist me" });
        try store.put(testReviewKey(42), .{ .local_id = 2, .kind = .comment, .parent = .{ .comment = 900 }, .body = "reply to remote" });
    }

    // Reopen: a fresh handle over the same file resumes the review.
    var s2 = try SqliteStore.open(path);
    defer s2.deinit();
    var review = try s2.store().loadReview(a, testReviewKey(42));
    try testing.expectEqual(@as(usize, 2), review.drafts.items.len);
    try testing.expectEqualStrings("persist me", review.get(1).?.body);
    try testing.expect(review.get(2).?.parent.? == .comment);
    // next_id resumes past the loaded drafts.
    const fresh = try review.add(a, .{ .kind = .comment, .body = "new" });
    try testing.expectEqual(@as(TempId, 3), fresh);
}

test "Submission checkpoint survives closing and reopening the database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}/submission.db", .{&tmp.sub_path}, 0);
    const key = testReviewKey(42);
    var operation_id: OperationId = undefined;

    {
        var s = try SqliteStore.open(path);
        defer s.deinit();
        const store = s.store();
        try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "first" });
        try store.put(key, .{ .local_id = 2, .kind = .comment, .body = "second", .state = .{ .failed = error.ServerError } });
        operation_id = try store.beginSubmission(key, "source-commit", &.{ .{ .temp_id = 1, .parent = null }, .{ .temp_id = 2, .parent = null } });
        try store.checkpointSubmission(operation_id, key, 1, .{ .posted = 900 }, 2);
    }

    var reopened = try SqliteStore.open(path);
    defer reopened.deinit();
    const store = reopened.store();
    const run = (try store.activeSubmission(arena.allocator())).?;
    try testing.expectEqual(operation_id, run.operation_id);
    try testing.expectEqual(@as(?TempId, 2), run.current_temp_id);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqual(@as(CommentId, 900), drafts[0].state.posted);
    try testing.expect(drafts[1].state == .submitting);

    try store.checkpointSubmission(operation_id, key, 2, .{ .posted = 901 }, null);
    try store.completeSubmission(operation_id, key, .clean);
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    const after_completion = try store.load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 0), after_completion.len);
}

test "a rejected SQLite Submission checkpoint rolls back its completed outcome" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "first" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});

    try testing.expectError(error.InvalidSubmissionCheckpoint, store.checkpointSubmission(operation_id, key, 1, .{ .posted = 900 }, 99));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = (try store.activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(?TempId, 1), run.current_temp_id);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expect(drafts[0].state == .submitting);
}

test "SQLite locks Bitbucket Draft mutation during an active Submission" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "remote" });
    try store.put(key, .{ .local_id = 2, .kind = .comment, .target = .local, .body = "local" });
    _ = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});

    try testing.expectError(error.DraftLocked, store.remove(key, 1));
    try store.put(key, .{ .local_id = 2, .kind = .comment, .target = .local, .body = "changed local" });
    try store.remove(key, 2);
}

test "SQLite keeps an unresolved outcome immutable after partial completion" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "unknown" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try store.checkpointSubmission(operation_id, key, 1, .outcome_unknown, null);
    try store.completeSubmission(operation_id, key, .partial);

    try testing.expectError(error.DraftLocked, store.put(key, .{ .local_id = 1, .kind = .comment, .body = "changed" }));
    try testing.expectError(error.DraftLocked, store.remove(key, 1));
    try store.resolveUnknown(key, 1, .{ .posted = 812 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(CommentId, 812), (try store.load(arena.allocator(), key))[0].state.posted);
}

test "SQLite rejects clean completion while a Bitbucket Draft failed" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "failed" });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});
    try store.checkpointSubmission(operation_id, key, 1, .{ .failed = error.Forbidden }, null);

    try testing.expectError(error.SubmissionNotClean, store.completeSubmission(operation_id, key, .clean));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) != null);
}

test "SQLite aborted completion restores the current Draft and closes partial" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const key = testReviewKey(7);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "retry", .state = .{ .failed = error.ServerError } });
    const operation_id = try store.beginSubmission(key, "source-commit", &.{.{ .temp_id = 1, .parent = null }});

    try store.completeSubmission(operation_id, key, .{ .aborted = .{ .failed = error.ServerError } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    const drafts = try store.load(arena.allocator(), key);
    try testing.expectEqual(ApiError.ServerError, drafts[0].state.failed);
}

test "SQLite reports an already-active Submission consistently" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const first = testReviewKey(7);
    const second = testReviewKey(8);
    try store.put(first, .{ .local_id = 1, .kind = .comment, .body = "first" });
    try store.put(second, .{ .local_id = 1, .kind = .comment, .body = "second" });
    _ = try store.beginSubmission(first, "first-commit", &.{.{ .temp_id = 1, .parent = null }});

    try testing.expectError(error.SubmissionAlreadyActive, store.beginSubmission(second, "second-commit", &.{.{ .temp_id = 1, .parent = null }}));
}

test "SQLite repository aliases are durable and reject conflicting identities" {
    var s = try SqliteStore.open(":memory:");
    defer s.deinit();
    const store = s.store();
    const remote = "remote:example.test/team/repo";
    const common = "common:/work/repo/.git";
    const id = try store.resolveRepository(&.{remote});
    try testing.expectEqual(id, try store.resolveRepository(&.{ remote, common }));
    try testing.expectEqual(id, try store.resolveRepository(&.{common}));
    _ = try store.resolveRepository(&.{"remote:example.test/other/repo"});
    try testing.expectError(error.RepositoryIdentityConflict, store.resolveRepository(&.{ remote, "remote:example.test/other/repo" }));
}

test "SQLite serializes TempId reservations across connections" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}/ids.db", .{&tmp.sub_path}, 0);
    var first = try SqliteStore.open(path);
    defer first.deinit();
    var second = try SqliteStore.open(path);
    defer second.deinit();
    const key = testReviewKey(91);

    try testing.expectEqual(@as(TempId, 1), try first.store().reserveTempId(key));
    try testing.expectEqual(@as(TempId, 2), try second.store().reserveTempId(key));
    try testing.expectEqual(@as(TempId, 3), try first.store().reserveTempId(key));
}

test "SQLite reopens the exact frozen participant graph and ignores later Drafts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}/frozen.db", .{&tmp.sub_path}, 0);
    const key = testReviewKey(42);

    {
        var sqlite = try SqliteStore.open(path);
        defer sqlite.deinit();
        const store = sqlite.store();
        try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "root" });
        try store.put(key, .{ .local_id = 2, .kind = .comment, .body = "reply", .parent = .{ .draft = 1 } });
        _ = try store.beginSubmission(key, "source", &.{ .{ .temp_id = 1, .parent = null }, .{ .temp_id = 2, .parent = .{ .draft = 1 } } });
        try store.put(key, .{ .local_id = 3, .kind = .comment, .body = "later" });
    }

    var reopened = try SqliteStore.open(path);
    defer reopened.deinit();
    const run = (try reopened.store().activeSubmission(arena.allocator())).?;
    try testing.expectEqual(@as(usize, 2), run.items.len);
    try testing.expectEqual(@as(TempId, 1), run.items[0].temp_id);
    try testing.expectEqual(@as(TempId, 2), run.items[1].temp_id);
    try testing.expect(run.items[1].parent.? == .draft and run.items[1].parent.?.draft == 1);
}

test "SQLite abandonment terminalizes the run and retains outcome evidence" {
    var sqlite = try SqliteStore.open(":memory:");
    defer sqlite.deinit();
    const store = sqlite.store();
    const key = testReviewKey(9);
    try store.put(key, .{ .local_id = 1, .kind = .comment, .body = "ambiguous" });
    const operation_id = try store.beginSubmission(key, "source", &.{.{ .temp_id = 1, .parent = null }});

    try store.abandonSubmission(operation_id, key);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.activeSubmission(arena.allocator())) == null);
    try testing.expect((try store.load(arena.allocator(), key))[0].state == .outcome_unknown);
}

test "v8 migration preserves every authored Draft field and lifecycle state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}/v7.db", .{&tmp.sub_path}, 0);
    const key = testReviewKey(51);

    {
        var sqlite = try SqliteStore.open(path);
        defer sqlite.deinit();
        try sqlite.store().put(key, .{
            .local_id = 4,
            .kind = .suggestion,
            .scope = .{ .@"inline" = .{ .path = "src/main.zig", .to = 9, .start_to = 8, .commit = "source" } },
            .snapshot = .{ .text = "before\nselected\nafter", .selection_start = 1, .selection_len = 1 },
            .body = "```suggestion\nreplacement\n```",
            .state = .{ .failed = error.ServerError },
        });
        try sqlite.store().put(key, .{
            .local_id = 5,
            .kind = .comment,
            .parent = .{ .draft = 4 },
            .body = "reply",
            .state = .outcome_unknown,
        });
        try sqlite.exec("DROP TABLE submission_run_items; PRAGMA user_version = 7;");
    }

    var upgraded = try SqliteStore.open(path);
    defer upgraded.deinit();
    const drafts = try upgraded.store().load(arena.allocator(), key);
    try testing.expectEqual(@as(usize, 2), drafts.len);
    try testing.expectEqual(@as(TempId, 4), drafts[0].local_id);
    try testing.expect(drafts[0].kind == .suggestion);
    try testing.expectEqualStrings("src/main.zig", drafts[0].scope.?.@"inline".path);
    try testing.expectEqual(@as(?u32, 8), drafts[0].scope.?.@"inline".start_to);
    try testing.expectEqualStrings("source", drafts[0].scope.?.@"inline".commit.?);
    try testing.expectEqualStrings("before\nselected\nafter", drafts[0].snapshot.?.text);
    try testing.expectEqualStrings("```suggestion\nreplacement\n```", drafts[0].body);
    try testing.expectEqual(ApiError.ServerError, drafts[0].state.failed);
    try testing.expect(drafts[1].parent.? == .draft and drafts[1].parent.?.draft == 4);
    try testing.expect(drafts[1].state == .outcome_unknown);
}
