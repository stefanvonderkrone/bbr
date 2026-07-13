//! The TUI: a unified diff viewer for one PR at a time, with a fuzzy PR Picker
//! (`p`) for switching. Boots vaxis on the alt-screen, renders a file Sidebar +
//! unified DiffPane over the current `Session`, and navigates with vim motions.
//! `[`/`]` jump between files; `o` isolates the focused file (the single-File
//! Buffer of the domain model) and then `[`/`]` step which file is isolated.
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
//! `f` cycles the diff scope Changes → fetched-whole → whole-file. The whole-file
//! scope needs the focused file's full text, fetched lazily on the same worker
//! pattern (`enrichment_done`, keyed by PR id + file index): the frame renders the
//! fetched lines immediately and re-weaves when the blob arrives (M9).
//!
//! `X` submits the pending review (M10): a worker snapshots the Drafts, then
//! drives the pure `Submission` engine — POSTing each in topological order,
//! remapping reply parents to their new ids, retrying with backoff, aborting on
//! auth — and streams each item's fate back as `submit_progress` (persisted as
//! it lands) plus a final `submit_done`. A clean batch deletes its now-published
//! Drafts (ADR-0007); a partial one keeps the failures pending for a retry (`X`
//! again is selective retry — already-posted Drafts are skipped).
//!
//! Lifetime: vaxis cells borrow their text until `render`. A Session owns its
//! diff/threads and transferred File Enrichment sides for as long as it is
//! current; per-frame gutter/overlay text is synthesized into `frame_arena`,
//! reset *after* render.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const render = @import("render.zig");
const theme = @import("theme.zig");
const Nav = @import("nav.zig").Nav;
const keymap = @import("keymap.zig");
const Picker = @import("picker.zig").Picker;
const composer_mod = @import("composer.zig");
const Composer = composer_mod.Composer;
const session = @import("session.zig");
const file_enrichment = @import("file_enrichment.zig");
const ArenaRing = @import("arena_ring.zig").ArenaRing;
const Session = session.Session;

const Credential = bbr.bitbucket.Credential;
const PullRequestSummary = bbr.bitbucket.PullRequestSummary;
const PendingReview = bbr.review.PendingReview;
const PendingReviewStore = bbr.review.PendingReviewStore;
const ReviewKey = bbr.review.ReviewKey;
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
    active_theme: theme.Theme,
    keymap: keymap.Keymap,
    highlighter: bbr.highlight.Highlighter,
    highlight_max_file_bytes: usize,
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
    enrichment_done: EnrichmentDone,
    submit_progress: SubmitProgress,
    submit_done: SubmitDone,
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

const EnrichmentOutcome = union(enum) {
    ok: file_enrichment.Result,
    err: anyerror,
};

/// A per-File enrichment result, tagged with the PR and file it targeted so a
/// result for a superseded PR (or an already-filled slot) is discarded.
const EnrichmentDone = struct {
    epoch: u64,
    pr_id: u64,
    file_idx: usize,
    outcome: EnrichmentOutcome,
};

/// Request handed to an enrichment worker. Repository, commit, and path values are copied
/// (fixed buffers) so the worker holds no reference to caller slices.
const EnrichmentReq = struct {
    repo: [256]u8,
    repo_len: usize,
    source_commit: [64]u8,
    source_commit_len: usize,
    destination_commit: [64]u8,
    destination_commit_len: usize,
    old_path: [512]u8,
    old_path_len: usize,
    new_path: [512]u8,
    new_path_len: usize,
    status: bbr.diff.FileStatus,
    pr_id: u64,
    file_idx: usize,
    epoch: u64,
};

/// A File enrichment in flight, keyed by PR + file so `ensureEnrichment` never double-runs
/// and a stale result (old PR) can't cancel a live entry.
const InflightEnrichment = struct {
    pr_id: u64,
    file_idx: usize,
};

/// One item's fate as the submission worker decides it, posted back so the main
/// thread can persist the Draft's new state (ADR-0007) as the batch runs. Carries
/// only plain values, so it crosses the thread boundary freely.
const SubmitProgress = struct {
    epoch: u64,
    pr_id: u64,
    item: bbr.review.ItemResult,
};

/// The terminal result of a submission batch. `stale` means the PR head moved
/// since load so nothing was posted (§9 stale-anchor guard); `aborted` carries
/// an auth failure that stopped the batch. Otherwise the roll-up counts describe
/// what happened, and a clean batch (`failed == 0 and skipped == 0`) triggers the
/// delete-on-batch-success step.
const SubmitDone = struct {
    epoch: u64,
    pr_id: u64,
    posted: usize,
    failed: usize,
    skipped: usize,
    aborted: ?anyerror,
    stale: bool,
};

/// The outcome of a finished Submission, shown in a floating result dialog until
/// the reviewer dismisses it. `aborted`/`stale` name the terminal condition; a
/// normal finish just carries the tallies. Held in run-scoped state, not an
/// event, so it survives frames while the post-submit re-fetch runs behind it.
const SubmitResult = struct {
    posted: usize,
    failed: usize,
    skipped: usize,
    aborted: ?[]const u8 = null, // @errorName is static — safe to borrow
    stale: bool = false,
};

/// A submission request handed to the worker: a self-owned snapshot of the PR's
/// pending Drafts (deep-copied into `arena` so the worker never touches
/// main-thread memory), plus the repo, PR id, and the source commit we loaded
/// against (for the stale-anchor check). The worker owns it and `destroy`s it.
const Submit = struct {
    arena: std.heap.ArenaAllocator,
    review: PendingReview,
    repo: []const u8,
    pr_id: u64,
    loaded_commit: []const u8,
    epoch: u64,

    fn destroy(self: *Submit) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
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
    // Diff scope, cycled by `f`: Changes (long context folded) → fetched-whole
    // (every fetched line, no folds) → whole-file (the real full file, blob
    // spliced in — M9). `expanded` holds individually-revealed folds (their ids
    // are Line pointers into the *current* session, cleared on a PR switch).
    var scope: Scope = .changes;
    var expanded: std.ArrayList(*const bbr.diff.Line) = .empty;
    defer expanded.deinit(gpa);

    // Isolate view: when set, the pane shows only this file (index into
    // `diff.files`); `o` toggles it, `[`/`]` change which file. `null` is the
    // all-files scroll. Cleared on a PR switch (indices belong to that diff).
    var isolate_file: ?usize = null;

    // PR-scoped: the reviewer's pending Drafts for the current PR, loaded from
    // the store on entry and reloaded on a PR switch (design §11 "drafts cache").
    // Draft bodies and anchor strings live in this arena.
    var review_arena = std.heap.ArenaAllocator.init(gpa);
    defer review_arena.deinit();
    // Empty until the first Session arrives; the initial-load path (below) fills
    // both `review` and `buf` on `load_done`.
    var review = if (current) |c|
        ctx.store.loadReview(review_arena.allocator(), reviewKey(ctx, c.pr.id)) catch PendingReview.init(c.pr.id)
    else
        PendingReview.init(0);

    var buf: bbr.diff.Buffer = if (current) |c|
        try rebuildBuffered(&ring, c, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(c)))
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

    // In-flight per-File enrichments, tracked like the loads above so every
    // worker is awaited before teardown. `enrichment_inflight` dedupes work
    // per (PR, file) so `ensureEnrichment` fires each file's fetch at most once.
    var enrichment_epoch: u64 = 0;
    var enrichment_loads: std.ArrayList(Load) = .empty;
    defer {
        for (enrichment_loads.items) |*l| _ = l.future.await(io);
        enrichment_loads.deinit(gpa);
    }
    var enrichment_inflight: std.ArrayList(InflightEnrichment) = .empty;
    defer enrichment_inflight.deinit(gpa);

    // In-flight submission batch (M10), tracked like the loads above so the
    // worker is awaited before teardown. `submit_epoch` discards submit events
    // from a batch superseded by a PR switch; only one batch runs at a time.
    var submit_epoch: u64 = 0;
    var submit_loads: std.ArrayList(Load) = .empty;
    defer {
        for (submit_loads.items) |*l| _ = l.future.await(io);
        submit_loads.deinit(gpa);
    }
    var submitting = false;
    var submit_total: usize = 0; // items in the running batch (for the modal)
    var submit_seen: usize = 0; // items reported so far (posted/failed/skipped)
    var submit_result: ?SubmitResult = null; // finished outcome, shown until dismissed
    var show_help = false; // the keybinding-help Overlay is up
    var reconciling = false; // a post-submit re-fetch is in flight (keep the result dialog, not the loading frame)

    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);

    const active_theme = ctx.active_theme;
    var nav = Nav.init(buf.rows.len, vx.window().height);
    const km = ctx.keymap;
    var resolver = keymap.Resolver{}; // tracks the leader across keypresses
    var loading = false; // a load is in flight for the current epoch
    var loading_id: u64 = initial_id; // PR the in-flight load targets (for the loading view)
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
                if (submit_result != null) {
                    // --- Submit result dialog: any key dismisses it. ---
                    submit_result = null;
                } else if (show_help) {
                    // --- Help Overlay: any key dismisses it. ---
                    show_help = false;
                } else if (composer) |*comp| {
                    // --- Composer mode: keys edit the draft body. ---
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                        comp.deinit();
                        composer = null;
                    } else if (key.matches('d', .{ .ctrl = true }) or key.matches('s', .{ .ctrl = true })) {
                        // Submit: persist the Draft, then close and re-weave. The
                        // Composer can only open over a loaded Session.
                        if (!comp.isBlank()) {
                            if (current) |cur| {
                                commitDraft(ctx.store, &review, review_arena.allocator(), reviewKey(ctx, cur.pr.id), comp) catch |err| {
                                    status_msg = @errorName(err);
                                };
                                buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
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
                                loading_id = s.id;
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
                    // --- Viewer mode. Resolve the key through the Keymap; the
                    // Resolver threads the leader grammar (gg/zz) and surfaces
                    // Count digits, and the resolved Action drives one switch. ---
                    switch (resolver.feed(km, key)) {
                        .none => {},
                        // A Count digit only matters over a loaded Session.
                        .digit => |d| if (current != null) nav.pushDigit(d),
                        .action => |act| switch (act) {
                            // Quit needs no Session.
                            .quit => break,
                            // `p` opens the Picker even while the initial PR is
                            // still loading — it needs no Session.
                            .open_picker => if (ctx.online) {
                                openPicker(ctx, &picker, &picker_arena, &loop, &picker_loads, &picker_epoch, gpa) catch |err| {
                                    status_msg = @errorName(err);
                                };
                            },
                            // The help Overlay needs no Session — it reads the Keymap.
                            .help => show_help = true,
                            // Everything else acts on the current Session/Buffer,
                            // so it waits until one is loaded.
                            else => if (current) |cur| switch (act) {
                                .quit, .open_picker, .help => unreachable, // handled above
                                // --- motions ---
                                .down => nav.down(),
                                .up => nav.up(),
                                .half_page_down => nav.halfPageDown(),
                                .half_page_up => nav.halfPageUp(),
                                .page_down => nav.pageDown(),
                                .page_up => nav.pageUp(),
                                .to_top => nav.toTop(),
                                .to_bottom => nav.toBottom(),
                                .center => nav.center(),
                                .scroll_cursor_top => nav.scrollCursorTop(),
                                .scroll_cursor_bottom => nav.scrollCursorBottom(),
                                .cursor_view_top => nav.cursorToViewTop(),
                                .cursor_view_middle => nav.cursorToViewMiddle(),
                                .cursor_view_bottom => nav.cursorToViewBottom(),
                                // Shift+arrow: start (or extend) a selection, then
                                // move. Plain motions leave `mark` untouched, so
                                // they extend an already-active selection.
                                .select_down => {
                                    nav.ensureMark();
                                    nav.down();
                                },
                                .select_up => {
                                    nav.ensureMark();
                                    nav.up();
                                },
                                // --- commands ---
                                .toggle_resolved => {
                                    show_resolved = !show_resolved;
                                    buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                    nav.setRowCount(buf.rows.len);
                                },
                                .toggle_layout => {
                                    layout = if (layout == .unified) .side_by_side else .unified;
                                    buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                    nav.setRowCount(buf.rows.len);
                                },
                                .cycle_scope => {
                                    // Cycle the diff scope: Changes → fetched-whole
                                    // → whole-file. The whole-file blob is fetched
                                    // lazily below the loop.
                                    scope = scope.next();
                                    expanded.clearRetainingCapacity();
                                    buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                    nav.setRowCount(buf.rows.len);
                                },
                                .comment => openComposer(&composer, &composer_arena, .{ .kind = .top_level, .label = "New comment" }),
                                .toggle_select => nav.toggleMark(),
                                .clear_selection => nav.clearMark(),
                                .inline_comment, .suggest => {
                                    // Author an inline comment / suggestion on the
                                    // cursor's line, or over the visual selection's
                                    // range if one is active.
                                    const kind: bbr.review.DraftKind = if (act == .suggest) .suggestion else .inline_comment;
                                    const active_file = isolate_file orelse fileIndexForRow(buf, nav.cursor);
                                    if (openInline(&composer, &composer_arena, cur, buf, nav.cursor, active_file, kind, nav.selection())) |_| {
                                        nav.clearMark(); // selection consumed
                                    } else |err| {
                                        status_msg = @errorName(err); // refused: keep the selection to retry
                                    }
                                },
                                .isolate => {
                                    // Toggle the isolate view over the focused file.
                                    if (isolate_file) |only| {
                                        isolate_file = null;
                                        buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                        nav.setRowCount(buf.rows.len);
                                        // Land the cursor back on the file we were isolating.
                                        if (fileHeaderRow(buf, only)) |hr| nav.jumpTo(hr);
                                    } else {
                                        isolate_file = fileIndexForRow(buf, nav.cursor);
                                        buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                        nav = Nav.init(buf.rows.len, vx.window().height);
                                    }
                                },
                                .next_file => {
                                    // Next file: jump the cursor forward, or (isolated) show it.
                                    if (isolate_file) |only| {
                                        if (only + 1 < cur.diff.files.len) {
                                            isolate_file = only + 1;
                                            buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                            nav = Nav.init(buf.rows.len, vx.window().height);
                                        }
                                    } else if (nextFileHeaderRow(buf, nav.cursor)) |hr| nav.jumpTo(hr);
                                },
                                .prev_file => {
                                    // Previous file: symmetric with next.
                                    if (isolate_file) |only| {
                                        if (only > 0) {
                                            isolate_file = only - 1;
                                            buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                            nav = Nav.init(buf.rows.len, vx.window().height);
                                        }
                                    } else if (prevFileHeaderRow(buf, nav.cursor)) |hr| nav.jumpTo(hr);
                                },
                                .reply => {
                                    // Reply to the comment or draft under the cursor.
                                    openReply(&composer, &composer_arena, buf, nav.cursor) catch |err| {
                                        status_msg = @errorName(err);
                                    };
                                },
                                .expand_fold => {
                                    // Expand the fold under the cursor, if any.
                                    if (nav.cursor < buf.rows.len and buf.rows[nav.cursor] == .fold) {
                                        expanded.append(gpa, buf.rows[nav.cursor].fold.id) catch {};
                                        buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                                        nav.setRowCount(buf.rows.len);
                                    }
                                },
                                .submit => {
                                    // Submit the pending review to Bitbucket (M10).
                                    // Runs on a worker; results stream back as events.
                                    if (!ctx.online) {
                                        status_msg = "offline: cannot submit";
                                    } else if (submitting) {
                                        status_msg = "already submitting…";
                                    } else if (review.drafts.items.len == 0) {
                                        status_msg = "no pending drafts to submit";
                                    } else if (spawnSubmit(ctx, &loop, &submit_loads, &submit_epoch, gpa, &review, cur.pr.id, cur.pr.source_commit)) |_| {
                                        submitting = true;
                                        submit_total = review.drafts.items.len;
                                        submit_seen = 0;
                                        status_msg = null;
                                    } else |err| {
                                        status_msg = @errorName(err);
                                    }
                                },
                            },
                        },
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
                    reconciling = false; // a post-submit re-fetch (if any) has landed
                    switch (done.outcome) {
                        .ok => |s| {
                            // On the initial boot `current` is null; on a switch
                            // it's the outgoing Session we now replace.
                            if (current) |c| c.destroy();
                            current = s;
                            // Expanded-fold ids and the isolate index pointed into
                            // the old session's diff.
                            expanded.clearRetainingCapacity();
                            isolate_file = null;
                            // Blobs belong to the old session; its in-flight fetches
                            // (still tracked in enrichment_loads) will be discarded on
                            // arrival by the PR-id check.
                            enrichment_inflight.clearRetainingCapacity();
                            // A submission targeting the old PR is now stale; its
                            // events are discarded by the epoch/pr-id guards.
                            submitting = false;
                            // Load the new PR's pending Drafts into a fresh arena.
                            _ = review_arena.reset(.retain_capacity);
                            review = ctx.store.loadReview(review_arena.allocator(), reviewKey(ctx, s.pr.id)) catch PendingReview.init(s.pr.id);
                            buf = rebuildBuffered(&ring, s, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(s))) catch buf;
                            nav = Nav.init(buf.rows.len, vx.window().height);
                            resolver = .{}; // drop any half-typed leader
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
            .enrichment_done => |done| {
                reap(&enrichment_loads, io, done.epoch);
                removeInflight(&enrichment_inflight, done.pr_id, done.file_idx);
                // Apply only if the PR it targeted is still current; otherwise
                // this per-File enrichment was superseded — discard.
                const applies = if (current) |c|
                    c.pr.id == done.pr_id and done.file_idx < c.enrichment.len()
                else
                    false;
                switch (done.outcome) {
                    .ok => |result_value| {
                        var result = result_value;
                        defer result.deinit();
                        if (applies) {
                            const cur = current.?;
                            if (cur.enrichment.admit(done.file_idx, &result)) {
                                const projection = cur.enrichment.projection();
                                buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, projection.blobs)) catch buf;
                                nav.setRowCount(buf.rows.len);
                            } else |err| status_msg = @errorName(err);
                        }
                    },
                    .err => |e| if (applies) {
                        if (e == error.OutOfMemory) return error.FileEnrichmentOutOfMemory;
                        status_msg = @errorName(e);
                    },
                }
            },
            .submit_progress => |p| {
                // Persist each item's new state as the batch runs, so a crash
                // mid-submit resumes correctly (ADR-0007). Only for the live
                // batch and the PR it targeted; a `skipped` item was never tried,
                // so it stays a plain draft for a later selective retry.
                if (p.epoch == submit_epoch) {
                    submit_seen += 1; // advance the "n / total" modal
                    if (current) |c| if (c.pr.id == p.pr_id) {
                        const new_state: ?bbr.review.DraftState = switch (p.item.status) {
                            .posted => .{ .posted = p.item.id.? },
                            .failed => .{ .failed = p.item.reason orelse error.ServerError },
                            .skipped => null,
                            .outcome_unknown => .outcome_unknown,
                        };
                        if (new_state) |st| if (review.get(p.item.temp_id)) |d| {
                            d.state = st;
                            ctx.store.put(reviewKey(ctx, c.pr.id), d.*) catch |err| {
                                status_msg = @errorName(err);
                            };
                        };
                    };
                }
            },
            .submit_done => |done| {
                reap(&submit_loads, io, done.epoch);
                if (done.epoch == submit_epoch) {
                    submitting = false;
                    // The outcome is shown in a floating result dialog (below),
                    // not the status bar, so it stays put until dismissed.
                    submit_result = .{
                        .posted = done.posted,
                        .failed = done.failed,
                        .skipped = done.skipped,
                        .aborted = if (done.aborted) |e| @errorName(e) else null,
                        .stale = done.stale,
                    };
                    // Delete-on-batch-success (ADR-0007): a clean batch owns no
                    // lingering posted rows — the comments live on the server.
                    if (!done.stale and done.aborted == null and done.failed == 0 and done.skipped == 0) {
                        if (current) |cur| {
                            for (review.drafts.items) |d| ctx.store.remove(reviewKey(ctx, cur.pr.id), d.local_id) catch {};
                            review.drafts.clearRetainingCapacity();
                        }
                    }
                    // Reflect the new draft states (or their removal) in the pane.
                    if (current) |cur| {
                        buf = rebuildBuffered(&ring, cur, layout, buildOpts(show_resolved, scope, expanded.items, review.drafts.items, isolate_file, sessionBlobs(cur))) catch buf;
                        nav.setRowCount(buf.rows.len);
                    }
                    // Reconcile with the server (M10b): a batch that posted anything
                    // means those comments now live on Bitbucket, which is
                    // authoritative (ADR-0001). Re-fetch the PR so they reappear —
                    // the just-deleted drafts are replaced by the real Comments. This
                    // runs behind the result dialog (`reconciling`, not the loading
                    // frame), so it never flashes a fullscreen "Loading" over the
                    // summary the reviewer is reading.
                    if (done.posted > 0) {
                        if (current) |cur| {
                            spawnLoad(ctx, &loop, &loads, &epoch, gpa, cur.pr.id) catch |err| {
                                status_msg = @errorName(err);
                            };
                            if (loads.items.len > 0) {
                                reconciling = true;
                                loading_id = cur.pr.id;
                            }
                        }
                    }
                }
            },
        }

        // Lazily enrich the focused File off-thread. One job fetches every
        // required side, runs the Highlighter, then posts one Epoch-stamped
        // result; plain rendering remains visible until it arrives.
        if (current) |curp| {
            const focused = isolate_file orelse fileIndexForRow(buf, nav.cursor);
            ensureEnrichment(ctx, &loop, curp, focused, &enrichment_loads, &enrichment_inflight, &enrichment_epoch, gpa);
        }

        const win = vx.window();
        const frame = frame_arena.allocator();
        // A load in flight (initial boot or a switch) shows the "Loading PR #N…"
        // dialog. A post-submit reconcile (`reconciling`) is deliberately excluded:
        // it runs behind the submit result dialog, over the still-shown review.
        if ((loading and !reconciling) or current == null) {
            render.drawLoading(frame, win, loading_id, active_theme, status_msg);
        } else {
            const cur = current.?;
            // In the isolate view the sidebar tracks the focused file directly;
            // otherwise it follows the cursor across the all-files buffer.
            const selected_file = isolate_file orelse fileIndexForRow(buf, nav.cursor);
            render.draw(frame, win, cur.diff, buf, active_theme, nav, selected_file, cur.threads, review.drafts.items);
            const visible_status = status_msg orelse highlightingStatus(frame, cur, selected_file);
            drawStatus(frame, win, cur.pr, nav, buf, layout, scope, show_resolved, isolate_file != null, loading, submitting, review.drafts.items.len, visible_status);
        }
        if (picker) |*p| render.drawPicker(frame, win, p, active_theme);
        if (composer) |*comp| render.drawComposerProjection(frame, win, .{
            .label = comp.request.label,
            .body = comp.body(),
        }, active_theme);
        // The progress modal floats over the viewer while a batch runs; when it
        // finishes the result dialog takes its place (and stays up, over the
        // reconcile re-fetch, until the reviewer dismisses it).
        if (submitting) {
            render.drawSubmit(frame, win, active_theme, submit_seen, submit_total);
        } else if (submit_result) |res| {
            render.drawSubmitResult(frame, win, active_theme, res.posted, res.failed, res.skipped, res.aborted, res.stale);
        }
        // The help Overlay floats above everything else, over any Session state.
        if (show_help) render.drawHelp(frame, win, active_theme, km);
        try vx.render(writer);
        _ = frame_arena.reset(.retain_capacity);
    }
}

fn highlightingStatus(allocator: std.mem.Allocator, current: *const Session, file_idx: usize) ?[]const u8 {
    if (file_idx >= current.enrichment.len()) return null;
    const status = current.enrichment.status(file_idx);
    if (status.old == .loading or status.new == .loading) return "highlighting…";
    if (status.old == .skipped_too_large or status.new == .skipped_too_large)
        return "highlighting skipped: file side exceeds max_file_bytes";
    const errors = current.enrichment.sideErrors(file_idx);
    if (sideStatusMessage(allocator, "old", status.old, errors.old)) |message| return message;
    if (sideStatusMessage(allocator, "new", status.new, errors.new)) |message| return message;
    return null;
}

fn sideStatusMessage(allocator: std.mem.Allocator, side: []const u8, state: bbr.highlight.SideState, maybe_error: ?anyerror) ?[]const u8 {
    const stage: []const u8 = switch (state) {
        .fetch_failed => "file fetch",
        .highlight_failed => "Grammar",
        else => return null,
    };
    const cause = if (maybe_error) |err| @errorName(err) else "unknown error";
    return std.fmt.allocPrint(allocator, "{s}-side highlighting unavailable: {s} {s} · showing plain text", .{ side, stage, cause }) catch "highlighting unavailable · showing plain text";
}

/// Assemble the buffer build options from the current toggles, the revealed
/// folds, and the pending Drafts. Rows borrow the session's diff/threads and the
/// review arena's drafts (not the buffer arena), so resetting it is safe.
/// Diff scope cycled by `f` (M9). Changes folds long context; fetched shows
/// every fetched line without folding; whole splices the file blob for the true
/// full file (falling back to the fetched rendering until the blob arrives).
const Scope = enum {
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

fn buildOpts(
    show_resolved: bool,
    scope: Scope,
    expanded: []const *const bbr.diff.Line,
    drafts: []const Draft,
    only_file: ?usize,
    blobs: []const bbr.diff.FileBlob,
) bbr.diff.BuildOptions {
    return .{
        .show_resolved = show_resolved,
        .fold_context = scope == .changes,
        .whole_file = scope == .whole,
        .expanded = expanded,
        .drafts = drafts,
        .only_file = only_file,
        .blobs = blobs,
    };
}

fn rebuildBuffered(ring: *ArenaRing(2), s: *const Session, layout: bbr.diff.Layout, opts: bbr.diff.BuildOptions) !bbr.diff.Buffer {
    const alloc = ring.begin();
    errdefer ring.abort();
    var enriched = opts;
    enriched.highlights = s.enrichment.projection().highlights;
    const buffer = try bbr.diff.buffer.buildWithComments(alloc, s.diff, layout, s.threads, enriched);
    ring.commit();
    return buffer;
}

fn sessionBlobs(s: *const Session) []const bbr.diff.FileBlob {
    return s.enrichment.projection().blobs;
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
    file_idx: usize,
    kind: bbr.review.DraftKind,
    sel: ?[2]usize,
) !void {
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();

    // Gather the anchored line(s): a visual selection's range, else the cursor.
    var lines: std.ArrayList(*const bbr.diff.Line) = .empty;
    if (sel) |r| {
        try collectSelectedLines(buf, r[0], r[1], &lines, a);
    } else if (lineAtCursor(buf, cursor)) |ln| {
        try lines.append(a, ln);
    }
    const span = try spanFromLines(lines.items, kind == .suggestion);

    const path = if (file_idx < s.diff.files.len) s.diff.files[file_idx].new_path else "";
    const anchor: bbr.review.Anchor = .{
        .path = try a.dupe(u8, path),
        .from = span.from,
        .to = span.to,
        .start_from = span.start_from,
        .start_to = span.start_to,
        .commit = try a.dupe(u8, s.pr.source_commit),
    };
    const noun: []const u8 = if (kind == .suggestion) "Suggest on" else "Comment on";
    const bottom = span.to orelse span.from orelse 0;
    const top = span.start_to orelse span.start_from;
    const label = (if (top) |t|
        std.fmt.allocPrint(a, "{s} {s}:{d}-{d}", .{ noun, path, t, bottom })
    else
        std.fmt.allocPrint(a, "{s} {s}:{d}", .{ noun, path, bottom })) catch "Comment";
    composer.* = Composer.init(a, .{ .kind = kind, .anchor = anchor, .label = label });

    // Feature 1: seed a suggestion with the source lines it proposes to rewrite,
    // so the reviewer edits real code inside the fence. A plain comment stays
    // empty — you're remarking, not replacing.
    if (kind == .suggestion and lines.items.len > 0) {
        var seed_buf: std.ArrayList(u8) = .empty;
        for (lines.items, 0..) |ln, i| {
            if (i > 0) try seed_buf.append(a, '\n');
            try seed_buf.appendSlice(a, ln.text);
        }
        try composer.*.?.seed(seed_buf.items);
    }
}

/// Open the Composer as a reply to the comment or draft under the cursor. The
/// reply co-locates with its parent (copying the parent's anchor); its `parent`
/// drives submission ordering — a reply to a pending Draft posts after it (M10).
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
fn reviewKey(ctx: RunCtx, pull_request_id: u64) ReviewKey {
    return .{
        .workspace = ctx.cred.workspace,
        .repository = ctx.repo,
        .pull_request_id = pull_request_id,
    };
}

fn commitDraft(store: PendingReviewStore, review: *PendingReview, a: std.mem.Allocator, key: ReviewKey, comp: *const Composer) !void {
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
    if (review.get(id)) |d| try store.put(key, d.*);
}

/// The diff line under the cursor (a unified `.line` or either side of a
/// side-by-side `.line_pair`), or null when the row isn't a line.
fn lineAtCursor(buf: bbr.diff.Buffer, cursor: usize) ?*const bbr.diff.Line {
    if (cursor >= buf.rows.len) return null;
    return lineAtRow(buf, cursor);
}

fn lineAtRow(buf: bbr.diff.Buffer, row: usize) ?*const bbr.diff.Line {
    return switch (buf.rows[row]) {
        .line => |lr| lr.line,
        .line_pair => |p| if (p.right) |rr| rr.line else if (p.left) |ll| ll.line else null,
        else => null,
    };
}

/// The line coordinates an anchor should carry — the M10b range shape.
const AnchorSpan = struct {
    from: ?u32 = null,
    to: ?u32 = null,
    start_from: ?u32 = null,
    start_to: ?u32 = null,
};

const RangeError = error{
    /// The selection contained no diff line at all.
    NotOnALine,
    /// The selection mixes added and removed lines — no coherent single side.
    MixedSides,
    /// The selected lines aren't a contiguous run (a hunk gap or a file border).
    NonContiguous,
    /// A suggestion was asked for over removed lines — Bitbucket can't apply it.
    SuggestionOnRemoved,
};

/// Map a run of selected diff lines (top→bottom) to an anchor span, per the
/// verified Bitbucket rules: a new-side range (all lines present in the new
/// file) is `{start_to, to}`; an old-side range (a removed line present) is
/// `{start_from, from}` and can't carry a suggestion. A single line yields a
/// single-sided anchor with no `start_*`. Pure, so it's unit-tested directly.
fn spanFromLines(lines: []const *const bbr.diff.Line, is_suggestion: bool) RangeError!AnchorSpan {
    if (lines.len == 0) return error.NotOnALine;

    var all_new = true;
    var all_old = true;
    for (lines) |ln| {
        if (ln.new_no == null) all_new = false;
        if (ln.old_no == null) all_old = false;
    }
    if (!all_new and !all_old) return error.MixedSides;

    // Prefer the new side (where suggestions apply and most comments live).
    if (all_new) {
        var i: usize = 1;
        while (i < lines.len) : (i += 1) {
            if (lines[i].new_no.? != lines[i - 1].new_no.? + 1) return error.NonContiguous;
        }
        const bottom = lines[lines.len - 1].new_no.?;
        if (lines.len == 1) return .{ .to = bottom };
        return .{ .to = bottom, .start_to = lines[0].new_no.? };
    }

    // Old side: the run includes a removed line. Suggestions are refused —
    // Bitbucket returns "You can't apply suggestions on removed lines".
    if (is_suggestion) return error.SuggestionOnRemoved;
    var i: usize = 1;
    while (i < lines.len) : (i += 1) {
        if (lines[i].old_no.? != lines[i - 1].old_no.? + 1) return error.NonContiguous;
    }
    const bottom = lines[lines.len - 1].old_no.?;
    if (lines.len == 1) return .{ .from = bottom };
    return .{ .from = bottom, .start_from = lines[0].old_no.? };
}

/// Collect the diff lines the selection `[lo, hi]` covers, refusing a selection
/// that crosses a file boundary. Non-line rows (hunk headers, comments, folds)
/// are skipped; a hunk gap surfaces later as `NonContiguous` in `spanFromLines`.
fn collectSelectedLines(
    buf: bbr.diff.Buffer,
    lo: usize,
    hi: usize,
    out: *std.ArrayList(*const bbr.diff.Line),
    a: std.mem.Allocator,
) !void {
    var row = lo;
    while (row <= hi and row < buf.rows.len) : (row += 1) {
        if (buf.rows[row] == .file_header) return error.NonContiguous; // spans files
        if (lineAtRow(buf, row)) |ln| try out.append(a, ln);
    }
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

/// Launch a background submission of the current PR's pending review, bumping
/// `submit_epoch`. Snapshots the Drafts into a self-owned request so the worker
/// never touches main-thread memory, then hands it off; the worker owns and
/// destroys the snapshot. Results arrive as `submit_progress`/`submit_done`.
fn spawnSubmit(
    ctx: RunCtx,
    loop: *Loop,
    submit_loads: *std.ArrayList(Load),
    submit_epoch: *u64,
    gpa: std.mem.Allocator,
    review: *const PendingReview,
    pr_id: u64,
    loaded_commit: []const u8,
) !void {
    submit_epoch.* += 1;
    const s = try buildSubmit(ctx, review, pr_id, loaded_commit, submit_epoch.*);
    const fut = ctx.io.concurrent(submitWorker, .{ loop, ctx.io, ctx.env_map, ctx.cred, s }) catch |err| {
        s.destroy(); // worker never started; we still own the snapshot
        return err;
    };
    try submit_loads.append(gpa, .{ .epoch = submit_epoch.*, .future = fut });
}

/// Build a self-owned submission request: deep-copy the review's Drafts into a
/// page-allocator arena (so they cross the thread boundary), plus the repo, PR
/// id, and the source commit we loaded against. Freed via `Submit.destroy`.
fn buildSubmit(
    ctx: RunCtx,
    review: *const PendingReview,
    pr_id: u64,
    loaded_commit: []const u8,
    epoch: u64,
) !*Submit {
    const page = std.heap.page_allocator;
    const s = try page.create(Submit);
    errdefer page.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(page);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    s.review = PendingReview.init(pr_id);
    for (review.drafts.items) |d| {
        try s.review.addExisting(a, try bbr.review.store.dupeDraft(a, d));
    }
    s.repo = try a.dupe(u8, ctx.repo);
    s.pr_id = pr_id;
    s.loaded_commit = try a.dupe(u8, loaded_commit);
    s.epoch = epoch;
    return s;
}

/// Runs on a worker thread. Drives the pure `Submission` engine over the snapshot
/// review, POSTing each step through a Bitbucket `Poster` and sleeping on retry
/// backoff. Posts each item's decided state as `submit_progress`, then a final
/// `submit_done`. First re-checks the PR head and bails (stale) if it moved.
fn submitWorker(
    loop: *Loop,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    req: *Submit,
) void {
    defer req.destroy();
    const page = std.heap.page_allocator;

    // Backs the http client (its connection pool + proxy config) and every
    // per-request allocation for the whole batch. Never reset mid-batch — the
    // client holds live buffers here — so it grows with the batch; a review is a
    // handful of Drafts, so that's bounded and freed when the worker returns.
    var scratch = std.heap.ArenaAllocator.init(page);
    defer scratch.deinit();

    var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(scratch.allocator(), env_map) catch {};
    const client = bbr.bitbucket.Client.init(http.httpClient(), cred);

    // Stale-anchor guard (§9): if the source head moved since load, anchors may
    // no longer resolve — don't post anything. A failed head check itself is not
    // grounds to block; only a confirmed change is.
    if (client.getPullRequest(scratch.allocator(), req.repo, req.pr_id)) |pr| {
        if (bbr.review.headChanged(req.loaded_commit, pr.source_commit)) {
            loop.postEvent(.{ .submit_done = .{ .epoch = req.epoch, .pr_id = req.pr_id, .posted = 0, .failed = 0, .skipped = 0, .aborted = null, .stale = true } }) catch {};
            return;
        }
    } else |_| {}

    var sub = bbr.review.Submission.init(page, &req.review) catch {
        loop.postEvent(.{ .submit_done = .{ .epoch = req.epoch, .pr_id = req.pr_id, .posted = 0, .failed = 0, .skipped = 0, .aborted = error.OutOfMemory, .stale = false } }) catch {};
        return;
    };
    defer sub.deinit();

    var poster = bbr.bitbucket.Poster{ .client = client, .allocator = scratch.allocator(), .repo_slug = req.repo, .pr_id = req.pr_id };
    const cp = poster.poster();

    // Tracks which results we've already posted as progress. On the (rare) OOM
    // we fall back to an empty slice: `emitProgress` then no-ops, but the batch
    // still runs and the final `submit_done` still lands.
    var no_emit = [_]bool{};
    const emitted: []bool = page.alloc(bool, sub.results.len) catch no_emit[0..];
    defer if (emitted.len > 0) page.free(emitted);
    @memset(emitted, false);

    while (true) {
        const step = sub.advance();
        emitProgress(loop, req, &sub, emitted);
        switch (step) {
            .post => |ps| {
                const d = req.review.getConst(ps.temp_id).?;
                // On an ambiguous retry, dedupe first (GET-and-match) so a
                // lost-response POST isn't sent twice (§9 "Duplicates").
                var outcome: bbr.review.PostOutcome = undefined;
                if (ps.dedupe) {
                    if (cp.findExisting(d.*) catch null) |existing| {
                        outcome = .{ .posted = existing };
                    } else {
                        outcome = cp.post(d.*, ps.parent) catch .ambiguous;
                    }
                } else {
                    outcome = cp.post(d.*, ps.parent) catch .ambiguous;
                }
                sub.report(outcome, null);
                emitProgress(loop, req, &sub, emitted);
            },
            .wait => |w| io.sleep(std.Io.Duration.fromMilliseconds(@intCast(w.ms)), .awake) catch {},
            .done, .aborted => break,
        }
    }
    emitProgress(loop, req, &sub, emitted);

    var posted: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    for (sub.results) |maybe| {
        const r = maybe orelse continue;
        switch (r.status) {
            .posted => posted += 1,
            .failed => failed += 1,
            .skipped => skipped += 1,
            // Keep the legacy adapter's clean-completion predicate false. The
            // Presentation adapter will expose this as its own result category.
            .outcome_unknown => failed += 1,
        }
    }
    loop.postEvent(.{ .submit_done = .{
        .epoch = req.epoch,
        .pr_id = req.pr_id,
        .posted = posted,
        .failed = failed,
        .skipped = skipped,
        .aborted = sub.aborted_reason,
        .stale = false,
    } }) catch {};
}

/// Post a `submit_progress` for every item decided since the last call (both the
/// items `report` resolved and the ones `advance` skipped), marking them emitted.
fn emitProgress(loop: *Loop, req: *Submit, sub: *bbr.review.Submission, emitted: []bool) void {
    for (sub.results, 0..) |maybe, i| {
        if (i >= emitted.len or emitted[i]) continue;
        const r = maybe orelse continue;
        emitted[i] = true;
        loop.postEvent(.{ .submit_progress = .{ .epoch = req.epoch, .pr_id = req.pr_id, .item = r } }) catch {};
    }
}

/// Ensure the focused File is being enriched. No-op offline, out of range,
/// already terminal on both sides, or already in flight. Otherwise one worker
/// fetches every required side and highlights it before posting one result.
fn ensureEnrichment(
    ctx: RunCtx,
    loop: *Loop,
    current: *Session,
    focused: usize,
    enrichment_loads: *std.ArrayList(Load),
    enrichment_inflight: *std.ArrayList(InflightEnrichment),
    enrichment_epoch: *u64,
    gpa: std.mem.Allocator,
) void {
    if (!ctx.online) return;
    if (focused >= current.diff.files.len or focused >= current.enrichment.len()) return;
    const file = current.diff.files[focused];
    const status = current.enrichment.status(focused);
    const old_ready = sideFinished(status.old);
    const new_ready = sideFinished(status.new);
    if (old_ready and new_ready) return;
    for (enrichment_inflight.items) |b| {
        if (b.pr_id == current.pr.id and b.file_idx == focused) return; // in flight
    }
    spawnEnrichment(ctx, loop, enrichment_loads, enrichment_epoch, gpa, current.pr.id, focused, current.pr.source_commit, current.pr.destination_commit, file) catch return;
    current.enrichment.markLoading(focused);
    enrichment_inflight.append(gpa, .{ .pr_id = current.pr.id, .file_idx = focused }) catch {};
}

fn sideFinished(state: bbr.highlight.SideState) bool {
    return switch (state) {
        .pending, .loading => false,
        .absent, .ready, .skipped_too_large, .fetch_failed, .highlight_failed => true,
    };
}

/// Drop the in-flight record for (`pr_id`, `file_idx`) once its result arrives.
fn removeInflight(enrichment_inflight: *std.ArrayList(InflightEnrichment), pr_id: u64, file_idx: usize) void {
    for (enrichment_inflight.items, 0..) |b, i| {
        if (b.pr_id == pr_id and b.file_idx == file_idx) {
            _ = enrichment_inflight.swapRemove(i);
            return;
        }
    }
}

/// Launch one background File enrichment, bumping `enrichment_epoch`. The
/// worker posts `enrichment_done` stamped with epoch, PR id, and file index.
fn spawnEnrichment(
    ctx: RunCtx,
    loop: *Loop,
    enrichment_loads: *std.ArrayList(Load),
    enrichment_epoch: *u64,
    gpa: std.mem.Allocator,
    pr_id: u64,
    file_idx: usize,
    source_commit: []const u8,
    destination_commit: []const u8,
    file: bbr.diff.File,
) !void {
    enrichment_epoch.* += 1;
    var req: EnrichmentReq = .{
        .repo = undefined,
        .repo_len = @min(ctx.repo.len, 256),
        .source_commit = undefined,
        .source_commit_len = @min(source_commit.len, 64),
        .destination_commit = undefined,
        .destination_commit_len = @min(destination_commit.len, 64),
        .old_path = undefined,
        .old_path_len = @min(file.old_path.len, 512),
        .new_path = undefined,
        .new_path_len = @min(file.new_path.len, 512),
        .status = file.status,
        .pr_id = pr_id,
        .file_idx = file_idx,
        .epoch = enrichment_epoch.*,
    };
    @memcpy(req.repo[0..req.repo_len], ctx.repo[0..req.repo_len]);
    @memcpy(req.source_commit[0..req.source_commit_len], source_commit[0..req.source_commit_len]);
    @memcpy(req.destination_commit[0..req.destination_commit_len], destination_commit[0..req.destination_commit_len]);
    @memcpy(req.old_path[0..req.old_path_len], file.old_path[0..req.old_path_len]);
    @memcpy(req.new_path[0..req.new_path_len], file.new_path[0..req.new_path_len]);

    const fut = try ctx.io.concurrent(enrichmentWorker, .{ loop, ctx.io, ctx.env_map, ctx.cred, ctx.highlighter, ctx.highlight_max_file_bytes, req });
    try enrichment_loads.append(gpa, .{ .epoch = enrichment_epoch.*, .future = fut });
}

/// Runs on a worker thread. Fetches one file's blob off the page allocator and
/// posts it back; frees the result if the hand-off fails (shutting down).
fn enrichmentWorker(
    loop: *Loop,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cred: Credential,
    highlighter: bbr.highlight.Highlighter,
    max_file_bytes: usize,
    req: EnrichmentReq,
) void {
    const repo = req.repo[0..req.repo_len];
    const page = std.heap.page_allocator;
    var scratch = std.heap.ArenaAllocator.init(page);
    defer scratch.deinit();
    var http = bbr.http.StdHttpClient.init(scratch.allocator(), io);
    defer http.deinit();
    http.initDefaultProxies(scratch.allocator(), env_map) catch {};
    const bb = bbr.bitbucket.Client.init(http.httpClient(), cred);

    var outcome: EnrichmentOutcome = if (file_enrichment.enrich(page, bb, highlighter, .{
        .repo = repo,
        .status = req.status,
        .source_commit = req.source_commit[0..req.source_commit_len],
        .destination_commit = req.destination_commit[0..req.destination_commit_len],
        .old_path = req.old_path[0..req.old_path_len],
        .new_path = req.new_path[0..req.new_path_len],
        .max_file_bytes = max_file_bytes,
    })) |result| .{ .ok = result } else |err| .{ .err = err };

    loop.postEvent(.{ .enrichment_done = .{
        .epoch = req.epoch,
        .pr_id = req.pr_id,
        .file_idx = req.file_idx,
        .outcome = outcome,
    } }) catch {
        if (outcome == .ok) outcome.ok.deinit();
    };
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

/// Row of the first file header strictly after `cursor` (jump-to-next-file), or
/// null when the cursor is already in/after the last file.
fn nextFileHeaderRow(buf: bbr.diff.Buffer, cursor: usize) ?usize {
    var i: usize = cursor + 1;
    while (i < buf.rows.len) : (i += 1) {
        if (buf.rows[i] == .file_header) return i;
    }
    return null;
}

/// Row of the last file header strictly before `cursor` (jump-to-previous-file),
/// or null when the cursor is in/before the first file.
fn prevFileHeaderRow(buf: bbr.diff.Buffer, cursor: usize) ?usize {
    var i: usize = cursor;
    while (i > 0) {
        i -= 1;
        if (buf.rows[i] == .file_header) return i;
    }
    return null;
}

/// Row of the `file_idx`-th file header (0-based), or null if out of range —
/// used to land the cursor on a file when leaving the isolate view.
fn fileHeaderRow(buf: bbr.diff.Buffer, file_idx: usize) ?usize {
    var n: usize = 0;
    for (buf.rows, 0..) |row, i| {
        if (row == .file_header) {
            if (n == file_idx) return i;
            n += 1;
        }
    }
    return null;
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
    scope: Scope,
    show_resolved: bool,
    isolate: bool,
    loading: bool,
    submitting: bool,
    draft_count: usize,
    status_msg: ?[]const u8,
) void {
    if (win.height == 0) return;
    const row = win.height - 1;
    const layout_hint: []const u8 = if (layout == .unified) "s split" else "s unified";
    // Names the *current* scope; `f` cycles Changes → fetched → whole.
    const scope_hint: []const u8 = switch (scope) {
        .changes => "f: changes",
        .fetched => "f: fetched",
        .whole => "f: whole",
    };
    const file_hint: []const u8 = if (isolate) "o all files" else "o isolate";
    const resolved_hint: []const u8 = if (show_resolved) "R hide resolved" else "R show resolved";
    // A transient message (error/summary) or an in-progress indicator takes the
    // tail slot; otherwise the key hints, with the pending-draft count on `X`.
    const default_tail: []const u8 = if (draft_count > 0)
        (std.fmt.allocPrint(frame, "X submit {d}  ·  c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit", .{draft_count}) catch "q quit")
    else
        "c/i comment  ·  [ ] file  ·  p switch  ·  ? help  ·  q quit";
    const tail: []const u8 = if (status_msg) |m| m else if (submitting) "submitting…" else if (loading) "loading…" else default_tail;
    const text = std.fmt.allocPrint(frame, " #{d} {s}  ·  {s} → {s}  ·  {d}/{d}  ·  {s}  ·  {s}  ·  {s}  ·  {s}  ·  {s} ", .{
        pr.id,
        pr.title,
        pr.source_branch,
        pr.destination_branch,
        @min(nav.cursor + 1, buf.rows.len),
        buf.rows.len,
        layout_hint,
        scope_hint,
        file_hint,
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

test "file-header helpers drive jump-to-file and isolate landing" {
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
    // Rows: 0..3 = file one (header, hunk, -, +); 4..7 = file two.

    // Next-file from within file one lands on file two's header (row 4).
    try testing.expectEqual(@as(?usize, 4), nextFileHeaderRow(buf, 0));
    try testing.expectEqual(@as(?usize, 4), nextFileHeaderRow(buf, 3));
    // No file after the last one.
    try testing.expectEqual(@as(?usize, null), nextFileHeaderRow(buf, 5));

    // Previous-file from within file two lands on its own header, then file one.
    try testing.expectEqual(@as(?usize, 4), prevFileHeaderRow(buf, 5));
    try testing.expectEqual(@as(?usize, 0), prevFileHeaderRow(buf, 4));
    try testing.expectEqual(@as(?usize, null), prevFileHeaderRow(buf, 0));

    // fileHeaderRow maps a file index to its header row (isolate-exit landing).
    try testing.expectEqual(@as(?usize, 0), fileHeaderRow(buf, 0));
    try testing.expectEqual(@as(?usize, 4), fileHeaderRow(buf, 1));
    try testing.expectEqual(@as(?usize, null), fileHeaderRow(buf, 2));
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

test "spanFromLines: single line yields a single-sided anchor" {
    const added = bbr.diff.Line{ .old_no = null, .new_no = 42, .kind = .added, .text = "x" };
    const removed = bbr.diff.Line{ .old_no = 7, .new_no = null, .kind = .removed, .text = "x" };

    const new_span = try spanFromLines(&.{&added}, false);
    try testing.expectEqual(@as(?u32, 42), new_span.to);
    try testing.expect(new_span.start_to == null and new_span.from == null);

    const old_span = try spanFromLines(&.{&removed}, false);
    try testing.expectEqual(@as(?u32, 7), old_span.from);
    try testing.expect(old_span.start_from == null and old_span.to == null);
}

test "spanFromLines: contiguous new-side range spans start_to..to" {
    const l0 = bbr.diff.Line{ .old_no = null, .new_no = 67, .kind = .context, .text = "a" };
    const l1 = bbr.diff.Line{ .old_no = null, .new_no = 68, .kind = .added, .text = "b" };
    const l2 = bbr.diff.Line{ .old_no = null, .new_no = 69, .kind = .added, .text = "c" };
    const span = try spanFromLines(&.{ &l0, &l1, &l2 }, true); // suggestion OK on new side
    try testing.expectEqual(@as(?u32, 67), span.start_to);
    try testing.expectEqual(@as(?u32, 69), span.to);
    try testing.expect(span.start_from == null and span.from == null);
}

test "spanFromLines: old-side range refuses a suggestion but allows a comment" {
    const l0 = bbr.diff.Line{ .old_no = 3, .new_no = null, .kind = .removed, .text = "a" };
    const l1 = bbr.diff.Line{ .old_no = 4, .new_no = null, .kind = .removed, .text = "b" };
    try testing.expectError(error.SuggestionOnRemoved, spanFromLines(&.{ &l0, &l1 }, true));
    const span = try spanFromLines(&.{ &l0, &l1 }, false);
    try testing.expectEqual(@as(?u32, 3), span.start_from);
    try testing.expectEqual(@as(?u32, 4), span.from);
}

test "spanFromLines: mixed sides and gaps are refused" {
    const added = bbr.diff.Line{ .old_no = null, .new_no = 10, .kind = .added, .text = "x" };
    const removed = bbr.diff.Line{ .old_no = 20, .new_no = null, .kind = .removed, .text = "x" };
    try testing.expectError(error.MixedSides, spanFromLines(&.{ &added, &removed }, false));

    const a0 = bbr.diff.Line{ .old_no = null, .new_no = 10, .kind = .added, .text = "x" };
    const a2 = bbr.diff.Line{ .old_no = null, .new_no = 12, .kind = .added, .text = "x" }; // gap: 11 missing
    try testing.expectError(error.NonContiguous, spanFromLines(&.{ &a0, &a2 }, false));

    try testing.expectError(error.NotOnALine, spanFromLines(&.{}, false));
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

    const key: ReviewKey = .{ .workspace = "workspace", .repository = "repo", .pull_request_id = 42 };
    try commitDraft(store, &review, review_arena.allocator(), key, &comp);

    // Added to the in-memory review, with the suggestion body fenced.
    try testing.expectEqual(@as(usize, 1), review.drafts.items.len);
    const d = review.drafts.items[0];
    try testing.expect(d.kind == .suggestion);
    try testing.expectEqualStrings("```suggestion\ndo it this way\n```", d.body);

    // Persisted through the store: a fresh load round-trips it.
    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    const loaded = try store.load(load_arena.allocator(), key);
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expectEqualStrings("f.zig", loaded[0].anchor.?.path);
    try testing.expectEqualStrings("c0", loaded[0].anchor.?.commit.?);
}

// Force the presentation modules' tests into the exe test binary.
test {
    _ = @import("render.zig");
    _ = @import("theme.zig");
    _ = @import("nav.zig");
    _ = @import("keymap.zig");
    _ = @import("picker.zig");
    _ = @import("session.zig");
    _ = @import("arena_ring.zig");
    _ = @import("composer.zig");
    _ = @import("file_enrichment.zig");
}
