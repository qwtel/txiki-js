/// Initialized
const std = @import("std");
const builtin = @import("builtin");

pub const z = @import("v8-qjs-compat.zig");
pub const c = z.c;

const QuickJSAllocator = @import("v8-qjs-allocator.zig").QJSAllocator;

fn freeFunc(rt: ?*c.JSRuntime, _: ?*anyopaque, ptr: ?*anyopaque) callconv(.C) void {
    c.js_free_rt(rt, ptr);
}

/// Matches Node's behavior of calling `_writeHostObject` / `_readHostObject` in JS userland when encountering typed arrays.
const NodeDelegate = struct {
    this_obj: c.JSValue,

    const Self = @This();

    pub fn writeHostObject(self: Self, ctx: ?*c.JSContext, obj: c.JSValue) !void {
        const js_func = c.JS_GetPropertyStr(ctx, self.this_obj, "_writeHostObject");
        defer c.JS_FreeValue(ctx, js_func);

        if (c.JS_IsFunction(ctx, js_func) == c.FALSE) return error.NotImplemented;

        var argv = [1]c.JSValue{obj};
        const js_result = c.JS_Call(ctx, js_func, self.this_obj, 1, &argv);
        defer c.JS_FreeValue(ctx, js_result);

        if (c.JS_IsException(js_result) == c.TRUE) return error.JSError;
    }

    pub fn readHostObject(self: Self, ctx: ?*c.JSContext) !c.JSValue {
        const js_func = c.JS_GetPropertyStr(ctx, self.this_obj, "_readHostObject");
        defer c.JS_FreeValue(ctx, js_func);

        if (c.JS_IsFunction(ctx, js_func) == c.FALSE) return error.NotImplemented;

        var argv = [0]c.JSValue{};
        const js_result = c.JS_Call(ctx, js_func, self.this_obj, 0, &argv);

        return js_result;
    }

    // Host objects behavior is opted in via `setTreatArrayBufferViewsAsHostObjects`
    pub fn hasCustomHostObject(_: Self) bool {
        return false;
    }
    pub fn isHostObject(_: Self, _: ?*c.JSContext, _: c.JSValue) !bool {
        return false;
    }
};

const Serializer = @import("v8-serialize.zig").Serializer(NodeDelegate);
const Deserializer = @import("v8-serialize.zig").Deserializer(NodeDelegate);

const Error = @import("v8-serialize.zig").Error;

const arrayBufferViewToSlice = @import("v8-serialize.zig").arrayBufferViewToSlice;

var serializer_class_id: c.JSClassID = undefined;
var deserializer_class_id: c.JSClassID = undefined;

fn initSerializer(ctx: ?*c.JSContext, obj: c.JSValue) !*Serializer {
    const allocator = QuickJSAllocator.allocator(ctx);
    const ser: *Serializer = try allocator.create(Serializer);
    ser.* = try Serializer.initDelegate(allocator, ctx, .{ .this_obj = obj });
    return ser;
}

fn initDeserializer(ctx: ?*c.JSContext, obj: c.JSValue, js_view: c.JSValue) !*Deserializer {
    const allocator = QuickJSAllocator.allocator(ctx);
    const des: *Deserializer = try allocator.create(Deserializer);
    des.* = try Deserializer.initDelegate(allocator, ctx, js_view, .{ .this_obj = obj });
    return des;
}

fn jsSerializerContructor(ctx: ?*c.JSContext, new_target: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    if (c.JS_IsConstructor(ctx, new_target) == 0) {
        return c.JS_ThrowTypeError(ctx, "not a constructor");
    }
    const proto = c.JS_GetPropertyStr(ctx, new_target, "prototype");
    defer c.JS_FreeValue(ctx, proto);

    const obj = c.JS_NewObjectProtoClass(ctx, proto, serializer_class_id);

    const ser: *Serializer = initSerializer(ctx, obj) catch {
        return c.JS_ThrowTypeError(ctx, "Could not create Serializer");
    };

    c.JS_SetOpaque(obj, ser);

    _ = argc;
    _ = argv;
    return obj;
}

fn jsSerializerFinalizer(_: ?*c.JSRuntime, this_val: c.JSValue) callconv(.C) void {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque(this_val, serializer_class_id)));
    ser.deinit();
    ser.allocator.destroy(ser);
}

fn jsSerializerWriteHeader(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    ser.writeHeader() catch {
        return c.JS_ThrowTypeError(ctx, "Could not write header");
    };
    _ = argc;
    _ = argv;
    return z.JS_UNDEFINED;
}

fn jsSerializerSetTreatArrayBufferViewsAsHostObjects(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    ser.setTreatArrayBufferViewsAsHostObjects(c.JS_ToBool(ctx, argv[0]) == c.TRUE);
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteDouble(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var dbl: f64 = undefined;
    _ = c.JS_ToFloat64(ctx, &dbl, argv[0]);
    ser.writeDouble(dbl) catch {
        return c.JS_ThrowTypeError(ctx, "Could not write double");
    };
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteValue(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    ser.writeObject(argv[0]) catch |err| switch (err) {
        Error.NotImplemented => return c.JS_ThrowTypeError(ctx, "Method _writeHostObject not implemented"),
        else => return c.JS_ThrowTypeError(ctx, "Could not write value"),
    };
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteRawBytes(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");

    const slice = arrayBufferViewToSlice(ctx, argv[0]) catch {
        return c.JS_ThrowTypeError(ctx, "Could not read bytes");
    };

    ser.writeRawBytes(slice) catch {
        return c.JS_ThrowTypeError(ctx, "Could not write raw bytes");
    };
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteUint32(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var num: u32 = undefined;
    if (c.JS_ToUint32(ctx, &num, argv[0]) != 0) return c.JS_ThrowTypeError(ctx, "Could not convert argument to integer");
    ser.writeUint32(num) catch {
        return c.JS_ThrowTypeError(ctx, "Could not write double");
    };
    return z.JS_UNDEFINED;
}

fn jsSerializerWriteUint64(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    if (argc < 2) return c.JS_ThrowTypeError(ctx, "Not enough arguments");

    var lo: u32 = undefined;
    var hi: u32 = undefined;
    if (c.JS_ToUint32(ctx, &lo, argv[0]) != 0 or c.JS_ToUint32(ctx, &hi, argv[1]) != 0) {
        return c.JS_ThrowTypeError(ctx, "Could not convert argument to integer");
    }
    const hi_64: u64 = @intCast(hi);
    const num: u64 = (hi_64 << 32) | lo;
    ser.writeUint64(num) catch {
        return c.JS_ThrowTypeError(ctx, "Could not write double");
    };
    return z.JS_UNDEFINED;
}

fn jsSerializerReleaseBuffer(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const ser: *Serializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, serializer_class_id)));
    const bytes = ser.release() catch {
        return c.JS_ThrowTypeError(ctx, "Could not release buffer");
    };
    _ = argc;
    _ = argv;
    return c.JS_NewUint8Array(ctx, bytes.ptr, bytes.len, &freeFunc, null, 0); // return c.JS_NewUint8ArrayCopy(ctx, bytes.ptr, bytes.len);
}

const serializer_class = c.JSClassDef{
    .class_name = "Serializer",
    .finalizer = jsSerializerFinalizer,
};
const serializer_proto_funcs = [_]c.JSCFunctionListEntry{
    z.JS_CFUNC_DEF("writeHeader", 0, jsSerializerWriteHeader),
    z.JS_CFUNC_DEF("writeValue", 1, jsSerializerWriteValue),
    z.JS_CFUNC_DEF("releaseBuffer", 0, jsSerializerReleaseBuffer),
    z.JS_CFUNC_DEF("writeUint32", 1, jsSerializerWriteUint32),
    z.JS_CFUNC_DEF("writeUint64", 2, jsSerializerWriteUint64),
    z.JS_CFUNC_DEF("writeDouble", 1, jsSerializerWriteDouble),
    z.JS_CFUNC_DEF("writeRawBytes", 1, jsSerializerWriteRawBytes),
    z.JS_CFUNC_DEF("_setTreatArrayBufferViewsAsHostObjects", 1, jsSerializerSetTreatArrayBufferViewsAsHostObjects),
};

fn jsDeserializerContructor(ctx: ?*c.JSContext, new_target: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    if (c.JS_IsConstructor(ctx, new_target) == 0) {
        return c.JS_ThrowTypeError(ctx, "not a constructor");
    }
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");

    const proto = c.JS_GetPropertyStr(ctx, new_target, "prototype");
    defer c.JS_FreeValue(ctx, proto);

    const obj = c.JS_NewObjectProtoClass(ctx, proto, deserializer_class_id);

    const des: *Deserializer = initDeserializer(ctx, obj, argv[0]) catch {
        return c.JS_ThrowTypeError(ctx, "Could not create Deserializer");
    };

    c.JS_SetOpaque(obj, des);

    return obj;
}

fn jsDeserializerFinalizer(_: ?*c.JSRuntime, this_val: c.JSValue) callconv(.C) void {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque(this_val, deserializer_class_id)));
    des.deinit();
    des.allocator.destroy(des);
}

fn jsDeserializerReadHeader(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    _ = des.readHeader() catch {
        return c.JS_ThrowTypeError(ctx, "Could not read value");
    };
    return z.JS_TRUE;
}

fn jsDeserializerGetWireFormatVersion(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    if (des.version != null) {
        return c.JS_NewUint32(ctx, des.version.?);
    } else {
        return z.JS_UNDEFINED;
    }
}

fn jsDeserializerReadDouble(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    const dbl = des.readDouble() catch {
        return c.JS_ThrowTypeError(ctx, "Could not read value");
    };
    return c.JS_NewFloat64(ctx, dbl);
}

fn jsDeserializerReadUint32(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    const val = des.readUint32() catch {
        return c.JS_ThrowTypeError(ctx, "Could not read value");
    };
    return c.JS_NewUint32(ctx, val);
}

fn jsDeserializerReadUint64(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    const val = des.readUint64() catch {
        return c.JS_ThrowTypeError(ctx, "Could not read value");
    };
    const hi: u32 = @intCast(val >> 32);
    const lo: u32 = @intCast(val & 0xFFFFFFFF);
    const tuple = c.JS_NewArray(ctx);
    _ = c.JS_DefinePropertyValueUint32(ctx, tuple, 0, c.JS_NewUint32(ctx, hi), c.JS_PROP_C_W_E);
    _ = c.JS_DefinePropertyValueUint32(ctx, tuple, 1, c.JS_NewUint32(ctx, lo), c.JS_PROP_C_W_E);
    return tuple;
}

fn jsDeserializerReadValue(ctx: ?*c.JSContext, this_val: c.JSValueConst, _: c_int, _: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    const val = des.readObject() catch |err| switch (err) {
        Error.NotImplemented => return c.JS_ThrowTypeError(ctx, "Method _readHostObject not implemented"),
        else => return c.JS_ThrowTypeError(ctx, "Could not read value"),
    };
    return val;
}

fn jsDeserializerReadRawBytes(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var length: u32 = undefined;
    if (c.JS_ToUint32(ctx, &length, argv[0]) < 0) return c.JS_ThrowTypeError(ctx, "Could not convert argument to uint32");
    const bytes = des.readRawBytes(@intCast(length)) catch {
        return c.JS_ThrowTypeError(ctx, "Could not read value");
    };
    return c.JS_NewUint8ArrayCopy(ctx, bytes.ptr, bytes.len);
}

/// Same as `jsDeserializerReadRawBytes`, but just advanced the internal position and returns the starting offset.
fn jsDeserializerReadRawBytes_(ctx: ?*c.JSContext, this_val: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    if (argc < 1) return c.JS_ThrowTypeError(ctx, "Not enough arguments");
    var length: u32 = undefined;
    if (c.JS_ToUint32(ctx, &length, argv[0]) < 0) return c.JS_ThrowTypeError(ctx, "Could not convert argument to uint32");
    const offset = des.position;
    _ = des.readRawBytes(@intCast(length)) catch {
        return c.JS_ThrowTypeError(ctx, "Could not read value");
    };
    return c.JS_NewUint32(ctx, @intCast(offset));
}

fn jsDeserializerBufferGetter(ctx: ?*c.JSContext, this_val: c.JSValueConst) callconv(.C) c.JSValue {
    const des: *Deserializer = @alignCast(@ptrCast(c.JS_GetOpaque2(ctx, this_val, deserializer_class_id)));
    // XXX: ensure Uint8Array, currently just passing through whatever typed array passed to the constructor
    return c.JS_DupValue(ctx, des.js_view);
}

const deserializer_class = c.JSClassDef{
    .class_name = "Deserializer",
    .finalizer = jsDeserializerFinalizer,
};
const deserializer_proto_funcs = [_]c.JSCFunctionListEntry{
    z.JS_CFUNC_DEF("readHeader", 0, jsDeserializerReadHeader),
    z.JS_CFUNC_DEF("readValue", 0, jsDeserializerReadValue),
    z.JS_CFUNC_DEF("getWireFormatVersion", 0, jsDeserializerGetWireFormatVersion),
    z.JS_CFUNC_DEF("readUint32", 0, jsDeserializerReadUint32),
    z.JS_CFUNC_DEF("readUint64", 0, jsDeserializerReadUint64),
    z.JS_CFUNC_DEF("readDouble", 0, jsDeserializerReadDouble),
    z.JS_CFUNC_DEF("readRawBytes", 1, jsDeserializerReadRawBytes),
    z.JS_CFUNC_DEF("_readRawBytes", 1, jsDeserializerReadRawBytes_),
    z.JS_CGETSET_DEF("buffer", jsDeserializerBufferGetter, null),
};

export fn zig__mod_v8_compat_init(ctx: ?*c.JSContext, ns: c.JSValue) callconv(.C) void {
    const rt = c.JS_GetRuntime(ctx);

    _ = c.JS_NewClassID(rt, &serializer_class_id);
    _ = c.JS_NewClass(rt, serializer_class_id, &serializer_class);

    const ser_proto = c.JS_NewObject(ctx);
    c.JS_SetPropertyFunctionList(ctx, ser_proto, &serializer_proto_funcs, serializer_proto_funcs.len);
    c.JS_SetClassProto(ctx, serializer_class_id, ser_proto);

    const ser_ctor = c.JS_NewCFunction2(ctx, jsSerializerContructor, "Serializer", 0, c.JS_CFUNC_constructor_or_func, 0);
    c.JS_SetConstructor(ctx, ser_ctor, ser_proto);

    _ = c.JS_NewClassID(rt, &deserializer_class_id);
    _ = c.JS_NewClass(rt, deserializer_class_id, &deserializer_class);

    const des_proto = c.JS_NewObject(ctx);
    c.JS_SetPropertyFunctionList(ctx, des_proto, &deserializer_proto_funcs, deserializer_proto_funcs.len);
    c.JS_SetClassProto(ctx, deserializer_class_id, des_proto);

    const des_ctor = c.JS_NewCFunction2(ctx, jsDeserializerContructor, "Deserializer", 1, c.JS_CFUNC_constructor_or_func, 0);
    c.JS_SetConstructor(ctx, des_ctor, des_proto);

    _ = c.JS_DefinePropertyValueStr(ctx, ns, "Serializer", ser_ctor, c.JS_PROP_C_W_E);
    _ = c.JS_DefinePropertyValueStr(ctx, ns, "Deserializer", des_ctor, c.JS_PROP_C_W_E);
}
