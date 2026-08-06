//! Deterministic, terminal-independent compacted File Tree projection.

const std = @import("std");
const bbr = @import("bbr");
const CellMetrics = @import("cell_metrics.zig").CellMetrics;

pub const Identity = union(enum) {
    directory: []const u8,
    file: usize,

    pub fn eql(a: Identity, b: Identity) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .directory => |path| std.mem.eql(u8, path, b.directory),
            .file => |index| index == b.file,
        };
    }
};

pub const Entry = struct {
    identity: Identity,
    parent: ?Identity,
    depth: usize,
    label: []const u8,
    expanded: bool = false,
    active: bool = false,
    active_descendant: bool = false,
    status: ?bbr.diff.FileStatus = null,
    comments: usize = 0,
    drafts: usize = 0,
    tally: []const u8 = "",
    tally_width: usize = 0,
};

pub const Projection = struct {
    entries: []const Entry = &.{},
    cursor: usize = 0,
    scroll: usize = 0,
    viewport: usize = 0,
};

const Node = struct {
    kind: enum { root, directory, file },
    path: []const u8,
    file_index: usize = 0,
    parent: ?usize,
    children: std.ArrayList(usize) = .empty,
};

pub fn build(
    allocator: std.mem.Allocator,
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    collapsed: []const []const u8,
    active_file: ?usize,
    content_width: usize,
    viewport: usize,
    wanted_cursor: ?Identity,
    wanted_scroll: usize,
    metrics: CellMetrics,
) !Projection {
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(allocator, .{ .kind = .root, .path = "", .parent = null });
    for (diff.files, 0..) |file, file_index| try insertFile(allocator, &nodes, file.displayPath(), file_index);
    sortChildren(&nodes, 0);

    var entries: std.ArrayList(Entry) = .empty;
    for (nodes.items[0].children.items) |child| try emit(allocator, &nodes, child, null, 0, diff, threads, drafts, collapsed, active_file, content_width, metrics, &entries);

    var cursor: usize = 0;
    if (wanted_cursor) |wanted| cursor = findVisible(entries.items, wanted) orelse nearestVisibleAncestor(entries.items, nodes.items, wanted) orelse 0;
    if (entries.items.len > 0) cursor = @min(cursor, entries.items.len - 1);
    var scroll = wanted_scroll;
    const max_scroll = entries.items.len -| viewport;
    scroll = @min(scroll, max_scroll);
    if (cursor < scroll) scroll = cursor;
    if (viewport > 0 and cursor >= scroll + viewport) scroll = cursor + 1 - viewport;
    return .{ .entries = try entries.toOwnedSlice(allocator), .cursor = cursor, .scroll = scroll, .viewport = viewport };
}

fn insertFile(allocator: std.mem.Allocator, nodes: *std.ArrayList(Node), path: []const u8, file_index: usize) !void {
    var parent: usize = 0;
    var segment_start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, segment_start, '/')) |slash| {
        if (slash > segment_start) {
            const directory_path = path[0..slash];
            parent = try findOrAddDirectory(allocator, nodes, parent, directory_path);
        }
        segment_start = slash + 1;
    }
    try nodes.append(allocator, .{ .kind = .file, .path = path, .file_index = file_index, .parent = parent });
    try nodes.items[parent].children.append(allocator, nodes.items.len - 1);
}

fn findOrAddDirectory(allocator: std.mem.Allocator, nodes: *std.ArrayList(Node), parent: usize, path: []const u8) !usize {
    for (nodes.items[parent].children.items) |child| {
        const node = nodes.items[child];
        if (node.kind == .directory and std.mem.eql(u8, node.path, path)) return child;
    }
    try nodes.append(allocator, .{ .kind = .directory, .path = path, .parent = parent });
    const index = nodes.items.len - 1;
    try nodes.items[parent].children.append(allocator, index);
    return index;
}

fn sortChildren(nodes: *std.ArrayList(Node), parent: usize) void {
    const children = nodes.items[parent].children.items;
    var i: usize = 1;
    while (i < children.len) : (i += 1) {
        var j = i;
        while (j > 0 and less(nodes.items[children[j]], nodes.items[children[j - 1]])) : (j -= 1) std.mem.swap(usize, &children[j], &children[j - 1]);
    }
    for (children) |child| if (nodes.items[child].kind == .directory) sortChildren(nodes, child);
}

fn less(a: Node, b: Node) bool {
    const order = std.mem.order(u8, a.path, b.path);
    if (order == .eq) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return order == .lt;
}

fn emit(
    allocator: std.mem.Allocator,
    nodes: *const std.ArrayList(Node),
    start_index: usize,
    parent_identity: ?Identity,
    depth: usize,
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    collapsed: []const []const u8,
    active_file: ?usize,
    content_width: usize,
    metrics: CellMetrics,
    entries: *std.ArrayList(Entry),
) !void {
    const start = nodes.items[start_index];
    if (start.kind == .file) {
        const file = diff.files[start.file_index];
        const comments = anchoredThreadCount(threads, file);
        const draft_count = anchoredDraftCount(drafts, file);
        const tally = try makeTally(allocator, comments, draft_count);
        const fixed = 3 + metrics.width(tally);
        const indent = @min(depth * 2, content_width -| fixed);
        const available = content_width -| fixed -| indent;
        try entries.append(allocator, .{
            .identity = .{ .file = start.file_index },
            .parent = parent_identity,
            .depth = indent / 2,
            .label = try truncate(allocator, leaf(start.path), available, metrics),
            .active = active_file != null and active_file.? == start.file_index,
            .status = file.status,
            .comments = comments,
            .drafts = draft_count,
            .tally = tally,
            .tally_width = metrics.width(tally),
        });
        return;
    }

    var end_index = start_index;
    while (nodes.items[end_index].children.items.len == 1) {
        const child = nodes.items[nodes.items[end_index].children.items[0]];
        if (child.kind != .directory) break;
        end_index = nodes.items[end_index].children.items[0];
    }
    const end = nodes.items[end_index];
    const identity: Identity = .{ .directory = end.path };
    const expanded = !containsPath(collapsed, end.path);
    const parent_path = if (parent_identity) |parent| switch (parent) {
        .directory => |path| path,
        .file => "",
    } else "";
    const relative = if (parent_path.len == 0) end.path else end.path[@min(end.path.len, parent_path.len + 1)..];
    const prefix = @min(depth * 2 + 2, content_width);
    const directory_label = try std.fmt.allocPrint(allocator, "{s}/", .{relative});
    try entries.append(allocator, .{
        .identity = identity,
        .parent = parent_identity,
        .depth = @min(depth, (content_width -| 2) / 2),
        .label = try truncate(allocator, directory_label, content_width -| prefix, metrics),
        .expanded = expanded,
        .active_descendant = if (active_file) |index| pathDescends(diff.files[index].displayPath(), end.path) else false,
    });
    if (!expanded) return;
    for (end.children.items) |child| try emit(allocator, nodes, child, identity, depth + 1, diff, threads, drafts, collapsed, active_file, content_width, metrics, entries);
}

fn truncate(allocator: std.mem.Allocator, text: []const u8, width: usize, metrics: CellMetrics) ![]const u8 {
    if (metrics.width(text) <= width) return text;
    if (width == 0) return "";
    if (width == 1) return "…";
    var used: usize = 0;
    var byte_end: usize = 0;
    while (byte_end < text.len) {
        const measurement = metrics.next(text[byte_end..]);
        if (used + measurement.cell_width > width - 1) break;
        used += measurement.cell_width;
        byte_end += measurement.byte_len;
    }
    return std.fmt.allocPrint(allocator, "{s}…", .{text[0..byte_end]});
}

fn makeTally(allocator: std.mem.Allocator, comments: usize, drafts: usize) ![]const u8 {
    if (comments == 0 and drafts == 0) return "";
    if (comments > 0 and drafts > 0) return std.fmt.allocPrint(allocator, "●{d} ✎{d}", .{ comments, drafts });
    if (comments > 0) return std.fmt.allocPrint(allocator, "●{d}", .{comments});
    return std.fmt.allocPrint(allocator, "✎{d}", .{drafts});
}

fn leaf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn containsPath(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, wanted)) return true;
    return false;
}

fn pathDescends(path: []const u8, directory: []const u8) bool {
    return path.len > directory.len and std.mem.startsWith(u8, path, directory) and path[directory.len] == '/';
}

fn anchoredThreadCount(items: []const bbr.review.Thread, file: bbr.diff.File) usize {
    var count: usize = 0;
    for (items) |thread| if (thread.root.anchor) |anchor| if (matches(anchor.path, file)) {
        count += 1;
    };
    return count;
}

fn anchoredDraftCount(items: []const bbr.review.Draft, file: bbr.diff.File) usize {
    var count: usize = 0;
    for (items) |draft| {
        if (draft.parent != null) continue;
        const path = switch (draft.effectiveScope()) {
            .review => continue,
            .file => |scope| scope.path,
            .@"inline" => |anchor| anchor.path,
        };
        if (matches(path, file)) count += 1;
    }
    return count;
}

fn matches(path: []const u8, file: bbr.diff.File) bool {
    return std.mem.eql(u8, path, file.new_path) or std.mem.eql(u8, path, file.displayPath());
}

fn findVisible(entries: []const Entry, wanted: Identity) ?usize {
    for (entries, 0..) |entry, index| if (entry.identity.eql(wanted)) return index;
    return null;
}

fn nearestVisibleAncestor(entries: []const Entry, nodes: []const Node, wanted: Identity) ?usize {
    if (wanted != .file or wanted.file >= nodes.len) return null;
    // A hidden File is represented by the nearest visible collapsed Directory.
    for (entries, 0..) |entry, index| if (entry.identity == .directory and !entry.expanded and entry.active_descendant) return index;
    return null;
}

const testing = std.testing;

test "empty File Tree is a valid stable projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty_diff: bbr.diff.Diff = .{ .files = &.{} };
    const tree = try build(arena.allocator(), empty_diff, &.{}, &.{}, &.{}, null, 0, 0, null, 0, .bytes);
    try testing.expectEqual(@as(usize, 0), tree.entries.len);
    try testing.expectEqual(@as(usize, 0), tree.cursor);
    try testing.expectEqual(@as(usize, 0), tree.scroll);
}

test "compacted File Tree is deterministic and keeps stable identities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diff = try bbr.diff.parse(arena.allocator(), "diff --git a/docs/adr/a.md b/docs/adr/a.md\n--- a/docs/adr/a.md\n+++ b/docs/adr/a.md\n@@ -1 +1 @@\n-a\n+b\n" ++
        "diff --git a/src/z.zig b/src/z.zig\n--- a/src/z.zig\n+++ b/src/z.zig\n@@ -1 +1 @@\n-a\n+b\n");
    const tree = try build(arena.allocator(), diff, &.{}, &.{}, &.{}, 0, 28, 8, .{ .file = 0 }, 0, .bytes);
    try testing.expectEqual(@as(usize, 4), tree.entries.len);
    try testing.expectEqualStrings("docs/adr/", tree.entries[0].label);
    try testing.expect(tree.entries[0].identity.eql(.{ .directory = "docs/adr" }));
    try testing.expect(tree.entries[1].identity.eql(.{ .file = 0 }));
    try testing.expectEqualStrings("src/", tree.entries[2].label);
}

test "File Tree truncation respects injected grapheme boundaries and fixed tallies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try bbr.diff.parse(a, "diff --git a/very-long-🙂.zig b/very-long-🙂.zig\n--- a/very-long-🙂.zig\n+++ b/very-long-🙂.zig\n@@ -1 +1 @@\n-a\n+b\n");
    const comments = [_]bbr.review.Comment{.{ .id = 1, .author = "A", .body = "x", .anchor = .{ .path = "very-long-🙂.zig", .to = 1 } }};
    const threads = try bbr.review.buildThreads(a, &comments);
    const Metrics = struct {
        fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            const byte_len: usize = if (text[0] & 0xf8 == 0xf0) 4 else if (text[0] & 0xf0 == 0xe0) 3 else if (text[0] & 0xe0 == 0xc0) 2 else 1;
            return .{ .byte_len = byte_len, .cell_width = if (byte_len == 4) 2 else 1 };
        }
    };
    const metrics_vtable: CellMetrics.VTable = .{ .next = Metrics.next };
    const metrics_context: u8 = 0;
    const metrics: CellMetrics = .{ .ptr = &metrics_context, .vtable = &metrics_vtable };
    const tree = try build(a, diff, threads, &.{}, &.{}, 0, 12, 4, .{ .file = 0 }, 0, metrics);
    try testing.expectEqualStrings("●1", tree.entries[0].tally);
    try testing.expect(std.mem.endsWith(u8, tree.entries[0].label, "…"));
    try testing.expect(std.unicode.utf8ValidateSlice(tree.entries[0].label));
    try testing.expectEqualStrings("ab🙂…", try truncate(a, "ab🙂xy", 5, metrics));
}
