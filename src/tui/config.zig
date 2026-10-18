//! Configuration intake owns the complete startup path: XDG/HOME discovery,
//! missing-file defaults, bounded file I/O, parsing, semantic validation,
//! diagnostics, and materialization of the runtime Theme and Keymap. It also
//! owns the one write, `persistTheme`. Callers cross these two seams and never
//! learn TOML or selection rules.

const std = @import("std");
const keymap = @import("keymap.zig");
const ThemeId = @import("theme_id.zig").ThemeId;

const testing = std.testing;

const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []const u8,
    hint: ?[]const u8 = null,
};

pub const Configuration = struct {
    pub const default_highlight_max_file_bytes: usize = 2 * 1024 * 1024;
    pub const default_inactive_file_cache_max_bytes: usize = 256 * 1024 * 1024;
    pub const default_comments_collapsed_rows: usize = 6;
    pub const default_external_edit_max_bytes: usize = 1024 * 1024;

    theme: ThemeId,
    keymap: keymap.OwnedKeymap,
    highlight_max_file_bytes: usize,
    file_cache_enabled: bool,
    inactive_file_cache_max_bytes: usize,
    comments_collapsed_rows: usize,
    mouse_enabled: bool,
    mouse_vertical_scroll_rows: usize,
    external_edit_max_bytes: usize,

    pub fn deinit(self: *Configuration, allocator: std.mem.Allocator) void {
        self.keymap.deinit(allocator);
    }
};

const Result = union(enum) {
    ok: Configuration,
    invalid: []Diagnostic,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*configuration| configuration.deinit(allocator),
            .invalid => |diagnostics| allocator.free(diagnostics),
        }
        self.* = undefined;
    }
};

pub const Failure = struct {
    path: []u8,
    diagnostics: []Diagnostic = &.{},
    read_error: ?anyerror = null,

    fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.diagnostics.len > 0) allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn report(self: Failure) void {
        if (self.read_error) |err| {
            std.debug.print("bbr: could not read configuration {s}: {s}\n", .{ self.path, @errorName(err) });
            return;
        }
        for (self.diagnostics) |diagnostic| {
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ self.path, diagnostic.line, diagnostic.column, diagnostic.message });
            if (diagnostic.hint) |hint| std.debug.print("  help: {s}\n", .{hint});
        }
    }
};

pub const LoadResult = union(enum) {
    ok: Configuration,
    invalid: Failure,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*configuration| configuration.deinit(allocator),
            .invalid => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

fn defaults(allocator: std.mem.Allocator) !Configuration {
    return .{
        .theme = .system,
        .keymap = try keymap.Keymap.fromOverrides(allocator, &.{}),
        .highlight_max_file_bytes = Configuration.default_highlight_max_file_bytes,
        .file_cache_enabled = true,
        .inactive_file_cache_max_bytes = Configuration.default_inactive_file_cache_max_bytes,
        .comments_collapsed_rows = Configuration.default_comments_collapsed_rows,
        .mouse_enabled = true,
        .mouse_vertical_scroll_rows = 3,
        .external_edit_max_bytes = Configuration.default_external_edit_max_bytes,
    };
}

fn path(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_CONFIG_HOME")) |base| return try std.fmt.allocPrint(allocator, "{s}/bbr/config.toml", .{base});
    if (env.get("HOME")) |home| return try std.fmt.allocPrint(allocator, "{s}/.config/bbr/config.toml", .{home});
    return null;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !LoadResult {
    const config_path = (try path(allocator, env)) orelse return .{ .ok = try defaults(allocator) };
    errdefer allocator.free(config_path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024 + 1)) catch |err| switch (err) {
        error.FileNotFound => {
            const configuration = try defaults(allocator);
            allocator.free(config_path);
            return .{ .ok = configuration };
        },
        error.StreamTooLong => {
            const diagnostics = try tooLargeDiagnostics(allocator);
            return .{ .invalid = .{ .path = config_path, .diagnostics = diagnostics } };
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = .{ .path = config_path, .read_error = err } },
    };
    defer allocator.free(source);
    const parsed = try parse(allocator, source);
    return switch (parsed) {
        .ok => |configuration| blk: {
            allocator.free(config_path);
            break :blk .{ .ok = configuration };
        },
        .invalid => |diagnostics| .{ .invalid = .{ .path = config_path, .diagnostics = diagnostics } },
    };
}

pub const PersistThemeError = error{
    /// Neither XDG_CONFIG_HOME nor HOME is set.
    NoConfigLocation,
    /// The file is over 64 KiB, or the rewritten file does not parse.
    /// Nothing is written.
    ConfigInvalid,
    WriteFailed,
    OutOfMemory,
};

/// Write `id` as the root `theme` of config.toml and keep every other byte.
/// The rewritten file must parse before it replaces the old one. The write is
/// atomic, follows a symlinked config.toml to its target, and creates the
/// `bbr` directory when it is absent.
pub fn persistTheme(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, id: ThemeId) PersistThemeError!void {
    const config_path = (try path(allocator, env)) orelse return error.NoConfigLocation;
    defer allocator.free(config_path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024 + 1)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        error.StreamTooLong => return error.ConfigInvalid,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.WriteFailed,
    };
    defer allocator.free(source);
    const next = try rewriteTheme(allocator, source, id.name());
    defer allocator.free(next);
    var parsed = try parse(allocator, next);
    defer parsed.deinit(allocator);
    if (parsed == .invalid) return error.ConfigInvalid;
    writeAtomically(allocator, io, config_path, next) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.WriteFailed,
    };
}

fn writeAtomically(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dir_path = std.fs.path.dirname(file_path).?;
    // createDirPath fails with NotDir when the last component is a directory symlink.
    cwd.access(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => try cwd.createDirPath(io, dir_path),
        else => return err,
    };
    // Rename over the resolved target, not over the symlink entry.
    const target: ?[:0]u8 = target: {
        var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        _ = cwd.readLink(io, file_path, &link_buffer) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => break :target null,
            else => return err,
        };
        break :target try cwd.realPathFileAlloc(io, file_path, allocator);
    };
    defer if (target) |resolved| allocator.free(resolved);
    const write_path = target orelse file_path;
    var dir = try cwd.openDir(io, std.fs.path.dirname(write_path).?, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, std.fs.path.basename(write_path), .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.replace(io);
}

/// Replace the value of the root `theme` key, or add the key before the first
/// table when the root has none. Every other byte stays as it was. `name` is a
/// ThemeId name, so it never needs escaping.
fn rewriteTheme(allocator: std.mem.Allocator, source: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    var line_start: usize = 0;
    const insert_at = while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        var parser = LineParser{ .text = source[line_start..line_end] };
        parser.space();
        if (!parser.done() and parser.peek() == '[') break line_start;
        if (!parser.done() and parser.peek() != '#') theme_line: {
            const key = parser.key() catch break :theme_line;
            if (!std.mem.eql(u8, key, "theme")) break :theme_line;
            parser.space();
            if (!parser.take('=')) break :theme_line;
            parser.space();
            const value_start = line_start + parser.pos;
            const value = parser.quoted() catch break :theme_line;
            // `value` sits between the quotes that start at `value_start`.
            const start = value_start + 1;
            return std.mem.concat(allocator, u8, &.{ source[0..start], name, source[start + value.len ..] });
        }
        line_start = line_end + 1;
    } else source.len;
    const separator: []const u8 = if (insert_at == source.len and source.len > 0 and source[source.len - 1] != '\n') "\n" else "";
    return std.mem.concat(allocator, u8, &.{ source[0..insert_at], separator, "theme = \"", name, "\"\n", source[insert_at..] });
}

fn parse(allocator: std.mem.Allocator, source: []const u8) !Result {
    if (source.len > 64 * 1024) {
        return .{ .invalid = try tooLargeDiagnostics(allocator) };
    }

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);
    var overrides: std.ArrayList(keymap.Override) = .empty;
    defer {
        for (overrides.items) |override| allocator.free(override.sequences);
        overrides.deinit(allocator);
    }
    var override_lines: std.ArrayList(usize) = .empty;
    defer override_lines.deinit(allocator);
    var theme: ThemeId = .system;
    var theme_seen = false;
    var highlight_max_file_bytes = Configuration.default_highlight_max_file_bytes;
    var highlight_limit_seen = false;
    var file_cache_enabled = true;
    var file_cache_enabled_seen = false;
    var inactive_file_cache_max_bytes = Configuration.default_inactive_file_cache_max_bytes;
    var file_cache_limit_seen = false;
    var comments_collapsed_rows = Configuration.default_comments_collapsed_rows;
    var comments_collapsed_seen = false;
    var mouse_enabled = true;
    var mouse_enabled_seen = false;
    var mouse_vertical_scroll_rows: usize = 3;
    var mouse_scroll_seen = false;
    var mouse_scroll_line: usize = 1;
    var external_edit_max_bytes = Configuration.default_external_edit_max_bytes;
    var external_edit_seen = false;
    var external_edit_line: usize = 1;
    var section: enum { root, keymap, highlight, files_cache, comments, input_mouse, external_edit, user_grammar, unknown } = .root;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        var parser = LineParser{ .text = raw_line };
        parser.space();
        if (parser.done() or parser.peek() == '#') continue;
        if (parser.peek() == '[') {
            const parsed_section = parser.section() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "malformed table header", .hint = "use [keymap], [highlight], [files.cache], [comments], [input.mouse], or [external_edit]" });
                section = .unknown;
                continue;
            };
            parser.space();
            if (!parser.trailing()) try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "unexpected text after table header" });
            if (std.mem.eql(u8, parsed_section, "keymap")) section = .keymap else if (std.mem.eql(u8, parsed_section, "highlight")) section = .highlight else if (std.mem.eql(u8, parsed_section, "files.cache")) section = .files_cache else if (std.mem.eql(u8, parsed_section, "comments")) section = .comments else if (std.mem.eql(u8, parsed_section, "input.mouse")) section = .input_mouse else if (std.mem.eql(u8, parsed_section, "external_edit")) section = .external_edit else if (std.mem.startsWith(u8, parsed_section, "grammars.") and parsed_section.len > "grammars.".len) section = .user_grammar else {
                section = .unknown;
                try diagnostics.append(allocator, .{ .line = line_number, .column = 2, .message = "unknown table", .hint = "use [keymap], [highlight], [files.cache], [comments], [input.mouse], or [external_edit]" });
            }
            continue;
        }

        const key = parser.key() catch {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a key" });
            continue;
        };
        parser.space();
        if (!parser.take('=')) {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected '=' after key" });
            continue;
        }
        parser.space();
        if (section == .keymap) {
            const parsed = parser.stringArray() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected an array of quoted key chords", .hint = "use action_name = [\"key\", \"other-key\"] or [] to unbind" });
                continue;
            };
            parser.space();
            if (!parser.trailing()) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "unexpected text after value" });
                continue;
            }
            if (overrides.items.len == 256) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "more than 256 Keymap entries" });
                continue;
            }
            var duplicate = false;
            for (overrides.items) |existing| if (std.mem.eql(u8, existing.action, key)) {
                duplicate = true;
                break;
            };
            if (duplicate) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate Keymap Action", .hint = "keep exactly one chord list for each Action" });
                continue;
            }
            const sequences = try allocator.dupe([]const u8, parsed.slice());
            const override: keymap.Override = .{ .action = key, .sequences = sequences };
            keymap.validateOverride(override) catch |err| {
                allocator.free(sequences);
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = switch (err) {
                    error.UnknownAction => "unknown Action name",
                    error.UnknownKey => "unknown key name",
                    error.SequenceTooLong => "key sequence exceeds eight chords",
                    error.CountConflict => "key sequence cannot begin with a Count digit",
                    else => "invalid key sequence",
                }, .hint = if (err == error.UnknownAction) "use an Action name shown in the Keybindings Overlay" else null });
                continue;
            };
            try overrides.append(allocator, override);
            try override_lines.append(allocator, line_number);
            continue;
        }
        if (section == .user_grammar) {
            if (!std.mem.eql(u8, key, "filenames") and !std.mem.eql(u8, key, "compound_suffixes") and !std.mem.eql(u8, key, "extensions") and !std.mem.eql(u8, key, "shebangs")) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown UserGrammar key", .hint = "use filenames, compound_suffixes, extensions, or shebangs" });
                continue;
            }
            const parsed = parser.stringArray() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a non-empty array of quoted GrammarMatch values" });
                continue;
            };
            if (parsed.len == 0) try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "GrammarMatch list cannot be empty" });
            parser.space();
            if (!parser.trailing()) try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "unexpected text after value" });
            continue;
        }
        const value: []const u8 = switch (section) {
            .highlight, .comments, .external_edit => parser.unsigned() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a non-negative integer byte count" });
                continue;
            },
            .files_cache => if (std.mem.eql(u8, key, "enabled")) parser.boolean() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected true or false" });
                continue;
            } else parser.unsigned() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a non-negative integer byte count" });
                continue;
            },
            .input_mouse => if (std.mem.eql(u8, key, "enabled")) parser.boolean() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected true or false" });
                continue;
            } else parser.unsigned() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a positive row count" });
                continue;
            },
            else => parser.quoted() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a quoted string value" });
                continue;
            },
        };
        parser.space();
        if (!parser.trailing()) {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "unexpected text after value" });
            continue;
        }

        switch (section) {
            .root => if (std.mem.eql(u8, key, "theme")) {
                if (theme_seen) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'theme' key", .hint = "keep exactly one top-level theme entry" });
                } else if (ThemeId.fromName(value)) |id| {
                    theme = id;
                } else try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown Theme name", .hint = "use system, dark, light, Catppuccin, Gruvbox, or Solarized" });
                theme_seen = true;
            } else try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown top-level key", .hint = "did you mean 'theme'?" }),
            .keymap => unreachable,
            .highlight => if (!std.mem.eql(u8, key, "max_file_bytes")) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown Highlighting key", .hint = "use max_file_bytes" });
            } else if (highlight_limit_seen) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'max_file_bytes' key", .hint = "keep exactly one Highlighting limit" });
            } else {
                highlight_max_file_bytes = std.fmt.parseInt(usize, value, 10) catch {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "Highlighting byte limit is too large" });
                    highlight_limit_seen = true;
                    continue;
                };
                highlight_limit_seen = true;
            },
            .files_cache => if (std.mem.eql(u8, key, "enabled")) {
                if (file_cache_enabled_seen) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'enabled' key", .hint = "keep exactly one File cache switch" });
                } else file_cache_enabled = std.mem.eql(u8, value, "true");
                file_cache_enabled_seen = true;
            } else if (std.mem.eql(u8, key, "max_bytes")) {
                if (file_cache_limit_seen) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'max_bytes' key", .hint = "keep exactly one File cache budget" });
                } else {
                    inactive_file_cache_max_bytes = std.fmt.parseInt(usize, value, 10) catch {
                        try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "File cache byte budget is too large" });
                        file_cache_limit_seen = true;
                        continue;
                    };
                }
                file_cache_limit_seen = true;
            } else try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown File cache key", .hint = "use enabled or max_bytes" }),
            .comments => if (!std.mem.eql(u8, key, "collapsed_rows")) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown Comments key", .hint = "use collapsed_rows" });
            } else if (comments_collapsed_seen) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'collapsed_rows' key", .hint = "keep exactly one Comment row limit" });
            } else {
                comments_collapsed_rows = std.fmt.parseInt(usize, value, 10) catch {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "Comment row limit is too large" });
                    comments_collapsed_seen = true;
                    continue;
                };
                comments_collapsed_seen = true;
            },
            .input_mouse => if (std.mem.eql(u8, key, "enabled")) {
                if (mouse_enabled_seen) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'enabled' key", .hint = "keep exactly one mouse input switch" });
                } else mouse_enabled = std.mem.eql(u8, value, "true");
                mouse_enabled_seen = true;
            } else if (std.mem.eql(u8, key, "vertical_scroll_rows")) {
                if (mouse_scroll_seen) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'vertical_scroll_rows' key", .hint = "keep exactly one mouse scroll row count" });
                } else {
                    mouse_scroll_line = line_number;
                    mouse_vertical_scroll_rows = std.fmt.parseInt(usize, value, 10) catch {
                        try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "mouse scroll row count is too large" });
                        mouse_scroll_seen = true;
                        continue;
                    };
                }
                mouse_scroll_seen = true;
            } else try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown Mouse input key", .hint = "use enabled or vertical_scroll_rows" }),
            .external_edit => if (!std.mem.eql(u8, key, "max_bytes")) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown External Edit key", .hint = "use max_bytes" });
            } else if (external_edit_seen) {
                try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'max_bytes' key", .hint = "keep exactly one External Edit limit" });
            } else {
                external_edit_line = line_number;
                external_edit_max_bytes = std.fmt.parseInt(usize, value, 10) catch {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "External Edit byte limit is too large" });
                    external_edit_seen = true;
                    continue;
                };
                external_edit_seen = true;
            },
            .user_grammar => unreachable,
            .unknown => {},
        }
    }

    if (mouse_vertical_scroll_rows == 0)
        try diagnostics.append(allocator, .{ .line = mouse_scroll_line, .column = 1, .message = "mouse vertical scroll rows must be greater than zero", .hint = "use enabled = false to disable mouse input" });
    if (external_edit_max_bytes == 0)
        try diagnostics.append(allocator, .{ .line = external_edit_line, .column = 1, .message = "External Edit max_bytes must be greater than zero", .hint = "use a positive local returned-file limit" });

    var owned_keymap = keymap.Keymap.fromOverrides(allocator, overrides.items) catch |err| {
        try diagnostics.append(allocator, .{ .line = if (override_lines.getLastOrNull()) |line| line else 1, .column = 1, .message = switch (err) {
            error.PrefixConflict => "a key sequence is the prefix of another binding",
            error.AmbiguousContext => "a Keymap chord is ambiguous in one Interaction Context",
            else => "Keymap could not be materialized",
        }, .hint = "remove one binding, unbind the conflicting default, or choose distinct prefixes" });
        return .{ .invalid = try diagnostics.toOwnedSlice(allocator) };
    };
    errdefer owned_keymap.deinit(allocator);
    if (diagnostics.items.len > 0) {
        owned_keymap.deinit(allocator);
        return .{ .invalid = try diagnostics.toOwnedSlice(allocator) };
    }
    return .{ .ok = .{
        .theme = theme,
        .keymap = owned_keymap,
        .highlight_max_file_bytes = highlight_max_file_bytes,
        .file_cache_enabled = file_cache_enabled,
        .inactive_file_cache_max_bytes = inactive_file_cache_max_bytes,
        .comments_collapsed_rows = comments_collapsed_rows,
        .mouse_enabled = mouse_enabled,
        .mouse_vertical_scroll_rows = mouse_vertical_scroll_rows,
        .external_edit_max_bytes = external_edit_max_bytes,
    } };
}

fn tooLargeDiagnostics(allocator: std.mem.Allocator) ![]Diagnostic {
    const diagnostics = try allocator.alloc(Diagnostic, 1);
    diagnostics[0] = .{ .line = 1, .column = 1, .message = "configuration exceeds 64 KiB", .hint = "remove unused entries or comments" };
    return diagnostics;
}

test "strict configuration rejects duplicate keys and sequence prefixes together" {
    const source =
        \\theme = "dark"
        \\theme = "light"
        \\[keymap]
        \\down = ["x"]
        \\up = ["x"]
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .invalid);
    try testing.expectEqual(@as(usize, 2), result.invalid.len);
    try testing.expectEqual(@as(usize, 2), result.invalid[0].line);
    try testing.expectEqual(@as(usize, 5), result.invalid[1].line);
}

test "unbinding a default can free its Leader for a shorter Action" {
    const source =
        \\[keymap]
        \\link_existing_comment = []
        \\set_verdict_approved = []
        \\set_verdict_changes_requested = []
        \\set_verdict_none = []
        \\open_review_search = []
        \\to_top = ["g"]
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
}

test "Selected Version configuration can share horizontal keys with Sidebar Actions" {
    var result = try parse(testing.allocator,
        \\[keymap]
        \\select_old_version = ["h", "left"]
        \\select_new_version = ["l", "right"]
    );
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
}

test "M21 kernel strict configuration rejects removed wrapping Action" {
    var result = try parse(testing.allocator,
        \\[keymap]
        \\toggle_diff_wrap = ["w"]
    );
    defer result.deinit(testing.allocator);
    try testing.expect(result == .invalid);
    try testing.expectEqualStrings("unknown Action name", result.invalid[0].message);
}

const LineParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn done(self: LineParser) bool {
        return self.pos >= self.text.len;
    }
    fn peek(self: LineParser) u8 {
        return self.text[self.pos];
    }
    fn column(self: LineParser) usize {
        return self.pos + 1;
    }
    fn take(self: *LineParser, expected: u8) bool {
        if (self.done() or self.peek() != expected) return false;
        self.pos += 1;
        return true;
    }
    fn space(self: *LineParser) void {
        while (!self.done() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\r')) self.pos += 1;
    }
    fn trailing(self: LineParser) bool {
        return self.done() or self.peek() == '#';
    }
    fn section(self: *LineParser) ![]const u8 {
        if (!self.take('[')) return error.ExpectedSection;
        const start = self.pos;
        while (!self.done() and self.peek() != ']') self.pos += 1;
        if (self.done() or self.pos == start) return error.ExpectedClose;
        const value = self.text[start..self.pos];
        self.pos += 1;
        return value;
    }
    fn key(self: *LineParser) ![]const u8 {
        if (!self.done() and self.peek() == '"') return self.quoted();
        const start = self.pos;
        while (!self.done()) {
            const ch = self.peek();
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.ExpectedKey;
        return self.text[start..self.pos];
    }
    fn quoted(self: *LineParser) ![]const u8 {
        if (!self.take('"')) return error.ExpectedQuote;
        const start = self.pos;
        while (!self.done() and self.peek() != '"') {
            if (self.peek() == '\\') return error.UnsupportedEscape;
            self.pos += 1;
        }
        if (self.done()) return error.UnterminatedString;
        const value = self.text[start..self.pos];
        self.pos += 1;
        return value;
    }

    const StringArray = struct {
        items: [16][]const u8 = undefined,
        len: usize = 0,

        fn slice(self: *const StringArray) []const []const u8 {
            return self.items[0..self.len];
        }
    };

    fn stringArray(self: *LineParser) !StringArray {
        var result: StringArray = .{};
        if (!self.take('[')) return error.ExpectedArray;
        self.space();
        if (self.take(']')) return result;
        while (true) {
            if (result.len == result.items.len) return error.TooManyItems;
            result.items[result.len] = try self.quoted();
            result.len += 1;
            self.space();
            if (self.take(']')) return result;
            if (!self.take(',')) return error.ExpectedComma;
            self.space();
        }
    }

    fn unsigned(self: *LineParser) ![]const u8 {
        const start = self.pos;
        while (!self.done() and std.ascii.isDigit(self.peek())) self.pos += 1;
        if (self.pos == start) return error.ExpectedUnsigned;
        return self.text[start..self.pos];
    }

    fn boolean(self: *LineParser) ![]const u8 {
        if (std.mem.startsWith(u8, self.text[self.pos..], "true")) {
            const start = self.pos;
            self.pos += 4;
            return self.text[start..self.pos];
        }
        if (std.mem.startsWith(u8, self.text[self.pos..], "false")) {
            const start = self.pos;
            self.pos += 5;
            return self.text[start..self.pos];
        }
        return error.ExpectedBoolean;
    }
};

test "configuration resolves theme and keymap while collecting independent diagnostics" {
    const source =
        \\theme = "catppuccin-mocha"
        \\[keymap]
        \\page_down = ["ctrl-x"]
        \\quit = []
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
    try testing.expectEqual(ThemeId.catppuccin_mocha, result.ok.theme);

    const broken =
        \\theem = "dark"
        \\theme = "midnight"
        \\[keymap]
        \\fly = ["ctrl-d"]
    ;
    var invalid = try parse(testing.allocator, broken);
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid == .invalid);
    try testing.expectEqual(@as(usize, 3), invalid.invalid.len);
    try testing.expectEqual(@as(usize, 1), invalid.invalid[0].line);
}

test "Highlighting size limit defaults to 2 MiB and accepts zero as unlimited" {
    var default_result = try parse(testing.allocator, "");
    defer default_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), default_result.ok.highlight_max_file_bytes);

    var configured = try parse(testing.allocator,
        \\[highlight]
        \\max_file_bytes = 0
    );
    defer configured.deinit(testing.allocator);
    try testing.expect(configured == .ok);
    try testing.expectEqual(@as(usize, 0), configured.ok.highlight_max_file_bytes);

    var invalid = try parse(testing.allocator,
        \\[highlight]
        \\max_file_bytes = -1
    );
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid == .invalid);
}

test "File content cache defaults on at 256 MiB and zero means unlimited" {
    var default_result = try parse(testing.allocator, "");
    defer default_result.deinit(testing.allocator);
    try testing.expect(default_result.ok.file_cache_enabled);
    try testing.expectEqual(@as(usize, 256 * 1024 * 1024), default_result.ok.inactive_file_cache_max_bytes);

    var configured = try parse(testing.allocator,
        \\[files.cache]
        \\enabled = false
        \\max_bytes = 1073741824
    );
    defer configured.deinit(testing.allocator);
    try testing.expect(configured == .ok);
    try testing.expect(!configured.ok.file_cache_enabled);
    try testing.expectEqual(@as(usize, 1024 * 1024 * 1024), configured.ok.inactive_file_cache_max_bytes);

    var zero = try parse(testing.allocator,
        \\[files.cache]
        \\enabled = true
        \\max_bytes = 0
    );
    defer zero.deinit(testing.allocator);
    try testing.expect(zero == .ok);
    try testing.expectEqual(@as(usize, 0), zero.ok.inactive_file_cache_max_bytes);

    var renamed_key = try parse(testing.allocator,
        \\[files.cache]
        \\max_retained_bytes_per_review = 1
    );
    defer renamed_key.deinit(testing.allocator);
    try testing.expect(renamed_key == .invalid);
    try testing.expectEqual(@as(usize, 2), renamed_key.invalid[0].line);
}

test "Comment disclosure defaults to six rendered rows and zero disables collapse" {
    var default_result = try parse(testing.allocator, "");
    defer default_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), default_result.ok.comments_collapsed_rows);

    var configured = try parse(testing.allocator,
        \\[comments]
        \\collapsed_rows = 0
    );
    defer configured.deinit(testing.allocator);
    try testing.expect(configured == .ok);
    try testing.expectEqual(@as(usize, 0), configured.ok.comments_collapsed_rows);
}

test "Mouse input defaults on with three-row scrolling and accepts opt-out and row count" {
    var default_result = try parse(testing.allocator, "");
    defer default_result.deinit(testing.allocator);
    try testing.expect(default_result.ok.mouse_enabled);
    try testing.expectEqual(@as(usize, 3), default_result.ok.mouse_vertical_scroll_rows);

    var configured = try parse(testing.allocator,
        \\[input.mouse]
        \\enabled = false
        \\vertical_scroll_rows = 7
    );
    defer configured.deinit(testing.allocator);
    try testing.expect(configured == .ok);
    try testing.expect(!configured.ok.mouse_enabled);
    try testing.expectEqual(@as(usize, 7), configured.ok.mouse_vertical_scroll_rows);

    var zero = try parse(testing.allocator,
        \\[input.mouse]
        \\vertical_scroll_rows = 0
    );
    defer zero.deinit(testing.allocator);
    try testing.expect(zero == .invalid);

    var duplicate_after_zero = try parse(testing.allocator,
        \\[input.mouse]
        \\vertical_scroll_rows = 0
        \\vertical_scroll_rows = 4
    );
    defer duplicate_after_zero.deinit(testing.allocator);
    try testing.expect(duplicate_after_zero == .invalid);
    try testing.expectEqual(@as(usize, 3), duplicate_after_zero.invalid[0].line);
    try testing.expectEqual(@as(usize, 2), duplicate_after_zero.invalid[1].line);
}

test "External Edit defaults to 1 MiB and rejects zero or unknown keys" {
    var default_result = try parse(testing.allocator, "");
    defer default_result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1024 * 1024), default_result.ok.external_edit_max_bytes);

    var configured = try parse(testing.allocator,
        \\[external_edit]
        \\max_bytes = 2048
    );
    defer configured.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2048), configured.ok.external_edit_max_bytes);

    var zero = try parse(testing.allocator,
        \\[external_edit]
        \\max_bytes = 0
    );
    defer zero.deinit(testing.allocator);
    try testing.expect(zero == .invalid);
    try testing.expectEqualStrings("External Edit max_bytes must be greater than zero", zero.invalid[0].message);
}

test "configuration path prefers XDG and falls back to HOME" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/ada");
    const home_path = (try path(testing.allocator, &env)).?;
    defer testing.allocator.free(home_path);
    try testing.expectEqualStrings("/home/ada/.config/bbr/config.toml", home_path);

    try env.put("XDG_CONFIG_HOME", "/cfg");
    const xdg_path = (try path(testing.allocator, &env)).?;
    defer testing.allocator.free(xdg_path);
    try testing.expectEqualStrings("/cfg/bbr/config.toml", xdg_path);
}

test "configuration intake owns missing valid malformed and unreadable file states" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", base);

    var missing = try load(testing.allocator, io, &env);
    defer missing.deinit(testing.allocator);
    try testing.expect(missing == .ok);
    try testing.expectEqual(ThemeId.system, missing.ok.theme);

    var bbr_dir = try tmp.dir.createDirPathOpen(io, "bbr", .{});
    defer bbr_dir.close(io);
    var file = try bbr_dir.createFile(io, "config.toml", .{});
    try file.writeStreamingAll(io,
        \\theme = "gruvbox-light"
        \\[keymap]
        \\page_down = ["ctrl-x"]
    );
    file.close(io);
    var valid = try load(testing.allocator, io, &env);
    defer valid.deinit(testing.allocator);
    try testing.expect(valid == .ok);
    try testing.expectEqual(ThemeId.gruvbox_light, valid.ok.theme);
    var resolver = keymap.Resolver{};
    try testing.expectEqual(keymap.Action.page_down, resolver.feed(valid.ok.keymap.keymap(), .diff, .{ .codepoint = 'x', .mods = .{ .ctrl = true } }).action);

    file = try bbr_dir.createFile(io, "config.toml", .{ .truncate = true });
    try file.writeStreamingAll(io, "theem = \"dark\"\n");
    file.close(io);
    var malformed = try load(testing.allocator, io, &env);
    defer malformed.deinit(testing.allocator);
    try testing.expect(malformed == .invalid);
    try testing.expectEqual(@as(usize, 1), malformed.invalid.diagnostics.len);

    file = try bbr_dir.createFile(io, "config.toml", .{ .truncate = true });
    const oversized = try testing.allocator.alloc(u8, 64 * 1024 + 2);
    defer testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try file.writeStreamingAll(io, oversized);
    file.close(io);
    var too_large = try load(testing.allocator, io, &env);
    defer too_large.deinit(testing.allocator);
    try testing.expect(too_large == .invalid);
    try testing.expectEqualStrings("configuration exceeds 64 KiB", too_large.invalid.diagnostics[0].message);

    try bbr_dir.deleteFile(io, "config.toml");
    try bbr_dir.createDir(io, "config.toml", .default_dir);
    var unreadable = try load(testing.allocator, io, &env);
    defer unreadable.deinit(testing.allocator);
    try testing.expect(unreadable == .invalid);
    try testing.expect(unreadable.invalid.read_error != null);
}

fn expectRewrite(source: []const u8, expected: []const u8) !void {
    const rewritten = try rewriteTheme(testing.allocator, source, "solarized-dark");
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings(expected, rewritten);
    var result = try parse(testing.allocator, rewritten);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
    try testing.expectEqual(ThemeId.solarized_dark, result.ok.theme);
}

test "rewriteTheme replaces or adds only the root theme value" {
    try expectRewrite(
        "# colors\ntheme = \"dark\" # keep\n\n[keymap]\nquit = [\"q\"]\n",
        "# colors\ntheme = \"solarized-dark\" # keep\n\n[keymap]\nquit = [\"q\"]\n",
    );
    try expectRewrite("theme=\"light\"\r\n[highlight]\r\nmax_file_bytes = 10\r\n", "theme=\"solarized-dark\"\r\n[highlight]\r\nmax_file_bytes = 10\r\n");
    try expectRewrite(
        "# theme = \"dark\"\n[keymap]\nquit = [\"q\"]\n",
        "# theme = \"dark\"\ntheme = \"solarized-dark\"\n[keymap]\nquit = [\"q\"]\n",
    );
    try expectRewrite("# only a comment", "# only a comment\ntheme = \"solarized-dark\"\n");
    try expectRewrite("# only a comment\n", "# only a comment\ntheme = \"solarized-dark\"\n");
    try expectRewrite("", "theme = \"solarized-dark\"\n");
}

test "persistTheme writes config.toml atomically through a symlink and refuses an invalid file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.NoConfigLocation, persistTheme(testing.allocator, io, &env, .dark));
    try env.put("XDG_CONFIG_HOME", base);

    try persistTheme(testing.allocator, io, &env, .gruvbox_dark);
    const created = try tmp.dir.readFileAlloc(io, "bbr/config.toml", testing.allocator, .limited(1024));
    defer testing.allocator.free(created);
    try testing.expectEqualStrings("theme = \"gruvbox-dark\"\n", created);
    try persistTheme(testing.allocator, io, &env, .gruvbox_dark);
    const again = try tmp.dir.readFileAlloc(io, "bbr/config.toml", testing.allocator, .limited(1024));
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(created, again);

    const invalid = "theme = \"dark\"\n[keymap]\nfly = [\"x\"]\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "bbr/config.toml", .data = invalid });
    try testing.expectError(error.ConfigInvalid, persistTheme(testing.allocator, io, &env, .light));
    const untouched = try tmp.dir.readFileAlloc(io, "bbr/config.toml", testing.allocator, .limited(1024));
    defer testing.allocator.free(untouched);
    try testing.expectEqualStrings(invalid, untouched);

    try tmp.dir.writeFile(io, .{ .sub_path = "dotfiles.toml", .data = "theme = \"dark\"\n[keymap]\nquit = [\"q\"]\n" });
    try tmp.dir.deleteFile(io, "bbr/config.toml");
    try tmp.dir.symLink(io, "../dotfiles.toml", "bbr/config.toml", .{});
    try persistTheme(testing.allocator, io, &env, .light);
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "bbr/config.toml", &link_buffer);
    try testing.expectEqualStrings("../dotfiles.toml", link_buffer[0..link_len]);
    const target = try tmp.dir.readFileAlloc(io, "dotfiles.toml", testing.allocator, .limited(1024));
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("theme = \"light\"\n[keymap]\nquit = [\"q\"]\n", target);
}

test "persistTheme writes config.toml through a symlinked bbr directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", base);

    try tmp.dir.createDir(io, "dotfiles", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "dotfiles/config.toml", .data = "# mine\ntheme = \"dark\"\n[highlight]\nmax_file_bytes = 10\n" });
    try tmp.dir.symLink(io, "dotfiles", "bbr", .{ .is_directory = true });
    try persistTheme(testing.allocator, io, &env, .light);
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "bbr", &link_buffer);
    try testing.expectEqualStrings("dotfiles", link_buffer[0..link_len]);
    const target = try tmp.dir.readFileAlloc(io, "dotfiles/config.toml", testing.allocator, .limited(1024));
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("# mine\ntheme = \"light\"\n[highlight]\nmax_file_bytes = 10\n", target);
}
