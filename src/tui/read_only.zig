//! A comptime proof that a value gives no write access to the data behind it.

const std = @import("std");

/// Fails the build when a mutable pointer is reachable from `T` through its
/// fields or the return types of its public non-generic functions. A `const`
/// pointer alone is not enough: `std.StringHashMapUnmanaged.getPtr` takes the
/// map by value and returns a `*V` into its entries. `path` names the value
/// in the error.
pub fn assert(comptime T: type, comptime path: []const u8) void {
    comptime {
        @setEvalBranchQuota(100_000);
        walk(T, path, &.{});
    }
}

fn walk(comptime T: type, comptime path: []const u8, comptime seen: []const type) void {
    for (seen) |done| if (done == T) return;
    const next = seen ++ .{T};
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (!pointer.is_const) @compileError(path ++ " is the mutable pointer " ++ @typeName(T) ++ ", so a write through it compiles");
            if (pointer.child != anyopaque) walk(pointer.child, path ++ ".*", next);
        },
        .optional => |optional| walk(optional.child, path ++ ".?", next),
        .array => |array| walk(array.child, path ++ "[]", next),
        .error_union => |error_union| walk(error_union.payload, path, next),
        inline .@"struct", .@"union" => |container| {
            for (container.fields) |field| walk(field.type, path ++ "." ++ field.name, next);
            for (container.decls) |decl| {
                const info = @typeInfo(@TypeOf(@field(T, decl.name)));
                if (info != .@"fn" or info.@"fn".is_generic) continue;
                if (info.@"fn".return_type) |Return| walk(Return, path ++ "." ++ decl.name ++ "()", next);
            }
        },
        else => {},
    }
}

test "a static string map behind a const pointer is read-only" {
    assert(*const std.StaticStringMap([]const u8), "names");
    assert([]const struct { text: []const u8, next: ?*const u8 }, "items");
}
