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

pub const Verb = struct {
    name: []const u8,
    summary: []const u8,
    help: []const u8,
    example: []const u8,
    handler: *const fn (std.process.Init, bbr.bitbucket.Client, []const []const u8, bool) anyerror!void,
};

pub const verbs = [_]Verb{
    .{ .name = "list-workspaces", .summary = "list workspaces for the authenticated account", .help = workspaces.list_help, .example = "bbr api list-workspaces --pagelen 10 --no-follow", .handler = workspaces.runList },
    .{ .name = "get-workspace", .summary = "get one workspace", .help = workspaces.get_help, .example = "bbr api get-workspace --workspace demo", .handler = workspaces.runGet },
    .{ .name = "list-repositories", .summary = "list repositories in a workspace", .help = repositories.list_help, .example = "bbr api list-repositories --workspace demo --limit 10", .handler = repositories.runList },
    .{ .name = "get-repository", .summary = "get one repository", .help = repositories.get_help, .example = "bbr api get-repository --workspace demo --repository sample", .handler = repositories.runGet },
    .{ .name = "list-pull-requests", .summary = "list pull requests in a repository", .help = pullrequests.list_help, .example = "bbr api list-pull-requests --repository sample --state OPEN --pagelen 10 --page 2 --no-follow", .handler = pullrequests.runList },
    .{ .name = "get-pull-request", .summary = "get one pull request", .help = pullrequests.get_help, .example = "bbr api get-pull-request --repository sample --pull-request-id 42", .handler = pullrequests.runGet },
    .{ .name = "list-commits", .summary = "list commits (PR, revision, or from..to range)", .help = commits.help, .example = "bbr api list-commits --repository sample --revision main --limit 10", .handler = commits.run },
    .{ .name = "get-diff", .summary = "raw diff of a pull request", .help = files.diff_help, .example = "bbr api get-diff --repository sample --pull-request-id 42 --out review.diff", .handler = files.runDiff },
    .{ .name = "get-compare-diff", .summary = "raw diff between two commits", .help = files.compare_help, .example = "bbr api get-compare-diff --repository sample --from abc123 --to def456 --patch", .handler = files.runCompare },
    .{ .name = "get-blob", .summary = "file bytes at a commit", .help = files.blob_help, .example = "bbr api get-blob --repository sample --commit abc123 --path src/main.zig --out main.zig", .handler = files.runBlob },
    .{ .name = "check-blob", .summary = "verify file metadata at a commit", .help = files.check_help, .example = "bbr api check-blob --repository sample --commit abc123 --path src/main.zig --attributes -", .handler = files.runCheck },
    .{ .name = "list-comments", .summary = "list comments on a pull request", .help = comments.list_help, .example = "bbr api list-comments --repository sample --pull-request-id 42 --no-head --limit 10", .handler = comments.runList },
    .{ .name = "get-comment", .summary = "get one comment", .help = comments.get_help, .example = "bbr api get-comment --repository sample --pull-request-id 42 --comment-id 7", .handler = comments.runGet },
    .{ .name = "create-comment", .summary = "create a comment or reply", .help = comments.create_help, .example = "bbr api create-comment --repository sample --pull-request-id 42 --body 'Please add a test.'", .handler = comments.runCreate },
    .{ .name = "update-comment", .summary = "edit a comment body", .help = comments.update_help, .example = "bbr api update-comment --repository sample --pull-request-id 42 --comment-id 7 --body 'Please test this case.'", .handler = comments.runUpdate },
    .{ .name = "delete-comment", .summary = "delete a comment", .help = comments.delete_help, .example = "bbr api delete-comment --repository sample --pull-request-id 42 --comment-id 7", .handler = comments.runDelete },
    .{ .name = "resolve-comment", .summary = "resolve a comment thread", .help = comments.resolve_help, .example = "bbr api resolve-comment --repository sample --pull-request-id 42 --comment-id 7", .handler = comments.runResolve },
    .{ .name = "reopen-comment", .summary = "reopen a comment thread", .help = comments.reopen_help, .example = "bbr api reopen-comment --repository sample --pull-request-id 42 --comment-id 7", .handler = comments.runReopen },
    .{ .name = "list-tasks", .summary = "list tasks on a pull request", .help = tasks.list_help, .example = "bbr api list-tasks --repository sample --pull-request-id 42 --state-filter UNRESOLVED --limit 10", .handler = tasks.runList },
    .{ .name = "get-task", .summary = "get one task", .help = tasks.get_help, .example = "bbr api get-task --repository sample --pull-request-id 42 --task-id 3", .handler = tasks.runGet },
    .{ .name = "create-task", .summary = "create a task", .help = tasks.create_help, .example = "bbr api create-task --repository sample --pull-request-id 42 --content 'Add a test.'", .handler = tasks.runCreate },
    .{ .name = "update-task", .summary = "update a task (content and/or state)", .help = tasks.update_help, .example = "bbr api update-task --repository sample --pull-request-id 42 --task-id 3 --state RESOLVED", .handler = tasks.runUpdate },
    .{ .name = "delete-task", .summary = "delete a task", .help = tasks.delete_help, .example = "bbr api delete-task --repository sample --pull-request-id 42 --task-id 3", .handler = tasks.runDelete },
    .{ .name = "resolve-task", .summary = "resolve a task", .help = tasks.resolve_help, .example = "bbr api resolve-task --repository sample --pull-request-id 42 --task-id 3", .handler = tasks.runResolve },
    .{ .name = "reopen-task", .summary = "reopen a task", .help = tasks.reopen_help, .example = "bbr api reopen-task --repository sample --pull-request-id 42 --task-id 3", .handler = tasks.runReopen },
    .{ .name = "whoami", .summary = "authenticated account UUID", .help = pullrequests.whoami_help, .example = "bbr api whoami --json", .handler = pullrequests.runWhoami },
    .{ .name = "get-verdict", .summary = "reviewer verdict for an account", .help = pullrequests.get_verdict_help, .example = "bbr api get-verdict --repository sample --pull-request-id 42 --uuid '{reviewer}'", .handler = pullrequests.runGetVerdict },
    .{ .name = "set-verdict", .summary = "set the reviewer verdict", .help = pullrequests.set_verdict_help, .example = "bbr api set-verdict --repository sample --pull-request-id 42 --verdict approved --expected-source-commit abc123", .handler = pullrequests.runSetVerdict },
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
    for (verbs) |verb| text = text ++ "  " ++ verb.name ++ "  " ++ verb.summary ++ "\n";
    break :blk text ++ "\nAuth comes from `bbr login` Profiles with per-field BITBUCKET_* overrides.\n" ++
        "Profile selection: --profile, BBR_PROFILE, Active Profile, default.\n" ++
        "Workspace selection: --workspace, BITBUCKET_WORKSPACE, selected Profile.\n";
};

const value_flags = [_][]const u8{
    "workspace", "repository",    "pull-request-id",    "comment-id",
    "parent-id", "task-id",       "body",               "body-file",
    "content",   "content-file",  "path",               "file-path",
    "to",        "from",          "start-to",           "start-from",
    "state",     "state-filter",  "source-branch",      "commit",
    "revision",  "source-commit", "destination-commit", "expected-source-commit",
    "uuid",      "out",           "pagelen",            "page",
    "query",     "sort",          "limit",              "attributes",
    "verdict",   "profile",
};

fn takesValue(name: []const u8) bool {
    return completionTakesValue(name);
}

/// Global `bbr api` flags, also completed before and after the verb.
pub const global_flags = [_][]const u8{ "profile", "workspace", "json", "help" };

/// Whether a flag name takes a value (space or `=` form). Shared with the
/// `bbr completion` scripts so value flags don't complete as booleans.
pub fn completionTakesValue(name: []const u8) bool {
    for (value_flags) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// Value-flag names for embedding in completion scripts.
pub const completion_value_flags = value_flags;

/// Per-verb flags for completion. Keep beside `verbs[]`: a new verb row needs
/// its flag row or `bbr completion` won't offer the verb's options. Names are
/// the long `--kebab-case` form without `--`; boolean flags (`--no-follow`,
/// `--no-head`, `--patch`, `--json`) are included too.
pub const VerbFlags = struct {
    verb: []const u8,
    flags: []const []const u8,
};

pub const verb_flags = [_]VerbFlags{
    .{ .verb = "list-workspaces", .flags = &.{ "pagelen", "page", "query", "sort", "no-follow", "limit", "json" } },
    .{ .verb = "get-workspace", .flags = &.{ "workspace", "json" } },
    .{ .verb = "list-repositories", .flags = &.{ "workspace", "pagelen", "page", "query", "sort", "no-follow", "limit", "json" } },
    .{ .verb = "get-repository", .flags = &.{ "repository", "workspace", "json" } },
    .{ .verb = "list-pull-requests", .flags = &.{ "repository", "state", "source-branch", "pagelen", "page", "query", "sort", "no-follow", "limit", "json" } },
    .{ .verb = "get-pull-request", .flags = &.{ "repository", "pull-request-id", "json" } },
    .{ .verb = "list-commits", .flags = &.{ "repository", "pull-request-id", "revision", "from", "to", "pagelen", "page", "query", "sort", "no-follow", "limit", "json" } },
    .{ .verb = "get-diff", .flags = &.{ "repository", "pull-request-id", "out", "json" } },
    .{ .verb = "get-compare-diff", .flags = &.{ "repository", "from", "to", "patch", "out", "json" } },
    .{ .verb = "get-blob", .flags = &.{ "repository", "commit", "path", "out", "json" } },
    .{ .verb = "check-blob", .flags = &.{ "repository", "commit", "path", "attributes", "json" } },
    .{ .verb = "list-comments", .flags = &.{ "repository", "pull-request-id", "source-commit", "destination-commit", "no-head", "pagelen", "page", "query", "sort", "no-follow", "limit", "json" } },
    .{ .verb = "get-comment", .flags = &.{ "repository", "pull-request-id", "comment-id", "json" } },
    .{ .verb = "create-comment", .flags = &.{ "repository", "pull-request-id", "body", "body-file", "parent-id", "path", "to", "from", "start-to", "start-from", "file-path", "source-commit", "json" } },
    .{ .verb = "update-comment", .flags = &.{ "repository", "pull-request-id", "comment-id", "body", "body-file", "json" } },
    .{ .verb = "delete-comment", .flags = &.{ "repository", "pull-request-id", "comment-id" } },
    .{ .verb = "resolve-comment", .flags = &.{ "repository", "pull-request-id", "comment-id", "json" } },
    .{ .verb = "reopen-comment", .flags = &.{ "repository", "pull-request-id", "comment-id", "json" } },
    .{ .verb = "list-tasks", .flags = &.{ "repository", "pull-request-id", "state-filter", "pagelen", "page", "query", "sort", "no-follow", "limit", "json" } },
    .{ .verb = "get-task", .flags = &.{ "repository", "pull-request-id", "task-id", "json" } },
    .{ .verb = "create-task", .flags = &.{ "repository", "pull-request-id", "content", "content-file", "comment-id", "json" } },
    .{ .verb = "update-task", .flags = &.{ "repository", "pull-request-id", "task-id", "content", "content-file", "state", "json" } },
    .{ .verb = "delete-task", .flags = &.{ "repository", "pull-request-id", "task-id" } },
    .{ .verb = "resolve-task", .flags = &.{ "repository", "pull-request-id", "task-id", "json" } },
    .{ .verb = "reopen-task", .flags = &.{ "repository", "pull-request-id", "task-id", "json" } },
    .{ .verb = "whoami", .flags = &.{"json"} },
    .{ .verb = "get-verdict", .flags = &.{ "repository", "pull-request-id", "uuid", "json" } },
    .{ .verb = "set-verdict", .flags = &.{ "repository", "pull-request-id", "verdict", "expected-source-commit", "json" } },
};

/// Flag names for one verb, or `null` for an unknown verb.
pub fn flagsForVerb(name: []const u8) ?[]const []const u8 {
    for (verb_flags) |entry| if (std.mem.eql(u8, entry.verb, name)) return entry.flags;
    return null;
}

/// Split argv (after `api`) into globals + verb + verb args.
/// Strips `--json`, `--workspace V`, and `--profile V` wherever
/// they appear as flags (never as a value-flag's value). `--help` anywhere
/// sets help_only.
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

fn writeError(writer: *std.Io.Writer, verb: ?Verb, err: anyerror) !void {
    try writer.writeAll("bbr api");
    if (verb) |v| try writer.print(" {s}", .{v.name});
    if (isOptionError(err)) {
        try writer.print(": bad options ({s})\n", .{@errorName(err)});
        try writeHelp(writer, if (verb) |v| v.name else null);
    } else {
        try writer.print(": {s}\n", .{@errorName(err)});
        if (err == error.MissingCredential) {
            try writer.writeAll("Run `bbr login` or set BITBUCKET_USERNAME, BITBUCKET_TOKEN, and --workspace or BITBUCKET_WORKSPACE.\n");
        }
    }
}

fn printError(init: std.process.Init, verb: ?Verb, err: anyerror) !void {
    var buf: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    try writeError(&stderr.interface, verb, err);
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
            } else if (!std.mem.eql(u8, f.name, "json") and
                !std.mem.eql(u8, f.name, "no-follow") and
                !std.mem.eql(u8, f.name, "no-head") and
                !std.mem.eql(u8, f.name, "patch"))
            {
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
        try printError(init, diagnosticVerb(argv.items), err);
        return err;
    };
    runArgs(init, gpa, argv.items, profile) catch |err| {
        try printError(init, diagnosticVerb(argv.items), err);
        return err;
    };
}

fn runArgs(init: std.process.Init, gpa: std.mem.Allocator, argv: []const []const u8, profile: ?[]const u8) !void {
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
    const bb = bbr.bitbucket.Client.init(transport.httpClient(), owned.credential());

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
    const argv = [_][]const u8{ "create-comment", "--body", "--json" };
    const p = try parseGlobal(a, &argv);
    defer a.free(p.rest);
    // `--json` right after value-flag `--body` is its value, not the global.
    try std.testing.expect(!p.json);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
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
    try std.testing.expectEqual(@as(usize, 28), verbs.len);
    inline for (verbs, 0..) |verb, index| {
        for (verbs[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, verb.name, other.name));
        try std.testing.expect(std.mem.startsWith(u8, verbHelp(verb.name), "usage: bbr api " ++ verb.name));
        try std.testing.expect(std.mem.indexOf(u8, help, "  " ++ verb.name ++ "  " ++ verb.summary ++ "\n") != null);
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
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
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
    try writeError(&writer, findVerb("get-pull-request"), error.InvalidNumber);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "bbr api get-pull-request: bad options (InvalidNumber)\nusage: bbr api get-pull-request"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), findVerb("get-pull-request").?.example) != null);
    writer = std.Io.Writer.fixed(&buffer);
    try writeError(&writer, findVerb("set-verdict"), error.Forbidden);
    try std.testing.expectEqualStrings("bbr api set-verdict: Forbidden\n", writer.buffered());
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
