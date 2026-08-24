//! UserGrammar lifecycle commands and XDG registry transactions.

const std = @import("std");
const user_grammar = @import("user_grammar.zig");
const c = @import("query_predicates.zig").c;

pub const bbr_identity = "bbr-m17-v1";

const Entry = struct {
    name: []const u8,
    enabled: bool,
    digest: [32]u8,
    receipt_identity: []const u8,
    receipt_tree_sitter: u32,
};

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    root_path: []const u8,
    dir: std.Io.Dir,
    entries: std.ArrayList(Entry) = .empty,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Store {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const data_home = if (env.get("XDG_DATA_HOME")) |path|
            path
        else if (env.get("HOME")) |home|
            try std.fmt.allocPrint(a, "{s}/.local/share", .{home})
        else
            return error.NoDataHome;
        const root_path = try std.fmt.allocPrint(a, "{s}/bbr/grammars", .{data_home});
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{});
        var result: Store = .{ .arena = arena, .io = io, .env = env, .root_path = root_path, .dir = dir };
        errdefer result.dir.close(io);
        try result.readRegistry();
        return result;
    }

    pub fn deinit(self: *Store) void {
        self.entries.deinit(self.arena.allocator());
        self.dir.close(self.io);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn registryEntries(self: *Store, allocator: std.mem.Allocator) ![]user_grammar.RegistryEntry {
        const result = try allocator.alloc(user_grammar.RegistryEntry, self.entries.items.len);
        errdefer allocator.free(result);
        for (self.entries.items, result) |entry, *output| {
            const path = try std.fs.path.join(allocator, &.{ self.root_path, entry.name });
            output.* = .{
                .name = entry.name,
                .path = path,
                .enabled = entry.enabled,
                .trusted_digest = entry.digest,
                .receipt = .{
                    .bundle_digest = entry.digest,
                    .bbr_identity = entry.receipt_identity,
                    .tree_sitter_identity = entry.receipt_tree_sitter,
                },
            };
        }
        return result;
    }

    pub fn freeRegistryEntries(allocator: std.mem.Allocator, entries: []user_grammar.RegistryEntry) void {
        for (entries) |entry| allocator.free(entry.path);
        allocator.free(entries);
    }

    pub fn validateOverrideNames(self: *const Store, overrides: []const user_grammar.MatchOverride) !void {
        for (overrides) |override| if (self.indexOf(override.name) == null) return error.UnknownUserGrammar;
    }

    fn readRegistry(self: *Store) !void {
        const source = self.dir.readFileAlloc(self.io, "registry", self.arena.allocator(), .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const name = fields.next() orelse return error.InvalidUserGrammarRegistry;
            const enabled = fields.next() orelse return error.InvalidUserGrammarRegistry;
            const digest_hex = fields.next() orelse return error.InvalidUserGrammarRegistry;
            const identity = fields.next() orelse return error.InvalidUserGrammarRegistry;
            const tree_sitter = fields.next() orelse return error.InvalidUserGrammarRegistry;
            if (!safeName(name) or fields.next() != null or (!std.mem.eql(u8, enabled, "0") and !std.mem.eql(u8, enabled, "1"))) return error.InvalidUserGrammarRegistry;
            try self.entries.append(self.arena.allocator(), .{
                .name = name,
                .enabled = enabled[0] == '1',
                .digest = try parseDigest(digest_hex),
                .receipt_identity = identity,
                .receipt_tree_sitter = std.fmt.parseInt(u32, tree_sitter, 10) catch return error.InvalidUserGrammarRegistry,
            });
        }
    }

    fn writeRegistry(self: *Store) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.arena.allocator());
        for (self.entries.items) |entry| try output.print(self.arena.allocator(), "{s}\t{d}\t{x}\t{s}\t{d}\n", .{
            entry.name,
            @intFromBool(entry.enabled),
            entry.digest,
            entry.receipt_identity,
            entry.receipt_tree_sitter,
        });
        var atomic = try self.dir.createFileAtomic(self.io, "registry", .{ .replace = true });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        try writer.interface.writeAll(output.items);
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    fn indexOf(self: *const Store, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return index;
        return null;
    }
};

pub fn loadOverrides(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]user_grammar.MatchOverride {
    const base = env.get("XDG_CONFIG_HOME") orelse if (env.get("HOME")) |home| try std.fmt.allocPrint(allocator, "{s}/.config", .{home}) else return &.{};
    defer if (env.get("XDG_CONFIG_HOME") == null) allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/bbr/config.toml", .{base});
    defer allocator.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(source);
    var overrides: std.ArrayList(user_grammar.MatchOverride) = .empty;
    var current: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            current = null;
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const header = line[0 .. close + 1];
            const trailing = std.mem.trim(u8, line[close + 1 ..], " \t");
            if (trailing.len != 0 and trailing[0] != '#') return error.InvalidUserGrammarConfiguration;
            if (std.mem.startsWith(u8, header, "[grammars.") and header[header.len - 1] == ']') {
                const name = header["[grammars.".len .. header.len - 1];
                for (overrides.items) |override| if (std.mem.eql(u8, override.name, name)) return error.DuplicateUserGrammarConfiguration;
                try overrides.append(allocator, .{ .name = try allocator.dupe(u8, name), .rules = .{} });
                current = overrides.items.len - 1;
            }
            continue;
        }
        const index = current orelse continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidUserGrammarConfiguration;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const values = try parseRuleArray(allocator, std.mem.trim(u8, line[equal + 1 ..], " \t"));
        const rules = &overrides.items[index].rules;
        if (std.mem.eql(u8, key, "filenames")) {
            if (rules.filenames.len != 0) return error.DuplicateUserGrammarConfiguration;
            rules.filenames = values;
        } else if (std.mem.eql(u8, key, "compound_suffixes")) {
            if (rules.compound_suffixes.len != 0) return error.DuplicateUserGrammarConfiguration;
            rules.compound_suffixes = values;
        } else if (std.mem.eql(u8, key, "extensions")) {
            if (rules.extensions.len != 0) return error.DuplicateUserGrammarConfiguration;
            rules.extensions = values;
        } else if (std.mem.eql(u8, key, "shebangs")) {
            if (rules.shebangs.len != 0) return error.DuplicateUserGrammarConfiguration;
            rules.shebangs = values;
        } else return error.InvalidUserGrammarConfiguration;
    }
    for (overrides.items) |override| _ = try user_grammar.effectiveRules(override.name, .{}, &.{override});
    return overrides.toOwnedSlice(allocator);
}

fn parseRuleArray(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const close = std.mem.lastIndexOfScalar(u8, raw, ']') orelse return error.InvalidUserGrammarConfiguration;
    if (raw.len < 5 or raw[0] != '[' or (std.mem.trim(u8, raw[close + 1 ..], " \t").len != 0 and std.mem.trim(u8, raw[close + 1 ..], " \t")[0] != '#')) return error.InvalidUserGrammarConfiguration;
    var result: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, raw[1..close], " \t"), ',');
    while (parts.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidUserGrammarConfiguration;
        try result.append(allocator, try allocator.dupe(u8, value[1 .. value.len - 1]));
    }
    return result.toOwnedSlice(allocator);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: []const []const u8,
    interactive_digest: ?[32]u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len == 0) return error.InvalidGrammarCommand;
    if (std.mem.eql(u8, args[0], "check") and args.len >= 2 and try isCandidatePath(io, args[1])) return checkCandidate(allocator, io, args, writer);
    var store = try Store.open(allocator, io, env);
    defer store.deinit();
    const command = args[0];
    if (std.mem.eql(u8, command, "list")) {
        if (args.len != 1) return error.InvalidGrammarCommand;
        return list(allocator, &store, writer);
    }
    if (std.mem.eql(u8, command, "check")) {
        if (args.len != 2 and args.len != 4) return error.InvalidGrammarCommand;
        const index = store.indexOf(args[1]) orelse return error.UserGrammarNotInstalled;
        const entry = store.entries.items[index];
        const target = try std.fs.path.join(allocator, &.{ store.root_path, entry.name });
        defer allocator.free(target);
        var inspection = try user_grammar.inspect(allocator, io, target);
        defer inspection.deinit();
        if (!std.crypto.timing_safe.eql([32]u8, entry.digest, inspection.report.digest)) return error.UntrustedDigest;
        try inspection.report.writeTrustPrompt(writer);
        if (args.len == 4) {
            if (!std.mem.eql(u8, args[2], "--trust-sha256")) return error.InvalidGrammarCommand;
            try inspection.validateTrusted(args[3]);
            try writer.writeAll("valid\n");
        }
        return;
    }
    if (std.mem.eql(u8, command, "install")) return installOrUpdate(allocator, &store, args, false, interactive_digest, writer);
    if (std.mem.eql(u8, command, "update")) return installOrUpdate(allocator, &store, args, true, interactive_digest, writer);
    if (std.mem.eql(u8, command, "enable") or std.mem.eql(u8, command, "disable")) {
        if (args.len != 2) return error.InvalidGrammarCommand;
        const index = store.indexOf(args[1]) orelse return error.UserGrammarNotInstalled;
        const enabled = std.mem.eql(u8, command, "enable");
        if (enabled) {
            store.entries.items[index].enabled = true;
            try validateRegistry(allocator, &store);
        } else store.entries.items[index].enabled = false;
        try store.writeRegistry();
        try writer.print("{s} {s}\n", .{ args[1], if (enabled) "enabled" else "disabled" });
        return;
    }
    if (std.mem.eql(u8, command, "remove")) {
        if (args.len != 2) return error.InvalidGrammarCommand;
        const index = store.indexOf(args[1]) orelse return error.UserGrammarNotInstalled;
        try refuseConfiguredReference(allocator, io, env, args[1]);
        const removed = store.entries.orderedRemove(index);
        var random: [8]u8 = undefined;
        try io.randomSecure(&random);
        const removed_name = try std.fmt.allocPrint(allocator, ".removed-{x}", .{random});
        defer allocator.free(removed_name);
        try store.dir.rename(removed.name, store.dir, removed_name, io);
        store.writeRegistry() catch |err| {
            try store.entries.insert(store.arena.allocator(), index, removed);
            store.dir.rename(removed_name, store.dir, removed.name, io) catch {};
            return err;
        };
        store.dir.deleteTree(io, removed_name) catch {};
        try writer.print("{s} removed\n", .{removed.name});
        return;
    }
    return error.InvalidGrammarCommand;
}

fn checkCandidate(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len != 2 and args.len != 4) return error.InvalidGrammarCommand;
    var inspection = try user_grammar.inspect(allocator, io, args[1]);
    defer inspection.deinit();
    try inspection.report.writeTrustPrompt(writer);
    if (args.len == 4) {
        if (!std.mem.eql(u8, args[2], "--trust-sha256")) return error.InvalidGrammarCommand;
        try inspection.validateTrusted(args[3]);
        try writer.writeAll("valid\n");
    }
}

fn isCandidatePath(io: std.Io, path: []const u8) !bool {
    if (std.mem.endsWith(u8, path, ".tar.gz") or std.fs.path.dirname(path) != null) return true;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    dir.close(io);
    return true;
}

pub fn writeCandidateReport(allocator: std.mem.Allocator, io: std.Io, path: []const u8, writer: *std.Io.Writer) ![32]u8 {
    var inspection = try user_grammar.inspect(allocator, io, path);
    defer inspection.deinit();
    try inspection.report.writeTrustPrompt(writer);
    return inspection.report.digest;
}

fn installOrUpdate(allocator: std.mem.Allocator, store: *Store, args: []const []const u8, update: bool, interactive_digest: ?[32]u8, writer: *std.Io.Writer) !void {
    const path_index: usize = if (update) 2 else 1;
    if (args.len != path_index + 1 and args.len != path_index + 3) return error.InvalidGrammarCommand;
    const requested_name = if (update) args[1] else null;
    if (requested_name) |name| if (store.indexOf(name) == null) return error.UserGrammarNotInstalled;
    var inspection = try user_grammar.inspect(allocator, store.io, args[path_index]);
    defer inspection.deinit();
    if (requested_name) |name| if (!std.mem.eql(u8, name, inspection.report.name)) return error.UserGrammarIdentityMismatch;
    const existing = store.indexOf(inspection.report.name);
    if (!update and existing != null) return error.UserGrammarAlreadyInstalled;
    try inspection.report.writeTrustPrompt(writer);
    var digest_buffer: [64]u8 = undefined;
    if (args.len == path_index + 3) {
        if (!std.mem.eql(u8, args[path_index + 1], "--trust-sha256")) return error.InvalidGrammarCommand;
        try inspection.validateTrusted(args[path_index + 2]);
    } else {
        const approved = interactive_digest orelse return error.TrustDeclined;
        if (!std.crypto.timing_safe.eql([32]u8, approved, inspection.report.digest)) return error.BundleChangedAfterTrustPrompt;
        try inspection.validateTrusted(inspection.report.digestHex(&digest_buffer));
    }

    var random: [8]u8 = undefined;
    try store.io.randomSecure(&random);
    const stage_name = try std.fmt.allocPrint(allocator, ".candidate-{x}", .{random});
    defer allocator.free(stage_name);
    try store.dir.createDir(store.io, stage_name, .default_dir);
    errdefer store.dir.deleteTree(store.io, stage_name) catch {};
    var stage_dir = try store.dir.openDir(store.io, stage_name, .{});
    defer stage_dir.close(store.io);
    try inspection.writeBundle(stage_dir);

    const entry: Entry = .{
        .name = try store.arena.allocator().dupe(u8, inspection.report.name),
        .enabled = true,
        .digest = inspection.report.digest,
        .receipt_identity = bbr_identity,
        .receipt_tree_sitter = c.TREE_SITTER_LANGUAGE_VERSION,
    };
    const old_entry = if (existing) |index| store.entries.items[index] else null;
    if (existing) |index| store.entries.items[index] = entry else try store.entries.append(store.arena.allocator(), entry);
    var published = false;
    errdefer if (!published) {
        if (existing) |index| {
            store.entries.items[index] = old_entry.?;
        } else {
            _ = store.entries.pop();
        }
    };

    try validateRegistryWithPath(allocator, store, entry.name, stage_name);
    const backup_name = try std.fmt.allocPrint(allocator, ".previous-{x}", .{random});
    defer allocator.free(backup_name);
    if (update) try store.dir.rename(entry.name, store.dir, backup_name, store.io);
    errdefer if (!published and update) store.dir.rename(backup_name, store.dir, entry.name, store.io) catch {};
    try store.dir.rename(stage_name, store.dir, entry.name, store.io);
    errdefer if (!published) store.dir.deleteTree(store.io, entry.name) catch {};
    try store.writeRegistry();
    published = true;
    if (update) store.dir.deleteTree(store.io, backup_name) catch {};
    try writer.print("{s} {s} and enabled\n", .{ entry.name, if (update) "updated" else "installed" });
}

fn validateRegistry(allocator: std.mem.Allocator, store: *Store) !void {
    return validateRegistryWithPath(allocator, store, "", "");
}

fn validateRegistryWithPath(allocator: std.mem.Allocator, store: *Store, staged_name: []const u8, staged_path: []const u8) !void {
    const entries = try store.registryEntries(allocator);
    defer Store.freeRegistryEntries(allocator, entries);
    if (staged_name.len != 0) for (entries) |*entry| if (std.mem.eql(u8, entry.name, staged_name)) {
        allocator.free(entry.path);
        entry.path = try std.fs.path.join(allocator, &.{ store.root_path, staged_path });
    };
    const overrides = try loadOverrides(store.arena.allocator(), store.io, store.env);
    try store.validateOverrideNames(overrides);
    var registry = try user_grammar.Registry.init(allocator, store.io, entries, overrides, bbr_identity);
    registry.deinit();
}

fn list(allocator: std.mem.Allocator, store: *Store, writer: *std.Io.Writer) !void {
    const entries = try store.registryEntries(allocator);
    defer Store.freeRegistryEntries(allocator, entries);
    const overrides = try loadOverrides(store.arena.allocator(), store.io, store.env);
    try store.validateOverrideNames(overrides);
    var registry = try user_grammar.Registry.init(allocator, store.io, entries, overrides, bbr_identity);
    defer registry.deinit();
    const statuses = try registry.statuses(allocator);
    defer allocator.free(statuses);
    for (statuses) |status| try writer.print("{s}\t{s}\t{s}\n", .{ status.name, if (status.enabled) "enabled" else "disabled", if (status.valid) "valid" else "invalid" });
}

fn refuseConfiguredReference(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) !void {
    const base = env.get("XDG_CONFIG_HOME") orelse if (env.get("HOME")) |home| try std.fmt.allocPrint(allocator, "{s}/.config", .{home}) else return;
    defer if (env.get("XDG_CONFIG_HOME") == null) allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/bbr/config.toml", .{base});
    defer allocator.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(source);
    const table = try std.fmt.allocPrint(allocator, "[grammars.{s}]", .{name});
    defer allocator.free(table);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const header = line[0 .. close + 1];
        const trailing = std.mem.trim(u8, line[close + 1 ..], " \t");
        if (std.mem.eql(u8, header, table) and (trailing.len == 0 or trailing[0] == '#')) return error.UserGrammarReferencedByConfiguration;
    }
}

fn parseDigest(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidUserGrammarRegistry;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidUserGrammarRegistry;
    return digest;
}

fn safeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

test "lifecycle preconditions preserve registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(base);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.UserGrammarNotInstalled, run(std.testing.allocator, std.testing.io, &env, &.{ "update", "missing", "bundle" }, null, &output.writer));
    try std.testing.expectError(error.UserGrammarNotInstalled, run(std.testing.allocator, std.testing.io, &env, &.{ "enable", "missing" }, null, &output.writer));
    var store = try Store.open(std.testing.allocator, std.testing.io, &env);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}
