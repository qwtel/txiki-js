/*
 * txiki.js
 *
 * Copyright (c) 2023-present Saúl Ibarra Corretgé <s@saghul.net>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#ifndef TJS__OMIT_SQLITE
#include "private.h"

#include <sqlite3.h>
#include <string.h>


static JSClassID tjs_sqlite3_class_id;

typedef struct TJSAsyncSQLiteWork TJSAsyncSQLiteWork;

typedef struct {
    sqlite3 *handle;
    bool in_flight; /* true while an async op is running */
} TJSSqlite3Handle;

static void tjs_sqlite3_finalizer(JSRuntime *rt, JSValue val) {
    TJSSqlite3Handle *h = JS_GetOpaque(val, tjs_sqlite3_class_id);
    if (!h) {
        return;
    }
    if (h->handle) {
        sqlite3_close(h->handle);
    }
    js_free_rt(rt, h);
}

static JSClassDef tjs_sqlite3_class = {
    "Handle",
    .finalizer = tjs_sqlite3_finalizer,
};

static JSValue tjs_new_sqlite3(JSContext *ctx, sqlite3 *handle) {
    TJSSqlite3Handle *h;
    JSValue obj;

    obj = JS_NewObjectClass(ctx, tjs_sqlite3_class_id);
    if (JS_IsException(obj)) {
        return obj;
    }

    h = js_mallocz(ctx, sizeof(*h));
    if (!h) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }

    h->handle = handle;
    h->in_flight = false;

    JS_SetOpaque(obj, h);
    return obj;
}

static TJSSqlite3Handle *tjs_sqlite3_get(JSContext *ctx, JSValue obj) {
    return JS_GetOpaque2(ctx, obj, tjs_sqlite3_class_id);
}

static JSClassID tjs_sqlite3_stmt_class_id;

typedef struct {
    sqlite3_stmt *stmt;
    TJSAsyncSQLiteWork *current_work;
} TJSSqlite3Stmt;

static void tjs_sqlite3_stmt_finalizer(JSRuntime *rt, JSValue val) {
    TJSSqlite3Stmt *h = JS_GetOpaque(val, tjs_sqlite3_stmt_class_id);
    if (!h) {
        return;
    }
    if (h->stmt) {
        sqlite3_reset(h->stmt);
        sqlite3_finalize(h->stmt);
    }
    js_free_rt(rt, h);
}

static JSClassDef tjs_sqlite3_stmt_class = {
    "Statement",
    .finalizer = tjs_sqlite3_stmt_finalizer,
};

static JSValue tjs_new_sqlite3_stmt(JSContext *ctx, sqlite3_stmt *stmt) {
    TJSSqlite3Stmt *h;
    JSValue obj;

    obj = JS_NewObjectClass(ctx, tjs_sqlite3_stmt_class_id);
    if (JS_IsException(obj)) {
        return obj;
    }

    h = js_mallocz(ctx, sizeof(*h));
    if (!h) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }

    h->stmt = stmt;
    h->current_work = NULL;

    JS_SetOpaque(obj, h);
    return obj;
}

static TJSSqlite3Stmt *tjs_sqlite3_stmt_get(JSContext *ctx, JSValue obj) {
    return JS_GetOpaque2(ctx, obj, tjs_sqlite3_stmt_class_id);
}

static JSValue tjs_new_sqlite3_error(JSContext *ctx, int err, sqlite3 *db);

JSValue tjs_throw_sqlite3_errno(JSContext *ctx, int err, sqlite3 *db) {
    JSValue obj = tjs_new_sqlite3_error(ctx, err, db);
    if (JS_IsException(obj)) {
        obj = JS_NULL;
    }
    return JS_Throw(ctx, obj);
}

static JSValue tjs_sqlite3_open(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    const char *db_name = JS_ToCString(ctx, argv[0]);

    if (!db_name) {
        return JS_EXCEPTION;
    }

    int flags;
    if (JS_ToInt32(ctx, &flags, argv[1])) {
        JS_FreeCString(ctx, db_name);
        return JS_EXCEPTION;
    }

    sqlite3 *handle = NULL;
    int r = sqlite3_open_v2(db_name, &handle, flags, NULL);

    JS_FreeCString(ctx, db_name);

    sqlite3_extended_result_codes(handle, 1);

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, handle);
    }

    // Enable sqlite extensions (but only via C calls)
    r = sqlite3_db_config(handle, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1, NULL);
    if (r != SQLITE_OK) {
        JSValue ret = tjs_throw_sqlite3_errno(ctx, r, handle);
        sqlite3_close(handle);
        return ret;
    }

    JSValue obj = tjs_new_sqlite3(ctx, handle);
    if (JS_IsException(obj)) {
        sqlite3_close(handle);
    }

    return obj;
}

static JSValue tjs_sqlite3_close(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    int r = sqlite3_close(h->handle);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, h->handle);
    }

    h->handle = NULL;

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_load_extension(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    const char *zFile = JS_ToCString(ctx, argv[1]);
    const char *zProc = JS_IsUndefined(argv[2]) ? NULL : JS_ToCString(ctx, argv[2]);

    if (!zFile) {
        return JS_EXCEPTION;
    }

    // zProc can be 0, it means "sqlite, do your best to quess it"

    int r = sqlite3_load_extension(h->handle, zFile, zProc, NULL);

    JS_FreeCString(ctx, zFile);
    if (zProc) {
        JS_FreeCString(ctx, zProc);
    }

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, h->handle);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_exec(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    const char *sql = JS_ToCString(ctx, argv[1]);

    if (!sql) {
        return JS_EXCEPTION;
    }

    int r = sqlite3_exec(h->handle, sql, NULL, NULL, NULL);

    JS_FreeCString(ctx, sql);

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, h->handle);
    }

    return JS_UNDEFINED;
}
static JSValue tjs_new_sqlite3_error(JSContext *ctx, int err, sqlite3 *db) {
    if (err == SQLITE_INTERRUPT) {
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue ctor = JS_GetPropertyStr(ctx, global, "DOMException");
        JS_FreeValue(ctx, global);
        JSValue ex;
        if (JS_IsFunction(ctx, ctor)) {
            JSValue args[2] = { JS_NewString(ctx, "Aborted"), JS_NewString(ctx, "AbortError") };
            ex = JS_CallConstructor(ctx, ctor, 2, args);
            JS_FreeValue(ctx, args[0]);
            JS_FreeValue(ctx, args[1]);
            JS_FreeValue(ctx, ctor);
            if (JS_IsException(ex)) {
                ex = JS_NewError(ctx);
            }
        } else {
            if (!JS_IsUndefined(ctor)) JS_FreeValue(ctx, ctor);
            ex = JS_NewError(ctx);
            JS_DefinePropertyValueStr(ctx, ex, "name", JS_NewString(ctx, "AbortError"), JS_PROP_C_W_E);
            JS_DefinePropertyValueStr(ctx, ex, "message", JS_NewString(ctx, "Aborted"), JS_PROP_C_W_E);
        }
        return ex;
    }
    JSValue obj;
    char error_buffer[512];
    int extended_error_code = sqlite3_extended_errcode(db);
    if (extended_error_code != err) {
        snprintf(error_buffer, sizeof(error_buffer),
                 "SQLite error %d: %s (Extended code: %d)",
                 err, sqlite3_errmsg(db), extended_error_code);
    } else {
        snprintf(error_buffer, sizeof(error_buffer),
                 "SQLite error %d: %s",
                 err, sqlite3_errmsg(db));
    }
    obj = JS_NewError(ctx);
    JS_DefinePropertyValueStr(ctx, obj, "message", JS_NewString(ctx, error_buffer), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "errno", JS_NewInt32(ctx, err), JS_PROP_C_W_E);
    return obj;
}


typedef struct TJSAsyncSQLiteWork {
    uv_work_t req;
    JSContext *ctx;
    TJSPromise promise;
    sqlite3 *db;
    TJSSqlite3Handle *handleRef;
    char *sql;                 /* for exec */
    int result;
    char *errmsg;              /* from sqlite3_exec */
} TJSAsyncSQLiteWork;

/* async exec(sql) => Promise<void> */
static void tjs__work_exec(uv_work_t *req) {
    TJSAsyncSQLiteWork *w = (TJSAsyncSQLiteWork *) req->data;
    sqlite3 *db = w->db;
    w->result = sqlite3_exec(db, w->sql, NULL, NULL, &w->errmsg);
}

static void tjs__after_work(uv_work_t *req, int status) {
    TJSAsyncSQLiteWork *w = (TJSAsyncSQLiteWork *) req->data;
    JSContext *ctx = w->ctx;
    if (w->handleRef) {
        w->handleRef->in_flight = false;
    }
    /* clear in-flight flag */
    /* find handle from db to reset the flag: we can't easily map back; best-effort: nothing to do here */

    if (w->result == SQLITE_OK) {
        JSValue undef = JS_UNDEFINED;
        TJS_ResolvePromise(ctx, &w->promise, 1, (JSValue[]){ JS_DupValue(ctx, undef) });
    } else {
        JSValue err = tjs_new_sqlite3_error(ctx, w->result, w->db);
        TJS_RejectPromise(ctx, &w->promise, 1, (JSValue[]){ err });
    }

    if (w->sql) js_free(ctx, w->sql);
    if (w->errmsg) sqlite3_free(w->errmsg);
    js_free(ctx, w);
}

static JSValue tjs_sqlite3_exec_async(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);
    if (!h) return JS_EXCEPTION;

    const char *sql = JS_ToCString(ctx, argv[1]);
    if (!sql) return JS_EXCEPTION;

    TJSAsyncSQLiteWork *w = js_mallocz(ctx, sizeof(*w));
    if (!w) {
        JS_FreeCString(ctx, sql);
        return JS_EXCEPTION;
    }
    w->ctx = ctx;
    w->db = h->handle;
    w->handleRef = h;
    size_t len = strlen(sql);
    w->sql = js_malloc(ctx, len + 1);
    if (!w->sql) {
        js_free(ctx, w);
        JS_FreeCString(ctx, sql);
        return JS_EXCEPTION;
    }
    memcpy(w->sql, sql, len + 1);
    w->result = SQLITE_OK;
    w->errmsg = NULL;

    JSValue promise = TJS_InitPromise(ctx, &w->promise);
    if (JS_IsException(promise)) {
        js_free(ctx, w->sql);
        js_free(ctx, w);
        JS_FreeCString(ctx, sql);
        return JS_EXCEPTION;
    }
    w->req.data = w;

    h->in_flight = true;

    int r = uv_queue_work(tjs_get_loop(ctx), &w->req, tjs__work_exec, tjs__after_work);
    JS_FreeCString(ctx, sql);
    if (r != 0) {
        h->in_flight = false;
        JSValue err = JS_ThrowInternalError(ctx, "uv_queue_work failed: %d", r);
        TJS_RejectPromise(ctx, &w->promise, 1, (JSValue[]){ err });
        js_free(ctx, w->sql);
        js_free(ctx, w);
        return JS_EXCEPTION;
    }

    return promise;
}

static JSValue tjs_sqlite3_set_abort(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = JS_GetOpaque2(ctx, argv[0], tjs_sqlite3_class_id);
    if (h && h->handle) {
        if (h->in_flight) {
            sqlite3_interrupt(h->handle);
        }
        return JS_UNDEFINED;
    }
    return JS_UNDEFINED;
}

/* -------- async all(sql, params?) -------- */

typedef enum {
    TJS_COL_NULL = 0,
    TJS_COL_INT64,
    TJS_COL_FLOAT64,
    TJS_COL_TEXT,
    TJS_COL_BLOB,
} TJSColType;

typedef struct {
    TJSColType type;
    union {
        int64_t i64;
        double f64;
        struct { char *ptr; int len; } text;
        struct { uint8_t *ptr; int len; } blob;
    } as;
} TJSColValue;

typedef struct {
    int num_cols;
    TJSColValue *values; /* length: num_cols */
} TJSRow;

typedef struct {
    uv_work_t req;
    JSContext *ctx;
    TJSPromise promise;
    sqlite3 *db;
    TJSSqlite3Handle *handleRef;
    sqlite3_stmt *stmt;
    /* results */
    int num_cols;
    char **col_names; /* length: num_cols */
    int num_rows;
    int cap_rows;
    TJSRow *rows;
    int result;
} TJSAsyncAllWork;

static void tjs__free_all_result(JSContext *ctx, TJSAsyncAllWork *w) {
    if (w->rows) {
        for (int r = 0; r < w->num_rows; r++) {
            TJSRow *row = &w->rows[r];
            if (row->values) {
                for (int c = 0; c < row->num_cols; c++) {
                    TJSColValue *cv = &row->values[c];
                    if (cv->type == TJS_COL_TEXT && cv->as.text.ptr) {
                        js_free(ctx, cv->as.text.ptr);
                    } else if (cv->type == TJS_COL_BLOB && cv->as.blob.ptr) {
                        js_free(ctx, cv->as.blob.ptr);
                    }
                }
                js_free(ctx, row->values);
            }
        }
        js_free(ctx, w->rows);
    }
    if (w->col_names) {
        for (int i = 0; i < w->num_cols; i++) {
            if (w->col_names[i]) js_free(ctx, w->col_names[i]);
        }
        js_free(ctx, w->col_names);
    }
}

static void tjs__work_all(uv_work_t *req) {
    TJSAsyncAllWork *w = (TJSAsyncAllWork *) req->data;
    sqlite3_stmt *stmt = w->stmt;

    w->result = sqlite3_reset(stmt);
    if (w->result != SQLITE_OK) {
        return;
    }

    /* capture column info */
    w->num_cols = sqlite3_column_count(stmt);
    w->col_names = (char **) js_malloc(w->ctx, sizeof(char *) * (w->num_cols));
    if (!w->col_names) {
        w->result = SQLITE_NOMEM;
        return;
    }
    for (int i = 0; i < w->num_cols; i++) {
        const char *name = sqlite3_column_name(stmt, i);
        size_t nl = strlen(name);
        w->col_names[i] = (char *) js_malloc(w->ctx, nl + 1);
        if (!w->col_names[i]) { w->result = SQLITE_NOMEM; return; }
        memcpy(w->col_names[i], name, nl + 1);
    }

    /* step rows */
    w->rows = NULL;
    w->num_rows = 0;
    w->cap_rows = 0;

    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        if (w->num_rows == w->cap_rows) {
            int new_cap = w->cap_rows ? w->cap_rows * 2 : 16;
            TJSRow *nr = (TJSRow *) js_realloc(w->ctx, w->rows, sizeof(TJSRow) * new_cap);
            if (!nr) { w->result = SQLITE_NOMEM; return; }
            w->rows = nr;
            w->cap_rows = new_cap;
        }
        TJSRow *row = &w->rows[w->num_rows++];
        row->num_cols = w->num_cols;
        row->values = (TJSColValue *) js_malloc(w->ctx, sizeof(TJSColValue) * w->num_cols);
        if (!row->values) { w->result = SQLITE_NOMEM; return; }
        for (int c = 0; c < w->num_cols; c++) {
            int ct = sqlite3_column_type(stmt, c);
            TJSColValue *cv = &row->values[c];
            switch (ct) {
                case SQLITE_INTEGER: {
                    cv->type = TJS_COL_INT64;
                    cv->as.i64 = sqlite3_column_int64(stmt, c);
                    break;
                }
                case SQLITE_FLOAT: {
                    cv->type = TJS_COL_FLOAT64;
                    cv->as.f64 = sqlite3_column_double(stmt, c);
                    break;
                }
                case SQLITE_TEXT: {
                    const unsigned char *tp = sqlite3_column_text(stmt, c);
                    int tl = sqlite3_column_bytes(stmt, c);
                    cv->type = TJS_COL_TEXT;
                    cv->as.text.ptr = (char *) js_malloc(w->ctx, tl + 1);
                    if (!cv->as.text.ptr) { w->result = SQLITE_NOMEM; return; }
                    memcpy(cv->as.text.ptr, tp, tl);
                    cv->as.text.ptr[tl] = '\0';
                    cv->as.text.len = tl;
                    break;
                }
                case SQLITE_BLOB: {
                    const void *bp = sqlite3_column_blob(stmt, c);
                    int bl = sqlite3_column_bytes(stmt, c);
                    cv->type = TJS_COL_BLOB;
                    cv->as.blob.ptr = (uint8_t *) js_malloc(w->ctx, bl);
                    if (!cv->as.blob.ptr) { w->result = SQLITE_NOMEM; return; }
                    memcpy(cv->as.blob.ptr, bp, bl);
                    cv->as.blob.len = bl;
                    break;
                }
                default: {
                    cv->type = TJS_COL_NULL;
                    break;
                }
            }
        }
    }
    w->result = (rc == SQLITE_DONE) ? SQLITE_OK : rc;
}

static void tjs__after_all(uv_work_t *req, int status) {
    TJSAsyncAllWork *w = (TJSAsyncAllWork *) req->data;
    JSContext *ctx = w->ctx;
    if (w->handleRef) {
        w->handleRef->in_flight = false;
    }

    /* finalize statement */
    if (w->stmt) {
        sqlite3_finalize(w->stmt);
        w->stmt = NULL;
    }

    if (w->result == SQLITE_OK) {
        JSValue arr = JS_NewArray(ctx);
        for (int r = 0; r < w->num_rows; r++) {
            JSValue obj = JS_NewObjectProto(ctx, JS_NULL);
            TJSRow *row = &w->rows[r];
            for (int c = 0; c < w->num_cols; c++) {
                TJSColValue *cv = &row->values[c];
                JSValue v;
                switch (cv->type) {
                    case TJS_COL_INT64: {
                        int64_t val = cv->as.i64;
                        if (val > 9007199254740991LL || val < -9007199254740991LL) v = JS_NewBigInt64(ctx, val);
                        else v = JS_NewInt64(ctx, val);
                        break;
                    }
                    case TJS_COL_FLOAT64: v = JS_NewFloat64(ctx, cv->as.f64); break;
                    case TJS_COL_TEXT: v = JS_NewStringLen(ctx, cv->as.text.ptr, cv->as.text.len); break;
                    case TJS_COL_BLOB: v = JS_NewUint8ArrayCopy(ctx, cv->as.blob.ptr, cv->as.blob.len); break;
                    default: v = JS_NULL; break;
                }
                JS_DefinePropertyValueStr(ctx, obj, w->col_names[c], v, JS_PROP_C_W_E);
            }
            JS_DefinePropertyValueUint32(ctx, arr, (uint32_t) r, obj, JS_PROP_C_W_E);
        }
        TJS_ResolvePromise(ctx, &w->promise, 1, (JSValue[]){ arr });
    } else {
        JSValue err = tjs_new_sqlite3_error(ctx, w->result, w->db);
        TJS_RejectPromise(ctx, &w->promise, 1, (JSValue[]){ err });
    }

    tjs__free_all_result(ctx, w);
    js_free(ctx, w);
}

static JSValue tjs__sqlite3_bind_params(JSContext *ctx, sqlite3_stmt *stmt, JSValue params);

static JSValue tjs_sqlite3_all_async(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);
    if (!h) return JS_EXCEPTION;

    const char *sql = JS_ToCString(ctx, argv[1]);
    if (!sql) return JS_EXCEPTION;

    sqlite3_stmt *stmt = NULL;
    int r = sqlite3_prepare_v2(h->handle, sql, -1, &stmt, NULL);
    JS_FreeCString(ctx, sql);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, h->handle);
    }

    /* bind params if given */
    if (argc >= 3 && !JS_IsUndefined(argv[2])) {
        if (JS_IsException(tjs__sqlite3_bind_params(ctx, stmt, argv[2]))) {
            sqlite3_finalize(stmt);
            return JS_EXCEPTION;
        }
    }

    TJSAsyncAllWork *w = js_mallocz(ctx, sizeof(*w));
    if (!w) {
        sqlite3_finalize(stmt);
        return JS_EXCEPTION;
    }
    w->ctx = ctx;
    w->db = h->handle;
    w->handleRef = h;
    w->stmt = stmt;
    w->rows = NULL;
    w->num_rows = 0;
    w->cap_rows = 0;
    w->col_names = NULL;
    w->num_cols = 0;
    w->result = SQLITE_OK;

    JSValue promise = TJS_InitPromise(ctx, &w->promise);
    if (JS_IsException(promise)) {
        sqlite3_finalize(stmt);
        js_free(ctx, w);
        return JS_EXCEPTION;
    }
    w->req.data = w;

    h->in_flight = true;
    int q = uv_queue_work(tjs_get_loop(ctx), &w->req, tjs__work_all, tjs__after_all);
    if (q != 0) {
        JSValue err = JS_ThrowInternalError(ctx, "uv_queue_work failed: %d", q);
        TJS_RejectPromise(ctx, &w->promise, 1, (JSValue[]){ err });
        sqlite3_finalize(stmt);
        js_free(ctx, w);
        return JS_EXCEPTION;
    }

    return promise;
}

static JSValue tjs_sqlite3_prepare(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    const char *sql = JS_ToCString(ctx, argv[1]);

    if (!sql) {
        return JS_EXCEPTION;
    }

    sqlite3_stmt *stmt = NULL;
    int r = sqlite3_prepare_v2(h->handle, sql, -1, &stmt, NULL);

    JS_FreeCString(ctx, sql);

    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, h->handle);
    }

    JSValue obj = tjs_new_sqlite3_stmt(ctx, stmt);
    if (JS_IsException(obj)) {
        sqlite3_finalize(stmt);
    }

    return obj;
}

static JSValue tjs_sqlite3_in_transaction(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Handle *h = tjs_sqlite3_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    return JS_NewBool(ctx, !sqlite3_get_autocommit(h->handle));
}

static JSValue tjs_sqlite3_stmt_finalize(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_UNDEFINED;
    }

    sqlite3_reset(h->stmt);

    int r = sqlite3_finalize(h->stmt);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, sqlite3_db_handle(h->stmt));
    }

    h->stmt = NULL;

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_stmt_expand(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_NewString(ctx, "");
    }

    char *sql = sqlite3_expanded_sql(h->stmt);
    if (sql == NULL) {
        return JS_ThrowOutOfMemory(ctx);
    }

    return JS_NewString(ctx, sql);
}

static JSValue tjs__stmt2obj(JSContext *ctx, TJSSqlite3Stmt *h) {
    JSValue obj = JS_NewObjectProto(ctx, JS_NULL);
    int count = sqlite3_column_count(h->stmt);

    for (int i = 0; i < count; i++) {
        const char *name = sqlite3_column_name(h->stmt, i);
        JSValue value;

        switch (sqlite3_column_type(h->stmt, i)) {
            case SQLITE_INTEGER: {
                int64_t val = sqlite3_column_int64(h->stmt, i);
                if (val > 9007199254740991 || val < -9007199254740991) {
                    value = JS_NewBigInt64(ctx, val);
                } else {
                    value = JS_NewInt64(ctx, val);
                }
                break;
            }
            case SQLITE_FLOAT: {
                value = JS_NewFloat64(ctx, sqlite3_column_double(h->stmt, i));
                break;
            }
            case SQLITE3_TEXT: {
                value = JS_NewString(ctx, (const char *) sqlite3_column_text(h->stmt, i));
                break;
            }
            case SQLITE_BLOB: {
                value = JS_NewUint8ArrayCopy(ctx,
                                             (uint8_t *) sqlite3_column_blob(h->stmt, i),
                                             sqlite3_column_bytes(h->stmt, i));
                break;
            }
            default: {
                value = JS_NULL;
                break;
            }
        }

        JS_DefinePropertyValueStr(ctx, obj, name, value, JS_PROP_C_W_E);
    }

    return obj;
}

static JSValue tjs__sqlite3_bind_param(JSContext *ctx, sqlite3_stmt *stmt, int idx, JSValue v) {
    int r;

#define CHECK_VALUE(ret, i)                                                                                            \
    if (ret == -1) {                                                                                                   \
        return JS_ThrowTypeError(ctx, "Failed to convert type at position %d", idx);                                   \
    }

#define CHECK_RET(ret)                                                                                                 \
    if (r != SQLITE_OK) {                                                                                              \
        return tjs_throw_sqlite3_errno(ctx, ret, sqlite3_db_handle(stmt));                                                                      \
    }

    switch (JS_VALUE_GET_NORM_TAG(v)) {
        case JS_TAG_BIG_INT: {
            int64_t x;
            r = JS_ToBigInt64(ctx, &x, v);
            CHECK_VALUE(r, idx);
            r = sqlite3_bind_int64(stmt, idx, x);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_STRING: {
            size_t len;
            const char *x = JS_ToCStringLen(ctx, &len, v);
            if (!x) {
                return JS_EXCEPTION;
            }
            r = sqlite3_bind_text(stmt, idx, x, len, SQLITE_TRANSIENT);
            JS_FreeCString(ctx, x);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_OBJECT: {
            size_t len = 0;
            const uint8_t *x = JS_GetUint8Array(ctx, &len, v);
            if (!x) {
                return JS_EXCEPTION;
            }
            r = sqlite3_bind_blob(stmt, idx, x, len, SQLITE_TRANSIENT);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_INT: {
            int64_t x;
            r = JS_ToInt64(ctx, &x, v);
            CHECK_VALUE(r, idx);
            if (x < INT_MIN || x > INT_MAX) {
                r = sqlite3_bind_int64(stmt, idx, x);
            } else {
                r = sqlite3_bind_int(stmt, idx, x);
            }
            CHECK_RET(r);
            break;
        }
        case JS_TAG_BOOL: {
            r = JS_ToBool(ctx, v);
            CHECK_VALUE(r, idx);
            r = sqlite3_bind_int(stmt, idx, r);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_NULL: {
            r = sqlite3_bind_null(stmt, idx);
            CHECK_RET(r);
            break;
        }
        case JS_TAG_FLOAT64: {
            double x;
            r = JS_ToFloat64(ctx, &x, v);
            CHECK_VALUE(r, idx);
            r = sqlite3_bind_double(stmt, idx, x);
            CHECK_RET(r);
            break;
        }
        default:
            return JS_ThrowTypeError(ctx, "Invalid bound parameter type at position %d", idx);
    }

    return JS_UNDEFINED;

#undef CHECK_VALUE
#undef CHECK_RET
}

static JSValue tjs__sqlite3_bind_params(JSContext *ctx, sqlite3_stmt *stmt, JSValue params) {
    sqlite3_clear_bindings(stmt);

    if (JS_IsArray(params)) {
        JSValue js_length = JS_GetPropertyStr(ctx, params, "length");
        uint64_t len;
        if (JS_ToIndex(ctx, &len, js_length)) {
            JS_FreeValue(ctx, js_length);
            return JS_EXCEPTION;
        }
        JS_FreeValue(ctx, js_length);
        for (int i = 0; i < len; i++) {
            JSValue v = JS_GetPropertyUint32(ctx, params, i);
            if (JS_IsException(v)) {
                return v;
            }
            bool is_exception = JS_IsException(tjs__sqlite3_bind_param(ctx, stmt, i + 1, v));
            JS_FreeValue(ctx, v);
            if (is_exception) {
                return JS_EXCEPTION;
            }
        }
    } else if (JS_IsObject(params)) {
        JSPropertyEnum *ptab;
        uint32_t plen;
        if (JS_GetOwnPropertyNames(ctx, &ptab, &plen, params, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)) {
            return JS_EXCEPTION;
        }
        for (int i = 0; i < plen; i++) {
            JSAtom patom = ptab[i].atom;
            JSValue prop = JS_GetProperty(ctx, params, patom);
            if (JS_IsException(prop)) {
                JS_FreePropertyEnum(ctx, ptab, plen);
                return JS_EXCEPTION;
            }
            const char *key = JS_AtomToCString(ctx, patom);
            int idx = sqlite3_bind_parameter_index(stmt, key);
            if (idx == 0 || JS_IsException(tjs__sqlite3_bind_param(ctx, stmt, idx, prop))) {
                if (idx == 0) {
                    JS_ThrowReferenceError(ctx, "Could not find parameter '%s'", key);
                }
                JS_FreeValue(ctx, prop);
                JS_FreeCString(ctx, key);
                JS_FreePropertyEnum(ctx, ptab, plen);
                return JS_EXCEPTION;
            }
            JS_FreeValue(ctx, prop);
            JS_FreeCString(ctx, key);
        }
        JS_FreePropertyEnum(ctx, ptab, plen);
    } else {
        return JS_ThrowTypeError(ctx, "Invalid bind parameters type: expected object or array");
    }

    return JS_UNDEFINED;
}

static JSValue tjs_sqlite3_stmt_all(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_ThrowInternalError(ctx, "Statement has been finalized");
    }

    int r = sqlite3_reset(h->stmt);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, sqlite3_db_handle(h->stmt));
    }

    if (argc == 2) {
        JSValue params = argv[1];

        if (JS_IsException(tjs__sqlite3_bind_params(ctx, h->stmt, params))) {
            return JS_EXCEPTION;
        }
    }

    JSValue result = JS_NewArray(ctx);
    uint32_t i = 0;

    while ((r = sqlite3_step(h->stmt)) == SQLITE_ROW) {
        JS_DefinePropertyValueUint32(ctx, result, i, tjs__stmt2obj(ctx, h), JS_PROP_C_W_E);
        i++;
    }

    if (r != SQLITE_OK && r != SQLITE_DONE) {
        JS_FreeValue(ctx, result);
        return tjs_throw_sqlite3_errno(ctx, r, sqlite3_db_handle(h->stmt));
    }

    return result;
}

static JSValue tjs_sqlite3_stmt_run(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    TJSSqlite3Stmt *h = tjs_sqlite3_stmt_get(ctx, argv[0]);

    if (!h) {
        return JS_EXCEPTION;
    }

    if (!h->stmt) {
        return JS_ThrowInternalError(ctx, "Statement has been finalized");
    }

    int r = sqlite3_reset(h->stmt);
    if (r != SQLITE_OK) {
        return tjs_throw_sqlite3_errno(ctx, r, sqlite3_db_handle(h->stmt));
    }

    if (argc == 2) {
        JSValue params = argv[1];

        if (JS_IsException(tjs__sqlite3_bind_params(ctx, h->stmt, params))) {
            return JS_EXCEPTION;
        }
    }

    r = sqlite3_step(h->stmt);
    if (r != SQLITE_OK && r != SQLITE_DONE && r != SQLITE_ROW) {
        return tjs_throw_sqlite3_errno(ctx, r, sqlite3_db_handle(h->stmt));
    }

    return JS_UNDEFINED;
}

static const JSCFunctionListEntry tjs_sqlite3_funcs[] = {
    TJS_CFUNC_DEF("open", 2, tjs_sqlite3_open),
    TJS_CFUNC_DEF("load_extension", 3, tjs_sqlite3_load_extension),
    TJS_CFUNC_DEF("close", 1, tjs_sqlite3_close),
    TJS_CFUNC_DEF("exec", 2, tjs_sqlite3_exec),
    TJS_CFUNC_DEF("exec_async", 2, tjs_sqlite3_exec_async),
    TJS_CFUNC_DEF("set_abort", 1, tjs_sqlite3_set_abort),
    TJS_CFUNC_DEF("all_async", 3, tjs_sqlite3_all_async),
    TJS_CFUNC_DEF("prepare", 2, tjs_sqlite3_prepare),
    TJS_CFUNC_DEF("in_transaction", 1, tjs_sqlite3_in_transaction),
    TJS_CFUNC_DEF("stmt_finalize", 1, tjs_sqlite3_stmt_finalize),
    TJS_CFUNC_DEF("stmt_expand", 1, tjs_sqlite3_stmt_expand),
    TJS_CFUNC_DEF("stmt_all", 2, tjs_sqlite3_stmt_all),
    TJS_CFUNC_DEF("stmt_run", 2, tjs_sqlite3_stmt_run),
    TJS_CONST(SQLITE_OPEN_CREATE),
    TJS_CONST(SQLITE_OPEN_READONLY),
    TJS_CONST(SQLITE_OPEN_READWRITE),
};

void tjs__mod_sqlite3_init(JSContext *ctx, JSValue ns) {
    JSRuntime *rt = JS_GetRuntime(ctx);

    /* Handle object */
    JS_NewClassID(rt, &tjs_sqlite3_class_id);
    JS_NewClass(rt, tjs_sqlite3_class_id, &tjs_sqlite3_class);
    JS_SetClassProto(ctx, tjs_sqlite3_class_id, JS_NULL);

    /* Statement object */
    JS_NewClassID(rt, &tjs_sqlite3_stmt_class_id);
    JS_NewClass(rt, tjs_sqlite3_stmt_class_id, &tjs_sqlite3_stmt_class);
    JS_SetClassProto(ctx, tjs_sqlite3_stmt_class_id, JS_NULL);

    JSValue obj = JS_NewObjectProto(ctx, JS_NULL);
    JS_SetPropertyFunctionList(ctx, obj, tjs_sqlite3_funcs, countof(tjs_sqlite3_funcs));

    JS_DefinePropertyValueStr(ctx, ns, "sqlite3", obj, JS_PROP_C_W_E);
}
#endif