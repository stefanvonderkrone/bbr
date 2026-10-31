//! `bbr api` dispatcher: one verb table row per endpoint, global
//! `--profile` / `--workspace` / `--json` / `--help`, per-verb long flags. Never starts
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
const branches = @import("branches.zig");
const users = @import("users.zig");

pub const Verb = struct {
    name: []const u8,
    summary: []const u8,
    help: []const u8,
    example: []const u8,
    /// Long flags without `--`, except the `global_flags` that every verb takes.
    value_flags: []const []const u8 = &.{},
    switch_flags: []const []const u8 = &.{},
    handler: *const fn (std.process.Init, bbr.bitbucket.Client, []const []const u8, bool) anyerror!void,
};

pub const verbs = [_]Verb{
    .{ .name = "list-workspaces", .summary = "list workspaces for the authenticated account", .help = workspaces.list_help, .example = "bbr api list-workspaces --pagelen 10 --no-follow", .value_flags = &.{ "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{"no-follow"}, .handler = workspaces.runList },
    .{ .name = "get-workspace", .summary = "get one workspace", .help = workspaces.get_help, .example = "bbr api get-workspace --workspace demo", .handler = workspaces.runGet },
    .{ .name = "list-workspace-members", .summary = "list Workspace Member names and UUIDs", .help = workspaces.members_help, .example = "bbr api list-workspace-members --json", .value_flags = &.{ "pagelen", "page", "limit" }, .switch_flags = &.{"no-follow"}, .handler = workspaces.runListMembers },
    .{ .name = "search-workspace-members", .summary = "find Workspace Member UUIDs by name", .help = workspaces.search_members_help, .example = "bbr api search-workspace-members --name 'Ada Lovelace' --json", .value_flags = &.{ "name", "pagelen", "concurrency", "limit" }, .handler = workspaces.runSearchMembers },
    .{ .name = "list-repositories", .summary = "list repositories in a workspace", .help = repositories.list_help, .example = "bbr api list-repositories --workspace demo --limit 10", .value_flags = &.{ "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{"no-follow"}, .handler = repositories.runList },
    .{ .name = "get-repository", .summary = "get one repository", .help = repositories.get_help, .example = "bbr api get-repository --workspace demo --repository sample", .value_flags = &.{"repository"}, .handler = repositories.runGet },
    .{ .name = "create-branch", .summary = "create a branch from a commit or branch", .help = branches.create_help, .example = "bbr api create-branch --repository sample --name feature/example --target main", .value_flags = &.{ "repository", "name", "target" }, .handler = branches.runCreate },
    .{ .name = "list-branches", .summary = "list branches in a repository", .help = branches.list_help, .example = "bbr api list-branches --repository sample --sort name --limit 10", .value_flags = &.{ "repository", "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{"no-follow"}, .handler = branches.runList },
    .{ .name = "get-branch", .summary = "get a branch and its target commit", .help = branches.get_help, .example = "bbr api get-branch --repository sample --name feature/example", .value_flags = &.{ "repository", "name" }, .handler = branches.runGet },
    .{ .name = "list-pull-requests", .summary = "list pull requests in a repository", .help = pullrequests.list_help, .example = "bbr api list-pull-requests --repository sample --state OPEN --pagelen 10 --page 2 --no-follow", .value_flags = &.{ "repository", "state", "source-branch", "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{"no-follow"}, .handler = pullrequests.runList },
    .{ .name = "list-workspace-pull-requests", .summary = "list Workspace pull requests by author or reviewer", .help = pullrequests.workspace_list_help, .example = "bbr api list-workspace-pull-requests --reviewer '{reviewer}' --state OPEN --state MERGED --limit 20", .value_flags = &.{ "author", "reviewer", "state", "query", "concurrency", "limit" }, .handler = pullrequests.runListWorkspace },
    .{ .name = "get-pull-request", .summary = "get one pull request", .help = pullrequests.get_help, .example = "bbr api get-pull-request --repository sample --pull-request-id 42", .value_flags = &.{ "repository", "pull-request-id" }, .handler = pullrequests.runGet },
    .{ .name = "create-pull-request", .summary = "create a ready or draft pull request", .help = pullrequests.create_help, .example = "bbr api create-pull-request --repository sample --title 'Example change' --source-branch feature/example --draft true", .value_flags = &.{ "repository", "title", "source-branch", "source-repository", "destination-branch", "description", "description-file", "reviewer", "draft", "close-source-branch" }, .switch_flags = &.{"clear-reviewers"}, .handler = pullrequests.runCreate },
    .{ .name = "update-pull-request", .summary = "update an open pull request", .help = pullrequests.update_help, .example = "bbr api update-pull-request --repository sample --pull-request-id 42 --draft false", .value_flags = &.{ "repository", "pull-request-id", "title", "source-branch", "destination-branch", "description", "description-file", "reviewer", "draft", "close-source-branch" }, .switch_flags = &.{"clear-reviewers"}, .handler = pullrequests.runUpdate },
    .{ .name = "decline-pull-request", .summary = "close a pull request without merging", .help = pullrequests.decline_help, .example = "bbr api decline-pull-request --repository sample --pull-request-id 42", .value_flags = &.{ "repository", "pull-request-id" }, .handler = pullrequests.runDecline },
    .{ .name = "list-commit-pull-requests", .summary = "list pull requests for a commit", .help = pullrequests.commit_list_help, .example = "bbr api list-commit-pull-requests --repository sample --commit abc123 --limit 10", .value_flags = &.{ "repository", "commit", "pagelen", "page", "limit" }, .switch_flags = &.{"no-follow"}, .handler = pullrequests.runListCommit },
    .{ .name = "list-commits", .summary = "list commits (PR, revision, or from..to range)", .help = commits.help, .example = "bbr api list-commits --repository sample --revision main --limit 10", .value_flags = &.{ "repository", "pull-request-id", "revision", "from", "to", "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{"no-follow"}, .handler = commits.run },
    .{ .name = "get-diff", .summary = "raw diff of a pull request", .help = files.diff_help, .example = "bbr api get-diff --repository sample --pull-request-id 42 --out review.diff", .value_flags = &.{ "repository", "pull-request-id", "out" }, .handler = files.runDiff },
    .{ .name = "get-compare-diff", .summary = "raw diff between two commits", .help = files.compare_help, .example = "bbr api get-compare-diff --repository sample --from abc123 --to def456 --patch", .value_flags = &.{ "repository", "from", "to", "out" }, .switch_flags = &.{"patch"}, .handler = files.runCompare },
    .{ .name = "get-blob", .summary = "file bytes at a commit", .help = files.blob_help, .example = "bbr api get-blob --repository sample --commit abc123 --path src/main.zig --out main.zig", .value_flags = &.{ "repository", "commit", "path", "out" }, .handler = files.runBlob },
    .{ .name = "check-blob", .summary = "verify file metadata at a commit", .help = files.check_help, .example = "bbr api check-blob --repository sample --commit abc123 --path src/main.zig --attributes -", .value_flags = &.{ "repository", "commit", "path", "attributes" }, .handler = files.runCheck },
    .{ .name = "list-comments", .summary = "list comments on a pull request", .help = comments.list_help, .example = "bbr api list-comments --repository sample --pull-request-id 42 --no-head --limit 10", .value_flags = &.{ "repository", "pull-request-id", "source-commit", "destination-commit", "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{ "no-head", "no-follow" }, .handler = comments.runList },
    .{ .name = "get-comment", .summary = "get one comment", .help = comments.get_help, .example = "bbr api get-comment --repository sample --pull-request-id 42 --comment-id 7", .value_flags = &.{ "repository", "pull-request-id", "comment-id" }, .handler = comments.runGet },
    .{ .name = "create-comment", .summary = "create a comment or reply", .help = comments.create_help, .example = "bbr api create-comment --repository sample --pull-request-id 42 --body 'Please add a test.'", .value_flags = &.{ "repository", "pull-request-id", "body", "body-file", "parent-id", "path", "to", "from", "start-to", "start-from", "file-path", "source-commit" }, .handler = comments.runCreate },
    .{ .name = "update-comment", .summary = "edit a comment body", .help = comments.update_help, .example = "bbr api update-comment --repository sample --pull-request-id 42 --comment-id 7 --body 'Please test this case.'", .value_flags = &.{ "repository", "pull-request-id", "comment-id", "body", "body-file" }, .handler = comments.runUpdate },
    .{ .name = "delete-comment", .summary = "delete a comment", .help = comments.delete_help, .example = "bbr api delete-comment --repository sample --pull-request-id 42 --comment-id 7", .value_flags = &.{ "repository", "pull-request-id", "comment-id" }, .handler = comments.runDelete },
    .{ .name = "resolve-comment", .summary = "resolve a comment thread", .help = comments.resolve_help, .example = "bbr api resolve-comment --repository sample --pull-request-id 42 --comment-id 7", .value_flags = &.{ "repository", "pull-request-id", "comment-id" }, .handler = comments.runResolve },
    .{ .name = "reopen-comment", .summary = "reopen a comment thread", .help = comments.reopen_help, .example = "bbr api reopen-comment --repository sample --pull-request-id 42 --comment-id 7", .value_flags = &.{ "repository", "pull-request-id", "comment-id" }, .handler = comments.runReopen },
    .{ .name = "list-tasks", .summary = "list tasks on a pull request", .help = tasks.list_help, .example = "bbr api list-tasks --repository sample --pull-request-id 42 --state-filter UNRESOLVED --limit 10", .value_flags = &.{ "repository", "pull-request-id", "state-filter", "pagelen", "page", "query", "sort", "limit" }, .switch_flags = &.{"no-follow"}, .handler = tasks.runList },
    .{ .name = "get-task", .summary = "get one task", .help = tasks.get_help, .example = "bbr api get-task --repository sample --pull-request-id 42 --task-id 3", .value_flags = &.{ "repository", "pull-request-id", "task-id" }, .handler = tasks.runGet },
    .{ .name = "create-task", .summary = "create a task", .help = tasks.create_help, .example = "bbr api create-task --repository sample --pull-request-id 42 --content 'Add a test.'", .value_flags = &.{ "repository", "pull-request-id", "content", "content-file", "comment-id" }, .handler = tasks.runCreate },
    .{ .name = "update-task", .summary = "update a task (content and/or state)", .help = tasks.update_help, .example = "bbr api update-task --repository sample --pull-request-id 42 --task-id 3 --state RESOLVED", .value_flags = &.{ "repository", "pull-request-id", "task-id", "content", "content-file", "state" }, .handler = tasks.runUpdate },
    .{ .name = "delete-task", .summary = "delete a task", .help = tasks.delete_help, .example = "bbr api delete-task --repository sample --pull-request-id 42 --task-id 3", .value_flags = &.{ "repository", "pull-request-id", "task-id" }, .handler = tasks.runDelete },
    .{ .name = "resolve-task", .summary = "resolve a task", .help = tasks.resolve_help, .example = "bbr api resolve-task --repository sample --pull-request-id 42 --task-id 3", .value_flags = &.{ "repository", "pull-request-id", "task-id" }, .handler = tasks.runResolve },
    .{ .name = "reopen-task", .summary = "reopen a task", .help = tasks.reopen_help, .example = "bbr api reopen-task --repository sample --pull-request-id 42 --task-id 3", .value_flags = &.{ "repository", "pull-request-id", "task-id" }, .handler = tasks.runReopen },
    .{ .name = "whoami", .summary = "authenticated account UUID", .help = pullrequests.whoami_help, .example = "bbr api whoami --json", .handler = pullrequests.runWhoami },
    .{ .name = "get-user", .summary = "get an account by account ID or UUID", .help = users.get_help, .example = "bbr api get-user --user-id ACCOUNT_ID --json", .value_flags = &.{"user-id"}, .handler = users.runGet },
    .{ .name = "get-verdict", .summary = "reviewer verdict for an account", .help = pullrequests.get_verdict_help, .example = "bbr api get-verdict --repository sample --pull-request-id 42 --uuid '{reviewer}'", .value_flags = &.{ "repository", "pull-request-id", "uuid" }, .handler = pullrequests.runGetVerdict },
    .{ .name = "set-verdict", .summary = "set the reviewer verdict", .help = pullrequests.set_verdict_help, .example = "bbr api set-verdict --repository sample --pull-request-id 42 --verdict approved --expected-source-commit abc123", .value_flags = &.{ "repository", "pull-request-id", "verdict", "expected-source-commit" }, .handler = pullrequests.runSetVerdict },
};

pub const help = blk: {
    var text: []const u8 =
        \\usage: bbr api [--profile NAME] [--workspace SLUG] [--json] VERB [options]
        \\
        \\Talk to the Bitbucket Cloud REST API (api.bitbucket.org/2.0) without the TUI.
        \\Global flags can go before or after the verb.
        \\--profile selects a saved Profile. --workspace overrides its Workspace and BITBUCKET_WORKSPACE.
        \\--json prints machine-readable JSON. --help prints this reference.
        \\`bbr api VERB --help` prints the verb's options. All flags are long
        \\`--kebab-case`; there are no short aliases.
        \\
        \\Verbs:
        \\
    ;
    var name_width: usize = 0;
    for (verbs) |verb| name_width = @max(name_width, verb.name.len);
    for (verbs) |verb| text = text ++ "  " ++ verb.name ++ (" " ** (name_width - verb.name.len + 2)) ++ verb.summary ++ "\n";
    break :blk text ++ "\nAuth comes from `bbr auth login` Profiles with per-field BITBUCKET_* overrides.\n" ++
        "Profile selection: --profile, BBR_PROFILE, Active Profile, default.\n" ++
        "Workspace selection: --workspace, BITBUCKET_WORKSPACE, selected Profile.\n";
};

/// Global `bbr api` flags, also completed before and after the verb.
pub const global_flags = [_][]const u8{ "profile", "workspace", "json", "help" };

const flag_sets = blk: {
    @setEvalBranchQuota(200_000);
    var values: []const []const u8 = &.{ "profile", "workspace" };
    var switches: []const []const u8 = &.{"json"};
    for (verbs) |verb| {
        for (verb.value_flags, 0..) |flag, index| {
            checkRowFlag(verb, flag, contains(verb.value_flags[0..index], flag) or contains(verb.switch_flags, flag));
            if (contains(switches, flag)) @compileError("--" ++ flag ++ " takes a value in bbr api " ++ verb.name ++ " but is a switch in another row of `verbs` in src/api/cli.zig");
            if (!contains(values, flag)) values = values ++ &[_][]const u8{flag};
        }
        for (verb.switch_flags, 0..) |flag, index| {
            checkRowFlag(verb, flag, contains(verb.switch_flags[0..index], flag));
            if (contains(values, flag)) @compileError("--" ++ flag ++ " is a switch in bbr api " ++ verb.name ++ " but takes a value in another row of `verbs` in src/api/cli.zig");
            if (!contains(switches, flag)) switches = switches ++ &[_][]const u8{flag};
        }
    }
    break :blk .{ .values = values, .switches = switches };
};

fn checkRowFlag(comptime verb: Verb, comptime flag: []const u8, comptime repeated: bool) void {
    if (contains(&global_flags, flag)) @compileError("bbr api " ++ verb.name ++ " lists global flag --" ++ flag ++ "; remove it from its row of `verbs` in src/api/cli.zig");
    if (repeated) @compileError("bbr api " ++ verb.name ++ " lists --" ++ flag ++ " twice in its row of `verbs` in src/api/cli.zig");
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// Every flag that takes a value (space or `=` form), globals first. The
/// `bbr completion` scripts embed it so value flags don't complete as switches.
pub const value_flags: []const []const u8 = flag_sets.values;

pub fn takesValue(name: []const u8) bool {
    return contains(value_flags, name);
}

/// Split argv (after `api`) into globals + verb + verb args.
/// Strips `--json`, `--workspace V`, and `--profile V` wherever
/// they appear as flags (never as a value-flag's value). Standalone `--help`
/// or `-h` sets help_only.
const Parsed = struct {
    verb: ?[]const u8,
    rest: []const []const u8,
    json: bool,
    workspace: ?[]const u8,
    profile: ?[]const u8,
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
    var profile: ?[]const u8 = null;
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
            if (std.mem.eql(u8, f.name, "workspace") or std.mem.eql(u8, f.name, "profile")) {
                const v = if (f.value) |v| v else blk: {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    break :blk argv[i];
                };
                if (v.len == 0) return error.MissingValue;
                if (std.mem.eql(u8, f.name, "workspace")) workspace = v else profile = v;
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
        .profile = profile,
        .help_only = help_only,
    };
}

fn printHelp(init: std.process.Init, verb: ?[]const u8) !void {
    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try writeHelp(&stdout.interface, verb);
    try stdout.interface.flush();
}

fn writeHelp(writer: *std.Io.Writer, name: ?[]const u8) !void {
    if (name) |n| {
        if (findVerb(n)) |verb| {
            try writer.writeAll(verb.help);
            try writer.writeAll("\nGlobal options: --profile NAME, --workspace SLUG, --json, --help.\n");
            try writer.print("\nExample:\n  {s}\n", .{verb.example});
            return;
        }
    }
    try writer.writeAll(help);
}

fn isOptionError(err: anyerror) bool {
    return err == error.UnknownFlag or err == error.MissingRequired or
        err == error.MissingValue or err == error.InvalidNumber or err == error.BadRequest or
        err == error.InvalidProfileName;
}

fn writeError(writer: *std.Io.Writer, verb: ?Verb, err: anyerror, detail: ?*const bbr.bitbucket.Client.ErrorDetail) !void {
    try writer.writeAll("bbr api");
    if (verb) |v| try writer.print(" {s}", .{v.name});
    const api_error = if (detail) |d| d.reason else null;
    const reported_error = if (detail) |d| d.reported_error else null;
    if (api_error != null and (api_error.? == err or (reported_error != null and reported_error.? == err))) {
        if (api_error.? != err) try writer.print(": {s}", .{@errorName(err)});
        try writer.print(": Bitbucket rejected request ({s})", .{@errorName(api_error.?)});
        if (detail.?.message) |message| try writer.print(": {s}", .{message});
        try writer.writeAll("\n");
    } else if (isOptionError(err)) {
        try writer.print(": bad options ({s})\n", .{@errorName(err)});
        try writeHelp(writer, if (verb) |v| v.name else null);
    } else {
        try writer.print(": {s}\n", .{@errorName(err)});
        if (err == error.MissingCredential) {
            try writer.writeAll("Run `bbr auth login` or set BITBUCKET_USERNAME, BITBUCKET_TOKEN, and --workspace or BITBUCKET_WORKSPACE.\n");
        }
    }
    if (verb) |v| {
        if (std.mem.eql(u8, v.name, "list-commit-pull-requests")) {
            if (err == error.PullRequestLinksIndexing) {
                try writer.writeAll("Bitbucket still indexes PullRequest links. Run the command again after indexing completes.\n");
            } else if (err == error.NotFound) {
                try writer.writeAll("The Repository or commit links were not found. Links can lack an index. Select 'Go to pull request' on the commit's details page to install the Pull Request Commit Links app.\n");
            }
        }
    }
}

fn printError(init: std.process.Init, verb: ?Verb, err: anyerror, detail: ?*const bbr.bitbucket.Client.ErrorDetail) !void {
    var buf: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    try writeError(&stderr.interface, verb, err, detail);
    try stderr.interface.flush();
}

/// Only report a registered verb in a positional slot. Never report a flag value.
fn diagnosticVerb(argv: []const []const u8) ?Verb {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (arg.isHelp(a)) continue;
        if (arg.splitFlag(a)) |f| {
            if (f.value != null) continue;
            if (takesValue(f.name)) {
                i += 1;
                if (i >= argv.len) return null;
            } else if (!contains(flag_sets.switches, f.name)) {
                // An unknown flag can take a value. Do not guess its meaning.
                return null;
            }
            continue;
        }
        return findVerb(a);
    }
    return null;
}

fn findVerb(name: []const u8) ?Verb {
    for (verbs) |verb| if (std.mem.eql(u8, verb.name, name)) return verb;
    return null;
}

fn verbHelp(name: []const u8) []const u8 {
    return if (findVerb(name)) |verb| verb.help else help;
}

fn cliCredential(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    workspace: ?[]const u8,
    profile: ?[]const u8,
) !bbr.bitbucket.auth.OwnedCredential {
    if (workspace) |value| {
        var overrides = try env.clone(gpa);
        defer overrides.deinit();
        try overrides.put("BITBUCKET_WORKSPACE", value);
        return bbr.bitbucket.auth.resolve(gpa, io, &overrides, profile);
    }
    return bbr.bitbucket.auth.resolve(gpa, io, env, profile);
}

/// Entry from `main.zig`: `bbr api [...]`. Reads auth without loading TUI config.
pub fn run(init: std.process.Init, gpa: std.mem.Allocator, it: anytype, profile: ?[]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (it.next()) |a| argv.append(gpa, a) catch |err| {
        try printError(init, diagnosticVerb(argv.items), err, null);
        return err;
    };
    var detail: bbr.bitbucket.Client.ErrorDetail = .{ .allocator = gpa, .io = init.io };
    defer detail.deinit();
    runArgs(init, gpa, argv.items, profile, &detail) catch |err| {
        try printError(init, diagnosticVerb(argv.items), err, &detail);
        return err;
    };
}

fn runArgs(init: std.process.Init, gpa: std.mem.Allocator, argv: []const []const u8, profile: ?[]const u8, detail: *bbr.bitbucket.Client.ErrorDetail) !void {
    const parsed = try parseGlobal(gpa, argv);
    defer gpa.free(parsed.rest);

    if (parsed.verb == null and !parsed.help_only and parsed.rest.len != 0) return error.UnknownFlag;
    if (parsed.verb == null or parsed.help_only) {
        try printHelp(init, parsed.verb);
        return;
    }
    const verb = parsed.verb.?;

    const entry = findVerb(verb) orelse return error.UnknownFlag;

    var owned = cliCredential(gpa, init.io, init.environ_map, parsed.workspace, parsed.profile orelse profile) catch |err| switch (err) {
        error.MissingUsername, error.MissingToken, error.MissingWorkspace => return error.MissingCredential,
        else => return err,
    };
    defer owned.deinit(gpa);

    var transport = bbr.http.StdHttpClient.init(gpa, init.io);
    defer transport.deinit();
    try transport.initDefaultProxies(init.arena.allocator(), init.environ_map);
    var bb = bbr.bitbucket.Client.init(transport.httpClient(), owned.credential());
    bb.error_detail = detail;

    try entry.handler(init, bb, parsed.rest, parsed.json);
}

test "parseGlobal extracts globals and verb" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "--json", "--workspace", "myws", "get-pull-request", "--repository", "r" };
    const p = try parseGlobal(a, &argv);
    defer a.free(p.rest);
    try std.testing.expectEqualStrings("get-pull-request", p.verb.?);
    try std.testing.expect(p.json);
    try std.testing.expectEqualStrings("myws", p.workspace.?);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
}

test "parseGlobal keeps flag values intact" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "--json", "--help", "-h" }) |value| {
        const p = try parseGlobal(a, &.{ "create-comment", "--body", value });
        defer a.free(p.rest);
        try std.testing.expect(!p.json);
        try std.testing.expect(!p.help_only);
        try std.testing.expectEqualStrings("create-comment", p.verb.?);
        try std.testing.expectEqual(@as(usize, 2), p.rest.len);
        try std.testing.expectEqualStrings("--body", p.rest[0]);
        try std.testing.expectEqualStrings(value, p.rest[1]);
    }
}

test "parseGlobal extracts Profiles without consuming verb flag values" {
    const a = std.testing.allocator;
    for ([_][]const []const u8{
        &.{ "--profile", "work", "create-comment", "--body", "--profile", "--workspace=demo" },
        &.{ "create-comment", "--body", "--profile", "--profile=work", "--workspace", "demo" },
    }) |argv| {
        const parsed = try parseGlobal(a, argv);
        defer a.free(parsed.rest);
        try std.testing.expectEqualStrings("work", parsed.profile.?);
        try std.testing.expectEqualStrings("demo", parsed.workspace.?);
        try std.testing.expectEqual(@as(usize, 2), parsed.rest.len);
        try std.testing.expectEqualStrings("--body", parsed.rest[0]);
        try std.testing.expectEqualStrings("--profile", parsed.rest[1]);
    }
    try std.testing.expectError(error.MissingValue, parseGlobal(a, &.{ "whoami", "--profile" }));
    try std.testing.expectError(error.MissingValue, parseGlobal(a, &.{ "whoami", "--profile=" }));
}

test "verb registry is unique and every entry has matching help" {
    var summary_column: ?usize = null;
    inline for (verbs, 0..) |verb, index| {
        for (verbs[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, verb.name, other.name));
        try std.testing.expect(std.mem.startsWith(u8, verbHelp(verb.name), "usage: bbr api " ++ verb.name));
        const row_start = std.mem.indexOf(u8, help, "  " ++ verb.name ++ "  ") orelse return error.TestUnexpectedResult;
        const column = std.mem.indexOf(u8, help[row_start..], verb.summary ++ "\n") orelse return error.TestUnexpectedResult;
        if (summary_column) |expected| try std.testing.expectEqual(expected, column) else summary_column = column;
        try std.testing.expect(std.mem.startsWith(u8, verb.example, "bbr api " ++ verb.name ++ " "));
        var buffer: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeHelp(&writer, verb.name);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), verb.example) != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Global options: --profile NAME, --workspace SLUG, --json, --help.") != null);
    }
    try std.testing.expect(findVerb("frobnicate") == null);
    try std.testing.expectEqualStrings(help, verbHelp("frobnicate"));
    try std.testing.expectEqualStrings(pullrequests.list_help, verbHelp("list-pull-requests"));
    try std.testing.expectEqualStrings(pullrequests.set_verdict_help, verbHelp("set-verdict"));
}

const UsageFlag = struct { name: []const u8, takes_value: bool };

/// The next `--flag` in a help usage block. A flag takes a value when a word
/// such as `N`, `SLUG`, or `true|false` follows it.
fn nextUsageFlag(usage: []const u8, pos: *usize) ?UsageFlag {
    const start = std.mem.indexOfPos(u8, usage, pos.*, "--") orelse return null;
    var end = start + 2;
    while (end < usage.len and (std.ascii.isLower(usage[end]) or std.ascii.isDigit(usage[end]) or usage[end] == '-')) end += 1;
    pos.* = end;
    const takes_value = end + 1 < usage.len and usage[end] == ' ' and std.mem.indexOfScalar(u8, "[(|-", usage[end + 1]) == null;
    return .{ .name = usage[start + 2 .. end], .takes_value = takes_value };
}

test "every verb's help usage shows exactly the flags of its row" {
    var failed = false;
    for (verbs) |verb| {
        const usage = verb.help[0 .. std.mem.indexOf(u8, verb.help, "\n\n") orelse verb.help.len];
        var pos: usize = 0;
        while (nextUsageFlag(usage, &pos)) |flag| {
            if (contains(&global_flags, flag.name)) continue;
            if (contains(if (flag.takes_value) verb.value_flags else verb.switch_flags, flag.name)) continue;
            std.debug.print("bbr api {s}: help usage shows --{s} as a {s}, but its row of `verbs` in src/api/cli.zig does not\n", .{ verb.name, flag.name, if (flag.takes_value) "value flag" else "switch" });
            failed = true;
        }
        for ([_][]const []const u8{ verb.value_flags, verb.switch_flags }) |row_flags| {
            row: for (row_flags) |name| {
                pos = 0;
                while (nextUsageFlag(usage, &pos)) |flag| if (std.mem.eql(u8, flag.name, name)) continue :row;
                std.debug.print("bbr api {s}: its row of `verbs` in src/api/cli.zig lists --{s}, but its help usage does not\n", .{ verb.name, name });
                failed = true;
            }
        }
    }
    try std.testing.expect(!failed);
}

test "skills/bbr/VERBS.md lists every bbr api verb once" {
    const doc = @embedFile("bbr_verbs_md");
    var failed = false;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        const name = bulletVerb(line) orelse continue;
        if (findVerb(name) != null) continue;
        std.debug.print("skills/bbr/VERBS.md lists `{s}`, which is not a row of `verbs` in src/api/cli.zig\n", .{name});
        failed = true;
    }
    for (verbs) |verb| {
        var count: usize = 0;
        lines.reset();
        while (lines.next()) |line| {
            if (std.mem.eql(u8, bulletVerb(line) orelse continue, verb.name)) count += 1;
        }
        if (count == 1) continue;
        std.debug.print("skills/bbr/VERBS.md must list `{s}` in one bullet; it lists it {d} times\n", .{ verb.name, count });
        failed = true;
    }
    try std.testing.expect(!failed);
}

fn bulletVerb(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "- `")) return null;
    const rest = line["- `".len..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '`') orelse return null];
}

test "CLI workspace override works without an environment workspace" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("BITBUCKET_USERNAME", "test-user");
    try env.put("BITBUCKET_TOKEN", "test-token");
    const parsed = try parseGlobal(a, &.{ "list-pull-requests", "--workspace", "flag-workspace" });
    defer a.free(parsed.rest);
    var cred = try cliCredential(a, std.testing.io, &env, parsed.workspace, null);
    defer cred.deinit(a);
    try std.testing.expectEqualStrings("flag-workspace", cred.workspace);
    try std.testing.expectEqualStrings("test-user", cred.username);
    try std.testing.expectEqualStrings("test-token", cred.token);
    try env.put("BITBUCKET_WORKSPACE", "env-workspace");
    var override = try cliCredential(a, std.testing.io, &env, parsed.workspace, null);
    defer override.deinit(a);
    try std.testing.expectEqualStrings("flag-workspace", override.workspace);
    var from_env = try cliCredential(a, std.testing.io, &env, null, null);
    defer from_env.deinit(a);
    try std.testing.expectEqualStrings("env-workspace", from_env.workspace);
    try std.testing.expectEqualStrings("env-workspace", env.get("BITBUCKET_WORKSPACE").?);
}

test "CLI credentials require username token and a workspace" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.MissingUsername, cliCredential(std.testing.allocator, std.testing.io, &env, "flag-workspace", null));
    try env.put("BITBUCKET_USERNAME", "test-user");
    try std.testing.expectError(error.MissingToken, cliCredential(std.testing.allocator, std.testing.io, &env, "flag-workspace", null));
    try env.put("BITBUCKET_TOKEN", "test-token");
    try std.testing.expectError(error.MissingWorkspace, cliCredential(std.testing.allocator, std.testing.io, &env, null, null));
}

test "API credentials use saved Profiles and per-field overrides" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    const path = try bbr.bitbucket.auth.save(a, std.testing.io, &env, "personal", &.{
        .{ .name = "personal", .username = "personal-user", .token = "personal-token", .workspace = "personal-workspace" },
        .{ .name = "work", .username = "work-user", .token = "work-token", .workspace = "" },
    });
    defer a.free(path);

    var active = try cliCredential(a, std.testing.io, &env, null, null);
    defer active.deinit(a);
    try std.testing.expectEqualStrings("personal-user", active.username);
    try std.testing.expectEqualStrings("personal-token", active.token);
    try std.testing.expectEqualStrings("personal-workspace", active.workspace);

    try env.put("BBR_PROFILE", "work");
    try std.testing.expectError(error.MissingWorkspace, cliCredential(a, std.testing.io, &env, null, null));
    var work = try cliCredential(a, std.testing.io, &env, "flag-workspace", null);
    defer work.deinit(a);
    try std.testing.expectEqualStrings("work-user", work.username);
    try std.testing.expectEqualStrings("work-token", work.token);
    try std.testing.expectEqualStrings("flag-workspace", work.workspace);
    try std.testing.expect(env.get("BITBUCKET_WORKSPACE") == null);

    try env.put("BITBUCKET_USERNAME", "override-user");
    try env.put("BITBUCKET_TOKEN", "");
    try env.put("BITBUCKET_WORKSPACE", "env-workspace");
    var override = try cliCredential(a, std.testing.io, &env, "flag-workspace", "personal");
    defer override.deinit(a);
    try std.testing.expectEqualStrings("personal", override.profile);
    try std.testing.expectEqualStrings("override-user", override.username);
    try std.testing.expectEqualStrings("personal-token", override.token);
    try std.testing.expectEqualStrings("flag-workspace", override.workspace);
    try std.testing.expectEqualStrings("env-workspace", env.get("BITBUCKET_WORKSPACE").?);
}

test "global and every verb help write examples to stdout without credentials" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var output: TestOutput = .{};
    var global: arg.Cursor = .{ .args = &.{"--help"} };
    try run(output.init(&env, &arena), a, &global, null);
    try std.testing.expectEqualStrings(help, output.stdoutBytes());
    try std.testing.expectEqual(@as(usize, 0), output.stderr_len);
    for (verbs) |verb| {
        output = .{};
        var args: arg.Cursor = .{ .args = &.{ verb.name, "--help" } };
        try run(output.init(&env, &arena), a, &args, null);
        try std.testing.expect(std.mem.startsWith(u8, output.stdoutBytes(), verb.help));
        try std.testing.expect(std.mem.indexOf(u8, output.stdoutBytes(), verb.example) != null);
        try std.testing.expectEqual(@as(usize, 0), output.stderr_len);
    }
}

test "diagnostic verb lookup skips sensitive values and does not guess unknown flag values" {
    try std.testing.expectEqualStrings("get-pull-request", diagnosticVerb(&.{ "--workspace", "private-workspace", "get-pull-request", "--body" }).?.name);
    try std.testing.expect(diagnosticVerb(&.{ "--body", "get-pull-request", "--workspace" }) == null);
    try std.testing.expect(diagnosticVerb(&.{ "--unknown", "get-pull-request", "--workspace" }) == null);
    try std.testing.expect(diagnosticVerb(&.{ "--workspace=whoami", "--body" }) == null);
    try std.testing.expect(diagnosticVerb(&.{ "private-value", "get-pull-request" }) == null);
    for ([_][]const u8{ "--help", "-h" }) |value| {
        try std.testing.expectEqualStrings("create-comment", diagnosticVerb(&.{ "--body", value, "create-comment", "--workspace" }).?.name);
        try std.testing.expect(diagnosticVerb(&.{ "--body", value, "--repository", "create-comment" }) == null);
        try std.testing.expectEqualStrings("create-comment", diagnosticVerb(&.{ value, "create-comment" }).?.name);
    }
}

test "global parse errors use stderr and name only a safely supplied verb" {
    const cases = [_]struct { args: []const []const u8, prefix: []const u8, hidden: []const u8 }{
        .{ .args = &.{ "--json", "create-comment", "--body", "private-body", "--workspace" }, .prefix = "bbr api create-comment: bad options (MissingValue)\n", .hidden = "private-body" },
        .{ .args = &.{ "--body", "get-pull-request", "--workspace" }, .prefix = "bbr api: bad options (MissingValue)\n", .hidden = "bbr api get-pull-request:" },
        .{ .args = &.{ "--unknown", "get-pull-request", "--workspace" }, .prefix = "bbr api: bad options (MissingValue)\n", .hidden = "bbr api get-pull-request:" },
        .{ .args = &.{ "--workspace", "private-workspace", "get-pull-request", "--pull-request-id" }, .prefix = "bbr api get-pull-request: bad options (MissingValue)\n", .hidden = "private-workspace" },
        .{ .args = &.{"private-invalid-verb"}, .prefix = "bbr api: bad options (UnknownFlag)\n", .hidden = "private-invalid-verb" },
        .{ .args = &.{"--unknown=private-value"}, .prefix = "bbr api: bad options (UnknownFlag)\n", .hidden = "private-value" },
    };
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (cases) |case| {
        var output: TestOutput = .{};
        var args: arg.Cursor = .{ .args = case.args };
        const expected: anyerror = if (case.args.len == 1) error.UnknownFlag else error.MissingValue;
        try std.testing.expectError(expected, run(output.init(&env, &arena), a, &args, null));
        try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
        try std.testing.expect(std.mem.startsWith(u8, output.stderrBytes(), case.prefix));
        try std.testing.expect(std.mem.indexOf(u8, output.stderrBytes(), case.hidden) == null);
    }
}

test "credential handler and proxy initialization errors stay on stderr with json" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var output: TestOutput = .{};
    var missing: arg.Cursor = .{ .args = &.{ "whoami", "--json" } };
    try std.testing.expectError(error.MissingCredential, run(output.init(&env, &arena), a, &missing, null));
    try std.testing.expect(std.mem.startsWith(u8, output.stderrBytes(), "bbr api whoami: MissingCredential\n"));
    try std.testing.expectEqual(@as(usize, 0), output.stdout_len);

    try env.put("BITBUCKET_USERNAME", "private-username");
    try env.put("BITBUCKET_TOKEN", "private-token");
    try env.put("BITBUCKET_WORKSPACE", "private-workspace");
    output = .{};
    var invalid: arg.Cursor = .{ .args = &.{ "whoami", "--json", "--uuid=private-value" } };
    try std.testing.expectError(error.UnknownFlag, run(output.init(&env, &arena), a, &invalid, null));
    try std.testing.expect(std.mem.startsWith(u8, output.stderrBytes(), "bbr api whoami: bad options (UnknownFlag)\n"));
    try std.testing.expect(std.mem.indexOf(u8, output.stderrBytes(), "Example:\n  bbr api whoami --json\n") != null);
    try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
    try std.testing.expect(std.mem.indexOf(u8, output.stderrBytes(), "private-") == null);

    try env.put("https_proxy", "socks5://private-proxy.invalid");
    output = .{};
    var proxy: arg.Cursor = .{ .args = &.{ "whoami", "--json" } };
    try std.testing.expectError(error.InvalidProxyConfiguration, run(output.init(&env, &arena), a, &proxy, null));
    try std.testing.expectEqualStrings("bbr api whoami: InvalidProxyConfiguration\n", output.stderrBytes());
    try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
}

test "error writer formats option help and runtime errors without user values" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeError(&writer, findVerb("get-pull-request"), error.InvalidNumber, null);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "bbr api get-pull-request: bad options (InvalidNumber)\nusage: bbr api get-pull-request"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), findVerb("get-pull-request").?.example) != null);
    writer = std.Io.Writer.fixed(&buffer);
    try writeError(&writer, findVerb("set-verdict"), error.Forbidden, null);
    try std.testing.expectEqualStrings("bbr api set-verdict: Forbidden\n", writer.buffered());
}

test "Bitbucket rejection messages survive response cleanup and stay on stderr" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var detail: bbr.bitbucket.Client.ErrorDetail = .{ .allocator = a, .io = std.testing.io };
    defer detail.deinit();
    const cases = [_]struct { status: u16 = 400, body: []const u8, err: anyerror = error.BadRequest, expected: []const u8, username: []const u8 = "test-user", token: []const u8 = "test-token" }{
        .{
            .body = "{\"type\":\"error\",\"error\":{\"message\":\"Field \\\".resolution\\\" does not support filtering\",\"detail\":\"unused\"}}",
            .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): Field \".resolution\" does not support filtering\n",
        },
        .{
            .status = 403,
            .body = "{\"error\":{\"message\":\"Repository access denied\"}}",
            .err = error.Forbidden,
            .expected = "bbr api list-comments: Bitbucket rejected request (Forbidden): Repository access denied\n",
        },
        .{
            .body = "{\"error\":{\"message\":\"Unsupported\\nfilter\\u001b\"}}",
            .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): Unsupported filter \n",
        },
        .{ .body = "not JSON", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest)\n" },
        .{ .body = "{}", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest)\n" },
        .{ .body = "{\"error\":{\"message\":null}}", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest)\n" },
        .{ .body = "{\"error\":{\"message\":42}}", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest)\n" },
        .{ .body = "{\"error\":{\"message\":\"\"}}", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest)\n" },
        .{ .body = "{\"error\":{\"message\":\"test-token\"}}", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): [redacted]\n" },
        .{ .body = "{\"error\":{\"message\":\"Basic dTp0\"}}", .username = "u", .token = "t", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): Basic [redacted]\n" },
        .{ .body = "{\"error\":{\"message\":\"dTp0\"}}", .username = "u", .token = "t", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): [redacted]\n" },
        .{ .body = "{\"error\":{\"message\":\"Invalid test-token, test-token. Retry.\"}}", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): Invalid [redacted], [redacted]. Retry.\n" },
        .{ .body = "{\"error\":{\"message\":\"Bad Basic dTp0, dTp0, raw t.\"}}", .username = "u", .token = "t", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): Bad Basic [redacted], [redacted], raw [redacted].\n" },
        .{ .body = "{\"error\":{\"message\":\"Basic dTpk\"}}", .username = "u", .token = "d", .expected = "bbr api list-comments: Bitbucket rejected request (BadRequest): Basic [redacted]\n" },
    };
    for (cases) |case| {
        var output: TestOutput = .{};
        var fake: bbr.http.FakeHttpClient = .{ .status = case.status, .body = case.body };
        var bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = case.username, .token = case.token, .workspace = "demo" });
        bb.error_detail = &detail;
        const init = output.init(&env, &arena);
        try std.testing.expectError(case.err, comments.runList(init, bb, &.{ "--repository=sample", "--pull-request-id=42", "--query=resolution=null", "--no-head" }, true));
        try printError(init, findVerb("list-comments"), case.err, &detail);
        try std.testing.expectEqualStrings(case.expected, output.stderrBytes());
        try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    }
}

test "failed verdict changes produce no stdout success result" {
    const pr =
        \\{"id":42,"title":"Review","state":"OPEN","author":{"display_name":"Ada","uuid":"{author}"},
        \\ "source":{"branch":{"name":"feature"},"commit":{"hash":"abc123"}},
        \\ "destination":{"branch":{"name":"main"},"commit":{"hash":"def456"}},"participants":[]}
    ;
    const cases = [_]struct { account: []const u8, expected_commit: []const u8, err: anyerror }{
        .{ .account = "{\"uuid\":\"{account}\"}", .expected_commit = "old", .err = error.ReviewerVerdictChangeFailed },
        .{ .account = "{\"uuid\":\"{author}\"}", .expected_commit = "abc123", .err = error.Forbidden },
    };
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (cases) |case| {
        const responses = [_]bbr.http.Canned{ .{ .body = case.account }, .{ .body = pr } };
        for ([_]bool{ false, true }) |json| {
            var output: TestOutput = .{};
            var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
            const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "test-user", .token = "test-token", .workspace = "demo" });
            const args = &.{ "--repository=sample", "--pull-request-id=42", "--verdict=approved", "--expected-source-commit", case.expected_commit };
            try std.testing.expectError(case.err, pullrequests.runSetVerdict(output.init(&env, &arena), bb, args, json));
            try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
            try std.testing.expectEqual(@as(usize, 2), fake.call_count);
        }
    }
}

test "unresolved verdict changes keep the domain error and the relevant API message" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pr =
        "{\"id\":42,\"title\":\"Review\",\"state\":\"OPEN\",\"author\":{\"display_name\":\"Ada\",\"uuid\":\"{author}\"}," ++
        "\"source\":{\"branch\":{\"name\":\"feature\"},\"commit\":{\"hash\":\"abc123\"}}," ++
        "\"destination\":{\"branch\":{\"name\":\"main\"},\"commit\":{\"hash\":\"def456\"}},\"participants\":[]}";
    const limited: bbr.http.Canned = .{ .status = 429, .body = "{\"error\":{\"message\":\"Slow down\"}}" };
    const forbidden: bbr.http.Canned = .{ .status = 403, .body = "{\"error\":{\"message\":\"Read denied\"}}" };
    for ([_]struct { mutation: bbr.http.Canned, after: bbr.http.Canned, expected: []const u8 }{
        .{ .mutation = limited, .after = .{ .body = pr }, .expected = "bbr api set-verdict: ReviewerVerdictChangeFailed: Bitbucket rejected request (RateLimited): Slow down\n" },
        .{ .mutation = limited, .after = forbidden, .expected = "bbr api set-verdict: ReviewerVerdictChangeFailed: Bitbucket rejected request (Forbidden): Read denied\n" },
        .{ .mutation = .{}, .after = forbidden, .expected = "bbr api set-verdict: ReviewerVerdictChangeFailed: Bitbucket rejected request (Forbidden): Read denied\n" },
    }) |case| {
        for ([_]bool{ false, true }) |json| {
            const responses = [_]bbr.http.Canned{ .{ .body = "{\"uuid\":\"{account}\"}" }, .{ .body = pr }, case.mutation, case.after };
            var output: TestOutput = .{};
            var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
            var detail: bbr.bitbucket.Client.ErrorDetail = .{ .allocator = a, .io = std.testing.io };
            defer detail.deinit();
            var bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "test-user", .token = "test-token", .workspace = "demo" });
            bb.error_detail = &detail;
            const init = output.init(&env, &arena);
            try std.testing.expectError(error.ReviewerVerdictChangeFailed, pullrequests.runSetVerdict(init, bb, &.{ "--repository=sample", "--pull-request-id=42", "--verdict=approved", "--expected-source-commit=abc123" }, json));
            try printError(init, findVerb("set-verdict"), error.ReviewerVerdictChangeFailed, &detail);
            try std.testing.expectEqualStrings(case.expected, output.stderrBytes());
            try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
            try std.testing.expectEqual(@as(usize, 4), fake.call_count);
        }
    }
}

test "API lifecycle globals preserve every new value option and clear-reviewers is boolean" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "name", "target", "title", "source-repository", "destination-branch", "description", "description-file", "reviewer", "draft", "close-source-branch" }) |name| {
        const flag = try std.fmt.allocPrint(a, "--{s}", .{name});
        defer a.free(flag);
        for ([_][]const u8{ "--help", "--profile", "--json", "--workspace=other" }) |value| {
            const parsed = try parseGlobal(a, &.{ "--profile=work", "update-pull-request", flag, value, "--json", "--workspace=demo" });
            defer a.free(parsed.rest);
            try std.testing.expectEqualStrings(value, parsed.rest[1]);
            try std.testing.expectEqualStrings("work", parsed.profile.?);
            try std.testing.expectEqualStrings("demo", parsed.workspace.?);
            try std.testing.expect(parsed.json);
            try std.testing.expect(!parsed.help_only);
        }
    }
    try std.testing.expect(!takesValue("clear-reviewers"));
    try std.testing.expectEqualStrings("update-pull-request", diagnosticVerb(&.{ "--clear-reviewers", "update-pull-request" }).?.name);
}

test "API lifecycle command handlers emit domain JSON and human draft state" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const branch = "{\"name\":\"feature\",\"target\":{\"hash\":\"abc123\"}}";
    const pr = "{\"id\":42,\"title\":\"Review\",\"state\":\"OPEN\",\"draft\":true,\"source\":{\"branch\":{\"name\":\"feature\"}},\"destination\":{\"branch\":{\"name\":\"main\"}}}";
    const cases = [_]struct { verb: []const u8, args: []const []const u8, response: []const u8, method: bbr.http.client.Method, list: bool = false }{
        .{ .verb = "create-branch", .args = &.{ "--repository=sample", "--name=feature", "--target=main" }, .response = branch, .method = .POST },
        .{ .verb = "get-branch", .args = &.{ "--repository=sample", "--name=feature" }, .response = branch, .method = .GET },
        .{ .verb = "list-branches", .args = &.{"--repository=sample"}, .response = "{\"values\":[" ++ branch ++ "]}", .method = .GET, .list = true },
        .{ .verb = "create-pull-request", .args = &.{ "--repository=sample", "--title=Review", "--source-branch=feature" }, .response = pr, .method = .POST },
        .{ .verb = "update-pull-request", .args = &.{ "--repository=sample", "--pull-request-id=42", "--draft=false" }, .response = pr, .method = .PUT },
        .{ .verb = "decline-pull-request", .args = &.{ "--repository=sample", "--pull-request-id=42" }, .response = pr, .method = .POST },
        .{ .verb = "list-commit-pull-requests", .args = &.{ "--repository=sample", "--commit=abc123" }, .response = "{\"values\":[" ++ pr ++ "]}", .method = .GET, .list = true },
    };
    for (cases) |case| {
        var fake: bbr.http.FakeHttpClient = .{ .body = case.response };
        const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
        var output: TestOutput = .{};
        try findVerb(case.verb).?.handler(output.init(&env, &arena), bb, case.args, true);
        try std.testing.expectEqual(case.method, fake.last_method.?);
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
        try std.testing.expectEqual(@as(usize, 0), output.stderr_len);
        const decoded = try std.json.parseFromSlice(std.json.Value, a, output.stdoutBytes(), .{});
        defer decoded.deinit();
        try std.testing.expect(if (case.list) decoded.value == .array else decoded.value == .object);
        if (std.mem.indexOf(u8, case.verb, "pull-request") != null) {
            const item = if (case.list) decoded.value.array.items[0] else decoded.value;
            try std.testing.expect(item.object.get("draft").?.bool);
            var human: TestOutput = .{};
            try findVerb(case.verb).?.handler(human.init(&env, &arena), bb, case.args, false);
            try std.testing.expect(std.mem.indexOf(u8, human.stdoutBytes(), if (case.list) "OPEN draft" else "draft: true") != null);
        }
    }
}

test "get-user prints public identity as JSON and human text" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var fake: bbr.http.FakeHttpClient = .{ .body = "{\"uuid\":\"{user}\",\"account_id\":\"id\",\"display_name\":\"Ada\",\"nickname\":\"ada\"}" };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
    for ([_]bool{ true, false }) |json| {
        var output: TestOutput = .{};
        try findVerb("get-user").?.handler(output.init(&env, &arena), bb, &.{"--user-id=id"}, json);
        try std.testing.expectEqual(@as(usize, 0), output.stderr_len);
        if (json) {
            const decoded = try std.json.parseFromSlice(bbr.bitbucket.User, a, output.stdoutBytes(), .{});
            defer decoded.deinit();
            try std.testing.expectEqualStrings("id", decoded.value.account_id);
            try std.testing.expectEqualStrings("Ada", decoded.value.display_name);
        } else {
            try std.testing.expectEqualStrings("{user} Ada\naccount_id: id\nnickname: ada\n", output.stdoutBytes());
        }
    }
}

test "API lifecycle pending commit lookup has no success output and has an actionable hint" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]u16{ 202, 404 }, [_]anyerror{ error.PullRequestLinksIndexing, error.NotFound }) |status, expected| {
        var output: TestOutput = .{};
        var fake: bbr.http.FakeHttpClient = .{ .status = status, .body = "{\"values\":[]}" };
        var detail: bbr.bitbucket.Client.ErrorDetail = .{ .allocator = a, .io = std.testing.io };
        defer detail.deinit();
        var bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
        bb.error_detail = &detail;
        try std.testing.expectError(expected, pullrequests.runListCommit(output.init(&env, &arena), bb, &.{ "--repository=sample", "--commit=abc123" }, true));
        try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
        var buf: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writeError(&writer, findVerb("list-commit-pull-requests"), expected, &detail);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), if (status == 202) "still indexes" else "Go to pull request") != null);
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    }
}

const member_page_one =
    \\{"page":1,"pagelen":2,"size":3,"values":[{"user":{"uuid":"{partial}","display_name":"Adaline Lovelace"}}],
    \\"next":"https://api.bitbucket.org/2.0/workspaces/demo/members?page=2"}
;
const member_page_two =
    \\{"values":[{"user":{"uuid":"{exact}","display_name":"Ada","nickname":"a"}},
    \\{"user":{"uuid":"{nickname}","display_name":"Nadia","nickname":"Ada"}}]}
;

test "Workspace Member search scans later pages and reports all exact matches before limiting output" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const responses = [_]bbr.http.Canned{ .{ .body = member_page_one }, .{ .body = member_page_two } };
    for ([_][]const u8{ "1", "0" }, [_]i64{ 1, 0 }) |limit, count| {
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
        var output: TestOutput = .{};
        try workspaces.runSearchMembers(output.init(&env, &arena), bb, &.{ "--name=Ada", "--pagelen=2", "--limit", limit }, true);
        try std.testing.expectEqual(@as(usize, 2), fake.call_count);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/workspaces/demo/members?pagelen=2", fake.urlAt(0).?);
        try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(1).?);
        try std.testing.expectEqual(@as(usize, 0), output.stderr_len);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, output.stdoutBytes(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
        const group = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("Ada", group.get("name").?.string);
        try std.testing.expectEqual(@as(usize, 2), group.count());
        const matches = group.get("matches").?.array.items;
        try std.testing.expectEqual(@as(usize, @intCast(count)), matches.len);
        if (count != 0) {
            try std.testing.expectEqual(@as(usize, 3), matches[0].object.count());
            try std.testing.expectEqualStrings("{exact}", matches[0].object.get("uuid").?.string);
            try std.testing.expectEqualStrings("Ada", matches[0].object.get("display_name").?.string);
            try std.testing.expectEqualStrings("a", matches[0].object.get("nickname").?.string);
        }
    }
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
    var human: TestOutput = .{};
    try workspaces.runSearchMembers(human.init(&env, &arena), bb, &.{ "--name=Ada", "--limit=1" }, false);
    try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/workspaces/demo/members?pagelen=100", fake.urlAt(0).?);
    try std.testing.expectEqualStrings("name: Ada\n{exact} Ada nickname: a\nok: 1 shown\n", human.stdoutBytes());
    var listed: TestOutput = .{};
    fake.responses = null;
    fake.body = member_page_two;
    try workspaces.runListMembers(listed.init(&env, &arena), bb, &.{}, true);
    const list = try std.json.parseFromSlice(std.json.Value, a, listed.stdoutBytes(), .{});
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.value.array.items.len);
    var human_list: TestOutput = .{};
    try workspaces.runListMembers(human_list.init(&env, &arena), bb, &.{}, false);
    try std.testing.expect(std.mem.indexOf(u8, human_list.stdoutBytes(), "{nickname} Nadia nickname: Ada") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_list.stdoutBytes(), "ok: 2 Workspace Member(s)") != null);
}

test "Workspace Member searches group repeated names and acquire each page once" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const responses = [_]bbr.http.Canned{ .{ .body = member_page_one }, .{ .body = member_page_two } };
    const names = [_][]const u8{ "Nadia", "Ada", "UnmatchedXYZ", "Ada" };
    for ([_][]const u8{ "1", "0" }) |limit| {
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
        var output: TestOutput = .{};
        try workspaces.runSearchMembers(output.init(&env, &arena), bb, &.{ "--name", names[0], "--name=Ada", "--name", names[2], "--name=Ada", "--limit", limit, "--concurrency=1", "--pagelen=2" }, true);
        try std.testing.expectEqual(@as(usize, 2), fake.call_count);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, output.stdoutBytes(), .{});
        defer parsed.deinit();
        const groups = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 4), groups.len);
        for (groups, names, [_]bool{ true, true, false, true }) |group, name, has_matches| {
            try std.testing.expectEqualStrings(name, group.object.get("name").?.string);
            try std.testing.expectEqual(@as(usize, 2), group.object.count());
            try std.testing.expectEqual(@as(usize, if (has_matches and limit[0] == '1') 1 else 0), group.object.get("matches").?.array.items.len);
        }
    }
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
    var output: TestOutput = .{};
    try workspaces.runSearchMembers(output.init(&env, &arena), bb, &.{ "--name=Nadia", "--name=Ada", "--concurrency=1" }, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output.stdoutBytes(), .{});
    defer parsed.deinit();
    const groups = parsed.value.array.items;
    try std.testing.expectEqualStrings("{nickname}", groups[0].object.get("matches").?.array.items[0].object.get("uuid").?.string);
    try std.testing.expectEqualStrings("{nickname}", groups[1].object.get("matches").?.array.items[1].object.get("uuid").?.string);
    fake.call_count = 0;
    var human: TestOutput = .{};
    try workspaces.runSearchMembers(human.init(&env, &arena), bb, &.{ "--name=Nadia", "--name=Ada", "--limit=1", "--concurrency=1" }, false);
    try std.testing.expectEqual(@as(usize, 2), fake.call_count);
    try std.testing.expectEqualStrings(
        "name: Nadia\n{nickname} Nadia nickname: Ada\nok: 1 shown\n" ++
            "name: Ada\n{exact} Ada nickname: a\nok: 1 shown\n",
        human.stdoutBytes(),
    );
}

test "Workspace Member commands reject invalid options before HTTP and preserve name flag values" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var fake: bbr.http.FakeHttpClient = .{ .body = "{\"values\":[]}" };
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
    var output: TestOutput = .{};
    const init = output.init(&env, &arena);
    for ([_]struct { args: []const []const u8, err: anyerror }{
        .{ .args = &.{}, .err = error.MissingRequired },
        .{ .args = &.{"--name= "}, .err = error.BadRequest },
        .{ .args = &.{"--name=\xff"}, .err = error.BadRequest },
        .{ .args = &.{ "--name=Ada", "--name= " }, .err = error.BadRequest },
        .{ .args = &.{ "--name=Ada", "--name=\xff" }, .err = error.BadRequest },
        .{ .args = &.{ "--name=Ada", "--name=Bob\n" }, .err = error.BadRequest },
        .{ .args = &.{ "--name=Ada", "--name" }, .err = error.MissingValue },
        .{ .args = &.{ "--name=Ada", "--page=2" }, .err = error.UnknownFlag },
        .{ .args = &.{ "--name=Ada", "--no-follow" }, .err = error.UnknownFlag },
        .{ .args = &.{ "--name=Ada", "--pagelen=0" }, .err = error.InvalidNumber },
        .{ .args = &.{ "--name=Ada", "--concurrency=0" }, .err = error.InvalidNumber },
        .{ .args = &.{ "--name=Ada", "--concurrency=-1" }, .err = error.InvalidNumber },
        .{ .args = &.{ "--name=Ada", "--concurrency" }, .err = error.MissingValue },
    }) |case| try std.testing.expectError(case.err, workspaces.runSearchMembers(init, bb, case.args, true));
    try std.testing.expectError(error.UnknownFlag, workspaces.runListMembers(init, bb, &.{"--query=Ada"}, true));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
    try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
    for ([_][]const u8{ "--help", "--profile", "--json", "--workspace=other" }) |value| {
        const parsed = try parseGlobal(a, &.{ "--profile=work", "search-workspace-members", "--name", value, "--name=Ada", "--json", "--workspace=demo" });
        defer a.free(parsed.rest);
        try std.testing.expect(!parsed.help_only);
        try std.testing.expectEqualStrings(value, parsed.rest[1]);
        try std.testing.expectEqualStrings("demo", parsed.workspace.?);
        try std.testing.expectEqualStrings("work", parsed.profile.?);
        var empty: TestOutput = .{};
        try workspaces.runSearchMembers(empty.init(&env, &arena), bb, parsed.rest, parsed.json);
        const groups = try std.json.parseFromSlice(std.json.Value, a, empty.stdoutBytes(), .{});
        defer groups.deinit();
        try std.testing.expectEqual(@as(usize, 2), groups.value.array.items.len);
        for (groups.value.array.items, [_][]const u8{ value, "Ada" }) |group, name| {
            try std.testing.expectEqualStrings(name, group.object.get("name").?.string);
            try std.testing.expectEqual(@as(usize, 0), group.object.get("matches").?.array.items.len);
            try std.testing.expectEqual(@as(usize, 2), group.object.count());
        }
        const concurrency = try parseGlobal(a, &.{ "search-workspace-members", "--name=Ada", "--concurrency", value, "--profile=work", "--workspace=demo", "--json" });
        defer a.free(concurrency.rest);
        try std.testing.expect(!concurrency.help_only);
        try std.testing.expectEqualStrings(value, concurrency.rest[2]);
        try std.testing.expectEqualStrings("demo", concurrency.workspace.?);
        try std.testing.expectError(error.InvalidNumber, workspaces.runSearchMembers(init, bb, concurrency.rest, concurrency.json));
    }
}

test "Workspace Member search failure on any page produces no partial success output" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]bbr.http.Canned{
        .{ .status = 401 }, .{ .status = 403 }, .{ .status = 429 }, .{ .body = "invalid" }, .{ .send_error = error.ConnectionReset },
    }, [_]anyerror{ error.Unauthorized, error.Forbidden, error.RateLimited, error.MalformedResponse, error.ConnectionReset }) |failure, expected| {
        for ([_]bool{ false, true }) |json| {
            for ([_]bool{ false, true }) |later| {
                const responses = [_]bbr.http.Canned{ .{ .body = member_page_one }, failure };
                var fake: bbr.http.FakeHttpClient = .{ .responses = if (later) &responses else responses[1..] };
                const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
                var output: TestOutput = .{};
                try std.testing.expectError(expected, workspaces.runSearchMembers(output.init(&env, &arena), bb, &.{ "--name=Ada", "--name=Nadia", "--concurrency=1" }, json));
                try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
                try std.testing.expectEqual(@as(usize, if (later) 2 else 1), fake.call_count);
            }
        }
    }
}

test "list-workspace-pull-requests prints Repository-qualified rows and no stdout on a failed Repository" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pr = "{\"id\":7,\"title\":\"Review\",\"state\":\"OPEN\",\"draft\":true,\"source\":{\"branch\":{\"name\":\"feature\"}}," ++
        "\"destination\":{\"branch\":{\"name\":\"main\"},\"repository\":{\"full_name\":\"demo/beta\"}}}";
    for ([_]bbr.http.Canned{ .{ .body = "{\"values\":[" ++ pr ++ "]}" }, .{ .status = 403 } }) |beta| {
        var responses = [_]bbr.http.Canned{
            .{ .request_key = "/repositories/demo?", .body = "{\"values\":[{\"slug\":\"beta\"},{\"slug\":\"alpha\"}]}" },
            .{ .request_key = "/alpha/pullrequests", .body = "{\"values\":[]}" },
            beta,
        };
        responses[2].request_key = "/beta/pullrequests";
        for ([_]bool{ false, true }) |json| {
            var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
            const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "demo" });
            var output: TestOutput = .{};
            const result = findVerb("list-workspace-pull-requests").?.handler(output.init(&env, &arena), bb, &.{"--reviewer={reviewer}"}, json);
            try std.testing.expectEqual(@as(usize, 3), fake.call_count);
            if (beta.status != 200) {
                try std.testing.expectError(error.Forbidden, result);
                try std.testing.expectEqual(@as(usize, 0), output.stdout_len);
            } else if (json) {
                try result;
                const decoded = try std.json.parseFromSlice(std.json.Value, a, output.stdoutBytes(), .{});
                defer decoded.deinit();
                try std.testing.expectEqualStrings("demo/beta", decoded.value.array.items[0].object.get("destination_repository").?.string);
            } else {
                try result;
                try std.testing.expectEqualStrings("demo/beta#7 [OPEN draft] Review (feature -> main)\nok: 1 pull request(s)\n", output.stdoutBytes());
            }
        }
    }
}

const TestOutput = struct {
    stdout_buffer: [8192]u8 = undefined,
    stderr_buffer: [8192]u8 = undefined,
    stdout_len: usize = 0,
    stderr_len: usize = 0,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.fileWritePositional = writePositional;
        table.operate = operate;
        break :blk table;
    };

    fn init(self: *TestOutput, env: *std.process.Environ.Map, arena: *std.heap.ArenaAllocator) std.process.Init {
        return .{
            .minimal = undefined,
            .arena = arena,
            .gpa = std.testing.allocator,
            .io = .{ .userdata = self, .vtable = &vtable },
            .environ_map = env,
            .preopens = undefined,
        };
    }

    fn stdoutBytes(self: *const TestOutput) []const u8 {
        return self.stdout_buffer[0..self.stdout_len];
    }

    fn stderrBytes(self: *const TestOutput) []const u8 {
        return self.stderr_buffer[0..self.stderr_len];
    }

    fn writePositional(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, _: u64) std.Io.File.WritePositionalError!usize {
        return capture(userdata, file, header, data, splat);
    }

    fn capture(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize) error{NoSpaceLeft}!usize {
        const self: *TestOutput = @ptrCast(@alignCast(userdata.?));
        const buffer: []u8 = if (file.handle == std.Io.File.stdout().handle) &self.stdout_buffer else &self.stderr_buffer;
        const len: *usize = if (file.handle == std.Io.File.stdout().handle) &self.stdout_len else &self.stderr_len;
        var writer = std.Io.Writer.fixed(buffer[len.*..]);
        writer.writeAll(header) catch return error.NoSpaceLeft;
        for (data, 0..) |part, index| {
            const repetitions = if (index + 1 == data.len) splat else 1;
            for (0..repetitions) |_| writer.writeAll(part) catch return error.NoSpaceLeft;
        }
        const written = writer.buffered().len;
        len.* += written;
        return written;
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const write = switch (operation) {
            .file_write_streaming => |write| write,
            else => unreachable,
        };
        return .{ .file_write_streaming = capture(userdata, write.file, write.header, write.data, write.splat) };
    }
};
