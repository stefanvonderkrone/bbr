const std = @import("std");
const bbr = @import("bbr");
const predicate_mod = @import("query_predicates.zig");
const c = predicate_mod.c;

pub const PreparedQuery = struct {
    query: *c.TSQuery,
    predicates: predicate_mod.Set,
    /// One entry for each pattern of an injection query, empty for other kinds.
    injections: []predicate_mod.Injection = &.{},

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
            diagnostic.query_error = error_type;
            return switch (kind) {
                .highlight => error.InvalidHighlightQuery,
                .locals => error.InvalidLocalsQuery,
                .injections => error.InvalidInjectionQuery,
            };
        };
        errdefer c.ts_query_delete(query);
        const injections: []predicate_mod.Injection = if (kind == .injections) try allocator.alloc(predicate_mod.Injection, c.ts_query_pattern_count(query)) else &.{};
        errdefer allocator.free(injections);
        const validated = if (kind == .injections)
            predicate_mod.Set.validateInjections(allocator, query, source, diagnostic, injections)
        else
            predicate_mod.Set.validate(allocator, query, source, diagnostic);
        const predicates = validated catch |err| {
            diagnostic.query_kind = kind;
            return err;
        };
        return .{ .query = query, .predicates = predicates, .injections = injections };
    }

    fn deinit(self: PreparedQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.injections);
        self.predicates.deinit(allocator);
        c.ts_query_delete(self.query);
    }
};

pub const InjectionQuery = struct {
    prepared: PreparedQuery,
    content_id: u32,
    language_id: ?u32,
};

pub const RuntimePackage = struct {
    allocator: std.mem.Allocator,
    language: *const c.TSLanguage,
    highlight: PreparedQuery,
    locals: ?PreparedQuery,
    injection: ?InjectionQuery = null,
    capture_names: []const []const u8,
    /// Null for a hidden Capture, whose name starts with `_`. Only predicates use it.
    captures: []const ?bbr.highlight.Capture,
    local_scope_id: ?u32 = null,
    local_definition_id: ?u32 = null,
    local_reference_id: ?u32 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        language: *const c.TSLanguage,
        highlight_source: []const u8,
        locals_source: []const u8,
        injections_source: []const u8,
        diagnostic: *predicate_mod.Diagnostic,
    ) !RuntimePackage {
        if (highlight_source.len > std.math.maxInt(u32) or locals_source.len > std.math.maxInt(u32) or injections_source.len > std.math.maxInt(u32)) return error.QueryTooLarge;
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
        const captures = try allocator.alloc(?bbr.highlight.Capture, capture_count);
        errdefer allocator.free(captures);
        for (capture_names) |*name| {
            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(highlight.query, @intCast(names_initialized), &name_len) orelse return error.InvalidCapture;
            name.* = try allocator.dupe(u8, name_ptr[0..name_len]);
            names_initialized += 1;
        }
        for (capture_names, captures, 0..) |name, *capture, id| {
            capture.* = if (std.mem.startsWith(u8, name, "_")) null else bbr.highlight.Capture.init(@intCast(id), name);
        }

        const locals = if (locals_source.len == 0) null else try PreparedQuery.init(allocator, language, locals_source, .locals, diagnostic);
        errdefer if (locals) |query| query.deinit(allocator);
        const injection: ?InjectionQuery = if (injections_source.len == 0) null else try initInjection(allocator, language, injections_source, diagnostic);
        return .{
            .allocator = allocator,
            .language = language,
            .highlight = highlight,
            .locals = locals,
            .injection = injection,
            .capture_names = capture_names,
            .captures = captures,
            .local_scope_id = if (locals) |query| predicate_mod.captureId(query.query, "local.scope") else null,
            .local_definition_id = if (locals) |query| predicate_mod.captureId(query.query, "local.definition") else null,
            .local_reference_id = if (locals) |query| predicate_mod.captureId(query.query, "local.reference") else null,
        };
    }

    fn initInjection(allocator: std.mem.Allocator, language: *const c.TSLanguage, source: []const u8, diagnostic: *predicate_mod.Diagnostic) !InjectionQuery {
        const prepared = try PreparedQuery.init(allocator, language, source, .injections, diagnostic);
        errdefer prepared.deinit(allocator);
        const content_id = predicate_mod.captureId(prepared.query, "injection.content") orelse {
            predicate_mod.setInvalidQueryDiagnostic(source, diagnostic, 0, .injections);
            return error.InvalidInjectionQuery;
        };
        return .{ .prepared = prepared, .content_id = content_id, .language_id = predicate_mod.captureId(prepared.query, "injection.language") };
    }

    pub fn deinit(self: *RuntimePackage) void {
        if (self.injection) |injection| injection.prepared.deinit(self.allocator);
        if (self.locals) |query| query.deinit(self.allocator);
        for (self.capture_names) |name| self.allocator.free(name);
        self.allocator.free(self.capture_names);
        self.allocator.free(self.captures);
        self.highlight.deinit(self.allocator);
        self.* = undefined;
    }
};
