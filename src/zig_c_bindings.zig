pub const z = @import("tjs_structs.zig");
pub const c = z.c;

pub const v8_compat = @import("mod_v8_compat.zig");
const has_sqlite = @hasDecl(c, "sqlite3");
pub const sqlite_async = if (has_sqlite) @import("mod_sqlite3_async.zig") else struct {};

export fn zig__mod_v8_compat_init(ctx: ?*c.JSContext, ns: c.JSValue) callconv(.c) void {
    return v8_compat.initModV8Compat(ctx, ns);
}

export fn zig__mod_sqlite3_async_init(ctx: ?*c.JSContext, ns: c.JSValue) callconv(.c) void {
    if (comptime has_sqlite) {
        return sqlite_async.initModSqlite3Async(ctx, ns);
    }
}
