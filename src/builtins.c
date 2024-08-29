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

#include "bundles/c/stdlib/assert.c"
// #include "bundles/c/stdlib/ffi.c"
#include "bundles/c/stdlib/getopts.c"
#include "bundles/c/stdlib/hashing.c"
#include "bundles/c/stdlib/ipaddr.c"
#include "bundles/c/stdlib/path.c"
#include "bundles/c/stdlib/posix-socket.c"
#ifdef TJS__HAS_SQLITE
#include "bundles/c/stdlib/sqlite.c"
#endif
#include "bundles/c/stdlib/uuid.c"
#include "private.h"


typedef struct {
    const char *name;
    const uint8_t *data;
    uint32_t data_size;
} tjs_builtin_t;

static tjs_builtin_t builtins[] = {
    { "tjs:assert", tjs__assert, tjs__assert_size_enum },
    // { "tjs:ffi", tjs__ffi, tjs__ffi_size },
    { "tjs:getopts", tjs__getopts, tjs__getopts_size_enum },
    { "tjs:hashing", tjs__hashing, tjs__hashing_size_enum },
    { "tjs:ipaddr", tjs__ipaddr, tjs__ipaddr_size_enum },
    { "tjs:path", tjs__path, tjs__path_size_enum },
    { "tjs:posix-socket", tjs__posix_socket, tjs__posix_socket_size_enum },
#ifdef TJS__HAS_SQLITE
    { "tjs:sqlite", tjs__sqlite, tjs__sqlite_size_enum },
#endif
    { "tjs:uuid", tjs__uuid, tjs__uuid_size_enum },
    { NULL, NULL, 0 },
};

JSModuleDef *tjs__load_builtin(JSContext *ctx, const char *name) {
    tjs_builtin_t *item = NULL;

    for (tjs_builtin_t *p = builtins; p->name != NULL; ++p) {
        if (strncmp(p->name, name, strlen(p->name)) == 0) {
            item = p;
            break;
        }
    }

    if (item == NULL) {
        return NULL;
    }

    JSValue obj = JS_ReadObject(ctx, item->data, item->data_size, JS_READ_OBJ_BYTECODE);

    CHECK_EQ(JS_IsException(obj), 0);
    CHECK_EQ(JS_VALUE_GET_TAG(obj), JS_TAG_MODULE);

    JSModuleDef *m = JS_VALUE_GET_PTR(obj);
    JS_FreeValue(ctx, obj);

    return m;
}
