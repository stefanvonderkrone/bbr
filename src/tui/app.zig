//! The TUI: a unified diff viewer for one PR at a time, with a fuzzy PR Picker
//! (`p`) for switching. Boots vaxis on the alt-screen, renders a file Sidebar +
//! unified DiffPane over the current `Session`, and navigates with vim motions.
//!
//! Concurrency (design §10): the initial PR *and* every switch load their
//! Session on a worker thread (`std.Io.concurrent`) so the UI never blocks —
//! the alt-screen shows a "Loading PR #N…" frame until the first one arrives.
//! Each load bumps an Epoch; the worker stamps its
//! result with the epoch it was launched under and posts it back as a custom
//! `load_done` event. Only the result whose epoch is still current is applied —
//! results from superseded switches are discarded (Epoch cancellation). Workers
//! allocate from the stateless `page_allocator`, never the main thread's `gpa`.
//!
//! Opening the Picker uses the same pattern for its summaries fetch: `p` shows
//! the overlay instantly in a loading state and a worker posts `picker_done`,
//! stamped with a separate `picker_epoch` so a stale fetch can't populate a
//! Picker that was closed and reopened.
//!
//! Lifetime: vaxis cells borrow their text until `render`. A Session owns its
//! diff/threads for as long as it is current; per-frame gutter/overlay text is
//! synthesized into `frame_arena`, reset *after* render.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const render = @import("render.zig");
const theme = @import("theme.zig");
const Nav = @import("nav.zig").Nav;
const Picker = @import("picker.zig").Picker;
const composer_mod = @import("composer.zig");
const Composer = composer_mod.Composer;
const session = @import("session.zig");
const ArenaRing = @import("arena_ring.zig").ArenaRing;
const Session = session.Session;

const Credential = bbr.bitbucket.Credential;
const PullRequestSummary = bbr.bitbucket.PullRequestSummary;
const PendingReview = bbr.review.PendingReview;
const PendingReviewStore = bbr.review.PendingReviewStore;
const Draft = bbr.review.Draft;

/// Everything `run` needs to fetch and switch PRs. `online` is false for the
/// offline `demo`, which disables the network-backed Picker. `store` persists
/// the reviewer's pending Drafts (SQLite in production, `:memory:` for demo).
pub const RunCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    repo: []const u8,
    store: PendingReviewStore,
    online: bool = true,
};

/// The event type our vaxis loop carries: the terminal events we consume plus
/// two background-worker completions — `load_done` (a Session switch) and
/// `picker_done` (the PR summaries for an async Picker open).
const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    load_done: LoadDone,
    picker_done: PickerDone,
};

const LoadOutcome = union(enum) {
    ok: *Session,
    err: anyerror,
};

const LoadDone = struct {
    epoch: u64,
    outcome: LoadOutcome,
};

/// The PR summaries a Picker load fetched, owned by their own arena so the
/// worker can hand them across threads. The main thread copies what it needs
/// into `picker_arena` and calls `destroy` — mirroring `Session`.
const Summaries = struct {
    arena: std.heap.ArenaAllocator,
    prs: []const PullRequestSummary,

    fn destroy(self: *Summaries) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
};

const PickerOutcome = union(enum) {
    ok: *Summaries,
    err: anyerror,
};

const PickerDone = struct {
    epoch: u64,
    outcome: PickerOutcome,
};

/// Request handed to a Picker load worker (`repo` copied by value, as `LoadReq`).
const PickerReq = struct {
    repo: [256]u8,
    repo_len: usize,
    epoch: u64,
};

const Loop = vaxis.Loop(AppEvent);

/// A background load and the epoch it was launched under. We keep the future so
/// its thread resources are reclaimed (awaited) once its result event arrives.
const Load = struct {
    epoch: u64,
    future: std.Io.Future(void),
};

/// Request handed to a load worker. `repo` is copied by value (a fixed buffer)
/// so the worker has no dangling reference to the caller's slice.
const LoadReq = struct {
    repo: [256]u8,
    repo_len: usize,
    id: u64,
    epoch: u64,
};

/// Run the viewer. `initial` is a pre-built Session (the offline demo) or null,
/// in which case PR `initial_id` is loaded on a worker thread while a "Loading
/// PR #N…" frame shows — the TUI never blocks the alt-screen on the first fetch.
/// Takes ownership of the current Session and destroys it (and any it switches
/// to) before returning.
pub fn run(ctx: RunCtx, initial: ?*Session, initial_id: u64) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;

    var current: ?*Session = initial;
    defer if (current) |c| c.destroy();

    // Buffer-scoped arenas: the flattened rows for the *current* session, rebuilt
    // whenever the layout, scope, resolved toggle, or a fold changes (and on a PR
    // switch). A ring of 2 double-buffers the rebuild — the displayed buffer stays
    // valid while the next one is built in the other arena.
    var ring = ArenaRing(2).init(gpa);
    defer ring.deinit();

    var show_resolved = false;
    var layout: bbr.diff.Layout = .unified;
    // Diff scope: fold long context runs by default (the "Changes" scope). `f`
    // flips to whole-file; `expanded` holds individually-revealed folds (their
    // ids are Line pointers into the *current* session, cleared on a PR switch).
    var scope_fold = true;
    var expanded: std.ArrayList(*const bbr.diff.Line) = .empty;
    defer expanded.deinit(gpa);

    // PR-scoped: the reviewer's pending Drafts for the current PR, loaded from
    // the store on entry and reloaded on a PR switch (design §11 "drafts cache").
    // Draft bodies and anchor strings live in this arena.
    var review_arena = std.heap.ArenaAllocator.init(gpa);
    defer review_arena.deinit();
    // Empty until the first Session arrives; the initial-load path (below) fills
    // both `review` and `buf` on `load_done`.
    var review = if (current) |c|
        ctx.store.loadReview(review_arena.allocator(), c.pr.id) catch PendingReview.init(c.pr.id)
    else
        PendingReview.init(0);

    var buf: bbr.diff.Buffer = if (current) |c|
        try bbr.diff.buffer.buildWithComments(ring.next(), c.diff, layout, c.threads, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items))
    else
        .{ .rows = &.{}, .layout = layout };

    // Per-frame arena for synthesized gutter/overlay text; reset after render.
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    // Picker overlay + its own arena (summaries + haystacks live here while open).
    var picker_arena = std.heap.ArenaAllocator.init(gpa);
    defer picker_arena.deinit();
    var picker: ?Picker = null;

    // Composer overlay + its own arena (the label + body text live here while open).
    var composer_arena = std.heap.ArenaAllocator.init(gpa);
    defer composer_arena.deinit();
    var composer: ?Composer = null;

    var write_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &write_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, ctx.env_map, .{});
    defer vx.deinit(gpa, writer);

    var loop: Loop = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    // In-flight loads. Declared *after* the loop so this defer runs *before*
    // loop.stop(): we must await every worker (so none posts into a torn-down
    // queue) before the loop is destroyed.
    var epoch: u64 = 0;
    var loads: std.ArrayList(Load) = .empty;
    defer {
        for (loads.items) |*l| _ = l.future.await(io);
        loads.deinit(gpa);
    }

    // In-flight Picker summary loads, tracked separately from Session loads:
    // they carry their own generation (`picker_epoch`) so a stale fetch can't
    // populate a Picker that was closed and reopened. Awaited before teardown.
    var picker_epoch: u64 = 0;
    var picker_loads: std.ArrayList(Load) = .empty;
    defer {
        for (picker_loads.items) |*l| _ = l.future.await(io);
        picker_loads.deinit(gpa);
    }

    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);

    const active_theme = theme.dark;
    var nav = Nav.init(buf.rows.len, vx.window().height);
    var pending_g = false; // saw the first `g` of a `gg`
    var loading = false; // a switch is in flight for the current epoch
    var status_msg: ?[]const u8 = null; // transient error/status (static string)

    // Boot the initial PR through the same worker path as a switch, so the
    // alt-screen shows a "Loading PR #N…" frame instead of blocking on the
    // first fetch. `initial != null` is the demo, already built — nothing to do.
    if (current == null) {
        spawnLoad(ctx, &loop, &loads, &epoch, gpa, initial_id) catch |err| {
            status_msg = @errorName(err);
        };
        if (loads.items.len > 0) loading = true;
    }

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (composer) |*comp| {
                    // --- Composer mode: keys edit the draft body. ---
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                        comp.deinit();
                        composer = null;
                    } else if (key.matches('d', .{ .ctrl = true }) or key.matches('s', .{ .ctrl = true })) {
                        // Submit: persist the Draft, then close and re-weave. The
                        // Composer can only open over a loaded Session.
                        if (!comp.isBlank()) {
                            if (current) |cur| {
                                commitDraft(ctx.store, &review, review_arena.allocator(), cur.pr.id, comp) catch |err| {
                                    status_msg = @errorName(err);
                                };
                                buf = rebuild(ring.next(), cur, layout, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items)) catch buf;
                                nav.setRowCount(buf.rows.len);
                            }
                        }
                        comp.deinit();
                        composer = null;
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        comp.newline() catch {};
                    } else if (key.matches('w', .{ .ctrl = true })) {
                        comp.deleteWord(); // vim insert-mode ^W
                    } else if (key.matches('u', .{ .ctrl = true })) {
                        comp.deleteToLineStart(); // vim insert-mode ^U
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        comp.backspace();
                    } else if (key.text) |t| {
                        comp.insert(t) catch {};
                    }
                } else if (picker) |*p| {
                    // --- Picker mode: keys drive the overlay. ---
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                        picker = null;
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        const sel = p.selection();
                        picker = null;
                        if (sel) |s| {
                            spawnLoad(ctx, &loop, &loads, &epoch, gpa, s.id) catch |err| {
                                status_msg = @errorName(err);
                            };
                            if (loads.items.len > 0) {
                                loading = true;
                                status_msg = null;
                            }
                        }
                    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
                        p.moveUp();
                    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
                        p.moveDown();
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        p.backspace();
                    } else if (key.text) |t| {
                        p.insert(t);
                    }
                } else {
                    // --- Viewer mode. ---
                    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;

                    // `p` opens the Picker even while the initial PR is still
                    // loading — it needs no Session. Everything else acts on the
                    // current Session/Buffer, so it waits until one is loaded.
                    if (key.matches('p', .{}) and ctx.online) {
                        openPicker(ctx, &picker, &picker_arena, &loop, &picker_loads, &picker_epoch, gpa) catch |err| {
                            status_msg = @errorName(err);
                        };
                    } else if (current) |cur| {
                        if (key.matches('R', .{})) {
                            show_resolved = !show_resolved;
                            buf = rebuild(ring.next(), cur, layout, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items)) catch buf;
                            nav.setRowCount(buf.rows.len);
                        } else if (key.matches('s', .{})) {
                            layout = if (layout == .unified) .side_by_side else .unified;
                            buf = rebuild(ring.next(), cur, layout, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items)) catch buf;
                            nav.setRowCount(buf.rows.len);
                        } else if (key.matches('f', .{})) {
                            // Toggle the diff scope: fold long context vs. whole file.
                            scope_fold = !scope_fold;
                            expanded.clearRetainingCapacity();
                            buf = rebuild(ring.next(), cur, layout, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items)) catch buf;
                            nav.setRowCount(buf.rows.len);
                        } else if (key.matches('c', .{})) {
                            // Author a PR-level (top-level) comment.
                            openComposer(&composer, &composer_arena, .{ .kind = .top_level, .label = "New comment" });
                        } else if (key.matches('i', .{}) or key.matches('S', .{})) {
                            // Author an inline comment / suggestion on the cursor's line.
                            const kind: bbr.review.DraftKind = if (key.matches('S', .{})) .suggestion else .inline_comment;
                            openInline(&composer, &composer_arena, cur, buf, nav.cursor, kind) catch |err| {
                                status_msg = @errorName(err);
                            };
                        } else if (key.matches('r', .{})) {
                            // Reply to the comment or draft under the cursor.
                            openReply(&composer, &composer_arena, buf, nav.cursor) catch |err| {
                                status_msg = @errorName(err);
                            };
                        } else if (key.matches(vaxis.Key.enter, .{})) {
                            // Expand the fold under the cursor, if any.
                            if (nav.cursor < buf.rows.len and buf.rows[nav.cursor] == .fold) {
                                expanded.append(gpa, buf.rows[nav.cursor].fold.id) catch {};
                                buf = rebuild(ring.next(), cur, layout, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items)) catch buf;
                                nav.setRowCount(buf.rows.len);
                            }
                        } else if (handleKey(&nav, &pending_g, key)) |_| {}
                    }
                }
            },
            .winsize => |ws| {
                try vx.resize(gpa, writer, ws);
                nav.setViewport(vx.window().height);
            },
            .load_done => |done| {
                reap(&loads, io, done.epoch);
                if (done.epoch != epoch) {
                    // Superseded by a newer switch: discard.
                    if (done.outcome == .ok) done.outcome.ok.destroy();
                } else {
                    loading = false;
                    switch (done.outcome) {
                        .ok => |s| {
                            // On the initial boot `current` is null; on a switch
                            // it's the outgoing Session we now replace.
                            if (current) |c| c.destroy();
                            current = s;
                            // Expanded-fold ids pointed into the old session's diff.
                            expanded.clearRetainingCapacity();
                            // Load the new PR's pending Drafts into a fresh arena.
                            _ = review_arena.reset(.retain_capacity);
                            review = ctx.store.loadReview(review_arena.allocator(), s.pr.id) catch PendingReview.init(s.pr.id);
                            buf = rebuild(ring.next(), s, layout, buildOpts(show_resolved, scope_fold, expanded.items, review.drafts.items)) catch buf;
                            nav = Nav.init(buf.rows.len, vx.window().height);
                            pending_g = false;
                            status_msg = null;
                        },
                        .err => |e| status_msg = @errorName(e),
                    }
                }
            },
            .picker_done => |done| {
                reap(&picker_loads, io, done.epoch);
                // Apply only if this is the current open and the Picker is still
                // up (not closed, not superseded by a reopen). Otherwise discard.
                if (done.epoch != picker_epoch or picker == null) {
                    if (done.outcome == .ok) done.outcome.ok.destroy();
                } else switch (done.outcome) {
                    .ok => |sums| {
                        defer sums.destroy();
                        // Copy the summaries into the Picker's own arena; the
                        // worker's arena dies with `sums` on return.
                        if (dupeSummaries(picker_arena.allocator(), sums.prs)) |copied| {
                            if (picker) |*p| p.populate(copied) catch |err| {
                                status_msg = @errorName(err);
                                picker = null;
                            };
                        } else |err| {
                            status_msg = @errorName(err);
                            picker = null;
                        }
                    },
                    .err => |e| {
                        status_msg = @errorName(e);
                        picker = null;
                    },
                }
            },
        }

        const win = vx.window();
        const frame = frame_arena.allocator();
        if (current) |cur| {
            const selected_file = fileIndexForRow(buf, nav.cursor);
            render.draw(frame, win, cur.diff, buf, active_theme, nav, selected_file, cur.threads, review.drafts.items);
            drawStatus(frame, win, cur.pr, nav, buf, layout, scope_fold, show_resolved, loading, status_msg);
        } else {
            render.drawLoading(frame, win, initial_id, active_theme, status_msg);
        }
        if (picker) |*p| render.drawPicker(frame, win, p, active_theme);
        if (composer) |*comp| render.drawComposer(frame, win, comp, active_theme);
        try vx.render(writer);
        _ = frame_arena.reset(.retain_capacity);
    }
}

/// Assemble the buffer build options from the current toggles, the revealed
/// folds, and the pending Drafts. Rows borrow the session's diff/threads and the
/// review arena's drafts (not the buffer arena), so resetting it is safe.
fn buildOpts(show_resolved: bool, scope_fold: bool, expanded: []const *const bbr.diff.Line, drafts: []const Draft) bbr.diff.BuildOptions {
    return .{ .show_resolved = show_resolved, .fold_context = scope_fold, .expanded = expanded, .drafts = drafts };
}

fn rebuild(alloc: std.mem.Allocator, s: *const Session, layout: bbr.diff.Layout, opts: bbr.diff.BuildOptions) !bbr.diff.Buffer {
    return bbr.diff.buffer.buildWithComments(alloc, s.diff, layout, s.threads, opts);
}

/// Open the Picker immediately in a loading state and kick the summaries fetch
/// onto a worker thread; `picker_done` populates it when the list returns. The
/// picker state (and the copied summaries) live in `picker_arena`, reset per
/// open. If the spawn fails we leave the Picker closed and surface the error.
fn openPicker(
    ctx: RunCtx,
    picker: *?Picker,
    picker_arena: *std.heap.ArenaAllocator,
    loop: *Loop,
    picker_loads: *std.ArrayList(Load),
    picker_epoch: *u64,
    gpa: std.mem.Allocator,
) !void {
    _ = picker_arena.reset(.retain_capacity);
    try spawnPickerLoad(ctx, loop, picker_loads, picker_epoch, gpa);
    picker.* = Picker.initLoading(picker_arena.allocator());
}

/// Deep-copy PR summaries into `a` (the Picker's arena) so they outlive the
/// worker's arena. The set is small — the open PRs of one repo.
fn dupeSummaries(a: std.mem.Allocator, prs: []const PullRequestSummary) ![]PullRequestSummary {
    const out = try a.alloc(PullRequestSummary, prs.len);
    for (prs, out) |src, *dst| {
        dst.* = .{
            .id = src.id,
            .title = try a.dupe(u8, src.title),
            .state = try a.dupe(u8, src.state),
            .author_display_name = try a.dupe(u8, src.author_display_name),
            .source_branch = try a.dupe(u8, src.source_branch),
            .destination_branch = try a.dupe(u8, src.destination_branch),
        };
    }
    return out;
}

/// Open the Composer with a ready-made Request (a static label). Resets the
/// composer arena, which backs the body text while open.
fn openComposer(composer: *?Composer, arena: *std.heap.ArenaAllocator, request: composer_mod.Request) void {
    _ = arena.reset(.retain_capacity);
    composer.* = Composer.init(arena.allocator(), request);
}

/// Open the Composer for an inline comment/suggestion anchored to the cursor's
/// diff line. Fails if the cursor isn't on a line. The anchor's path/commit are
/// duped into the composer arena so they survive a PR switch mid-compose.
fn openInline(
    composer: *?Composer,
    arena: *std.heap.ArenaAllocator,
    s: *const Session,
    buf: bbr.diff.Buffer,
    cursor: usize,
    kind: bbr.review.DraftKind,
) !void {
    const ln = lineAtCursor(buf, cursor) orelse return error.NotOnALine;
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    const file_idx = fileIndexForRow(buf, cursor);
    const path = if (file_idx < s.diff.files.len) s.diff.files[file_idx].new_path else "";
    const anchor: bbr.review.Anchor = .{
        .path = try a.dupe(u8, path),
        .from = if (ln.new_no == null) ln.old_no else null,
        .to = ln.new_no,
        .commit = try a.dupe(u8, s.pr.source_commit),
    };
    const noun: []const u8 = if (kind == .suggestion) "Suggest on" else "Comment on";
    const label = std.fmt.allocPrint(a, "{s} {s}:{d}", .{ noun, path, ln.new_no orelse ln.old_no orelse 0 }) catch "Comment";
    composer.* = Composer.init(a, .{ .kind = kind, .anchor = anchor, .label = label });
}

/// Open the Composer as a reply to the comment or draft under the cursor. The
/// reply co-locates with its parent (copying the parent's anchor); its `parent`
/// drives submission ordering — a reply to a pending Draft posts after it (M9).
fn openReply(composer: *?Composer, arena: *std.heap.ArenaAllocator, buf: bbr.diff.Buffer, cursor: usize) !void {
    if (cursor >= buf.rows.len) return error.NoReplyTarget;
    // A reply is placed under its parent (the `parent` link drives rendering and
    // submission order), so it needs no anchor of its own — the parent already
    // carries the diff location.
    const parent: bbr.review.draft.Parent = switch (buf.rows[cursor]) {
        .comment => |cr| .{ .comment = cr.comment.id },
        .draft => |dr| .{ .draft = dr.draft.local_id },
        else => return error.NoReplyTarget,
    };
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    composer.* = Composer.init(a, .{ .kind = .reply, .parent = parent, .label = "Reply" });
}

/// Persist a composed Draft: dupe its body (fencing a suggestion) and anchor
/// strings into the review arena, add it to the PendingReview, and write it
/// through the store so it survives a crash / quit / PR switch.
fn commitDraft(store: PendingReviewStore, review: *PendingReview, a: std.mem.Allocator, pr_id: u64, comp: *const Composer) !void {
    var nd = comp.toNewDraft();
    nd.body = if (nd.kind == .suggestion)
        try std.fmt.allocPrint(a, "```suggestion\n{s}\n```", .{comp.body()})
    else
        try a.dupe(u8, comp.body());
    if (nd.anchor) |*anc| {
        anc.path = try a.dupe(u8, anc.path);
        if (anc.commit) |cm| anc.commit = try a.dupe(u8, cm);
    }
    const id = try review.add(a, nd);
    if (review.get(id)) |d| try store.put(pr_id, d.*);
}

/// The diff line under the cursor (a unified `.line` or either side of a
/// side-by-side `.line_pair`), or null when the row isn't a line.
fn lineAtCursor(buf: bbr.diff.Buffer, cursor: usize) ?*const bbr.diff.Line {
    if (cursor >= buf.rows.len) return null;
    return switch (buf.rows[cursor]) {
        .line => |lr| lr.line,
        .line_pair => |p| if (p.right) |rr| rr.line else if (p.left) |ll| ll.line else null,
        else => null,
    };
}

/// Launch a background load for `id`, bumping the epoch. The worker posts a
/// `load_done` event stamped with this epoch; only the current epoch's result
/// is applied. On success the future is tracked so we can await it later.
fn spawnLoad(
    ctx: RunCtx,
    loop: *Loop,
    loads: *std.ArrayList(Load),
    epoch: *u64,
    gpa: std.mem.Allocator,
    id: u64,
) !void {
    epoch.* += 1;
    var req: LoadReq = .{ .repo = undefined, .repo_len = @min(ctx.repo.len, 256), .id = id, .epoch = epoch.* };
    @memcpy(req.repo[0..req.repo_len], ctx.repo[0..req.repo_len]);

    const fut = try ctx.io.concurrent(loadWorker, .{ loop, ctx.io, ctx.env_map, ctx.cred, req });
    try loads.append(gpa, .{ .epoch = epoch.*, .future = fut });
}

/// Launch a background Picker summaries fetch, bumping `picker_epoch`. The
/// worker posts a `picker_done` stamped with this epoch; only a result matching
/// the current epoch (and an open Picker) is applied.
fn spawnPickerLoad(
    ctx: RunCtx,
    loop: *Loop,
    picker_loads: *std.ArrayList(Load),
    picker_epoch: *u64,
    gpa: std.mem.Allocator,
) !void {
    picker_epoch.* += 1;
    var req: PickerReq = .{ .repo = undefined, .repo_len = @min(ctx.repo.len, 256), .epoch = picker_epoch.* };
    @memcpy(req.repo[0..req.repo_len], ctx.repo[0..req.repo_len]);

    const fut = try ctx.io.concurrent(pickerWorker, .{ loop, ctx.io, ctx.env_map, ctx.cred, req });
    try picker_loads.append(gpa, .{ .epoch = picker_epoch.*, .future = fut });
}

/// Runs on a worker thread. Fetches the repo's open-PR summaries off the page
/// allocator and posts them back. Frees the result if the hand-off fails.
fn pickerWorker(
    loop: *Loop,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    req: PickerReq,
) void {
    const repo = req.repo[0..req.repo_len];
    const outcome: PickerOutcome = if (fetchSummaries(io, env_map, cred, repo)) |s|
        .{ .ok = s }
    else |err|
        .{ .err = err };

    loop.postEvent(.{ .picker_done = .{ .epoch = req.epoch, .outcome = outcome } }) catch {
        if (outcome == .ok) outcome.ok.destroy();
    };
}

/// Fetch the repo's open-PR summaries into a self-owned `Summaries` on the page
/// allocator (thread-safe, so the worker never races the main thread's gpa).
fn fetchSummaries(
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    repo: []const u8,
) !*Summaries {
    const page = std.heap.page_allocator;
    const s = try page.create(Summaries);
    errdefer page.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(page);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    var http = bbr.http.StdHttpClient.init(a, io);
    defer http.deinit();
    try http.initDefaultProxies(a, env_map);
    const bb = bbr.bitbucket.Client.init(http.httpClient(), cred);

    s.prs = try bb.listPullRequests(a, repo, .{});
    return s;
}

/// Await and drop the tracked load with `epoch` (its result has arrived). The
/// worker returns right after posting, so the await completes promptly.
fn reap(loads: *std.ArrayList(Load), io: std.Io, epoch: u64) void {
    var i: usize = 0;
    while (i < loads.items.len) : (i += 1) {
        if (loads.items[i].epoch == epoch) {
            _ = loads.items[i].future.await(io);
            _ = loads.swapRemove(i);
            return;
        }
    }
}

/// Runs on a worker thread. Loads the Session off the main allocator (via the
/// stateless page_allocator) and posts it back. If the hand-off fails (shutting
/// down), the session is freed here rather than leaked.
fn loadWorker(
    loop: *Loop,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    req: LoadReq,
) void {
    const repo = req.repo[0..req.repo_len];
    const outcome: LoadOutcome = if (session.load(io, std.heap.page_allocator, env_map, cred, repo, req.id)) |s|
        .{ .ok = s }
    else |err|
        .{ .err = err };

    loop.postEvent(.{ .load_done = .{ .epoch = req.epoch, .outcome = outcome } }) catch {
        if (outcome == .ok) outcome.ok.destroy();
    };
}

/// Apply a key to `nav`. Returns non-null when the key was a recognized motion.
fn handleKey(nav: *Nav, pending_g: *bool, key: vaxis.Key) ?void {
    // `gg` is a two-key motion: the first `g` arms, the second fires.
    if (pending_g.*) {
        pending_g.* = false;
        if (key.matches('g', .{})) {
            nav.toTop();
            return {};
        }
        // Any other key after a lone `g` just falls through to normal handling.
    }

    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        nav.down();
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        nav.up();
    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
        nav.halfPageDown();
    } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
        nav.halfPageUp();
    } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) {
        nav.toBottom();
    } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) {
        pending_g.* = true;
    } else if (key.text) |t| {
        // Numeric Count prefix (5j, 42G, …).
        if (t.len == 1 and t[0] >= '0' and t[0] <= '9') {
            nav.pushDigit(t[0] - '0');
        } else return null;
    } else return null;
    return {};
}

/// Which file (index into `diff.files`) the row at `cursor` belongs to, so the
/// sidebar highlight tracks the diff pane. Counts file headers up to the cursor.
fn fileIndexForRow(buf: bbr.diff.Buffer, cursor: usize) usize {
    var idx: usize = 0;
    var seen_any = false;
    var i: usize = 0;
    while (i <= cursor and i < buf.rows.len) : (i += 1) {
        if (buf.rows[i] == .file_header) {
            if (seen_any) idx += 1 else seen_any = true;
        }
    }
    return idx;
}

/// A one-line status bar across the bottom row. `frame` is the per-frame arena
/// (outlives render); a stack buffer would dangle since cells borrow the text.
fn drawStatus(
    frame: std.mem.Allocator,
    win: vaxis.Window,
    pr: bbr.bitbucket.PullRequest,
    nav: Nav,
    buf: bbr.diff.Buffer,
    layout: bbr.diff.Layout,
    scope_fold: bool,
    show_resolved: bool,
    loading: bool,
    status_msg: ?[]const u8,
) void {
    if (win.height == 0) return;
    const row = win.height - 1;
    const layout_hint: []const u8 = if (layout == .unified) "s split" else "s unified";
    const scope_hint: []const u8 = if (scope_fold) "f whole" else "f changes";
    const resolved_hint: []const u8 = if (show_resolved) "R hide resolved" else "R show resolved";
    // A transient message (error) or the loading indicator takes the tail slot.
    const tail: []const u8 = if (status_msg) |m| m else if (loading) "loading…" else "c/i comment  ·  r reply  ·  p switch  ·  q quit";
    const text = std.fmt.allocPrint(frame, " #{d} {s}  ·  {s} → {s}  ·  {d}/{d}  ·  {s}  ·  {s}  ·  {s}  ·  {s} ", .{
        pr.id,
        pr.title,
        pr.source_branch,
        pr.destination_branch,
        @min(nav.cursor + 1, buf.rows.len),
        buf.rows.len,
        layout_hint,
        scope_hint,
        resolved_hint,
        tail,
    }) catch " q quit ";
    const style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } };
    var c: u16 = 0;
    while (c < win.width) : (c += 1) win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .wrap = .none });
}

// ---------------------------------------------------------------------------
// Tests — pure helpers; the render/nav/theme/picker modules test their drawing.
// ---------------------------------------------------------------------------
const testing = std.testing;

test "fileIndexForRow tracks which file a row belongs to" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw =
        \\diff --git a/one.txt b/one.txt
        \\--- a/one.txt
        \\+++ b/one.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\diff --git a/two.txt b/two.txt
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    ;
    const diff = try bbr.diff.parse(a, raw);
    const buf = try bbr.diff.buffer.build(a, diff, .unified);

    // File one: rows 0..3 (header, hunk, removed, added).
    try testing.expectEqual(@as(usize, 0), fileIndexForRow(buf, 0));
    try testing.expectEqual(@as(usize, 0), fileIndexForRow(buf, 3));
    // File two: rows 4..7.
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(buf, 4));
    try testing.expectEqual(@as(usize, 1), fileIndexForRow(buf, 7));
}

test "lineAtCursor returns the diff line under the cursor, null elsewhere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try bbr.diff.parse(a, "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n@@ -1 +1 @@\n-x\n+y\n");
    const buf = try bbr.diff.buffer.build(a, diff, .unified);

    // Rows: 0 file_header, 1 hunk_header, 2 line(-x), 3 line(+y).
    try testing.expect(lineAtCursor(buf, 0) == null); // header
    try testing.expect(lineAtCursor(buf, 2) != null); // removed line
    try testing.expectEqual(@as(?u32, 1), lineAtCursor(buf, 3).?.new_no); // added line's new number
}

test "commitDraft fences a suggestion, adds it to the review, and persists it" {
    var mem = bbr.review.InMemoryStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();

    var review_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer review_arena.deinit();
    var review = PendingReview.init(42);

    var comp = Composer.init(testing.allocator, .{
        .kind = .suggestion,
        .anchor = .{ .path = "f.zig", .to = 3, .commit = "c0" },
        .label = "Suggest on f.zig:3",
    });
    defer comp.deinit();
    try comp.insert("do it this way");

    try commitDraft(store, &review, review_arena.allocator(), 42, &comp);

    // Added to the in-memory review, with the suggestion body fenced.
    try testing.expectEqual(@as(usize, 1), review.drafts.items.len);
    const d = review.drafts.items[0];
    try testing.expect(d.kind == .suggestion);
    try testing.expectEqualStrings("```suggestion\ndo it this way\n```", d.body);

    // Persisted through the store: a fresh load round-trips it.
    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    const loaded = try store.load(load_arena.allocator(), 42);
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expectEqualStrings("f.zig", loaded[0].anchor.?.path);
    try testing.expectEqualStrings("c0", loaded[0].anchor.?.commit.?);
}

// Force the presentation modules' tests into the exe test binary.
test {
    _ = @import("render.zig");
    _ = @import("theme.zig");
    _ = @import("nav.zig");
    _ = @import("picker.zig");
    _ = @import("session.zig");
    _ = @import("arena_ring.zig");
    _ = @import("composer.zig");
}
