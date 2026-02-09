#ifndef MY_ZIG_LIB_H
#define MY_ZIG_LIB_H

#include <quickjs.h>

#ifdef TJS__OMIT_ZIG_MODULES
static inline void zig__mod_v8_compat_init(JSContext *ctx, JSValue ns) {}
static inline void zig__mod_sqlite3_async_init(JSContext *ctx, JSValue ns) {}
#else
void zig__mod_v8_compat_init(JSContext *ctx, JSValue ns);
void zig__mod_sqlite3_async_init(JSContext *ctx, JSValue ns);
#endif

#endif // MY_ZIG_LIB_H
