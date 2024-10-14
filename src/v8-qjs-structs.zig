/// Handrolled struct defs for a bunch of QuickJS types that either couldn't be auto-translagted by Zig,
/// or are marked private but we want to use them anyway..
const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("cutils.h");
    @cInclude("list.h");
    @cInclude("libregexp.h");
    @cInclude("libbf.h");
    @cInclude("quickjs.h");
});

const dump_leaks = builtin.mode == .Debug;

pub const JSString = extern struct {
    header: c.JSRefCountHeader,
    _len_or_is_wide_char: u32,
    // XXX: bitfields are nightmares. From experiments, will claim an extra u32 on windows only
    ___padding1: if (@import("builtin").target.os.tag == .windows) u32 else void,
    _hash_or_atom_type: u32,
    // XXX: bitfields are nightmares. From experiments, will claim an extra u32 on windows only
    ___padding2: if (@import("builtin").target.os.tag == .windows) u32 else void,
    hash_next: u32,
    first_weak_ref: *anyopaque, // XXX: should be c.JSWeakRefRecord,
    link: if (dump_leaks) c.list_head else void,
    u: extern union {
        str8: [0]u8,
        str16: [0]u16,
    },
    pub fn len(self: *JSString) u31 { return @intCast(self._len_or_is_wide_char & 0x7FFFFFFF); }
    pub fn isWideChar(self: *JSString) bool { return (self._len_or_is_wide_char & 0x80000000) != 0; }
    pub fn hash(self: *JSString) u30 { return @intCast(self._hash_or_atom_type & 0x3FFFFFFF); }
    pub fn atomType(self: *JSString) u2 { return @intCast(self._hash_or_atom_type >> 30); }
};

pub const JSVarRef = extern struct {
    a: extern union {
        header: JSGCObjectHeader,
        b: extern struct {
            __gc_ref_count: c_int,
            __gc_mark: u8,
            _bitfield: u8,
            var_idx: u16,
        },
    },
    pvalue: *c.JSValue,
    value: *c.JSValue,
};

pub const JSBigInt = extern struct {
    header: c.JSRefCountHeader,
    num: c.bf_t,
};

pub const JSGCObjectHeader = extern struct {
    ref_count: c_int,
    _gc_obj_type_or_mark: u8,
    // XXX: bitfields are nightmares. From experiments, will have alignment 8 on 64-bit windows, but 4 otherwise.
    // Since we only target 64-bit win, just hard-code it...
    dummy1: u8 align(if (@import("builtin").target.os.tag == .windows) 8 else 1),
    dummy2: u16,
    link: c.list_head,
    pub fn gcObjType(self: *JSGCObjectHeader) u4 { return @intCast(self._gc_obj_type_or_mark & 0x0F); }
    pub fn mark(self: *JSGCObjectHeader) u4 { return @intCast(self._gc_obj_type_or_mark >> 4); }
};

pub const JSProperty = extern struct {
    u: extern union {
        value: c.JSValue,
        getset: extern struct {
            getter: *c.JSObject,
            setter: *c.JSObject,
        },
        var_ref: *JSVarRef,
        init: extern struct {
            realm_and_id: usize,
            opaque_field: *void,
        },
    },
};

pub const JSShapeProperty = extern struct {
    _hash_next_or_flags: u32,
    atom: c.JSAtom,
    pub fn hashNext(self: *JSShapeProperty) u26 { return @intCast(self._hash_next_or_flags & 0x3FFFFFF); }
    pub fn flags(self: *JSShapeProperty) u6 { return @intCast(self._hash_next_or_flags >> 26); }
};

pub const JSShape = extern struct {
    header: JSGCObjectHeader,
    is_hashed: u8,
    has_small_array_index: u8,
    hash: u32,
    prop_hash_mask: u32,
    prop_size: c_int,
    prop_count: c_int,
    deleted_prop_count: c_int,
    shape_hash_next: *anyopaque, // *JSShape, // XXX: why segfault when logging and not opaque?
    proto: *JSObject,
    prop: [0]JSShapeProperty,
};

pub const JSRegExp = extern struct {
    pattern: *JSString,
    bytecode: *JSString, // also contains the flags
};

pub const JSMapRecord = extern struct {
    ref_count: c_int, // used during enumeration to avoid freeing the record
    empty: c_int, // TRUE if the record is deleted
    map: *JSMapState,
    link: c.list_head,
    hash_link: c.list_head,
    key: c.JSValue,
    value: c.JSValue,
};

pub const JSMapState = extern struct {
    is_weak: c_int,
    records: c.list_head,
    record_count: u32,
    hash_table: *c.list_head,
    hash_size: u32,
    record_count_threshold: u32,
};

pub const JSArrayBuffer = extern struct {
    byte_length: c_int, // 0 if detached */
    detached: u8,
    shared: u8, // if shared, the array buffer cannot be detached */
    data: [*]u8, // NULL if detached */
    array_list: c.list_head,
    _opaque: *anyopaque, // *void
    freee_func: *anyopaque, // *JSFreeArrayBufferDataFunc;
};

pub const JSTypedArray = extern struct {
    link: c.list_head,
    obj: *JSObject,
    buffer: *JSObject,
    offset: u32,
    length: u32,
};

pub const JSObject = extern struct {
    a: extern union {
        header: JSGCObjectHeader,
        b: extern struct {
            const Self = @This();
            __gc_ref_count: c_int, // corresponds to header.ref_count
            __gc_mark: u8,         // corresponds to header.mark/gc_obj_type
            _bitfield: u8,
            class_id: u16,         // see JS_CLASS_x
            pub fn extensible(self: *Self) bool { return self._bitfield & 0x01 != 0; }
            pub fn freeMark(self: *Self) bool { return self._bitfield & 0x02 != 0; }
            pub fn isExotic(self: *Self) bool { return self._bitfield & 0x04 != 0; }
            pub fn fastArray(self: *Self) bool { return self._bitfield & 0x08 != 0; }
            pub fn isConstructor(self: *Self) bool { return self._bitfield & 0x10 != 0; }
            pub fn isUncatchableError(self: *Self) bool { return self._bitfield & 0x20 != 0; }
            pub fn tmpMark(self: *Self) bool { return self._bitfield & 0x40 != 0; }
            pub fn isHTMLDDA(self: *Self) bool { return self._bitfield & 0x80 != 0; }
        },
    },
    shape: *JSShape,
    prop: [*]JSProperty,
    first_weak_ref: *anyopaque, // XXX: should be c.JSWeakRefRecord,
    u: extern union {
        array: extern struct {
            u1: extern union {
                size: u32,              // JS_CLASS_ARRAY, JS_CLASS_ARGUMENTS
                typed_array: *JSTypedArray, //JS_CLASS_UINT8C_ARRAY..JS_CLASS_FLOAT64_ARRAY
            },
            u: extern union {
                values: [*]c.JSValue, // JS_CLASS_ARRAY, JS_CLASS_ARGUMENTS
                ptr: *anyopaque,      // JS_CLASS_UINT8C_ARRAY..JS_CLASS_FLOAT64_ARRAY
                int8_ptr: [*]i8,      // JS_CLASS_INT8_ARRAY
                uint8_ptr: [*]u8,     // JS_CLASS_UINT8_ARRAY
                int16_ptr: [*]i16,    // JS_CLASS_INT16_ARRAY
                uint16_ptr: [*]u16,   // JS_CLASS_UINT16_ARRAY
                int32_ptr: [*]i32,    // JS_CLASS_INT32_ARRAY
                uint32_ptr: [*]u32,   // JS_CLASS_UINT32_ARRAY
                int64_ptr: [*]i64,    // JS_CLASS_INT64_ARRAY
                uint64_ptr: [*]u64,   // JS_CLASS_UINT64_ARRAY
                fp16_ptr: [*]u16,     // JS_CLASS_FLOAT16_ARRAY
                float_ptr: [*]f32,    // JS_CLASS_FLOAT32_ARRAY
                double_ptr: [*]f64,   // JS_CLASS_FLOAT64_ARRAY
            },
            count: u32, // <= 2^31-1. 0 for a detached typed array
        },
        array_buffer: *JSArrayBuffer,
        typed_array: *JSTypedArray,
        map_state: *JSMapState,
        regexp: JSRegExp,
        object_data: c.JSValue,
        // XXX: add other object types as needed
    },
};

pub const JSContext = extern struct {
    header: JSGCObjectHeader,
    rt: *c.JSRuntime,
    link: c.list_head,

    binary_object_count: u16,
    binary_object_size: c_int,

    array_shape: *JSShape,   // initial shape for Array objects

    class_proto: *c.JSValue,
    function_proto: c.JSValue,
    function_ctor: c.JSValue,
    array_ctor: c.JSValue,
    regexp_ctor: c.JSValue,
    promise_ctor: c.JSValue,
    native_error_proto: [8]c.JSValue, // XXX: should be: JSValue native_error_proto[JS_NATIVE_ERROR_COUNT];

    // XXX: add other fields as needed
};

/// These are the values of the `class_id` field in `JSObject`. In qjs they are named `JS_CLASS_*`.
// XXX: Mabye don't use capslock?
pub const JSClassId = enum(u16) {
    OBJECT = 1,        // must be first
    ARRAY,             // u.array       | length
    ERROR,
    NUMBER,            // u.object_data
    STRING,            // u.object_data
    BOOLEAN,           // u.object_data
    SYMBOL,            // u.object_data
    ARGUMENTS,         // u.array       | length
    MAPPED_ARGUMENTS,  //               | length
    DATE,              // u.object_data
    MODULE_NS,
    C_FUNCTION,        // u.cfunc
    BYTECODE_FUNCTION, // u.func
    BOUND_FUNCTION,    // u.bound_function
    C_FUNCTION_DATA,   // u.c_function_data_record
    GENERATOR_FUNCTION, // u.func
    FOR_IN_ITERATOR,   // u.for_in_iterator
    REGEXP,            // u.regexp
    ARRAY_BUFFER,      // u.array_buffer
    SHARED_ARRAY_BUFFER, // u.array_buffer
    UINT8C_ARRAY,      // u.array (typed_array)
    INT8_ARRAY,        // u.array (typed_array)
    UINT8_ARRAY,       // u.array (typed_array)
    INT16_ARRAY,       // u.array (typed_array)
    UINT16_ARRAY,      // u.array (typed_array)
    INT32_ARRAY,       // u.array (typed_array)
    UINT32_ARRAY,      // u.array (typed_array)
    BIG_INT64_ARRAY,   // u.array (typed_array)
    BIG_UINT64_ARRAY,  // u.array (typed_array)
    FLOAT16_ARRAY,     // u.array (typed_array)
    FLOAT32_ARRAY,     // u.array (typed_array)
    FLOAT64_ARRAY,     // u.array (typed_array)
    DATAVIEW,          // u.typed_array
    BIG_INT,           // u.object_data
    MAP,               // u.map_state
    SET,               // u.map_state
    WEAKMAP,           // u.map_state
    WEAKSET,           // u.map_state
    MAP_ITERATOR,      // u.map_iterator_data
    SET_ITERATOR,      // u.map_iterator_data
    ARRAY_ITERATOR,    // u.array_iterator_data
    STRING_ITERATOR,   // u.array_iterator_data
    REGEXP_STRING_ITERATOR,   // u.regexp_string_iterator_data
    GENERATOR,         // u.generator_data
    PROXY,             // u.proxy_data
    PROMISE,           // u.promise_data
    PROMISE_RESOLVE_FUNCTION,  // u.promise_function_data
    PROMISE_REJECT_FUNCTION,   // u.promise_function_data
    ASYNC_FUNCTION,            // u.func
    ASYNC_FUNCTION_RESOLVE,    // u.async_function_data
    ASYNC_FUNCTION_REJECT,     // u.async_function_data
    ASYNC_FROM_SYNC_ITERATOR,  // u.async_from_sync_iterator_data
    ASYNC_GENERATOR_FUNCTION,  // u.func
    ASYNC_GENERATOR,   // u.async_generator_data
    WEAK_REF,
    FINALIZATION_REGISTRY,
    CALL_SITE,

    INIT_COUNT, // last entry for predefined classes
    _,
};

pub fn JS_CFUNC_DEF(comptime name: [*c]const u8, comptime length: u8, comptime func1: ?*const c.JSCFunction) c.JSCFunctionListEntry  {
    return .{
        .name = name,
        .prop_flags = c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE,
        .def_type = c.JS_DEF_CFUNC,
        .magic = 0,
        .u = .{ .func = .{ .length = length, .cproto = c.JS_CFUNC_generic, .cfunc = .{ .generic = func1 } } },
    };
}

pub fn JS_CGETSET_DEF(
    comptime name: [*c]const u8,
    comptime fgetter: ?*const fn (?*c.JSContext, c.JSValue) callconv(.C) c.JSValue,
    comptime fsetter: ?*const fn (?*c.JSContext, c.JSValue, c.JSValue) callconv(.C) c.JSValue,
) c.JSCFunctionListEntry {
    return .{
        .name = name,
        .prop_flags = c.JS_PROP_CONFIGURABLE,
        .def_type = c.JS_DEF_CGETSET,
        .magic = 0,
        .u = .{ .getset = .{ .get = .{ .getter = fgetter }, .set = .{ .setter = fsetter } } },
    };
}

const JS_NAN_BOXING = c.INTPTR_MAX < c.INT64_MAX;

/// 64-bit only!!
fn _JS_MKVAL(comptime tag: i64, comptime val: i32) c.JSValue {
    return c.JSValue{
        .tag = tag,
        .u = c.JSValueUnion{ .int32 = val },
    };
}

/// 64-bit only!!
fn _JS_MKPTR(comptime tag: i64, comptime p: ?*anyopaque) c.JSValue {
    return c.JSValue{
        .tag = tag,
        .u = c.JSValueUnion{ .ptr = p },
    };
}

// zig translate-c can't handle these macros correctly (on 64-bit) so we re-define here:
pub const JS_NULL = if (JS_NAN_BOXING) c.JS_NULL else _JS_MKVAL(c.JS_TAG_NULL, 0);
pub const JS_UNDEFINED = if (JS_NAN_BOXING) c.JS_UNDEFINED else _JS_MKVAL(c.JS_TAG_UNDEFINED, 0);
pub const JS_FALSE = if (JS_NAN_BOXING) c.JS_FALSE else _JS_MKVAL(c.JS_TAG_BOOL, 0);
pub const JS_TRUE = if (JS_NAN_BOXING) c.JS_TRUE else _JS_MKVAL(c.JS_TAG_BOOL, 1);
pub const JS_EXCEPTION = if (JS_NAN_BOXING) c.JS_EXCEPTION else _JS_MKVAL(c.JS_TAG_EXCEPTION, 0);
pub const JS_UNINITIALIZED = if (JS_NAN_BOXING) c.JS_UNINITIALIZED else _JS_MKVAL(c.JS_TAG_UNINITIALIZED, 0);
