//! bbr entry point. Zig 0.16 hands `main` an `Init` carrying `gpa`, `arena`,
//! `io` (a `std.Io.Threaded`-backed runtime), `environ_map`, and args — so we do
//! not construct any of that ourselves.
//!
//! Startup resolves what to open (design §startup): a pasted PR URL, an explicit
//! `<repo> <id>`, or auto-detection from the current worktree (the tracking
//! remote + the branch's open PRs). The TUI then loads that PR and lets the
//! reviewer switch with the fuzzy Picker.

const std = @import("std");
const bbr = @import("bbr");
const build_options = @import("build_options");
const app = @import("tui/app.zig");
const session = @import("tui/session.zig");
const persist = @import("persist/sqlite_store.zig");
const config = @import("tui/config.zig");
const TreeSitterHighlighter = @import("highlight/tree_sitter_highlighter.zig").TreeSitterHighlighter;
const grammar_cli = @import("highlight/grammar_cli.zig");
const api_cli = @import("api/cli.zig");
const completion_cli = @import("completion.zig");
const presentation = @import("tui/presentation.zig");
const buffer_mod = @import("tui/buffer.zig");

/// Single-pass view over already-collected argv. Subcommand runners take
/// `it: anytype` and call `it.next()`, so this keeps their call sites
/// unchanged while the global `--profile` flag is filtered out up front.
const ArgSlice = struct {
    args: []const []const u8,
    idx: usize = 0,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.idx >= self.args.len) return null;
        defer self.idx += 1;
        return self.args[self.idx];
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const auth = bbr.bitbucket.auth;

    // Collect argv so each subcommand can parse its flags and their values.
    var it = init.minimal.args.iterate();
    _ = it.next(); // executable name
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (it.next()) |arg| try argv.append(gpa, arg);

    var flag_profile: ?[]const u8 = null;
    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(gpa);
    var arg_idx: usize = 0;
    while (arg_idx < argv.items.len) : (arg_idx += 1) {
        const a = argv.items[arg_idx];
        if (filtered.items.len == 0 and std.mem.eql(u8, a, "api")) {
            var api_args = ArgSlice{ .args = argv.items[arg_idx + 1 ..] };
            return api_cli.run(init, gpa, &api_args, flag_profile);
        } else if (std.mem.eql(u8, a, "--profile")) {
            arg_idx += 1;
            if (arg_idx >= argv.items.len) {
                std.debug.print("bbr: --profile needs a value\n", .{});
                return;
            }
            flag_profile = argv.items[arg_idx];
        } else if (std.mem.startsWith(u8, a, "--profile=")) {
            flag_profile = a["--profile=".len..];
            if (flag_profile.?.len == 0) {
                std.debug.print("bbr: --profile needs a value\n", .{});
                return;
            }
        } else {
            try filtered.append(gpa, a);
        }
    }
    if (flag_profile) |p| {
        if (!auth.isValidProfileName(p)) {
            std.debug.print("bbr: invalid profile name '{s}'\n", .{p});
            return;
        }
    }

    const first: ?[]const u8 = if (filtered.items.len > 0) filtered.items[0] else null;
    const rest_args: []const []const u8 = if (filtered.items.len > 1) filtered.items[1..] else &[_][]const u8{};
    var rest = ArgSlice{ .args = rest_args };

    if (first) |argument| {
        if (std.mem.eql(u8, argument, "--version")) {
            var output_buffer: [128]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
            try stdout.interface.print("bbr {s}\n", .{build_options.version});
            return stdout.interface.flush();
        }
    }

    // `demo` needs no credentials: it feeds synthetic data through the real
    // buffer/renderer so the comment UI can be exercised entirely offline.
    if (first) |f| {
        if (std.mem.eql(u8, f, "grammar")) return grammarRun(init, gpa, &rest);
        if (std.mem.eql(u8, f, "demo")) {
            var loaded = try config.load(gpa, init.io, init.environ_map);
            defer loaded.deinit(gpa);
            return switch (loaded) {
                .ok => |*configuration| demoRun(init.io, gpa, init.environ_map, configuration),
                .invalid => |failure| failure.report(),
            };
        }
        if (std.mem.eql(u8, f, "local")) return localRun(init, gpa, &rest);
        if (std.mem.eql(u8, f, "external-edit-smoke")) {
            if (!std.mem.eql(u8, init.environ_map.get("BBR_ALLOW_PTY_SMOKE") orelse "", "1")) {
                std.debug.print("bbr: refusing PTY smoke without BBR_ALLOW_PTY_SMOKE=1\n", .{});
                return;
            }
            try app.externalEditSmoke(init.io, gpa, init.environ_map);
            std.debug.print("ok: External Edit PTY handoff, redraw, and recreated input verified\n", .{});
            return;
        }
        if (std.mem.eql(u8, f, "login")) return loginRun(init, gpa, &rest, flag_profile);
        if (std.mem.eql(u8, f, "logout")) return logoutRun(init, gpa, &rest, flag_profile);
        if (std.mem.eql(u8, f, "completion")) return completion_cli.run(init, gpa, &rest);
        if (std.mem.eql(u8, f, "check-blobs")) {
            var blob_owned = auth.resolve(gpa, init.io, init.environ_map, flag_profile) catch |err| {
                if (err == error.InvalidAuthFile) return;
                std.debug.print("skipped: blob checker needs a login (`bbr login`) or BITBUCKET_USERNAME, BITBUCKET_TOKEN, and BITBUCKET_WORKSPACE\n", .{});
                return;
            };
            defer blob_owned.deinit(gpa);
            return checkBlobsRun(init, gpa, blob_owned.credential(), &rest);
        }
    }

    var owned = auth.resolve(gpa, init.io, init.environ_map, flag_profile) catch |err| {
        if (err == error.InvalidAuthFile) return;
        std.debug.print("bbr: missing credential: {s}\nRun `bbr login` to save credentials, or set BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE.\n", .{
            @errorName(err),
        });
        return;
    };
    defer owned.deinit(gpa);
    const cred = owned.credential();

    if (first) |f| {
        // Debug aids: dump raw comment JSON (no parsing).
        if (std.mem.eql(u8, f, "raw-comments")) return rawComments(init, gpa, cred, &rest);
        if (std.mem.eql(u8, f, "raw-comment")) return rawComment(init, gpa, cred, &rest);
        // Live smoke test: fetch + print, no TUI (scriptable, exits non-zero on failure).
        if (std.mem.eql(u8, f, "check")) return checkRun(init, gpa, cred, &rest);
        if (std.mem.eql(u8, f, "check-acquisition")) return checkAcquisitionRun(init, gpa, cred);
        if (std.mem.eql(u8, f, "check-mutation")) return checkMutationRun(init, gpa, cred, &rest);
        if (std.mem.eql(u8, f, "check-verdict")) return checkVerdictRun(init, gpa, cred, &rest);
        // Print startup resolution (branch/remote/PR list) without the TUI.
        if (std.mem.eql(u8, f, "detect")) return detectRun(init, gpa, cred, &rest);
    }

    // Build the startup input from the remaining args: a URL, an explicit
    // `<repo> <id>`, a bare `<repo>` (detect within it), or nothing (detect all).
    var input: bbr.startup.Input = .{};
    if (first) |f| {
        if (looksLikeUrl(f)) {
            input = .{ .url = f };
        } else if (rest.next()) |second| {
            input = .{ .repo_slug = f, .id = std.fmt.parseInt(u64, second, 10) catch return usage() };
        } else {
            input = .{ .repo_slug = f };
        }
    }

    var loaded = try config.load(gpa, init.io, init.environ_map);
    defer loaded.deinit(gpa);
    switch (loaded) {
        .ok => |*configuration| try openTui(init, gpa, cred, input, configuration),
        .invalid => |failure| failure.report(),
    }
}

fn grammarRun(init: std.process.Init, gpa: std.mem.Allocator, it: anytype) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    while (it.next()) |arg| try args.append(gpa, arg);

    const needs_confirmation = args.items.len > 0 and
        (std.mem.eql(u8, args.items[0], "install") or std.mem.eql(u8, args.items[0], "update")) and
        !containsTrustArgument(args.items);
    var interactive_digest: ?[32]u8 = null;
    if (needs_confirmation) {
        const path_index: usize = if (std.mem.eql(u8, args.items[0], "update")) 2 else 1;
        if (args.items.len <= path_index) return usage();
        var output_buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
        const previewed_digest = try grammar_cli.writeCandidateReport(gpa, init.io, args.items[path_index], &stdout.interface);
        try stdout.interface.writeAll("Trust this exact bundle? [y/N] ");
        try stdout.interface.flush();
        var buffer: [16]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(init.io, &buffer);
        const answer = (try stdin.interface.takeDelimiter('\n')) orelse "";
        const approved = std.ascii.eqlIgnoreCase(std.mem.trim(u8, answer, " \t\r"), "y") or
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, answer, " \t\r"), "yes");
        if (approved) interactive_digest = previewed_digest;
    }
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    grammar_cli.run(gpa, init.io, init.environ_map, args.items, interactive_digest, &stdout.interface) catch |err| {
        std.debug.print("bbr grammar: {s}\n", .{@errorName(err)});
        return err;
    };
    try stdout.interface.flush();
}

fn containsTrustArgument(args: []const []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "--trust-sha256")) return true;
    return false;
}

/// Resolve the startup entry and hand off to the TUI. One StdHttpClient serves
/// startup and every remote worker so its connection pool lives for the TUI.
fn openTui(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, input: bbr.startup.Input, configuration: *const config.Configuration) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var git = bbr.git.ShellGitClient.init(gpa, init.io);

    var client = bbr.http.StdHttpClient.init(std.heap.page_allocator, init.io);
    defer client.deinit();
    try client.initDefaultProxies(a, init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const entry = bbr.startup.resolve(a, git.gitClient(), bb, input) catch |err| {
        std.debug.print("bbr: could not resolve a PR to open: {s}\n", .{@errorName(err)});
        return;
    };

    // The repo and the id to open. A picker/empty result has no single id, so we
    // fall back to the first listed PR (the reviewer switches with `p`).
    const target: struct { repo: []const u8, id: u64 } = switch (entry) {
        .open => |t| .{ .repo = t.repo_slug, .id = t.id },
        .pick => |p| blk: {
            if (p.prs.len == 0) break :blk .{ .repo = p.repo_slug, .id = 0 };
            std.debug.print("bbr: {d} open PRs; opening #{d}. Press 'p' to switch.\n", .{ p.prs.len, p.prs[0].id });
            break :blk .{ .repo = p.repo_slug, .id = p.prs[0].id };
        },
        .empty => |repo| {
            std.debug.print("bbr: no open pull requests in {s}.\n", .{repo});
            return;
        },
    };

    // The initial PR is loaded on a worker thread inside `app.run` (it shows a
    // "Loading PR #N…" frame meanwhile), so we don't block here — `run` is told
    // which id to open and passes `initial = null`.

    // `repo` must outlive the TUI (worker loads copy it), so dupe it into a
    // buffer the run owns via the session-independent gpa arena above… but that
    // arena is freed on return. Copy into a stable stack buffer instead.
    var repo_buf: [256]u8 = undefined;
    const repo_len = @min(target.repo.len, repo_buf.len);
    @memcpy(repo_buf[0..repo_len], target.repo[0..repo_len]);

    // Global-tier pending-review store (design §11): opened once, lives until exit.
    var store = openStore(gpa, init.io, init.environ_map);
    defer store.deinit();
    var lock_dir = try openSubmissionLockDir(gpa, init.io, init.environ_map);
    defer lock_dir.close(init.io);
    var os_locks = bbr.review.OsSubmissionLocks.init(gpa, init.io, lock_dir);
    defer os_locks.deinit();
    var grammar_store: ?grammar_cli.Store = grammar_cli.Store.open(gpa, init.io, init.environ_map) catch |err| switch (err) {
        error.NoDataHome => null,
        else => return err,
    };
    defer if (grammar_store) |*grammar_data_store| grammar_data_store.deinit();
    var grammar_registry: ?@import("highlight/user_grammar.zig").Registry = null;
    defer if (grammar_registry) |*registry| registry.deinit();
    if (grammar_store) |*grammar_data_store| {
        const grammar_entries = try grammar_data_store.registryEntries(a);
        const grammar_overrides = try grammar_cli.loadOverrides(a, init.io, init.environ_map);
        try grammar_data_store.validateOverrideNames(grammar_overrides);
        grammar_registry = try @import("highlight/user_grammar.zig").Registry.init(gpa, init.io, grammar_entries, grammar_overrides, grammar_cli.bbr_identity);
    }
    var tree_sitter_highlighter = try TreeSitterHighlighter.init(gpa, if (grammar_registry) |*registry| registry else null);
    defer tree_sitter_highlighter.deinit();

    app.run(.{
        .io = init.io,
        .gpa = gpa,
        .env_map = init.environ_map,
        .bitbucket = bb,
        .repo = repo_buf[0..repo_len],
        .store = store.store(),
        .active_theme = configuration.active_theme,
        .keymap = configuration.keymap.keymap(),
        .highlighter = tree_sitter_highlighter.highlighter(),
        .highlight_max_file_bytes = configuration.highlight_max_file_bytes,
        .file_cache_enabled = configuration.file_cache_enabled,
        .inactive_file_cache_max_bytes = configuration.inactive_file_cache_max_bytes,
        .comments_collapsed_rows = configuration.comments_collapsed_rows,
        .mouse_enabled = configuration.mouse_enabled,
        .mouse_vertical_scroll_rows = configuration.mouse_vertical_scroll_rows,
        .external_edit_max_bytes = configuration.external_edit_max_bytes,
        .submission_locks = os_locks.locks(),
    }, null, try presentation.OwnedReviewIdentity.init(cred.workspace, target.repo, target.id)) catch |err| {
        if (tuiFatalMessage(err)) |message| {
            std.debug.print("{s}\n", .{message});
            return;
        }
        return err;
    };
}

fn localRun(init: std.process.Init, gpa: std.mem.Allocator, it: anytype) !void {
    const base_input = it.next();
    const source_input = it.next();
    if (it.next() != null) return usage();

    var loaded = try config.load(gpa, init.io, init.environ_map);
    defer loaded.deinit(gpa);
    const configuration = switch (loaded) {
        .ok => |*value| value,
        .invalid => |failure| return failure.report(),
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var git = bbr.git.ShellGitClient.init(gpa, init.io);
    const client = git.gitClient();
    const source_name = if (source_input) |value| value else client.currentBranch(a) catch |err| {
        std.debug.print("bbr local: cannot determine SourceRef: {s}\n", .{@errorName(err)});
        return;
    };
    const source = client.resolveRef(a, source_name) catch |err| {
        std.debug.print("bbr local: cannot resolve SourceRef '{s}': {s}\n", .{ source_name, @errorName(err) });
        return;
    };
    const base_name = if (base_input) |value| value else client.defaultBaseRef(a, source.canonical) catch |err| {
        std.debug.print("bbr local: no default BaseRef ({s}); pass one explicitly\n", .{@errorName(err)});
        return;
    };
    const base = client.resolveRef(a, base_name) catch |err| {
        std.debug.print("bbr local: cannot resolve BaseRef '{s}': {s}\n", .{ base_name, @errorName(err) });
        return;
    };
    const common_dir = client.commonDir(a) catch |err| {
        std.debug.print("bbr local: cannot identify repository: {s}\n", .{@errorName(err)});
        return;
    };

    var store = openStore(gpa, init.io, init.environ_map);
    defer store.deinit();
    const common_alias = try std.fmt.allocPrint(a, "common:{s}", .{common_dir});
    var aliases: [2][]const u8 = undefined;
    var alias_count: usize = 0;
    if (client.repositoryRemote(a, source.canonical)) |remote| {
        aliases[alias_count] = try std.fmt.allocPrint(a, "remote:{s}", .{remote});
        alias_count += 1;
    } else |_| {}
    aliases[alias_count] = common_alias;
    alias_count += 1;
    const repository_id = store.store().resolveRepository(aliases[0..alias_count]) catch |err| {
        std.debug.print("bbr local: cannot resolve repository identity: {s}\n", .{@errorName(err)});
        return;
    };
    const key = presentation.OwnedReviewIdentity.initLocal(repository_id, base.canonical, source.canonical) catch {
        std.debug.print("bbr local: Ref name is too long\n", .{});
        return;
    };

    var grammar_store: ?grammar_cli.Store = grammar_cli.Store.open(gpa, init.io, init.environ_map) catch |err| switch (err) {
        error.NoDataHome => null,
        else => return err,
    };
    defer if (grammar_store) |*grammar_data_store| grammar_data_store.deinit();
    var grammar_registry: ?@import("highlight/user_grammar.zig").Registry = null;
    defer if (grammar_registry) |*registry| registry.deinit();
    if (grammar_store) |*grammar_data_store| {
        const grammar_entries = try grammar_data_store.registryEntries(a);
        const grammar_overrides = try grammar_cli.loadOverrides(a, init.io, init.environ_map);
        try grammar_data_store.validateOverrideNames(grammar_overrides);
        grammar_registry = try @import("highlight/user_grammar.zig").Registry.init(gpa, init.io, grammar_entries, grammar_overrides, grammar_cli.bbr_identity);
    }
    var tree_sitter_highlighter = try TreeSitterHighlighter.init(gpa, if (grammar_registry) |*registry| registry else null);
    defer tree_sitter_highlighter.deinit();
    try app.run(.{
        .io = init.io,
        .gpa = gpa,
        .env_map = init.environ_map,
        .repo = "",
        .store = store.store(),
        .active_theme = configuration.active_theme,
        .keymap = configuration.keymap.keymap(),
        .highlighter = tree_sitter_highlighter.highlighter(),
        .highlight_max_file_bytes = configuration.highlight_max_file_bytes,
        .file_cache_enabled = configuration.file_cache_enabled,
        .inactive_file_cache_max_bytes = configuration.inactive_file_cache_max_bytes,
        .comments_collapsed_rows = configuration.comments_collapsed_rows,
        .mouse_enabled = configuration.mouse_enabled,
        .mouse_vertical_scroll_rows = configuration.mouse_vertical_scroll_rows,
        .external_edit_max_bytes = configuration.external_edit_max_bytes,
        .online = false,
    }, null, key);
}

fn tuiFatalMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.FileEnrichmentOutOfMemory => "bbr: file enrichment ran out of memory; the review was not modified",
        else => null,
    };
}

/// Open the pending-review store at `~/.local/state/bbr/pending.db`, creating the
/// directory. Falls back to an in-memory (non-durable) store when HOME is unset
/// or the file can't be prepared, so the reviewer can still author this session.
fn openStore(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) persist.SqliteStore {
    if (statePath(gpa, io, env_map)) |path| {
        defer gpa.free(path);
        if (persist.SqliteStore.open(path)) |s| {
            return s;
        } else |err| {
            std.debug.print("bbr: could not open {s} ({s}); drafts won't persist this session\n", .{ path, @errorName(err) });
        }
    } else |_| {}
    return persist.SqliteStore.open(":memory:") catch @panic("sqlite :memory: open failed");
}

/// Build the state DB path, creating `~/.local/state/bbr`. Caller frees.
fn statePath(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) ![:0]u8 {
    const home = env_map.get("HOME") orelse return error.NoHome;
    const dir = try std.fmt.allocPrint(gpa, "{s}/.local/state/bbr", .{home});
    defer gpa.free(dir);
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.close(io);
    return std.fmt.allocPrintSentinel(gpa, "{s}/pending.db", .{dir}, 0);
}

fn openSubmissionLockDir(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !std.Io.Dir {
    const home = env_map.get("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(gpa, "{s}/.local/state/bbr/submission-locks", .{home});
    defer gpa.free(path);
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
}

fn looksLikeUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or
        std.mem.startsWith(u8, s, "https://") or
        std.mem.indexOf(u8, s, "bitbucket.org") != null;
}

fn rawComments(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const pr_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const raw = try bb.getCommentsRaw(gpa, repo, pr_id);
    defer gpa.free(raw);
    std.debug.print("{s}\n", .{raw});
}

fn rawComment(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const pr_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();
    const cid = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const raw = try bb.getCommentRaw(gpa, repo, pr_id, cid);
    defer gpa.free(raw);
    std.debug.print("{s}\n", .{raw});
}

fn checkRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const pr = try bb.getPullRequest(gpa, repo, id);
    defer bbr.bitbucket.deinitPullRequest(gpa, pr);

    std.debug.print(
        "ok: fetched PR from Bitbucket\n#{d} [{s}] {s}\n  author: {s}\n  {s} -> {s}\n",
        .{ pr.id, pr.state, pr.title, pr.author_display_name, pr.source_branch, pr.destination_branch },
    );

    // Also fetch comments and summarize, so a real run confirms the live JSON
    // shape parses (esp. the inline/outdated fields we couldn't verify offline).
    var carena = std.heap.ArenaAllocator.init(gpa);
    defer carena.deinit();
    const comments = try bb.getComments(carena.allocator(), repo, id, .{
        .source = pr.source_commit,
        .destination = pr.destination_commit,
    });
    const threads = try bbr.review.buildThreads(carena.allocator(), comments);

    var inline_n: usize = 0;
    var resolved_n: usize = 0;
    var outdated_n: usize = 0;
    for (threads) |t| {
        if (t.isInline()) inline_n += 1;
        if (t.resolved) resolved_n += 1;
        if (t.root.state == .outdated) outdated_n += 1;
    }
    std.debug.print(
        "  comments: {d} in {d} threads ({d} inline, {d} resolved, {d} outdated)\n",
        .{ comments.len, threads.len, inline_n, resolved_n, outdated_n },
    );
    if (threads.len > 0) {
        const t = threads[0];
        const anc: []const u8 = if (t.root.anchor) |x| x.path else "(PR-level)";
        std.debug.print("  first thread: {s} on {s} — \"{s}\" (+{d} replies)\n", .{
            t.root.author, anc, firstLine(t.root.body), t.replies.len,
        });
    }
}

fn checkAcquisitionRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential) !void {
    if (!std.mem.eql(u8, init.environ_map.get("BBR_ALLOW_LIVE_ACQUISITION_GATE") orelse "", "1")) {
        std.debug.print("bbr: refusing live acquisition gate without BBR_ALLOW_LIVE_ACQUISITION_GATE=1\n", .{});
        return;
    }
    const ids = [_]u64{ 1856, 1726 };
    for (ids) |id| {
        var sequential: [10]u64 = undefined;
        var bounded: [10]u64 = undefined;
        var failures: usize = 0;
        var rate_limited: usize = 0;
        var max_connections: usize = 0;
        for (0..10) |sample_index| {
            sequential[sample_index] = runAcquisitionSample(init, gpa, cred, id, false, &failures, &rate_limited, &max_connections) catch 0;
            bounded[sample_index] = runAcquisitionSample(init, gpa, cred, id, true, &failures, &rate_limited, &max_connections) catch 0;
        }
        std.mem.sort(u64, &sequential, {}, std.sort.asc(u64));
        std.mem.sort(u64, &bounded, {}, std.sort.asc(u64));
        const sequential_median = (sequential[4] + sequential[5]) / 2;
        const bounded_median = (bounded[4] + bounded[5]) / 2;
        const reduction = if (sequential_median == 0) 0 else (sequential_median -| bounded_median) * 100 / sequential_median;
        std.debug.print("PullRequest {d}: sequential={d}ms bounded={d}ms reduction={d}% connections={d} failures={d} rate-limited={d}\n", .{
            id, sequential_median, bounded_median, reduction, max_connections, failures, rate_limited,
        });
        if (reduction < 30 or max_connections > 2 or failures != 0 or rate_limited != 0) return error.AcquisitionGateFailed;
    }
}

fn runAcquisitionSample(
    init: std.process.Init,
    gpa: std.mem.Allocator,
    cred: bbr.bitbucket.Credential,
    id: u64,
    bounded: bool,
    failures: *usize,
    rate_limited: *usize,
    max_connections: *usize,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var transport = bbr.http.StdHttpClient.init(std.heap.page_allocator, init.io);
    defer transport.deinit();
    transport.enableConnectionCountTracking();
    try transport.initDefaultProxies(arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(transport.httpClient(), cred);
    const start = std.Io.Clock.awake.now(init.io);
    const loaded = if (bounded)
        session.loadWith(init.io, std.heap.page_allocator, bb, "pr-webapp", id)
    else
        session.loadSequentialWith(std.heap.page_allocator, bb, "pr-webapp", id);
    const candidate = loaded catch |err| {
        failures.* += 1;
        if (err == error.RateLimited) rate_limited.* += 1;
        return err;
    };
    defer candidate.destroy();
    max_connections.* = @max(max_connections.*, transport.maxConnectionCount());
    return @intCast(@divFloor(start.untilNow(init.io, .awake).toNanoseconds(), std.time.ns_per_ms));
}

fn checkMutationRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    if (!std.mem.eql(u8, init.environ_map.get("BBR_ALLOW_LIVE_MUTATION") orelse "", "1")) {
        std.debug.print("bbr: refusing destructive check without BBR_ALLOW_LIVE_MUTATION=1\n", .{});
        return;
    }
    const repo = it.next() orelse return usage();
    const pull_request_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();
    if (it.next() != null) return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);
    const author_uuid = try bb.getAuthenticatedAccountUuid(gpa);
    defer gpa.free(author_uuid);

    var nonce_bytes: [8]u8 = undefined;
    try init.io.randomSecure(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .native);
    const created_body = try std.fmt.allocPrint(gpa, "bbr-m16-live-check-{x}-created", .{nonce});
    defer gpa.free(created_body);
    const updated_body = try std.fmt.allocPrint(gpa, "bbr-m16-live-check-{x}-updated", .{nonce});
    defer gpa.free(updated_body);

    const comment_id = try bb.createComment(gpa, repo, pull_request_id, .{ .body = created_body, .scope = .review });
    var cleanup_needed = true;
    defer if (cleanup_needed) bb.deleteComment(gpa, repo, pull_request_id, comment_id) catch {};

    try verifyLiveComment(gpa, bb, repo, pull_request_id, comment_id, author_uuid, created_body);
    try bb.updateComment(gpa, repo, pull_request_id, comment_id, updated_body);
    try verifyLiveComment(gpa, bb, repo, pull_request_id, comment_id, author_uuid, updated_body);
    try bb.deleteComment(gpa, repo, pull_request_id, comment_id);
    cleanup_needed = false;
    try verifyLiveCommentDeleted(gpa, bb, repo, pull_request_id, comment_id, author_uuid);
    std.debug.print("ok: created, fetched, body-updated, and deleted disposable Comment #{d}\n", .{comment_id});
}

fn checkVerdictRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    if (!std.mem.eql(u8, init.environ_map.get("BBR_ALLOW_LIVE_MUTATION") orelse "", "1")) {
        std.debug.print("bbr: refusing destructive check without BBR_ALLOW_LIVE_MUTATION=1\n", .{});
        return;
    }
    const repo = it.next() orelse return usage();
    const pull_request_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();
    if (it.next() != null) return usage();

    var transport = bbr.http.StdHttpClient.init(gpa, init.io);
    defer transport.deinit();
    try transport.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(transport.httpClient(), cred);
    const account_uuid = try bb.getAuthenticatedAccountUuid(gpa);
    defer gpa.free(account_uuid);
    const initial_pull_request = try bb.getPullRequest(gpa, repo, pull_request_id);
    defer bbr.bitbucket.deinitPullRequest(gpa, initial_pull_request);
    if (std.mem.eql(u8, account_uuid, initial_pull_request.author_uuid)) return error.PullRequestAuthorCannotSetReviewerVerdict;

    const initial = initial_pull_request.reviewerVerdict(account_uuid);
    const target: bbr.bitbucket.ReviewerVerdict = if (initial == .approved) .changes_requested else .approved;
    var restored = false;
    defer if (!restored) {
        _ = restoreReviewerVerdict(gpa, bb, repo, pull_request_id, account_uuid, initial) catch {};
    };

    const changed = try bb.changeReviewerVerdict(gpa, repo, pull_request_id, initial_pull_request.source_commit, account_uuid, target);
    if (!verdictChangeSucceeded(changed)) return error.ReviewerVerdictChangeFailed;
    const restore_result = try restoreReviewerVerdict(gpa, bb, repo, pull_request_id, account_uuid, initial);
    if (!verdictChangeSucceeded(restore_result)) return error.ReviewerVerdictRestoreFailed;
    restored = true;
    std.debug.print("ok: changed Reviewer Verdict from {s} to {s} and restored it\n", .{ @tagName(initial), @tagName(target) });
}

fn restoreReviewerVerdict(
    gpa: std.mem.Allocator,
    bb: bbr.bitbucket.Client,
    repo: []const u8,
    pull_request_id: u64,
    account_uuid: []const u8,
    target: bbr.bitbucket.ReviewerVerdict,
) !bbr.bitbucket.ReviewerVerdictChangeResult {
    const current = try bb.getPullRequest(gpa, repo, pull_request_id);
    defer bbr.bitbucket.deinitPullRequest(gpa, current);
    return bb.changeReviewerVerdict(gpa, repo, pull_request_id, current.source_commit, account_uuid, target);
}

fn verdictChangeSucceeded(result: bbr.bitbucket.ReviewerVerdictChangeResult) bool {
    return switch (result) {
        .success, .reconciled_success => true,
        else => false,
    };
}

fn checkBlobsRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const pull_request_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();
    const fixture_classes = [_][]const u8{ "text", "empty", "binary", "path-special", "executable", "link" };
    var checked: [fixture_classes.len]bool = @splat(false);

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);
    const pull_request = try bb.getPullRequest(gpa, repo, pull_request_id);
    defer bbr.bitbucket.deinitPullRequest(gpa, pull_request);

    while (it.next()) |class| {
        const side = it.next() orelse return usage();
        const path = it.next() orelse return usage();
        const expected_attributes = it.next() orelse return usage();
        const class_index = for (fixture_classes, 0..) |known, index| {
            if (std.mem.eql(u8, known, class)) break index;
        } else return error.UnknownBlobFixtureClass;
        if (checked[class_index]) return error.DuplicateBlobFixtureClass;
        checked[class_index] = true;

        const commit = if (std.mem.eql(u8, side, "old"))
            pull_request.destination_commit
        else if (std.mem.eql(u8, side, "new"))
            pull_request.source_commit
        else
            return error.InvalidBlobFixtureSide;
        var attributes: std.ArrayList([]const u8) = .empty;
        defer attributes.deinit(gpa);
        if (!std.mem.eql(u8, expected_attributes, "-")) {
            var values = std.mem.splitScalar(u8, expected_attributes, ',');
            while (values.next()) |attribute| {
                if (attribute.len == 0) return error.InvalidBlobFixtureAttributes;
                try attributes.append(gpa, attribute);
            }
        }
        const raw_len = try bb.checkFileBlob(gpa, repo, commit, path, attributes.items);
        if (std.mem.eql(u8, class, "empty") and raw_len != 0) return error.BlobExpectedEmpty;
        std.debug.print("ok: {s} {s} {s} commit={s} type=commit_file size={d} attributes={s} raw={d}\n", .{
            class, side, path, commit, raw_len, expected_attributes, raw_len,
        });
    }

    for (fixture_classes, checked) |class, present| {
        if (!present) std.debug.print("skipped: blob fixture class {s} was not supplied\n", .{class});
    }
}

fn verifyLiveComment(
    gpa: std.mem.Allocator,
    client: bbr.bitbucket.Client,
    repo: []const u8,
    pull_request_id: u64,
    comment_id: bbr.review.CommentId,
    author_uuid: []const u8,
    expected_body: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const comments = try client.getComments(arena.allocator(), repo, pull_request_id, .{});
    for (comments) |comment| {
        if (comment.id != comment_id) continue;
        if (comment.deleted or !std.mem.eql(u8, comment.body, expected_body)) return error.LiveMutationBodyMismatch;
        if (comment.author_uuid == null or !std.mem.eql(u8, comment.author_uuid.?, author_uuid)) return error.LiveMutationAuthorMismatch;
        if (comment.parent_id != null or comment.scope == null or comment.scope.? != .review) return error.LiveMutationScopeMismatch;
        return;
    }
    return error.LiveMutationCommentMissing;
}

fn verifyLiveCommentDeleted(
    gpa: std.mem.Allocator,
    client: bbr.bitbucket.Client,
    repo: []const u8,
    pull_request_id: u64,
    comment_id: bbr.review.CommentId,
    author_uuid: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const comments = try client.getComments(arena.allocator(), repo, pull_request_id, .{});
    for (comments) |comment| {
        if (comment.id != comment_id) continue;
        if (!comment.deleted) return error.LiveMutationDeleteFailed;
        if (comment.author_uuid == null or !std.mem.eql(u8, comment.author_uuid.?, author_uuid)) return error.LiveMutationAuthorMismatch;
        if (comment.parent_id != null or comment.scope == null or comment.scope.? != .review) return error.LiveMutationScopeMismatch;
    }
}

/// `detect [<repo>]`: run startup resolution and print the outcome, no TUI. A
/// scriptable way to verify the GitClient + list pipeline against live data.
fn detectRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var input: bbr.startup.Input = .{};
    if (it.next()) |repo| input = .{ .repo_slug = repo };

    var git = bbr.git.ShellGitClient.init(gpa, init.io);

    // Report what the GitClient sees, so a failed detect is diagnosable.
    if (git.gitClient().currentBranch(a)) |b| {
        std.debug.print("branch: {s}\n", .{b});
    } else |err| std.debug.print("branch: <{s}>\n", .{@errorName(err)});
    if (git.gitClient().remote(a)) |r| {
        std.debug.print("remote: {s}/{s}\n", .{ r.workspace, r.repo_slug });
    } else |err| std.debug.print("remote: <{s}>\n", .{@errorName(err)});

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(a, init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const entry = try bbr.startup.resolve(a, git.gitClient(), bb, input);
    switch (entry) {
        .open => |t| std.debug.print("resolved: open {s} #{d}\n", .{ t.repo_slug, t.id }),
        .pick => |p| {
            std.debug.print("resolved: pick {s} ({s}, {d} PRs)\n", .{
                p.repo_slug, if (p.prefiltered) "branch-filtered" else "all open", p.prs.len,
            });
            for (p.prs, 0..) |pr, i| {
                if (i == 10) {
                    std.debug.print("  … and {d} more\n", .{p.prs.len - 10});
                    break;
                }
                std.debug.print("  #{d} {s} ({s} → {s})\n", .{ pr.id, pr.title, pr.source_branch, pr.destination_branch });
            }
        },
        .empty => |repo| std.debug.print("resolved: no open PRs in {s}\n", .{repo}),
    }
}

/// Read one interactive line: print the prompt, read through newline, trim
/// whitespace. Returns an owned copy; `error.LoginAborted` on EOF, and
/// `error.EmptyInput` when the line is blank (the caller re-prompts).
/// `stdin` is one reader held for the whole login so piped input is not lost
/// between prompts (each reader buffers its fill).
fn promptInput(gpa: std.mem.Allocator, io: std.Io, stdin: *std.Io.Reader, prompt: []const u8, hide_input: bool) ![]u8 {
    const fd = std.Io.File.stdin().handle;
    const original: ?std.posix.termios = if (hide_input) std.posix.tcgetattr(fd) catch |err| switch (err) {
        error.NotATerminal => null,
        else => return err,
    } else null;
    if (original) |term| {
        var hidden = term;
        hidden.lflag.ECHO = false;
        hidden.lflag.ECHONL = false;
        try std.posix.tcsetattr(fd, .NOW, hidden);
    }
    defer if (original) |term| std.posix.tcsetattr(fd, .NOW, term) catch {};

    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &output_buffer);
    try stdout.interface.writeAll(prompt);
    try stdout.interface.flush();
    defer if (original != null) {
        stdout.interface.writeAll("\n") catch {};
        stdout.interface.flush() catch {};
    };
    const line = (try stdin.takeDelimiter('\n')) orelse return error.LoginAborted;
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return error.EmptyInput;
    if (trimmed.len > 1024) return error.InputTooLong;
    return gpa.dupe(u8, trimmed);
}

/// Prompt up to three times for a non-empty value.
fn promptField(gpa: std.mem.Allocator, io: std.Io, stdin: *std.Io.Reader, prompt: []const u8, hide_input: bool) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 3) : (attempts += 1) {
        return promptInput(gpa, io, stdin, prompt, hide_input) catch |err| switch (err) {
            error.EmptyInput => continue,
            else => return err,
        };
    }
    return error.LoginAborted;
}

fn warnEnvOverride(env_map: *std.process.Environ.Map) void {
    const auth = bbr.bitbucket.auth;
    if (auth.credentialEnvValue(env_map, "BITBUCKET_USERNAME") != null or
        auth.credentialEnvValue(env_map, "BITBUCKET_TOKEN") != null or
        auth.credentialEnvValue(env_map, "BITBUCKET_WORKSPACE") != null)
    {
        std.debug.print("note: BITBUCKET_* environment variables override the file\n", .{});
    }
}

/// `bbr login [profile]`: prompt for Email, Token, Workspace, verify live
/// against Bitbucket, then save the profile and select it as active.
fn loginRun(init: std.process.Init, gpa: std.mem.Allocator, rest: *ArgSlice, flag_profile: ?[]const u8) !void {
    const auth = bbr.bitbucket.auth;
    const positional = rest.next();
    if (rest.next() != null) return usage();
    if (positional) |p| {
        if (!auth.isValidProfileName(p)) {
            std.debug.print("bbr: invalid profile name '{s}'\n", .{p});
            return;
        }
    }
    if (positional != null and flag_profile != null and !std.mem.eql(u8, positional.?, flag_profile.?)) {
        std.debug.print("bbr: profile given twice (`{s}` vs `--profile {s}`); use one\n", .{ positional.?, flag_profile.? });
        return;
    }
    const profile_name = auth.selectedProfileName(gpa, init.environ_map, null, positional orelse flag_profile) catch |err| {
        std.debug.print("bbr: could not select profile: {s}\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(profile_name);

    const auth_path = (try auth.authFilePath(gpa, init.environ_map)) orelse {
        std.debug.print("bbr: cannot save credentials: set XDG_DATA_HOME or HOME\n", .{});
        return;
    };
    defer gpa.free(auth_path);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const email = promptField(gpa, init.io, &stdin.interface, "Email: ", false) catch |err| {
        std.debug.print("bbr: login aborted ({s})\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(email);
    const token = promptField(gpa, init.io, &stdin.interface, "Token: ", true) catch |err| {
        std.debug.print("bbr: login aborted ({s})\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(token);
    const workspace = promptField(gpa, init.io, &stdin.interface, "Workspace: ", false) catch |err| {
        std.debug.print("bbr: login aborted ({s})\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(workspace);

    const candidate: bbr.bitbucket.Credential = .{ .username = email, .token = token, .workspace = workspace };
    var http_client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer http_client.deinit();
    try http_client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(http_client.httpClient(), candidate);

    const uuid = bb.getAuthenticatedAccountUuid(gpa) catch |err| {
        if (err == error.Unauthorized) std.debug.print("bbr: login failed: bad email/token (401); nothing saved\n", .{}) else std.debug.print("bbr: login failed: {s}; nothing saved\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(uuid);
    bb.checkWorkspace(gpa, workspace) catch |err| {
        if (err == error.NotFound) {
            std.debug.print("bbr: login failed: workspace not found or not visible; nothing saved\n", .{});
        } else {
            std.debug.print("bbr: login failed: {s}; nothing saved\n", .{@errorName(err)});
        }
        return;
    };

    const path = auth.upsertProfile(gpa, init.io, init.environ_map, profile_name, candidate) catch |err| {
        std.debug.print("bbr: could not save credentials: {s}\n", .{@errorName(err)});
        if (err == error.InvalidAuthFile) return;
        return err;
    };
    defer gpa.free(path);
    std.debug.print("Logged in as '{s}'. Saved to {s}.\n", .{ profile_name, path });
    warnEnvOverride(init.environ_map);
}

/// `bbr logout [profile]` removes one profile; `bbr logout --all` deletes the
/// whole file. Bare `bbr logout` removes the selected Profile. Missing files or
/// profiles exit quietly with "already logged out".
fn logoutRun(init: std.process.Init, gpa: std.mem.Allocator, rest: *ArgSlice, flag_profile: ?[]const u8) !void {
    const auth = bbr.bitbucket.auth;
    var positional: ?[]const u8 = null;
    var want_all = false;
    while (rest.next()) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            want_all = true;
        } else if (positional == null) {
            positional = a;
        } else {
            return usage();
        }
    }
    if (positional) |p| {
        if (!auth.isValidProfileName(p)) {
            std.debug.print("bbr: invalid profile name '{s}'\n", .{p});
            return;
        }
    }
    if (!want_all and positional != null and flag_profile != null and !std.mem.eql(u8, positional.?, flag_profile.?)) {
        std.debug.print("bbr: profile given twice (`{s}` vs `--profile {s}`); use one\n", .{ positional.?, flag_profile.? });
        return;
    }

    if (want_all) {
        if (try auth.deleteAuthFile(gpa, init.io, init.environ_map)) {
            std.debug.print("Logged out (all profiles removed).\n", .{});
        } else {
            std.debug.print("Already logged out.\n", .{});
        }
        warnEnvOverride(init.environ_map);
        return;
    }

    var loaded = auth.load(gpa, init.io, init.environ_map) catch |err| switch (err) {
        error.InvalidAuthFile => return,
        else => return err,
    };
    defer if (loaded) |*l| l.deinit(gpa);
    const file_active: ?[]const u8 = if (loaded) |*l| l.file.active_profile else null;
    const name = auth.selectedProfileName(gpa, init.environ_map, file_active, positional orelse flag_profile) catch |err| {
        std.debug.print("bbr: could not select profile: {s}\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(name);
    const removed = auth.removeProfile(gpa, init.io, init.environ_map, name) catch |err| switch (err) {
        error.InvalidAuthFile => return,
        else => return err,
    };
    if (removed) {
        std.debug.print("Logged out '{s}'.\n", .{name});
    } else {
        std.debug.print("Already logged out (no credentials for '{s}').\n", .{name});
    }
    warnEnvOverride(init.environ_map);
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  bbr                              auto-detect the PR for the current branch
        \\  bbr [--profile <name>] <pr-url>  open a pasted Bitbucket PR URL
        \\  bbr [--profile <name>] <repo-slug>  detect the current branch's PR in <repo>
        \\  bbr [--profile <name>] <repo-slug> <pr-id>  open a specific PR in the TUI
        \\  bbr login [profile]              save Bitbucket credentials (prompts for Email, Token, Workspace)
        \\  bbr logout [profile|--all]       remove saved credentials
        \\  bbr local [base-ref] [source-ref] review committed local Git changes
        \\  bbr check <repo-slug> <pr-id>    live smoke check (fetch + print, no TUI)
        \\  bbr check-blobs <repo> <pr-id> [<class> <old|new> <path> <attrs|->]...
        \\  bbr check-acquisition             opt-in Candidate Session acquisition gate
        \\  bbr check-mutation <repo> <pr-id> destructive live Comment lifecycle check
        \\  bbr check-verdict <repo> <pr-id>  destructive live Reviewer Verdict check
        \\  bbr external-edit-smoke          interactive PTY External Edit check
        \\  bbr demo                         open the TUI with synthetic data (no network)
        \\  bbr grammar <command> ...        manage trusted local UserGrammars
        \\  bbr api [--workspace SLUG] [--json] VERB [options]
        \\  bbr api --help                   list all verbs (no credentials needed)
        \\  bbr api VERB --help              options for one verb
        \\  bbr completion (bash|zsh|fish)   print a shell completion script (no credentials needed)
        \\  bbr completion --list-profiles   saved Profile names, one per line (for completion scripts)
        \\
        \\Credentials come from `$XDG_DATA_HOME/bbr/auth.toml` (see `bbr login`).
        \\`--profile <name>` (or BBR_PROFILE) selects a saved profile.
        \\BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE override the file per field.
        \\
    , .{});
}

/// First line of a string (up to the first newline). Borrows the input.
fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s[0..nl] else s;
}

/// A synthetic diff exercising every comment render path — no credentials, no
/// network. Line numbering matters: comments anchor to new lines that exist.
const demo_diff =
    \\diff --git a/src/server.zig b/src/server.zig
    \\--- a/src/server.zig
    \\+++ b/src/server.zig
    \\@@ -10,4 +10,4 @@ pub fn listen() !void {
    \\     const port = 8080;
    \\-    const timeout = 30;
    \\+    const timeout = 60;
    \\     try bind(port);
    \\     log("listening");
    \\diff --git a/README.md b/README.md
    \\--- a/README.md
    \\+++ b/README.md
    \\@@ -1,2 +1,2 @@
    \\-# webapp
    \\+# pr-webapp
    \\ A small demo service.
    \\
;

/// Run the TUI against `demo_diff` and a hand-built set of threads covering:
/// a PR-level comment, an inline root + reply, a suggestion, a resolved thread
/// (hidden until `R`), and an outdated thread (in the per-file section). The
/// Picker is disabled (`online = false`): there is no repo to list.
fn demoRun(io: std.Io, gpa: std.mem.Allocator, env_map: *std.process.Environ.Map, configuration: *const config.Configuration) !void {
    // Build the session on the page allocator so app.run can destroy it uniformly.
    const s = try session.create(std.heap.page_allocator);
    const a = s.arena.allocator();

    s.diff = try bbr.diff.parse(a, demo_diff);
    try s.initializeEnrichment();

    const path = "src/server.zig";
    const comments = try a.dupe(bbr.review.Comment, &.{
        .{ .id = 1, .author = "Reviewer", .body = "Thanks — one question and a nit below." },
        .{ .id = 2, .author = "Reviewer", .body = "Why 60 specifically? A named const would read better.", .anchor = .{ .path = path, .to = 11 } },
        .{ .id = 3, .parent_id = 2, .author = "Author", .body = "Fair — see suggestion." },
        .{ .id = 4, .parent_id = 2, .author = "Author", .body = "```suggestion\n    const timeout_s = 60;\n```" },
        .{ .id = 5, .author = "Reviewer", .body = "spacing here is off", .resolved = true, .anchor = .{ .path = path, .to = 13 } },
        .{ .id = 6, .parent_id = 5, .author = "Author", .body = "fixed, thanks" },
        .{ .id = 7, .author = "Reviewer", .body = "this note pointed at code that no longer exists", .state = .outdated, .anchor = .{ .path = path, .from = 99 } },
    });
    s.threads = try bbr.review.buildThreads(a, comments);

    const pr: bbr.bitbucket.PullRequest = .{
        .id = 1799,
        .title = "Demo: raise handler timeout",
        .state = "OPEN",
        .author_display_name = "Author",
        .source_branch = "feature/timeout",
        .destination_branch = "main",
        .source_commit = "democ0ffee",
        .destination_commit = "demodeadbeef",
    };
    s.source = .{ .remote = pr };
    s.header = .{
        .title = pr.title,
        .source_ref = pr.source_branch,
        .base_ref = pr.destination_branch,
        .source_commit = pr.source_commit,
        .base_commit = pr.destination_commit,
        .author = pr.author_display_name,
        .locator = "demo",
        .source_label = "Demo",
        .pull_request_id = pr.id,
    };

    // Ephemeral in-memory store: the demo authors drafts but persists nothing.
    var store = persist.SqliteStore.open(":memory:") catch @panic("sqlite :memory: open failed");
    defer store.deinit();
    var plain_highlighter: bbr.highlight.PlainHighlighter = .{};
    try app.run(.{
        .io = io,
        .gpa = gpa,
        .env_map = env_map,
        .repo = "",
        .store = store.store(),
        .active_theme = configuration.active_theme,
        .keymap = configuration.keymap.keymap(),
        .highlighter = plain_highlighter.highlighter(),
        .highlight_max_file_bytes = configuration.highlight_max_file_bytes,
        .file_cache_enabled = configuration.file_cache_enabled,
        .inactive_file_cache_max_bytes = configuration.inactive_file_cache_max_bytes,
        .comments_collapsed_rows = configuration.comments_collapsed_rows,
        .mouse_enabled = configuration.mouse_enabled,
        .mouse_vertical_scroll_rows = configuration.mouse_vertical_scroll_rows,
        .external_edit_max_bytes = configuration.external_edit_max_bytes,
        .online = false,
    }, s, try presentation.OwnedReviewIdentity.init("", "", pr.id));
}

// Test discovery only follows `_ = @import(...)` chains rooted in the *test
// root* file's test blocks. This block roots the exe module's TUI test tree
// (app → render → theme → nav → picker → session); the core `bbr` module's
// tests run via src/root.zig.
test {
    _ = @import("api/cli.zig");
    _ = @import("api/args.zig");
    _ = @import("api/workspaces.zig");
    _ = @import("api/repositories.zig");
    _ = @import("api/pullrequests.zig");
    _ = @import("api/comments.zig");
    _ = @import("api/tasks.zig");
    _ = @import("api/files.zig");
    _ = @import("api/commits.zig");
    _ = @import("highlight/tree_sitter_highlighter.zig");
    _ = @import("highlight/query_regex.zig");
    _ = @import("highlight/user_grammar.zig");
    _ = @import("highlight/grammar_cli.zig");
    _ = @import("tui/app.zig");
    _ = @import("tui/config.zig");
    _ = @import("tui/review_body.zig");
    _ = @import("tui/review_card.zig");
    _ = @import("tui/search.zig");
    _ = @import("persist/sqlite_store.zig");
}

test "File Enrichment OOM has a distinct fatal message" {
    try std.testing.expectEqualStrings(
        "bbr: file enrichment ran out of memory; the review was not modified",
        tuiFatalMessage(error.FileEnrichmentOutOfMemory).?,
    );
    try std.testing.expect(tuiFatalMessage(error.NotFound) == null);
}

test "login reader trims lines and preserves empty input and EOF errors" {
    const testing = std.testing;
    var reader = std.Io.Reader.fixed(" \t first \r\n \t\r\nsecond");
    const first = try promptInput(testing.allocator, testing.io, &reader, "", false);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first", first);
    try testing.expectError(error.EmptyInput, promptInput(testing.allocator, testing.io, &reader, "", false));
    const second = try promptInput(testing.allocator, testing.io, &reader, "", false);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("second", second);
    try testing.expectError(error.LoginAborted, promptInput(testing.allocator, testing.io, &reader, "", false));
}

test "login field retries blank lines at most three times" {
    const testing = std.testing;
    var reader = std.Io.Reader.fixed("\n \r\n value \n\n\n\nignored\n");
    const value = try promptField(testing.allocator, testing.io, &reader, "", false);
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("value", value);
    try testing.expectError(error.LoginAborted, promptField(testing.allocator, testing.io, &reader, "", false));
    const remaining = try promptInput(testing.allocator, testing.io, &reader, "", false);
    defer testing.allocator.free(remaining);
    try testing.expectEqualStrings("ignored", remaining);
}

test "login reader rejects input longer than 1024 bytes" {
    var input: [1026]u8 = undefined;
    @memset(&input, 'x');
    input[input.len - 1] = '\n';
    var reader = std.Io.Reader.fixed(&input);
    try std.testing.expectError(error.InputTooLong, promptInput(std.testing.allocator, std.testing.io, &reader, "", false));
}

// The demo is our offline validation surface, so guard that its synthetic data
// actually weaves as intended: anchors land on real lines, the suggestion is
// detected, resolved threads hide, and the outdated one groups per file.
test "demo data weaves through the real pipeline" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try bbr.diff.parse(a, demo_diff);
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Reviewer", .body = "PR-level note." },
        .{ .id = 2, .author = "Reviewer", .body = "Why 60?", .anchor = .{ .path = "src/server.zig", .to = 11 } },
        .{ .id = 4, .parent_id = 2, .author = "Author", .body = "```suggestion\n    const timeout_s = 60;\n```" },
        .{ .id = 5, .author = "Reviewer", .body = "nit", .resolved = true, .anchor = .{ .path = "src/server.zig", .to = 13 } },
        .{ .id = 7, .author = "Reviewer", .body = "stale", .state = .outdated, .anchor = .{ .path = "src/server.zig", .from = 99 } },
    };
    const threads = try bbr.review.buildThreads(a, &comments);

    // The inline suggestion is detected on comment #4.
    try testing.expect(comments[2].suggestion() != null);

    // Collapsed disclosures contribute no content rows.
    const hidden = try buffer_mod.buildWithComments(a, diff, .unified, threads, .{});
    var hidden_comments: usize = 0;
    var outdated_sections: usize = 0;
    for (hidden.rows) |r| {
        // A multi-line body emits one row per visual line (M11); count the
        // header (`is_first`) rows to tally distinct comments woven.
        if (r == .comment and r.comment.part == .header) hidden_comments += 1;
        if (r == .disclosure and r.disclosure.kind == .outdated) outdated_sections += 1;
    }
    // PR-level (#1) + inline root (#2) + suggestion reply (#4); both hidden
    // groups remain represented by their disclosure rows.
    try testing.expectEqual(@as(usize, 3), hidden_comments);
    try testing.expectEqual(@as(usize, 1), outdated_sections);

    // Revealed: the resolved thread's root now appears too.
    const shown = try buffer_mod.buildWithComments(a, diff, .unified, threads, .{ .expanded_disclosures = &.{
        .{ .resolved_thread = 5 },
        .{ .outdated_file = &diff.files[0] },
    } });
    var shown_comments: usize = 0;
    for (shown.rows) |r| {
        if (r == .comment and r.comment.part == .header) shown_comments += 1;
    }
    try testing.expectEqual(@as(usize, 5), shown_comments);
}

test {
    _ = @import("tui/presentation.zig");
    _ = @import("tui/selected_version_hardening_test.zig");
}
