//! Presentation — the deterministic state-transition seam between terminal
//! mechanics and the coherent review state the renderer projects (ADR-0012).

const std = @import("std");
const bbr = @import("bbr");
const session_mod = @import("session.zig");
const ArenaRing = @import("arena_ring.zig").ArenaRing;
const Nav = @import("nav.zig").Nav;

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

pub const SessionEpoch = u64;
pub const LoadIntent = u64;

/// Repository-qualified identity copied by value into commands and state. The
/// fixed storage keeps the first command protocol self-owned without exposing
/// another allocator lifetime to the terminal adapter.
pub const ReviewKey = struct {
    workspace_buf: [128]u8 = undefined,
    workspace_len: u8,
    repository_buf: [256]u8 = undefined,
    repository_len: u16,
    pull_request_id: u64,

    pub fn init(workspace_name: []const u8, repository_name: []const u8, pull_request_id: u64) error{NameTooLong}!ReviewKey {
        if (workspace_name.len > 128 or repository_name.len > 256) return error.NameTooLong;
        var key: ReviewKey = .{
            .workspace_len = @intCast(workspace_name.len),
            .repository_len = @intCast(repository_name.len),
            .pull_request_id = pull_request_id,
        };
        @memcpy(key.workspace_buf[0..workspace_name.len], workspace_name);
        @memcpy(key.repository_buf[0..repository_name.len], repository_name);
        return key;
    }

    pub fn workspace(self: *const ReviewKey) []const u8 {
        return self.workspace_buf[0..self.workspace_len];
    }

    pub fn repository(self: *const ReviewKey) []const u8 {
        return self.repository_buf[0..self.repository_len];
    }

    pub fn eql(a: ReviewKey, b: ReviewKey) bool {
        return a.pull_request_id == b.pull_request_id and
            std.mem.eql(u8, a.workspace(), b.workspace()) and
            std.mem.eql(u8, a.repository(), b.repository());
    }

    fn storeKey(self: *const ReviewKey) bbr.review.ReviewKey {
        return .{
            .workspace = self.workspace(),
            .repository = self.repository(),
            .pull_request_id = self.pull_request_id,
        };
    }
};

pub const Dependencies = struct {
    reviews: bbr.review.PendingReviewStore,
};

pub const InitialReview = struct {
    key: ReviewKey,
    session: *Session,
};

pub const Boot = struct {
    initial: ?InitialReview = null,
    viewport_rows: usize,
};

pub const SessionLoadOutcome = union(enum) {
    loaded: *Session,
    failed: anyerror,
};

pub const SessionLoaded = struct {
    intent: LoadIntent,
    outcome: SessionLoadOutcome,
};

pub const OwnedInput = union(enum) {
    choose_pull_request: ReviewKey,
    session_loaded: SessionLoaded,
    push_count_digit: u8,
    resize_viewport: usize,
    review_action: ReviewAction,
    request_shutdown,
};

/// Session-relative actions whose complete state is Navigation. They are
/// suspended while a replacement is pending, along with every other Action
/// that depends on the currently published review.
pub const ReviewAction = enum {
    down,
    up,
    half_page_down,
    half_page_up,
    page_down,
    page_up,
    to_top,
    to_bottom,
    center,
    scroll_cursor_top,
    scroll_cursor_bottom,
    cursor_view_top,
    cursor_view_middle,
    cursor_view_bottom,
    select_down,
    select_up,
    toggle_selection,
    clear_selection,
};

pub const LoadSession = struct {
    intent: LoadIntent,
    key: ReviewKey,
};

pub const OwnedCommand = union(enum) {
    load_session: LoadSession,
};

pub const NavigationProjection = struct {
    cursor: usize,
    scroll: usize,
    count: usize,
    mark: ?usize,
};

pub const ReviewProjection = struct {
    key: ReviewKey,
    session_epoch: SessionEpoch,
    pull_request: *const bbr.bitbucket.PullRequest,
    diff: *const bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    buffer: bbr.diff.Buffer,
    navigation: NavigationProjection,
};

pub const Projection = struct {
    review: ?ReviewProjection,
    replacing: bool,
    replacement_error: ?ReplacementError,
    shutting_down: bool,
};

pub const ReplacementError = enum {
    session_load_failed,
    pending_review_load_failed,
    buffer_build_failed,
    out_of_memory,
};

const Published = struct {
    allocator: Allocator,
    key: ReviewKey,
    epoch: SessionEpoch,
    session: *Session,
    review_arena: std.heap.ArenaAllocator,
    review: bbr.review.PendingReview,
    buffers: ArenaRing(2),
    buffer: bbr.diff.Buffer,
    navigation: Nav,

    fn create(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        key: ReviewKey,
        epoch: SessionEpoch,
        session: *Session,
        viewport_rows: usize,
    ) !*Published {
        const published = try allocator.create(Published);
        errdefer allocator.destroy(published);
        errdefer session.destroy();

        published.allocator = allocator;
        published.key = key;
        published.epoch = epoch;
        published.session = session;
        published.review_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer published.review_arena.deinit();
        published.review = store.loadReview(published.review_arena.allocator(), key.storeKey()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.PendingReviewLoadFailed;
        };
        published.buffers = ArenaRing(2).init(allocator);
        errdefer published.buffers.deinit();

        const buffer_allocator = published.buffers.begin();
        errdefer published.buffers.abort();
        const enrichment = session.enrichment.projection();
        published.buffer = bbr.diff.buffer.buildWithComments(
            buffer_allocator,
            session.diff,
            .unified,
            session.threads,
            .{
                .drafts = published.review.drafts.items,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
            },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BufferBuildFailed;
        };
        published.buffers.commit();
        published.navigation = Nav.init(published.buffer.rows.len, viewport_rows);
        return published;
    }

    fn destroy(self: *Published) void {
        const allocator = self.allocator;
        self.buffers.deinit();
        self.review_arena.deinit();
        self.session.destroy();
        allocator.destroy(self);
    }

    fn projection(self: *const Published) ReviewProjection {
        return .{
            .key = self.key,
            .session_epoch = self.epoch,
            .pull_request = &self.session.pr,
            .diff = &self.session.diff,
            .threads = self.session.threads,
            .drafts = self.review.drafts.items,
            .buffer = self.buffer,
            .navigation = .{
                .cursor = self.navigation.cursor,
                .scroll = self.navigation.scroll,
                .count = self.navigation.count,
                .mark = self.navigation.mark,
            },
        };
    }
};

const Replacement = struct {
    intent: LoadIntent,
    key: ReviewKey,
};

pub const Presentation = struct {
    allocator: Allocator,
    dependencies: Dependencies,
    viewport_rows: usize,
    published: ?*Published = null,
    replacement: ?Replacement = null,
    next_intent: LoadIntent = 0,
    next_session_epoch: SessionEpoch = 0,
    commands: std.ArrayList(OwnedCommand) = .empty,
    outstanding_loads: usize = 0,
    shutdown_requested: bool = false,
    replacement_error: ?ReplacementError = null,

    pub fn init(allocator: Allocator, dependencies: Dependencies, boot: Boot) !Presentation {
        var self: Presentation = .{
            .allocator = allocator,
            .dependencies = dependencies,
            .viewport_rows = boot.viewport_rows,
        };
        errdefer self.deinit();
        if (boot.initial) |initial| {
            self.next_session_epoch = 1;
            self.published = try Published.create(
                allocator,
                dependencies.reviews,
                initial.key,
                self.next_session_epoch,
                initial.session,
                boot.viewport_rows,
            );
        }
        return self;
    }

    pub fn deinit(self: *Presentation) void {
        if (self.published) |published| published.destroy();
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    /// The sole mutation entry point. Candidate construction consumes a loaded
    /// Session whether it commits, fails, or proves stale.
    pub fn dispatch(self: *Presentation, input: OwnedInput) !void {
        switch (input) {
            .choose_pull_request => |key| if (!self.shutdown_requested) try self.choosePullRequest(key),
            .session_loaded => |completed| self.acceptLoadedSession(completed),
            .push_count_digit => |digit| self.pushCountDigit(digit),
            .resize_viewport => |rows| self.resizeViewport(rows),
            .review_action => |action| self.applyReviewAction(action),
            .request_shutdown => self.requestShutdown(),
        }
    }

    pub fn takeCommand(self: *Presentation) ?OwnedCommand {
        if (self.commands.items.len == 0) return null;
        const command = self.commands.orderedRemove(0);
        self.outstanding_loads += 1;
        return command;
    }

    pub fn projection(self: *const Presentation) Projection {
        return .{
            .review = if (self.published) |published| published.projection() else null,
            .replacing = self.replacement != null,
            .replacement_error = self.replacement_error,
            .shutting_down = self.shutdown_requested,
        };
    }

    pub fn readyToExit(self: *const Presentation) bool {
        return self.shutdown_requested and self.commands.items.len == 0 and self.outstanding_loads == 0;
    }

    fn requestShutdown(self: *Presentation) void {
        self.shutdown_requested = true;
        self.commands.clearRetainingCapacity();
        self.replacement = null;
    }

    fn pushCountDigit(self: *Presentation, digit: u8) void {
        if (self.shutdown_requested or self.replacement != null) return;
        if (self.published) |published| published.navigation.pushDigit(digit);
    }

    fn resizeViewport(self: *Presentation, rows: usize) void {
        self.viewport_rows = rows;
        if (self.published) |published| published.navigation.setViewport(rows);
    }

    fn applyReviewAction(self: *Presentation, action: ReviewAction) void {
        if (self.shutdown_requested or self.replacement != null) return;
        const published = self.published orelse return;
        switch (action) {
            .down => published.navigation.down(),
            .up => published.navigation.up(),
            .half_page_down => published.navigation.halfPageDown(),
            .half_page_up => published.navigation.halfPageUp(),
            .page_down => published.navigation.pageDown(),
            .page_up => published.navigation.pageUp(),
            .to_top => published.navigation.toTop(),
            .to_bottom => published.navigation.toBottom(),
            .center => published.navigation.center(),
            .scroll_cursor_top => published.navigation.scrollCursorTop(),
            .scroll_cursor_bottom => published.navigation.scrollCursorBottom(),
            .cursor_view_top => published.navigation.cursorToViewTop(),
            .cursor_view_middle => published.navigation.cursorToViewMiddle(),
            .cursor_view_bottom => published.navigation.cursorToViewBottom(),
            .select_down => {
                published.navigation.ensureMark();
                published.navigation.down();
            },
            .select_up => {
                published.navigation.ensureMark();
                published.navigation.up();
            },
            .toggle_selection => published.navigation.toggleMark(),
            .clear_selection => published.navigation.clearMark(),
        }
    }

    fn choosePullRequest(self: *Presentation, key: ReviewKey) !void {
        if (self.published) |published| {
            if (ReviewKey.eql(published.key, key)) {
                self.next_intent += 1; // invalidate a candidate already in flight
                self.replacement = null;
                self.replacement_error = null;
                self.commands.clearRetainingCapacity();
                return;
            }
        }

        const intent = self.next_intent + 1;
        // Reserve before changing either the queued command or replacement
        // intent. Once one slot exists, superseding a not-yet-started load is
        // allocation-free and cannot strand Presentation in `.replacing`.
        try self.commands.ensureTotalCapacity(self.allocator, 1);
        // Commands not yet transferred to the terminal adapter are still ours
        // to supersede. Already-taken commands complete normally and are
        // rejected later by their LoadIntent.
        self.commands.clearRetainingCapacity();
        self.commands.appendAssumeCapacity(.{ .load_session = .{ .intent = intent, .key = key } });
        self.next_intent = intent;
        self.replacement = .{ .intent = intent, .key = key };
        self.replacement_error = null;
    }

    fn acceptLoadedSession(self: *Presentation, completed: SessionLoaded) void {
        if (self.outstanding_loads > 0) self.outstanding_loads -= 1;
        const replacement = self.replacement orelse {
            if (completed.outcome == .loaded) completed.outcome.loaded.destroy();
            return;
        };
        if (replacement.intent != completed.intent) {
            if (completed.outcome == .loaded) completed.outcome.loaded.destroy();
            return;
        }

        switch (completed.outcome) {
            .failed => |err| {
                self.replacement = null;
                self.replacement_error = if (err == error.OutOfMemory) .out_of_memory else .session_load_failed;
            },
            .loaded => |session| {
                const epoch = self.next_session_epoch + 1;
                const candidate = Published.create(
                    self.allocator,
                    self.dependencies.reviews,
                    replacement.key,
                    epoch,
                    session,
                    self.viewport_rows,
                ) catch |err| {
                    self.replacement = null;
                    self.replacement_error = switch (err) {
                        error.OutOfMemory => .out_of_memory,
                        error.PendingReviewLoadFailed => .pending_review_load_failed,
                        error.BufferBuildFailed => .buffer_build_failed,
                    };
                    return;
                };

                const previous = self.published;
                self.published = candidate;
                self.next_session_epoch = epoch;
                self.replacement = null;
                self.replacement_error = null;
                if (previous) |published| published.destroy();
            },
        }
    }
};

const testing = std.testing;

fn testSession(backing: std.mem.Allocator, id: u64, marker: u8) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    const raw = try std.fmt.allocPrint(
        a,
        "diff --git a/{c}.zig b/{c}.zig\n--- a/{c}.zig\n+++ b/{c}.zig\n@@ -1 +1 @@\n-old\n+new\n",
        .{ marker, marker, marker, marker },
    );
    s.pr = .{
        .id = id,
        .title = try std.fmt.allocPrint(a, "PR {d}", .{id}),
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.diff = try bbr.diff.parse(a, raw);
    try s.initializeEnrichment();
    return s;
}

test "failed replacement Buffer construction preserves the published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const a = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(failing.allocator(), .{
        .reviews = store.store(),
    }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = a },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    const before = presentation.projection().review.?;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;

    const candidate = try testSession(testing.allocator, 2, 'b');
    failing.fail_index = failing.alloc_index + 1; // Published allocation succeeds; Buffer allocation fails.
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = candidate },
    } });

    try testing.expect(failing.has_induced_failure);
    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 1), after.review.?.pull_request.id);
    try testing.expectEqual(before.session_epoch, after.review.?.session_epoch);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, after.review.?.navigation));
    try testing.expectEqual(ReplacementError.out_of_memory, after.replacement_error.?);
}

test "only the latest queued replacement command is exposed" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{
        .reviews = store.store(),
    }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 3) });

    const command = presentation.takeCommand().?.load_session;
    try testing.expectEqual(@as(u64, 3), command.key.pull_request_id);
    try testing.expect(presentation.takeCommand() == null);
}

test "a complete candidate publishes atomically and advances the Session Epoch" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });

    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 2), after.review.?.pull_request.id);
    try testing.expectEqual(before.session_epoch + 1, after.review.?.session_epoch);
    try testing.expect(after.review.?.buffer.rows.ptr != before.buffer.rows.ptr);
    try testing.expect(!after.replacing);
    try testing.expect(after.replacement_error == null);
}

test "a stale candidate is disposed and the latest failure restores the exact published review" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    const initial = try testSession(testing.allocator, 1, 'a');
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = try ReviewKey.init("workspace", "repo", 1), .session = initial },
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    const before = presentation.projection().review.?;

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const b = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 3) });
    const c = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = b.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = c.intent,
        .outcome = .{ .failed = error.NotFound },
    } });

    const after = presentation.projection();
    try testing.expectEqual(@as(u64, 1), after.review.?.pull_request.id);
    try testing.expectEqual(before.session_epoch, after.review.?.session_epoch);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, after.review.?.navigation));
    try testing.expectEqual(ReplacementError.session_load_failed, after.replacement_error.?);
}

test "shutdown drains issued loads and disposes their late completions" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();

    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .viewport_rows = 24,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 1) });
    const command = presentation.takeCommand().?.load_session;

    try presentation.dispatch(.request_shutdown);
    try testing.expect(!presentation.readyToExit());
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 1, 'a') },
    } });

    try testing.expect(presentation.readyToExit());
    try testing.expect(presentation.projection().review == null);
}

test "Navigation and Count mutate only through dispatch" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .push_count_digit = 2 });
    try presentation.dispatch(.{ .review_action = .down });
    try testing.expectEqual(@as(usize, 2), presentation.projection().review.?.navigation.cursor);
    try presentation.dispatch(.{ .review_action = .toggle_selection });
    try presentation.dispatch(.{ .review_action = .up });
    const navigation = presentation.projection().review.?.navigation;
    try testing.expectEqual(@as(usize, 1), navigation.cursor);
    try testing.expectEqual(@as(?usize, 2), navigation.mark);
}

test "Session-relative Navigation is suspended during replacement" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .review_action = .down });
    const before = presentation.projection().review.?.navigation;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    try presentation.dispatch(.{ .review_action = .down });
    try presentation.dispatch(.{ .push_count_digit = 9 });
    try testing.expect(std.meta.eql(before, presentation.projection().review.?.navigation));
}
