const std = @import("std");
const bbr = @import("bbr");
const synthetic = @import("synthetic.zig");

pub const name = "intraline_500_parts";

pub fn run(allocator: std.mem.Allocator, pair: *const synthetic.LinePair) !bbr.diff.intraline.Pair {
    return bbr.diff.intraline.diff(allocator, pair.old, pair.new);
}

pub fn checksum(result: bbr.diff.intraline.Pair) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(&.{@intFromBool(result.whole_line)});
    for (result.old) |segment| {
        hash.update(segment.text);
        hash.update(&.{@intFromBool(segment.emphasis)});
    }
    for (result.new) |segment| {
        hash.update(segment.text);
        hash.update(&.{@intFromBool(segment.emphasis)});
    }
    return hash.final();
}
