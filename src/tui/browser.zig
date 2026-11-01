//! The Browser: the Workspace-wide tree of Repositories and, under each
//! expanded Repository, its open PullRequests. This module owns the Browser
//! data and the Browser Entry projection. It imports neither vaxis nor
//! theme.zig, so Presentation can own it.

const std = @import("std");
const bbr = @import("bbr");

const Allocator = std.mem.Allocator;

pub const RepositorySummary = bbr.bitbucket.RepositorySummary;
const summary_cache = bbr.bitbucket.summary_cache;
pub const PullRequestSummary = bbr.bitbucket.PullRequestSummary;
pub const WorkId = u64;

/// Why a list load failed: a classified Bitbucket refusal, or a failure
/// before Bitbucket answered.
pub const Failure = bbr.bitbucket.ApiError || error{ OutOfMemory, ConnectionFailed, WorkerLaunchFailed };

pub fn failure(err: anyerror) Failure {
    inline for (@typeInfo(Failure).error_set.?) |member| {
        if (err == @field(anyerror, member.name)) return @field(Failure, member.name);
    }
    return error.ConnectionFailed;
}

/// A failure that tells the reviewer the previous list is no longer theirs to see.
fn dropsPrevious(reason: Failure) bool {
    return reason == error.Forbidden or reason == error.NotFound;
}

/// Owned PullRequest Summaries: one list load, or a populated Picker.
pub const PullRequestSummaries = struct {
    arena: std.heap.ArenaAllocator,
    prs: []const PullRequestSummary,

    pub fn create(backing: Allocator) !*PullRequestSummaries {
        const summaries = try backing.create(PullRequestSummaries);
        summaries.arena = std.heap.ArenaAllocator.init(backing);
        summaries.prs = &.{};
        return summaries;
    }

    pub fn destroy(self: *PullRequestSummaries) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }

    /// Copies `items` and every string they hold.
    pub fn copy(backing: Allocator, items: []const PullRequestSummary) Allocator.Error!*PullRequestSummaries {
        const summaries = try create(backing);
        errdefer summaries.destroy();
        const a = summaries.arena.allocator();
        const prs = try a.alloc(PullRequestSummary, items.len);
        for (items, prs) |item, *pr| {
            pr.* = item;
            pr.title = try a.dupe(u8, item.title);
            pr.state = try a.dupe(u8, item.state);
            pr.author_display_name = try a.dupe(u8, item.author_display_name);
            pr.source_branch = try a.dupe(u8, item.source_branch);
            pr.destination_branch = try a.dupe(u8, item.destination_branch);
        }
        summaries.prs = prs;
        return summaries;
    }
};

/// Owned Repository Summaries from one Repository list load.
pub const RepositorySummaries = struct {
    arena: std.heap.ArenaAllocator,
    repositories: []const RepositorySummary,

    pub fn create(backing: Allocator) !*RepositorySummaries {
        const summaries = try backing.create(RepositorySummaries);
        summaries.arena = std.heap.ArenaAllocator.init(backing);
        summaries.repositories = &.{};
        return summaries;
    }

    pub fn destroy(self: *RepositorySummaries) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
};

/// An owned Summary Cache Snapshot from one Summary Cache load.
pub const CachedSummaries = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: summary_cache.Snapshot,

    pub fn create(backing: Allocator) !*CachedSummaries {
        const cached = try backing.create(CachedSummaries);
        cached.arena = std.heap.ArenaAllocator.init(backing);
        cached.snapshot = .{ .workspace = "", .repositories = &.{} };
        return cached;
    }

    pub fn destroy(self: *CachedSummaries) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
};

pub const RepositoriesOutcome = union(enum) { loaded: *RepositorySummaries, failed: Failure };
pub const PullRequestsOutcome = union(enum) { loaded: *PullRequestSummaries, failed: Failure };

/// A copy-safe Workspace or Repository slug. A Selection outlives the list
/// that named it, so it owns its bytes.
pub const Name = struct {
    buf: [256]u8 = undefined,
    len: u16 = 0,

    pub fn init(text: []const u8) error{NameTooLong}!Name {
        var name: Name = .{};
        if (text.len > name.buf.len) return error.NameTooLong;
        @memcpy(name.buf[0..text.len], text);
        name.len = @intCast(text.len);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: *const Name, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

/// The expanded Repository and the focused PullRequest that a new Browser
/// begins with.
pub const Start = struct {
    workspace: Name,
    repository: ?Name = null,
    pull_request_id: ?u64 = null,
};

pub const Sort = enum { updated, name };

/// The cursor names its row, so it survives a refresh, a sort, and a
/// Session replacement.
pub const Selection = union(enum) {
    repository: Name,
    pull_request: struct { repository: Name, id: u64 },

    pub fn repositorySlug(self: *const Selection) []const u8 {
        return switch (self.*) {
            .repository => |*name| name.slice(),
            .pull_request => |*pr| pr.repository.slice(),
        };
    }
};

/// The last settled PullRequest list of a Repository. Each list arm owns its
/// Summaries.
pub const Settled = union(enum) {
    unknown,
    cached: *PullRequestSummaries,
    loaded: *PullRequestSummaries,
    failed: struct { reason: Failure, previous: ?*PullRequestSummaries },

    pub fn list(self: Settled) ?[]const PullRequestSummary {
        const owner = switch (self) {
            .unknown => return null,
            .cached, .loaded => |summaries| summaries,
            .failed => |failed| failed.previous orelse return null,
        };
        return owner.prs;
    }

    fn take(self: *Settled) ?*PullRequestSummaries {
        const owner = switch (self.*) {
            .unknown => null,
            .cached, .loaded => |summaries| summaries,
            .failed => |failed| failed.previous,
        };
        self.* = .unknown;
        return owner;
    }

    fn deinit(self: *Settled) void {
        if (self.take()) |owner| owner.destroy();
    }
};

/// A wanted PullRequest list request: waiting in the FIFO with its ticket,
/// or issued with the WorkId its completion must carry.
pub const Request = union(enum) { waiting: u64, issued: WorkId };

pub const PullRequestLoad = struct {
    settled: Settled = .unknown,
    request: ?Request = null,

    pub fn loading(self: PullRequestLoad) bool {
        return self.request != null;
    }
};

pub const RepositoryNode = struct {
    summary: RepositorySummary,
    expanded: bool = false,
    pull_requests: PullRequestLoad = .{},

    /// The open-PullRequest count, or null before any list is known.
    pub fn count(self: *const RepositoryNode) ?usize {
        return if (self.pull_requests.settled.list()) |prs| prs.len else null;
    }
};

pub const RepositoryList = struct {
    loaded: ?*RepositorySummaries = null,
    failure: ?Failure = null,
    work: ?WorkId = null,
};

pub const Message = union(enum) {
    loading_repositories,
    repositories_failed: Failure,
    no_repositories,
    loading_pull_requests: usize,
    pull_requests_failed: struct { repository: usize, reason: Failure },
    no_pull_requests: usize,
};

/// One row of the Browser. A message entry never takes the cursor.
pub const Entry = union(enum) {
    repository: usize,
    /// `index` names a PullRequest in the settled list of its Repository.
    pull_request: struct { repository: usize, index: usize },
    message: Message,

    pub fn selectable(self: Entry) bool {
        return switch (self) {
            .repository, .pull_request => true,
            .message => false,
        };
    }
};

/// The visible Browser Entries in Sort order: each Repository, and under an
/// expanded Repository its messages and PullRequests. A Repository list
/// message follows the Repositories.
pub fn entries(allocator: Allocator, nodes: []const RepositoryNode, repositories: RepositoryList, sort: Sort) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(allocator);
    const order = try allocator.alloc(usize, nodes.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, RepositoryOrder{ .nodes = nodes, .sort = sort }, RepositoryOrder.less);

    var prs_order: std.ArrayList(usize) = .empty;
    defer prs_order.deinit(allocator);
    for (order) |node_index| {
        const node = nodes[node_index];
        try out.append(allocator, .{ .repository = node_index });
        if (!node.expanded) continue;
        const load = node.pull_requests;
        const prs = load.settled.list();
        if (load.settled == .failed) {
            try out.append(allocator, .{ .message = .{ .pull_requests_failed = .{ .repository = node_index, .reason = load.settled.failed.reason } } });
        } else if (prs == null and load.loading()) {
            try out.append(allocator, .{ .message = .{ .loading_pull_requests = node_index } });
        } else if (prs != null and prs.?.len == 0) {
            try out.append(allocator, .{ .message = .{ .no_pull_requests = node_index } });
        }
        const items = prs orelse continue;
        prs_order.clearRetainingCapacity();
        try prs_order.ensureTotalCapacity(allocator, items.len);
        for (0..items.len) |index| prs_order.appendAssumeCapacity(index);
        std.mem.sort(usize, prs_order.items, PullRequestOrder{ .prs = items, .sort = sort }, PullRequestOrder.less);
        for (prs_order.items) |index| try out.append(allocator, .{ .pull_request = .{ .repository = node_index, .index = index } });
    }
    if (repositories.loaded) |loaded| {
        if (loaded.repositories.len == 0 and nodes.len == 0) try out.append(allocator, .{ .message = .no_repositories });
    } else if (repositories.work != null) {
        try out.append(allocator, .{ .message = .loading_repositories });
    } else if (repositories.failure) |reason| {
        try out.append(allocator, .{ .message = .{ .repositories_failed = reason } });
    }
    return out.toOwnedSlice(allocator);
}

/// Newest first, and a missing time last.
fn newer(a: ?i64, b: ?i64) ?bool {
    if (a == null and b == null) return null;
    if (a == null) return false;
    if (b == null) return true;
    if (a.? == b.?) return null;
    return a.? > b.?;
}

const RepositoryOrder = struct {
    nodes: []const RepositoryNode,
    sort: Sort,

    fn less(self: RepositoryOrder, a: usize, b: usize) bool {
        const left = self.nodes[a].summary;
        const right = self.nodes[b].summary;
        switch (self.sort) {
            .updated => if (newer(left.updated_on, right.updated_on)) |result| return result,
            .name => switch (std.ascii.orderIgnoreCase(left.name, right.name)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            },
        }
        return std.mem.order(u8, left.slug, right.slug) == .lt;
    }
};

const PullRequestOrder = struct {
    prs: []const PullRequestSummary,
    sort: Sort,

    fn less(self: PullRequestOrder, a: usize, b: usize) bool {
        const left = self.prs[a];
        const right = self.prs[b];
        if (self.sort == .updated) if (newer(left.updated_on, right.updated_on)) |result| return result;
        return left.id > right.id;
    }
};

/// 9999-12-31T23:59:59Z, the last second with a four-digit year.
const last_four_digit_second: i64 = 253402300799;

/// `YYYY-MM-DD` in UTC, or null for a missing, negative, or post-9999 time.
pub fn formatDate(buf: *[10]u8, seconds: ?i64) ?[]const u8 {
    const value = seconds orelse return null;
    // std.time.epoch overflows for a large time, such as one from a corrupt Summary Cache.
    if (value < 0 or value > last_four_digit_second) return null;
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(value) }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
    }) catch null;
}

/// The Browser state. It belongs to the process: Presentation keeps it
/// outside the published Session, so a Session replacement never resets it.
pub const Browser = struct {
    allocator: Allocator,
    workspace: Name,
    /// The slug of the Browser Start Repository. Its placeholder node shows
    /// this slug until the Repository list arrives.
    start_repository: Name = .{},
    nodes: std.ArrayList(RepositoryNode) = .empty,
    repositories: RepositoryList = .{},
    /// The Summary Cache that the node summaries borrow until the first
    /// Repository list success replaces them.
    cached: ?*CachedSummaries = null,
    sort: Sort = .updated,
    entries: []Entry = &.{},
    cursor: ?Selection = null,
    cursor_index: ?usize = null,
    /// The Browser Start PullRequest. The cursor moves to it when its row
    /// appears, and a cursor Motion clears it.
    pending_focus: ?Selection = null,
    scroll: usize = 0,
    viewport: usize = 1,
    next_ticket: u64 = 0,

    pub fn create(allocator: Allocator, start: Start, viewport: usize) Allocator.Error!*Browser {
        const self = try allocator.create(Browser);
        self.* = .{ .allocator = allocator, .workspace = start.workspace, .viewport = @max(viewport, 1) };
        errdefer self.destroy();
        if (start.repository) |repository| {
            self.start_repository = repository;
            const slug = self.start_repository.slice();
            try self.nodes.append(allocator, .{ .summary = .{ .slug = slug, .name = slug, .updated_on = null } });
            _ = self.expand(0);
            self.cursor = .{ .repository = repository };
            if (start.pull_request_id) |id| self.pending_focus = .{ .pull_request = .{ .repository = repository, .id = id } };
        }
        try self.rebuild();
        return self;
    }

    pub fn destroy(self: *Browser) void {
        for (self.nodes.items) |*node| node.pull_requests.settled.deinit();
        self.nodes.deinit(self.allocator);
        if (self.repositories.loaded) |loaded| loaded.destroy();
        if (self.cached) |cached| cached.destroy();
        self.allocator.free(self.entries);
        self.allocator.destroy(self);
    }

    pub fn findNode(self: *const Browser, slug: []const u8) ?usize {
        for (self.nodes.items, 0..) |node, index| if (std.mem.eql(u8, node.summary.slug, slug)) return index;
        return null;
    }

    pub fn nodeForRequest(self: *const Browser, work_id: WorkId) ?usize {
        for (self.nodes.items, 0..) |node, index| {
            const request = node.pull_requests.request orelse continue;
            if (request == .issued and request.issued == work_id) return index;
        }
        return null;
    }

    /// Expands a Repository. Returns true when it now waits for a load.
    pub fn expand(self: *Browser, index: usize) bool {
        const node = &self.nodes.items[index];
        node.expanded = true;
        if (node.pull_requests.request != null) return false;
        switch (node.pull_requests.settled) {
            .unknown, .cached => {},
            .loaded, .failed => return false,
        }
        node.pull_requests.request = .{ .waiting = self.takeTicket() };
        return true;
    }

    /// Collapses a Repository and removes it from the FIFO. An issued load
    /// still completes and stores its result.
    pub fn collapse(self: *Browser, index: usize) void {
        const node = &self.nodes.items[index];
        node.expanded = false;
        if (node.pull_requests.request) |request| if (request == .waiting) {
            node.pull_requests.request = null;
        };
    }

    /// Queues a new load for every expanded Repository. A load in flight
    /// loses its WorkId, so its completion is stale.
    pub fn refreshExpanded(self: *Browser) void {
        for (self.nodes.items) |*node| {
            if (node.expanded) node.pull_requests.request = .{ .waiting = self.takeTicket() };
        }
    }

    /// The FIFO head: the waiting Repository with the oldest ticket.
    pub fn nextWaiting(self: *const Browser) ?usize {
        var best: ?usize = null;
        var best_ticket: u64 = 0;
        for (self.nodes.items, 0..) |node, index| {
            const request = node.pull_requests.request orelse continue;
            if (request != .waiting) continue;
            if (best == null or request.waiting < best_ticket) {
                best = index;
                best_ticket = request.waiting;
            }
        }
        return best;
    }

    /// Empties the FIFO. Each waiting Repository keeps its earlier settled list.
    pub fn dropWaiting(self: *Browser) void {
        for (self.nodes.items) |*node| {
            if (node.pull_requests.request) |request| if (request == .waiting) {
                node.pull_requests.request = null;
            };
        }
    }

    fn takeTicket(self: *Browser) u64 {
        self.next_ticket += 1;
        return self.next_ticket;
    }

    /// Replaces the Repository nodes with `list`, which the Browser then owns.
    /// A node in the list keeps its expansion and its PullRequest load. A node
    /// outside it goes away with its PullRequests. On error the caller still
    /// owns `list`.
    pub fn replaceRepositories(self: *Browser, list: *RepositorySummaries) Allocator.Error!void {
        var next: std.ArrayList(RepositoryNode) = .empty;
        errdefer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, list.repositories.len);
        var previous: std.StringHashMapUnmanaged(usize) = .empty;
        defer previous.deinit(self.allocator);
        try previous.ensureTotalCapacity(self.allocator, @intCast(self.nodes.items.len));
        for (self.nodes.items, 0..) |node, index| previous.putAssumeCapacity(node.summary.slug, index);
        const kept = try self.allocator.alloc(bool, self.nodes.items.len);
        defer self.allocator.free(kept);
        @memset(kept, false);

        for (list.repositories) |summary| {
            var node: RepositoryNode = .{ .summary = summary };
            if (previous.get(summary.slug)) |index| if (!kept[index]) {
                kept[index] = true;
                node.expanded = self.nodes.items[index].expanded;
                node.pull_requests = self.nodes.items[index].pull_requests;
            };
            next.appendAssumeCapacity(node);
        }
        for (self.nodes.items, kept) |*node, keep| if (!keep) node.pull_requests.settled.deinit();
        self.nodes.deinit(self.allocator);
        self.nodes = next;
        if (self.repositories.loaded) |old| old.destroy();
        self.repositories.loaded = list;
        self.repositories.failure = null;
        if (self.cached) |cached| cached.destroy();
        self.cached = null;
    }

    /// Fills the Browser from the Summary Cache, which the Browser then owns.
    /// Call it only before the first Repository list success. A cached
    /// Repository updates its node or adds one. A cached PullRequest list
    /// fills only a node with no settled list. On error the caller still owns
    /// `cache`.
    pub fn fillFromCache(self: *Browser, cache: *CachedSummaries) Allocator.Error!void {
        std.debug.assert(self.repositories.loaded == null);
        const repositories = cache.snapshot.repositories;
        try self.nodes.ensureUnusedCapacity(self.allocator, repositories.len);
        const lists = try self.allocator.alloc(?*PullRequestSummaries, repositories.len);
        defer self.allocator.free(lists);
        @memset(lists, null);
        defer for (lists) |unused| if (unused) |owner| owner.destroy();
        for (repositories, lists) |repository, *list| {
            const prs = repository.pull_requests orelse continue;
            list.* = try PullRequestSummaries.copy(self.allocator, prs);
        }

        for (repositories, lists) |repository, *list| {
            const index = self.findNode(repository.summary.slug) orelse blk: {
                self.nodes.appendAssumeCapacity(.{ .summary = repository.summary });
                break :blk self.nodes.items.len - 1;
            };
            const node = &self.nodes.items[index];
            node.summary = repository.summary;
            if (node.pull_requests.settled == .unknown) if (list.*) |owner| {
                node.pull_requests.settled = .{ .cached = owner };
                list.* = null;
            };
        }
        if (self.cached) |old| old.destroy();
        self.cached = cache;
    }

    /// The Summary Cache Snapshot of the current nodes. It borrows the
    /// Browser data. The caller frees only `repositories`.
    pub fn snapshot(self: *const Browser, allocator: Allocator) Allocator.Error!summary_cache.Snapshot {
        const repositories = try allocator.alloc(summary_cache.Repository, self.nodes.items.len);
        for (self.nodes.items, repositories) |node, *repository| repository.* = .{
            .summary = node.summary,
            .pull_requests = node.pull_requests.settled.list(),
        };
        return .{ .workspace = self.workspace.slice(), .repositories = repositories };
    }

    /// Stores a current PullRequest list completion. The Browser takes the
    /// loaded Summaries.
    pub fn storePullRequests(self: *Browser, index: usize, outcome: PullRequestsOutcome) void {
        const load = &self.nodes.items[index].pull_requests;
        load.request = null;
        switch (outcome) {
            .loaded => |summaries| {
                load.settled.deinit();
                load.settled = .{ .loaded = summaries };
            },
            .failed => |reason| {
                var previous = load.settled.take();
                if (dropsPrevious(reason)) if (previous) |owner| {
                    owner.destroy();
                    previous = null;
                };
                load.settled = .{ .failed = .{ .reason = reason, .previous = previous } };
            },
        }
    }

    pub fn pullRequest(self: *const Browser, entry: Entry) ?PullRequestSummary {
        if (entry != .pull_request) return null;
        const prs = self.nodes.items[entry.pull_request.repository].pull_requests.settled.list() orelse return null;
        return prs[entry.pull_request.index];
    }

    fn selectionAt(self: *const Browser, index: usize) ?Selection {
        return switch (self.entries[index]) {
            .repository => |node| .{ .repository = Name.init(self.nodes.items[node].summary.slug) catch return null },
            .pull_request => |pr| .{ .pull_request = .{
                .repository = Name.init(self.nodes.items[pr.repository].summary.slug) catch return null,
                .id = self.pullRequest(self.entries[index]).?.id,
            } },
            .message => null,
        };
    }

    fn indexOf(self: *const Browser, selection: Selection) ?usize {
        for (self.entries, 0..) |entry, index| switch (entry) {
            .repository => |node| if (selection == .repository and selection.repository.eql(self.nodes.items[node].summary.slug)) return index,
            .pull_request => |pr| if (selection == .pull_request and
                selection.pull_request.repository.eql(self.nodes.items[pr.repository].summary.slug) and
                selection.pull_request.id == self.pullRequest(entry).?.id) return index,
            .message => {},
        };
        return null;
    }

    /// Recomputes the Browser Entries and moves the cursor to its Selection.
    /// A missing PullRequest falls back to its Repository row. A missing
    /// Repository falls back to the row at the same index. On error the
    /// Browser has no Entries, because the previous Entries can index past
    /// changed data. The cursor keeps its Selection for the next rebuild.
    pub fn rebuild(self: *Browser) Allocator.Error!void {
        const next = entries(self.allocator, self.nodes.items, self.repositories, self.sort) catch |err| {
            self.allocator.free(self.entries);
            self.entries = &.{};
            self.cursor_index = null;
            self.scroll = 0;
            return err;
        };
        self.allocator.free(self.entries);
        self.entries = next;
        const previous_index = self.cursor_index;

        if (self.pending_focus) |pending| {
            if (self.indexOf(pending) != null) {
                self.cursor = pending;
                self.pending_focus = null;
            } else if (pending == .pull_request) {
                const node = self.findNode(pending.repositorySlug());
                const load = if (node) |index| self.nodes.items[index].pull_requests else PullRequestLoad{};
                if (node != null and !load.loading() and load.settled != .unknown) {
                    self.cursor = .{ .repository = pending.pull_request.repository };
                    self.pending_focus = null;
                }
            }
        }

        self.cursor_index = null;
        if (self.cursor) |cursor| {
            if (self.indexOf(cursor)) |index| {
                self.cursor_index = index;
            } else if (cursor == .pull_request) {
                if (self.indexOf(.{ .repository = cursor.pull_request.repository })) |index| self.cursor_index = index;
            }
        }
        if (self.cursor_index == null) {
            const anchor = @min(previous_index orelse 0, self.entries.len -| 1);
            self.cursor_index = self.nearestSelectable(anchor);
        }
        self.cursor = if (self.cursor_index) |index| self.selectionAt(index) else null;
        self.keepCursorVisible();
    }

    fn nearestSelectable(self: *const Browser, anchor: usize) ?usize {
        var index = anchor;
        while (index < self.entries.len) : (index += 1) if (self.entries[index].selectable()) return index;
        index = @min(anchor, self.entries.len);
        while (index > 0) {
            index -= 1;
            if (self.entries[index].selectable()) return index;
        }
        return null;
    }

    /// The scroll keeps its top row until the cursor leaves the viewport.
    fn keepCursorVisible(self: *Browser) void {
        if (self.cursor_index) |index| {
            if (index < self.scroll) self.scroll = index;
            if (index >= self.scroll + self.viewport) self.scroll = index + 1 - self.viewport;
        }
        self.scroll = @min(self.scroll, self.entries.len -| self.viewport);
    }

    /// Switches between the updated-time Sort and the name Sort. The cursor
    /// keeps its Selection. On error the previous Sort stays, and the
    /// Browser has no Entries until the next rebuild.
    pub fn cycleSort(self: *Browser) Allocator.Error!void {
        const previous = self.sort;
        self.sort = switch (previous) {
            .updated => .name,
            .name => .updated,
        };
        errdefer self.sort = previous;
        try self.rebuild();
    }

    pub fn setViewport(self: *Browser, rows: usize) void {
        self.viewport = @max(rows, 1);
        self.keepCursorVisible();
    }

    pub const Motion = enum { down, up, half_page_down, half_page_up, to_top, to_bottom };

    /// Moves the cursor over the selectable Entries. A Motion clears the
    /// pending focus.
    pub fn move(self: *Browser, motion: Motion) void {
        self.pending_focus = null;
        if (self.entries.len == 0) return;
        const current = self.cursor_index orelse 0;
        const half = @max(self.viewport / 2, 1);
        const target: ?usize = switch (motion) {
            .down => self.selectableAfter(current),
            .up => self.selectableBefore(current),
            .half_page_down => self.selectableAtOrBefore(@min(current + half, self.entries.len - 1)) orelse self.selectableAfter(current),
            .half_page_up => self.selectableAtOrAfter(current -| half) orelse self.selectableBefore(current),
            .to_top => self.selectableAtOrAfter(0),
            .to_bottom => self.selectableAtOrBefore(self.entries.len - 1),
        };
        self.select(target orelse return);
    }

    pub fn selectRepository(self: *Browser, node: usize) void {
        for (self.entries, 0..) |entry, index| {
            if (entry == .repository and entry.repository == node) return self.select(index);
        }
    }

    pub fn select(self: *Browser, index: usize) void {
        if (index >= self.entries.len or !self.entries[index].selectable()) return;
        self.pending_focus = null;
        self.cursor_index = index;
        self.cursor = self.selectionAt(index);
        self.keepCursorVisible();
    }

    pub fn scrollBy(self: *Browser, delta: isize) void {
        const max = self.entries.len -| self.viewport;
        self.scroll = if (delta < 0) self.scroll -| @abs(delta) else @min(self.scroll +| @abs(delta), max);
    }

    fn selectableAfter(self: *const Browser, index: usize) ?usize {
        return if (index + 1 < self.entries.len) self.selectableAtOrAfter(index + 1) else null;
    }

    fn selectableBefore(self: *const Browser, index: usize) ?usize {
        return if (index > 0) self.selectableAtOrBefore(index - 1) else null;
    }

    fn selectableAtOrAfter(self: *const Browser, start: usize) ?usize {
        var index = start;
        while (index < self.entries.len) : (index += 1) if (self.entries[index].selectable()) return index;
        return null;
    }

    fn selectableAtOrBefore(self: *const Browser, start: usize) ?usize {
        var index = @min(start + 1, self.entries.len);
        while (index > 0) {
            index -= 1;
            if (self.entries[index].selectable()) return index;
        }
        return null;
    }

    pub fn cursorEntry(self: *const Browser) ?Entry {
        return self.entries[self.cursor_index orelse return null];
    }

    pub fn projection(self: *const Browser) Projection {
        return .{
            .workspace = self.workspace.slice(),
            .nodes = self.nodes.items,
            .entries = self.entries,
            .cursor = self.cursor_index,
            .scroll = self.scroll,
        };
    }
};

/// Borrowed and immutable, like the Presentation Projection that holds it.
pub const Projection = struct {
    workspace: []const u8,
    nodes: []const RepositoryNode,
    entries: []const Entry,
    cursor: ?usize,
    scroll: usize,

    pub fn pullRequest(self: Projection, entry: Entry) ?PullRequestSummary {
        if (entry != .pull_request) return null;
        const prs = self.nodes[entry.pull_request.repository].pull_requests.settled.list() orelse return null;
        return prs[entry.pull_request.index];
    }
};

const testing = std.testing;

fn testPullRequests(items: []const PullRequestSummary) !*PullRequestSummaries {
    const summaries = try PullRequestSummaries.create(testing.allocator);
    summaries.prs = try summaries.arena.allocator().dupe(PullRequestSummary, items);
    return summaries;
}

fn testRepositories(items: []const RepositorySummary) !*RepositorySummaries {
    const summaries = try RepositorySummaries.create(testing.allocator);
    summaries.repositories = try summaries.arena.allocator().dupe(RepositorySummary, items);
    return summaries;
}

fn testPr(id: u64, updated_on: ?i64) PullRequestSummary {
    return .{ .id = id, .title = "t", .state = "OPEN", .author_display_name = "Ada", .source_branch = "f", .destination_branch = "main", .updated_on = updated_on };
}

fn testStart(repository: ?[]const u8, id: ?u64) !Start {
    return .{
        .workspace = try Name.init("check24"),
        .repository = if (repository) |slug| try Name.init(slug) else null,
        .pull_request_id = id,
    };
}

test "M24 browser entries order Repositories and PullRequests by update time, newest first, with null last" {
    const prs = try testPullRequests(&.{ testPr(3, 100), testPr(9, null), testPr(4, 300), testPr(5, 300) });
    var nodes = [_]RepositoryNode{
        .{ .summary = .{ .slug = "b", .name = "B", .updated_on = 10 } },
        .{ .summary = .{ .slug = "a", .name = "A", .updated_on = null } },
        .{ .summary = .{ .slug = "c", .name = "C", .updated_on = 10 }, .expanded = true, .pull_requests = .{ .settled = .{ .loaded = prs } } },
    };
    defer nodes[2].pull_requests.settled.deinit();
    const list = try entries(testing.allocator, &nodes, .{}, .updated);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 7), list.len);
    try testing.expectEqual(Entry{ .repository = 0 }, list[0]);
    try testing.expectEqual(Entry{ .repository = 2 }, list[1]);
    const ids = [_]u64{ 5, 4, 3, 9 };
    for (ids, list[2..6]) |id, entry| try testing.expectEqual(id, prs.prs[entry.pull_request.index].id);
    try testing.expectEqual(Entry{ .repository = 1 }, list[6]);
}

test "M24 browser the name Sort orders Repositories by name without ASCII case, then slug, and PullRequests by id" {
    const prs = try testPullRequests(&.{ testPr(3, 900), testPr(9, null), testPr(5, 1) });
    var nodes = [_]RepositoryNode{
        .{ .summary = .{ .slug = "b-2", .name = "beta", .updated_on = 40 } },
        .{ .summary = .{ .slug = "a", .name = "Alpha", .updated_on = null }, .expanded = true, .pull_requests = .{ .settled = .{ .loaded = prs } } },
        .{ .summary = .{ .slug = "b-1", .name = "Beta", .updated_on = 10 } },
        .{ .summary = .{ .slug = "z", .name = "alpha2", .updated_on = 90 } },
    };
    defer nodes[1].pull_requests.settled.deinit();
    const list = try entries(testing.allocator, &nodes, .{}, .name);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 7), list.len);
    try testing.expectEqual(Entry{ .repository = 1 }, list[0]);
    const ids = [_]u64{ 9, 5, 3 };
    for (ids, list[1..4]) |id, entry| try testing.expectEqual(id, prs.prs[entry.pull_request.index].id);
    try testing.expectEqualSlices(Entry, &.{ .{ .repository = 3 }, .{ .repository = 2 }, .{ .repository = 0 } }, list[4..]);
}

test "M24 browser entries show the loading, empty, and failure message entries" {
    var empty_nodes = [_]RepositoryNode{};
    const loading = try entries(testing.allocator, &empty_nodes, .{ .work = 1 }, .updated);
    defer testing.allocator.free(loading);
    try testing.expectEqualSlices(Entry, &.{.{ .message = .loading_repositories }}, loading);
    const failed = try entries(testing.allocator, &empty_nodes, .{ .failure = error.Forbidden }, .updated);
    defer testing.allocator.free(failed);
    try testing.expectEqualSlices(Entry, &.{.{ .message = .{ .repositories_failed = error.Forbidden } }}, failed);
    const list = try testRepositories(&.{});
    defer list.destroy();
    const none = try entries(testing.allocator, &empty_nodes, .{ .loaded = list }, .updated);
    defer testing.allocator.free(none);
    try testing.expectEqualSlices(Entry, &.{.{ .message = .no_repositories }}, none);

    const empty = try testPullRequests(&.{});
    var nodes = [_]RepositoryNode{
        .{ .summary = .{ .slug = "a", .name = "A", .updated_on = 3 }, .expanded = true, .pull_requests = .{ .request = .{ .waiting = 1 } } },
        .{ .summary = .{ .slug = "b", .name = "B", .updated_on = 2 }, .expanded = true, .pull_requests = .{ .settled = .{ .loaded = empty } } },
        .{ .summary = .{ .slug = "c", .name = "C", .updated_on = 1 }, .expanded = true, .pull_requests = .{ .settled = .{ .failed = .{ .reason = error.ServerError, .previous = null } } } },
    };
    defer nodes[1].pull_requests.settled.deinit();
    const rows = try entries(testing.allocator, &nodes, .{}, .updated);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(Entry, &.{
        .{ .repository = 0 },
        .{ .message = .{ .loading_pull_requests = 0 } },
        .{ .repository = 1 },
        .{ .message = .{ .no_pull_requests = 1 } },
        .{ .repository = 2 },
        .{ .message = .{ .pull_requests_failed = .{ .repository = 2, .reason = error.ServerError } } },
    }, rows);
    for (rows) |entry| try testing.expectEqual(entry != .message, entry.selectable());
}

test "M24 browser a Browser Start expands its Repository and focuses its PullRequest when the row appears" {
    var browser = try Browser.create(testing.allocator, try testStart("repo", 7), 10);
    defer browser.destroy();
    try testing.expectEqual(@as(usize, 1), browser.nodes.items.len);
    try testing.expect(browser.nodes.items[0].expanded);
    try testing.expectEqual(@as(?usize, 0), browser.nextWaiting());
    try testing.expectEqualStrings("repo", browser.cursor.?.repositorySlug());
    try testing.expect(browser.cursor.? == .repository);

    browser.nodes.items[0].pull_requests.request = .{ .issued = 1 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{ testPr(9, 2), testPr(7, 1) }) });
    try browser.rebuild();
    try testing.expectEqual(@as(u64, 7), browser.cursor.?.pull_request.id);
    try testing.expectEqual(@as(?usize, 2), browser.cursor_index);
    try testing.expect(browser.pending_focus == null);
}

test "M24 browser a plain Browser Start expands nothing and a missing focus falls back to its Repository" {
    var plain = try Browser.create(testing.allocator, try testStart(null, null), 10);
    defer plain.destroy();
    try testing.expectEqual(@as(usize, 0), plain.nodes.items.len);
    try testing.expect(plain.cursor == null);

    var browser = try Browser.create(testing.allocator, try testStart("repo", 7), 10);
    defer browser.destroy();
    browser.nodes.items[0].pull_requests.request = .{ .issued = 1 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{testPr(9, 2)}) });
    try browser.rebuild();
    try testing.expect(browser.cursor.? == .repository);
    try testing.expect(browser.pending_focus == null);
}

test "M24 browser a Motion skips message entries and clears the pending focus" {
    var browser = try Browser.create(testing.allocator, try testStart("repo", 7), 10);
    defer browser.destroy();
    browser.repositories.work = 1;
    try browser.rebuild();
    try testing.expect(browser.entries[1] == .message);
    browser.move(.down);
    try testing.expectEqual(@as(?usize, 0), browser.cursor_index);
    try testing.expect(browser.pending_focus == null);
}

test "M24 browser a Repository list keeps the expansion and load of a known node and drops a lost one" {
    var browser = try Browser.create(testing.allocator, try testStart("repo", null), 10);
    defer browser.destroy();
    browser.nodes.items[0].pull_requests.request = .{ .issued = 1 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{testPr(1, 1)}) });
    const first = try testRepositories(&.{ .{ .slug = "repo", .name = "Repo", .updated_on = 1 }, .{ .slug = "lost", .name = "Lost", .updated_on = 2 } });
    try browser.replaceRepositories(first);
    try browser.rebuild();
    try testing.expectEqual(@as(usize, 2), browser.nodes.items.len);
    try testing.expect(browser.nodes.items[0].expanded);
    try testing.expectEqual(@as(?usize, 1), browser.nodes.items[0].count());
    _ = browser.expand(1);
    browser.nodes.items[1].pull_requests.request = .{ .issued = 2 };
    browser.storePullRequests(1, .{ .loaded = try testPullRequests(&.{testPr(5, 1)}) });

    const second = try testRepositories(&.{.{ .slug = "repo", .name = "Repo", .updated_on = 1 }});
    try browser.replaceRepositories(second);
    try browser.rebuild();
    try testing.expectEqual(@as(usize, 1), browser.nodes.items.len);
    try testing.expect(browser.findNode("lost") == null);
}

fn expectEntriesInBounds(browser: *const Browser) !void {
    for (browser.entries) |entry| switch (entry) {
        .repository => |node| try testing.expect(node < browser.nodes.items.len),
        .pull_request => |pr| {
            try testing.expect(pr.repository < browser.nodes.items.len);
            const prs = browser.nodes.items[pr.repository].pull_requests.settled.list() orelse return error.TestUnexpectedResult;
            try testing.expect(pr.index < prs.len);
        },
        .message => {},
    };
    if (browser.cursor_index) |index| try testing.expect(index < browser.entries.len);
    try testing.expect(browser.scroll <= browser.entries.len);
}

test "M24 browser a failed rebuild after a data change leaves no Entry past the data" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var browser = try Browser.create(failing.allocator(), try testStart("repo", null), 10);
    defer browser.destroy();
    browser.nodes.items[0].pull_requests.request = .{ .issued = 1 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{ testPr(1, 1), testPr(2, 2), testPr(3, 3) }) });
    try browser.replaceRepositories(try testRepositories(&.{
        .{ .slug = "repo", .name = "Repo", .updated_on = 3 },
        .{ .slug = "b", .name = "B", .updated_on = 2 },
        .{ .slug = "c", .name = "C", .updated_on = 1 },
    }));
    try browser.rebuild();
    browser.move(.to_bottom);

    browser.nodes.items[0].pull_requests.request = .{ .issued = 2 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{testPr(1, 1)}) });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, browser.rebuild());
    try expectEntriesInBounds(browser);

    failing.fail_index = std.math.maxInt(usize);
    const list = try testRepositories(&.{.{ .slug = "repo", .name = "Repo", .updated_on = 3 }});
    try browser.replaceRepositories(list);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, browser.rebuild());
    try expectEntriesInBounds(browser);

    failing.fail_index = std.math.maxInt(usize);
    try browser.rebuild();
    try expectEntriesInBounds(browser);
    try testing.expectEqual(@as(usize, 2), browser.entries.len);
}

test "M24 browser a lost Selection after a failed rebuild lands on the row at the same index" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var browser = try Browser.create(failing.allocator(), try testStart(null, null), 10);
    defer browser.destroy();
    try browser.replaceRepositories(try testRepositories(&.{
        .{ .slug = "r0", .name = "R0", .updated_on = 4 },
        .{ .slug = "r1", .name = "R1", .updated_on = 3 },
        .{ .slug = "r2", .name = "R2", .updated_on = 2 },
        .{ .slug = "r3", .name = "R3", .updated_on = 1 },
    }));
    try browser.rebuild();
    browser.select(2);

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, browser.rebuild());
    try expectEntriesInBounds(browser);

    failing.fail_index = std.math.maxInt(usize);
    try browser.replaceRepositories(try testRepositories(&.{
        .{ .slug = "r0", .name = "R0", .updated_on = 4 },
        .{ .slug = "r1", .name = "R1", .updated_on = 3 },
        .{ .slug = "r3", .name = "R3", .updated_on = 1 },
    }));
    try browser.rebuild();
    try testing.expectEqual(@as(?usize, 2), browser.cursor_index);
    try testing.expect(browser.cursor.?.repository.eql("r3"));
}

test "M24 browser a Sort change keeps the selected Repository and moves the scroll only when its row leaves the viewport" {
    var browser = try Browser.create(testing.allocator, try testStart(null, null), 4);
    defer browser.destroy();
    try browser.replaceRepositories(try testRepositories(&.{
        .{ .slug = "r0", .name = "F", .updated_on = 6 },
        .{ .slug = "r1", .name = "e", .updated_on = 5 },
        .{ .slug = "r2", .name = "D", .updated_on = 4 },
        .{ .slug = "r3", .name = "c", .updated_on = 3 },
        .{ .slug = "r4", .name = "B", .updated_on = 2 },
        .{ .slug = "r5", .name = "a", .updated_on = 1 },
    }));
    try browser.rebuild();
    browser.select(2);
    browser.scrollBy(1);
    try testing.expectEqual(@as(usize, 1), browser.scroll);

    try browser.cycleSort();
    try testing.expectEqual(Sort.name, browser.sort);
    try testing.expectEqual(Entry{ .repository = 5 }, browser.entries[0]);
    try testing.expect(browser.cursor.?.repository.eql("r2"));
    try testing.expectEqual(@as(?usize, 3), browser.cursor_index);
    try testing.expectEqual(@as(usize, 1), browser.scroll);

    try browser.cycleSort();
    try testing.expectEqual(Sort.updated, browser.sort);
    try testing.expect(browser.cursor.?.repository.eql("r2"));
    try testing.expectEqual(@as(?usize, 2), browser.cursor_index);
    try testing.expectEqual(@as(usize, 1), browser.scroll);

    browser.select(0);
    try testing.expectEqual(@as(usize, 0), browser.scroll);
    try browser.cycleSort();
    try testing.expect(browser.cursor.?.repository.eql("r0"));
    try testing.expectEqual(@as(?usize, 5), browser.cursor_index);
    try testing.expectEqual(@as(usize, 2), browser.scroll);
}

test "M24 browser a Sort change keeps the selected PullRequest" {
    var browser = try Browser.create(testing.allocator, try testStart("repo", 7), 10);
    defer browser.destroy();
    browser.nodes.items[0].pull_requests.request = .{ .issued = 1 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{ testPr(7, 300), testPr(9, 100), testPr(8, null) }) });
    try browser.rebuild();
    try testing.expectEqual(@as(?usize, 1), browser.cursor_index);

    try browser.cycleSort();
    try testing.expectEqual(@as(u64, 7), browser.cursor.?.pull_request.id);
    try testing.expectEqual(@as(?usize, 3), browser.cursor_index);
    try testing.expectEqual(@as(u64, 9), browser.pullRequest(browser.entries[1]).?.id);
    try browser.cycleSort();
    try testing.expectEqual(@as(u64, 7), browser.cursor.?.pull_request.id);
    try testing.expectEqual(@as(?usize, 1), browser.cursor_index);
}

test "M24 browser dates format as UTC days" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2026-10-30", formatDate(&buf, 1793318400).?);
    try testing.expectEqualStrings("1970-01-01", formatDate(&buf, 0).?);
    try testing.expect(formatDate(&buf, null) == null);
    try testing.expect(formatDate(&buf, -1) == null);
    try testing.expectEqualStrings("9999-12-31", formatDate(&buf, 253402300799).?);
    try testing.expect(formatDate(&buf, 253402300800) == null);
    try testing.expect(formatDate(&buf, 1 << 50) == null);
    try testing.expect(formatDate(&buf, std.math.maxInt(i64)) == null);
}

test "M24 browser failure keeps ApiError names and maps other errors" {
    try testing.expectEqual(@as(Failure, error.RateLimited), failure(error.RateLimited));
    try testing.expectEqual(@as(Failure, error.OutOfMemory), failure(error.OutOfMemory));
    try testing.expectEqual(@as(Failure, error.ConnectionFailed), failure(error.ConnectionResetByPeer));
}

test "M24 cache the Summary Cache fills only nodes with no settled list and copies its PullRequests" {
    var browser = try Browser.create(testing.allocator, try testStart("repo", null), 10);
    defer browser.destroy();
    browser.nodes.items[0].pull_requests.request = .{ .issued = 1 };
    browser.storePullRequests(0, .{ .loaded = try testPullRequests(&.{testPr(1, 1)}) });

    const cache = try CachedSummaries.create(testing.allocator);
    const a = cache.arena.allocator();
    cache.snapshot = .{ .workspace = "check24", .repositories = try a.dupe(summary_cache.Repository, &.{
        .{ .summary = .{ .slug = "repo", .name = "Repo", .updated_on = 4 }, .pull_requests = try a.dupe(PullRequestSummary, &.{testPr(9, 1)}) },
        .{ .summary = .{ .slug = "api", .name = "API", .updated_on = 3 }, .pull_requests = try a.dupe(PullRequestSummary, &.{testPr(5, 1)}) },
    }) };
    try browser.fillFromCache(cache);
    try testing.expectEqualStrings("Repo", browser.nodes.items[0].summary.name);
    try testing.expect(browser.nodes.items[0].pull_requests.settled == .loaded);
    try testing.expectEqual(@as(u64, 1), browser.nodes.items[0].pull_requests.settled.list().?[0].id);
    const api = browser.findNode("api").?;
    try testing.expect(browser.nodes.items[api].pull_requests.settled == .cached);

    try browser.replaceRepositories(try testRepositories(&.{.{ .slug = "api", .name = "API", .updated_on = 3 }}));
    try testing.expect(browser.cached == null);
    try testing.expectEqual(@as(u64, 5), browser.nodes.items[0].pull_requests.settled.list().?[0].id);
}
