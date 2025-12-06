const std = @import("std");
const QuickJSAllocator = @import("tjs_qjs_allocator.zig").QJSAllocator;

pub const z = @import("tjs_structs.zig");
pub const c = z.c;

extern fn JS_MakeError(ctx: ?*c.JSContext, error_num: z.JSErrorEnum, message: [*c]const u8, add_backtrace: bool) c.JSValue;
extern fn tjs_sqlite3_bind_params_public(ctx: ?*c.JSContext, stmt: ?*c.sqlite3_stmt, params: c.JSValue) callconv(.c) c.JSValue;

var handle_class_id: c.JSClassID = 0;

// Negative values are never used by SQLite result codes; safe for internal signals
const RESULT_ZIG_OOM: c_int = -1;

const SqliteHandle = struct {
    ctx: ?*c.JSContext = null,
    db: ?*c.sqlite3 = null,
    in_flight: bool = false,
    abort_requested: bool = false,
};
const ErrCtx = struct {
    rc: c_int = 0,
    db: ?*c.sqlite3 = null,
};

fn jsSqliteHandleFinalizer(_: ?*c.JSRuntime, val: c.JSValue) callconv(.c) void {
    const oh: ?*SqliteHandle = @ptrCast(@alignCast(c.JS_GetOpaque(val, handle_class_id)));
    if (oh) |h| {
        if (h.db) |db| _ = c.sqlite3_close(db);
        QuickJSAllocator.allocator(h.ctx).destroy(h);
    }
}

const handle_class = c.JSClassDef{
    .class_name = "Handle",
    .finalizer = jsSqliteHandleFinalizer,
};

fn newSqliteError(ctx: ?*c.JSContext, err: c_int, db: ?*c.sqlite3) c.JSValue {
    if (err == c.SQLITE_INTERRUPT) {
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const ctor = c.JS_GetPropertyStr(ctx, global, "DOMException");
        defer if (!c.JS_IsUndefined(ctor)) c.JS_FreeValue(ctx, ctor);
        var ex: c.JSValue = undefined;
        if (c.JS_IsFunction(ctx, ctor)) {
            var args = [_]c.JSValue{ c.JS_NewString(ctx, "Aborted"), c.JS_NewString(ctx, "AbortError") };
            defer c.JS_FreeValue(ctx, args[0]);
            defer c.JS_FreeValue(ctx, args[1]);
            ex = c.JS_CallConstructor(ctx, ctor, 2, &args);
        } else {
            ex = JS_MakeError(ctx, .plain_error, "AbortError: Aborted", false);
            _ = c.JS_DefinePropertyValueStr(ctx, ex, "name", c.JS_NewString(ctx, "AbortError"), c.JS_PROP_C_W_E);
        }
        return ex;
    }

    var msg: [512:0]u8 = undefined;
    const extended_error_code: c_int = c.sqlite3_extended_errcode(db);
    const sqlite_msg = c.sqlite3_errmsg(db);
    if (extended_error_code != err) {
        _ = std.fmt.bufPrintZ(&msg, "SQLite error {d}: {s} (Extended code: {d})", .{ err, sqlite_msg, extended_error_code }) catch 0;
    } else {
        _ = std.fmt.bufPrintZ(&msg, "SQLite error {d}: {s}", .{ err, sqlite_msg }) catch 0;
    }
    const ex = JS_MakeError(ctx, .plain_error, &msg, false);
    _ = c.JS_DefinePropertyValueStr(ctx, ex, "errno", c.JS_NewInt32(ctx, err), c.JS_PROP_C_W_E);
    return ex;
}

fn throwSqliteErr(ctx: ?*c.JSContext, err: c_int, db: ?*c.sqlite3) c.JSValue {
    const obj = newSqliteError(ctx, err, db);
    return c.JS_Throw(ctx, obj);
}

fn jsOpenImpl(ctx: ?*c.JSContext, name: [*:0]const u8, flags: c_int, ec: *ErrCtx) !c.JSValue {
    var odb: ?*c.sqlite3 = null;
    const rc1 = c.sqlite3_open_v2(name, &odb, flags, null);
    if (rc1 != c.SQLITE_OK and odb != null) {
        ec.* = .{ .rc = rc1, .db = odb.? };
        return error.SQLiteError;
    }
    if (odb == null) return error.OpenError;
    errdefer _ = c.sqlite3_close(odb);
    const db = odb.?;
    _ = c.sqlite3_extended_result_codes(db, 1);

    var old_enable_ext: c_int = 0;
    const rc2 = c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, @as(c_int, 1), &old_enable_ext);
    if (rc2 != c.SQLITE_OK) {
        ec.* = .{ .rc = rc2, .db = db };
        return error.SQLiteError;
    }

    const obj = c.JS_NewObjectClass(ctx, @intCast(handle_class_id));
    if (c.JS_IsException(obj)) return error.JSException;
    errdefer c.JS_FreeValue(ctx, obj);

    const ac = QuickJSAllocator.allocator(ctx);
    const h = try ac.create(SqliteHandle);
    errdefer ac.destroy(h);

    h.* = .{ .ctx = ctx, .db = db, .in_flight = false };
    // Install a connection-wide progress handler to react to aborts
    _ = c.sqlite3_progress_handler(db, 1000, progressCallback, h);
    _ = c.JS_SetOpaque(obj, h);
    odb = null; // ownership transferred
    return obj;
}

fn jsOpen(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "Invalid arguments");

    const db_name = c.JS_ToCString(ctx, argv[0]);
    if (db_name == null) return z.JS_EXCEPTION;
    defer c.JS_FreeCString(ctx, db_name);

    var flags: c_int = 0;
    if (c.JS_ToInt32(ctx, &flags, argv[1]) != 0) return z.JS_EXCEPTION;

    var ec: ErrCtx = .{};
    const result = jsOpenImpl(ctx, db_name, flags, &ec) catch |e| switch (e) {
        error.OpenError => c.JS_ThrowTypeError(ctx, "Failed to open database"),
        error.SQLiteError => throwSqliteErr(ctx, ec.rc, ec.db),
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
        error.JSException => z.JS_EXCEPTION,
    };
    return result;
}

fn jsClose(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Invalid arguments");
    const h: ?*SqliteHandle = @ptrCast(@alignCast(c.JS_GetOpaque2(ctx, argv[0], handle_class_id)));
    if (h == null) return c.JS_ThrowTypeError(ctx, "Illegal invocation");
    if (h.?.db) |db| {
        const rc = c.sqlite3_close(db);
        if (rc != c.SQLITE_OK) return throwSqliteErr(ctx, rc, db);
        h.?.db = null;
    }
    return z.JS_UNDEFINED;
}

fn jsLoadExtension(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "Invalid arguments");
    const h: ?*SqliteHandle = @ptrCast(@alignCast(c.JS_GetOpaque2(ctx, argv[0], handle_class_id)));
    if (h == null or h.?.db == null) return c.JS_ThrowTypeError(ctx, "Illegal invocation");

    const zFile = c.JS_ToCString(ctx, argv[1]);
    if (zFile == null) return z.JS_EXCEPTION;
    defer c.JS_FreeCString(ctx, zFile);

    const zProc = if (argc >= 3 and !c.JS_IsUndefined(argv[2])) c.JS_ToCString(ctx, argv[2]) else null;
    defer if (zProc) |p| c.JS_FreeCString(ctx, p);

    const rc = c.sqlite3_load_extension(h.?.db, zFile, zProc, null);
    if (rc != c.SQLITE_OK) {
        return throwSqliteErr(ctx, rc, h.?.db);
    }
    return z.JS_UNDEFINED;
}

fn jsNotImplemented(ctx: ?*c.JSContext, _: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    return c.JS_ThrowTypeError(ctx, "Not implemented");
}

fn jsSetAbort(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Invalid arguments");
    const oh: ?*SqliteHandle = @ptrCast(@alignCast(c.JS_GetOpaque2(ctx, argv[0], handle_class_id)));
    if (oh) |h| {
        h.abort_requested = true;
        if (h.in_flight) {
            _ = c.sqlite3_interrupt(h.db);
        }
    } else return c.JS_ThrowTypeError(ctx, "Illegal invocation");
    return z.JS_UNDEFINED;
}

fn Work(comptime Result: type) type {
    return struct {
        req: c.uv_work_t,
        ctx: ?*c.JSContext,
        promise: c.TJSPromise,
        db: *c.sqlite3,
        handle: ?*SqliteHandle,
        stmt: ?*c.sqlite3_stmt,
        rc: c_int,
        result: Result, // extension payload, zero-sized if Extra is empty
    };
}

const RunWork = Work(struct {});

fn runCallback(req: [*c]c.uv_work_t) callconv(.c) void {
    const w: *RunWork = @ptrCast(@alignCast(req.*.data));
    var rc: c_int = c.SQLITE_OK;
    while (true) {
        rc = c.sqlite3_step(w.stmt);
        if (rc != c.SQLITE_ROW) break;
    }
    w.rc = if (rc == c.SQLITE_DONE or rc == c.SQLITE_OK) c.SQLITE_OK else rc;
}

fn afterRunCallback(req: [*c]c.uv_work_t, _: c_int) callconv(.c) void {
    const w: *RunWork = @ptrCast(@alignCast(req.*.data));
    defer QuickJSAllocator.allocator(w.ctx).destroy(w);

    const ctx = w.ctx;

    if (w.handle) |h| {
        h.in_flight = false;
        h.abort_requested = false;
    }
    if (w.stmt) |stmt| _ = c.sqlite3_finalize(stmt);

    if (w.rc == c.SQLITE_OK) {
        var argv = [_]c.JSValue{ z.JS_UNDEFINED };
        c.TJS_ResolvePromise(ctx, &w.promise, 1, &argv);
    } else {
        const err = newSqliteError(ctx, w.rc, w.db);
        var argv = [_]c.JSValue{ err };
        c.TJS_RejectPromise(ctx, &w.promise, 1, &argv);
    }
}

const ColType = enum { null_, int64, float64, text, blob };

const ColValue = union(ColType) {
    null_: void,
    int64: i64,
    float64: f64,
    text: []u8,
    blob: []u8,
};

const Row = struct {
    values: []ColValue,
};

const AllWork = Work(struct {
    num_cols: c_int,
    col_names: [][:0]u8,
    rows: []Row,
    arena: std.heap.ArenaAllocator,
});

fn progressCallback(userdata: ?*anyopaque) callconv(.c) c_int {
    if (userdata == null) return 0;
    const oh: ?*SqliteHandle = @ptrCast(@alignCast(userdata));
    return if (oh) |h| if (h.abort_requested) c.SQLITE_INTERRUPT else c.SQLITE_OK else c.SQLITE_OK;
}

fn allCallbackImpl(w: *AllWork) !void {
    const stmt = w.stmt.?;

    w.rc = c.sqlite3_reset(stmt);
    if (w.rc != c.SQLITE_OK) return error.SqliteError;

    const wr = &w.result;
    const ac = wr.arena.allocator();

    // Capture column info
    wr.num_cols = c.sqlite3_column_count(stmt);
    wr.col_names = try ac.alloc([:0]u8, @intCast(wr.num_cols));
    var col_idx: c_int = 0;
    while (col_idx < wr.num_cols) : (col_idx += 1) {
        const name_c = c.sqlite3_column_name(stmt, col_idx);
        if (name_c == null) return error.OutOfMemory;
        const name_z = std.mem.span(name_c);
        const buf = try ac.alloc(u8, name_z.len + 1);
        std.mem.copyForwards(u8, buf[0..name_z.len], name_z);
        buf[name_z.len] = 0;
        wr.col_names[@intCast(col_idx)] = buf[0..name_z.len :0];
    }

    // Step rows
    var rows_builder = std.ArrayListUnmanaged(Row){};
    defer rows_builder.deinit(ac);

    var rc: c_int = c.SQLITE_OK;
    while (true) {
        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) break;

        var row_values = try ac.alloc(ColValue, @intCast(wr.num_cols));

        col_idx = 0; // reset
        while (col_idx < wr.num_cols) : (col_idx += 1) {
            const ct = c.sqlite3_column_type(stmt, col_idx);
            switch (ct) {
                c.SQLITE_INTEGER => {
                    const v: i64 = c.sqlite3_column_int64(stmt, col_idx);
                    row_values[@intCast(col_idx)] = ColValue{ .int64 = v };
                },
                c.SQLITE_FLOAT => {
                    const v: f64 = c.sqlite3_column_double(stmt, col_idx);
                    row_values[@intCast(col_idx)] = ColValue{ .float64 = v };
                },
                c.SQLITE_TEXT => {
                    const tp = c.sqlite3_column_text(stmt, col_idx);
                    const tl = c.sqlite3_column_bytes(stmt, col_idx);
                    if (tp == null or tl < 0) return error.OutOfMemory;
                    const src = @as([*]const u8, @ptrCast(tp))[0..@intCast(tl)];
                    const dst = try ac.alloc(u8, src.len);
                    @memcpy(dst, src);
                    row_values[@intCast(col_idx)] = ColValue{ .text = dst };
                },
                c.SQLITE_BLOB => {
                    const bp = c.sqlite3_column_blob(stmt, col_idx);
                    const bl = c.sqlite3_column_bytes(stmt, col_idx);
                    if (bp == null or bl < 0) return error.OutOfMemory;
                    const src = @as([*]const u8, @ptrCast(bp))[0..@intCast(bl)];
                    const dst = try ac.alloc(u8, src.len);
                    @memcpy(dst, src);
                    row_values[@intCast(col_idx)] = ColValue{ .blob = dst };
                },
                else => {
                    row_values[@intCast(col_idx)] = ColValue{ .null_ = {} };
                },
            }
        }
        try rows_builder.append(ac, .{ .values = row_values });
    }

    wr.rows = try rows_builder.toOwnedSlice(ac);
    w.rc = if (rc == c.SQLITE_DONE) c.SQLITE_OK else rc;
}

fn allCallback(req: [*c]c.uv_work_t) callconv(.c) void {
    const w: *AllWork = @ptrCast(@alignCast(req.*.data));
    allCallbackImpl(w) catch |e| switch (e) {
        error.OutOfMemory => w.rc = RESULT_ZIG_OOM,
        error.SqliteError => {}, // w.result already set
    };
}

fn jsFromColValue(ctx: ?*c.JSContext, v: ColValue) c.JSValue {
    return switch (v) {
        .null_ => z.JS_NULL,
        .int64 => |x| blk: {
            const max_safe: i64 = 9007199254740991;
            const min_safe: i64 = -9007199254740991;
            if (x > max_safe or x < min_safe) break :blk c.JS_NewBigInt64(ctx, x);
            break :blk c.JS_NewInt64(ctx, x);
        },
        .float64 => |x| c.JS_NewFloat64(ctx, x),
        .text => |s| c.JS_NewStringLen(ctx, s.ptr, @intCast(s.len)),
        .blob => |b| c.JS_NewUint8ArrayCopy(ctx, b.ptr, @intCast(b.len)),
    };
}

fn afterAllCallbackImpl(w: *AllWork, ec: *ErrCtx) !c.JSValue {
    const ctx = w.ctx;
    const wr = &w.result;
    defer wr.arena.deinit();

    if (w.handle) |h| {
        h.in_flight = false;
        h.abort_requested = false;
    }
    if (w.stmt) |stmt| {
        _ = c.sqlite3_finalize(stmt);
    }
    if (w.rc == RESULT_ZIG_OOM) {
        return error.OutOfMemory;
    }
    if (w.rc != c.SQLITE_OK) {
        ec.* = .{ .rc = w.rc, .db = w.db };
        return error.SQLiteError;
    }

    const arr = c.JS_NewArray(ctx);
    if (c.JS_IsException(arr)) return error.JSException;
    errdefer c.JS_FreeValue(ctx, arr);

    var row_idx: usize = 0;
    while (row_idx < wr.rows.len) : (row_idx += 1) {
        const obj = c.JS_NewObjectProto(ctx, z.JS_NULL);
        if (c.JS_IsException(obj)) return error.JSException;
        errdefer c.JS_FreeValue(ctx, obj);

        const row = wr.rows[row_idx];
        var col_idx: usize = 0;
        while (col_idx < @as(usize, @intCast(wr.num_cols))) : (col_idx += 1) {
            const v = jsFromColValue(ctx, row.values[col_idx]);
            if (c.JS_IsException(v)) return error.JSException;
            errdefer c.JS_FreeValue(ctx, v);

            if (c.JS_DefinePropertyValueStr(ctx, obj, &wr.col_names[col_idx][0], v, c.JS_PROP_C_W_E) < 0) {
                return error.JSException;
            }
        }
        if (c.JS_DefinePropertyValueUint32(ctx, arr, @intCast(row_idx), obj, c.JS_PROP_C_W_E) < 0) {
            return error.JSException;
        }
    }
    return arr;
}

inline fn oomException(ctx: ?*c.JSContext) c.JSValue {
    _ = c.JS_ThrowOutOfMemory(ctx);
    return c.JS_GetException(ctx);
}

fn afterAllCallback(req: [*c]c.uv_work_t, _: c_int) callconv(.c) void {
    const w: *AllWork = @ptrCast(@alignCast(req.*.data));
    defer QuickJSAllocator.allocator(w.ctx).destroy(w);

    var is_rejected = false;
    var ec: ErrCtx = .{};
    const res = afterAllCallbackImpl(w, &ec) catch |e| blk: {
        is_rejected = true;
        break :blk switch (e) {
            error.SQLiteError => newSqliteError(w.ctx, ec.rc, ec.db),
            error.OutOfMemory => oomException(w.ctx),
            error.JSException => c.JS_GetException(w.ctx),
        };
    };

    var argv = [_]c.JSValue{ res };
    if (!is_rejected) {
        c.TJS_ResolvePromise(w.ctx, &w.promise, 1, &argv);
    } else {
        c.TJS_RejectPromise(w.ctx, &w.promise, 1, &argv);
    }
}

fn allAsyncImpl(ctx: ?*c.JSContext, h: *SqliteHandle, sql: [*:0]const u8, params: c.JSValue, ec: *ErrCtx) !c.JSValue {
    var stmt: ?*c.sqlite3_stmt = null;
    const pr = c.sqlite3_prepare_v2(h.db, sql, -1, &stmt, null);
    if (pr != c.SQLITE_OK or stmt == null) {
        ec.* = .{ .rc = pr, .db = h.db };
        return error.SQLiteError;
    }
    errdefer _ = c.sqlite3_finalize(stmt);

    if (!c.JS_IsUndefined(params)) {
        if (c.JS_IsException(tjs_sqlite3_bind_params_public(ctx, stmt, params))) {
            return error.JSException;
        }
    }

    const ac = QuickJSAllocator.allocator(ctx);
    var w = try ac.create(AllWork);
    errdefer ac.destroy(w);
    w.* = .{
        .req = undefined,
        .ctx = ctx,
        .promise = undefined,
        .db = h.db.?,
        .handle = h,
        .stmt = stmt,
        .rc = c.SQLITE_OK,
        .result = .{
            .num_cols = 0,
            .col_names = &.{},
            .rows = &.{},
            .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        },
    };

    const promise = c.TJS_InitPromise(ctx, &w.promise);
    if (c.JS_IsException(promise)) return error.JSException;
    w.req.data = @ptrCast(w);

    h.in_flight = true;
    errdefer h.in_flight = false;

    const q = c.uv_queue_work(c.tjs_get_loop(ctx), &w.req, allCallback, afterAllCallback);
    if (q != 0) {
        ec.* = .{ .rc = q, .db = h.db };
        return error.UVError;
    }

    return promise;
}

fn execAsyncImpl(ctx: ?*c.JSContext, h: *SqliteHandle, sql: [*:0]const u8, params: c.JSValue, ec: *ErrCtx) !c.JSValue {
    var stmt: ?*c.sqlite3_stmt = null;
    const pr = c.sqlite3_prepare_v2(h.db, sql, -1, &stmt, null);
    if (pr != c.SQLITE_OK or stmt == null) {
        ec.* = .{ .rc = pr, .db = h.db };
        return error.SQLiteError;
    }
    errdefer _ = c.sqlite3_finalize(stmt);

    if (!c.JS_IsUndefined(params)) {
        if (c.JS_IsException(tjs_sqlite3_bind_params_public(ctx, stmt, params))) {
            return error.JSException;
        }
    }

    const ac = QuickJSAllocator.allocator(ctx);
    var w = try ac.create(RunWork);
    errdefer ac.destroy(w);
    w.* = .{
        .req = undefined,
        .ctx = ctx,
        .promise = undefined,
        .db = h.db.?,
        .handle = h,
        .stmt = stmt,
        .rc = c.SQLITE_OK,
        .result = .{},
    };

    const promise = c.TJS_InitPromise(ctx, &w.promise);
    if (c.JS_IsException(promise)) return error.JSException;
    w.req.data = @ptrCast(w);

    h.in_flight = true;
    errdefer h.in_flight = false;

    const q = c.uv_queue_work(c.tjs_get_loop(ctx), &w.req, runCallback, afterRunCallback);
    if (q != 0) {
        ec.* = .{ .rc = q, .db = h.db };
        return error.UVError;
    }

    return promise;
}

fn jsExecAsync(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "Invalid arguments");

    const h: ?*SqliteHandle = @ptrCast(@alignCast(c.JS_GetOpaque2(ctx, argv[0], handle_class_id)));
    if (h == null or h.?.db == null) return c.JS_ThrowTypeError(ctx, "Illegal invocation");

    const sql = c.JS_ToCString(ctx, argv[1]);
    if (sql == null) return z.JS_EXCEPTION;
    defer c.JS_FreeCString(ctx, sql);

    const params = if (argc >= 3) argv[2] else z.JS_UNDEFINED;

    var ec: ErrCtx = .{};
    const promise = execAsyncImpl(ctx, h.?, sql, params, &ec) catch |e| switch (e) {
        error.SQLiteError => return throwSqliteErr(ctx, ec.rc, ec.db),
        error.UVError => return c.JS_ThrowInternalError(ctx, "sqlite exec_async failed"),
        error.OutOfMemory => return c.JS_ThrowOutOfMemory(ctx),
        error.JSException => return z.JS_EXCEPTION, // quickjs already in exception state
    };
    return promise;
}

fn jsAllAsync(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "Invalid arguments");

    const h: ?*SqliteHandle = @ptrCast(@alignCast(c.JS_GetOpaque2(ctx, argv[0], handle_class_id)));
    if (h == null or h.?.db == null) return c.JS_ThrowTypeError(ctx, "Illegal invocation");

    const sql = c.JS_ToCString(ctx, argv[1]);
    if (sql == null) return z.JS_EXCEPTION;
    defer c.JS_FreeCString(ctx, sql);

    const params = if (argc >= 3) argv[2] else z.JS_UNDEFINED;

    var ec: ErrCtx = .{};
    const promise = allAsyncImpl(ctx, h.?, sql, params, &ec) catch |e| switch (e) {
        error.SQLiteError => return throwSqliteErr(ctx, ec.rc, ec.db),
        error.UVError => return c.JS_ThrowInternalError(ctx, "sqlite all_async failed"),
        error.OutOfMemory => return c.JS_ThrowOutOfMemory(ctx),
        error.JSException => z.JS_EXCEPTION, // quickjs already in exception state
    };
    return promise;
}

const sqlite_funcs = [_]c.JSCFunctionListEntry{
    z.JS_CFUNC_DEF("open", 2, jsOpen),
    z.JS_CFUNC_DEF("load_extension", 3, jsLoadExtension),
    z.JS_CFUNC_DEF("close", 1, jsClose),
    z.JS_CFUNC_DEF("exec_async", 2, jsExecAsync),
    z.JS_CFUNC_DEF("set_abort", 1, jsSetAbort),
    z.JS_CFUNC_DEF("all_async", 3, jsAllAsync),
    z.JS_PROP_INT32_DEF("SQLITE_OPEN_CREATE", c.SQLITE_OPEN_CREATE, c.JS_PROP_ENUMERABLE),
    z.JS_PROP_INT32_DEF("SQLITE_OPEN_READONLY", c.SQLITE_OPEN_READONLY, c.JS_PROP_ENUMERABLE),
    z.JS_PROP_INT32_DEF("SQLITE_OPEN_READWRITE", c.SQLITE_OPEN_READWRITE, c.JS_PROP_ENUMERABLE),
};

pub fn initModSqlite3Async(ctx: ?*c.JSContext, ns: c.JSValue) void {
    const rt = c.JS_GetRuntime(ctx);

    // Handle object
    _ = c.JS_NewClassID(rt, &handle_class_id);
    _ = c.JS_NewClass(rt, handle_class_id, &handle_class);
    c.JS_SetClassProto(ctx, handle_class_id, z.JS_NULL);

    const obj = c.JS_NewObjectProto(ctx, z.JS_NULL);
    c.JS_SetPropertyFunctionList(ctx, obj, &sqlite_funcs, sqlite_funcs.len);

    _ = c.JS_DefinePropertyValueStr(ctx, ns, "sqlite3_async", obj, c.JS_PROP_C_W_E);
}
