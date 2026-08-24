//! Validation for trusted, local UserGrammar candidates.

const std = @import("std");
const builtin = @import("builtin");
const grammar_match = @import("grammar_match.zig");
const predicate_mod = @import("query_predicates.zig");
const c = predicate_mod.c;

const max_file_bytes = 64 * 1024 * 1024;
const manifest_name = "grammar.toml";

pub const GrammarMatches = struct {
    filenames: []const []const u8 = &.{},
    compound_suffixes: []const []const u8 = &.{},
    extensions: []const []const u8 = &.{},
    shebangs: []const []const u8 = &.{},
};

pub const ValidationReceipt = struct {
    bundle_digest: [32]u8,
    bbr_identity: []const u8,
    tree_sitter_identity: u32,

    pub fn matches(self: ValidationReceipt, digest: [32]u8, bbr_identity: []const u8) bool {
        return std.crypto.timing_safe.eql([32]u8, self.bundle_digest, digest) and
            std.mem.eql(u8, self.bbr_identity, bbr_identity) and
            self.tree_sitter_identity == c.TREE_SITTER_LANGUAGE_VERSION;
    }
};

pub const MatchOverride = struct {
    name: []const u8,
    rules: GrammarMatches,
};

pub fn effectiveRules(name: []const u8, defaults: GrammarMatches, overrides: []const MatchOverride) !GrammarMatches {
    for (overrides) |override| {
        if (!std.mem.eql(u8, override.name, name)) continue;
        try validateRules(override.rules);
        return override.rules;
    }
    return defaults;
}

pub fn matches(rules: GrammarMatches, path: []const u8, content: []const u8) bool {
    inline for (std.meta.tags(MatchKind)) |kind| if (matchesKind(rules, kind, path, content)) return true;
    return false;
}

const MatchKind = enum { filename, compound_suffix, extension, shebang };

fn matchesKind(rules: GrammarMatches, kind: MatchKind, path: []const u8, content: []const u8) bool {
    const basename = std.fs.path.basename(path);
    const candidates = switch (kind) {
        .filename => rules.filenames,
        .compound_suffix => rules.compound_suffixes,
        .extension => rules.extensions,
        .shebang => rules.shebangs,
    };
    for (candidates) |candidate| {
        const matched = switch (kind) {
            .filename => std.mem.eql(u8, basename, candidate),
            .compound_suffix => std.mem.endsWith(u8, basename, candidate),
            .extension => std.mem.eql(u8, std.fs.path.extension(basename), candidate),
            .shebang => std.mem.startsWith(u8, content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len], candidate),
        };
        if (matched) return true;
    }
    return false;
}

pub fn validateActiveConflicts(names: []const []const u8, rules: []const GrammarMatches) !void {
    std.debug.assert(names.len == rules.len);
    for (rules, 0..) |left, left_index| {
        for (rules[left_index + 1 ..], left_index + 1..) |right, right_index| {
            if (rulesOverlap(left, right)) {
                _ = names[right_index];
                return error.UserGrammarConflict;
            }
        }
    }
}

fn rulesOverlap(left: GrammarMatches, right: GrammarMatches) bool {
    if (ruleListsOverlap(left.filenames, right.filenames) or
        suffixListsOverlap(left.compound_suffixes, right.compound_suffixes) or
        ruleListsOverlap(left.extensions, right.extensions) or
        prefixListsOverlap(left.shebangs, right.shebangs)) return true;
    for (left.filenames) |filename| {
        for (right.compound_suffixes) |suffix| if (std.mem.endsWith(u8, filename, suffix)) return true;
        for (right.extensions) |extension| if (std.mem.eql(u8, std.fs.path.extension(filename), extension)) return true;
    }
    for (right.filenames) |filename| {
        for (left.compound_suffixes) |suffix| if (std.mem.endsWith(u8, filename, suffix)) return true;
        for (left.extensions) |extension| if (std.mem.eql(u8, std.fs.path.extension(filename), extension)) return true;
    }
    for (left.compound_suffixes) |suffix| for (right.extensions) |extension| {
        if (std.mem.eql(u8, std.fs.path.extension(suffix), extension)) return true;
    };
    for (right.compound_suffixes) |suffix| for (left.extensions) |extension| {
        if (std.mem.eql(u8, std.fs.path.extension(suffix), extension)) return true;
    };
    const left_has_path_rules = left.filenames.len + left.compound_suffixes.len + left.extensions.len != 0;
    const right_has_path_rules = right.filenames.len + right.compound_suffixes.len + right.extensions.len != 0;
    return left_has_path_rules and right.shebangs.len != 0 or right_has_path_rules and left.shebangs.len != 0;
}

fn ruleListsOverlap(left: []const []const u8, right: []const []const u8) bool {
    for (left) |left_rule| for (right) |right_rule| {
        if (std.mem.eql(u8, left_rule, right_rule)) return true;
    };
    return false;
}

fn suffixListsOverlap(left: []const []const u8, right: []const []const u8) bool {
    for (left) |left_rule| for (right) |right_rule| {
        if (std.mem.endsWith(u8, left_rule, right_rule) or std.mem.endsWith(u8, right_rule, left_rule)) return true;
    };
    return false;
}

fn prefixListsOverlap(left: []const []const u8, right: []const []const u8) bool {
    for (left) |left_rule| for (right) |right_rule| {
        if (std.mem.startsWith(u8, left_rule, right_rule) or std.mem.startsWith(u8, right_rule, left_rule)) return true;
    };
    return false;
}

pub const RegistryEntry = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool,
    trusted_digest: [32]u8,
    receipt: ?ValidationReceipt = null,
};

pub const InstallationStatus = struct {
    name: []const u8,
    enabled: bool,
    valid: bool,
};

pub const RuntimeGrammar = struct {
    name: []const u8,
    language: *const c.TSLanguage,
    query: []const u8,
    locals_query: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    installations: []Installation,

    const Installation = struct {
        name: []u8,
        enabled: bool,
        rules: GrammarMatches = .{},
        inspection: ?Inspection = null,
        loaded: ?Loaded = null,

        const Loaded = struct {
            library: std.DynLib,
            language: *const c.TSLanguage,
        };
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        entries: []const RegistryEntry,
        overrides: []const MatchOverride,
        bbr_identity: []const u8,
    ) !Registry {
        var installations: std.ArrayList(Installation) = .empty;
        errdefer {
            deinitInstallations(allocator, installations.items);
            installations.deinit(allocator);
        }

        for (entries) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            var inspection = inspect(allocator, io, entry.path) catch |err| {
                if (entry.enabled) return err;
                try installations.append(allocator, .{ .name = name, .enabled = false });
                continue;
            };
            errdefer inspection.deinit();
            if (!std.mem.eql(u8, entry.name, inspection.report.name) or
                !std.crypto.timing_safe.eql([32]u8, entry.trusted_digest, inspection.report.digest))
            {
                if (entry.enabled) {
                    if (!std.mem.eql(u8, entry.name, inspection.report.name)) return error.UserGrammarIdentityMismatch;
                    return error.UntrustedDigest;
                }
                try installations.append(allocator, .{ .name = name, .enabled = false });
                inspection.deinit();
                continue;
            }

            const rules = try effectiveRules(entry.name, inspection.report.rules, overrides);
            if (entry.enabled and !(if (entry.receipt) |receipt| receipt.matches(inspection.report.digest, bbr_identity) else false)) {
                var digest_buffer: [64]u8 = undefined;
                try inspection.validateTrusted(inspection.report.digestHex(&digest_buffer));
            }
            try installations.append(allocator, .{
                .name = name,
                .enabled = entry.enabled,
                .rules = rules,
                .inspection = inspection,
            });
        }

        for (installations.items, 0..) |*left, left_index| {
            if (!left.enabled) continue;
            for (installations.items[left_index + 1 ..]) |*right| {
                if (!right.enabled) continue;
                const names = [_][]const u8{ left.name, right.name };
                const rules = [_]GrammarMatches{ left.rules, right.rules };
                try validateActiveConflicts(&names, &rules);
            }
        }
        return .{ .allocator = allocator, .installations = try installations.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        deinitInstallations(self.allocator, self.installations);
        self.allocator.free(self.installations);
        self.* = undefined;
    }

    pub fn statuses(self: *const Registry, allocator: std.mem.Allocator) ![]InstallationStatus {
        const result = try allocator.alloc(InstallationStatus, self.installations.len);
        for (self.installations, result) |installation, *status| status.* = .{
            .name = installation.name,
            .enabled = installation.enabled,
            .valid = installation.inspection != null,
        };
        return result;
    }

    pub fn grammar(self: *Registry, path: []const u8, content: []const u8) !?RuntimeGrammar {
        const installation = self.select(path, content) orelse return null;
        return try load(installation, self.allocator);
    }

    pub fn matchName(self: *Registry, path: []const u8, content: []const u8) ?[]const u8 {
        return (self.select(path, content) orelse return null).name;
    }

    fn select(self: *Registry, path: []const u8, content: []const u8) ?*Installation {
        inline for (std.meta.tags(MatchKind)) |kind| {
            for (self.installations) |*installation| {
                if (!installation.enabled or !matchesKind(installation.rules, kind, path, content)) continue;
                return installation;
            }
        }
        return null;
    }

    fn load(installation: *Installation, allocator: std.mem.Allocator) !RuntimeGrammar {
        const inspection = &(installation.inspection orelse return error.InvalidUserGrammarInstallation);
        if (installation.loaded == null) {
            const temporary = try inspection.writeTemporaryLibrary();
            defer std.Io.Dir.cwd().deleteTree(inspection.io, temporary.root) catch {};
            var library = std.DynLib.open(temporary.path) catch return error.NativeLibraryLoadFailed;
            errdefer library.close();
            const symbol = try allocator.dupeZ(u8, inspection.manifest.symbol);
            defer allocator.free(symbol);
            const language_fn = library.lookup(*const fn () callconv(.c) ?*const c.TSLanguage, symbol) orelse return error.MissingLanguageSymbol;
            const language = language_fn() orelse return error.InvalidLanguageSymbol;
            if (c.ts_language_abi_version(language) != inspection.manifest.tree_sitter_abi.?) return error.TreeSitterAbiMismatch;
            installation.loaded = .{ .library = library, .language = language };
        }
        return .{
            .name = installation.name,
            .language = installation.loaded.?.language,
            .query = findFile(inspection.files, inspection.manifest.highlight_query).?.bytes,
            .locals_query = if (inspection.manifest.locals_query) |path| findFile(inspection.files, path).?.bytes else "",
        };
    }
};

fn deinitInstallations(allocator: std.mem.Allocator, installations: []Registry.Installation) void {
    for (installations) |*installation| {
        if (installation.loaded) |*loaded| loaded.library.close();
        if (installation.inspection) |*inspection| inspection.deinit();
        allocator.free(installation.name);
    }
}

pub const Report = struct {
    name: []const u8,
    version: []const u8,
    digest: [32]u8,
    rules: GrammarMatches,
    affected_built_in_grammars: []const []const u8,

    pub fn digestHex(self: Report, buffer: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{x}", .{self.digest}) catch unreachable;
    }

    pub fn writeTrustPrompt(self: Report, writer: *std.Io.Writer) !void {
        var digest_buffer: [64]u8 = undefined;
        try writer.print(
            "WARNING: this UserGrammar contains native code. It runs in bbr with your permissions.\nGrammar: {s} {s}\nSHA-256: {s}\n",
            .{ self.name, self.version, self.digestHex(&digest_buffer) },
        );
        try writeRules(writer, self.rules);
        if (self.affected_built_in_grammars.len != 0) {
            try writer.writeAll("Affected BuiltInGrammars:");
            for (self.affected_built_in_grammars) |name| try writer.print(" {s}", .{name});
            try writer.writeByte('\n');
        }
    }
};

pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    manifest: Manifest,
    files: []File,
    report: Report,
    io: std.Io,
    diagnostic: ?predicate_mod.Diagnostic = null,

    pub fn deinit(self: *Inspection) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Trust is exact and case-insensitive hexadecimal. Native code is loaded
    /// only after this check succeeds.
    pub fn validateTrusted(self: *Inspection, trusted_sha256: []const u8) !void {
        var expected: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&expected, "{x}", .{self.report.digest}) catch unreachable;
        if (!std.ascii.eqlIgnoreCase(&expected, trusted_sha256)) return error.UntrustedDigest;
        const temporary = try self.writeTemporaryLibrary();
        defer std.Io.Dir.cwd().deleteTree(self.io, temporary.root) catch {};
        const library_path = temporary.path;
        var library = std.DynLib.open(library_path) catch return error.NativeLibraryLoadFailed;
        defer library.close();
        const symbol = try self.arena.allocator().dupeZ(u8, self.manifest.symbol);
        const language_fn = library.lookup(*const fn () callconv(.c) ?*const c.TSLanguage, symbol) orelse return error.MissingLanguageSymbol;
        const language = language_fn() orelse return error.InvalidLanguageSymbol;
        self.diagnostic = null;
        try validateLanguage(self.arena.allocator(), language, self.manifest, self.files, &self.diagnostic);
    }

    pub fn writeBundle(self: *const Inspection, dir: std.Io.Dir) !void {
        for (self.files) |file| {
            if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(self.io, parent);
            try dir.writeFile(self.io, .{ .sub_path = file.path, .data = file.bytes });
        }
    }

    fn writeTemporaryLibrary(self: *Inspection) !struct { root: []const u8, path: []const u8 } {
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const root = try std.fmt.allocPrint(self.arena.allocator(), "/tmp/bbr-usergrammar-{x}", .{random});
        try std.Io.Dir.createDirAbsolute(self.io, root, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(self.io, root) catch {};
        var dir = try std.Io.Dir.openDirAbsolute(self.io, root, .{});
        defer dir.close(self.io);
        if (std.fs.path.dirname(self.manifest.library)) |parent| try dir.createDirPath(self.io, parent);
        try dir.writeFile(self.io, .{ .sub_path = self.manifest.library, .data = findFile(self.files, self.manifest.library).?.bytes });
        return .{ .root = root, .path = try std.fs.path.join(self.arena.allocator(), &.{ root, self.manifest.library }) };
    }
};

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Inspection {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const archive = std.mem.endsWith(u8, path, ".tar.gz");
    const files = if (archive)
        try readArchive(a, io, path)
    else
        try readFolder(a, io, path);
    const manifest_file = findFile(files, manifest_name) orelse return error.MissingManifest;
    const manifest = try parseManifest(a, manifest_file.bytes);
    try validateManifest(manifest);
    try validateFiles(manifest, files);
    const digest = canonicalDigest(files);
    const affected = try affectedBuiltIns(a, manifest.rules);
    return .{
        .arena = arena,
        .manifest = manifest,
        .files = files,
        .report = .{
            .name = manifest.name,
            .version = manifest.version,
            .digest = digest,
            .rules = manifest.rules,
            .affected_built_in_grammars = affected,
        },
        .io = io,
    };
}

const Payload = struct { path: ?[]const u8, sha256: ?[32]u8 };
const Manifest = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    tree_sitter_abi: ?u32 = null,
    symbol: []const u8 = "",
    library: []const u8 = "",
    highlight_query: []const u8 = "",
    locals_query: ?[]const u8 = null,
    payloads: []const Payload = &.{},
    rules: GrammarMatches = .{},
};

const File = struct { path: []const u8, bytes: []const u8 };

fn readFolder(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]File {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList(File) = .empty;
    var total_bytes: usize = 0;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => continue,
            .file => {},
            else => return error.NonRegularFile,
        }
        const file_path = try allocator.dupe(u8, entry.path);
        if (!safePath(file_path)) return error.UnsafePath;
        const bytes = try readRegularFile(allocator, io, dir, file_path);
        total_bytes = std.math.add(usize, total_bytes, bytes.len) catch return error.BundleTooLarge;
        if (total_bytes > max_file_bytes or files.items.len >= 1024) return error.BundleTooLarge;
        try files.append(allocator, .{ .path = file_path, .bytes = bytes });
    }
    return files.toOwnedSlice(allocator);
}

fn readRegularFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io, path, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |other| return other,
    };
}

fn readArchive(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]File {
    const compressed = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
    var input: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &window);
    const tar_bytes = decompressor.reader.allocRemaining(allocator, .limited(max_file_bytes + 1)) catch return error.InvalidArchive;
    if (tar_bytes.len > max_file_bytes) return error.ArchiveTooLarge;
    return parseTar(allocator, tar_bytes);
}

fn parseTar(allocator: std.mem.Allocator, bytes: []const u8) ![]File {
    var files: std.ArrayList(File) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    var ended = false;
    while (at + 512 <= bytes.len) {
        const header = bytes[at..][0..512];
        if (allZero(header)) {
            if (at + 1024 > bytes.len or !allZero(bytes[at..])) return error.InvalidArchive;
            ended = true;
            break;
        }
        if (!validTarChecksum(header)) return error.InvalidArchive;
        var name = tarPath(header, allocator) catch return error.InvalidArchive;
        const kind = header[156];
        if (kind == '5' and std.mem.endsWith(u8, name, "/")) name = name[0 .. name.len - 1];
        if (!safePath(name)) return error.UnsafePath;
        for (seen.items) |previous| if (std.mem.eql(u8, previous, name)) return error.DuplicateArchiveEntry;
        try seen.append(allocator, name);
        const size = parseTarOctal(header[124..136]) catch return error.InvalidArchive;
        const data_start = at + 512;
        const data_end = std.math.add(usize, data_start, size) catch return error.InvalidArchive;
        if (data_end > bytes.len) return error.InvalidArchive;
        if (kind == '5') {
            if (size != 0) return error.InvalidArchive;
        } else if (kind == 0 or kind == '0') {
            const content = try allocator.dupe(u8, bytes[data_start..data_end]);
            try files.append(allocator, .{ .path = name, .bytes = content });
        } else {
            return error.NonRegularFile;
        }
        at = std.mem.alignForward(usize, data_end, 512);
    }
    if (!ended) return error.InvalidArchive;
    return files.toOwnedSlice(allocator);
}

fn tarPath(header: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const name = std.mem.sliceTo(header[0..100], 0);
    const prefix = std.mem.sliceTo(header[345..500], 0);
    if (name.len == 0) return error.InvalidArchive;
    return if (prefix.len == 0) allocator.dupe(u8, name) else std.fs.path.join(allocator, &.{ prefix, name });
}

fn validTarChecksum(header: []const u8) bool {
    const expected = parseTarOctal(header[148..156]) catch return false;
    var sum: usize = 0;
    for (header, 0..) |byte, index| sum += if (index >= 148 and index < 156) ' ' else byte;
    return sum == expected;
}

fn parseTarOctal(raw: []const u8) !usize {
    const value = std.mem.trim(u8, raw, " \x00");
    if (value.len == 0) return 0;
    return std.fmt.parseInt(usize, value, 8);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn parseManifest(allocator: std.mem.Allocator, source: []const u8) !Manifest {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidManifest;
    var manifest: Manifest = .{};
    var payloads: std.ArrayList(Payload) = .empty;
    var filenames: std.ArrayList([]const u8) = .empty;
    var compound_suffixes: std.ArrayList([]const u8) = .empty;
    var extensions: std.ArrayList([]const u8) = .empty;
    var shebangs: std.ArrayList([]const u8) = .empty;
    var root_fields: std.StringHashMapUnmanaged(void) = .empty;
    var match_fields: std.StringHashMapUnmanaged(void) = .empty;
    var section: enum { root, payload, matches } = .root;
    var current_payload: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[payload]]")) {
            section = .payload;
            try payloads.append(allocator, .{ .path = null, .sha256 = null });
            current_payload = payloads.items.len - 1;
            continue;
        }
        if (std.mem.eql(u8, line, "[matches]")) {
            section = .matches;
            current_payload = null;
            continue;
        }
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        switch (section) {
            .root => {
                const field = try root_fields.getOrPut(allocator, key);
                if (field.found_existing) return error.DuplicateManifestField;
                try setRootField(&manifest, key, value);
            },
            .payload => {
                const payload = &payloads.items[current_payload orelse return error.InvalidManifest];
                if (std.mem.eql(u8, key, "path")) {
                    if (payload.path != null) return error.DuplicateManifestField;
                    payload.path = try parseString(value);
                } else if (std.mem.eql(u8, key, "sha256")) {
                    if (payload.sha256 != null) return error.DuplicateManifestField;
                    payload.sha256 = try parseDigest(try parseString(value));
                } else return error.UnknownManifestField;
            },
            .matches => {
                const field = try match_fields.getOrPut(allocator, key);
                if (field.found_existing) return error.DuplicateManifestField;
                if (std.mem.eql(u8, key, "filenames")) try parseStringArray(allocator, value, &filenames) else if (std.mem.eql(u8, key, "compound_suffixes")) try parseStringArray(allocator, value, &compound_suffixes) else if (std.mem.eql(u8, key, "extensions")) try parseStringArray(allocator, value, &extensions) else if (std.mem.eql(u8, key, "shebangs")) try parseStringArray(allocator, value, &shebangs) else return error.UnknownManifestField;
            },
        }
    }
    for (payloads.items) |payload| if (payload.path == null or payload.path.?.len == 0 or payload.sha256 == null) return error.InvalidManifest;
    manifest.payloads = try payloads.toOwnedSlice(allocator);
    manifest.rules = .{
        .filenames = try filenames.toOwnedSlice(allocator),
        .compound_suffixes = try compound_suffixes.toOwnedSlice(allocator),
        .extensions = try extensions.toOwnedSlice(allocator),
        .shebangs = try shebangs.toOwnedSlice(allocator),
    };
    return manifest;
}

fn setRootField(manifest: *Manifest, key: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, key, "tree_sitter_abi")) {
        if (manifest.tree_sitter_abi != null) return error.DuplicateManifestField;
        manifest.tree_sitter_abi = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidManifest;
        return;
    }
    const value = try parseString(raw);
    const field: *[]const u8 = if (std.mem.eql(u8, key, "name")) &manifest.name else if (std.mem.eql(u8, key, "version")) &manifest.version else if (std.mem.eql(u8, key, "os")) &manifest.os else if (std.mem.eql(u8, key, "arch")) &manifest.arch else if (std.mem.eql(u8, key, "symbol")) &manifest.symbol else if (std.mem.eql(u8, key, "library")) &manifest.library else if (std.mem.eql(u8, key, "highlight_query")) &manifest.highlight_query else if (std.mem.eql(u8, key, "locals_query")) {
        if (manifest.locals_query != null) return error.DuplicateManifestField;
        manifest.locals_query = value;
        return;
    } else return error.UnknownManifestField;
    if (field.len != 0) return error.DuplicateManifestField;
    field.* = value;
}

fn parseString(raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidManifest;
    const value = raw[1 .. raw.len - 1];
    if (std.mem.indexOfAny(u8, value, "\\\n\r") != null) return error.InvalidManifest;
    return value;
}

fn parseStringArray(allocator: std.mem.Allocator, raw: []const u8, output: *std.ArrayList([]const u8)) !void {
    if (output.items.len != 0 or raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') return error.InvalidManifest;
    const body = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t");
    if (body.len == 0) return;
    var values = std.mem.splitScalar(u8, body, ',');
    while (values.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (value.len == 0) return error.InvalidManifest;
        try output.append(allocator, try parseString(value));
    }
}

fn validateManifest(manifest: Manifest) !void {
    if (!validName(manifest.name) or manifest.version.len == 0 or !validSymbol(manifest.symbol)) return error.InvalidGrammarIdentity;
    _ = std.SemanticVersion.parse(manifest.version) catch return error.InvalidGrammarVersion;
    if (!std.mem.eql(u8, manifest.os, @tagName(builtin.os.tag)) or !std.mem.eql(u8, manifest.arch, @tagName(builtin.cpu.arch))) return error.TargetMismatch;
    if (manifest.tree_sitter_abi == null or manifest.library.len == 0 or manifest.highlight_query.len == 0) return error.InvalidManifest;
    if (manifest.tree_sitter_abi.? < c.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION or manifest.tree_sitter_abi.? > c.TREE_SITTER_LANGUAGE_VERSION) return error.TreeSitterAbiMismatch;
    if (!safePath(manifest.library) or !safePath(manifest.highlight_query) or if (manifest.locals_query) |path| !safePath(path) else false) return error.UnsafePath;
    if (manifest.payloads.len == 0) return error.InvalidManifest;
    try validateRules(manifest.rules);
}

fn validateFiles(manifest: Manifest, files: []const File) !void {
    if (files.len != manifest.payloads.len + 1) return error.UndeclaredFile;
    for (manifest.payloads, 0..) |payload, index| {
        const path = payload.path.?;
        if (!safePath(path) or std.mem.eql(u8, path, manifest_name)) return error.UnsafePath;
        for (manifest.payloads[0..index]) |previous| if (std.mem.eql(u8, previous.path.?, path)) return error.DuplicatePayload;
        const file = findFile(files, path) orelse return error.MissingPayload;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file.bytes, &actual, .{});
        if (!std.crypto.timing_safe.eql([32]u8, actual, payload.sha256.?)) return error.PayloadDigestMismatch;
    }
    if (!isPayload(manifest, manifest.library) or !isPayload(manifest, manifest.highlight_query) or if (manifest.locals_query) |path| !isPayload(manifest, path) else false) return error.UndeclaredPayloadRole;
    for (files) |file| if (!std.mem.eql(u8, file.path, manifest_name) and !isPayload(manifest, file.path)) return error.UndeclaredFile;
}

fn canonicalDigest(files: []const File) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var remaining = files.len;
    while (remaining != 0) {
        var selected: ?usize = null;
        for (files, 0..) |file, index| {
            var rank: usize = 0;
            for (files) |other| {
                if (std.mem.order(u8, other.path, file.path) == .lt) rank += 1;
            }
            if (rank == files.len - remaining) selected = index;
        }
        const file = files[selected.?];
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, file.path.len, .big);
        hasher.update(&length);
        hasher.update(file.path);
        std.mem.writeInt(u64, &length, file.bytes.len, .big);
        hasher.update(&length);
        hasher.update(file.bytes);
        remaining -= 1;
    }
    return hasher.finalResult();
}

fn validateLanguage(allocator: std.mem.Allocator, language: *const c.TSLanguage, manifest: Manifest, files: []const File, diagnostic: ?*?predicate_mod.Diagnostic) !void {
    if (c.ts_language_abi_version(language) != manifest.tree_sitter_abi.?) return error.TreeSitterAbiMismatch;
    const highlight = findFile(files, manifest.highlight_query).?.bytes;
    const requires_locals = try validateQuery(allocator, language, highlight, .highlight, diagnostic);
    if (manifest.locals_query) |path| {
        if (try validateQuery(allocator, language, findFile(files, path).?.bytes, .locals, diagnostic)) return error.InvalidLocalsQuery;
    } else if (requires_locals) return error.MissingLocalsQuery;
}

fn validateQuery(allocator: std.mem.Allocator, language: *const c.TSLanguage, source: []const u8, kind: predicate_mod.Diagnostic.QueryKind, diagnostic: ?*?predicate_mod.Diagnostic) !bool {
    var offset: u32 = 0;
    var query_error: c.TSQueryError = undefined;
    const query = c.ts_query_new(language, source.ptr, @intCast(source.len), &offset, &query_error) orelse {
        if (diagnostic) |output| output.* = queryDiagnostic(source, offset, kind);
        return if (kind == .highlight) error.InvalidHighlightQuery else error.InvalidLocalsQuery;
    };
    defer c.ts_query_delete(query);
    var predicate_diagnostic: predicate_mod.Diagnostic = undefined;
    const predicates = predicate_mod.Set.validate(allocator, query, source, &predicate_diagnostic) catch {
        predicate_diagnostic.query_kind = kind;
        if (diagnostic) |output| output.* = predicate_diagnostic;
        return error.InvalidPredicate;
    };
    defer predicates.deinit(allocator);
    if (kind == .locals and (!queryHasCapture(query, "local.definition") or !queryHasCapture(query, "local.reference"))) return error.InvalidLocalsQuery;
    return predicates.requiresLocals();
}

fn queryDiagnostic(source: []const u8, offset: u32, kind: predicate_mod.Diagnostic.QueryKind) predicate_mod.Diagnostic {
    var line: u32 = 1;
    var column: u32 = 1;
    for (source[0..@min(@as(usize, offset), source.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .kind = .invalid_query, .source_offset = offset, .line = line, .column = column, .query_kind = kind };
}

fn queryHasCapture(query: *const c.TSQuery, expected: []const u8) bool {
    for (0..c.ts_query_capture_count(query)) |id| {
        var len: u32 = 0;
        const name = c.ts_query_capture_name_for_id(query, @intCast(id), &len) orelse continue;
        if (std.mem.eql(u8, name[0..len], expected)) return true;
    }
    return false;
}

fn validateRules(rules: GrammarMatches) !void {
    try validateRuleList(rules.filenames, .filename);
    try validateRuleList(rules.compound_suffixes, .compound);
    try validateRuleList(rules.extensions, .extension);
    try validateRuleList(rules.shebangs, .shebang);
    if (rules.filenames.len + rules.compound_suffixes.len + rules.extensions.len + rules.shebangs.len == 0) return error.MissingGrammarMatch;
}

const RuleKind = enum { filename, compound, extension, shebang };
fn validateRuleList(rules: []const []const u8, kind: RuleKind) !void {
    for (rules, 0..) |rule, index| {
        if (rule.len == 0 or !std.unicode.utf8ValidateSlice(rule) or std.mem.indexOfScalar(u8, rule, '\x00') != null) return error.InvalidGrammarMatch;
        if (hasTerminalControl(rule)) return error.InvalidGrammarMatch;
        const valid = switch (kind) {
            .filename => std.fs.path.basename(rule).len == rule.len,
            .compound => rule[0] == '.' and std.mem.countScalar(u8, rule, '.') >= 2,
            .extension => rule[0] == '.' and std.mem.countScalar(u8, rule, '.') == 1,
            .shebang => std.mem.startsWith(u8, rule, "#!"),
        };
        if (!valid) return error.InvalidGrammarMatch;
        for (rules[0..index]) |previous| if (std.mem.eql(u8, previous, rule)) return error.DuplicateGrammarMatch;
    }
}

fn affectedBuiltIns(allocator: std.mem.Allocator, rules: GrammarMatches) ![]const []const u8 {
    var affected: std.ArrayList([]const u8) = .empty;
    for (rules.filenames) |filename| try appendAffected(allocator, &affected, filename, "");
    for (rules.compound_suffixes) |suffix| try appendAffected(allocator, &affected, try std.fmt.allocPrint(allocator, "candidate{s}", .{suffix}), "");
    for (rules.extensions) |extension| try appendAffected(allocator, &affected, try std.fmt.allocPrint(allocator, "candidate{s}", .{extension}), "");
    for (rules.shebangs) |shebang| try appendAffected(allocator, &affected, "candidate", shebang);
    return affected.toOwnedSlice(allocator);
}

fn appendAffected(allocator: std.mem.Allocator, affected: *std.ArrayList([]const u8), path: []const u8, content: []const u8) !void {
    const name = grammar_match.builtInGrammarName(path, content) orelse return;
    for (affected.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try affected.append(allocator, name);
}

fn writeRules(writer: *std.Io.Writer, rules: GrammarMatches) !void {
    inline for (.{ .{ "filename", rules.filenames }, .{ "compound suffix", rules.compound_suffixes }, .{ "extension", rules.extensions }, .{ "shebang", rules.shebangs } }) |category| {
        for (category[1]) |rule| try writer.print("Match: {s} {s}\n", .{ category[0], rule });
    }
}

fn findFile(files: []const File, path: []const u8) ?File {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}

fn isPayload(manifest: Manifest, path: []const u8) bool {
    for (manifest.payloads) |payload| if (std.mem.eql(u8, payload.path.?, path)) return true;
    return false;
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn validSymbol(symbol: []const u8) bool {
    if (symbol.len == 0 or !(std.ascii.isAlphabetic(symbol[0]) or symbol[0] == '_')) return false;
    for (symbol[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn hasTerminalControl(value: []const u8) bool {
    var view = std.unicode.Utf8View.init(value) catch return true;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or codepoint >= 0x7f and codepoint <= 0x9f or codepoint >= 0x202a and codepoint <= 0x202e or codepoint >= 0x2066 and codepoint <= 0x2069) return true;
    }
    return false;
}

fn parseDigest(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidDigest;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidDigest;
    return digest;
}

const testing = std.testing;
extern fn tree_sitter_javascript() callconv(.c) ?*const c.TSLanguage;

test "folder inspection validates exact payloads and reports native trust" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "bundle/queries");
    try tmp.dir.createDirPath(io, "bundle/lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/queries/highlights.scm", .data = "(identifier) @variable\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/lib/grammar.dylib", .data = "native bytes" });
    const query_digest = digestHex("(identifier) @variable\n");
    const library_digest = digestHex("native bytes");
    const manifest = try std.fmt.allocPrint(testing.allocator,
        \\name = "fixture"
        \\version = "1.2.3"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_fixture"
        \\library = "lib/grammar.dylib"
        \\highlight_query = "queries/highlights.scm"
        \\[[payload]]
        \\path = "lib/grammar.dylib"
        \\sha256 = "{s}"
        \\[[payload]]
        \\path = "queries/highlights.scm"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = [".js", ".fixture"]
        \\
    , .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), library_digest, query_digest });
    defer testing.allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/grammar.toml", .data = manifest });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/bundle", .{&tmp.sub_path});
    defer testing.allocator.free(path);

    var inspection = try inspect(testing.allocator, io, path);
    defer inspection.deinit();
    try testing.expectEqualStrings("fixture", inspection.report.name);
    try testing.expectEqualStrings("1.2.3", inspection.report.version);
    try testing.expectEqualStrings("JavaScript", inspection.report.affected_built_in_grammars[0]);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try inspection.report.writeTrustPrompt(&output.writer);
    try testing.expect(std.mem.indexOf(u8, output.written(), "native code") != null);
    try testing.expectError(error.UntrustedDigest, inspection.validateTrusted("00" ** 32));
    var trusted_digest: [64]u8 = undefined;
    try testing.expectError(error.NativeLibraryLoadFailed, inspection.validateTrusted(inspection.report.digestHex(&trusted_digest)));
}

test "folder inspection rejects extra files links and changed payload bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "bundle");
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/payload", .data = "changed" });
    const digest = digestHex("expected");
    const manifest = try minimalManifest(testing.allocator, "payload", "payload", digest, ".fixture");
    defer testing.allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/grammar.toml", .data = manifest });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/bundle", .{&tmp.sub_path});
    defer testing.allocator.free(path);
    try testing.expectError(error.PayloadDigestMismatch, inspect(testing.allocator, io, path));

    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/payload", .data = "expected" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle/extra", .data = "x" });
    try testing.expectError(error.UndeclaredFile, inspect(testing.allocator, io, path));

    try tmp.dir.symLink(io, "bundle", "linked-bundle", .{ .is_directory = true });
    const linked_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/linked-bundle", .{&tmp.sub_path});
    defer testing.allocator.free(linked_path);
    try testing.expectError(error.NotDir, inspect(testing.allocator, io, linked_path));
}

test "tar parser rejects duplicate unsafe and linked entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const regular = try testTar(allocator, &.{ .{ "grammar.toml", '0', "x" }, .{ "payload", '0', "y" } });
    const files = try parseTar(allocator, regular);
    try testing.expectEqual(@as(usize, 2), files.len);

    const duplicate = try testTar(allocator, &.{ .{ "x", '0', "a" }, .{ "x", '0', "b" } });
    try testing.expectError(error.DuplicateArchiveEntry, parseTar(allocator, duplicate));
    const unsafe = try testTar(allocator, &.{.{ "../x", '0', "a" }});
    try testing.expectError(error.UnsafePath, parseTar(allocator, unsafe));
    const link = try testTar(allocator, &.{.{ "x", '2', "" }});
    try testing.expectError(error.NonRegularFile, parseTar(allocator, link));
    const duplicate_dir = try testTar(allocator, &.{ .{ "queries/", '5', "" }, .{ "queries/", '5', "" } });
    try testing.expectError(error.DuplicateArchiveEntry, parseTar(allocator, duplicate_dir));
}

test "tar.gz inspection uses the same logical bundle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = "native bytes";
    const manifest = try minimalManifest(allocator, "payload", "payload", digestHex(payload), ".fixture");
    const tar = try testTar(allocator, &.{ .{ "grammar.toml", '0', manifest }, .{ "payload", '0', payload } });
    var compressed: std.Io.Writer.Allocating = .init(allocator);
    try compressed.ensureUnusedCapacity(10);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, &window, .gzip, .fastest);
    try compressor.writer.writeAll(tar);
    try compressor.finish();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bundle.tar.gz", .data = compressed.written() });
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/bundle.tar.gz", .{&tmp.sub_path});

    var inspection = try inspect(testing.allocator, testing.io, path);
    defer inspection.deinit();
    try testing.expectEqualStrings("fixture", inspection.report.name);
}

test "trusted native validation checks ABI queries predicates and regexes" {
    const language = tree_sitter_javascript().?;
    const valid_files = [_]File{
        .{ .path = "highlights.scm", .bytes = "((identifier) @constructor (#match? @constructor \"^[A-Z]\"))" },
        .{ .path = "locals.scm", .bytes = "(identifier) @local.definition\n(identifier) @local.reference" },
    };
    var manifest: Manifest = .{
        .tree_sitter_abi = c.ts_language_abi_version(language),
        .highlight_query = "highlights.scm",
        .locals_query = "locals.scm",
    };
    try validateLanguage(testing.allocator, language, manifest, &valid_files, null);

    manifest.tree_sitter_abi.? -= 1;
    try testing.expectError(error.TreeSitterAbiMismatch, validateLanguage(testing.allocator, language, manifest, &valid_files, null));
    manifest.tree_sitter_abi = c.ts_language_abi_version(language);
    const invalid_query = [_]File{
        .{ .path = "highlights.scm", .bytes = "((identifier) @x (#match? @x \"(?=x)\"))" },
        .{ .path = "locals.scm", .bytes = "(identifier) @local.definition\n(identifier) @local.reference" },
    };
    try testing.expectError(error.InvalidPredicate, validateLanguage(testing.allocator, language, manifest, &invalid_query, null));

    manifest.locals_query = null;
    const local_predicate = [_]File{.{ .path = "highlights.scm", .bytes = "((identifier) @variable.builtin (#is-not? local))" }};
    try testing.expectError(error.MissingLocalsQuery, validateLanguage(testing.allocator, language, manifest, &local_predicate, null));
}

test "canonical digest changes with any declared byte" {
    const first = [_]File{
        .{ .path = "grammar.toml", .bytes = "a" },
        .{ .path = "payload", .bytes = "b" },
    };
    const reordered = [_]File{
        .{ .path = "payload", .bytes = "b" },
        .{ .path = "grammar.toml", .bytes = "a" },
    };
    const changed = [_]File{
        .{ .path = "grammar.toml", .bytes = "a" },
        .{ .path = "payload", .bytes = "c" },
    };
    try testing.expectEqual(canonicalDigest(&first), canonicalDigest(&reordered));
    try testing.expect(!std.mem.eql(u8, &canonicalDigest(&first), &canonicalDigest(&changed)));
}

test "manifest rejects duplicate fields and terminal control GrammarMatches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const duplicate =
        \\name = ""
        \\name = "fixture"
    ;
    try testing.expectError(error.DuplicateManifestField, parseManifest(arena.allocator(), duplicate));

    const unsafe_rules: GrammarMatches = .{ .filenames = &.{"safe\x1b[2J"} };
    try testing.expectError(error.InvalidGrammarMatch, validateRules(unsafe_rules));
}

test "GrammarMatch uses category precedence and explicit configuration replaces defaults" {
    const defaults: GrammarMatches = .{
        .filenames = &.{"Dockerfile"},
        .compound_suffixes = &.{".test.js"},
        .extensions = &.{".js"},
        .shebangs = &.{"#!/usr/bin/env fixture"},
    };
    try testing.expect(matches(defaults, "src/Dockerfile", ""));
    try testing.expect(matches(defaults, "src/a.test.js", ""));
    try testing.expect(matches(defaults, "src/a.js", ""));
    try testing.expect(matches(defaults, "script", "#!/usr/bin/env fixture -x\n"));

    const configured = try effectiveRules("fixture", defaults, &.{.{
        .name = "fixture",
        .rules = .{ .extensions = &.{".zig"} },
    }});
    try testing.expect(matches(configured, "src/a.zig", ""));
    try testing.expect(!matches(configured, "src/a.js", ""));
    try testing.expect(!matches(configured, "src/Dockerfile", ""));
}

test "active UserGrammar conflicts are errors" {
    const names = [_][]const u8{ "first", "second" };
    const conflicting = [_]GrammarMatches{
        .{ .extensions = &.{".fixture"} },
        .{ .extensions = &.{".fixture"} },
    };
    try testing.expectError(error.UserGrammarConflict, validateActiveConflicts(&names, &conflicting));

    const distinct = [_]GrammarMatches{
        .{ .extensions = &.{".first"} },
        .{ .extensions = &.{".second"} },
    };
    try validateActiveConflicts(&names, &distinct);

    const cross_category = [_]GrammarMatches{
        .{ .compound_suffixes = &.{".test.js"} },
        .{ .extensions = &.{".js"} },
    };
    try testing.expectError(error.UserGrammarConflict, validateActiveConflicts(&names, &cross_category));
}

test "validation receipt requires bundle bbr and tree-sitter identities" {
    const digest = canonicalDigest(&.{.{ .path = "grammar.toml", .bytes = "fixture" }});
    const receipt: ValidationReceipt = .{
        .bundle_digest = digest,
        .bbr_identity = "test-build",
        .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION,
    };
    try testing.expect(receipt.matches(digest, "test-build"));
    var changed = digest;
    changed[0] ^= 1;
    try testing.expect(!receipt.matches(changed, "test-build"));
    try testing.expect(!receipt.matches(digest, "other-build"));
    var runtime_changed = receipt;
    runtime_changed.tree_sitter_identity -= 1;
    try testing.expect(!runtime_changed.matches(digest, "test-build"));
}

test "registry reuses exact receipts and loads a matching UserGrammar on first use" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const first_path = try writeRegistryBundle(&tmp, "first", ".first", "not a library");
    defer testing.allocator.free(first_path);
    const second_path = try writeRegistryBundle(&tmp, "second", ".other", "also not a library");
    defer testing.allocator.free(second_path);
    var first_inspection = try inspect(testing.allocator, testing.io, first_path);
    const first_digest = first_inspection.report.digest;
    first_inspection.deinit();
    var second_inspection = try inspect(testing.allocator, testing.io, second_path);
    const second_digest = second_inspection.report.digest;
    second_inspection.deinit();
    const entries = [_]RegistryEntry{
        .{ .name = "first", .path = first_path, .enabled = true, .trusted_digest = first_digest, .receipt = .{ .bundle_digest = first_digest, .bbr_identity = "test-build", .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION } },
        .{ .name = "second", .path = second_path, .enabled = true, .trusted_digest = second_digest, .receipt = .{ .bundle_digest = second_digest, .bbr_identity = "test-build", .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION } },
    };
    var registry = try Registry.init(testing.allocator, testing.io, &entries, &.{.{
        .name = "second",
        .rules = .{ .filenames = &.{"exact.fixture"} },
    }}, "test-build");
    defer registry.deinit();

    try testing.expectEqualStrings("second", registry.matchName("src/exact.fixture", "").?);
    try testing.expectEqualStrings("first", registry.matchName("src/other.first", "").?);
    try testing.expectError(error.NativeLibraryLoadFailed, registry.grammar("src/other.first", ""));
}

test "registry rejects stale active receipts but lists invalid inactive installations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeRegistryBundle(&tmp, "fixture", ".fixture", "not a library");
    defer testing.allocator.free(path);
    var inspection = try inspect(testing.allocator, testing.io, path);
    const digest = inspection.report.digest;
    inspection.deinit();

    const stale = [_]RegistryEntry{.{
        .name = "fixture",
        .path = path,
        .enabled = true,
        .trusted_digest = digest,
        .receipt = .{ .bundle_digest = digest, .bbr_identity = "old-build", .tree_sitter_identity = c.TREE_SITTER_LANGUAGE_VERSION },
    }};
    try testing.expectError(error.NativeLibraryLoadFailed, Registry.init(testing.allocator, testing.io, &stale, &.{}, "test-build"));

    var payload = try tmp.dir.openFile(testing.io, "fixture/payload", .{ .mode = .write_only });
    try payload.writeStreamingAll(testing.io, "tampered");
    payload.close(testing.io);
    const inactive = [_]RegistryEntry{.{ .name = "fixture", .path = path, .enabled = false, .trusted_digest = digest }};
    var registry = try Registry.init(testing.allocator, testing.io, &inactive, &.{}, "test-build");
    defer registry.deinit();
    const statuses = try registry.statuses(testing.allocator);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(@as(usize, 1), statuses.len);
    try testing.expect(!statuses[0].enabled);
    try testing.expect(!statuses[0].valid);

    const untampered_path = try writeRegistryBundle(&tmp, "inactive", ".inactive", "bytes");
    defer testing.allocator.free(untampered_path);
    const untrusted_inactive = [_]RegistryEntry{.{ .name = "inactive", .path = untampered_path, .enabled = false, .trusted_digest = @splat(0) }};
    var untrusted_registry = try Registry.init(testing.allocator, testing.io, &untrusted_inactive, &.{}, "test-build");
    defer untrusted_registry.deinit();
    const untrusted_statuses = try untrusted_registry.statuses(testing.allocator);
    defer testing.allocator.free(untrusted_statuses);
    try testing.expect(!untrusted_statuses[0].valid);

    const active = [_]RegistryEntry{.{ .name = "fixture", .path = path, .enabled = true, .trusted_digest = digest }};
    try testing.expectError(error.PayloadDigestMismatch, Registry.init(testing.allocator, testing.io, &active, &.{}, "test-build"));
}

fn digestHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var result: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{digest}) catch unreachable;
    return result;
}

fn minimalManifest(allocator: std.mem.Allocator, library: []const u8, query: []const u8, digest: [64]u8, extension: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\name = "fixture"
        \\version = "1.0.0"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_fixture"
        \\library = "{s}"
        \\highlight_query = "{s}"
        \\[[payload]]
        \\path = "{s}"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = ["{s}"]
        \\
    , .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), library, query, library, digest, extension });
}

fn writeRegistryBundle(tmp: *testing.TmpDir, name: []const u8, extension: []const u8, payload: []const u8) ![]u8 {
    try tmp.dir.createDir(testing.io, name, .default_dir);
    const payload_path = try std.fmt.allocPrint(testing.allocator, "{s}/payload", .{name});
    defer testing.allocator.free(payload_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = payload_path, .data = payload });
    const manifest = try std.fmt.allocPrint(testing.allocator,
        \\name = "{s}"
        \\version = "1.0.0"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_fixture"
        \\library = "payload"
        \\highlight_query = "payload"
        \\[[payload]]
        \\path = "payload"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = ["{s}"]
        \\
    , .{ name, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), digestHex(payload), extension });
    defer testing.allocator.free(manifest);
    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/grammar.toml", .{name});
    defer testing.allocator.free(manifest_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = manifest_path, .data = manifest });
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

const TarTestEntry = struct { []const u8, u8, []const u8 };
fn testTar(allocator: std.mem.Allocator, entries: []const TarTestEntry) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    for (entries) |entry| {
        var header: [512]u8 = @splat(0);
        @memcpy(header[0..entry[0].len], entry[0]);
        _ = std.fmt.bufPrint(header[100..108], "{o:0>7}\x00", .{@as(usize, 0o644)}) catch unreachable;
        _ = std.fmt.bufPrint(header[124..136], "{o:0>11}\x00", .{entry[2].len}) catch unreachable;
        @memset(header[148..156], ' ');
        header[156] = entry[1];
        @memcpy(header[257..263], "ustar\x00");
        var checksum: usize = 0;
        for (header) |byte| checksum += byte;
        _ = std.fmt.bufPrint(header[148..156], "{o:0>6}\x00 ", .{checksum}) catch unreachable;
        try output.appendSlice(allocator, &header);
        try output.appendSlice(allocator, entry[2]);
        try output.appendNTimes(allocator, 0, std.mem.alignForward(usize, entry[2].len, 512) - entry[2].len);
    }
    try output.appendNTimes(allocator, 0, 1024);
    return output.toOwnedSlice(allocator);
}
