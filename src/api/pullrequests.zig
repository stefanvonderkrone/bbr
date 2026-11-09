//! PullRequest reads, creation, updates, decline, and Reviewer Verdict commands.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");
const repositories = @import("repositories.zig");

pub const list_help =
    \\usage: bbr api list-pull-requests --repository SLUG [--state OPEN|MERGED|DECLINED|SUPERSEDED] [--source-branch NAME]
    \\      [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--concurrency N] [--limit N] [--json]
    \\
    \\List pull requests (GET .../pullrequests).
    \\--state ignores letter case. The default is OPEN.
    \\
++ ws.pagingHelp(bbr.bitbucket.max_pagelen.pull_requests, ws.default_concurrency);

pub const workspace_list_help =
    \\usage: bbr api list-workspace-pull-requests --author UUID [--reviewer UUID]
    \\      [--state OPEN|MERGED|DECLINED|SUPERSEDED ...] [--query Q] [--concurrency N] [--limit N] [--json]
    \\   or: bbr api list-workspace-pull-requests (--author UUID | --reviewer UUID | --author UUID --reviewer UUID)
    \\      --repository SLUG ... [--state OPEN|MERGED|DECLINED|SUPERSEDED ...] [--query Q]
    \\      [--concurrency N] [--limit N] [--json]
    \\
    \\List PullRequests in the selected Workspace that one account authored or reviews.
    \\--author and --reviewer take account UUIDs.
    \\Without --repository, --author is required. The command reads the Workspace author endpoint,
    \\and --reviewer filters its results. Rows keep the Bitbucket order, and paging stops at --limit.
    \\Bitbucket has no reviewer endpoint, so a scan with only --reviewer needs --repository.
    \\Repeat --repository to name each Repository to scan. Supply --author, --reviewer, or both.
    \\Rows follow the given Repository order, then the Bitbucket order in each Repository.
    \\A repeated Repository is scanned once.
    \\Repeat --state to select several states. --state ignores letter case. The default is OPEN.
    \\--query is a Bitbucket q expression. The command joins it to its own filter with AND.
++ ws.concurrencyHelp(ws.default_concurrency) ++
    \\--limit caps the total. A failed request fails the complete list, unless all its rows
    \\come after the first --limit rows. HTTP 429 is not retried.
    \\
;

pub const get_help =
    \\usage: bbr api get-pull-request --repository SLUG --pull-request-id N [--json]
    \\
;

const mutation_options =
    \\      [--destination-branch NAME]
    \\      [--description TEXT | --description-file PATH] [--reviewer UUID ... | --clear-reviewers]
    \\      [--default-reviewers [--effective]] [--draft true|false] [--close-source-branch true|false] [--json]
    \\
    \\--reviewer replaces the reviewer list. --clear-reviewers sends an empty list.
    \\Bitbucket adds no Default Reviewers through the API. --default-reviewers sends the Repository's
    \\Default Reviewers plus the --reviewer values and leaves out the PullRequest Author.
    \\It prints a warning on stderr when a --reviewer value names the Author.
    \\--effective uses the Effective Default Reviewers, which add the Default Reviewers of the Project.
    \\On update, --default-reviewers replaces the reviewer list.
    \\Without a reviewer flag, create sends no reviewers and update leaves them unchanged.
    \\Description files must not exceed 1 MiB. Flags can appear in any order.
    \\
;

pub const create_help =
    \\usage: bbr api create-pull-request --repository SLUG --title TEXT --source-branch NAME
    \\      [--source-repository WORKSPACE/SLUG]
    \\
++ mutation_options ++
    \\--source-repository selects a fork source. The request Repository is the destination.
    \\Create a ready PullRequest by default. Use --draft true to create a Draft PullRequest.
    \\An omitted destination branch uses the Repository's main branch.
    \\
;

pub const update_help =
    \\usage: bbr api update-pull-request --repository SLUG --pull-request-id N
    \\      [--title TEXT] [--source-branch NAME]
    \\
++ mutation_options ++
    \\Update an open PullRequest. Supply at least one change.
    \\--draft false makes a Draft PullRequest ready. --draft true makes it a draft.
    \\Omitted fields stay unchanged. An empty description clears the description.
    \\
;

pub const decline_help =
    \\usage: bbr api decline-pull-request --repository SLUG --pull-request-id N [--json]
    \\
    \\Close a PullRequest without merging. This does not set a Reviewer Verdict.
    \\
;

pub const commit_list_help =
    \\usage: bbr api list-commit-pull-requests --repository SLUG --commit HASH [--pagelen N] [--page N] [--no-follow] [--limit N] [--json]
    \\
    \\List PullRequests where Bitbucket reviewed this commit, including closed PullRequests.
    \\Follow pages by default. --no-follow returns one page. --limit caps the total.
    \\Pending link indexing fails with a hint. This command does not poll.
    \\The Pull Request Commit Links app must exist. Bitbucket installs it when someone
    \\selects 'Go to pull request' on a commit's details page.
    \\
++ ws.pagelenHelp(bbr.bitbucket.max_pagelen.commit_pull_requests);

pub const whoami_help =
    \\usage: bbr api whoami [--json]
    \\
    \\Print the authenticated account UUID (GET /user).
    \\
;

pub const get_verdict_help =
    \\usage: bbr api get-verdict --repository SLUG --pull-request-id N [--uuid UUID] [--json]
    \\
    \\Show the review verdict for one account (defaults to the authenticated account).
    \\
;

pub const set_verdict_help =
    \\usage: bbr api set-verdict --repository SLUG --pull-request-id N --verdict approved|changes_requested|none|no_verdict --expected-source-commit HASH [--json]
    \\
    \\Set the reviewer verdict for the authenticated account only.
    \\
;

fn parseState(text: []const u8) !bbr.bitbucket.PullRequestState {
    for (std.enums.values(bbr.bitbucket.PullRequestState)) |state| {
        if (std.ascii.eqlIgnoreCase(@tagName(state), text)) return state;
    }
    return error.BadRequest;
}

const ListArgs = struct {
    repository: []const u8,
    filter: bbr.bitbucket.ListOptions,
    page: bbr.bitbucket.PageOptions,
    concurrency: usize,
};

fn parseList(args: []const []const u8) !ListArgs {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var filter: bbr.bitbucket.ListOptions = .{};
    var page: bbr.bitbucket.PageOptions = .{};
    var concurrency: ?usize = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (try ws.takePageFlag(&cur, f, &page, bbr.bitbucket.max_pagelen.pull_requests)) continue;
        if (std.mem.eql(u8, f.name, "concurrency")) {
            _ = cur.next();
            try ws.takeConcurrency(&cur, f, &concurrency);
        } else if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "state")) {
            _ = cur.next();
            filter.state = try parseState(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "source-branch")) {
            _ = cur.next();
            filter.source_branch = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    return .{
        .repository = repository orelse return error.MissingRequired,
        .filter = filter,
        .page = page,
        .concurrency = concurrency orelse ws.default_concurrency,
    };
}

fn listPullRequests(allocator: std.mem.Allocator, io: std.Io, bb: bbr.bitbucket.Client, args: []const []const u8) ![]bbr.bitbucket.PullRequestSummary {
    const parsed = try parseList(args);
    return bb.listPullRequestsPage(io, allocator, parsed.repository, parsed.filter, parsed.page, ws.effectiveConcurrency(parsed.concurrency, std.Thread.getCpuCount()));
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const items = try listPullRequests(arena.allocator(), init.io, bb, args);
    try printSummaries(init, items, json);
}

fn printSummaries(init: std.process.Init, items: []const bbr.bitbucket.PullRequestSummary, json: bool) !void {
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |pr| try out.printLine(init, "#{d} [{s}{s}] {s} ({s} -> {s})", .{
            pr.id, pr.state, if (pr.draft) " draft" else "", pr.title, pr.source_branch, pr.destination_branch,
        });
        try out.printLine(init, "ok: {d} pull request(s)", .{items.len});
    }
}

const WorkspaceListArgs = struct {
    filter: bbr.bitbucket.WorkspacePullRequestFilter,
    options: bbr.bitbucket.WorkspacePullRequestOptions,
};

/// The returned Repository slugs are owned by `allocator`.
fn parseWorkspaceList(allocator: std.mem.Allocator, args: []const []const u8) !WorkspaceListArgs {
    var cur: arg.Cursor = .{ .args = args };
    var author: ?[]const u8 = null;
    var reviewer: ?[]const u8 = null;
    var slugs: std.ArrayList([]const u8) = .empty;
    errdefer slugs.deinit(allocator);
    var states: std.EnumSet(bbr.bitbucket.PullRequestState) = .empty;
    var query: ?[]const u8 = null;
    var limit: ?usize = null;
    var concurrency: ?usize = null;
    while (cur.next()) |text| {
        const f = arg.splitFlag(text) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "author")) {
            try arg.setOption([]const u8, &author, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "reviewer")) {
            try arg.setOption([]const u8, &reviewer, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "repository")) {
            const slug = try arg.takeValue(&cur, f);
            if (slug.len == 0) return error.BadRequest;
            for (slugs.items) |seen| {
                if (std.mem.eql(u8, seen, slug)) break;
            } else try slugs.append(allocator, slug);
        } else if (std.mem.eql(u8, f.name, "state")) {
            states.insert(try parseState(try arg.takeValue(&cur, f)));
        } else if (std.mem.eql(u8, f.name, "query")) {
            try arg.setOption([]const u8, &query, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "limit")) {
            try arg.setOption(usize, &limit, try arg.parseUsize(try arg.takeValue(&cur, f)));
        } else if (std.mem.eql(u8, f.name, "concurrency")) {
            try ws.takeConcurrency(&cur, f, &concurrency);
        } else return error.UnknownFlag;
    }
    for ([_]?[]const u8{ author, reviewer, query }) |value| if (value) |text| if (text.len == 0) return error.BadRequest;
    const scope: bbr.bitbucket.PullRequestScope = if (slugs.items.len == 0)
        .{ .workspace_author = .{ .author = author orelse return error.MissingRequired, .reviewer = reviewer } }
    else blk: {
        const party: bbr.bitbucket.PullRequestParty = if (author) |author_uuid|
            if (reviewer) |reviewer_uuid| .{ .author_and_reviewer = .{ .author = author_uuid, .reviewer = reviewer_uuid } } else .{ .author = author_uuid }
        else
            .{ .reviewer = reviewer orelse return error.MissingRequired };
        break :blk .{ .repositories = .{ .slugs = try slugs.toOwnedSlice(allocator), .party = party } };
    };
    return .{
        .filter = .{ .scope = scope, .states = if (states.count() == 0) .initOne(.OPEN) else states, .query = query },
        .options = .{ .limit = limit, .concurrency = concurrency orelse ws.default_concurrency },
    };
}

fn listWorkspacePullRequests(allocator: std.mem.Allocator, io: std.Io, bb: bbr.bitbucket.Client, args: []const []const u8) ![]bbr.bitbucket.PullRequestSummary {
    var parsed = try parseWorkspaceList(allocator, args);
    defer if (parsed.filter.scope == .repositories) allocator.free(parsed.filter.scope.repositories.slugs);
    parsed.options.concurrency = ws.effectiveConcurrency(parsed.options.concurrency, std.Thread.getCpuCount());
    return bb.listWorkspacePullRequests(io, allocator, parsed.filter, parsed.options);
}

pub fn runListWorkspace(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const items = try listWorkspacePullRequests(arena.allocator(), init.io, bb, args);
    if (json) return out.printJson(init, items);
    for (items) |pr| try out.printLine(init, "{s}#{d} [{s}{s}] {s} ({s} -> {s})", .{
        pr.destination_repository, pr.id, pr.state, if (pr.draft) " draft" else "", pr.title, pr.source_branch, pr.destination_branch,
    });
    try out.printLine(init, "ok: {d} pull request(s)", .{items.len});
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const id = pr_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const pr = try bb.getPullRequest(arena.allocator(), repo, id);
    try printPullRequest(init, pr, json);
}

fn printPullRequest(init: std.process.Init, pr: bbr.bitbucket.PullRequest, json: bool) !void {
    if (json) {
        try out.printJson(init, pr);
    } else {
        try out.printLine(init, "#{d} [{s}] {s}", .{ pr.id, pr.state, pr.title });
        try out.printLine(init, "draft: {}", .{pr.draft});
        if (pr.url.len != 0) try out.printLine(init, "url: {s}", .{pr.url});
        try out.printLine(init, "author: {s}", .{pr.author_display_name});
        try out.printLine(init, "author uuid: {s}", .{pr.author_uuid});
        try out.printLine(init, "{s} -> {s}", .{ pr.source_branch, pr.destination_branch });
        try out.printLine(init, "source: {s} destination: {s}", .{ pr.source_commit, pr.destination_commit });
        if (pr.source_repository.len != 0) try out.printLine(init, "source repository: {s}", .{pr.source_repository});
        if (pr.destination_repository.len != 0) try out.printLine(init, "destination repository: {s}", .{pr.destination_repository});
        try out.printLine(init, "close source branch: {}", .{pr.close_source_branch});
        try out.printLine(init, "description: {s}", .{pr.description});
        if (pr.reviewers) |reviewers| {
            try out.printLine(init, "reviewers: {d}", .{reviewers.len});
            for (reviewers) |reviewer| try out.printLine(init, "  {s}: {s}", .{ reviewer.uuid, reviewer.display_name });
        }
        if (pr.reviewer_verdicts) |verdicts| {
            try out.printLine(init, "reviewer verdicts: {d}", .{verdicts.len});
            for (verdicts) |entry| {
                try out.printLine(init, "  {s}: {s}", .{ entry.account_uuid, @tagName(entry.verdict) });
            }
        }
    }
}

/// `--default-reviewers`, with `--effective` and the `--reviewer` values to add.
const DefaultReviewerFlags = struct { effective: bool, add: []const []const u8 };

/// The reviewer flags of a create or update. The parser rejects every other combination.
const ReviewerFlags = union(enum) {
    /// No reviewer flag. Create sends no reviewers, and update keeps them.
    keep,
    /// The `--reviewer` values, or none for `--clear-reviewers`.
    set: []const []const u8,
    defaults: DefaultReviewerFlags,

    /// The reviewers that the flags name before a Default Reviewer read. Null keeps the reviewers.
    fn named(self: ReviewerFlags) ?[]const []const u8 {
        return switch (self) {
            .keep => null,
            .set => |uuids| uuids,
            .defaults => |defaults| defaults.add,
        };
    }
};

const MutationArgs = struct {
    repository: ?[]const u8 = null,
    pr_id: ?u64 = null,
    /// `mutatePullRequest` sets `opts.reviewers` from `reviewer_flags`.
    opts: bbr.bitbucket.PullRequestOptions = .{},
    description_file: ?[]const u8 = null,
    /// Owns the `--reviewer` values that `reviewer_flags` borrows.
    reviewers: std.ArrayList([]const u8) = .empty,
    reviewer_flags: ReviewerFlags = .keep,

    fn deinit(self: *MutationArgs, a: std.mem.Allocator) void {
        self.reviewers.deinit(a);
    }
};

fn parseMutation(a: std.mem.Allocator, args: []const []const u8, create: bool) !MutationArgs {
    var cur: arg.Cursor = .{ .args = args };
    var p: MutationArgs = .{};
    errdefer p.deinit(a);
    var clear_reviewers = false;
    var default_reviewers = false;
    var effective = false;
    while (cur.next()) |text| {
        const f = arg.splitFlag(text) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "repository")) {
            try arg.setOption([]const u8, &p.repository, try arg.takeValue(&cur, f));
        } else if (!create and std.mem.eql(u8, f.name, "pull-request-id")) {
            try arg.setOption(u64, &p.pr_id, try arg.parseU64(try arg.takeValue(&cur, f)));
        } else if (std.mem.eql(u8, f.name, "title")) {
            try arg.setOption([]const u8, &p.opts.title, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "source-branch")) {
            try arg.setOption([]const u8, &p.opts.source_branch, try arg.takeValue(&cur, f));
        } else if (create and std.mem.eql(u8, f.name, "source-repository")) {
            try arg.setOption([]const u8, &p.opts.source_repository, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "destination-branch")) {
            try arg.setOption([]const u8, &p.opts.destination_branch, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "description")) {
            try arg.setOption([]const u8, &p.opts.description, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "description-file")) {
            try arg.setOption([]const u8, &p.description_file, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "reviewer")) {
            try p.reviewers.append(a, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "clear-reviewers")) {
            if (f.value != null) return error.UnknownFlag;
            clear_reviewers = true;
        } else if (std.mem.eql(u8, f.name, "default-reviewers")) {
            if (f.value != null) return error.UnknownFlag;
            default_reviewers = true;
        } else if (std.mem.eql(u8, f.name, "effective")) {
            if (f.value != null) return error.UnknownFlag;
            effective = true;
        } else if (std.mem.eql(u8, f.name, "draft")) {
            try arg.setOption(bool, &p.opts.draft, try arg.parseBool(try arg.takeValue(&cur, f)));
        } else if (std.mem.eql(u8, f.name, "close-source-branch")) {
            try arg.setOption(bool, &p.opts.close_source_branch, try arg.parseBool(try arg.takeValue(&cur, f)));
        } else return error.UnknownFlag;
    }
    const repository = p.repository orelse return error.MissingRequired;
    if (repository.len == 0) return error.BadRequest;
    if (!create) {
        const id = p.pr_id orelse return error.MissingRequired;
        if (id == 0) return error.InvalidNumber;
    }
    if (effective and !default_reviewers) return error.BadRequest;
    if (clear_reviewers and (p.reviewers.items.len != 0 or default_reviewers)) return error.BadRequest;
    p.reviewer_flags = if (default_reviewers)
        .{ .defaults = .{ .effective = effective, .add = p.reviewers.items } }
    else if (clear_reviewers)
        .{ .set = &.{} }
    else if (p.reviewers.items.len != 0)
        .{ .set = p.reviewers.items }
    else
        .keep;
    if (p.description_file) |path| {
        if (path.len == 0 or p.opts.description != null) return error.BadRequest;
        // A file is an explicit description change, even before it is read.
        p.opts.description = "";
    }
    // `opts.reviewers` stays null until `mutatePullRequest`. Validate the named reviewers now,
    // so that bad flags send no request.
    var named = p.opts;
    named.reviewers = p.reviewer_flags.named();
    try named.validate(create);
    return p;
}

fn mutatePullRequest(a: std.mem.Allocator, io: std.Io, bb: bbr.bitbucket.Client, args: []const []const u8, create: bool) !bbr.bitbucket.PullRequest {
    var p = try parseMutation(a, args, create);
    defer p.deinit(a);
    const description = if (p.description_file) |path| try out.readFile(io, a, path) else null;
    defer if (description) |text| a.free(text);
    if (description) |text| p.opts.description = text;
    var reads = std.heap.ArenaAllocator.init(a);
    defer reads.deinit();
    p.opts.reviewers = switch (p.reviewer_flags) {
        .keep => null,
        .set => |uuids| uuids,
        .defaults => |defaults| try withDefaultReviewers(reads.allocator(), io, bb, p.repository.?, if (create) null else p.pr_id.?, defaults),
    };
    return if (create)
        bb.createPullRequest(a, p.repository.?, p.opts)
    else
        bb.updatePullRequest(a, p.repository.?, p.pr_id.?, p.opts);
}

/// Reads the PullRequest Author and the Default Reviewers, then merges them with `defaults.add`.
/// `pr_id` is null on create, where the Authenticated Account becomes the Author.
fn withDefaultReviewers(a: std.mem.Allocator, io: std.Io, bb: bbr.bitbucket.Client, repository: []const u8, pr_id: ?u64, defaults: DefaultReviewerFlags) ![]const []const u8 {
    const author = if (pr_id) |id| (try bb.getPullRequest(a, repository, id)).author_uuid else try bb.getAuthenticatedAccountUuid(a);
    if (author.len == 0) return error.MalformedResponse;
    const concurrency = ws.effectiveConcurrency(repositories.default_reviewers_concurrency, std.Thread.getCpuCount());
    const listed = try bb.listDefaultReviewers(io, a, repository, defaults.effective, .{}, concurrency);
    const selection = try mergeReviewerUuids(a, listed, defaults.add, author);
    if (selection.dropped_explicit_author) {
        const verb = if (pr_id == null) "create-pull-request" else "update-pull-request";
        try out.printWarning(io, verb, "--reviewer {s} is the PullRequest Author. bbr leaves it out.", .{author});
    }
    return selection.uuids;
}

const ReviewerSelection = struct { uuids: []const []const u8, dropped_explicit_author: bool };

/// The Default Reviewers in Bitbucket order, then `explicit`. Each UUID appears once, and the
/// first wins. `author` never appears. `dropped_explicit_author` is true only when `explicit` names it.
fn mergeReviewerUuids(allocator: std.mem.Allocator, defaults: []const bbr.bitbucket.DefaultReviewer, explicit: []const []const u8, author: []const u8) !ReviewerSelection {
    var uuids: std.ArrayList([]const u8) = try .initCapacity(allocator, defaults.len + explicit.len);
    errdefer uuids.deinit(allocator);
    for (defaults) |reviewer| addReviewer(&uuids, reviewer.uuid, author);
    for (explicit) |uuid| addReviewer(&uuids, uuid, author);
    const dropped = for (explicit) |uuid| {
        if (std.mem.eql(u8, uuid, author)) break true;
    } else false;
    return .{ .uuids = try uuids.toOwnedSlice(allocator), .dropped_explicit_author = dropped };
}

fn addReviewer(uuids: *std.ArrayList([]const u8), uuid: []const u8, author: []const u8) void {
    if (std.mem.eql(u8, uuid, author)) return;
    for (uuids.items) |seen| if (std.mem.eql(u8, seen, uuid)) return;
    uuids.appendAssumeCapacity(uuid);
}

pub fn runCreate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try printPullRequest(init, try mutatePullRequest(arena.allocator(), init.io, bb, args, true), json);
}

pub fn runUpdate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try printPullRequest(init, try mutatePullRequest(arena.allocator(), init.io, bb, args, false), json);
}

fn declinePullRequest(a: std.mem.Allocator, bb: bbr.bitbucket.Client, args: []const []const u8) !bbr.bitbucket.PullRequest {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var id: ?u64 = null;
    while (cur.next()) |text| {
        const f = arg.splitFlag(text) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "repository")) {
            try arg.setOption([]const u8, &repository, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            try arg.setOption(u64, &id, try arg.parseU64(try arg.takeValue(&cur, f)));
        } else return error.UnknownFlag;
    }
    const repo = repository orelse return error.MissingRequired;
    const pr_id = id orelse return error.MissingRequired;
    if (repo.len == 0) return error.BadRequest;
    if (pr_id == 0) return error.InvalidNumber;
    return bb.declinePullRequest(a, repo, pr_id);
}

pub fn runDecline(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try printPullRequest(init, try declinePullRequest(arena.allocator(), bb, args), json);
}

fn listCommitPullRequests(a: std.mem.Allocator, bb: bbr.bitbucket.Client, args: []const []const u8) ![]bbr.bitbucket.PullRequestSummary {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var page: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |text| {
        const f = arg.splitFlag(text) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "query") or std.mem.eql(u8, f.name, "sort")) return error.UnknownFlag;
        if (try ws.takePageFlag(&cur, f, &page, bbr.bitbucket.max_pagelen.commit_pull_requests)) continue;
        _ = cur.next();
        if (std.mem.eql(u8, f.name, "repository")) {
            try arg.setOption([]const u8, &repository, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "commit")) {
            try arg.setOption([]const u8, &commit, try arg.takeValue(&cur, f));
        } else return error.UnknownFlag;
    }
    const repo = repository orelse return error.MissingRequired;
    const hash = commit orelse return error.MissingRequired;
    if (repo.len == 0 or hash.len == 0) return error.BadRequest;
    return bb.listCommitPullRequests(a, repo, hash, page);
}

pub fn runListCommit(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try printSummaries(init, try listCommitPullRequests(arena.allocator(), bb, args), json);
}

pub fn runWhoami(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    if (args.len != 0) return error.UnknownFlag;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const uuid = try bb.getAuthenticatedAccountUuid(arena.allocator());
    if (json) {
        try out.printJson(init, .{ .uuid = uuid });
    } else {
        try out.printLine(init, "{s}", .{uuid});
    }
}

pub fn runGetVerdict(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var uuid: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "uuid")) {
            _ = cur.next();
            uuid = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const id = pr_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const account = if (uuid) |u| u else try bb.getAuthenticatedAccountUuid(a);
    const pr = try bb.getPullRequest(a, repo, id);
    const verdict = pr.reviewerVerdict(account);
    if (json) {
        try out.printJson(init, .{ .uuid = account, .verdict = @tagName(verdict) });
    } else {
        try out.printLine(init, "{s}: {s}", .{ account, @tagName(verdict) });
    }
}

const SetVerdictResult = struct {
    result: bbr.bitbucket.ReviewerVerdictChangeResult,
    verdict: []const u8,
};

fn setVerdict(allocator: std.mem.Allocator, bb: bbr.bitbucket.Client, args: []const []const u8) !SetVerdictResult {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var verdict_s: ?[]const u8 = null;
    var expected: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "verdict")) {
            _ = cur.next();
            verdict_s = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "expected-source-commit")) {
            _ = cur.next();
            expected = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const id = pr_id orelse return error.MissingRequired;
    const vs = verdict_s orelse return error.MissingRequired;
    const exp = expected orelse return error.MissingRequired;
    const target: bbr.bitbucket.ReviewerVerdict = if (std.mem.eql(u8, vs, "approved"))
        .approved
    else if (std.mem.eql(u8, vs, "changes_requested"))
        .changes_requested
    else if (std.mem.eql(u8, vs, "none") or std.mem.eql(u8, vs, "no_verdict"))
        .no_verdict
    else
        return error.BadRequest;

    const account = try bb.getAuthenticatedAccountUuid(allocator);
    defer allocator.free(account);
    return .{
        .result = try bb.changeReviewerVerdict(allocator, repo, id, exp, account, target),
        .verdict = vs,
    };
}

pub fn runSetVerdict(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const changed = try setVerdict(arena.allocator(), bb, args);
    const result = changed.result;
    const vs = changed.verdict;
    switch (result) {
        .success, .reconciled_success => {},
        .api_error => |err| return err,
        .stale_source_commit => return error.ReviewerVerdictChangeFailed,
        .unresolved => |unresolved| {
            const cause = unresolved orelse return error.ReviewerVerdictChangeFailed;
            const reported = bb.diagnostic.fail(.execute, .{ .zig = cause }, @src());
            // The message names the translated meaning and the client cause, and the record
            // takes the client cause, so the record keeps the evidence that the client noted.
            var buf: [512]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &buf);
            const writer = &stderr.interface;
            try writer.writeAll("bbr api set-verdict: ReviewerVerdictChangeFailed");
            const rejection = if (bb.error_detail) |detail| detail.reason else null;
            if (bbr.bitbucket.asApiError(cause) == null) {
                try writer.print(": {s}", .{@errorName(cause)});
            } else if (rejection) |reason| {
                try writer.print(": Bitbucket rejected request ({s})", .{@errorName(reason)});
                if (bb.error_detail.?.message) |message| try writer.print(": {s}", .{message});
            }
            try writer.writeByte('\n');
            try writer.flush();
            return reported;
        },
    }
    const name: []const u8 = switch (result) {
        .success => "success",
        .reconciled_success => "reconciled_success",
        .api_error => "api_error",
        .stale_source_commit => "stale_source_commit",
        .unresolved => "unresolved",
    };
    if (json) {
        try out.printJson(init, .{ .result = name, .verdict = vs });
    } else {
        try out.printLine(init, "ok: {s} (verdict {s})", .{ name, vs });
    }
}

test "list-pull-requests parses interleaved filters and page controls in both value forms" {
    const cases = [_][]const []const u8{
        &.{ "--page", "3", "--repository", "repository", "--query", "title=\"Review\"", "--state", "MERGED", "--pagelen", "10", "--source-branch", "feature", "--limit", "12", "--sort", "-id", "--no-follow" },
        &.{ "--no-follow", "--repository=repository", "--pagelen=10", "--state=MERGED", "--sort=-id", "--source-branch=feature", "--page=3", "--query=title=\"Review\"", "--limit=12" },
    };
    for (cases) |args| {
        const parsed = try parseList(args);
        try std.testing.expectEqualStrings("repository", parsed.repository);
        try std.testing.expectEqual(.MERGED, parsed.filter.state);
        try std.testing.expectEqualStrings("feature", parsed.filter.source_branch.?);
        try std.testing.expectEqual(@as(u32, 10), parsed.page.pagelen.?);
        try std.testing.expectEqual(@as(u32, 3), parsed.page.page.?);
        try std.testing.expectEqualStrings("title=\"Review\"", parsed.page.query.?);
        try std.testing.expectEqualStrings("-id", parsed.page.sort.?);
        try std.testing.expect(!parsed.page.follow);
        try std.testing.expectEqual(@as(usize, 12), parsed.page.limit.?);
    }
    const defaults = try parseList(&.{ "--repository", "repository" });
    try std.testing.expectEqual(.OPEN, defaults.filter.state);
    try std.testing.expect(defaults.filter.source_branch == null);
    try std.testing.expectEqual(bbr.bitbucket.PageOptions{}, defaults.page);
}

test "list-pull-requests rejects invalid page controls before HTTP" {
    var fake: bbr.http.FakeHttpClient = .{};
    const bb = testClient(&fake);
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingRequired, listPullRequests(a, std.testing.io, bb, &.{"--no-follow"}));
    try std.testing.expectError(error.MissingValue, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--page" }));
    try std.testing.expectError(error.InvalidNumber, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--pagelen=-1" }));
    try std.testing.expectError(error.InvalidNumber, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--pagelen=51" }));
    try std.testing.expectError(error.InvalidNumber, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--limit=bad" }));
    try std.testing.expectError(error.UnknownFlag, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--no-follow=false" }));
    try std.testing.expectError(error.UnknownFlag, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--unknown" }));
    try std.testing.expectError(error.BadRequest, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--state=closed" }));
    try std.testing.expectError(error.BadRequest, listPullRequests(a, std.testing.io, bb, &.{ "--repository=repository", "--state=" }));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
}

const test_pull_request =
    \\{"id":42,"title":"Review","state":"OPEN",
    \\ "author":{"display_name":"Ada","uuid":"{author}"},
    \\ "source":{"branch":{"name":"feature"},"commit":{"hash":"abc123"}},
    \\ "destination":{"branch":{"name":"main"},"commit":{"hash":"def456"}}
;

const test_first_page = "{\"values\":[" ++ test_pull_request ++ "}," ++ test_pull_request ++
    "}],\"next\":\"https://api.bitbucket.org/2.0/repositories/workspace/repository/pullrequests?page=4\"}";
const test_last_page = "{\"values\":[" ++ test_pull_request ++ "}]}";

fn testClient(fake: *bbr.http.FakeHttpClient) bbr.bitbucket.Client {
    return bbr.bitbucket.Client.init(fake.httpClient(), .{
        .username = "test-user",
        .token = "test-token",
        .workspace = "workspace",
    });
}

test "list-pull-requests sends filters and page controls and does not follow with no-follow" {
    const responses = [_]bbr.http.Canned{
        .{ .body = test_first_page },
        .{ .send_error = error.UnexpectedNextPage },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const a = std.testing.allocator;
    const items = try listPullRequests(a, std.testing.io, testClient(&fake), &.{
        "--page=3",     "--repository=repository", "--query=title=\"Review\"", "--state=MERGED",
        "--pagelen=10", "--source-branch=feature", "--sort=-id",               "--no-follow",
    });
    defer bbr.bitbucket.deinitSummaries(a, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    const url = fake.lastUrl().?;
    try std.testing.expect(std.mem.startsWith(u8, url, bbr.bitbucket.base_url ++ "/repositories/workspace/repository/pullrequests?"));
    for ([_][]const u8{
        "pagelen=10",                                                                                           "page=3", "sort=-id",
        "q=state%3D%22MERGED%22%20AND%20source.branch.name%3D%22feature%22%20AND%20%28title%3D%22Review%22%29",
    }) |part| try std.testing.expect(std.mem.indexOf(u8, url, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=") == null);
}

test "list-pull-requests sends the PullRequest maximum --pagelen of 50" {
    var fake: bbr.http.FakeHttpClient = .{ .body = "{\"values\":[]}" };
    const items = try listPullRequests(std.testing.allocator, std.testing.io, testClient(&fake), &.{ "--repository=repository", "--pagelen", "50", "--no-follow" });
    defer bbr.bitbucket.deinitSummaries(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    try std.testing.expect(std.mem.indexOf(u8, fake.lastUrl().?, "pagelen=50") != null);
}

test "list-pull-requests accepts a state in any letter case and sends it in uppercase" {
    for ([_][]const u8{ "open", "Merged", "DECLINED", "superseded" }, [_][]const u8{ "OPEN", "MERGED", "DECLINED", "SUPERSEDED" }) |given, sent| {
        var fake: bbr.http.FakeHttpClient = .{ .body = "{\"values\":[]}" };
        const items = try listPullRequests(std.testing.allocator, std.testing.io, testClient(&fake), &.{ "--repository=repository", "--state", given });
        defer bbr.bitbucket.deinitSummaries(std.testing.allocator, items);
        const state = try std.mem.concat(std.testing.allocator, u8, &.{ "state=", sent });
        defer std.testing.allocator.free(state);
        try std.testing.expect(std.mem.indexOf(u8, fake.lastUrl().?, state) != null);
    }
}

test "list-pull-requests limit stops HTTP paging and defaults still follow next" {
    const responses = [_]bbr.http.Canned{
        .{ .body = test_first_page },
        .{ .body = test_last_page },
    };
    const a = std.testing.allocator;
    var limited: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const capped = try listPullRequests(a, std.testing.io, testClient(&limited), &.{ "--limit=1", "--repository=repository" });
    defer bbr.bitbucket.deinitSummaries(a, capped);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqual(@as(usize, 1), limited.call_count);

    var following: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const all = try listPullRequests(a, std.testing.io, testClient(&following), &.{ "--repository=repository", "--page=3" });
    defer bbr.bitbucket.deinitSummaries(a, all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(@as(usize, 2), following.call_count);
    try std.testing.expectEqualStrings(
        bbr.bitbucket.base_url ++ "/repositories/workspace/repository/pullrequests?page=4",
        following.urlAt(1).?,
    );
}

test "list-workspace-pull-requests rejects invalid options before HTTP" {
    var fake: bbr.http.FakeHttpClient = .{ .body = "{\"values\":[]}" };
    const bb = testClient(&fake);
    for ([_]struct { args: []const []const u8, err: anyerror }{
        .{ .args = &.{}, .err = error.MissingRequired },
        .{ .args = &.{ "--state=OPEN", "--limit=2" }, .err = error.MissingRequired },
        .{ .args = &.{"--reviewer={a}"}, .err = error.MissingRequired },
        .{ .args = &.{ "--repository=sample", "--repository=other" }, .err = error.MissingRequired },
        .{ .args = &.{ "--author={a}", "--repository=" }, .err = error.BadRequest },
        .{ .args = &.{ "--author={a}", "--state=opened" }, .err = error.BadRequest },
        .{ .args = &.{ "--author={a}", "--state", "CLOSED" }, .err = error.BadRequest },
        .{ .args = &.{ "--author={a}", "--author={b}" }, .err = error.BadRequest },
        .{ .args = &.{ "--author={a}", "--reviewer={a}", "--reviewer", "{b}" }, .err = error.BadRequest },
        .{ .args = &.{ "--author={a}", "--reviewer=" }, .err = error.BadRequest },
        .{ .args = &.{ "--reviewer={a}", "--repository=sample", "--concurrency=0" }, .err = error.InvalidNumber },
        .{ .args = &.{ "--author={a}", "--limit=bad" }, .err = error.InvalidNumber },
        .{ .args = &.{ "--reviewer={a}", "--repository=sample", "--page=2" }, .err = error.UnknownFlag },
        .{ .args = &.{ "--author={a}", "--no-follow" }, .err = error.UnknownFlag },
        .{ .args = &.{ "--reviewer={a}", "--repository" }, .err = error.MissingValue },
    }) |case| try std.testing.expectError(case.err, listWorkspacePullRequests(std.testing.allocator, std.Io.failing, bb, case.args));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
    const repeated = try listWorkspacePullRequests(std.testing.allocator, std.Io.failing, bb, &.{ "--author={a}", "--author={a}", "--state=Merged", "--state=MERGED", "--state", "open", "--state", "OPEN" });
    defer bbr.bitbucket.deinitSummaries(std.testing.allocator, repeated);
    try std.testing.expect(std.mem.startsWith(u8, fake.lastUrl().?, bbr.bitbucket.base_url ++ "/workspaces/workspace/pullrequests/%7Ba%7D?pagelen=50&state=OPEN&state=MERGED&fields="));
}

test "list-workspace-pull-requests accepts --concurrency with or without --repository" {
    for ([_][]const []const u8{
        &.{ "--author={a}", "--concurrency=2" },
        &.{ "--author={a}", "--repository=sample", "--concurrency=2" },
    }, [_][]const u8{
        bbr.bitbucket.base_url ++ "/workspaces/workspace/pullrequests/%7Ba%7D?",
        bbr.bitbucket.base_url ++ "/repositories/workspace/sample/pullrequests?",
    }) |args, prefix| {
        var fake: bbr.http.FakeHttpClient = .{ .body = "{\"values\":[]}" };
        const items = try listWorkspacePullRequests(std.testing.allocator, std.testing.io, testClient(&fake), args);
        defer bbr.bitbucket.deinitSummaries(std.testing.allocator, items);
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
        try std.testing.expect(std.mem.startsWith(u8, fake.lastUrl().?, prefix));
    }
    var fake: bbr.http.FakeHttpClient = .{};
    try std.testing.expectError(error.InvalidNumber, listWorkspacePullRequests(std.testing.allocator, std.Io.failing, testClient(&fake), &.{ "--author={a}", "--concurrency=0" }));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
}

test "PullRequest list helps state the concurrency default of their parsers" {
    try std.testing.expectEqual(ws.default_concurrency, (try parseList(&.{"--repository=sample"})).concurrency);
    const workspace = try parseWorkspaceList(std.testing.allocator, &.{"--author={a}"});
    try std.testing.expectEqual(ws.default_concurrency, workspace.options.concurrency);
    for ([_][]const u8{ list_help, workspace_list_help }) |help|
        try std.testing.expect(std.mem.indexOf(u8, help, ws.concurrencyHelp(ws.default_concurrency)) != null);
}

test "set-verdict rejects a spoofed uuid before HTTP" {
    var fake: bbr.http.FakeHttpClient = .{};
    const bb = testClient(&fake);
    const cases = [_][]const []const u8{
        &.{ "--uuid", "{spoofed}", "--repository=repository", "--pull-request-id=42", "--verdict=none", "--expected-source-commit=abc123" },
        &.{ "--repository=repository", "--pull-request-id=42", "--verdict=none", "--expected-source-commit=abc123", "--uuid={spoofed}" },
    };
    for (cases) |args| try std.testing.expectError(error.UnknownFlag, setVerdict(std.testing.allocator, bb, args));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
    try std.testing.expect(std.mem.indexOf(u8, set_verdict_help, "--uuid") == null);
    try std.testing.expect(std.mem.indexOf(u8, get_verdict_help, "--uuid UUID") != null);
}

test "set-verdict proves the authenticated account before removing its verdict" {
    const before = test_pull_request ++
        ",\"participants\":[{\"user\":{\"uuid\":\"{authenticated}\"},\"state\":\"changes_requested\"}," ++
        "{\"user\":{\"uuid\":\"{spoofed}\"},\"approved\":true}]}";
    const after = test_pull_request ++
        ",\"participants\":[{\"user\":{\"uuid\":\"{spoofed}\"},\"approved\":true}]}";
    const responses = [_]bbr.http.Canned{
        .{ .body = "{\"uuid\":\"{authenticated}\"}" },
        .{ .body = before },
        .{ .status = 204 },
        .{ .body = after },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const changed = try setVerdict(std.testing.allocator, testClient(&fake), &.{
        "--repository=repository", "--pull-request-id=42", "--verdict=none", "--expected-source-commit=abc123",
    });
    try std.testing.expectEqual(bbr.bitbucket.ReviewerVerdictChangeResult.success, changed.result);
    try std.testing.expectEqual(@as(usize, 4), fake.call_count);
    try std.testing.expectEqualStrings(bbr.bitbucket.base_url ++ "/user", fake.urlAt(0).?);
    try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(0).?);
    try std.testing.expectEqual(bbr.http.client.Method.DELETE, fake.methodAt(2).?);
    try std.testing.expectEqualStrings(
        bbr.bitbucket.base_url ++ "/repositories/workspace/repository/pullrequests/42/request-changes",
        fake.urlAt(2).?,
    );
}

test "set-verdict does not mutate when account authentication fails" {
    var fake: bbr.http.FakeHttpClient = .{ .status = 401 };
    try std.testing.expectError(error.Unauthorized, setVerdict(std.testing.allocator, testClient(&fake), &.{
        "--repository=repository", "--pull-request-id=42", "--verdict=approved", "--expected-source-commit=abc123",
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    try std.testing.expectEqualStrings(bbr.bitbucket.base_url ++ "/user", fake.lastUrl().?);
    try std.testing.expectEqual(bbr.http.client.Method.GET, fake.last_method.?);
}

test "API lifecycle mutation parser preserves optional values and reviewer replacement" {
    const a = std.testing.allocator;
    var created = try parseMutation(a, &.{
        "--draft=true",                "--reviewer",     "{ada}",                   "--source-repository=fork/sample", "--repository=sample",
        "--title",                     "Change",         "--source-branch=feature", "--destination-branch=release",    "--reviewer={bob}",
        "--close-source-branch=false", "--description=",
    }, true);
    defer created.deinit(a);
    try std.testing.expectEqual(@as(?bool, true), created.opts.draft);
    try std.testing.expectEqual(@as(?bool, false), created.opts.close_source_branch);
    try std.testing.expectEqualStrings("", created.opts.description.?);
    try std.testing.expectEqual(@as(usize, 2), created.reviewer_flags.set.len);
    var minimal = try parseMutation(a, &.{ "--repository=sample", "--title=Change", "--source-branch=feature" }, true);
    defer minimal.deinit(a);
    try std.testing.expect(minimal.opts.draft == null);
    try std.testing.expect(minimal.reviewer_flags == .keep);
    var cleared = try parseMutation(a, &.{ "--clear-reviewers", "--repository=sample", "--pull-request-id=42", "--draft", "false" }, false);
    defer cleared.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), cleared.reviewer_flags.set.len);
    try std.testing.expectEqual(@as(?bool, false), cleared.opts.draft);
    var defaults = try parseMutation(a, &.{ "--repository=sample", "--pull-request-id=42", "--effective", "--default-reviewers", "--reviewer={ada}" }, false);
    defer defaults.deinit(a);
    try std.testing.expect(defaults.reviewer_flags.defaults.effective);
    try std.testing.expectEqualStrings("{ada}", defaults.reviewer_flags.defaults.add[0]);
}

test "mergeReviewerUuids keeps the Default Reviewer order, adds new --reviewer values, and leaves out the Author" {
    const a = std.testing.allocator;
    const defaults = [_]bbr.bitbucket.DefaultReviewer{
        .{ .uuid = "{bob}", .display_name = "Bob", .reviewer_type = .project },
        .{ .uuid = "{author}", .display_name = "Author", .reviewer_type = .repository },
        .{ .uuid = "{ada}", .display_name = "Ada", .reviewer_type = .repository },
        .{ .uuid = "{bob}", .display_name = "Bob", .reviewer_type = .repository },
    };
    for ([_]struct { explicit: []const []const u8, uuids: []const []const u8, dropped: bool }{
        .{ .explicit = &.{}, .uuids = &.{ "{bob}", "{ada}" }, .dropped = false },
        .{ .explicit = &.{ "{carol}", "{ada}", "{carol}" }, .uuids = &.{ "{bob}", "{ada}", "{carol}" }, .dropped = false },
        .{ .explicit = &.{ "{author}", "{ADA}", "ada" }, .uuids = &.{ "{bob}", "{ada}", "{ADA}", "ada" }, .dropped = true },
    }) |case| {
        const selection = try mergeReviewerUuids(a, &defaults, case.explicit, "{author}");
        defer a.free(selection.uuids);
        try std.testing.expectEqual(case.uuids.len, selection.uuids.len);
        for (case.uuids, selection.uuids) |expected, uuid| try std.testing.expectEqualStrings(expected, uuid);
        try std.testing.expectEqual(case.dropped, selection.dropped_explicit_author);
    }
}

test "API lifecycle invalid mutation options fail before HTTP" {
    const a = std.testing.allocator;
    var fake: bbr.http.FakeHttpClient = .{};
    const bb = testClient(&fake);
    for ([_][]const []const u8{
        &.{ "--repository=sample", "--pull-request-id=42" },
        &.{ "--repository=sample", "--pull-request-id=42", "--draft=yes" },
        &.{ "--repository=sample", "--pull-request-id=42", "--draft=true", "--draft=false" },
        &.{ "--repository=sample", "--pull-request-id=42", "--title=" },
        &.{ "--repository=sample", "--pull-request-id=42", "--reviewer=" },
        &.{ "--repository=sample", "--pull-request-id=42", "--reviewer={ada}", "--clear-reviewers" },
        &.{ "--repository=sample", "--pull-request-id=42", "--description=", "--description-file=unused" },
        &.{ "--repository=sample", "--pull-request-id=42", "--description-file=" },
        &.{ "--repository=sample", "--pull-request-id=42", "--effective", "--draft=true" },
        &.{ "--repository=sample", "--pull-request-id=42", "--default-reviewers", "--clear-reviewers" },
        &.{ "--repository=sample", "--pull-request-id=42", "--clear-reviewers", "--default-reviewers", "--effective" },
        &.{ "--repository=sample", "--pull-request-id=42", "--default-reviewers", "--reviewer=" },
    }) |args| try std.testing.expectError(error.BadRequest, mutatePullRequest(a, std.testing.io, bb, args, false));
    try std.testing.expectError(error.BadRequest, mutatePullRequest(a, std.testing.io, bb, &.{ "--repository=sample", "--title=Change", "--source-branch=feature", "--effective" }, true));
    try std.testing.expectError(error.MissingRequired, mutatePullRequest(a, std.testing.io, bb, &.{"--repository=sample"}, true));
    try std.testing.expectError(error.MissingRequired, mutatePullRequest(a, std.testing.io, bb, &.{ "--repository=sample", "--source-branch=feature", "--default-reviewers" }, true));
    for ([_][]const u8{ "--clear-reviewers=true", "--default-reviewers=true", "--effective=true" }) |flag|
        try std.testing.expectError(error.UnknownFlag, mutatePullRequest(a, std.testing.io, bb, &.{ "--repository=sample", "--pull-request-id=42", "--default-reviewers", flag }, false));
    for ([_][]const []const u8{
        &.{ "--repository=sample", "--pull-request-id=42", "--source-repository=fork/sample" },
        &.{ "--repository=sample", "--pull-request-id=42", "--title=Change", "--source-repository", "fork/sample" },
    }) |args| try std.testing.expectError(error.UnknownFlag, mutatePullRequest(a, std.testing.io, bb, args, false));
    try std.testing.expect(std.mem.indexOf(u8, update_help, "--source-repository") == null);
    try std.testing.expect(std.mem.indexOf(u8, create_help, "--source-repository WORKSPACE/SLUG") != null);
    try std.testing.expectError(error.InvalidNumber, declinePullRequest(a, bb, &.{ "--repository=sample", "--pull-request-id=0" }));
    try std.testing.expectError(error.UnknownFlag, listCommitPullRequests(a, bb, &.{ "--repository=sample", "--commit=abc123", "--query=state=OPEN" }));
    try std.testing.expectError(error.InvalidNumber, listCommitPullRequests(a, bb, &.{ "--repository=sample", "--commit=abc123", "--page=0" }));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
}

test "API lifecycle description files preserve text and fail before HTTP when too large" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/description", .{tmp.sub_path});
    defer a.free(path);
    const args = &.{ "--repository=sample", "--pull-request-id=42", "--description-file", path };
    var fake: bbr.http.FakeHttpClient = .{ .body = test_pull_request ++ "}" };
    const bb = testClient(&fake);
    for ([_][]const u8{ "Line one\nQuote \" and slash \\.", "" }) |text| {
        try out.writeFile(io, text, path);
        const pr = try mutatePullRequest(a, io, bb, args, false);
        defer bbr.bitbucket.deinitPullRequest(a, pr);
        const sent = try std.json.parseFromSlice(struct { description: []const u8 }, a, fake.lastBody().?, .{});
        defer sent.deinit();
        try std.testing.expectEqualStrings(text, sent.value.description);
    }
    const large = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(large);
    @memset(large, 'x');
    try out.writeFile(io, large[0 .. 1024 * 1024], path);
    const exact_limit = try mutatePullRequest(a, io, bb, args, false);
    defer bbr.bitbucket.deinitPullRequest(a, exact_limit);
    try out.writeFile(io, large, path);
    try std.testing.expectError(error.StreamTooLong, mutatePullRequest(a, io, bb, args, false));
    try std.testing.expectEqual(@as(usize, 3), fake.call_count);
}

test "API lifecycle commit CLI follows pages and retains closed states" {
    const a = std.testing.allocator;
    const merged = "{\"id\":42,\"title\":\"Change\",\"state\":\"MERGED\",\"source\":{\"branch\":{\"name\":\"feature\"}},\"destination\":{\"branch\":{\"name\":\"main\"}}}";
    const declined = "{\"id\":43,\"title\":\"Other\",\"state\":\"DECLINED\",\"source\":{\"branch\":{\"name\":\"other\"}},\"destination\":{\"branch\":{\"name\":\"main\"}}}";
    const responses = [_]bbr.http.Canned{
        .{ .body = "{\"values\":[" ++ merged ++ "],\"next\":\"https://api.bitbucket.org/2.0/next\"}" },
        .{ .body = "{\"values\":[" ++ declined ++ "]}" },
    };
    for ([_][]const []const u8{
        &.{ "--page=2", "--repository=sample", "--commit=abc123", "--pagelen=5" },
        &.{ "--no-follow", "--repository=sample", "--commit=abc123" },
        &.{ "--limit=1", "--commit=abc123", "--repository=sample" },
    }, [_]usize{ 2, 1, 1 }) |args, count| {
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        const items = try listCommitPullRequests(a, testClient(&fake), args);
        defer bbr.bitbucket.deinitSummaries(a, items);
        try std.testing.expectEqual(count, items.len);
        try std.testing.expectEqual(count, fake.call_count);
        try std.testing.expectEqualStrings("MERGED", items[0].state);
        if (count == 2) try std.testing.expectEqualStrings("DECLINED", items[1].state);
    }
}
