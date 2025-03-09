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

pub const JSRefCountHeader = extern struct {
    ref_count: c_int,
};

pub const JSBigInt = extern struct {
    header: JSRefCountHeader,
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
pub const JSClassId = enum(u16) {
    object = 1,        // must be first
    array,             // u.array       | length
    @"error",
    number,            // u.object_data
    string,            // u.object_data
    boolean,           // u.object_data
    symbol,            // u.object_data
    arguments,         // u.array       | length
    mapped_arguments,  //               | length
    date,              // u.object_data
    module_ns,
    c_function,        // u.cfunc
    bytecode_function, // u.func
    bound_function,    // u.bound_function
    c_function_data,   // u.c_function_data_record
    generator_function, // u.func
    for_in_iterator,   // u.for_in_iterator
    regexp,            // u.regexp
    array_buffer,      // u.array_buffer
    shared_array_buffer, // u.array_buffer
    uint8c_array,      // u.array (typed_array)
    int8_array,        // u.array (typed_array)
    uint8_array,       // u.array (typed_array)
    int16_array,       // u.array (typed_array)
    uint16_array,      // u.array (typed_array)
    int32_array,       // u.array (typed_array)
    uint32_array,      // u.array (typed_array)
    big_int64_array,   // u.array (typed_array)
    big_uint64_array,  // u.array (typed_array)
    float16_array,     // u.array (typed_array)
    float32_array,     // u.array (typed_array)
    float64_array,     // u.array (typed_array)
    dataview,          // u.typed_array
    big_int,           // u.object_data
    map,               // u.map_state
    set,               // u.map_state
    weakmap,           // u.map_state
    weakset,           // u.map_state
    map_iterator,      // u.map_iterator_data
    set_iterator,      // u.map_iterator_data
    array_iterator,    // u.array_iterator_data
    string_iterator,   // u.array_iterator_data
    regexp_string_iterator,   // u.regexp_string_iterator_data
    generator,         // u.generator_data
    proxy,             // u.proxy_data
    promise,           // u.promise_data
    promise_resolve_function,  // u.promise_function_data
    promise_reject_function,   // u.promise_function_data
    async_function,            // u.func
    async_function_resolve,    // u.async_function_data
    async_function_reject,     // u.async_function_data
    async_from_sync_iterator,  // u.async_from_sync_iterator_data
    async_generator_function,  // u.func
    async_generator,   // u.async_generator_data
    weak_ref,
    finalization_registry,
    call_site,

    init_count, // last entry for predefined classes
    _,
};

pub const JSErrorEnum = enum(c_int) {
    eval_error,
    range_error,
    reference_error,
    syntax_error,
    type_error,
    uri_error,
    internal_error,
    aggregate_error,
    plain_error,
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
