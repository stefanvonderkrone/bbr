//! `bbr api` dispatcher: one verb table row per endpoint, global
//! `--workspace` / `--json` / `--help`, per-verb long flags. Never starts
//! the TUI: this module only builds `StdHttpClient` + `Client` and runs one
//! verb. Add a new endpoint as one `Client` method + one table row (+ one
//! function in the matching `src/api/*.zig` resource file).

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const workspaces = @import("workspaces.zig");
const repositories = @import("repositories.zig");
const pullrequests = @import("pullrequests.zig");
const comments = @import("comments.zig");
const tasks = @import("tasks.zig");
const files = @import("files.zig");
const commits = @import("commits.zig");

pub const help =
    \\usage: bbr api [--workspace SLUG] [--json] VERB [options]
    \\
    \\Talk to the Bitbucket Cloud REST API (api.bitbucket.org/2.0) without the TUI.
    \\Global flags go before the verb: --workspace overrides BITBUCKET_WORKSPACE,
    \\--json prints machine-readable JSON, --help prints this reference.
    \\`bbr api VERB --help` prints the verb's options. All flags are long
    \\`--kebab-case`; there are no short aliases.
    \\
    \\Verbs:
    \\  list-workspaces    list workspaces for the authenticated account
    \\  get-workspace      get one workspace
    \\  list-repositories  list repositories in a workspace
    \\  get-repository     get one repository
    \\  list-prs           list pull requests in a repository
    \\  get-pr             get one pull request
    \\  list-commits       list commits (PR, revision, or from..to range)
    \\  get-diff           raw diff of a pull request
    \\  get-compare-diff   raw diff between two commits
    \\  get-blob           file bytes at a commit
    \\  check-blob         verify file metadata at a commit
    \\  list-comments      list comments on a pull request
    \\  get-comment        get one comment
    \\  create-comment     create a comment or reply
    \\  update-comment     edit a comment body
    \\  delete-comment     delete a comment
    \\  resolve-comment    resolve a comment thread
    \\  reopen-comment     reopen a comment thread
    \\  list-tasks         list tasks on a pull request
    \\  get-task           get one task
    \\  create-task        create a task
    \\  update-task        update a task (content and/or state)
    \\  delete-task        delete a task
    \\  resolve-task       resolve a task
    \\  reopen-task        reopen a task
    \\  whoami             authenticated account UUID
    \\  get-verdict        reviewer verdict for an account
    \\  set-verdict        set the reviewer verdict
    \\
    \\Auth comes from BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE.
    \\
;

const value_flags = [_][]const u8{
    "workspace",       "repository",     "pull-request-id", "comment-id",
    "parent-id",       "task-id",        "body",            "body-file",
    "content",         "content-file",   "path",            "file-path",
    "to",              "from",           "start-to",        "start-from",
    "state",           "state-filter",   "source-branch",   "commit",
    "revision",        "source-commit",  "destination-commit",
    "expected-source-commit", "uuid",    "out",             "pagelen",
    "page",            "query",          "sort",            "limit",
    "attributes",      "verdict",
};

fn takesValue(name: []const u8) bool {
    for (value_flags) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// Split argv (after `api`) into globals + verb + verb args.
/// Strips `--json` (sets json) and `--workspace V` (sets override) wherever
/// they appear as flags (never as a value-flag's value). `--help` anywhere
/// sets help_only.
const Parsed = struct {
    verb: ?[]const u8,
    rest: []const []const u8,
    json: bool,
    workspace: ?[]const u8,
    help_only: bool,
};

fn parseGlobal(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
) !Parsed {
    var rest: std.ArrayList([]const u8) = .empty;
    errdefer rest.deinit(gpa);
    var verb: ?[]const u8 = null;
    var json = false;
    var workspace: ?[]const u8 = null;
    var help_only = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (arg.isHelp(a)) {
            help_only = true;
            continue;
        }
        if (arg.splitFlag(a)) |f| {
            if (std.mem.eql(u8, f.name, "json") and f.value == null) {
                json = true;
                continue;
            }
            if (std.mem.eql(u8, f.name, "workspace")) {
                const v = if (f.value) |v| v else blk: {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    break :blk argv[i];
                };
                workspace = v;
                continue;
            }
            // Any other flag: keep verbatim (plus its value, when it takes
            // one and uses the space form).
            try rest.append(gpa, a);
            if (f.value == null and takesValue(f.name)) {
                i += 1;
                if (i >= argv.len) return error.MissingValue;
                try rest.append(gpa, argv[i]);
            }
            continue;
        }
        // Positional: first one is the verb.
        if (verb == null) {
            verb = a;
        } else {
            try rest.append(gpa, a);
        }
    }
    return .{
        .verb = verb,
        .rest = try rest.toOwnedSlice(gpa),
        .json = json,
        .workspace = workspace,
        .help_only = help_only,
    };
}

fn printHelp(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try stdout.interface.writeAll(help);
    try stdout.interface.flush();
}

fn printVerbHelp(init: std.process.Init, verb: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const text: ?[]const u8 = if (std.mem.eql(u8, verb, "list-workspaces"))
        workspaces.list_help
    else if (std.mem.eql(u8, verb, "get-workspace"))
        workspaces.get_help
    else if (std.mem.eql(u8, verb, "list-repositories"))
        repositories.list_help
    else if (std.mem.eql(u8, verb, "get-repository"))
        repositories.get_help
    else if (std.mem.eql(u8, verb, "list-prs"))
        pullrequests.list_help
    else if (std.mem.eql(u8, verb, "get-pr"))
        pullrequests.get_help
    else if (std.mem.eql(u8, verb, "whoami"))
        pullrequests.whoami_help
    else if (std.mem.eql(u8, verb, "get-verdict"))
        pullrequests.get_verdict_help
    else if (std.mem.eql(u8, verb, "set-verdict"))
        pullrequests.set_verdict_help
    else if (std.mem.eql(u8, verb, "list-commits"))
        commits.help
    else if (std.mem.eql(u8, verb, "get-diff"))
        files.diff_help
    else if (std.mem.eql(u8, verb, "get-compare-diff"))
        files.compare_help
    else if (std.mem.eql(u8, verb, "get-blob"))
        files.blob_help
    else if (std.mem.eql(u8, verb, "check-blob"))
        files.check_help
    else if (std.mem.eql(u8, verb, "list-comments"))
        comments.list_help
    else if (std.mem.eql(u8, verb, "get-comment"))
        comments.get_help
    else if (std.mem.eql(u8, verb, "create-comment"))
        comments.create_help
    else if (std.mem.eql(u8, verb, "update-comment"))
        comments.update_help
    else if (std.mem.eql(u8, verb, "delete-comment"))
        comments.delete_help
    else if (std.mem.eql(u8, verb, "resolve-comment"))
        comments.resolve_help
    else if (std.mem.eql(u8, verb, "reopen-comment"))
        comments.reopen_help
    else if (std.mem.eql(u8, verb, "list-tasks"))
        tasks.list_help
    else if (std.mem.eql(u8, verb, "get-task"))
        tasks.get_help
    else if (std.mem.eql(u8, verb, "create-task"))
        tasks.create_help
    else if (std.mem.eql(u8, verb, "update-task"))
        tasks.update_help
    else if (std.mem.eql(u8, verb, "delete-task"))
        tasks.delete_help
    else if (std.mem.eql(u8, verb, "resolve-task"))
        tasks.resolve_help
    else if (std.mem.eql(u8, verb, "reopen-task"))
        tasks.reopen_help
    else
        null;
    if (text) |t| {
        try stdout.interface.writeAll(t);
    } else {
        try stdout.interface.writeAll(help);
    }
    try stdout.interface.flush();
}

/// Entry from `main.zig`: `bbr api [...]`. Never touches config or the TUI.
pub fn run(init: std.process.Init, gpa: std.mem.Allocator, it: anytype) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (it.next()) |a| try argv.append(gpa, a);

    const parsed = try parseGlobal(gpa, argv.items);
    defer gpa.free(parsed.rest);

    if (parsed.verb == null or parsed.help_only) {
        if (parsed.verb) |v| {
            // `bbr api VERB --help`: verb reference, no credentials needed.
            try printVerbHelp(init, v);
        } else {
            try printHelp(init);
        }
        return;
    }
    const verb = parsed.verb.?;

    // Unknown verb: full reference to stderr, non-zero exit.
    if (!isVerb(verb)) {
        std.debug.print("bbr api: unknown verb '{s}'\n{s}", .{ verb, help });
        return error.UnknownFlag;
    }

    var cred = bbr.bitbucket.Credential.fromEnv(init.environ_map) catch {
        std.debug.print(
            "bbr api: missing credential: set BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE\n",
            .{},
        );
        return error.MissingCredential;
    };
    if (parsed.workspace) |w| cred.workspace = w;

    var transport = bbr.http.StdHttpClient.init(gpa, init.io);
    defer transport.deinit();
    try transport.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(transport.httpClient(), cred);

    dispatch(init, bb, verb, parsed.rest, parsed.json) catch |err| {
        if (err == error.UnknownFlag or err == error.MissingRequired or
            err == error.MissingValue or err == error.InvalidNumber or
            err == error.BadRequest)
        {
            std.debug.print("bbr api {s}: bad options ({s})\n", .{ verb, @errorName(err) });
            try printVerbHelp(init, verb);
        } else {
            std.debug.print("bbr api {s}: {s}\n", .{ verb, @errorName(err) });
        }
        return err;
    };
}

fn isVerb(verb: []const u8) bool {
    for (verbs) |v| if (std.mem.eql(u8, v, verb)) return true;
    return false;
}

const verbs = [_][]const u8{
    "list-workspaces", "get-workspace",
    "list-repositories", "get-repository",
    "list-prs",         "get-pr",
    "list-commits",     "get-diff",
    "get-compare-diff",  "get-blob",
    "check-blob",        "list-comments",
    "get-comment",       "create-comment",
    "update-comment",    "delete-comment",
    "resolve-comment",   "reopen-comment",
    "list-tasks",        "get-task",
    "create-task",       "update-task",
    "delete-task",       "resolve-task",
    "reopen-task",       "whoami",
    "get-verdict",       "set-verdict",
};

fn dispatch(
    init: std.process.Init,
    bb: bbr.bitbucket.Client,
    verb: []const u8,
    args: []const []const u8,
    json: bool,
) !void {
    if (std.mem.eql(u8, verb, "list-workspaces")) return workspaces.runList(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-workspace")) return workspaces.runGet(init, bb, args, json);
    if (std.mem.eql(u8, verb, "list-repositories")) return repositories.runList(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-repository")) return repositories.runGet(init, bb, args, json);
    if (std.mem.eql(u8, verb, "list-prs")) return pullrequests.runList(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-pr")) return pullrequests.runGet(init, bb, args, json);
    if (std.mem.eql(u8, verb, "whoami")) return pullrequests.runWhoami(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-verdict")) return pullrequests.runGetVerdict(init, bb, args, json);
    if (std.mem.eql(u8, verb, "set-verdict")) return pullrequests.runSetVerdict(init, bb, args, json);
    if (std.mem.eql(u8, verb, "list-commits")) return commits.run(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-diff")) return files.runDiff(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-compare-diff")) return files.runCompare(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-blob")) return files.runBlob(init, bb, args, json);
    if (std.mem.eql(u8, verb, "check-blob")) return files.runCheck(init, bb, args, json);
    if (std.mem.eql(u8, verb, "list-comments")) return comments.runList(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-comment")) return comments.runGet(init, bb, args, json);
    if (std.mem.eql(u8, verb, "create-comment")) return comments.runCreate(init, bb, args, json);
    if (std.mem.eql(u8, verb, "update-comment")) return comments.runUpdate(init, bb, args, json);
    if (std.mem.eql(u8, verb, "delete-comment")) return comments.runDelete(init, bb, args, json);
    if (std.mem.eql(u8, verb, "resolve-comment")) return comments.runResolve(init, bb, args, json);
    if (std.mem.eql(u8, verb, "reopen-comment")) return comments.runReopen(init, bb, args, json);
    if (std.mem.eql(u8, verb, "list-tasks")) return tasks.runList(init, bb, args, json);
    if (std.mem.eql(u8, verb, "get-task")) return tasks.runGet(init, bb, args, json);
    if (std.mem.eql(u8, verb, "create-task")) return tasks.runCreate(init, bb, args, json);
    if (std.mem.eql(u8, verb, "update-task")) return tasks.runUpdate(init, bb, args, json);
    if (std.mem.eql(u8, verb, "delete-task")) return tasks.runDelete(init, bb, args, json);
    if (std.mem.eql(u8, verb, "resolve-task")) return tasks.runResolve(init, bb, args, json);
    if (std.mem.eql(u8, verb, "reopen-task")) return tasks.runReopen(init, bb, args, json);
    return error.UnknownFlag;
}

test "parseGlobal extracts globals and verb" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "--json", "--workspace", "myws", "get-pr", "--repository", "r" };
    const p = try parseGlobal(a, &argv);
    defer a.free(p.rest);
    try std.testing.expectEqualStrings("get-pr", p.verb.?);
    try std.testing.expect(p.json);
    try std.testing.expectEqualStrings("myws", p.workspace.?);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
}

test "parseGlobal keeps flag values intact" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "create-comment", "--body", "--json" };
    const p = try parseGlobal(a, &argv);
    defer a.free(p.rest);
    // `--json` right after value-flag `--body` is its value, not the global.
    try std.testing.expect(!p.json);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
}

test "all verbs are known" {
    for (verbs) |v| try std.testing.expect(isVerb(v));
    try std.testing.expect(!isVerb("frobnicate"));
}
