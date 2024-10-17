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

pub const JSString = opaque {}; 

pub const JSBigInt = extern struct {
    header: c.JSRefCountHeader,
    num: c.bf_t,
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

pub const JSErrorEnum = enum(c_int) {
    EVAL_ERROR,
    RANGE_ERROR,
    REFERENCE_ERROR,
    SYNTAX_ERROR,
    TYPE_ERROR,
    URI_ERROR,
    INTERNAL_ERROR,
    AGGREGATE_ERROR,
    PLAIN_ERROR,
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
