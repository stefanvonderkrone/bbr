//! Production execution policy for Presentation commands.
//!
//! Presentation decides which remote action is valid; this adapter performs
//! that action without owning Session or Submission state. Every caller turns
//! the result back into a typed `OwnedInput` for serialized admission.

const bbr = @import("bbr");
const std = @import("std");
const vaxis = @import("vaxis");
const presentation = @import("presentation.zig");
const browser = @import("browser.zig");

pub fn checkRecovery(allocator: std.mem.Allocator, client: bbr.bitbucket.Client, command: presentation.CheckRecovery) presentation.OwnedInput {
    const pr = client.getPullRequest(allocator, command.identity.repository(), command.identity.pullRequestId()) catch |err| return .{ .recovery_checked = .{
        .command_id = command.command_id,
        .operation_id = command.operation_id,
        .identity = command.identity,
        .outcome = .{ .failed = bbr.diagnostic.Failure.capture(.recovery_check, .execute, .{ .command_id = command.command_id, .operation_id = command.operation_id }, .{ .zig = err }, @src()) },
    } };
    return presentation.recoveryCheckSucceeded(command.command_id, command.operation_id, command.identity, pr.source_commit);
}

pub fn listPullRequests(allocator: std.mem.Allocator, client: bbr.bitbucket.Client, command: presentation.ListPullRequests) presentation.OwnedInput {
    const summaries = presentation.PullRequestSummaries.create(allocator) catch |err| return .{ .pull_requests_loaded = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .outcome = .{ .failed = bbr.diagnostic.Failure.capture(.picker_list, .prepare, .{ .command_id = command.command_id, .work_id = command.work_id }, .{ .zig = err }, @src()) },
    } };
    summaries.prs = client.listPullRequests(summaries.arena.allocator(), command.repositoryName(), .{}) catch |err| {
        summaries.destroy();
        return .{ .pull_requests_loaded = .{
            .command_id = command.command_id,
            .work_id = command.work_id,
            .outcome = .{ .failed = bbr.diagnostic.Failure.capture(.picker_list, .execute, .{ .command_id = command.command_id, .work_id = command.work_id }, .{ .zig = err }, @src()) },
        } };
    };
    return .{ .pull_requests_loaded = .{ .command_id = command.command_id, .work_id = command.work_id, .outcome = .{ .loaded = summaries } } };
}

pub const TerminalHandoff = struct {
    ptr: *anyopaque,
    suspend_fn: *const fn (*anyopaque) anyerror!void,
    restore_fn: *const fn (*anyopaque) anyerror!void,

    pub fn leaveTui(self: TerminalHandoff) !void {
        return self.suspend_fn(self.ptr);
    }

    pub fn resumeTui(self: TerminalHandoff) !void {
        return self.restore_fn(self.ptr);
    }
};

pub fn resolveEditor(env: *const std.process.Environ.Map) ?[]const u8 {
    inline for (.{ "GIT_EDITOR", "VISUAL", "EDITOR" }) |name| {
        if (env.get(name)) |value| if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    return null;
}

fn editorArgv(editor: []const u8, path: []const u8) [6][]const u8 {
    return .{
        "/bin/sh",
        "-c",
        "editor=$1; path=$2; eval \"set -- $editor\"; exec \"$@\" \"$path\"",
        "bbr-external-edit",
        editor,
        path,
    };
}

/// Consumes `command`. Terminal restoration errors are reported distinctly so
/// the caller can leave the retained Markdown path visible before exiting.
pub fn externalEdit(
    io: std.Io,
    env: *const std.process.Environ.Map,
    handoff: TerminalHandoff,
    command: *presentation.ExternalEdit,
) !*presentation.ExternalEditCompleted {
    defer command.destroy();
    const completed = try presentation.ExternalEditCompleted.create(command.allocator, command.command_id, command.session_epoch);
    const a = completed.arena.allocator();
    const editor = resolveEditor(env) orelse {
        completed.outcome = .missing_editor;
        return completed;
    };
    if (std.mem.eql(u8, std.mem.trim(u8, editor, " \t\r\n"), "/bin/sh")) {
        completed.outcome = .invalid_editor;
        return completed;
    }

    const temp_base = env.get("TMPDIR") orelse "/tmp";
    var random_bytes: [8]u8 = undefined;
    io.randomSecure(&random_bytes) catch |err| {
        completed.evidence = externalEditFailure(command, .prepare, err, @src());
        completed.outcome = .failed;
        return completed;
    };
    const nonce = std.mem.readInt(u64, &random_bytes, .native);
    const dir_path = std.fmt.allocPrint(a, "{s}/bbr-external-edit-{x}", .{ temp_base, nonce }) catch |err| {
        completed.evidence = externalEditFailure(command, .prepare, err, @src());
        completed.outcome = .failed;
        return completed;
    };
    const file_path = std.fmt.allocPrint(a, "{s}/body.md", .{dir_path}) catch |err| {
        completed.evidence = externalEditFailure(command, .prepare, err, @src());
        completed.outcome = .failed;
        return completed;
    };
    std.Io.Dir.cwd().createDir(io, dir_path, @enumFromInt(0o700)) catch |err| {
        completed.evidence = externalEditFailure(command, .open, err, @src());
        completed.outcome = .failed;
        return completed;
    };
    var retain = true;
    defer if (!retain) std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| {
        completed.secondary_evidence = externalEditFailure(command, .cleanup, err, @src());
    };
    var file = std.Io.Dir.cwd().createFile(io, file_path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    }) catch |err| {
        completed.evidence = externalEditFailure(command, .open, err, @src());
        completed.outcome = .failed;
        retain = false;
        return completed;
    };
    file.writeStreamingAll(io, command.body) catch |err| {
        completed.evidence = externalEditFailure(command, .write, err, @src());
        file.close(io);
        completed.outcome = .failed;
        retain = false;
        return completed;
    };
    file.close(io);

    handoff.leaveTui() catch |err| {
        completed.evidence = externalEditFailure(command, .prepare, err, @src());
        completed.outcome = .{ .restoration_failed = file_path };
        return completed;
    };
    const argv = editorArgv(editor, file_path);
    var child = std.process.spawn(io, .{ .argv = &argv, .cwd = .inherit }) catch |err| {
        completed.evidence = externalEditFailure(command, .launch, err, @src());
        if (handoff.resumeTui()) |_| {
            completed.outcome = .failed;
            retain = false;
        } else |restore_error| {
            completed.secondary_evidence = externalEditFailure(command, .cleanup, restore_error, @src());
            completed.outcome = .{ .restoration_failed = file_path };
        }
        return completed;
    };
    const term = child.wait(io) catch |err| {
        completed.evidence = externalEditFailure(command, .execute, err, @src());
        if (handoff.resumeTui()) |_| {
            completed.outcome = .failed;
            retain = false;
        } else |restore_error| {
            completed.secondary_evidence = externalEditFailure(command, .cleanup, restore_error, @src());
            completed.outcome = .{ .restoration_failed = file_path };
        }
        return completed;
    };
    if (handoff.resumeTui()) |_| {} else |err| {
        completed.evidence = externalEditFailure(command, .cleanup, err, @src());
        completed.outcome = .{ .restoration_failed = file_path };
        return completed;
    }
    switch (term) {
        .exited => |code| if (code != 0) {
            completed.outcome = .cancelled;
            retain = false;
            return completed;
        },
        else => {
            completed.evidence = bbr.diagnostic.Failure.capture(.external_edit, .execute, .{ .command_id = command.command_id, .session_epoch = command.session_epoch }, .{ .git = switch (term) {
                .signal => |code| .{ .kind = .signal, .code = @intFromEnum(code) },
                .stopped => |code| .{ .kind = .stopped, .code = @intFromEnum(code) },
                .unknown => |code| .{ .kind = .unknown, .code = code },
                .exited => unreachable,
            } }, @src());
            completed.outcome = .failed;
            retain = false;
            return completed;
        },
    }
    const read_limit = if (command.max_bytes == std.math.maxInt(usize)) command.max_bytes else command.max_bytes + 1;
    const returned = std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(read_limit)) catch |err| {
        switch (err) {
            error.StreamTooLong => {},
            else => completed.evidence = externalEditFailure(command, .read, err, @src()),
        }
        completed.outcome = switch (err) {
            error.StreamTooLong => .too_large,
            else => .failed,
        };
        retain = false;
        return completed;
    };
    if (returned.len > command.max_bytes) {
        completed.outcome = .too_large;
        retain = false;
        return completed;
    }
    if (std.mem.indexOfScalar(u8, returned, 0) != null) {
        completed.outcome = .contains_nul;
        retain = false;
        return completed;
    }
    if (!std.unicode.utf8ValidateSlice(returned)) {
        completed.outcome = .invalid_utf8;
        retain = false;
        return completed;
    }
    if (std.mem.eql(u8, returned, command.body)) {
        completed.outcome = .unchanged;
        retain = false;
        return completed;
    }
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| {
        completed.evidence = externalEditFailure(command, .cleanup, err, @src());
        completed.outcome = .{ .cleanup_failed = .{ .body = returned, .path = file_path } };
        return completed;
    };
    retain = true;
    completed.outcome = .{ .changed = returned };
    return completed;
}

fn externalEditFailure(command: *const presentation.ExternalEdit, phase: bbr.diagnostic.Phase, err: anyerror, comptime source: std.builtin.SourceLocation) bbr.diagnostic.Failure {
    return bbr.diagnostic.Failure.capture(.external_edit, phase, .{ .command_id = command.command_id, .session_epoch = command.session_epoch }, .{ .zig = err }, source);
}

/// Consumes Presentation-owned source bytes at the terminal boundary and
/// reports whether OSC 52 was written successfully.
pub fn copyToClipboard(vx: vaxis.Vaxis, tty: *std.Io.Writer, command: *presentation.ClipboardCopy) presentation.OwnedInput {
    defer command.destroy();
    vx.copyToSystemClipboard(tty, command.text, command.allocator) catch |err| return .{ .clipboard_completed = .{ .command_id = command.command_id, .success = false, .evidence = bbr.diagnostic.Failure.capture(.clipboard, .write, .{ .command_id = command.command_id }, .{ .zig = err }, @src()) } };
    return .{ .clipboard_completed = .{ .command_id = command.command_id, .success = true } };
}

pub fn postOutcome(
    poster: bbr.review.CommentPoster,
    draft: bbr.review.Draft,
    parent: ?bbr.review.CommentId,
    dedupe: bool,
) !bbr.review.PostOutcome {
    if (dedupe) {
        const checked = try poster.findExisting(draft, parent);
        return switch (checked.outcome) {
            .found => |id| .{ .posted = id },
            .missing => (try poster.post(draft, parent)).outcome,
            .rejected => |err| .{ .rejected = err },
            .ambiguous => .ambiguous,
        };
    }
    return (try poster.post(draft, parent)).outcome;
}

/// Consumes `command` whether execution succeeds or fails.
pub fn executePost(command: *presentation.PostDraft, poster: bbr.review.CommentPoster) presentation.OwnedInput {
    defer command.destroy();
    var evidence: ?bbr.diagnostic.Failure = null;
    const context: bbr.diagnostic.Context = .{ .command_id = command.command_id, .operation_id = command.operation_id, .draft_id = command.draft.local_id };
    const result = if (command.dedupe) blk: {
        if (poster.findExisting(command.draft, command.parent)) |checked| {
            break :blk switch (checked.outcome) {
                .found => |id| bbr.review.PostResult{ .outcome = .{ .posted = id } },
                .missing => poster.post(command.draft, command.parent) catch |err| failed: {
                    evidence = bbr.diagnostic.Failure.capture(.submission, .execute, context, .{ .zig = err }, @src());
                    break :failed bbr.review.PostResult{ .outcome = .ambiguous };
                },
                .rejected => |err| bbr.review.PostResult{ .outcome = .{ .rejected = err }, .retry_after_ms = checked.retry_after_ms },
                .ambiguous => bbr.review.PostResult{ .outcome = .ambiguous },
            };
        } else |err| {
            evidence = bbr.diagnostic.Failure.capture(.submission, .execute, context, .{ .zig = err }, @src());
            break :blk bbr.review.PostResult{ .outcome = .ambiguous };
        }
    } else poster.post(command.draft, command.parent) catch |err| blk: {
        evidence = bbr.diagnostic.Failure.capture(.submission, .execute, context, .{ .zig = err }, @src());
        break :blk bbr.review.PostResult{ .outcome = .ambiguous };
    };
    if (result.outcome == .rejected) evidence = bbr.diagnostic.Failure.capture(.submission, .rejection, context, .{ .zig = result.outcome.rejected }, @src());
    return .{ .post_draft_completed = .{
        .evidence = evidence,
        .command_id = command.command_id,
        .operation_id = command.operation_id,
        .identity = command.identity,
        .temp_id = command.draft.local_id,
        .outcome = result.outcome,
        .retry_after_ms = result.retry_after_ms,
    } };
}

pub fn executeCommentEdit(command: *presentation.UpdateComment, client: bbr.bitbucket.Client) presentation.OwnedInput {
    defer command.destroy();
    var evidence: ?bbr.diagnostic.Failure = null;
    const outcome: presentation.CommentEditOutcome = if (client.updateComment(
        command.allocator,
        command.identity.repository(),
        command.identity.pullRequestId(),
        command.comment_id,
        command.body,
    )) |_| .updated else |err| blk: {
        evidence = bbr.diagnostic.Failure.capture(.mutation, .execute, .{ .command_id = command.command_id }, .{ .zig = err }, @src());
        break :blk switch (err) {
            error.Unauthorized => .{ .definitive_failure = error.Unauthorized },
            error.Forbidden => .{ .definitive_failure = error.Forbidden },
            error.BadRequest => .{ .definitive_failure = error.BadRequest },
            error.NotFound => .{ .definitive_failure = error.NotFound },
            error.Conflict => .{ .definitive_failure = error.Conflict },
            error.RateLimited => .{ .definitive_failure = error.RateLimited },
            error.ServerError => .{ .definitive_failure = error.ServerError },
            error.UnexpectedStatus => .{ .definitive_failure = error.UnexpectedStatus },
            error.MalformedResponse => .{ .definitive_failure = error.MalformedResponse },
            else => .outcome_unknown,
        };
    };
    return .{ .comment_edit_completed = .{
        .evidence = evidence,
        .command_id = command.command_id,
        .identity = command.identity,
        .comment_id = command.comment_id,
        .outcome = outcome,
    } };
}

pub fn executeCommentDelete(command: *presentation.DeleteComment, client: bbr.bitbucket.Client) presentation.OwnedInput {
    defer command.destroy();
    var evidence: ?bbr.diagnostic.Failure = null;
    const outcome: presentation.CommentDeleteOutcome = if (client.deleteComment(
        command.allocator,
        command.identity.repository(),
        command.identity.pullRequestId(),
        command.comment_id,
    )) |_| .deleted else |err| blk: {
        switch (err) {
            error.NotFound => {},
            else => evidence = bbr.diagnostic.Failure.capture(.mutation, .execute, .{ .command_id = command.command_id }, .{ .zig = err }, @src()),
        }
        break :blk switch (err) {
            error.NotFound => .not_found,
            error.Unauthorized => .{ .definitive_failure = error.Unauthorized },
            error.Forbidden => .{ .definitive_failure = error.Forbidden },
            error.BadRequest => .{ .definitive_failure = error.BadRequest },
            error.Conflict => .{ .definitive_failure = error.Conflict },
            error.RateLimited => .{ .definitive_failure = error.RateLimited },
            error.ServerError => .{ .definitive_failure = error.ServerError },
            error.UnexpectedStatus => .{ .definitive_failure = error.UnexpectedStatus },
            error.MalformedResponse => .{ .definitive_failure = error.MalformedResponse },
            else => .outcome_unknown,
        };
    };
    return .{ .comment_delete_completed = .{
        .evidence = evidence,
        .command_id = command.command_id,
        .identity = command.identity,
        .comment_id = command.comment_id,
        .outcome = outcome,
    } };
}

pub fn executeReviewerVerdict(
    allocator: std.mem.Allocator,
    command: presentation.ChangeReviewerVerdict,
    client: bbr.bitbucket.Client,
) presentation.OwnedInput {
    const result = client.changeReviewerVerdict(
        allocator,
        command.identity.repository(),
        command.identity.pullRequestId(),
        command.expectedSourceCommit(),
        command.authenticatedAccountUuid(),
        command.target,
    ) catch |err| return .{ .reviewer_verdict_changed = .{
        .evidence = bbr.diagnostic.Failure.capture(.verdict, .execute, .{ .command_id = command.command_id }, .{ .zig = err }, @src()),
        .command_id = command.command_id,
        .identity = command.identity,
        .target = command.target,
        .outcome = .adapter_failed,
    } };
    const cause: ?anyerror = switch (result) {
        .api_error => |err| err,
        .unresolved => |err| err,
        .success, .reconciled_success, .stale_source_commit => null,
    };
    return .{ .reviewer_verdict_changed = .{
        .evidence = if (cause) |err| bbr.diagnostic.Failure.capture(
            .verdict,
            if (bbr.bitbucket.asApiError(err) != null) .rejection else .execute,
            .{ .command_id = command.command_id },
            .{ .zig = err },
            @src(),
        ) else null,
        .command_id = command.command_id,
        .identity = command.identity,
        .target = command.target,
        .outcome = .{ .completed = result },
    } };
}

/// Runs the remote step of Startup Detection. A failed detection and a name
/// that does not fit give a plain Browser.
pub fn detectAdjacentPullRequests(allocator: std.mem.Allocator, client: bbr.bitbucket.Client, command: presentation.DetectAdjacentPullRequests) presentation.OwnedInput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const detection = command.detection;
    const outcome = bbr.startup.detect(arena.allocator(), client, .{
        .repository = detection.repository.slice(),
        .branch = detection.branch.slice(),
        .named = detection.named,
    });
    return .{ .adjacent_detected = .{
        .command_id = command.command_id,
        .outcome = adjacentOutcome(detection.workspace, outcome) catch .{ .browse = .{ .workspace = detection.workspace } },
    } };
}

fn adjacentOutcome(workspace: browser.Name, outcome: bbr.startup.Outcome) !presentation.AdjacentOutcome {
    return switch (outcome) {
        .open => |target| .{ .open = try presentation.OwnedReviewIdentity.init(workspace.slice(), target.repository, target.id) },
        .browse => |browse| .{ .browse = try browserStart(workspace, browse) },
        .failed => |failed| .{ .browse = try browserStart(workspace, failed.browse) },
    };
}

/// The Browser Start for a Startup Detection result.
pub fn browserStart(workspace: browser.Name, browse: bbr.startup.Browse) !presentation.BrowserStart {
    return .{
        .workspace = workspace,
        .repository = if (browse.repository) |repository| try browser.Name.init(repository) else null,
        .pull_request_id = browse.pull_request_id,
    };
}

/// The first input of a remote run. A Repository or branch name that does
/// not fit gives a plain Browser.
pub fn startInput(workspace: []const u8, start: bbr.startup.Start) !presentation.OwnedInput {
    const name = try browser.Name.init(workspace);
    return switch (start) {
        .open => |target| .{ .choose_pull_request = try presentation.OwnedReviewIdentity.init(workspace, target.repository, target.id) },
        .detect => |detection| .{ .detect_startup = .{
            .workspace = name,
            .repository = browser.Name.init(detection.repository) catch return .{ .start_browser = .{ .workspace = name } },
            .branch = browser.Name.init(detection.branch) catch return .{ .start_browser = .{ .workspace = name } },
            .named = detection.named,
        } },
        .browse => |browse| .{ .start_browser = browserStart(name, browse) catch .{ .workspace = name } },
    };
}

/// Lists the Repository Summaries of the Workspace. The completion owns them.
pub fn listBrowserRepositories(allocator: std.mem.Allocator, client: bbr.bitbucket.Client, command: presentation.ListBrowserRepositories) presentation.OwnedInput {
    return .{ .browser_repositories_loaded = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .outcome = loadRepositories(allocator, client) catch |err| .{ .failed = browser.failure(err) },
    } };
}

fn loadRepositories(allocator: std.mem.Allocator, client: bbr.bitbucket.Client) !browser.RepositoriesOutcome {
    const summaries = try browser.RepositorySummaries.create(allocator);
    errdefer summaries.destroy();
    summaries.repositories = try client.listRepositorySummaries(summaries.arena.allocator());
    return .{ .loaded = summaries };
}

/// Lists the open PullRequest Summaries of one Repository. The completion
/// owns them.
pub fn listBrowserPullRequests(allocator: std.mem.Allocator, client: bbr.bitbucket.Client, command: presentation.ListBrowserPullRequests) presentation.OwnedInput {
    return .{ .browser_pull_requests_loaded = .{
        .command_id = command.command_id,
        .work_id = command.work_id,
        .outcome = loadPullRequests(allocator, client, command.repositoryName()) catch |err| .{ .failed = browser.failure(err) },
    } };
}

fn loadPullRequests(allocator: std.mem.Allocator, client: bbr.bitbucket.Client, repository: []const u8) !browser.PullRequestsOutcome {
    const summaries = try browser.PullRequestSummaries.create(allocator);
    errdefer summaries.destroy();
    summaries.prs = try client.listPullRequests(summaries.arena.allocator(), repository, .{});
    return .{ .loaded = summaries };
}

const summary_cache = bbr.bitbucket.summary_cache;
const summary_cache_permissions: std.Io.File.Permissions = @enumFromInt(0o600);

/// Reads the Summary Cache. A missing file, a parse error, another account,
/// or another Workspace gives an empty result. The completion owns the cache.
pub fn loadSummaryCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8, command: presentation.LoadSummaryCache) presentation.OwnedInput {
    return .{ .summary_cache_loaded = .{
        .command_id = command.command_id,
        .cache = readSummaryCache(allocator, io, path, command.account, command.workspaceName()),
    } };
}

fn readSummaryCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8, account: summary_cache.Account, workspace: []const u8) ?*browser.CachedSummaries {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(summary_cache.max_bytes + 1)) catch return null;
    defer allocator.free(bytes);
    const cache = browser.CachedSummaries.create(allocator) catch return null;
    const snapshot = summary_cache.decode(cache.arena.allocator(), bytes, account) orelse {
        cache.destroy();
        return null;
    };
    if (!std.mem.eql(u8, snapshot.workspace, workspace)) {
        cache.destroy();
        return null;
    }
    cache.snapshot = snapshot;
    return cache;
}

/// Writes the Summary Cache atomically with mode 0600 and consumes `command`.
pub fn saveSummaryCache(io: std.Io, path: []const u8, command: *presentation.SaveSummaryCache) presentation.OwnedInput {
    defer command.destroy();
    writeSummaryCache(io, path, command.bytes) catch return .{ .summary_cache_saved = .{ .command_id = command.command_id, .saved = false } };
    return .{ .summary_cache_saved = .{ .command_id = command.command_id, .saved = true } };
}

fn writeSummaryCache(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(io);
    const name = std.fs.path.basename(path);
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = true, .permissions = summary_cache_permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

const testing = std.testing;

test "diagnostics Picker and recovery preserve distinct original adapter errors" {
    for ([_]anyerror{ error.ConnectionReset, error.HostUnreachable }) |err| {
        var fake: bbr.http.FakeHttpClient = .{ .send_error = err };
        const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
        var repository: [256]u8 = undefined;
        @memcpy(repository[0..4], "repo");
        var picker = listPullRequests(testing.allocator, client, .{ .command_id = 31, .work_id = 41, .repository = .{ .bytes = repository, .len = 4 } });
        defer picker.deinit();
        try testing.expectEqual(err, picker.pull_requests_loaded.outcome.failed.cause.zig);
        try testing.expectEqual(@as(?u64, 31), picker.pull_requests_loaded.outcome.failed.context.command_id);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const recovery = checkRecovery(arena.allocator(), client, .{
            .command_id = 32,
            .operation_id = 42,
            .identity = .{ .value = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1) },
            .source_commit = .{ .bytes = [_]u8{0} ** 64, .len = 0 },
        });
        try testing.expectEqual(err, recovery.recovery_checked.outcome.failed.cause.zig);
        try testing.expectEqual(@as(?u64, 42), recovery.recovery_checked.outcome.failed.context.operation_id);
    }
}

test "diagnostics External Edit captures missing private parent before generic failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(parent);
    const missing = try std.fs.path.join(testing.allocator, &.{ parent, "missing", "private" });
    defer testing.allocator.free(missing);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_EDITOR", "vi");
    try env.put("TMPDIR", missing);
    var handoff = FakeHandoff{};
    const command = try testExternalEditCommand("secret body", 64);
    const id = command.command_id;
    const completed = try externalEdit(testing.io, &env, handoff.value(), command);
    defer completed.destroy();
    try testing.expect(completed.outcome == .failed);
    try testing.expectEqual(error.FileNotFound, completed.evidence.?.cause.zig);
    try testing.expectEqual(@as(?u64, id), completed.evidence.?.context.command_id);
    try testing.expectEqual(bbr.diagnostic.Operation.external_edit, completed.evidence.?.operation);
    try testing.expect(std.mem.endsWith(u8, completed.evidence.?.source.file, "presentation_adapter.zig"));
}

test "editor resolution uses first non-empty configured value" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_EDITOR", "   ");
    try env.put("VISUAL", "code --wait");
    try env.put("EDITOR", "vim");
    try testing.expectEqualStrings("code --wait", resolveEditor(&env).?);
    try env.put("GIT_EDITOR", "nvim");
    try testing.expectEqualStrings("nvim", resolveEditor(&env).?);
}

test "editor shell script keeps the temporary path out of evaluated text" {
    const argv = editorArgv("vim -f; touch /tmp/not-interpreted-here", "/tmp/a path/body.md");
    try testing.expectEqualStrings("/bin/sh", argv[0]);
    try testing.expectEqualStrings("bbr-external-edit", argv[3]);
    try testing.expectEqualStrings("vim -f; touch /tmp/not-interpreted-here", argv[4]);
    try testing.expectEqualStrings("/tmp/a path/body.md", argv[5]);
    try testing.expect(std.mem.indexOf(u8, argv[2], "exec \"$@\" \"$path\"") != null);
}

const FakeHandoff = struct {
    left: bool = false,
    resumed: bool = false,
    fail_resume: bool = false,

    fn value(self: *FakeHandoff) TerminalHandoff {
        return .{ .ptr = self, .suspend_fn = leaveTui, .restore_fn = resumeTui };
    }

    fn leaveTui(ptr: *anyopaque) !void {
        const self: *FakeHandoff = @ptrCast(@alignCast(ptr));
        self.left = true;
    }

    fn resumeTui(ptr: *anyopaque) !void {
        const self: *FakeHandoff = @ptrCast(@alignCast(ptr));
        self.resumed = true;
        if (self.fail_resume) return error.RestoreFailed;
    }
};

fn testExternalEditCommand(body: []const u8, max_bytes: usize) !*presentation.ExternalEdit {
    const command = try testing.allocator.create(presentation.ExternalEdit);
    command.* = .{
        .allocator = testing.allocator,
        .command_id = 17,
        .session_epoch = 23,
        .max_bytes = max_bytes,
        .body = try testing.allocator.dupe(u8, body),
    };
    return command;
}

test "External Edit writes exact bytes and returns validated changed content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("TMPDIR", base);
    try env.put("GIT_EDITOR", "sh -c 'test \"$(cat \"$1\")\" = exact && printf changed > \"$1\"' sh");
    var handoff: FakeHandoff = .{};

    const completed = try externalEdit(testing.io, &env, handoff.value(), try testExternalEditCommand("exact", 64));
    defer completed.destroy();
    try testing.expect(completed.outcome == .changed);
    try testing.expectEqualStrings("changed", completed.outcome.changed);
    try testing.expect(handoff.left and handoff.resumed);
    try testing.expectEqual(@as(presentation.CommandId, 17), completed.command_id);
}

test "External Edit distinguishes size validation and restoration failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("TMPDIR", base);
    try env.put("EDITOR", "sh -c 'printf too-large > \"$1\"' sh");
    var handoff: FakeHandoff = .{};
    const too_large = try externalEdit(testing.io, &env, handoff.value(), try testExternalEditCommand("old", 3));
    defer too_large.destroy();
    try testing.expect(too_large.outcome == .too_large);

    handoff = .{ .fail_resume = true };
    const failed = try externalEdit(testing.io, &env, handoff.value(), try testExternalEditCommand("old", 64));
    defer {
        if (failed.outcome == .restoration_failed)
            std.Io.Dir.cwd().deleteTree(testing.io, std.fs.path.dirname(failed.outcome.restoration_failed).?) catch {};
        failed.destroy();
    }
    try testing.expect(failed.outcome == .restoration_failed);
    var retained = try std.Io.Dir.cwd().openFile(testing.io, failed.outcome.restoration_failed, .{});
    retained.close(testing.io);
}

fn testDeleteCommand() !*presentation.DeleteComment {
    const command = try testing.allocator.create(presentation.DeleteComment);
    command.* = .{
        .allocator = testing.allocator,
        .command_id = 17,
        .identity = .{ .value = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1) },
        .comment_id = 42,
    };
    return command;
}

test "Review recovery Picker list failures surface once without a retry" {
    const cases = [_]struct { response: bbr.http.Canned, expected: anyerror }{
        .{ .response = .{ .status = 503 }, .expected = error.ServerError },
        .{ .response = .{ .status = 429, .retry_after_ms = 5000 }, .expected = error.RateLimited },
        .{ .response = .{ .body = "invalid JSON" }, .expected = error.MalformedResponse },
        .{ .response = .{ .send_error = error.ConnectionResetByPeer }, .expected = error.ConnectionResetByPeer },
    };
    var repository: [256]u8 = undefined;
    @memcpy(repository[0..4], "repo");
    const command: presentation.ListPullRequests = .{ .command_id = 31, .work_id = 41, .repository = .{ .bytes = repository, .len = 4 } };
    for (cases) |case| {
        const responses = [_]bbr.http.Canned{ case.response, .{ .body = "{\"values\":[]}" } };
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "test", .token = "test", .workspace = "workspace" });
        const failed = listPullRequests(testing.allocator, client, command).pull_requests_loaded.outcome.failed;
        try testing.expectEqual(bbr.diagnostic.Phase.execute, failed.phase);
        try testing.expectEqual(case.expected, failed.cause.zig);
        try testing.expectEqual(@as(usize, 1), fake.call_count);
        const loaded = listPullRequests(testing.allocator, client, command).pull_requests_loaded.outcome.loaded;
        loaded.destroy();
        try testing.expectEqual(@as(usize, 2), fake.call_count);
    }
}

test "Comment deletion adapter distinguishes not-found, definitive, and unknown outcomes" {
    const cases = [_]struct { status: u16, send_error: ?anyerror, expected: std.meta.Tag(presentation.CommentDeleteOutcome) }{
        .{ .status = 204, .send_error = null, .expected = .deleted },
        .{ .status = 404, .send_error = null, .expected = .not_found },
        .{ .status = 403, .send_error = null, .expected = .definitive_failure },
        .{ .status = 200, .send_error = error.ConnectionReset, .expected = .outcome_unknown },
    };
    for (cases) |case| {
        var fake: bbr.http.FakeHttpClient = .{ .status = case.status, .send_error = case.send_error };
        const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "workspace" });
        const input = executeCommentDelete(try testDeleteCommand(), client).comment_delete_completed;
        try testing.expectEqual(case.expected, std.meta.activeTag(input.outcome));
        try testing.expectEqual(@as(bbr.review.CommentId, 42), input.comment_id);
    }
}

const FakePoster = struct {
    existing: ?bbr.review.CommentId = null,
    posted: bbr.review.PostOutcome = .{ .posted = 900 },
    find_calls: usize = 0,
    post_calls: usize = 0,
    fail_post: bool = false,

    fn poster(self: *FakePoster) bbr.review.CommentPoster {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: bbr.review.CommentPoster.VTable = .{
        .post = post,
        .findExisting = findExisting,
    };

    fn post(ptr: *anyopaque, _: bbr.review.Draft, _: ?bbr.review.CommentId) anyerror!bbr.review.PostResult {
        const self: *FakePoster = @ptrCast(@alignCast(ptr));
        self.post_calls += 1;
        if (self.fail_post) return error.TransportFailure;
        return .{ .outcome = self.posted };
    }

    fn findExisting(ptr: *anyopaque, _: bbr.review.Draft, _: ?bbr.review.CommentId) anyerror!bbr.review.CheckResult {
        const self: *FakePoster = @ptrCast(@alignCast(ptr));
        self.find_calls += 1;
        return if (self.existing) |id| .{ .outcome = .{ .found = id } } else .{ .outcome = .missing };
    }
};

fn testCommand(operation_id: bbr.review.OperationId, dedupe: bool) !*presentation.PostDraft {
    const command = try testing.allocator.create(presentation.PostDraft);
    command.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .operation_id = operation_id,
        .identity = .{ .value = try presentation.OwnedReviewIdentity.init("workspace", "repo", 1) },
        .draft = .{ .local_id = 41, .kind = .comment, .body = "body" },
        .parent = null,
        .dedupe = dedupe,
    };
    return command;
}

test "dedupe hit completes from the existing Comment without another POST" {
    var fake = FakePoster{ .existing = 777 };
    const outcome = try postOutcome(fake.poster(), .{
        .local_id = 1,
        .kind = .comment,
        .body = "already posted",
    }, null, true);

    try testing.expectEqual(@as(bbr.review.CommentId, 777), outcome.posted);
    try testing.expectEqual(@as(usize, 1), fake.find_calls);
    try testing.expectEqual(@as(usize, 0), fake.post_calls);
}

test "dedupe miss performs the POST" {
    var fake = FakePoster{};
    const outcome = try postOutcome(fake.poster(), .{
        .local_id = 1,
        .kind = .comment,
        .body = "new comment",
    }, null, true);

    try testing.expectEqual(@as(bbr.review.CommentId, 900), outcome.posted);
    try testing.expectEqual(@as(usize, 1), fake.find_calls);
    try testing.expectEqual(@as(usize, 1), fake.post_calls);
}

test "executePost consumes the command and returns correlated success" {
    var fake = FakePoster{};
    const input = executePost(try testCommand(17, false), fake.poster());

    try testing.expectEqual(@as(bbr.review.OperationId, 17), input.post_draft_completed.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 41), input.post_draft_completed.temp_id);
    try testing.expectEqual(@as(bbr.review.CommentId, 900), input.post_draft_completed.outcome.posted);
}

test "executePost returns correlated ambiguity when execution errors" {
    var fake = FakePoster{ .fail_post = true };
    const input = executePost(try testCommand(23, false), fake.poster());

    try testing.expectEqual(@as(bbr.review.OperationId, 23), input.post_draft_completed.operation_id);
    try testing.expectEqual(@as(bbr.review.TempId, 41), input.post_draft_completed.temp_id);
    try testing.expect(input.post_draft_completed.outcome == .ambiguous);
}

test "M24 browser list workers return correlated Summaries and classified failures" {
    const repositories = [_]bbr.http.Canned{.{ .status = 200, .body =
        \\{"values":[{"slug":"api","name":"API","updated_on":"2026-10-30T00:00:00Z"}]}
    }};
    var fake: bbr.http.FakeHttpClient = .{ .responses = &repositories };
    const client = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "check24" });
    var loaded = listBrowserRepositories(testing.allocator, client, .{ .command_id = 4, .work_id = 9 });
    defer loaded.deinit();
    try testing.expectEqual(@as(presentation.CommandId, 4), loaded.browser_repositories_loaded.command_id);
    try testing.expectEqual(@as(presentation.WorkId, 9), loaded.browser_repositories_loaded.work_id);
    const items = loaded.browser_repositories_loaded.outcome.loaded.repositories;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("api", items[0].slug);
    try testing.expectEqual(@as(?i64, 1793318400), items[0].updated_on);

    var forbidden: bbr.http.FakeHttpClient = .{ .status = 403, .body = "{}" };
    var failed = listBrowserPullRequests(testing.allocator, bbr.bitbucket.Client.init(forbidden.httpClient(), .{ .username = "u", .token = "t", .workspace = "check24" }), .{
        .command_id = 5,
        .work_id = 10,
        .repository = try browser.Name.init("api"),
    });
    defer failed.deinit();
    try testing.expectEqual(@as(presentation.WorkId, 10), failed.browser_pull_requests_loaded.work_id);
    try testing.expectEqual(@as(browser.Failure, error.Forbidden), failed.browser_pull_requests_loaded.outcome.failed);
    try testing.expect(std.mem.indexOf(u8, forbidden.lastUrl().?, "/repositories/check24/api/pullrequests") != null);
}

fn testCachePath(tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

const test_account: summary_cache.Account = .{ .hex = @splat('a') };

fn testSaveCommand(account: summary_cache.Account, snapshot: summary_cache.Snapshot) !*presentation.SaveSummaryCache {
    const bytes = try summary_cache.encode(testing.allocator, account, snapshot);
    errdefer testing.allocator.free(bytes);
    const command = try presentation.SaveSummaryCache.create(testing.allocator, bytes);
    command.command_id = 6;
    return command;
}

const test_cache_prs = [_]bbr.bitbucket.PullRequestSummary{.{ .id = 7, .title = "Fix the cart", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/cart", .destination_branch = "main", .updated_on = 5, .approval_count = 1 }};

const test_cache_snapshot: summary_cache.Snapshot = .{
    .workspace = "check24",
    .repositories = &.{.{ .summary = .{ .slug = "api", .name = "API", .updated_on = 3 }, .pull_requests = &test_cache_prs }},
};

test "M24 cache the save worker creates the directory and writes mode 0600, and the load worker reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testCachePath(&tmp, "state/bbr/browser-cache.json");
    defer testing.allocator.free(path);

    var saved = saveSummaryCache(testing.io, path, try testSaveCommand(test_account, test_cache_snapshot));
    defer saved.deinit();
    try testing.expectEqual(@as(presentation.CommandId, 6), saved.summary_cache_saved.command_id);
    try testing.expect(saved.summary_cache_saved.saved);
    const stat = try std.Io.Dir.cwd().statFile(testing.io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(stat.permissions)) & 0o777);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    for ([_][]const u8{ "token", "description", "http", "://" }) |word| try testing.expect(std.mem.indexOf(u8, bytes, word) == null);

    try std.Io.Dir.cwd().setFilePermissions(testing.io, path, @enumFromInt(0o644), .{});
    var second = saveSummaryCache(testing.io, path, try testSaveCommand(test_account, .{ .workspace = "check24", .repositories = &.{} }));
    defer second.deinit();
    try testing.expect(second.summary_cache_saved.saved);
    const replaced = try std.Io.Dir.cwd().statFile(testing.io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(replaced.permissions)) & 0o777);
    var dir = try tmp.dir.openDir(testing.io, "state/bbr", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var names: usize = 0;
    while (try it.next(testing.io)) |entry| {
        try testing.expectEqualStrings("browser-cache.json", entry.name);
        names += 1;
    }
    try testing.expectEqual(@as(usize, 1), names);

    var third = saveSummaryCache(testing.io, path, try testSaveCommand(test_account, test_cache_snapshot));
    defer third.deinit();
    var loaded = loadSummaryCache(testing.allocator, testing.io, path, .{ .command_id = 8, .workspace = try browser.Name.init("check24"), .account = test_account });
    defer loaded.deinit();
    try testing.expectEqual(@as(presentation.CommandId, 8), loaded.summary_cache_loaded.command_id);
    try testing.expectEqualDeep(test_cache_snapshot, loaded.summary_cache_loaded.cache.?.snapshot);
}

test "M24 cache a missing, broken, or foreign Summary Cache gives an empty result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testCachePath(&tmp, "browser-cache.json");
    defer testing.allocator.free(path);
    const workspace = try browser.Name.init("check24");

    var missing = loadSummaryCache(testing.allocator, testing.io, path, .{ .command_id = 1, .workspace = workspace, .account = test_account });
    defer missing.deinit();
    try testing.expect(missing.summary_cache_loaded.cache == null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "browser-cache.json", .data = "{\"version\":1,\"workspace\":" });
    var broken = loadSummaryCache(testing.allocator, testing.io, path, .{ .command_id = 2, .workspace = workspace, .account = test_account });
    defer broken.deinit();
    try testing.expect(broken.summary_cache_loaded.cache == null);

    var saved = saveSummaryCache(testing.io, path, try testSaveCommand(test_account, .{ .workspace = "other", .repositories = test_cache_snapshot.repositories }));
    defer saved.deinit();
    try testing.expect(saved.summary_cache_saved.saved);
    var foreign = loadSummaryCache(testing.allocator, testing.io, path, .{ .command_id = 3, .workspace = workspace, .account = test_account });
    defer foreign.deinit();
    try testing.expect(foreign.summary_cache_loaded.cache == null);
}

test "M24 cache a Summary Cache saved for one account is empty for another account in the same Workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testCachePath(&tmp, "browser-cache.json");
    defer testing.allocator.free(path);
    const workspace = try browser.Name.init("check24");

    var saved = saveSummaryCache(testing.io, path, try testSaveCommand(test_account, test_cache_snapshot));
    defer saved.deinit();
    try testing.expect(saved.summary_cache_saved.saved);
    var other = loadSummaryCache(testing.allocator, testing.io, path, .{ .command_id = 1, .workspace = workspace, .account = .of("bo@example.com") });
    defer other.deinit();
    try testing.expect(other.summary_cache_loaded.cache == null);
    var same = loadSummaryCache(testing.allocator, testing.io, path, .{ .command_id = 2, .workspace = workspace, .account = test_account });
    defer same.deinit();
    try testing.expectEqualDeep(test_cache_snapshot, same.summary_cache_loaded.cache.?.snapshot);
}

test "M24 cache a failed save reports the failure and consumes the command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    const path = try testCachePath(&tmp, "file/browser-cache.json");
    defer testing.allocator.free(path);
    var failed = saveSummaryCache(testing.io, path, try testSaveCommand(test_account, test_cache_snapshot));
    defer failed.deinit();
    try testing.expectEqual(@as(presentation.CommandId, 6), failed.summary_cache_saved.command_id);
    try testing.expect(!failed.summary_cache_saved.saved);
}

test "M24 startup the detection worker opens one AdjacentPullRequest and turns a failure into a plain Browser" {
    const credential: bbr.bitbucket.Credential = .{ .username = "u", .token = "t", .workspace = "check24" };
    const command: presentation.DetectAdjacentPullRequests = .{ .command_id = 6, .detection = .{
        .workspace = try browser.Name.init("check24"),
        .repository = try browser.Name.init("pr-webapp"),
        .branch = try browser.Name.init("feature/x"),
        .named = true,
    } };
    var one: bbr.http.FakeHttpClient = .{ .body =
        \\{"values":[{"id":99,"title":"t","state":"OPEN","source":{"branch":{"name":"feature/x"}},"destination":{"branch":{"name":"main"}}}]}
    };
    const opened = detectAdjacentPullRequests(testing.allocator, bbr.bitbucket.Client.init(one.httpClient(), credential), command);
    try testing.expectEqual(@as(presentation.CommandId, 6), opened.adjacent_detected.command_id);
    try testing.expect(presentation.OwnedReviewIdentity.eql(try .init("check24", "pr-webapp", 99), opened.adjacent_detected.outcome.open));

    var failing: bbr.http.FakeHttpClient = .{ .status = 404, .body = "{}" };
    const failed = detectAdjacentPullRequests(testing.allocator, bbr.bitbucket.Client.init(failing.httpClient(), credential), command);
    const start = failed.adjacent_detected.outcome.browse;
    try testing.expectEqualStrings("check24", start.workspace.slice());
    try testing.expectEqualStrings("pr-webapp", start.repository.?.slice());
    try testing.expect(start.pull_request_id == null);
}
