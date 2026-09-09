const std = @import("std");
const bbr = @import("bbr");

pub const name = "diff_parse_300_files_50000_lines";

pub fn run(allocator: std.mem.Allocator, raw: []const u8) !bbr.diff.Diff {
    return bbr.diff.parse(allocator, raw);
}

pub fn checksum(parsed: bbr.diff.Diff) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (parsed.files) |file| {
        hash.update(file.old_path);
        hash.update(file.new_path);
        for (file.hunks) |hunk| {
            hash.update(std.mem.asBytes(&hunk.old_start));
            hash.update(std.mem.asBytes(&hunk.new_start));
            for (hunk.lines) |line| {
                hash.update(&.{@intFromEnum(line.kind)});
                hash.update(line.text);
            }
        }
    }
    return hash.final();
}
