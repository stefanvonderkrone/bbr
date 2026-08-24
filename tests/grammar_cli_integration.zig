const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const bbr = args.next() orelse return error.MissingBbrPath;
    const library = args.next() orelse return error.MissingFixturePath;

    var tmp = try std.Io.Dir.cwd().createDirPathOpen(init.io, ".zig-cache/grammar-cli-integration", .{});
    defer tmp.close(init.io);
    tmp.deleteTree(init.io, "data") catch {};
    tmp.deleteTree(init.io, "config") catch {};
    tmp.deleteTree(init.io, "bundle") catch {};
    try tmp.createDirPath(init.io, "data");
    try tmp.createDirPath(init.io, "config/bbr");
    try tmp.createDirPath(init.io, "bundle/lib");
    try tmp.createDirPath(init.io, "bundle/queries");
    try std.Io.Dir.cwd().copyFile(library, std.Io.Dir.cwd(), ".zig-cache/grammar-cli-integration/bundle/lib/grammar", init.io, .{});
    const library_bytes = try tmp.readFileAlloc(init.io, "bundle/lib/grammar", init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(library_bytes);
    const query = "(identifier) @variable\n";
    try tmp.writeFile(init.io, .{ .sub_path = "bundle/queries/highlights.scm", .data = query });
    const library_digest = digestHex(library_bytes);
    const query_digest = digestHex(query);
    const manifest = try std.fmt.allocPrint(init.gpa,
        \\name = "fixture"
        \\version = "1.0.0"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_javascript"
        \\library = "lib/grammar"
        \\highlight_query = "queries/highlights.scm"
        \\[[payload]]
        \\path = "lib/grammar"
        \\sha256 = "{s}"
        \\[[payload]]
        \\path = "queries/highlights.scm"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = [".fixture"]
        \\
    , .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), library_digest, query_digest });
    defer init.gpa.free(manifest);
    try tmp.writeFile(init.io, .{ .sub_path = "bundle/grammar.toml", .data = manifest });
    const tar = try testTar(init.gpa, &.{ .{ "grammar.toml", manifest }, .{ "lib/grammar", library_bytes }, .{ "queries/highlights.scm", query } });
    defer init.gpa.free(tar);
    var compressed: std.Io.Writer.Allocating = .init(init.gpa);
    defer compressed.deinit();
    try compressed.ensureUnusedCapacity(10);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, &window, .gzip, .fastest);
    try compressor.writer.writeAll(tar);
    try compressor.finish();
    try tmp.writeFile(init.io, .{ .sub_path = "bundle.tar.gz", .data = compressed.written() });

    var env = std.process.Environ.Map.init(init.gpa);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", ".zig-cache/grammar-cli-integration/data");
    try env.put("XDG_CONFIG_HOME", ".zig-cache/grammar-cli-integration/config");
    try env.put("HOME", ".zig-cache/grammar-cli-integration");

    const check = try command(init, &env, &.{ bbr, "grammar", "check", ".zig-cache/grammar-cli-integration/bundle" });
    defer freeResult(init.gpa, check);
    try expectSuccess(check);
    const digest = try reportedDigest(check.stdout);
    const archive_check = try command(init, &env, &.{ bbr, "grammar", "check", ".zig-cache/grammar-cli-integration/bundle.tar.gz" });
    defer freeResult(init.gpa, archive_check);
    try expectSuccess(archive_check);
    if (!std.mem.eql(u8, digest, try reportedDigest(archive_check.stdout))) return error.ArchiveDigestMismatch;

    const install = try command(init, &env, &.{ bbr, "grammar", "install", ".zig-cache/grammar-cli-integration/bundle", "--trust-sha256", digest });
    defer freeResult(init.gpa, install);
    try expectSuccess(install);
    try expectList(init, &env, bbr, "fixture\tenabled\tvalid");

    const invalid_query = "(not-a-node) @variable\n";
    try tmp.writeFile(init.io, .{ .sub_path = "bundle/queries/highlights.scm", .data = invalid_query });
    const invalid_manifest = try manifestFor(init.gpa, library_digest, digestHex(invalid_query), "2.0.0");
    defer init.gpa.free(invalid_manifest);
    try tmp.writeFile(init.io, .{ .sub_path = "bundle/grammar.toml", .data = invalid_manifest });
    const invalid_check = try command(init, &env, &.{ bbr, "grammar", "check", ".zig-cache/grammar-cli-integration/bundle" });
    defer freeResult(init.gpa, invalid_check);
    try expectSuccess(invalid_check);
    const invalid_digest = try reportedDigest(invalid_check.stdout);
    const failed_update = try command(init, &env, &.{ bbr, "grammar", "update", "fixture", ".zig-cache/grammar-cli-integration/bundle", "--trust-sha256", invalid_digest });
    defer freeResult(init.gpa, failed_update);
    if (failed_update.term != .exited or failed_update.term.exited == 0) return error.InvalidUpdateSucceeded;
    try expectList(init, &env, bbr, "fixture\tenabled\tvalid");

    try expectCommandSuccess(init, &env, &.{ bbr, "grammar", "disable", "fixture" });
    try expectList(init, &env, bbr, "fixture\tdisabled\tvalid");
    try tmp.writeFile(init.io, .{ .sub_path = "config/bbr/config.toml", .data = "[grammars.fixture]\nextensions = [\".configured\"] # replaces defaults\n" });
    try expectCommandSuccess(init, &env, &.{ bbr, "grammar", "enable", "fixture" });
    const refused_remove = try command(init, &env, &.{ bbr, "grammar", "remove", "fixture" });
    defer freeResult(init.gpa, refused_remove);
    if (refused_remove.term != .exited or refused_remove.term.exited == 0) return error.ConfiguredRemovalSucceeded;
    try tmp.writeFile(init.io, .{ .sub_path = "config/bbr/config.toml", .data = "# [grammars.fixture]\n" });
    try expectCommandSuccess(init, &env, &.{ bbr, "grammar", "disable", "fixture" });
    try tmp.writeFile(init.io, .{ .sub_path = "data/bbr/grammars/fixture/queries/highlights.scm", .data = "tampered" });
    try expectList(init, &env, bbr, "fixture\tdisabled\tinvalid");
    try expectCommandSuccess(init, &env, &.{ bbr, "grammar", "remove", "fixture" });
    try expectList(init, &env, bbr, "");
}

fn reportedDigest(output: []const u8) ![]const u8 {
    const marker = "SHA-256: ";
    const start = (std.mem.indexOf(u8, output, marker) orelse return error.MissingDigest) + marker.len;
    if (output.len < start + 64) return error.MissingDigest;
    return output[start .. start + 64];
}

fn manifestFor(allocator: std.mem.Allocator, library_digest: [64]u8, query_digest: [64]u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\name = "fixture"
        \\version = "{s}"
        \\os = "{s}"
        \\arch = "{s}"
        \\tree_sitter_abi = 15
        \\symbol = "tree_sitter_javascript"
        \\library = "lib/grammar"
        \\highlight_query = "queries/highlights.scm"
        \\[[payload]]
        \\path = "lib/grammar"
        \\sha256 = "{s}"
        \\[[payload]]
        \\path = "queries/highlights.scm"
        \\sha256 = "{s}"
        \\[matches]
        \\extensions = [".fixture"]
        \\
    , .{ version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), library_digest, query_digest });
}

fn command(init: std.process.Init, env: *const std.process.Environ.Map, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(init.gpa, init.io, .{ .argv = argv, .environ_map = env });
}

fn expectCommandSuccess(init: std.process.Init, env: *const std.process.Environ.Map, argv: []const []const u8) !void {
    const result = try command(init, env, argv);
    defer freeResult(init.gpa, result);
    try expectSuccess(result);
}

fn expectList(init: std.process.Init, env: *const std.process.Environ.Map, bbr: []const u8, expected: []const u8) !void {
    const result = try command(init, env, &.{ bbr, "grammar", "list" });
    defer freeResult(init.gpa, result);
    try expectSuccess(result);
    if (!std.mem.eql(u8, std.mem.trim(u8, result.stdout, "\r\n"), expected)) return error.UnexpectedGrammarList;
}

fn expectSuccess(result: std.process.RunResult) !void {
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("grammar command failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.GrammarCommandFailed;
    }
}

fn freeResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn digestHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var result: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{digest}) catch unreachable;
    return result;
}

const TarEntry = struct { []const u8, []const u8 };

fn testTar(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    for (entries) |entry| {
        var header: [512]u8 = @splat(0);
        @memcpy(header[0..entry[0].len], entry[0]);
        _ = std.fmt.bufPrint(header[100..108], "{o:0>7}\x00", .{@as(usize, 0o644)}) catch unreachable;
        _ = std.fmt.bufPrint(header[124..136], "{o:0>11}\x00", .{entry[1].len}) catch unreachable;
        @memset(header[148..156], ' ');
        header[156] = '0';
        @memcpy(header[257..263], "ustar\x00");
        var checksum: usize = 0;
        for (header) |byte| checksum += byte;
        _ = std.fmt.bufPrint(header[148..156], "{o:0>6}\x00 ", .{checksum}) catch unreachable;
        try output.appendSlice(allocator, &header);
        try output.appendSlice(allocator, entry[1]);
        try output.appendNTimes(allocator, 0, std.mem.alignForward(usize, entry[1].len, 512) - entry[1].len);
    }
    try output.appendNTimes(allocator, 0, 1024);
    return output.toOwnedSlice(allocator);
}
