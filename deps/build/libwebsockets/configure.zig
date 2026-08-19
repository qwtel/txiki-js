//! Generate `lws_config.h` and `lws_config_private.h` from CMake `.in` templates
//! without running CMake. Substitution and `#cmakedefine` flags come from
//! `config.zon` (parsed with `std.zon.parse.fromSliceAlloc` when the
//! schema contains pointers; same pattern as the root `build.zig` / `build.zig.zon`).

const std = @import("std");

pub const LwsConfigZon = struct {
    subst: []const struct { name: []const u8, value: []const u8 },
    public_cmakedef_base: []const []const u8,
    public_cmakedef_unix: []const []const u8,
    public_cmakedef_linux: []const []const u8,
    public_cmakedef_windows: []const []const u8,
    public_cmakedef_non_android: []const []const u8,
    private_cmakedef_base: []const []const u8,
    private_cmakedef_unix: []const []const u8,
    private_cmakedef_windows: []const []const u8,
};

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Variable names whose `${name}` substitution must become a C string literal (quoted, escaped).
const c_string_subst_keys = [_][]const u8{"LWS_LIBRARY_VERSION_PATCH_ELABORATED"};

fn substNeedsCStringLiteral(key: []const u8) bool {
    for (c_string_subst_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn cMacroStringLiteral(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

/// Body after `#cmakedefine ` or `//#cmakedefine ` (CMake sometimes comments these out in .in files).
fn cmakedefineBodyAfterPrefix(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "#cmakedefine ")) return line["#cmakedefine ".len..];
    if (std.mem.startsWith(u8, line, "//#cmakedefine ")) return line["//#cmakedefine ".len..];
    return null;
}

fn parseCmakedefineName(body: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
    if (i >= body.len) return null;
    const start = i;
    while (i < body.len and isIdentByte(body[i])) i += 1;
    if (i == start) return null;
    return body[start..i];
}

fn substDollarBraces(allocator: std.mem.Allocator, input: []const u8, vars: std.StringArrayHashMapUnmanaged([]const u8)) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        if (input[pos] == '$' and pos + 1 < input.len and input[pos + 1] == '{') {
            const key_start = pos + 2;
            const key_end = std.mem.indexOfScalarPos(u8, input, key_start, '}') orelse {
                try out.appendSlice(allocator, input[pos..]);
                break;
            };
            const key = input[key_start..key_end];
            const raw = vars.get(key) orelse "";
            if (substNeedsCStringLiteral(key)) {
                const quoted = try cMacroStringLiteral(allocator, raw);
                defer allocator.free(quoted);
                try out.appendSlice(allocator, quoted);
            } else {
                try out.appendSlice(allocator, raw);
            }
            pos = key_end + 1;
        } else {
            try out.append(allocator, input[pos]);
            pos += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn configureTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    vars: std.StringArrayHashMapUnmanaged([]const u8),
    cmakedef_true: std.StringArrayHashMapUnmanaged(void),
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (cmakedefineBodyAfterPrefix(line)) |body| {
            const name = parseCmakedefineName(body) orelse {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                continue;
            };
            const body_after_name = blk: {
                var j: usize = 0;
                while (j < body.len and std.ascii.isWhitespace(body[j])) j += 1;
                j += name.len;
                break :blk std.mem.trim(u8, body[j..], " \t");
            };

            if (cmakedef_true.contains(name)) {
                const replaced = try substDollarBraces(allocator, body_after_name, vars);
                defer allocator.free(replaced);
                if (replaced.len == 0) {
                    try out.print(allocator, "#define {s}\n", .{name});
                } else {
                    try out.print(allocator, "#define {s} {s}\n", .{ name, replaced });
                }
            } else {
                try out.print(allocator, "/* #undef {s} */\n", .{name});
            }
        } else {
            const replaced = try substDollarBraces(allocator, line, vars);
            defer allocator.free(replaced);
            try out.appendSlice(allocator, replaced);
            try out.append(allocator, '\n');
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parseLwsConfig(allocator: std.mem.Allocator, zon_src: [:0]const u8) !LwsConfigZon {
    const cfg = try std.zon.parse.fromSliceAlloc(LwsConfigZon, allocator, zon_src, null, .{
        .ignore_unknown_fields = true,
    });
    errdefer std.zon.parse.free(allocator, cfg);
    return cfg;
}

fn fillVarsFromZon(vars: *std.StringArrayHashMapUnmanaged([]const u8), gpa: std.mem.Allocator, cfg: LwsConfigZon) !void {
    for (cfg.subst) |e| try vars.put(gpa, e.name, e.value);
}

pub fn generatePublic(
    allocator: std.mem.Allocator,
    template: []const u8,
    target: std.Target,
    optimize: std.builtin.OptimizeMode,
    zon_src: [:0]const u8,
) ![]const u8 {
    const cfg = try parseLwsConfig(allocator, zon_src);
    defer std.zon.parse.free(allocator, cfg);

    var vars: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer vars.deinit(allocator);
    try fillVarsFromZon(&vars, allocator, cfg);

    var cmakedef_true: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer cmakedef_true.deinit(allocator);
    for (cfg.public_cmakedef_base) |n| try cmakedef_true.put(allocator, n, {});
    const os_cmakedef = if (target.os.tag == .windows) cfg.public_cmakedef_windows else cfg.public_cmakedef_unix;
    for (os_cmakedef) |n| try cmakedef_true.put(allocator, n, {});
    if (target.os.tag == .linux) {
        for (cfg.public_cmakedef_linux) |n| try cmakedef_true.put(allocator, n, {});
    }
    if (!target.abi.isAndroid()) {
        for (cfg.public_cmakedef_non_android) |n| try cmakedef_true.put(allocator, n, {});
    }
    if (optimize != .Debug) try cmakedef_true.put(allocator, "LWS_WITH_NO_LOGS", {});

    return configureTemplate(allocator, template, vars, cmakedef_true);
}

pub fn generatePrivate(
    allocator: std.mem.Allocator,
    template: []const u8,
    target: std.Target,
    zon_src: [:0]const u8,
) ![]const u8 {
    const cfg = try parseLwsConfig(allocator, zon_src);
    defer std.zon.parse.free(allocator, cfg);

    var vars: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer vars.deinit(allocator);
    try fillVarsFromZon(&vars, allocator, cfg);

    var cmakedef_true: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer cmakedef_true.deinit(allocator);
    for (cfg.private_cmakedef_base) |n| try cmakedef_true.put(allocator, n, {});
    const os_cmakedef = if (target.os.tag == .windows) cfg.private_cmakedef_windows else cfg.private_cmakedef_unix;
    for (os_cmakedef) |n| try cmakedef_true.put(allocator, n, {});

    const no_fork = switch (target.os.tag) {
        .windows, .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };
    if (!no_fork) try cmakedef_true.put(allocator, "LWS_HAVE_FORK", {});

    return configureTemplate(allocator, template, vars, cmakedef_true);
}
