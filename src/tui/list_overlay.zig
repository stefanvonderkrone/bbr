//! List Overlays: Overlays made of one query line and one fuzzy-ranked list
//! with one selection. `FuzzyList` owns the query, the ranked matches, and the
//! selection for every one of them. It never owns or borrows items: each list
//! passes a haystack value on refilter. No arm holds a borrow either: data
//! that another owner frees, such as the published Session's Files, comes in
//! as an argument at each call.
//!
//! A haystack is any value with:
//!     fn len(self) usize
//!     fn score(self, index: usize, query: Query) ?f64
//! `score` returns null to exclude the item. Higher scores rank first, and
//! ties keep item order.

const std = @import("std");
const zf = @import("zf");
const bbr = @import("bbr");
const search = @import("search.zig");

const Allocator = std.mem.Allocator;
const PullRequestSummary = bbr.bitbucket.PullRequestSummary;
const File = bbr.diff.File;
const Action = @import("action.zig").Action;
const InteractionContext = @import("action.zig").InteractionContext;
const keymap = @import("keymap.zig");
const ThemeId = @import("theme_id.zig").ThemeId;

/// Max whitespace-separated needles honored in a query; extra words are ignored.
const max_needles = 8;

pub const FuzzyList = struct {
    allocator: Allocator,
    /// Item indices in rank order, best first. Length `match_count`.
    match_buf: []usize = &.{},
    /// Score of each match, parallel to `match_buf`.
    score_buf: []f64 = &.{},
    match_count: usize = 0,
    /// Cursor into `match_buf[0..match_count]`.
    selected: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    pub fn query(self: *const FuzzyList) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// Item indices of the visible matches, best first.
    pub fn matches(self: *const FuzzyList) []const usize {
        return self.match_buf[0..self.match_count];
    }

    /// The item index under the cursor, or null when nothing matches.
    pub fn selectedItem(self: *const FuzzyList) ?usize {
        return if (self.match_count == 0) null else self.match_buf[self.selected];
    }

    /// First visible match row for a viewport of `rows` rows. Paint and
    /// hit-testing both call this, so they cannot disagree.
    pub fn scrollTop(self: *const FuzzyList, rows: usize) usize {
        if (rows == 0 or self.selected < rows) return 0;
        return self.selected - rows + 1;
    }

    fn init(allocator: Allocator, item_count: usize) Allocator.Error!FuzzyList {
        var self: FuzzyList = .{ .allocator = allocator };
        try self.resize(item_count);
        return self;
    }

    /// Size the buffers for a new item set and keep the query. On failure the
    /// old buffers stay intact.
    fn resize(self: *FuzzyList, item_count: usize) Allocator.Error!void {
        const match_buf = try self.allocator.alloc(usize, item_count);
        errdefer self.allocator.free(match_buf);
        const score_buf = try self.allocator.alloc(f64, item_count);
        self.allocator.free(self.match_buf);
        self.allocator.free(self.score_buf);
        self.match_buf = match_buf;
        self.score_buf = score_buf;
        self.match_count = 0;
    }

    fn deinit(self: *FuzzyList) void {
        self.allocator.free(self.match_buf);
        self.allocator.free(self.score_buf);
        self.* = undefined;
    }

    /// A query edit puts the cursor on the best match, so Enter never runs
    /// whatever lands under the old cursor row.
    /// A full query takes no part of a scalar.
    fn appendQuery(self: *FuzzyList, bytes: []const u8) void {
        var start: usize = 0;
        while (start < bytes.len) {
            const len = std.unicode.utf8ByteSequenceLength(bytes[start]) catch 1;
            const end = @min(start + len, bytes.len);
            if (self.query_len + end - start > self.query_buf.len) break;
            @memcpy(self.query_buf[self.query_len..][0 .. end - start], bytes[start..end]);
            self.query_len += end - start;
            start = end;
        }
        self.selected = 0;
    }

    fn popQuery(self: *FuzzyList) void {
        self.query_len = search.lastScalarStart(self.query());
        self.selected = 0;
    }

    fn moveUp(self: *FuzzyList) void {
        if (self.selected > 0) self.selected -= 1;
    }

    fn moveDown(self: *FuzzyList) void {
        if (self.selected + 1 < self.match_count) self.selected += 1;
    }

    /// Select match row `row`. Out of range is a no-op.
    fn selectRow(self: *FuzzyList, row: usize) void {
        if (row < self.match_count) self.selected = row;
    }

    /// Put the cursor on the match row that shows item `item`, if visible.
    fn selectItem(self: *FuzzyList, item: usize) void {
        for (self.matches(), 0..) |candidate, row| if (candidate == item) {
            self.selected = row;
            return;
        };
    }

    /// Recompute the matches from the current query. A blank query matches
    /// every item in item order. The cursor is clamped into the new set.
    fn refilter(self: *FuzzyList, haystack: anytype) void {
        const text = std.mem.trim(u8, self.query(), " \t");
        const item_count = haystack.len();
        std.debug.assert(item_count <= self.match_buf.len);
        if (text.len == 0) {
            for (0..item_count) |index| self.match_buf[index] = index;
            self.match_count = item_count;
            self.clamp();
            return;
        }

        var needles: [max_needles][]const u8 = undefined;
        var needle_count: usize = 0;
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        while (words.next()) |word| {
            if (needle_count == needles.len) break;
            needles[needle_count] = word;
            needle_count += 1;
        }
        const parsed: Query = .{ .text = text, .needles = needles[0..needle_count] };

        var count: usize = 0;
        for (0..item_count) |index| {
            const score = haystack.score(index, parsed) orelse continue;
            self.match_buf[count] = index;
            self.score_buf[count] = score;
            count += 1;
        }
        self.match_count = count;

        // Stable insertion sort, best first: every list is small.
        var unsorted: usize = 1;
        while (unsorted < count) : (unsorted += 1) {
            const item = self.match_buf[unsorted];
            const score = self.score_buf[unsorted];
            var slot = unsorted;
            while (slot > 0 and self.score_buf[slot - 1] < score) : (slot -= 1) {
                self.match_buf[slot] = self.match_buf[slot - 1];
                self.score_buf[slot] = self.score_buf[slot - 1];
            }
            self.match_buf[slot] = item;
            self.score_buf[slot] = score;
        }
        self.clamp();
    }

    fn clamp(self: *FuzzyList) void {
        if (self.match_count == 0) {
            self.selected = 0;
        } else if (self.selected >= self.match_count) {
            self.selected = self.match_count - 1;
        }
    }
};

/// A trimmed, non-blank query and its whitespace-separated needles.
pub const Query = struct {
    text: []const u8,
    needles: []const []const u8,

    /// Rank `haystack` against every needle.
    pub fn rank(self: Query, haystack: []const u8) ?f64 {
        return zf.rank(haystack, self.needles, .{ .plain = true, .case_sensitive = false });
    }

    /// Rank `haystack` against the whole query as one needle.
    pub fn rankText(self: Query, haystack: []const u8) ?f64 {
        return zf.rank(haystack, &.{self.text}, .{ .plain = true, .case_sensitive = false });
    }
};

/// Owned PullRequest summaries for a populated Picker.
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
};

/// The Repository a Picker lists, copied when the Picker opens. Enter builds
/// its identity from this copy, so it needs no published or loading Session.
pub const Repository = struct {
    workspace_buf: [128]u8 = undefined,
    workspace_len: u8 = 0,
    name_buf: [256]u8 = undefined,
    name_len: u16 = 0,

    pub fn init(workspace_name: []const u8, repository_name: []const u8) error{NameTooLong}!Repository {
        var self: Repository = .{};
        if (workspace_name.len > self.workspace_buf.len or repository_name.len > self.name_buf.len) return error.NameTooLong;
        @memcpy(self.workspace_buf[0..workspace_name.len], workspace_name);
        @memcpy(self.name_buf[0..repository_name.len], repository_name);
        self.workspace_len = @intCast(workspace_name.len);
        self.name_len = @intCast(repository_name.len);
        return self;
    }

    pub fn workspace(self: *const Repository) []const u8 {
        return self.workspace_buf[0..self.workspace_len];
    }

    pub fn name(self: *const Repository) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The PullRequest Picker. While its summaries load it shows a spinner and
/// still accepts a query, which applies the moment the summaries arrive.
pub const PullRequestPicker = struct {
    list: FuzzyList,
    repository: Repository,
    /// The work id of its `list_pull_requests` command. A load or tick with
    /// another id is stale.
    work_id: u64,
    /// Null while loading.
    summaries: ?*PullRequestSummaries = null,
    spinner_phase: u3 = 0,

    pub fn loading(self: *const PullRequestPicker) bool {
        return self.summaries == null;
    }

    pub fn prs(self: *const PullRequestPicker) []const PullRequestSummary {
        return if (self.summaries) |summaries| summaries.prs else &.{};
    }

    pub fn spinnerGlyph(self: *const PullRequestPicker) []const u8 {
        return spinner_glyphs[self.spinner_phase];
    }
};

const spinner_glyphs = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };

/// Ranks semantic fields independently so title relevance wins over an
/// incidental bare id, branch, or author hit. `#N` is the explicit direct-id
/// route and bypasses title-first ranking.
const PullRequestHaystack = struct {
    prs: []const PullRequestSummary,

    fn len(self: PullRequestHaystack) usize {
        return self.prs.len;
    }

    fn score(self: PullRequestHaystack, index: usize, q: Query) ?f64 {
        const pr = self.prs[index];
        var id_buf: [32]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{pr.id}) catch return null;
        if (q.text.len > 1 and q.text[0] == '#') return if (std.mem.eql(u8, q.text[1..], id_text)) 10000 else null;
        if (q.rank(pr.title)) |rank| return rank + 3000;
        if (q.rank(pr.source_branch)) |rank| return rank + 2000;
        if (q.rank(pr.author_display_name)) |rank| return rank + 1000;
        return q.rank(id_text);
    }
};

/// The Session-local File Finder. Its items are the published Session's
/// Files, which every call that reads them passes in.
pub const FileFinder = struct {
    list: FuzzyList,
};

/// A basename match ranks above any match found only in the full path.
const FileHaystack = struct {
    files: []const File,

    fn len(self: FileHaystack) usize {
        return self.files.len;
    }

    fn score(self: FileHaystack, index: usize, q: Query) ?f64 {
        const path = self.files[index].displayPath();
        if (q.rankText(std.fs.path.basename(path))) |rank| return rank + 1000;
        return q.rankText(path);
    }
};

/// One curated Command Palette row. The title and description live here and
/// not in the Keymap, because an Action without a default chord needs text too.
pub const Command = struct {
    action: Action,
    title: []const u8,
    description: []const u8,
};

pub const CommandPalette = struct {
    list: FuzzyList,
    /// Indices into `commands` that the Pane context supported when the
    /// palette opened. A supported but unavailable command stays listed.
    rows: [commands.len]u8 = undefined,
    row_count: u8 = 0,

    pub fn command(self: *const CommandPalette, item: usize) Command {
        return commands[self.rows[item]];
    }

    /// The curated non-Motion commands, in display order for an empty query.
    pub const commands = [_]Command{
        .{ .action = .open_file_finder, .title = "Find File", .description = "Jump to a changed File by path" },
        .{ .action = .open_review_search, .title = "Search Review", .description = "Search every File version and Comment in this Review" },
        .{ .action = .open_buffer_search, .title = "Search Buffer", .description = "Search the text of the DiffPane" },
        .{ .action = .open_pull_request_picker, .title = "Switch Pull Request", .description = "Open another PullRequest in this Repository" },
        .{ .action = .refresh, .title = "Refresh Review", .description = "Reload the current Review" },
        .{ .action = .toggle_layout, .title = "Toggle Layout", .description = "Switch between unified and side-by-side" },
        .{ .action = .cycle_scope, .title = "Cycle Diff Scope", .description = "Show changes, fetched context, or the whole File" },
        .{ .action = .isolate, .title = "Isolate File", .description = "Show only the current File, or show every File again" },
        .{ .action = .next_file, .title = "Next File", .description = "Move to the next changed File" },
        .{ .action = .prev_file, .title = "Previous File", .description = "Move to the previous changed File" },
        .{ .action = .select_old_version, .title = "Select Old Version", .description = "Inspect the old File version" },
        .{ .action = .select_new_version, .title = "Select New Version", .description = "Inspect the new File version" },
        .{ .action = .toggle_select, .title = "Toggle Selection", .description = "Start or end a visual Line selection" },
        .{ .action = .inline_comment, .title = "Inline Comment", .description = "Comment on the Line or Selection" },
        .{ .action = .suggest, .title = "Suggest Change", .description = "Propose replacement code for the Line or Selection" },
        .{ .action = .file_comment, .title = "File Comment", .description = "Comment on the current File" },
        .{ .action = .review_comment, .title = "Review Comment", .description = "Comment on the whole Review" },
        .{ .action = .reply, .title = "Reply", .description = "Reply to the Comment under the cursor" },
        .{ .action = .edit_review_item, .title = "Edit", .description = "Edit the Draft or own Comment under the cursor" },
        .{ .action = .reanchor_review_item, .title = "Re-anchor Draft", .description = "Move a local root Draft to another Line" },
        .{ .action = .delete_review_item, .title = "Delete", .description = "Delete the Draft or own Comment under the cursor" },
        .{ .action = .yank, .title = "Copy", .description = "Copy the Line, Selection, or body to the clipboard" },
        .{ .action = .set_verdict_approved, .title = "Approve", .description = "Set your Reviewer Verdict to Approved" },
        .{ .action = .set_verdict_changes_requested, .title = "Request Changes", .description = "Set your Reviewer Verdict to Changes requested" },
        .{ .action = .set_verdict_none, .title = "Clear Verdict", .description = "Set your Reviewer Verdict to No verdict" },
        .{ .action = .submit, .title = "Submit Review", .description = "Publish every local Draft to Bitbucket" },
        .{ .action = .recover_submission, .title = "Resume Submission", .description = "Continue an interrupted Submission" },
        .{ .action = .resolve_unpublished, .title = "Mark Draft Unpublished", .description = "Confirm that an unknown-outcome Draft was not posted" },
        .{ .action = .link_existing_comment, .title = "Link Existing Comment", .description = "Link an unknown-outcome Draft to a posted Comment" },
        .{ .action = .focus_next_pane, .title = "Switch Pane", .description = "Move focus between the Sidebar and the DiffPane" },
        .{ .action = .open_theme_overlay, .title = "Theme", .description = "Preview and choose the color Theme" },
        .{ .action = .help, .title = "Keybindings", .description = "Show the keybinding help" },
        .{ .action = .quit, .title = "Quit", .description = "Quit bbr" },
    };

    const pane_contexts = [_]InteractionContext{ .diff, .diff_source, .diff_disclosure, .diff_review_card, .sidebar, .sidebar_directory, .sidebar_file };

    comptime {
        @setEvalBranchQuota(100_000);
        if (commands.len > std.math.maxInt(u8)) @compileError("the Command Palette holds at most 255 commands");
        for (commands, 0..) |entry, index| {
            const name = "Command Palette entry \"" ++ entry.title ++ "\"";
            if (keymap.isMotion(entry.action)) @compileError(name ++ " is a Motion; the Command Palette lists commands only");
            if (entry.action == .open_command_palette) @compileError(name ++ " reopens the Command Palette");
            for (pane_contexts) |context| {
                if (keymap.supportsContext(entry.action, context)) break;
            } else @compileError(name ++ " is supported in no Pane context, so it can never show");
            for (commands[0..index]) |earlier| {
                if (earlier.action == entry.action) @compileError(name ++ " repeats the Action of \"" ++ earlier.title ++ "\"");
                if (std.mem.eql(u8, earlier.title, entry.title)) @compileError(name ++ " repeats a title");
            }
        }
    }

    /// A title match ranks above any match found only in a description.
    const Haystack = struct {
        palette: *const CommandPalette,

        fn len(self: Haystack) usize {
            return self.palette.row_count;
        }

        fn score(self: Haystack, index: usize, q: Query) ?f64 {
            const entry = self.palette.command(index);
            if (q.rank(entry.title)) |rank| return rank + 1000;
            return q.rank(entry.description);
        }
    };
};

/// The Theme Overlay. It stores no original Theme: the Configured Theme is the
/// original, and the preview derives from the selection, so closing reverts.
pub const ThemeOverlay = struct {
    list: FuzzyList,

    const Haystack = struct {
        fn len(_: Haystack) usize {
            return ThemeId.count;
        }

        fn score(_: Haystack, index: usize, q: Query) ?f64 {
            return q.rank(ThemeId.at(index).name());
        }
    };
};

/// The one List Overlay Presentation holds. Policy that differs per arm is an
/// exhaustive switch here, so a new arm fails the build at every decision.
pub const ListOverlay = union(enum) {
    pull_request_picker: PullRequestPicker,
    file_finder: FileFinder,
    command_palette: CommandPalette,
    theme: ThemeOverlay,

    /// A loading Picker has no items, so opening it allocates nothing.
    pub fn openPullRequestPicker(allocator: Allocator, work_id: u64, repository: Repository) ListOverlay {
        return .{ .pull_request_picker = .{ .list = .{ .allocator = allocator }, .repository = repository, .work_id = work_id } };
    }

    pub fn openFileFinder(allocator: Allocator, files: []const File) Allocator.Error!ListOverlay {
        var overlay: ListOverlay = .{ .file_finder = .{ .list = try FuzzyList.init(allocator, files.len) } };
        overlay.refilter(files);
        return overlay;
    }

    /// Lists the commands that `pane_context`, the Pane under the palette,
    /// supports.
    pub fn openCommandPalette(allocator: Allocator, pane_context: InteractionContext) Allocator.Error!ListOverlay {
        var palette: CommandPalette = .{ .list = undefined };
        for (CommandPalette.commands, 0..) |entry, index| if (keymap.supportsContext(entry.action, pane_context)) {
            palette.rows[palette.row_count] = @intCast(index);
            palette.row_count += 1;
        };
        palette.list = try FuzzyList.init(allocator, palette.row_count);
        var overlay: ListOverlay = .{ .command_palette = palette };
        overlay.refilter(&.{});
        return overlay;
    }

    /// Opens with the cursor on `configured`, so opening changes nothing on
    /// screen.
    pub fn openTheme(allocator: Allocator, configured: ThemeId) Allocator.Error!ListOverlay {
        var overlay: ListOverlay = .{ .theme = .{ .list = try FuzzyList.init(allocator, ThemeId.count) } };
        overlay.refilter(&.{});
        overlay.theme.list.selectItem(@intFromEnum(configured));
        return overlay;
    }

    pub fn deinit(self: *ListOverlay) void {
        switch (self.*) {
            .pull_request_picker => |*picker| {
                picker.list.deinit();
                if (picker.summaries) |summaries| summaries.destroy();
            },
            .file_finder => |*finder| finder.list.deinit(),
            .command_palette => |*palette| palette.list.deinit(),
            .theme => |*overlay| overlay.list.deinit(),
        }
        self.* = undefined;
    }

    pub fn list(self: *const ListOverlay) *const FuzzyList {
        return switch (self.*) {
            inline else => |*arm| &arm.list,
        };
    }

    /// `files` are the published Session's Files. Only the File Finder
    /// reads them.
    pub fn insert(self: *ListOverlay, bytes: []const u8, files: []const File) void {
        self.listMut().appendQuery(bytes);
        self.refilter(files);
    }

    /// `files` as for `insert`.
    pub fn backspace(self: *ListOverlay, files: []const File) void {
        self.listMut().popQuery();
        self.refilter(files);
    }

    pub fn moveUp(self: *ListOverlay) void {
        self.listMut().moveUp();
    }

    pub fn moveDown(self: *ListOverlay) void {
        self.listMut().moveDown();
    }

    /// A click selects a row and never confirms it.
    pub fn selectRow(self: *ListOverlay, row: usize) void {
        self.listMut().selectRow(row);
    }

    /// What Enter would choose, as a value that outlives `deinit`. Null keeps
    /// the Overlay open: nothing matches, or the Picker is still loading.
    pub fn choice(self: *const ListOverlay) ?Choice {
        const item = self.list().selectedItem() orelse return null;
        return switch (self.*) {
            .pull_request_picker => |*picker| .{ .pull_request = .{ .repository = picker.repository, .id = picker.prs()[item].id } },
            .file_finder => .{ .file = item },
            .command_palette => |*palette| .{ .action = palette.command(item).action },
            .theme => .{ .theme = ThemeId.at(item) },
        };
    }

    pub fn interactionContext(self: *const ListOverlay) InteractionContext {
        return switch (self.*) {
            .pull_request_picker => .pull_request_picker,
            .file_finder => .file_finder,
            .command_palette => .command_palette,
            .theme => .theme_overlay,
        };
    }

    /// Which context ActionAvailability reports while this Overlay is open.
    /// The Command Palette greys its rows against the Pane under it, and the
    /// Theme Overlay runs no Action.
    pub fn availabilityContext(self: *const ListOverlay) enum { overlay, pane } {
        return switch (self.*) {
            .pull_request_picker, .file_finder => .overlay,
            .command_palette, .theme => .pane,
        };
    }

    /// True when the arm's items describe the published Session: the File
    /// Finder's indices name its Files, and the Command Palette lists what its
    /// Pane context supported. Presentation closes such an arm before it
    /// replaces the Session.
    pub fn closesOnReplacement(self: *const ListOverlay) bool {
        return switch (self.*) {
            .file_finder, .command_palette => true,
            .pull_request_picker, .theme => false,
        };
    }

    /// The Theme to paint while this Overlay is open, if it previews one.
    pub fn themePreview(self: *const ListOverlay) ?ThemeId {
        return switch (self.*) {
            .theme => |*overlay| if (overlay.list.selectedItem()) |item| ThemeId.at(item) else null,
            .pull_request_picker, .file_finder, .command_palette => null,
        };
    }

    /// The scoped tick a loading Picker needs. Null for every other state.
    pub fn tickScope(self: *const ListOverlay) ?u64 {
        return switch (self.*) {
            .pull_request_picker => |*picker| if (picker.loading()) picker.work_id else null,
            .file_finder, .command_palette, .theme => null,
        };
    }

    pub const Box = @import("layouts.zig").Box;

    /// The box size in cells. Paint and hit-testing both read it. Each item
    /// takes one row, below one query row.
    pub fn box(self: *const ListOverlay) Box {
        return switch (self.*) {
            .pull_request_picker, .file_finder => .{ .width = 60, .height = 16 },
            .command_palette => .{ .width = 80, .height = 16 },
            .theme => .{ .width = 40, .height = ThemeId.count + 1 },
        };
    }

    /// The name in the top border of the query box.
    pub fn title(self: *const ListOverlay) []const u8 {
        return switch (self.*) {
            .pull_request_picker => "Pull Requests",
            .file_finder => "File Finder",
            .command_palette => "Command Palette",
            .theme => "Theme",
        };
    }

    /// Fill the loading Picker that issued `work_id` and take ownership of
    /// `summaries`. On any error the caller still owns `summaries`.
    pub fn populatePullRequests(self: *ListOverlay, work_id: u64, summaries: *PullRequestSummaries) (Allocator.Error || error{NotLoadingPicker})!void {
        if (self.tickScope() != work_id) return error.NotLoadingPicker;
        const picker = &self.pull_request_picker;
        try picker.list.resize(summaries.prs.len);
        picker.summaries = summaries;
        picker.list.refilter(PullRequestHaystack{ .prs = picker.prs() });
    }

    /// Advance the spinner of the loading Picker that issued `scope`.
    pub fn tick(self: *ListOverlay, scope: u64) void {
        if (self.tickScope() != scope) return;
        self.pull_request_picker.spinner_phase +%= 1;
    }

    fn listMut(self: *ListOverlay) *FuzzyList {
        return switch (self.*) {
            inline else => |*arm| &arm.list,
        };
    }

    fn refilter(self: *ListOverlay, files: []const File) void {
        switch (self.*) {
            .pull_request_picker => |*picker| picker.list.refilter(PullRequestHaystack{ .prs = picker.prs() }),
            .file_finder => |*finder| finder.list.refilter(FileHaystack{ .files = files }),
            .command_palette => |*palette| palette.list.refilter(CommandPalette.Haystack{ .palette = palette }),
            .theme => |*overlay| overlay.list.refilter(ThemeOverlay.Haystack{}),
        }
    }
};

// A Session replacement frees data that an open List Overlay could point
// into. So an arm holds no pointer except the buffers it owns, and a borrow
// must come in as an argument at each call.
comptime {
    for (std.meta.fields(ListOverlay)) |arm| for (std.meta.fields(arm.type)) |field| {
        if (field.type == FuzzyList or field.type == ?*PullRequestSummaries) continue;
        if (holdsPointer(field.type)) @compileError("ListOverlay arm ." ++ arm.name ++ " field ." ++ field.name ++
            " holds a pointer. Pass borrowed data into each call instead, as `insert` takes the Session's Files.");
    };
}

fn holdsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |optional| holdsPointer(optional.child),
        .array => |array| holdsPointer(array.child),
        .@"struct" => |info| for (info.fields) |field| {
            if (holdsPointer(field.type)) break true;
        } else false,
        .@"union" => |info| for (info.fields) |field| {
            if (holdsPointer(field.type)) break true;
        } else false,
        else => false,
    };
}

/// What a confirmed List Overlay chose. A value, so no borrow survives close.
pub const Choice = union(enum) {
    pull_request: struct { repository: Repository, id: u64 },
    file: usize,
    action: Action,
    theme: ThemeId,
};

const testing = std.testing;

fn samplePrs() []const PullRequestSummary {
    return &.{
        .{ .id = 10, .title = "Add diff parser", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/diff", .destination_branch = "main" },
        .{ .id = 11, .title = "Fix navigation", .state = "OPEN", .author_display_name = "Grace", .source_branch = "feature/nav", .destination_branch = "main" },
        .{ .id = 12, .title = "Comment threads", .state = "OPEN", .author_display_name = "Ada", .source_branch = "feature/comments", .destination_branch = "main" },
    };
}

fn testPicker(prs: []const PullRequestSummary) !ListOverlay {
    var overlay = ListOverlay.openPullRequestPicker(testing.allocator, 1, .{});
    errdefer overlay.deinit();
    try testPopulate(&overlay, prs);
    return overlay;
}

fn testPopulate(overlay: *ListOverlay, prs: []const PullRequestSummary) !void {
    const summaries = try PullRequestSummaries.create(testing.allocator);
    summaries.prs = prs;
    overlay.populatePullRequests(1, summaries) catch |err| {
        summaries.destroy();
        return err;
    };
}

fn chosenPullRequest(overlay: *const ListOverlay) ?u64 {
    return (overlay.choice() orelse return null).pull_request.id;
}

test "empty query matches every PR in order" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.list().matches().len);
    try testing.expectEqual(@as(u64, 10), chosenPullRequest(&p).?);
}

test "a query edit keeps whole scalars" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    p.insert("aä", &.{});
    p.backspace(&.{});
    try testing.expectEqualStrings("a", p.list().query());
    p.backspace(&.{});
    p.insert("x" ** 255 ++ "ä", &.{});
    try testing.expectEqual(@as(usize, 255), p.list().query().len);
}

test "a query narrows to fuzzy matches" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    p.insert("nav", &.{});
    try testing.expectEqual(@as(usize, 1), p.list().matches().len);
    try testing.expectEqual(@as(u64, 11), chosenPullRequest(&p).?);
}

test "matching by id and by author" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    p.insert("12", &.{});
    try testing.expectEqual(@as(u64, 12), chosenPullRequest(&p).?);

    p.backspace(&.{});
    p.backspace(&.{});
    p.insert("Grace", &.{});
    try testing.expectEqual(@as(u64, 11), chosenPullRequest(&p).?);
}

test "title ranks ahead of bare id while hash id is direct" {
    const prs = [_]PullRequestSummary{
        .{ .id = 15, .title = "Routine cleanup", .state = "OPEN", .author_display_name = "Ada", .source_branch = "cleanup", .destination_branch = "main" },
        .{ .id = 42, .title = "M15 navigation polish", .state = "OPEN", .author_display_name = "Grace", .source_branch = "navigation", .destination_branch = "main" },
    };
    var p = try testPicker(&prs);
    defer p.deinit();
    p.insert("15", &.{});
    try testing.expectEqual(@as(u64, 42), chosenPullRequest(&p).?);
    p.backspace(&.{});
    p.backspace(&.{});
    p.insert("#15", &.{});
    try testing.expectEqual(@as(u64, 15), chosenPullRequest(&p).?);
    try testing.expectEqual(@as(usize, 1), p.list().matches().len);
}

test "no match yields no choice" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    p.insert("zzzznope", &.{});
    try testing.expectEqual(@as(usize, 0), p.list().matches().len);
    try testing.expect(p.choice() == null);
}

test "navigation clamps at both ends" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    p.moveUp();
    try testing.expectEqual(@as(usize, 0), p.list().selected);
    p.moveDown();
    p.moveDown();
    p.moveDown();
    try testing.expectEqual(@as(usize, 2), p.list().selected);
}

test "a loading picker has no matches until populated" {
    var p = ListOverlay.openPullRequestPicker(testing.allocator, 1, .{});
    defer p.deinit();
    try testing.expectEqual(@as(?u64, 1), p.tickScope());
    try testing.expectEqual(@as(usize, 0), p.list().matches().len);
    try testing.expect(p.choice() == null);

    p.insert("nav", &.{});
    try testing.expectEqual(@as(usize, 0), p.list().matches().len);

    try testPopulate(&p, samplePrs());
    try testing.expect(p.tickScope() == null);
    try testing.expectEqual(@as(usize, 1), p.list().matches().len);
    try testing.expectEqual(@as(u64, 11), chosenPullRequest(&p).?);
}

test "a stale or repeated load does not populate the Picker" {
    var p = ListOverlay.openPullRequestPicker(testing.allocator, 1, .{});
    defer p.deinit();
    const stale = try PullRequestSummaries.create(testing.allocator);
    defer stale.destroy();
    try testing.expectError(error.NotLoadingPicker, p.populatePullRequests(2, stale));
    try testPopulate(&p, samplePrs());
    try testing.expectError(error.NotLoadingPicker, p.populatePullRequests(1, stale));
}

test "loading Picker spinner advances one fixed-width glyph per scoped tick" {
    var p = ListOverlay.openPullRequestPicker(testing.allocator, 1, .{});
    defer p.deinit();
    try testing.expectEqualStrings("\xe2\xa0\x8b", p.pull_request_picker.spinnerGlyph());
    p.tick(2);
    try testing.expectEqualStrings("\xe2\xa0\x8b", p.pull_request_picker.spinnerGlyph());
    p.tick(1);
    try testing.expectEqualStrings("\xe2\xa0\x99", p.pull_request_picker.spinnerGlyph());
    try testPopulate(&p, &.{});
    p.tick(1);
    try testing.expectEqualStrings("\xe2\xa0\x99", p.pull_request_picker.spinnerGlyph());
}

test "populate with an empty list leaves a ready, empty picker" {
    var p = ListOverlay.openPullRequestPicker(testing.allocator, 1, .{});
    defer p.deinit();
    try testPopulate(&p, &.{});
    try testing.expect(!p.pull_request_picker.loading());
    try testing.expectEqual(@as(usize, 0), p.list().matches().len);
    try testing.expect(p.choice() == null);
}

test "a query edit selects the best match" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    p.moveDown();
    p.moveDown();
    p.insert("feature", &.{});
    try testing.expectEqual(@as(usize, 3), p.list().matches().len);
    try testing.expectEqual(samplePrs()[p.list().matches()[0]].id, chosenPullRequest(&p).?);
    p.moveDown();
    p.backspace(&.{});
    try testing.expectEqual(samplePrs()[p.list().matches()[0]].id, chosenPullRequest(&p).?);
}

test "File Finder ranks a basename match above a path-only match" {
    const files = [_]File{
        .{ .old_path = "src/finder/main.zig", .new_path = "src/finder/main.zig", .status = .modified, .hunks = &.{} },
        .{ .old_path = "src/finder.zig", .new_path = "src/finder.zig", .status = .modified, .hunks = &.{} },
    };
    var finder = try ListOverlay.openFileFinder(testing.allocator, &files);
    defer finder.deinit();
    try testing.expectEqual(@as(usize, 2), finder.list().matches().len);
    finder.insert("finder", &files);
    try testing.expectEqual(Choice{ .file = 1 }, finder.choice().?);
    try testing.expectEqual(@as(usize, 2), finder.list().matches().len);
}

test "scroll top keeps the selected row inside the viewport" {
    var p = try testPicker(samplePrs());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.list().scrollTop(2));
    p.moveDown();
    p.moveDown();
    try testing.expectEqual(@as(usize, 1), p.list().scrollTop(2));
    try testing.expectEqual(@as(usize, 0), p.list().scrollTop(0));
}
