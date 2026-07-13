//! Presentation — the deterministic state-transition seam between terminal
//! mechanics and the coherent review state the renderer projects (ADR-0012).

const std = @import("std");
const bbr = @import("bbr");
const session_mod = @import("session.zig");
const ArenaRing = @import("arena_ring.zig").ArenaRing;
const Nav = @import("nav.zig").Nav;
const composer_mod = @import("composer.zig");
const Composer = composer_mod.Composer;

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
    action: Action,
    composer: ComposerInput,
    request_shutdown,
};

pub const TextChunk = struct {
    bytes: [64]u8 = undefined,
    len: u8,

    pub fn init(text: []const u8) error{TextTooLong}!TextChunk {
        if (text.len > 64) return error.TextTooLong;
        var chunk: TextChunk = .{ .len = @intCast(text.len) };
        @memcpy(chunk.bytes[0..text.len], text);
        return chunk;
    }

    pub fn slice(self: *const TextChunk) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ComposerInput = union(enum) {
    insert: TextChunk,
    newline,
    backspace,
    delete_word,
    delete_to_line_start,
    cancel,
    save,
};

/// Session-relative actions whose complete state is Navigation. They are
/// suspended while a replacement is pending, along with every other Action
/// that depends on the currently published review.
pub const Action = enum {
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
    quit,
    open_picker,
    comment,
    inline_comment,
    suggest,
    reply,
    submit,
    help,
    toggle_select,
    clear_selection,
    toggle_resolved,
    toggle_layout,
    cycle_scope,
    isolate,
    next_file,
    prev_file,
    expand_fold,
};

pub const Scope = enum {
    changes,
    fetched,
    whole,

    fn next(self: Scope) Scope {
        return switch (self) {
            .changes => .fetched,
            .fetched => .whole,
            .whole => .changes,
        };
    }
};

pub const Preferences = struct {
    layout: bbr.diff.Layout = .unified,
    scope: Scope = .changes,
    show_resolved: bool = false,
};

pub const LoadSession = struct {
    intent: LoadIntent,
    key: ReviewKey,
};

pub const OwnedCommand = union(enum) {
    load_session: LoadSession,
};

pub const ReviewProjection = struct {
    key: ReviewKey,
    session_epoch: SessionEpoch,
    pull_request: *const bbr.bitbucket.PullRequest,
    diff: *const bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    buffer: bbr.diff.Buffer,
    /// A value snapshot. Mutating this copy cannot affect Presentation.
    navigation: Nav,
    preferences: Preferences,
    isolated_file: ?usize,
};

pub const Projection = struct {
    review: ?ReviewProjection,
    composer: ?ComposerProjection,
    replacing: bool,
    replacement_error: ?ReplacementError,
    action_error: ?ActionError,
    shutting_down: bool,
};

pub const ComposerProjection = struct {
    label: []const u8,
    body: []const u8,
};

pub const ActionError = enum {
    action_refused,
    buffer_build_failed,
    invalid_selection,
    out_of_memory,
    persistence_failed,
};

const BufferTransactionError = error{ BufferBuildFailed, OutOfMemory };

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
    expanded_folds: std.ArrayList(*const bbr.diff.Line),
    isolated_file: ?usize,
    composer_arena: std.heap.ArenaAllocator,
    composer: ?Composer,

    fn create(
        allocator: Allocator,
        store: bbr.review.PendingReviewStore,
        key: ReviewKey,
        epoch: SessionEpoch,
        session: *Session,
        viewport_rows: usize,
        preferences: Preferences,
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
        published.expanded_folds = .empty;
        errdefer published.expanded_folds.deinit(allocator);
        published.isolated_file = null;
        published.composer_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer published.composer_arena.deinit();
        published.composer = null;

        const buffer_allocator = published.buffers.begin();
        errdefer published.buffers.abort();
        const enrichment = session.enrichment.projection();
        published.buffer = bbr.diff.buffer.buildWithComments(
            buffer_allocator,
            session.diff,
            preferences.layout,
            session.threads,
            .{
                .drafts = published.review.drafts.items,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
                .show_resolved = preferences.show_resolved,
                .fold_context = preferences.scope == .changes,
                .whole_file = preferences.scope == .whole,
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
        if (self.composer) |*composer| composer.deinit();
        self.composer_arena.deinit();
        self.expanded_folds.deinit(allocator);
        self.buffers.deinit();
        self.review_arena.deinit();
        self.session.destroy();
        allocator.destroy(self);
    }

    fn projection(self: *const Published, preferences: Preferences) ReviewProjection {
        return .{
            .key = self.key,
            .session_epoch = self.epoch,
            .pull_request = &self.session.pr,
            .diff = &self.session.diff,
            .threads = self.session.threads,
            .drafts = self.review.drafts.items,
            .buffer = self.buffer,
            .navigation = self.navigation,
            .preferences = preferences,
            .isolated_file = self.isolated_file,
        };
    }

    fn rebuild(
        self: *Published,
        preferences: Preferences,
        expanded_folds: []const *const bbr.diff.Line,
        isolated_file: ?usize,
    ) BufferTransactionError!void {
        const candidate = try self.stageBuffer(preferences, expanded_folds, isolated_file);
        self.buffers.commit();
        self.buffer = candidate;
        self.navigation.setRowCount(candidate.rows.len);
    }

    /// Begin and populate the inactive Buffer generation. The caller must
    /// commit it or abort it after any additional fallible work.
    fn stageBuffer(
        self: *Published,
        preferences: Preferences,
        expanded_folds: []const *const bbr.diff.Line,
        isolated_file: ?usize,
    ) BufferTransactionError!bbr.diff.Buffer {
        const allocator = self.buffers.begin();
        errdefer self.buffers.abort();
        const enrichment = self.session.enrichment.projection();
        const candidate = bbr.diff.buffer.buildWithComments(
            allocator,
            self.session.diff,
            preferences.layout,
            self.session.threads,
            .{
                .show_resolved = preferences.show_resolved,
                .fold_context = preferences.scope == .changes,
                .whole_file = preferences.scope == .whole,
                .expanded = expanded_folds,
                .drafts = self.review.drafts.items,
                .only_file = isolated_file,
                .blobs = enrichment.blobs,
                .highlights = enrichment.highlights,
            },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BufferBuildFailed;
        };
        return candidate;
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
    preferences: Preferences = .{},
    published: ?*Published = null,
    replacement: ?Replacement = null,
    next_intent: LoadIntent = 0,
    next_session_epoch: SessionEpoch = 0,
    commands: std.ArrayList(OwnedCommand) = .empty,
    outstanding_loads: usize = 0,
    shutdown_requested: bool = false,
    replacement_error: ?ReplacementError = null,
    action_error: ?ActionError = null,

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
                self.preferences,
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
            .action => |action| self.applyAction(action),
            .composer => |composer_input| self.applyComposerInput(composer_input),
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
            .review = if (self.published) |published| published.projection(self.preferences) else null,
            .composer = if (self.published) |published| if (published.composer) |*composer| .{
                .label = composer.request.label,
                .body = composer.body(),
            } else null else null,
            .replacing = self.replacement != null,
            .replacement_error = self.replacement_error,
            .action_error = self.action_error,
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

    fn applyAction(self: *Presentation, action: Action) void {
        if (action == .quit) {
            self.requestShutdown();
            return;
        }
        if (self.shutdown_requested or self.replacement != null) return;
        const published = self.published orelse return;
        self.action_error = null;
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
            .toggle_select => published.navigation.toggleMark(),
            .clear_selection => published.navigation.clearMark(),
            .toggle_resolved => {
                var candidate = self.preferences;
                candidate.show_resolved = !candidate.show_resolved;
                self.publishPreferences(published, candidate);
            },
            .toggle_layout => {
                var candidate = self.preferences;
                candidate.layout = if (candidate.layout == .unified) .side_by_side else .unified;
                self.publishPreferences(published, candidate);
            },
            .cycle_scope => {
                var candidate = self.preferences;
                candidate.scope = candidate.scope.next();
                published.rebuild(candidate, &.{}, published.isolated_file) catch |err| {
                    self.action_error = normalizeActionError(err);
                    return;
                };
                self.preferences = candidate;
                published.expanded_folds.clearRetainingCapacity();
                self.action_error = null;
            },
            .isolate => self.toggleIsolation(published),
            .next_file => self.moveFile(published, 1),
            .prev_file => self.moveFile(published, -1),
            .expand_fold => self.expandFold(published),
            .comment => self.openComposer(published, .{ .kind = .top_level, .label = "New comment" }),
            .reply => self.openReplyComposer(published),
            .inline_comment => self.openInlineComposer(published, .inline_comment),
            .suggest => self.openInlineComposer(published, .suggestion),
            .open_picker,
            .submit,
            .help,
            => {},
            .quit => unreachable,
        }
    }

    fn openComposer(self: *Presentation, published: *Published, request: composer_mod.Request) void {
        if (published.composer != null) return;
        _ = published.composer_arena.reset(.retain_capacity);
        published.composer = Composer.init(published.composer_arena.allocator(), request);
        self.action_error = null;
    }

    fn openReplyComposer(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) {
            self.action_error = .action_refused;
            return;
        }
        const parent: bbr.review.draft.Parent = switch (published.buffer.rows[published.navigation.cursor]) {
            .comment => |row| .{ .comment = row.comment.id },
            .draft => |row| .{ .draft = row.draft.local_id },
            else => {
                self.action_error = .action_refused;
                return;
            },
        };
        self.openComposer(published, .{ .kind = .reply, .parent = parent, .label = "Reply" });
    }

    fn openInlineComposer(self: *Presentation, published: *Published, kind: bbr.review.DraftKind) void {
        if (published.composer != null) return;
        if (published.navigation.cursor >= published.buffer.rows.len) {
            self.action_error = .action_refused;
            return;
        }
        const file_index = published.isolated_file orelse fileIndexForRow(published.buffer, published.navigation.cursor);
        if (file_index >= published.session.diff.files.len) {
            self.action_error = .action_refused;
            return;
        }

        _ = published.composer_arena.reset(.retain_capacity);
        const allocator = published.composer_arena.allocator();
        var lines: std.ArrayList(*const bbr.diff.Line) = .empty;
        if (published.navigation.selection()) |selection| {
            collectSelectedLines(published.buffer, selection[0], selection[1], &lines, allocator) catch {
                self.action_error = .invalid_selection;
                return;
            };
        } else if (lineAtRow(published.buffer.rows[published.navigation.cursor])) |line| {
            lines.append(allocator, line) catch {
                self.action_error = .out_of_memory;
                return;
            };
        }
        const span = spanFromLines(lines.items, kind == .suggestion) catch {
            self.action_error = .invalid_selection;
            return;
        };
        const path = published.session.diff.files[file_index].new_path;
        const anchor: bbr.review.Anchor = .{
            .path = allocator.dupe(u8, path) catch {
                self.action_error = .out_of_memory;
                return;
            },
            .from = span.from,
            .to = span.to,
            .start_from = span.start_from,
            .start_to = span.start_to,
            .commit = allocator.dupe(u8, published.session.pr.source_commit) catch {
                self.action_error = .out_of_memory;
                return;
            },
        };
        const noun = if (kind == .suggestion) "Suggest on" else "Comment on";
        const bottom = span.to orelse span.from orelse 0;
        const top = span.start_to orelse span.start_from;
        const label = (if (top) |first|
            std.fmt.allocPrint(allocator, "{s} {s}:{d}-{d}", .{ noun, path, first, bottom })
        else
            std.fmt.allocPrint(allocator, "{s} {s}:{d}", .{ noun, path, bottom })) catch {
            self.action_error = .out_of_memory;
            return;
        };
        published.composer = Composer.init(allocator, .{ .kind = kind, .anchor = anchor, .label = label });
        if (kind == .suggestion) {
            var seed: std.ArrayList(u8) = .empty;
            for (lines.items, 0..) |line, index| {
                if (index > 0) seed.append(allocator, '\n') catch {
                    published.composer = null;
                    self.action_error = .out_of_memory;
                    return;
                };
                seed.appendSlice(allocator, line.text) catch {
                    published.composer = null;
                    self.action_error = .out_of_memory;
                    return;
                };
            }
            published.composer.?.seed(seed.items) catch {
                published.composer = null;
                self.action_error = .out_of_memory;
                return;
            };
        }
        published.navigation.clearMark();
        self.action_error = null;
    }

    fn applyComposerInput(self: *Presentation, composer_input: ComposerInput) void {
        if (self.shutdown_requested or self.replacement != null) return;
        const published = self.published orelse return;
        const composer = if (published.composer) |*value| value else return;
        switch (composer_input) {
            .insert => |chunk| {
                composer.insert(chunk.slice()) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                self.action_error = null;
            },
            .newline => {
                composer.newline() catch {
                    self.action_error = .out_of_memory;
                    return;
                };
                self.action_error = null;
            },
            .backspace => {
                composer.backspace();
                self.action_error = null;
            },
            .delete_word => {
                composer.deleteWord();
                self.action_error = null;
            },
            .delete_to_line_start => {
                composer.deleteToLineStart();
                self.action_error = null;
            },
            .cancel => {
                composer.deinit();
                published.composer = null;
                self.action_error = null;
            },
            .save => self.saveComposer(published),
        }
    }

    fn saveComposer(self: *Presentation, published: *Published) void {
        const composer = if (published.composer) |*value| value else return;
        if (composer.isBlank()) return;
        const review_allocator = published.review_arena.allocator();
        published.review.drafts.ensureUnusedCapacity(review_allocator, 1) catch {
            self.action_error = .out_of_memory;
            return;
        };

        const new_draft = composer.toNewDraft();
        var draft: bbr.review.Draft = .{
            .local_id = published.review.next_id,
            .kind = new_draft.kind,
            .target = new_draft.target,
            .parent = new_draft.parent,
            .body = (if (new_draft.kind == .suggestion)
                std.fmt.allocPrint(review_allocator, "```suggestion\n{s}\n```", .{new_draft.body})
            else
                review_allocator.dupe(u8, new_draft.body)) catch {
                self.action_error = .out_of_memory;
                return;
            },
        };
        if (new_draft.anchor) |anchor| {
            draft.anchor = anchor;
            draft.anchor.?.path = review_allocator.dupe(u8, anchor.path) catch {
                self.action_error = .out_of_memory;
                return;
            };
            if (anchor.commit) |commit| {
                draft.anchor.?.commit = review_allocator.dupe(u8, commit) catch {
                    self.action_error = .out_of_memory;
                    return;
                };
            }
        }

        published.review.drafts.appendAssumeCapacity(draft);
        published.review.next_id += 1;
        const previous_len = published.review.drafts.items.len - 1;
        const candidate = published.stageBuffer(self.preferences, published.expanded_folds.items, published.isolated_file) catch |err| {
            published.review.drafts.shrinkRetainingCapacity(previous_len);
            published.review.next_id -= 1;
            self.action_error = normalizeActionError(err);
            return;
        };

        self.dependencies.reviews.put(published.key.storeKey(), draft) catch {
            published.buffers.abort();
            published.review.drafts.shrinkRetainingCapacity(previous_len);
            published.review.next_id -= 1;
            self.action_error = .persistence_failed;
            return;
        };
        published.buffers.commit();
        published.buffer = candidate;
        published.navigation.setRowCount(candidate.rows.len);
        composer.deinit();
        published.composer = null;
        self.action_error = null;
    }

    fn publishPreferences(self: *Presentation, published: *Published, candidate: Preferences) void {
        published.rebuild(candidate, published.expanded_folds.items, published.isolated_file) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        self.preferences = candidate;
        self.action_error = null;
    }

    fn toggleIsolation(self: *Presentation, published: *Published) void {
        if (published.session.diff.files.len == 0) return;
        const previous = published.isolated_file;
        const candidate = if (previous) |_| null else fileIndexForRow(published.buffer, published.navigation.cursor);
        published.rebuild(self.preferences, published.expanded_folds.items, candidate) catch |err| {
            self.action_error = normalizeActionError(err);
            return;
        };
        published.isolated_file = candidate;
        if (previous) |file_index| {
            if (fileHeaderRow(published.buffer, file_index)) |row| published.navigation.jumpTo(row);
        } else {
            published.navigation = Nav.init(published.buffer.rows.len, self.viewport_rows);
        }
        self.action_error = null;
    }

    fn moveFile(self: *Presentation, published: *Published, direction: i2) void {
        if (published.isolated_file) |current| {
            const candidate = if (direction > 0)
                if (current + 1 < published.session.diff.files.len) current + 1 else return
            else if (current > 0)
                current - 1
            else
                return;
            published.rebuild(self.preferences, published.expanded_folds.items, candidate) catch |err| {
                self.action_error = normalizeActionError(err);
                return;
            };
            published.isolated_file = candidate;
            published.navigation = Nav.init(published.buffer.rows.len, self.viewport_rows);
            self.action_error = null;
            return;
        }
        const row = if (direction > 0)
            nextFileHeaderRow(published.buffer, published.navigation.cursor)
        else
            previousFileHeaderRow(published.buffer, published.navigation.cursor);
        if (row) |target| published.navigation.jumpTo(target);
    }

    fn expandFold(self: *Presentation, published: *Published) void {
        if (published.navigation.cursor >= published.buffer.rows.len) return;
        if (published.buffer.rows[published.navigation.cursor] != .fold) return;
        const old_len = published.expanded_folds.items.len;
        published.expanded_folds.append(self.allocator, published.buffer.rows[published.navigation.cursor].fold.id) catch {
            self.action_error = .out_of_memory;
            return;
        };
        published.rebuild(self.preferences, published.expanded_folds.items, published.isolated_file) catch |err| {
            published.expanded_folds.shrinkRetainingCapacity(old_len);
            self.action_error = normalizeActionError(err);
            return;
        };
        self.action_error = null;
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
                    self.preferences,
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
                self.action_error = null;
                if (previous) |published| published.destroy();
            },
        }
    }
};

fn normalizeActionError(err: BufferTransactionError) ActionError {
    return switch (err) {
        error.BufferBuildFailed => .buffer_build_failed,
        error.OutOfMemory => .out_of_memory,
    };
}

fn lineAtRow(row: bbr.diff.buffer.Row) ?*const bbr.diff.Line {
    return switch (row) {
        .line => |line| line.line,
        .line_pair => |pair| if (pair.right) |right| right.line else if (pair.left) |left| left.line else null,
        else => null,
    };
}

const AnchorSpan = struct {
    from: ?u32 = null,
    to: ?u32 = null,
    start_from: ?u32 = null,
    start_to: ?u32 = null,
};

fn spanFromLines(lines: []const *const bbr.diff.Line, suggestion: bool) !AnchorSpan {
    if (lines.len == 0) return error.NotOnALine;
    var all_new = true;
    var all_old = true;
    for (lines) |line| {
        if (line.new_no == null) all_new = false;
        if (line.old_no == null) all_old = false;
    }
    if (!all_new and !all_old) return error.MixedSides;
    if (all_new) {
        for (lines[1..], 1..) |line, index| {
            if (line.new_no.? != lines[index - 1].new_no.? + 1) return error.NonContiguous;
        }
        const last = lines[lines.len - 1].new_no.?;
        return if (lines.len == 1) .{ .to = last } else .{ .to = last, .start_to = lines[0].new_no.? };
    }
    if (suggestion) return error.SuggestionOnRemoved;
    for (lines[1..], 1..) |line, index| {
        if (line.old_no.? != lines[index - 1].old_no.? + 1) return error.NonContiguous;
    }
    const last = lines[lines.len - 1].old_no.?;
    return if (lines.len == 1) .{ .from = last } else .{ .from = last, .start_from = lines[0].old_no.? };
}

fn collectSelectedLines(
    buffer: bbr.diff.Buffer,
    low: usize,
    high: usize,
    lines: *std.ArrayList(*const bbr.diff.Line),
    allocator: Allocator,
) !void {
    var index = low;
    while (index <= high and index < buffer.rows.len) : (index += 1) {
        if (buffer.rows[index] == .file_header) return error.NonContiguous;
        if (lineAtRow(buffer.rows[index])) |line| try lines.append(allocator, line);
    }
}

fn fileIndexForRow(buffer: bbr.diff.Buffer, cursor: usize) usize {
    var file_index: usize = 0;
    var seen_file = false;
    var row: usize = 0;
    while (row <= cursor and row < buffer.rows.len) : (row += 1) {
        if (buffer.rows[row] == .file_header) {
            if (seen_file) file_index += 1 else seen_file = true;
        }
    }
    return file_index;
}

fn nextFileHeaderRow(buffer: bbr.diff.Buffer, cursor: usize) ?usize {
    var row = cursor +| 1;
    while (row < buffer.rows.len) : (row += 1) {
        if (buffer.rows[row] == .file_header) return row;
    }
    return null;
}

fn previousFileHeaderRow(buffer: bbr.diff.Buffer, cursor: usize) ?usize {
    if (cursor == 0) return null;
    var row = cursor;
    while (row > 0) {
        row -= 1;
        if (buffer.rows[row] == .file_header) return row;
    }
    return null;
}

fn fileHeaderRow(buffer: bbr.diff.Buffer, file_index: usize) ?usize {
    var seen: usize = 0;
    for (buffer.rows, 0..) |row, index| {
        if (row == .file_header) {
            if (seen == file_index) return index;
            seen += 1;
        }
    }
    return null;
}

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

fn testTwoFileSession(backing: std.mem.Allocator, id: u64) !*session_mod.Session {
    const s = try session_mod.create(backing);
    errdefer s.destroy();
    const a = s.arena.allocator();
    s.pr = .{
        .id = id,
        .title = "Two files",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    s.diff = try bbr.diff.parse(a,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old a
        \\+new a
        \\diff --git a/b.zig b/b.zig
        \\--- a/b.zig
        \\+++ b/b.zig
        \\@@ -1 +1 @@
        \\-old b
        \\+new b
    );
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
    try presentation.dispatch(.{ .action = .down });
    try testing.expectEqual(@as(usize, 2), presentation.projection().review.?.navigation.cursor);
    try presentation.dispatch(.{ .action = .toggle_select });
    try presentation.dispatch(.{ .action = .up });
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

    try presentation.dispatch(.{ .action = .down });
    const before = presentation.projection().review.?.navigation;
    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .push_count_digit = 9 });
    try testing.expect(std.meta.eql(before, presentation.projection().review.?.navigation));
}

test "failed Buffer transaction preserves Buffer preferences and Navigation" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 2,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .down });
    const before = presentation.projection().review.?;

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .action = .toggle_layout });

    const after = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(before.buffer.rows.ptr, after.review.?.buffer.rows.ptr);
    try testing.expectEqual(before.buffer.layout, after.review.?.buffer.layout);
    try testing.expect(std.meta.eql(before.preferences, after.review.?.preferences));
    try testing.expect(std.meta.eql(before.navigation, after.review.?.navigation));
    try testing.expectEqual(ActionError.out_of_memory, after.action_error.?);
}

test "preferences survive replacement while file isolation resets" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testTwoFileSession(testing.allocator, 1),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    try presentation.dispatch(.{ .action = .toggle_layout });
    try presentation.dispatch(.{ .action = .toggle_resolved });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .isolate });
    const isolated = presentation.projection().review.?;
    try testing.expectEqual(@as(?usize, 0), isolated.isolated_file);
    try testing.expectEqual(bbr.diff.Layout.side_by_side, isolated.preferences.layout);
    try testing.expect(isolated.preferences.show_resolved);
    try testing.expectEqual(Scope.fetched, isolated.preferences.scope);

    try presentation.dispatch(.{ .choose_pull_request = try ReviewKey.init("workspace", "repo", 2) });
    const command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'c') },
    } });

    const replaced = presentation.projection().review.?;
    try testing.expectEqual(bbr.diff.Layout.side_by_side, replaced.preferences.layout);
    try testing.expect(replaced.preferences.show_resolved);
    try testing.expectEqual(Scope.fetched, replaced.preferences.scope);
    try testing.expectEqual(@as(?usize, null), replaced.isolated_file);
    try testing.expectEqual(@as(usize, 0), replaced.navigation.cursor);
}

test "saving a Composer Draft persists it for a later Session" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);

    {
        var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
            .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
            .viewport_rows = 8,
        });
        defer presentation.deinit();

        try presentation.dispatch(.{ .action = .comment });
        try testing.expectEqualStrings("New comment", presentation.projection().composer.?.label);
        try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("ship it") } });
        try presentation.dispatch(.{ .composer = .save });

        const projection = presentation.projection();
        try testing.expect(projection.composer == null);
        try testing.expectEqual(@as(usize, 1), projection.review.?.drafts.len);
        try testing.expectEqualStrings("ship it", projection.review.?.drafts[0].body);
    }

    var resumed = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer resumed.deinit();
    try testing.expectEqualStrings("ship it", resumed.projection().review.?.drafts[0].body);
}

test "Reply on a Draft row saves a child linked to that Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    try store.store().put(key.storeKey(), .{
        .local_id = 7,
        .kind = .top_level,
        .body = "parent",
    });
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    const review = presentation.projection().review.?;
    var draft_row: usize = 0;
    for (review.buffer.rows, 0..) |row, index| {
        if (row == .draft) {
            draft_row = index;
            break;
        }
    }
    for (0..draft_row) |_| try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .reply });
    try testing.expectEqualStrings("Reply", presentation.projection().composer.?.label);
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("child") } });
    try presentation.dispatch(.{ .composer = .save });

    const drafts = presentation.projection().review.?.drafts;
    try testing.expectEqual(@as(usize, 2), drafts.len);
    try testing.expectEqualStrings("child", drafts[1].body);
    try testing.expect(drafts[1].parent.? == .draft);
    try testing.expectEqual(@as(bbr.review.TempId, 7), drafts[1].parent.?.draft);
    try testing.expect(drafts[1].anchor == null);
}

test "Suggest derives an Anchor and persists a fenced seeded Draft" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const key = try ReviewKey.init("workspace", "repo", 1);
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{ .key = key, .session = try testSession(testing.allocator, 1, 'a') },
        .viewport_rows = 8,
    });
    defer presentation.deinit();

    const review = presentation.projection().review.?;
    var added_row: usize = 0;
    for (review.buffer.rows, 0..) |row, index| switch (row) {
        .line => |line| if (line.line.new_no != null) {
            added_row = index;
            break;
        },
        else => {},
    };
    for (0..added_row) |_| try presentation.dispatch(.{ .action = .down });
    try presentation.dispatch(.{ .action = .suggest });
    try testing.expectEqualStrings("new", presentation.projection().composer.?.body);
    try presentation.dispatch(.{ .composer = .save });

    const draft = presentation.projection().review.?.drafts[0];
    try testing.expectEqualStrings("```suggestion\nnew\n```", draft.body);
    try testing.expectEqualStrings("a.zig", draft.anchor.?.path);
    try testing.expectEqual(@as(?u32, 1), draft.anchor.?.to);
    try testing.expectEqualStrings("source", draft.anchor.?.commit.?);
}

test "persistence failure preserves Composer and the exact published review" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = bbr.review.InMemoryStore.init(failing.allocator());
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("keep me") } });
    const before = presentation.projection().review.?;

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .composer = .save });

    const failed = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(ActionError.persistence_failed, failed.action_error.?);
    try testing.expectEqualStrings("keep me", failed.composer.?.body);
    try testing.expectEqual(@as(usize, 0), failed.review.?.drafts.len);
    try testing.expectEqual(before.buffer.rows.ptr, failed.review.?.buffer.rows.ptr);
    try testing.expect(std.meta.eql(before.navigation, failed.review.?.navigation));

    failing.fail_index = std.math.maxInt(usize);
    try presentation.dispatch(.{ .composer = .save });
    try testing.expect(presentation.projection().composer == null);
    try testing.expectEqualStrings("keep me", presentation.projection().review.?.drafts[0].body);
}

test "inline Composer allocation failure publishes no invalid Overlay" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var presentation = try Presentation.init(failing.allocator(), .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    const rows = presentation.projection().review.?.buffer.rows;
    var added_row: usize = 0;
    for (rows, 0..) |row, index| switch (row) {
        .line => |line| if (line.line.new_no != null) {
            added_row = index;
            break;
        },
        else => {},
    };
    for (0..added_row) |_| try presentation.dispatch(.{ .action = .down });

    failing.fail_index = failing.alloc_index;
    try presentation.dispatch(.{ .action = .suggest });

    const projection = presentation.projection();
    try testing.expect(failing.has_induced_failure);
    try testing.expect(projection.composer == null);
    try testing.expectEqual(ActionError.out_of_memory, projection.action_error.?);
}

test "failed replacement preserves Composer and successful replacement resets it" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try ReviewKey.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator, 1, 'a'),
        },
        .viewport_rows = 8,
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .comment });
    try presentation.dispatch(.{ .composer = .{ .insert = try TextChunk.init("survive rollback") } });

    const key_two = try ReviewKey.init("workspace", "repo", 2);
    try presentation.dispatch(.{ .choose_pull_request = key_two });
    const failed_command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = failed_command.intent,
        .outcome = .{ .failed = error.NotFound },
    } });
    try testing.expectEqualStrings("survive rollback", presentation.projection().composer.?.body);

    try presentation.dispatch(.{ .choose_pull_request = key_two });
    const successful_command = presentation.takeCommand().?.load_session;
    try presentation.dispatch(.{ .session_loaded = .{
        .intent = successful_command.intent,
        .outcome = .{ .loaded = try testSession(testing.allocator, 2, 'b') },
    } });
    try testing.expect(presentation.projection().composer == null);
}
