/*
 * txiki.js
 *
 * Copyright (c) 2022-present Saúl Ibarra Corretgé <s@saghul.net>
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

#include "private.h"
#include "utils.h"
#ifdef TJS__HAS_WASM
#include "wasm.h"
#endif

// #include <curl/curl.h>
#include <string.h>
#if defined(_MSC_VER)
// It should be safe to define these as 0,1,2 even when compiling with msvc:
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#else
#include <unistd.h>
#endif


static JSValue tjs_exit(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    int status;
    if (JS_ToInt32(ctx, &status, argv[0])) {
        status = -1;
    }
    /* Reset TTY state (if it had changed) before exiting. */
    uv_tty_reset_mode();
    exit(status);
    return JS_UNDEFINED;
}

static JSValue tjs_uname(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    JSValue obj;
    int r;
    uv_utsname_t utsname;

    r = uv_os_uname(&utsname);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    obj = JS_NewObjectProto(ctx, JS_NULL);
    JS_DefinePropertyValueStr(ctx, obj, "sysname", JS_NewString(ctx, utsname.sysname), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "release", JS_NewString(ctx, utsname.release), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "version", JS_NewString(ctx, utsname.version), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "machine", JS_NewString(ctx, utsname.machine), JS_PROP_C_W_E);

    return obj;
}

static JSValue tjs_uptime(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    double upt;
    uv_uptime(&upt);
    return JS_NewFloat64(ctx, upt);
}

static JSValue tjs_guess_handle(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    int fd;
    if (JS_ToInt32(ctx, &fd, argv[0])) {
        return JS_EXCEPTION;
    }

    switch (uv_guess_handle(fd)) {
        case UV_TTY:
            return JS_NewString(ctx, "tty");
        case UV_NAMED_PIPE:
            return JS_NewString(ctx, "pipe");
        case UV_FILE:
            return JS_NewString(ctx, "file");
        case UV_TCP:
            return JS_NewString(ctx, "tcp");
        case UV_UDP:
            return JS_NewString(ctx, "udp");
        default:
            return JS_NewString(ctx, "unknown");
    }
}

static JSValue tjs_environ(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    uv_env_item_t *env;
    int envcount, r;

    r = uv_os_environ(&env, &envcount);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    JSValue obj = JS_NewObjectProto(ctx, JS_NULL);

    for (int i = 0; i < envcount; i++) {
        JS_DefinePropertyValueStr(ctx, obj, env[i].name, JS_NewString(ctx, env[i].value), JS_PROP_C_W_E);
    }

    uv_os_free_environ(env, envcount);

    return obj;
}

static JSValue tjs_envKeys(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    uv_env_item_t *env;
    int envcount, r;

    r = uv_os_environ(&env, &envcount);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    JSValue obj = JS_NewArray(ctx);

    for (int i = 0; i < envcount; i++) {
        JS_SetPropertyUint32(ctx, obj, i, JS_NewString(ctx, env[i].name));
    }

    uv_os_free_environ(env, envcount);

    return obj;
}

static JSValue tjs_getenv(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    if (!JS_IsString(argv[0])) {
        return JS_ThrowTypeError(ctx, "expected a string");
    }

    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) {
        return JS_EXCEPTION;
    }

    char buf[1024];
    size_t size = sizeof(buf);
    char *dbuf = buf;
    int r;

    r = uv_os_getenv(name, dbuf, &size);
    if (r != 0) {
        if (r != UV_ENOBUFS) {
            JS_FreeCString(ctx, name);
            return tjs_throw_errno(ctx, r);
        }
        dbuf = js_malloc(ctx, size);
        if (!dbuf) {
            JS_FreeCString(ctx, name);
            return JS_EXCEPTION;
        }
        r = uv_os_getenv(name, dbuf, &size);
        if (r != 0) {
            JS_FreeCString(ctx, name);
            js_free(ctx, dbuf);
            return tjs_throw_errno(ctx, r);
        }
    }

    JS_FreeCString(ctx, name);
    JSValue ret = JS_NewStringLen(ctx, dbuf, size);

    if (dbuf != buf) {
        js_free(ctx, dbuf);
    }

    return ret;
}

static JSValue tjs_setenv(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    if (!JS_IsString(argv[0])) {
        return JS_ThrowTypeError(ctx, "expected a string");
    }
    if (JS_IsUndefined(argv[1])) {
        return JS_ThrowTypeError(ctx, "expected a value");
    }

    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) {
        return JS_EXCEPTION;
    }

    const char *value = JS_ToCString(ctx, argv[1]);
    if (!value) {
        return JS_EXCEPTION;
    }

    int r = uv_os_setenv(name, value);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, value);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_unsetenv(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    if (!JS_IsString(argv[0])) {
        return JS_ThrowTypeError(ctx, "expected a string");
    }

    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) {
        return JS_EXCEPTION;
    }

    int r = uv_os_unsetenv(name);
    JS_FreeCString(ctx, name);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_chdir(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    if (!JS_IsString(argv[0])) {
        return JS_ThrowTypeError(ctx, "expected a string");
    }

    const char *dir = JS_ToCString(ctx, argv[0]);
    if (!dir) {
        return JS_EXCEPTION;
    }

    int r = uv_chdir(dir);
    JS_FreeCString(ctx, dir);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_cwd(JSContext *ctx, JSValue this_val) {
    char buf[1024];
    size_t size = sizeof(buf);
    char *dbuf = buf;
    int r;

    r = uv_cwd(dbuf, &size);
    if (r != 0) {
        if (r != UV_ENOBUFS) {
            return tjs_throw_errno(ctx, r);
        }
        dbuf = js_malloc(ctx, size);
        if (!dbuf) {
            return JS_EXCEPTION;
        }
        r = uv_cwd(dbuf, &size);
        if (r != 0) {
            js_free(ctx, dbuf);
            return tjs_throw_errno(ctx, r);
        }
    }

    JSValue ret = JS_NewStringLen(ctx, dbuf, size);

    if (dbuf != buf) {
        js_free(ctx, dbuf);
    }

    return ret;
}

static JSValue tjs_homedir(JSContext *ctx, JSValue this_val) {
    char buf[1024];
    size_t size = sizeof(buf);
    char *dbuf = buf;
    int r;

    r = uv_os_homedir(dbuf, &size);
    if (r != 0) {
        if (r != UV_ENOBUFS) {
            return tjs_throw_errno(ctx, r);
        }
        dbuf = js_malloc(ctx, size);
        if (!dbuf) {
            return JS_EXCEPTION;
        }
        r = uv_os_homedir(dbuf, &size);
        if (r != 0) {
            js_free(ctx, dbuf);
            return tjs_throw_errno(ctx, r);
        }
    }

    JSValue ret = JS_NewStringLen(ctx, dbuf, size);

    if (dbuf != buf) {
        js_free(ctx, dbuf);
    }

    return ret;
}

static JSValue tjs_tmpdir(JSContext *ctx, JSValue this_val) {
    char buf[1024];
    size_t size = sizeof(buf);
    char *dbuf = buf;
    int r;

    r = uv_os_tmpdir(dbuf, &size);
    if (r != 0) {
        if (r != UV_ENOBUFS) {
            return tjs_throw_errno(ctx, r);
        }
        dbuf = js_malloc(ctx, size);
        if (!dbuf) {
            return JS_EXCEPTION;
        }
        r = uv_os_tmpdir(dbuf, &size);
        if (r != 0) {
            js_free(ctx, dbuf);
            return tjs_throw_errno(ctx, r);
        }
    }

    JSValue ret = JS_NewStringLen(ctx, dbuf, size);

    if (dbuf != buf) {
        js_free(ctx, dbuf);
    }

    return ret;
}

static JSValue tjs_random(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    size_t size;
    uint8_t *buf = JS_GetArrayBuffer(ctx, &size, argv[0]);
    if (!buf) {
        return JS_EXCEPTION;
    }

    uint64_t off = 0;
    if (!JS_IsUndefined(argv[1]) && JS_ToIndex(ctx, &off, argv[1])) {
        return JS_EXCEPTION;
    }

    uint64_t len = size;
    if (!JS_IsUndefined(argv[2]) && JS_ToIndex(ctx, &len, argv[2])) {
        return JS_EXCEPTION;
    }

    if (off + len > size) {
        return JS_ThrowRangeError(ctx, "array buffer overflow");
    }

    int r = uv_random(NULL, NULL, buf + off, len, 0, NULL);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    return JS_UNDEFINED;
}

static JSValue tjs_cpu_info(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    uv_cpu_info_t *infos;
    int count;
    int r = uv_cpu_info(&infos, &count);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    JSValue val = JS_NewArray(ctx);

    for (int i = 0; i < count; i++) {
        uv_cpu_info_t info = infos[i];

        JSValue v = JS_NewObjectProto(ctx, JS_NULL);

        JS_DefinePropertyValueStr(ctx, v, "model", JS_NewString(ctx, info.model), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, v, "speed", JS_NewInt64(ctx, info.speed), JS_PROP_C_W_E);

        JSValue t = JS_NewObjectProto(ctx, JS_NULL);
        JS_DefinePropertyValueStr(ctx, t, "user", JS_NewFloat64(ctx, info.cpu_times.user), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, t, "nice", JS_NewFloat64(ctx, info.cpu_times.nice), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, t, "sys", JS_NewFloat64(ctx, info.cpu_times.sys), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, t, "idle", JS_NewFloat64(ctx, info.cpu_times.idle), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, t, "irq", JS_NewFloat64(ctx, info.cpu_times.irq), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, v, "times", t, JS_PROP_C_W_E);

        JS_SetPropertyUint32(ctx, val, i, v);
    }

    uv_free_cpu_info(infos, count);

    return val;
}

static JSValue tjs_loadavg(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    double avg[3] = { -1, -1, -1 };

    uv_loadavg(avg);

    JSValue val = JS_NewArray(ctx);

    JS_SetPropertyUint32(ctx, val, 0, JS_NewFloat64(ctx, avg[0]));
    JS_SetPropertyUint32(ctx, val, 1, JS_NewFloat64(ctx, avg[1]));
    JS_SetPropertyUint32(ctx, val, 2, JS_NewFloat64(ctx, avg[2]));

    return val;
}

static JSValue tjs_network_interfaces(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    uv_interface_address_t *interfaces;
    int count;
    int r = uv_interface_addresses(&interfaces, &count);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    JSValue val = JS_NewArray(ctx);

    for (int i = 0; i < count; i++) {
        uv_interface_address_t iface = interfaces[i];
        char mac[18];
        char buf[INET6_ADDRSTRLEN + 1];

        JSValue addr = JS_NewObjectProto(ctx, JS_NULL);

        JS_DefinePropertyValueStr(ctx, addr, "name", JS_NewString(ctx, iface.name), JS_PROP_C_W_E);

        snprintf(mac,
                 sizeof(mac),
                 "%02x:%02x:%02x:%02x:%02x:%02x",
                 (unsigned char) iface.phys_addr[0],
                 (unsigned char) iface.phys_addr[1],
                 (unsigned char) iface.phys_addr[2],
                 (unsigned char) iface.phys_addr[3],
                 (unsigned char) iface.phys_addr[4],
                 (unsigned char) iface.phys_addr[5]);
        JS_DefinePropertyValueStr(ctx, addr, "mac", JS_NewString(ctx, mac), JS_PROP_C_W_E);

        if (iface.address.address4.sin_family == AF_INET) {
            uv_ip4_name(&iface.address.address4, buf, sizeof(buf));
        } else if (iface.address.address4.sin_family == AF_INET6) {
            uv_ip6_name(&iface.address.address6, buf, sizeof(buf));
            JS_DefinePropertyValueStr(ctx,
                                      addr,
                                      "scopeId",
                                      JS_NewUint32(ctx, iface.address.address6.sin6_scope_id),
                                      JS_PROP_C_W_E);
        }
        JS_DefinePropertyValueStr(ctx, addr, "address", JS_NewString(ctx, buf), JS_PROP_C_W_E);

        if (iface.netmask.netmask4.sin_family == AF_INET) {
            uv_ip4_name(&iface.netmask.netmask4, buf, sizeof(buf));
        } else if (iface.netmask.netmask4.sin_family == AF_INET6) {
            uv_ip6_name(&iface.netmask.netmask6, buf, sizeof(buf));
        }
        JS_DefinePropertyValueStr(ctx, addr, "netmask", JS_NewString(ctx, buf), JS_PROP_C_W_E);

        JS_DefinePropertyValueStr(ctx, addr, "internal", JS_NewBool(ctx, iface.is_internal), JS_PROP_C_W_E);

        JS_SetPropertyUint32(ctx, val, i, addr);
    }

    uv_free_interface_addresses(interfaces, count);

    return val;
}

static JSValue tjs_gethostname(JSContext *ctx, JSValue this_val) {
    char buf[UV_MAXHOSTNAMESIZE];
    size_t size = sizeof(buf);

    int r = uv_os_gethostname(buf, &size);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    return JS_NewStringLen(ctx, buf, size);
}

static JSValue tjs_getpid(JSContext *ctx, JSValue this_val) {
    return JS_NewInt32(ctx, uv_os_getpid());
}

static JSValue tjs_getppid(JSContext *ctx, JSValue this_val) {
    return JS_NewInt32(ctx, uv_os_getppid());
}

static JSValue tjs_userInfo(JSContext *ctx, JSValue this_val) {
    uv_passwd_t p;

    int r = uv_os_get_passwd(&p);
    if (r != 0) {
        return tjs_throw_errno(ctx, r);
    }

    JSValue obj = JS_NewObjectProto(ctx, JS_NULL);
    JS_DefinePropertyValueStr(ctx, obj, "userName", JS_NewString(ctx, p.username), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "userId", JS_NewInt32(ctx, p.uid), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "groupId", JS_NewInt32(ctx, p.gid), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "shell", p.shell ? JS_NewString(ctx, p.shell) : JS_NULL, JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, obj, "homeDir", p.homedir ? JS_NewString(ctx, p.homedir) : JS_NULL, JS_PROP_C_W_E);

    uv_os_free_passwd(&p);

    return obj;
}

static JSValue tjs_availableParallelism(JSContext *ctx, JSValue this_val, int argc, JSValue *argv) {
    return JS_NewUint32(ctx, uv_available_parallelism());
}

static const JSCFunctionListEntry tjs_os_funcs[] = {
    TJS_CONST(AF_INET),
    TJS_CONST(AF_INET6),
    TJS_CONST(AF_UNSPEC),
    TJS_CONST(STDIN_FILENO),
    TJS_CONST(STDOUT_FILENO),
    TJS_CONST(STDERR_FILENO),
    TJS_CFUNC_DEF("exit", 1, tjs_exit),
    TJS_CFUNC_DEF("uname", 0, tjs_uname),
    TJS_CFUNC_DEF("uptime", 0, tjs_uptime),
    TJS_CFUNC_DEF("guessHandle", 1, tjs_guess_handle),
    TJS_CFUNC_DEF("getenv", 0, tjs_getenv),
    TJS_CFUNC_DEF("setenv", 2, tjs_setenv),
    TJS_CFUNC_DEF("unsetenv", 1, tjs_unsetenv),
    TJS_CFUNC_DEF("envKeys", 0, tjs_envKeys),
    TJS_CFUNC_DEF("environ", 0, tjs_environ),
    TJS_CFUNC_DEF("chdir", 1, tjs_chdir),
    TJS_CFUNC_DEF("random", 3, tjs_random),
    TJS_CFUNC_DEF("cpuInfo", 0, tjs_cpu_info),
    TJS_CFUNC_DEF("loadavg", 0, tjs_loadavg),
    TJS_CFUNC_DEF("networkInterfaces", 0, tjs_network_interfaces),
    TJS_CFUNC_DEF("availableParallelism", 0, tjs_availableParallelism),
    TJS_CGETSET_DEF("cwd", tjs_cwd, NULL),
    TJS_CGETSET_DEF("homeDir", tjs_homedir, NULL),
    TJS_CGETSET_DEF("hostName", tjs_gethostname, NULL),
    TJS_CGETSET_DEF("pid", tjs_getpid, NULL),
    TJS_CGETSET_DEF("ppid", tjs_getppid, NULL),
    TJS_CGETSET_DEF("tmpDir", tjs_tmpdir, NULL),
    TJS_CGETSET_DEF("userInfo", tjs_userInfo, NULL),
};

void tjs__mod_os_init(JSContext *ctx, JSValue ns) {
    JS_SetPropertyFunctionList(ctx, ns, tjs_os_funcs, countof(tjs_os_funcs));
}
