const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");
const presentation_mod = @import("presentation.zig");
const render = @import("render.zig");
const session_mod = @import("session.zig");
const file_enrichment = @import("file_enrichment.zig");
const theme = @import("theme.zig").dark;

const Presentation = presentation_mod.Presentation;
const SelectedVersion = presentation_mod.SelectedVersion;
const testing = std.testing;

const TestBlobSource = struct {
    fn source(self: *TestBlobSource) file_enrichment.BlobSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(_: *anyopaque, allocator: std.mem.Allocator, commit: []const u8, _: []const u8) anyerror![]u8 {
        return allocator.dupe(u8, if (std.mem.eql(u8, commit, "source")) "new value\n" else "old value\n");
    }
};

const TestHighlighter = struct {
    fn highlighter(self: *TestHighlighter) bbr.highlight.Highlighter {
        return .{ .ptr = self, .vtable = &.{ .highlight = highlight } };
    }

    fn highlight(_: *anyopaque, allocator: std.mem.Allocator, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!bbr.highlight.HighlightResult {
        return .{ .spans = try allocator.dupe(bbr.highlight.Span, &.{.{
            .line = 1,
            .start = 0,
            .end = 3,
            .capture = bbr.highlight.Capture.init(0, "keyword"),
        }}) };
    }
};

fn testSession(backing: std.mem.Allocator) !*session_mod.Session {
    const session = try session_mod.create(backing);
    errdefer session.destroy();
    const allocator = session.arena.allocator();
    const pull_request: bbr.bitbucket.PullRequest = .{
        .id = 1,
        .title = "Selected Version hardening",
        .state = "OPEN",
        .author_display_name = "Reviewer",
        .source_branch = "feature",
        .destination_branch = "main",
        .source_commit = "source",
        .destination_commit = "destination",
    };
    session.source = .{ .remote = pull_request };
    session.header = .{
        .title = pull_request.title,
        .source_ref = pull_request.source_branch,
        .base_ref = pull_request.destination_branch,
        .source_commit = pull_request.source_commit,
        .base_commit = pull_request.destination_commit,
        .author = pull_request.author_display_name,
        .locator = "repo",
        .source_label = "Bitbucket",
        .pull_request_id = pull_request.id,
    };
    session.diff = try bbr.diff.parse(allocator,
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1 +1 @@
        \\-old value
        \\+new value
    );
    try session.initializeEnrichment();
    var source = TestBlobSource{};
    var highlighter = TestHighlighter{};
    var enrichment = try file_enrichment.enrichFrom(backing, source.source(), highlighter.highlighter(), .{
        .repo = "repo",
        .status = .modified,
        .source_commit = "source",
        .destination_commit = "destination",
        .old_path = "src/a.zig",
        .new_path = "src/a.zig",
        .max_file_bytes = 0,
    });
    defer enrichment.deinit();
    try session.enrichment.admit(0, &enrichment);
    return session;
}

fn initPresentation(allocator: std.mem.Allocator, store: bbr.review.PendingReviewStore, geometry: presentation_mod.FrameGeometry) !Presentation {
    return Presentation.init(allocator, .{ .reviews = store }, .{
        .initial = .{
            .key = try presentation_mod.OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator),
        },
        .geometry = geometry,
    });
}

fn headlessWindow(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = screen,
    };
}

fn renderedFrameFingerprint(review: presentation_mod.ReviewProjection) !u64 {
    const geometry = review.frame.geometry;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = geometry.rows, .cols = geometry.cols, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const window = headlessWindow(&screen);
    render.drawReview(scratch.allocator(), window, review, theme, 0);
    var hash = std.hash.Wyhash.init(0);
    for (0..geometry.rows) |row| for (0..geometry.cols) |col| {
        const cell = window.readCell(@intCast(col), @intCast(row)).?;
        hash.update(cell.char.grapheme);
        hash.update(&.{cell.char.width});
        hash.update(&.{ @intFromBool(cell.style.bold), @intFromBool(cell.style.dim), @intFromBool(cell.style.italic) });
    };
    return hash.final();
}

const PublishedFrameSnapshot = struct {
    preferences: presentation_mod.Preferences,
    selected_version: SelectedVersion,
    revision: u64,
    visual_rows_revision: u64,
    geometry: @import("frame.zig").Geometry,
    panes: @import("frame.zig").PaneRects,
    overlay: ?@import("frame.zig").OverlayTarget,
    visual_rows_len: usize,
    buffer_rows_len: usize,
    buffer_row_kinds_len: usize,
    buffer_file_tallies_len: usize,
    buffer_file_rows_len: usize,
    layout: presentation_mod.Layout,
    selected_column: ?@import("buffer.zig").SelectedColumn,
    navigation: @import("nav.zig").Nav,
    file_tree_entries_len: usize,
    file_tree_cursor: usize,
    file_tree_scroll: usize,
    file_tree_viewport: usize,
    focus: @import("frame.zig").PaneFocus,
    frame_selected_version: SelectedVersion,
    version_title_targets: @import("frame.zig").VersionTitleTargets,
};

fn publishedFrameSnapshot(review: presentation_mod.ReviewProjection) PublishedFrameSnapshot {
    const frame = review.frame;
    return .{
        .preferences = review.preferences,
        .selected_version = review.selected_version,
        .revision = frame.revision,
        .visual_rows_revision = frame.visual_rows_revision,
        .geometry = frame.geometry,
        .panes = frame.panes,
        .overlay = frame.overlay,
        .visual_rows_len = frame.visual_rows.len,
        .buffer_rows_len = frame.buffer.rows.len,
        .buffer_row_kinds_len = frame.buffer.row_kinds.len,
        .buffer_file_tallies_len = frame.buffer.file_tallies.len,
        .buffer_file_rows_len = frame.buffer.file_rows.len,
        .layout = frame.buffer.layout,
        .selected_column = frame.buffer.selected_column,
        .navigation = frame.navigation,
        .file_tree_entries_len = frame.file_tree.entries.len,
        .file_tree_cursor = frame.file_tree.cursor,
        .file_tree_scroll = frame.file_tree.scroll,
        .file_tree_viewport = frame.file_tree.viewport,
        .focus = frame.focus,
        .frame_selected_version = frame.selected_version,
        .version_title_targets = frame.version_title_targets,
    };
}

test "M20 hardening forces every Selected Version projection allocation failure" {
    var saw_failure = false;
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var presentation = try initPresentation(failing.allocator(), store.store(), .{ .cols = 80, .rows = 10 });
        defer presentation.deinit();
        try presentation.dispatch(.{ .action = .down });
        try presentation.dispatch(.{ .action = .toggle_select });
        try presentation.dispatch(.{ .push_count_digit = 7 });
        const before_review = presentation.projection().review.?;
        const before = publishedFrameSnapshot(before_review);
        const before_render = try renderedFrameFingerprint(before_review);
        const sidebar = before_review.frame.panes.sidebar_content;
        try presentation.dispatch(.{ .mouse = .{ .col = sidebar.x, .row = sidebar.y, .button = .left, .type = .press } });
        failing.fail_index = failing.alloc_index + offset;

        try presentation.dispatch(.{ .action = .select_old_version });

        const after = presentation.projection().review.?;
        if (!failing.has_induced_failure) {
            try testing.expectEqual(SelectedVersion.old, after.selected_version);
            break;
        }
        saw_failure = true;
        try testing.expect(std.meta.eql(before, publishedFrameSnapshot(after)));
        try testing.expectEqual(before_render, try renderedFrameFingerprint(after));
        failing.fail_index = std.math.maxInt(usize);
        try presentation.dispatch(.{ .mouse = .{ .col = sidebar.x, .row = sidebar.y, .button = .left, .type = .release } });
        try testing.expectEqual(@import("frame.zig").PaneFocus.sidebar, presentation.projection().review.?.frame.focus);
    }
    try testing.expect(saw_failure);
}

test "M20 hardening forces every yank allocation failure and keeps refusal cleanup" {
    var saw_failure = false;
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var store = bbr.review.InMemoryStore.init(testing.allocator);
        defer store.deinit();
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var presentation = try initPresentation(failing.allocator(), store.store(), .{ .cols = 80, .rows = 10 });
        defer presentation.deinit();
        try presentation.dispatch(.{ .action = .down });
        try presentation.dispatch(.{ .action = .down });
        try presentation.dispatch(.{ .action = .toggle_select });
        try presentation.dispatch(.{ .action = .down });
        try presentation.dispatch(.{ .push_count_digit = 7 });
        failing.fail_index = failing.alloc_index + offset;

        try presentation.dispatch(.{ .action = .yank });

        const projected = presentation.projection();
        try testing.expectEqual(@as(usize, 0), projected.review.?.navigation.count);
        if (!failing.has_induced_failure) {
            failing.fail_index = std.math.maxInt(usize);
            var command = presentation.takeCommand().?;
            defer command.deinit();
            try testing.expectEqualStrings("new value", command.copy_clipboard.text);
            try testing.expect(projected.review.?.navigation.mark == null);
            break;
        }
        saw_failure = true;
        try testing.expectEqual(presentation_mod.ActionError.out_of_memory, projected.action_error.?);
        try testing.expect(projected.review.?.navigation.mark != null);
        try testing.expect(presentation.takeCommand() == null);
    }
    try testing.expect(saw_failure);
}

test "M20 hardening renders zero narrow ordinary and wide DiffPane geometry" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try initPresentation(testing.allocator, store.store(), .{ .cols = 80, .rows = 8 });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .select_old_version });
    try presentation.dispatch(.{ .action = .focus_next_pane });

    for ([_]u16{ 0, 34, 80, 160 }) |cols| {
        try presentation.dispatch(.{ .resize = .{ .cols = cols, .rows = 8 } });
        const review = presentation.projection().review.?;
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 8, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(testing.allocator);
        const window = headlessWindow(&screen);

        render.drawReview(scratch.allocator(), window, review, theme, 0);

        const targets = review.frame.version_title_targets;
        if (targets.old) |old| {
            try testing.expect(old.x + old.width <= cols);
            try testing.expectEqualStrings("g", window.readCell(old.x, old.y).?.char.grapheme);
            try testing.expectEqual(theme.accent, window.readCell(old.x, old.y).?.style.fg);
            try testing.expect(window.readCell(old.x, old.y).?.style.bold);
        }
        if (targets.new) |new| {
            try testing.expect(new.x + new.width <= cols);
            try testing.expectEqualStrings("N", window.readCell(new.x, new.y).?.char.grapheme);
            try testing.expect(!std.meta.eql(theme.accent, window.readCell(new.x, new.y).?.style.fg));
        }
        if (cols >= 80) {
            const source_row = review.frame.panes.diff_content.y + 2;
            var highlighted = false;
            for (0..cols) |col| if (window.readCell(@intCast(col), source_row)) |cell| {
                if (std.mem.eql(u8, cell.char.grapheme, "o")) {
                    try testing.expectEqual(theme.syntax_keyword, cell.style.fg);
                    highlighted = true;
                    break;
                }
            };
            try testing.expect(highlighted);
        }
        try testing.expectEqual(@import("frame.zig").PaneFocus.sidebar, review.frame.focus);
    }

    try presentation.dispatch(.{ .resize = .{ .cols = 80, .rows = 8 } });
    try presentation.dispatch(.{ .action = .toggle_layout });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .cycle_scope });
    const review = presentation.projection().review.?;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 8, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const window = headlessWindow(&screen);
    render.drawReview(scratch.allocator(), window, review, theme, 0);
    const line_row = review.frame.panes.diff_content.y + 1;
    var accented_gutter = false;
    var highlighted_source = false;
    for (review.frame.panes.diff_content.x..80) |col| if (window.readCell(@intCast(col), line_row)) |cell| {
        if (std.mem.eql(u8, cell.char.grapheme, "▐")) {
            try testing.expectEqual(theme.accent, cell.style.fg);
            accented_gutter = true;
        }
        if (std.mem.eql(u8, cell.char.grapheme, "o")) {
            try testing.expectEqual(theme.syntax_keyword, cell.style.fg);
            highlighted_source = true;
        }
    };
    try testing.expect(accented_gutter);
    try testing.expect(highlighted_source);
}

test "M20 hardening renders the selected renamed path in the DiffPane title" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    const session = try testSession(testing.allocator);
    errdefer session.destroy();
    const files = try session.arena.allocator().dupe(bbr.diff.File, session.diff.files);
    files[0].old_path = "old.txt";
    files[0].new_path = "new.txt";
    files[0].status = .renamed;
    session.diff.files = files;
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store() }, .{
        .initial = .{
            .key = try presentation_mod.OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = session,
        },
        .geometry = .{ .cols = 80, .rows = 8 },
    });
    defer presentation.deinit();
    try presentation.dispatch(.{ .action = .select_old_version });
    try presentation.dispatch(.{ .action = .cycle_scope });
    try presentation.dispatch(.{ .action = .cycle_scope });
    const review = presentation.projection().review.?;
    try testing.expectEqual(presentation_mod.Scope.whole, review.preferences.scope);

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 8, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const window = headlessWindow(&screen);
    render.drawReview(scratch.allocator(), window, review, theme, 0);

    const title_x = review.frame.panes.diff.x + 2;
    for ("old.txt", 0..) |char, offset| {
        try testing.expectEqualStrings(&.{char}, window.readCell(title_x + @as(u16, @intCast(offset)), review.frame.panes.diff.y).?.char.grapheme);
    }
}

test "M20 hardening accepts only an unmodified same-target title click" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try initPresentation(testing.allocator, store.store(), .{ .cols = 80, .rows = 10 });
    defer presentation.deinit();
    const old = presentation.projection().review.?.frame.version_title_targets.old.?;
    const new = presentation.projection().review.?.frame.version_title_targets.new.?;

    for ([_]presentation_mod.MouseInput{
        .{ .col = old.x, .row = old.y, .button = .left, .type = .press, .modified = true },
        .{ .col = old.x, .row = old.y, .button = .unsupported, .type = .press },
        .{ .col = old.x, .row = old.y, .button = .right, .type = .press },
        .{ .col = old.x, .row = old.y, .button = .left, .type = .motion },
        .{ .col = old.x, .row = old.y, .button = .left, .type = .drag },
    }) |mouse| {
        try presentation.dispatch(.{ .mouse = mouse });
        try presentation.dispatch(.{ .mouse = .{ .col = old.x, .row = old.y, .button = .left, .type = .release } });
        try testing.expectEqual(SelectedVersion.new, presentation.projection().review.?.selected_version);
    }

    try presentation.dispatch(.{ .mouse = .{ .col = old.x, .row = old.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = new.x, .row = new.y, .button = .left, .type = .release } });
    try testing.expectEqual(SelectedVersion.new, presentation.projection().review.?.selected_version);

    try presentation.dispatch(.{ .mouse = .{ .col = old.x, .row = old.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .resize = .{ .cols = 81, .rows = 10 } });
    try presentation.dispatch(.{ .mouse = .{ .col = old.x, .row = old.y, .button = .left, .type = .release } });
    try testing.expectEqual(SelectedVersion.new, presentation.projection().review.?.selected_version);

    try presentation.dispatch(.{ .action = .review_comment });
    const current_old = presentation.projection().review.?.frame.version_title_targets.old.?;
    try presentation.dispatch(.{ .mouse = .{ .col = current_old.x, .row = current_old.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = current_old.x, .row = current_old.y, .button = .left, .type = .release } });
    try testing.expectEqual(SelectedVersion.new, presentation.projection().review.?.selected_version);
    try presentation.dispatch(.{ .composer = .cancel });

    try presentation.dispatch(.{ .resize = .{ .cols = 34, .rows = 10 } });
    const clipped = presentation.projection().review.?.frame.version_title_targets;
    try testing.expect(clipped.old == null);
    try testing.expect(clipped.new != null);
    try presentation.dispatch(.{ .mouse = .{ .col = 33, .row = 0, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = 33, .row = 0, .button = .left, .type = .release } });
    try testing.expectEqual(SelectedVersion.new, presentation.projection().review.?.selected_version);

    try presentation.dispatch(.{ .resize = .{ .cols = 80, .rows = 10 } });
    const visible_old = presentation.projection().review.?.frame.version_title_targets.old.?;
    try presentation.dispatch(.{ .mouse = .{ .col = visible_old.x, .row = visible_old.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = visible_old.x, .row = visible_old.y, .button = .left, .type = .release } });
    try testing.expectEqual(SelectedVersion.old, presentation.projection().review.?.selected_version);
}

test "M20 hardening disabled mouse input cannot select a title segment" {
    var store = bbr.review.InMemoryStore.init(testing.allocator);
    defer store.deinit();
    var presentation = try Presentation.init(testing.allocator, .{ .reviews = store.store(), .mouse_enabled = false }, .{
        .initial = .{
            .key = try presentation_mod.OwnedReviewIdentity.init("workspace", "repo", 1),
            .session = try testSession(testing.allocator),
        },
        .geometry = .{ .cols = 80, .rows = 10 },
    });
    defer presentation.deinit();
    const old = presentation.projection().review.?.frame.version_title_targets.old.?;

    try presentation.dispatch(.{ .mouse = .{ .col = old.x, .row = old.y, .button = .left, .type = .press } });
    try presentation.dispatch(.{ .mouse = .{ .col = old.x, .row = old.y, .button = .left, .type = .release } });

    try testing.expectEqual(SelectedVersion.new, presentation.projection().review.?.selected_version);
}
