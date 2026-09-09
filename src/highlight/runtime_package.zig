const std = @import("std");
const bbr = @import("bbr");
const predicate_mod = @import("query_predicates.zig");
const c = predicate_mod.c;

pub const PreparedQuery = struct {
    query: *c.TSQuery,
    predicates: predicate_mod.Set,

    fn init(
        allocator: std.mem.Allocator,
        language: *const c.TSLanguage,
        source: []const u8,
        kind: predicate_mod.Diagnostic.QueryKind,
        diagnostic: *predicate_mod.Diagnostic,
    ) !PreparedQuery {
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = undefined;
        const query = c.ts_query_new(language, source.ptr, @intCast(source.len), &error_offset, &error_type) orelse {
            predicate_mod.setInvalidQueryDiagnostic(source, diagnostic, error_offset, kind);
            return if (kind == .locals) error.InvalidLocalsQuery else error.InvalidHighlightQuery;
        };
        errdefer c.ts_query_delete(query);
        const predicates = predicate_mod.Set.validate(allocator, query, source, diagnostic) catch |err| {
            diagnostic.query_kind = kind;
            return err;
        };
        return .{ .query = query, .predicates = predicates };
    }

    fn deinit(self: PreparedQuery, allocator: std.mem.Allocator) void {
        self.predicates.deinit(allocator);
        c.ts_query_delete(self.query);
    }
};

pub const RuntimePackage = struct {
    allocator: std.mem.Allocator,
    language: *const c.TSLanguage,
    highlight: PreparedQuery,
    locals: ?PreparedQuery,
    capture_names: []const []const u8,
    captures: []const bbr.highlight.Capture,
    local_scope_id: ?u32 = null,
    local_definition_id: ?u32 = null,
    local_reference_id: ?u32 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        language: *const c.TSLanguage,
        highlight_source: []const u8,
        locals_source: []const u8,
        diagnostic: *predicate_mod.Diagnostic,
    ) !RuntimePackage {
        if (highlight_source.len > std.math.maxInt(u32) or locals_source.len > std.math.maxInt(u32)) return error.QueryTooLarge;
        const highlight = try PreparedQuery.init(allocator, language, highlight_source, .highlight, diagnostic);
        errdefer highlight.deinit(allocator);

        const capture_count = c.ts_query_capture_count(highlight.query);
        if (capture_count > @as(u32, std.math.maxInt(u16)) + 1) return error.TooManyCaptures;
        const capture_names = try allocator.alloc([]const u8, capture_count);
        var names_initialized: usize = 0;
        errdefer {
            for (capture_names[0..names_initialized]) |name| allocator.free(name);
            allocator.free(capture_names);
        }
        const captures = try allocator.alloc(bbr.highlight.Capture, capture_count);
        errdefer allocator.free(captures);
        for (capture_names) |*name| {
            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(highlight.query, @intCast(names_initialized), &name_len) orelse return error.InvalidCapture;
            name.* = try allocator.dupe(u8, name_ptr[0..name_len]);
            names_initialized += 1;
        }
        for (capture_names, 0..) |name, id| captures[id] = bbr.highlight.Capture.init(@intCast(id), name);

        const locals = if (locals_source.len == 0) null else try PreparedQuery.init(allocator, language, locals_source, .locals, diagnostic);
        errdefer if (locals) |query| query.deinit(allocator);
        return .{
            .allocator = allocator,
            .language = language,
            .highlight = highlight,
            .locals = locals,
            .capture_names = capture_names,
            .captures = captures,
            .local_scope_id = if (locals) |query| predicate_mod.captureId(query.query, "local.scope") else null,
            .local_definition_id = if (locals) |query| predicate_mod.captureId(query.query, "local.definition") else null,
            .local_reference_id = if (locals) |query| predicate_mod.captureId(query.query, "local.reference") else null,
        };
    }

    pub fn deinit(self: *RuntimePackage) void {
        if (self.locals) |query| query.deinit(self.allocator);
        for (self.capture_names) |name| self.allocator.free(name);
        self.allocator.free(self.capture_names);
        self.allocator.free(self.captures);
        self.highlight.deinit(self.allocator);
        self.* = undefined;
    }
};
