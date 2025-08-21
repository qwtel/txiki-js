pub const v8_compat = @import("mod_v8_compat.zig");
pub const sqlite_async = @import("mod_sqlite3_async.zig");

pub const z = @import("tjs_structs.zig");
pub const c = z.c;

export fn zig__mod_v8_compat_init(ctx: ?*c.JSContext, ns: c.JSValue) callconv(.C) void {
    return v8_compat.initModV8Compat(ctx, ns);
}

export fn zig__mod_sqlite3_async_init(ctx: ?*c.JSContext, ns: c.JSValue) callconv(.C) void {
    return sqlite_async.initModSqlite3Async(ctx, ns);
}
