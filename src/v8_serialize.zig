const std = @import("std");
const builtin = @import("builtin");

pub const z = @import("tjs_structs.zig");
pub const c = z.c;

const QJSAllocator = @import("tjs_qjs_allocator.zig").QJSAllocator;

extern fn JS_MakeError2(ctx: ?*c.JSContext, error_num: z.JSErrorEnum, add_backtrace: bool, message: [*c]const u8) c.JSValue;

// A bunch of qjs internal functions that we've re-exported with a different prefix.
extern fn _js_compact_bigint(ctx: ?*c.JSContext, p: *z.JSBigInt) c.JSValue;
extern fn _js_new_string8_len(ctx: ?*c.JSContext, buf: [*c]const u8, len: c_int) c.JSValue;
extern fn _js_new_string16_len(ctx: ?*c.JSContext, buf: [*c]const u16, len: c_int) c.JSValue;
extern fn _js_bigint_from_string(ctx: ?*c.JSContext, str: [*c]const u8, radix: c_int) ?*z.JSBigInt;
extern fn _js_bigint_to_string1(ctx: ?*c.JSContext, val: c.JSValueConst, radix: c_int) c.JSValue;
extern fn _js_typed_array_get_buffer(ctx: ?*c.JSContext, this_val: c.JSValueConst) c.JSValue;
extern fn _js_dataview_get_buffer(ctx: ?*c.JSContext, this_val: c.JSValue) c.JSValue;
extern fn _js_dataview_constructor(ctx: ?*c.JSContext, new_target: c.JSValue, argc: c_int, argv: [*c]c.JSValue) c.JSValue;
extern fn _js_get_regexp(ctx: ?*c.JSContext, obj: c.JSValue, throw_error: bool) *z.JSRegExp;
extern fn _js_is_fast_array(ctx: ?*c.JSContext, obj: c.JSValue) bool;
extern fn _js_get_fast_array(ctx: ?*c.JSContext, obj: c.JSValue, arrpp: *[*]c.JSValue, countp: *u32) bool;
extern fn _js_get_non_index_enumerable_string_keys_excluding(ctx: ?*c.JSContext, ptab: [*c][*c]c.JSPropertyEnum, plen: *u32, obj: c.JSValueConst, skip_indices_below: u32) c_int;

// A few non-standard qjs functions that we've added.
extern fn _js_check_stack_overflow(ctx: ?*c.JSContext, alloca_size: usize) bool;
extern fn _js_atom_is_string(ctx: ?*c.JSContext, v: c.JSAtom) bool;
extern fn _js_get_map_state(ctx: ?*c.JSContext, obj: c.JSValue, throw_error: bool) *z.JSMapState;
extern fn _js_string_is_wide_char(p: *const z.JSString) bool;
extern fn _js_string_get_len(p: *const z.JSString) u32;
extern fn _js_string_get_str8(p: *const z.JSString) [*]const u8;
extern fn _js_string_get_str16(p: *const z.JSString) [*]const u16;
extern fn _js_get_object_data(ctx: ?*c.JSContext, obj: c.JSValue, pval: *c.JSValue) bool;
extern fn _js_typed_array_get_byte_length(p: *c.JSObject) u32;
extern fn _js_typed_array_get_byte_offset(p: *c.JSObject) u32;

const kLatestVersion = 15;

const cTRUE = 1;
const cFALSE = 0;

pub const Error = std.mem.Allocator.Error || error{
    DataCloneError,
    DataCloneErrorDetachedArrayBuffer,
    DataCloneDeserializationError,
    DataCloneDeserializationVersionError,
    NotImplemented,
    JSException,
};

fn bytesNeededForVarint(comptime T: type, value: T) usize {
    comptime {
        const type_info = @typeInfo(T);
        if (type_info != .int or type_info.int.signedness != .unsigned) {
            @compileError("Only unsigned integer types can be written as varints.");
        }
    }

    var result: usize = 0;
    var temp_value = value;
    while (temp_value != 0) : (temp_value >>= 7) {
        result += 1;
    }
    return result;
}

// /// A right-shift for u64 slices that can shift by more than 64 bits.
// fn shiftRightU64Slice(values: []u64, n: usize) void {
//     const m = n / 64; // Number of full u64 shifts
//     const n_bits: u6 = @intCast(n % 64); // Remaining bit shift within u64

//     const len = values.len;

//     // Shift full u64 values
//     if (m > 0) {
//         var i = len;
//         while (i > m) : (i -= 1) {
//             const idx = i - 1;
//             values[idx] = values[idx - m];
//         }
//         for (0..m) |idx| {
//             values[idx] = 0;
//         }
//     }

//     // Shift remaining bits within u64s
//     if (n_bits > 0) {
//         var carry: u64 = 0;
//         var i = len;
//         while (i > m) : (i -= 1) {
//             const idx = i - 1;
//             const new_carry = values[idx] << (63 - n_bits + 1); // Save bits that will be shifted out
//             values[idx] = (values[idx] >> n_bits) | carry;
//             carry = new_carry;
//         }
//     }
// }

fn ShiftTypeOf(comptime T: type) type {
    const type_info = @typeInfo(T);
    return switch (type_info.int.bits) {
        0...8 => u3,
        9...16 => u4,
        17...32 => u5,
        33...64 => u6,
        else => @compileError("Unsupported integer type"),
    };
}

// fn freeFunc(rt: ?*c.JSRuntime, _: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
//     c.js_free_rt(rt, ptr);
// }

inline fn stackCheck(ctx: ?*c.JSContext) !void {
    if (_js_check_stack_overflow(ctx, 0)) {
        @branchHint(.unlikely);
        _ = c.JS_ThrowRangeError(ctx, "Maximum call stack size exceeded");
        return Error.JSException;
    }
}

inline fn exceptionCheck(val: c.JSValue) !void {
    if (c.JS_IsException(val)) {
        @branchHint(.unlikely);
        return Error.JSException;
    }
}

inline fn getTypedArrayBuffer(ctx: ?*c.JSContext, obj: c.JSValue) !struct { c.JSValue, usize, usize, usize } {
    var offset: usize = 0;
    var length: usize = 0;
    var bytes_per_element: usize = 0;
    const buffer = c.JS_GetTypedArrayBuffer(ctx, obj, &offset, &length, &bytes_per_element);
    try exceptionCheck(buffer);
    return .{ buffer, offset, length, bytes_per_element };
}

pub fn arrayBufferViewToSlice(ctx: ?*c.JSContext, obj: c.JSValue) ![]u8 {
    const js_ab, const offset, const length, const bytes_per_element = try getTypedArrayBuffer(ctx, obj);
    defer c.JS_FreeValue(ctx, js_ab);

    var len: usize = 0;
    const bytes = c.JS_GetArrayBuffer(ctx, &len, js_ab);
    if (bytes == null) {
        @branchHint(.unlikely);
        return Error.JSException;
    }

    return bytes[offset .. offset + (length * bytes_per_element)];
}

pub const SerializationTag = enum(u8) {
    version = 255,
    padding = 0,
    verify_object_count = '?',
    the_hole = '-',
    undefined = '_',
    null = '0',
    true = 'T',
    false = 'F',
    int32 = 'I',
    uint32 = 'U',
    double = 'N',
    big_int = 'Z',
    utf8_string = 'S',
    one_byte_string = '"',
    two_byte_string = 'c',
    object_reference = '^',
    begin_js_object = 'o',
    end_js_object = '{',
    begin_sparse_js_array = 'a',
    end_sparse_js_array = '@',
    begin_dense_js_array = 'A',
    end_dense_js_array = '$',
    date = 'D',
    true_object = 'y',
    false_object = 'x',
    number_object = 'n',
    big_int_object = 'z',
    string_object = 's',
    reg_exp = 'R',
    begin_js_map = ';',
    end_js_map = ':',
    begin_js_set = '\'',
    end_js_set = ',',
    array_buffer = 'B',
    resizable_array_buffer = '~',
    array_buffer_transfer = 't',
    array_buffer_view = 'V',
    shared_array_buffer = 'u',
    shared_object = 'p',
    wasm_module_transfer = 'w',
    host_object = '\\',
    wasm_memory_transfer = 'm',
    @"error" = 'r',
    _,
};

pub const ArrayBufferViewTag = enum(u8) {
    int8_array = 'b',
    uint8_array = 'B',
    uint8_clamped_array = 'C',
    int16_array = 'w',
    uint16_array = 'W',
    int32_array = 'd',
    uint32_array = 'D',
    float16_array = 'h',
    float32_array = 'f',
    float64_array = 'F',
    big_int64_array = 'q',
    big_uint64_array = 'Q',
    data_view = '?',
    _,
};

pub const ErrorTag = enum(u8) {
    eval_error_prototype = 'E',
    range_error_prototype = 'R',
    reference_error_prototype = 'F',
    syntax_error_prototype = 'S',
    type_error_prototype = 'T',
    uri_error_prototype = 'U',
    message = 'm',
    cause = 'c',
    stack = 's',
    end = '.',
    _,
};

pub const DefaultDelegate = struct {
    const Self = @This();
    pub fn hasCustomHostObject(_: Self) bool {
        return false;
    }
    pub fn isHostObject(_: Self, _: ?*c.JSContext, _: c.JSValue) !bool {
        return false;
    }
    pub fn writeHostObject(_: Self, _: ?*c.JSContext, _: c.JSValue) !void {
        return Error.NotImplemented;
    }
    pub fn readHostObject(_: Self, _: ?*c.JSContext) !c.JSValue {
        return Error.NotImplemented;
    }
    pub fn throwDataCloneError(_: Self, _: ?*c.JSContext, _: []const u8) !void {
        return Error.NotImplemented;
    }
};

const JSObjectHashContext = struct {
    const Self = @This();
    pub fn hash(_: Self, s: *c.JSObject) u64 {
        return @intFromPtr(s) * 3163; // Taken from QuickJS's hash function
    }
    pub fn eql(_: Self, a: *c.JSObject, b: *c.JSObject) bool {
        return a == b;
    }
};

const SetOrMap = enum(u1) { Set, Map };
const ObjectOrArray = enum(u1) { Object, Array };

/// A V8 compatible serializer for QuickJS values.
pub fn Serializer(comptime Delegate: type) type {
    // XXX: comptime validate delegate type
    return struct {
        ac: std.mem.Allocator,
        ctx: ?*c.JSContext,
        buffer: std.ArrayListUnmanaged(u8),
        id_map: std.HashMapUnmanaged(*c.JSObject, u32, JSObjectHashContext, std.hash_map.default_max_load_percentage),
        next_id: u32 = 0,

        treat_array_buffer_views_as_host_objects: bool = false,
        has_custom_objects: bool = false,
        delegate: ?Delegate,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: ?*c.JSContext, delegate: ?Delegate) !Self {
            return Self{
                .ac = allocator,
                .ctx = ctx,
                .buffer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 2),
                .id_map = .empty,
                .delegate = delegate,
                .has_custom_objects = if (delegate) |d| d.hasCustomHostObject() else false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.ac);
            self.id_map.deinit(self.ac);
        }

        pub fn writeHeader(self: *Self) !void {
            try self.writeTag(.version);
            try self.writeVarint(u32, kLatestVersion);
        }

        pub fn setTreatArrayBufferViewsAsHostObjects(self: *Self, mode: bool) void {
            self.treat_array_buffer_views_as_host_objects = mode;
        }

        fn writeTag(self: *Self, tag: SerializationTag) !void {
            try self.buffer.append(self.ac, @intFromEnum(tag));
        }

        fn writeVarint(self: *Self, comptime T: type, value: T) !void {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .unsigned) {
                    @compileError("Only unsigned integer types can be written as varints.");
                }
            }
            var temp_value = value;
            while (temp_value >= 0x80) : (temp_value >>= 7) {
                try self.buffer.append(self.ac, @intCast((temp_value & 0x7F) | 0x80));
            }
            try self.buffer.append(self.ac, @intCast(temp_value));
        }

        fn writeZigZag(self: *Self, comptime T: type, value: T) !void {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .signed) {
                    @compileError("Only signed integer types can be written as zigzag.");
                }
            }
            const UnsignedT = @Type(.{ .int = .{ .bits = @typeInfo(T).int.bits, .signedness = .unsigned } });
            const bit_value: UnsignedT = @bitCast(value);
            const sign_bit: UnsignedT = @bitCast(value >> (@bitSizeOf(T) - 1));
            const zigzag_value: UnsignedT = bit_value << 1 ^ sign_bit;
            try self.writeVarint(UnsignedT, zigzag_value);
        }

        fn writeRawFloat64(self: *Self, value: f64) !void {
            const value_bytes: [@sizeOf(f64)]u8 = @bitCast(value);
            try self.writeRawBytes(&value_bytes);
        }

        pub fn writeDouble(self: *Self, value: f64) !void {
            try self.writeRawFloat64(value);
        }

        fn writeOneByteString(self: *Self, value: []const u8) !void {
            try self.writeVarint(usize, value.len);
            try self.writeRawBytes(value);
        }

        fn writeTwoByteString(self: *Self, value: []const u16) !void {
            try self.writeVarint(usize, value.len * @sizeOf(u16));
            try self.writeRawBytes(@ptrCast(value));
        }

        fn writeBigIntContents(self: *Self, obj: c.JSValue) !void {
            const tag = c.JS_VALUE_GET_NORM_TAG(obj);

            // Short BigInt: always emit one 64-bit word payload.
            if (tag == c.JS_TAG_SHORT_BIG_INT) {
                const val: i32 = c.JS_VALUE_GET_SHORT_BIG_INT(obj);
                if (val == 0) {
                    return self.writeVarint(u32, 0);
                }
                const sign_bit: u1 = if (val < 0) 1 else 0;
                var mag: u64 = if (val < 0) @intCast(-@as(i64, val)) else @intCast(@as(i64, val));

                const bitfield: u32 = (8 << 1) | @as(u32, sign_bit); // 8 payload bytes (one u64 word)
                try self.writeVarint(u32, bitfield);

                const out = try self.reserveRawBytes(8);
                var i: usize = 0;
                while (i < 8) : (i += 1) {
                    out[i] = @intCast(mag & 0xFF);
                    mag >>= 8;
                }
                return;
            }

            // Heap BigInt: get limbs slice (two's complement) and convert to sign-magnitude u64 words.
            const bi: *z.JSBigInt = @alignCast(@ptrCast(c.JS_VALUE_GET_PTR(obj)));
            const limbs_ptr: [*]const z.js_limb_t = @ptrCast(&bi.tab);
            const limbs: []const z.js_limb_t = limbs_ptr[0..@intCast(bi.len)];

            // Zero check
            if (limbs.len == 1 and limbs[0] == 0) {
                return self.writeVarint(u32, 0);
            }

            const sign_bit: u1 = @intCast((limbs[limbs.len - 1] >> 31) & 1);

            // Prepare magnitude limbs (32-bit) trimmed of leading zeros
            var mag_limbs: []const z.js_limb_t = undefined;
            var tmp_buf: ?[]z.js_limb_t = null;
            defer if (tmp_buf) |b| self.ac.free(b);

            if (sign_bit == 1) {
                // Two's complement negate to get magnitude
                var tmp = try self.ac.alloc(z.js_limb_t, limbs.len);
                tmp_buf = tmp; // defer free to end of outer scope
                var carry: u1 = 1;
                var i: usize = 0;
                while (i < limbs.len) : (i += 1) {
                    const inv = ~limbs[i];
                    const sum, const carry_out = @addWithOverflow(inv, carry);
                    carry = carry_out;
                    tmp[i] = sum;
                }
                var end: usize = tmp.len;
                while (end > 1 and tmp[end - 1] == 0) end -= 1;
                mag_limbs = tmp[0..end];
            } else {
                var end: usize = limbs.len;
                while (end > 1 and limbs[end - 1] == 0) end -= 1;
                mag_limbs = limbs[0..end];
            }

            // Convert 32-bit limbs into u64 words (little-endian base 2^64)
            const num_words: usize = (mag_limbs.len + 1) / 2; // ceil(len/2)
            const byte_length: u31 = @intCast(num_words * 8);
            const bitfield: u32 = (byte_length << 1) | sign_bit;
            try self.writeVarint(u32, bitfield);

            const out = try self.reserveRawBytes(byte_length);
            var pos: usize = 0;
            var w: usize = 0;
            while (w < num_words) : (w += 1) {
                const lo_idx = 2 * w;
                const hi_idx = lo_idx + 1;
                const lo: u64 = if (lo_idx < mag_limbs.len) @as(u64, mag_limbs[lo_idx]) else 0;
                const hi: u64 = if (hi_idx < mag_limbs.len) @as(u64, mag_limbs[hi_idx]) else 0;
                var word: u64 = (hi << 32) | lo;
                var i: usize = 0;
                while (i < 8) : (i += 1) {
                    out[pos] = @intCast(word & 0xFF);
                    word >>= 8;
                    pos += 1;
                }
            }
        }

        fn reserveRawBytes(self: *Self, size: usize) ![]u8 {
            try self.buffer.ensureUnusedCapacity(self.ac, size);
            const slice = self.buffer.unusedCapacitySlice();
            self.buffer.items.len += size;
            return slice[0..size];
        }

        pub fn writeRawBytes(self: *Self, bytes: []const u8) !void {
            try self.buffer.appendSlice(self.ac, bytes);
        }

        fn writeByte(self: *Self, value: u8) !void {
            try self.buffer.append(self.ac, value);
        }

        pub fn writeUint32(self: *Self, value: u32) !void {
            try self.writeVarint(u32, value);
        }

        pub fn writeUint64(self: *Self, value: u64) !void {
            try self.writeVarint(u64, value);
        }

        pub fn release(self: *Self) ![]u8 {
            return self.buffer.toOwnedSlice(self.ac);
        }

        pub fn writeObject(self: *Self, object: c.JSValue) Error!void {
            // XXX: ensure heap object?
            const tag = c.JS_VALUE_GET_NORM_TAG(object);
            // std.debug.print("Tag? {}\n", .{tag});
            switch (tag) {
                c.JS_TAG_INT => {
                    try self.writeSmi(object);
                },
                c.JS_TAG_UNDEFINED, c.JS_TAG_NULL, c.JS_TAG_BOOL => {
                    try self.writeOddball(object);
                },
                c.JS_TAG_FLOAT64 => {
                    try self.writeHeapNumber(object);
                },
                c.JS_TAG_BIG_INT, c.JS_TAG_SHORT_BIG_INT => {
                    try self.writeBigInt(object);
                },
                c.JS_TAG_STRING => {
                    try self.writeString(@ptrCast(c.JS_VALUE_GET_PTR(object)));
                },
                c.JS_TAG_OBJECT => {
                    const p: *c.JSObject = @ptrCast(c.JS_VALUE_GET_PTR(object));
                    const class_id = c.JS_GetClassID(object);
                    // std.debug.print("Class id? {}\n", .{p.a.b.class_id});
                    switch (class_id) {
                        // Despite being JSReceivers, these have their wrapped buffer serialized
                        // first. That makes this logic a little quirky, because it needs to
                        // happen before we assign object IDs.
                        @intFromEnum(z.JSClassId.uint8c_array)...@intFromEnum(z.JSClassId.dataview) => {
                            if (!self.id_map.contains(p) and !self.treat_array_buffer_views_as_host_objects) {
                                const is_dataview = class_id == @intFromEnum(z.JSClassId.dataview);
                                const ab_val = if (is_dataview) _js_dataview_get_buffer(self.ctx, object) else _js_typed_array_get_buffer(self.ctx, object);
                                try exceptionCheck(ab_val);
                                defer c.JS_FreeValue(self.ctx, ab_val);
                                try self.writeJSReceiver(ab_val, @ptrCast(c.JS_VALUE_GET_PTR(ab_val)));
                            }
                            try self.writeJSReceiver(object, p);
                        },
                        else => {
                            try self.writeJSReceiver(object, p);
                        },
                    }
                },
                else => {
                    try self.throwDataCloneError();
                },
            }
        }

        fn writeOddball(self: *Self, oddball: c.JSValue) !void {
            const tag = c.JS_VALUE_GET_NORM_TAG(oddball);
            const v8_tag: SerializationTag = switch (tag) {
                c.JS_TAG_UNDEFINED => .undefined,
                c.JS_TAG_NULL => .null,
                c.JS_TAG_BOOL => if (c.JS_VALUE_GET_INT(oddball) == 0) .false else .true,
                else => unreachable,
            };
            try self.writeTag(v8_tag);
        }

        fn writeSmi(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.int32);
            try self.writeZigZag(i32, c.JS_VALUE_GET_INT(value));
        }

        fn writeHeapNumber(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.double);
            try self.writeDouble(c.JS_VALUE_GET_FLOAT64(value));
        }

        fn writeBigInt(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.big_int);
            try self.writeBigIntContents(value);
        }

        fn writeString(self: *Self, p: *const z.JSString) !void {
            const len = _js_string_get_len(p);
            if (_js_string_is_wide_char(p)) {
                const chars = _js_string_get_str16(p);
                const byte_length: u32 = len * @sizeOf(u16);
                // The existing reading code expects 16-byte strings to be aligned.
                if (((self.buffer.items.len + 1 + bytesNeededForVarint(u32, byte_length)) & 1) != 0) {
                    try self.writeTag(.padding);
                }
                try self.writeTag(.two_byte_string);
                try self.writeTwoByteString(chars[0..len]);
            } else {
                const chars = _js_string_get_str8(p);
                try self.writeTag(.one_byte_string);
                try self.writeOneByteString(chars[0..len]);
            }
        }

        fn writeJSReceiver(self: *Self, obj: c.JSValue, p: *c.JSObject) !void {
            // If the object has already been serialized, just write its ID.
            const find_result = try self.id_map.getOrPut(self.ac, p);
            if (find_result.found_existing) {
                try self.writeTag(.object_reference);
                try self.writeVarint(u32, find_result.value_ptr.* - 1);
                return;
            }

            // Otherwise, allocate an ID for it.
            const id = self.next_id;
            self.next_id += 1;
            find_result.value_ptr.* = id + 1;

            const class_id: z.JSClassId = @enumFromInt(c.JS_GetClassID(obj));

            // Eliminate callable and exotic objects, which should not be serialized.
            if (c.JS_IsFunction(self.ctx, obj) or isSpecialReceiverInstanceType(class_id)) {
                // Allow host objects to be delegated explicitly.
                if (!(try self.isHostObject(obj))) {
                    try self.throwDataCloneError();
                }
            }

            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            switch (class_id) {
                .array => {
                    try self.writeJSArray(obj);
                },
                .object => {
                    const is_host_object = try self.isHostObject(obj);
                    if (is_host_object) {
                        try self.writeHostObject(obj);
                    } else {
                        try self.writeJSObject(obj);
                    }
                },
                .date => {
                    try self.writeJSDate(obj);
                },
                .number, .string, .boolean, .big_int => {
                    try self.writeJSPrimitiveWrapper(obj);
                },
                .regexp => {
                    try self.writeJSRegExp(obj);
                },
                .map => {
                    try self.writeJSMap(.Map, obj);
                },
                .set => {
                    try self.writeJSMap(.Set, obj);
                },
                .array_buffer, .shared_array_buffer => {
                    try self.writeJSArrayBuffer(obj);
                },
                .uint8c_array, .int8_array, .uint8_array, .int16_array, .uint16_array, .int32_array, .uint32_array,
                .big_int64_array, .big_uint64_array, .float16_array, .float32_array, .float64_array, .dataview => {
                    try self.writeJSArrayBufferView(obj, class_id);
                },
                .@"error" => {
                    try self.writeJSError(obj);
                },
                else => {
                    try self.throwDataCloneError();
                },
            }
        }

        fn isSpecialReceiverInstanceType(class_id: z.JSClassId) bool {
            return switch (@intFromEnum(class_id)) {
                // TypedArrays + DataView are contiguous in QuickJS
                @intFromEnum(z.JSClassId.uint8c_array)...@intFromEnum(z.JSClassId.dataview) => false,
                else => switch (class_id) {
                    .object, .array, .date, .regexp,
                    .array_buffer, .shared_array_buffer,
                    .map, .set,
                    .number, .string, .boolean, .big_int,
                    .@"error" => false,
                    else => true,
                },
            };
        }

        fn writeJSObject(self: *Self, obj: c.JSValue) !void {
            // const raw_props: [*]z.JSShapeProperty = @ptrCast(&p.shape.prop);
            // const props = raw_props[0..@intCast(p.shape.prop_size)];

            // var properties_written: u32 = 0;
            // var is_pojo = true;

            // inline for (0..2) |pass| {
            //     if (is_pojo) {
            //         if (pass == 1) try self.writeTag(.BeginJSObject);
            //         for (props, 0..) |*prop, i| {
            //             const atom = prop.atom;
            //             const flags = prop.flags();
            //             if (atom != c.JS_ATOM_NULL and _js_atom_is_string(self.ctx, atom) == cTRUE and (flags & c.JS_PROP_ENUMERABLE) != 0) {
            //                 if (pass == 0 and (flags & c.JS_PROP_TMASK) != 0) {
            //                     is_pojo = false;
            //                     break;
            //                 }
            //                 if (pass == 1) {
            //                     const key = c.JS_AtomToValue(self.ctx, atom);
            //                     defer c.JS_FreeValue(self.ctx, key);

            //                     const value = p.prop[i].u.value;

            //                     try self.writeObject(key);
            //                     try self.writeObject(value);
            //                     properties_written += 1;
            //                 }
            //             }
            //         }
            //         if (pass == 1) try self.writeTag(.EndJSObject);
            //         if (pass == 1) try self.writeVarint(u32, properties_written);
            //     } else {
            //         try self.writeJSObjectSlow(.Object, obj);
            //     }
            // }
            try self.writeJSObjectOrSparseArraySlow(.Object, obj);
        }

        fn getOwnPropertyNames(self: *Self, obj: c.JSValue) ![]c.JSPropertyEnum {
            var prop_enum: [*c]c.JSPropertyEnum = undefined;
            var len: u32 = 0;
            if (c.JS_GetOwnPropertyNames(self.ctx, &prop_enum, &len, obj, c.JS_GPN_STRING_MASK | c.JS_GPN_ENUM_ONLY) != 0) {
                return Error.JSException;
            }
            return prop_enum[0..len];
        }

        fn writeJSObjectOrSparseArraySlow(self: *Self, comptime kind: ObjectOrArray, obj: c.JSValue) !void {
            var length: i64 = undefined;
            if (kind == .Array) if (c.JS_GetLength(self.ctx, obj, &length) != 0) try self.throwDataCloneError();

            const prop_enum = try self.getOwnPropertyNames(obj);
            defer c.JS_FreePropertyEnum(self.ctx, prop_enum.ptr, @intCast(prop_enum.len));

            try self.writeTag(if (kind == .Array) .begin_sparse_js_array else .begin_js_object);
            if (kind == .Array) try self.writeVarint(u32, @intCast(length));

            const properties_written = try self.writeJSObjectPropertiesSlow(obj, prop_enum);

            try self.writeTag(if (kind == .Array) .end_sparse_js_array else .end_js_object);
            try self.writeVarint(u32, properties_written);
            if (kind == .Array) try self.writeVarint(u32, @intCast(length)); // XXX: get length again?
        }

        fn writeArrayNonElementProps(self: *Self, arr: c.JSValue, length: u32) !u32 {
            var prop_enum: [*c]c.JSPropertyEnum = undefined;
            var len: u32 = 0;

            // Iterate over shape properties only
            if (_js_get_non_index_enumerable_string_keys_excluding(self.ctx, &prop_enum, &len, arr, length) != 0) {
                @branchHint(.unlikely);
                try self.throwDataCloneError();
            }
            if (len == 0) return 0; // nothing allocated, nothing to free
            defer c.JS_FreePropertyEnum(self.ctx, prop_enum, @intCast(len));

            var properties_written: u32 = 0;
            const props = prop_enum[0..len];

            for (props) |prop| {
                const key = c.JS_AtomToValue(self.ctx, prop.atom);
                defer c.JS_FreeValue(self.ctx, key);

                const value = c.JS_GetProperty(self.ctx, arr, prop.atom);
                try exceptionCheck(value);
                defer c.JS_FreeValue(self.ctx, value);

                // Guard against getters deleting the property
                const has_property = c.JS_HasProperty(self.ctx, arr, prop.atom);
                if (has_property < 0) return Error.JSException;
                if (has_property == cFALSE) continue;

                try self.writeObject(key);
                try self.writeObject(value);
                properties_written += 1;
            }

            return properties_written;
        }

        fn writeJSArray(self: *Self, obj: c.JSValue) !void {
            if (_js_is_fast_array(self.ctx, obj)) {
                var values: [*]c.JSValue = undefined;
                var length: u32 = undefined;
                _ = _js_get_fast_array(self.ctx, obj, &values, &length);
                try self.writeTag(.begin_dense_js_array);
                try self.writeVarint(u32, length);
                for (0..length) |i| {
                    const item = values[i];
                    switch (c.JS_VALUE_GET_NORM_TAG(item)) {
                        c.JS_TAG_INT => try self.writeSmi(item),
                        c.JS_TAG_FLOAT64 => try self.writeHeapNumber(item),
                        else => try self.writeObject(item),
                    }
                }

                // Write properties (i.e. non-numeric keys on an array)
                const properties_written = try self.writeArrayNonElementProps(obj, length);

                try self.writeTag(.end_dense_js_array);
                try self.writeVarint(u32, properties_written);
                try self.writeVarint(u32, length);
            } else {
                try self.writeJSObjectOrSparseArraySlow(.Array, obj);
            }
        }

        fn writeJSDate(self: *Self, obj: c.JSValue) !void {
            var date: c.JSValue = undefined;
            _ = _js_get_object_data(self.ctx, obj, &date);
            defer c.JS_FreeValue(self.ctx, date);
            try self.writeTag(.date);
            try self.writeDouble(c.JS_VALUE_GET_FLOAT64(date));
        }

        fn writeJSPrimitiveWrapper(self: *Self, obj: c.JSValue) !void {
            var value: c.JSValue = undefined;
            _ = _js_get_object_data(self.ctx, obj, &value);
            defer c.JS_FreeValue(self.ctx, value);

            const tag = c.JS_VALUE_GET_NORM_TAG(value);
            switch (tag) {
                c.JS_TAG_BOOL => try self.writeTag(if (c.JS_VALUE_GET_INT(value) == 0) .false_object else .true_object),
                c.JS_TAG_FLOAT64, c.JS_TAG_INT => {
                    const dbl: f64 = if (tag == c.JS_TAG_INT) @floatFromInt(c.JS_VALUE_GET_INT(value)) else c.JS_VALUE_GET_FLOAT64(value);
                    try self.writeTag(.number_object);
                    try self.writeDouble(dbl);
                },
                c.JS_TAG_BIG_INT => {
                    try self.writeTag(.big_int_object);
                    try self.writeBigIntContents(value);
                },
                c.JS_TAG_STRING => {
                    try self.writeTag(.string_object);
                    try self.writeString(@ptrCast(c.JS_VALUE_GET_PTR(value)));
                },
                else => {
                    @branchHint(.unlikely);
                    try self.throwDataCloneError();
                },
            }
        }

        fn writeJSRegExp(self: *Self, obj: c.JSValue) !void {
            const regexp = _js_get_regexp(self.ctx, obj, false);
            const bc = regexp.bytecode;
            std.debug.assert(_js_string_is_wide_char(bc) == false);

            const raw_bc = _js_string_get_str8(bc);
            const flags = c.lre_get_flags(raw_bc);

            var v8_flags = flags & 0b111; // first 3 falgs are identical (/gmi)
            if ((flags & c.LRE_FLAG_STICKY) != 0) v8_flags |= 1 << 3;
            if ((flags & c.LRE_FLAG_UNICODE) != 0) v8_flags |= 1 << 4;
            if ((flags & c.LRE_FLAG_DOTALL) != 0) v8_flags |= 1 << 5;

            try self.writeTag(.reg_exp);
            try self.writeString(regexp.pattern);
            try self.writeVarint(u32, @intCast(v8_flags));
        }

        fn writeJSMap(self: *Self, comptime as: SetOrMap, obj: c.JSValue) !void {
            const s = _js_get_map_state(self.ctx, obj, false);
            const length = s.record_count * (if (as == .Map) 2 else 1);

            var entries = try std.ArrayListUnmanaged(c.JSValue).initCapacity(self.ac, length);
            defer entries.deinit(self.ac);

            var el = s.records.next;
            while (el != &s.records) : (el = el.*.next) {
                const mr: *allowzero z.JSMapRecord = @alignCast(@fieldParentPtr("link", el));
                if (mr.empty == false) {
                    entries.appendAssumeCapacity(mr.key);
                    if (as == .Map) entries.appendAssumeCapacity(mr.value);
                }
            }

            try self.writeTag(if (as == .Map) .begin_js_map else .begin_js_set);
            for (entries.items) |entry| {
                try self.writeObject(entry);
            }
            try self.writeTag(if (as == .Map) .end_js_map else .end_js_set);
            try self.writeVarint(u32, length);
        }

        fn writeJSArrayBuffer(self: *Self, obj: c.JSValue) !void {
            var byte_length: usize = 0;
            const bytes = c.JS_GetArrayBuffer(self.ctx, &byte_length, obj);
            if (bytes == null) {
                @branchHint(.unlikely);
                try self.throwDataCloneErrorDetachedArrayBuffer();
            }

            // std.debug.print("HELLO?? {}\n", .{byte_length});
            try self.writeTag(.array_buffer);
            try self.writeVarint(u32, @intCast(byte_length));
            try self.writeRawBytes(bytes[0..@intCast(byte_length)]);
        }

        fn writeJSArrayBufferView(self: *Self, val: c.JSValue, class_id: z.JSClassId) !void {
            if (self.treat_array_buffer_views_as_host_objects) {
                return self.writeHostObject(val);
            }

            try self.writeTag(.array_buffer_view);

            const is_dataview = class_id == .dataview;
            const ab_val = if (is_dataview) _js_dataview_get_buffer(self.ctx, val) else _js_typed_array_get_buffer(self.ctx, val);
            try exceptionCheck(ab_val);
            defer c.JS_FreeValue(self.ctx, ab_val);

            const p: *c.JSObject = @ptrCast(c.JS_VALUE_GET_PTR(val));
            const byte_offset = _js_typed_array_get_byte_offset(p);
            const byte_length = _js_typed_array_get_byte_length(p);

            // XXX: out of bounds check?

            const tag: ArrayBufferViewTag = switch (class_id) {
                .uint8c_array => .uint8_clamped_array,
                .int8_array => .int8_array,
                .uint8_array => .uint8_array,
                .int16_array => .int16_array,
                .uint16_array => .uint16_array,
                .int32_array => .int32_array,
                .uint32_array => .uint32_array,
                .big_int64_array => .big_int64_array,
                .big_uint64_array => .big_uint64_array,
                .float16_array => .float16_array,
                .float32_array => .float32_array,
                .float64_array => .float64_array,
                .dataview => .data_view,
                else => unreachable,
            };

            try self.writeVarint(u32, @intFromEnum(tag));
            try self.writeVarint(u32, byte_offset);
            try self.writeVarint(u32, byte_length);
            // V8 has special flags for length tracking and resizable array buffer backing,
            // but QuickJS doesn't have equivalent features. In V8 these flags would be:
            // uint32_t flags =
            //      JSArrayBufferViewIsLengthTracking::encode(view->is_length_tracking()) |
            //      JSArrayBufferViewIsBackedByRab::encode(view->is_backed_by_rab());
            // For QuickJS compatibility, we'll just write 0 as the flags value
            try self.writeVarint(u32, 0);
        }

        fn writeErrorTag(self: *Self, tag: ErrorTag) !void {
            try self.writeVarint(u32, @intFromEnum(tag));
        }

        fn writeJSError(self: *Self, obj: c.JSValue) !void {
            var message_desc: c.JSPropertyDescriptor = undefined;
            const message = c.JS_NewAtom(self.ctx, "message");
            defer c.JS_FreeAtom(self.ctx, message);
            const message_found = c.JS_GetOwnProperty(self.ctx, &message_desc, obj, message) == cTRUE;
            defer if (message_found) c.JS_FreeValue(self.ctx, message_desc.value);

            var cause_desc: c.JSPropertyDescriptor = undefined;
            const cause = c.JS_NewAtom(self.ctx, "cause");
            defer c.JS_FreeAtom(self.ctx, cause);
            const cause_found = c.JS_GetOwnProperty(self.ctx, &cause_desc, obj, cause) == cTRUE;
            defer if (cause_found) c.JS_FreeValue(self.ctx, cause_desc.value);

            try self.writeTag(.@"error");

            const name_object = c.JS_GetPropertyStr(self.ctx, obj, "name");
            try exceptionCheck(name_object);
            defer c.JS_FreeValue(self.ctx, name_object);

            const name_cstr = c.JS_ToCString(self.ctx, name_object);
            if (name_cstr == null) {
                @branchHint(.unlikely);
                return Error.JSException;
            }
            defer c.JS_FreeCString(self.ctx, name_cstr);

            const name = std.mem.span(name_cstr);
            if (std.mem.eql(u8, name, "EvalError")) {
                try self.writeErrorTag(.eval_error_prototype);
            } else if (std.mem.eql(u8, name, "RangeError")) {
                try self.writeErrorTag(.range_error_prototype);
            } else if (std.mem.eql(u8, name, "ReferenceError")) {
                try self.writeErrorTag(.reference_error_prototype);
            } else if (std.mem.eql(u8, name, "SyntaxError")) {
                try self.writeErrorTag(.syntax_error_prototype);
            } else if (std.mem.eql(u8, name, "TypeError")) {
                try self.writeErrorTag(.type_error_prototype);
            } else if (std.mem.eql(u8, name, "URIError")) {
                try self.writeErrorTag(.uri_error_prototype);
            } else {
                // The default prototype in the deserialization side is Error.prototype, so
                // we don't have to do anything here.
            }

            if (message_found) {
                try self.writeErrorTag(.message);
                try self.writeString(@ptrCast(c.JS_VALUE_GET_PTR(message_desc.value)));
            }

            const stack = c.JS_NewAtom(self.ctx, "stack");
            defer c.JS_FreeAtom(self.ctx, stack);
            const stack_val = c.JS_GetProperty(self.ctx, obj, stack);
            try exceptionCheck(stack_val);
            defer c.JS_FreeValue(self.ctx, stack_val);
            if (c.JS_IsString(stack_val)) {
                try self.writeErrorTag(.stack);
                try self.writeString(@ptrCast(c.JS_VALUE_GET_PTR(stack_val)));
            }

            if (cause_found) {
                try self.writeErrorTag(.cause);
                try self.writeObject(cause_desc.value);
            }

            try self.writeErrorTag(.end);
        }

        fn writeHostObject(self: *Self, val: c.JSValue) !void {
            // Let delegate perform any custom serialization. If it throws, roll back.
            const saved_len = self.buffer.items.len;
            errdefer self.buffer.items.len = saved_len;
            if (self.delegate) |del| {
                try self.writeTag(.host_object);
                try del.writeHostObject(self.ctx, val);
            } else {
                return Error.NotImplemented;
            }
        }

        fn writeJSObjectPropertiesSlow(self: *Self, obj: c.JSValue, prop_enum: []c.JSPropertyEnum) !u32 {
            var properties_written: u32 = 0;

            for (prop_enum) |prop| {
                if (prop.is_enumerable == false) continue;
                const key = c.JS_AtomToValue(self.ctx, prop.atom);
                defer c.JS_FreeValue(self.ctx, key);
                const value = c.JS_GetProperty(self.ctx, obj, prop.atom);
                try exceptionCheck(value);
                defer c.JS_FreeValue(self.ctx, value);

                // If the property is no longer found, do not serialize it.
                // This could happen if a getter deleted the property.
                const has_property = c.JS_HasProperty(self.ctx, obj, prop.atom);
                if (has_property < 0) return Error.JSException;
                if (has_property == cFALSE) continue;

                try self.writeObject(key);
                try self.writeObject(value);
                properties_written += 1;
            }

            return properties_written;
        }

        fn isHostObject(self: *Self, val: c.JSValue) !bool {
            if (!self.has_custom_objects) return false;
            return if (self.delegate) |del| try del.isHostObject(self.ctx, val) else return Error.NotImplemented;
        }

        fn throwDataCloneErrorMsg(self: *Self, comptime msg: []const u8) !noreturn {
            if (self.delegate) |del| {
                try del.throwDataCloneError(self.ctx, msg);
            } else {
                _ = c.JS_ThrowTypeError(self.ctx, msg.ptr);
            }
            return Error.DataCloneError;
        }

        fn throwDataCloneError(self: *Self) !noreturn {
            return self.throwDataCloneErrorMsg("Data clone error");
        }

        fn throwDataCloneErrorDetachedArrayBuffer(self: *Self) !noreturn {
            return self.throwDataCloneErrorMsg("ArrayBuffer is detached");
        }
    };
}

/// A V8 compatible deserializer for QuickJS values.
pub fn Deserializer(comptime Delegate: type) type {
    // FIXME: comptime validate delegate type
    return struct {
        ac: std.mem.Allocator,
        ctx: ?*c.JSContext,
        js_view: c.JSValue,
        data: []const u8,
        position: usize = 0,
        version: ?u32 = undefined,
        next_id: u32 = 0,
        version_13_broken_data_mode: bool = false,
        suppress_deserialization_errors: bool = false,
        id_map: std.AutoHashMapUnmanaged(u32, c.JSValue),
        // array_buffer_transfer_map: *anyopaque = null,
        // shared_object_conveyor: *anyopaque = null,
        delegate: ?Delegate,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: ?*c.JSContext, buffer_view: c.JSValue, delegate: ?Delegate) !Self {
            const slice = try arrayBufferViewToSlice(ctx, buffer_view);
            return Self{
                .ac = allocator,
                .ctx = ctx,
                .js_view = c.JS_DupValue(ctx, buffer_view), // XXX: should probably create our own view
                .data = slice,
                .id_map = .empty,
                .delegate = delegate,
            };
        }

        pub fn deinit(self: *Self) void {
            self.id_map.deinit(self.ac);
            c.JS_FreeValue(self.ctx, self.js_view);
        }

        pub fn readHeader(self: *Self) !bool {
            if (try self.peekTag() == .version) {
                try self.consumeTag(.version);
                const version = try self.readVarint(u32);
                if (version > kLatestVersion) {
                    try self.throwDataCloneDeserializationVersionError();
                }
                self.version = version;
            }
            return true;
        }

        fn peekTag(self: *Self) !?SerializationTag {
            var peek_position = self.position;
            var tag: SerializationTag = .padding;
            while (tag == .padding) {
                if (peek_position >= self.data.len) return null;
                tag = @enumFromInt(self.data[peek_position]);
                peek_position += 1;
            }
            return tag;
        }

        fn consumeTag(self: *Self, tag: ?SerializationTag) !void {
            const actual_tag = self.readTag();
            if (tag == null or actual_tag != tag) try self.throwDataCloneDeserializationError();
        }

        fn readTag(self: *Self) ?SerializationTag {
            var tag: SerializationTag = .padding;
            while (tag == .padding) {
                if (self.position >= self.data.len) return null;
                tag = @enumFromInt(self.data[self.position]);
                self.position += 1;
            }
            return tag;
        }

        fn readVarint(self: *Self, comptime T: type) !T {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .unsigned) {
                    @compileError("Only unsigned integer types can be read from varints.");
                }
            }
            var value: T = 0;
            const ShiftT = ShiftTypeOf(T);
            var shift: ShiftT = 0;
            var has_another_byte: bool = true;
            while (has_another_byte) {
                if (self.position >= self.data.len) {
                    @branchHint(.unlikely);
                    try self.throwDataCloneDeserializationError();
                }
                const byte = self.data[self.position];
                has_another_byte = (byte & 0x80) != 0;
                if (shift < @sizeOf(T) * 8) {
                    const x: T = @intCast(byte & 0x7F);
                    value |= x << shift;
                    shift +%= 7; // allow wraparound since result isn't used anyway
                } else {
                    if (has_another_byte) try self.throwDataCloneDeserializationError();
                    return value;
                }
                self.position += 1;
            }
            return value;
        }

        fn readZigZag(self: *Self, comptime T: type) !T {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .int or type_info.int.signedness != .signed) {
                    @compileError("Only signed integer types can be read as zigzag.");
                }
            }
            const UnsignedT = @Type(.{ .int = .{ .bits = @typeInfo(T).int.bits, .signedness = .unsigned } });
            const unsigned_value: UnsignedT = try self.readVarint(UnsignedT);
            const a: T = @intCast(unsigned_value >> 1);
            const b: T = @intCast(unsigned_value & 1);
            return a ^ -b;
        }

        pub fn readDouble(self: *Self) !f64 {
            if (self.position + @sizeOf(f64) > self.data.len) try self.throwDataCloneDeserializationError();
            const f64_bytes = self.data[self.position .. self.position + @sizeOf(f64)];
            const value = std.mem.bytesAsValue(f64, f64_bytes).*;
            self.position += @sizeOf(f64);
            return value;
        }

        pub fn readRawBytes(self: *Self, length: usize) ![]const u8 {
            if (self.position + length > self.data.len) try self.throwDataCloneDeserializationError();
            const slice = self.data[self.position .. self.position + length];
            self.position += length;
            return slice;
        }

        pub fn readByte(self: *Self) !u8 {
            // std.debug.print("data: {any}, {}\n", .{ self.data, self.position });
            if (self.data.len - self.position < @sizeOf(u8)) try self.throwDataCloneDeserializationError();
            const byte = self.data[self.position];
            self.position += 1;
            return byte;
        }

        pub fn readUint32(self: *Self) !u32 {
            return try self.readVarint(u32);
        }

        pub fn readUint64(self: *Self) !u64 {
            return try self.readVarint(u64);
        }

        pub fn readObject(self: *Self) Error!c.JSValue {
            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const result = try self.readObjectInternal();
            errdefer c.JS_FreeValue(self.ctx, result);

            // ArrayBufferView is special in that it consumes the value before it, even
            // after format version 0.
            if (c.JS_IsArrayBuffer(result)) {
                @branchHint(.unlikely);
                const tag = try self.peekTag();
                if (tag == .array_buffer_view) {
                    try self.consumeTag(.array_buffer_view);
                    defer c.JS_FreeValue(self.ctx, result); // XXX: chance of double free here?
                    return try self.readJSArrayBufferView(result);
                }
            }

            return result;
        }

        fn readObjectInternal(self: *Self) !c.JSValue {
            if (self.readTag()) |tag| switch (tag) {
                .verify_object_count => {
                    // Read the count and ignore it.
                    _ = try self.readVarint(u32);
                    return self.readObject();
                },
                .undefined => return z.JS_UNDEFINED,
                .null => return z.JS_NULL,
                .true => return z.JS_TRUE,
                .false => return z.JS_FALSE,
                .int32 => {
                    const value = try self.readZigZag(i32);
                    return c.JS_NewInt32(self.ctx, value);
                },
                .uint32 => {
                    const value = try self.readVarint(u32);
                    return c.JS_NewUint32(self.ctx, value);
                },
                .double => {
                    const value = try self.readDouble();
                    return c.JS_NewFloat64(self.ctx, value);
                },
                .big_int => {
                    return self.readBigInt();
                },
                .utf8_string => {
                    return self.readUtf8String();
                },
                .one_byte_string => {
                    return self.readOneByteString();
                },
                .two_byte_string => {
                    return self.readTwoByteString();
                },
                .object_reference => {
                    const id = try self.readVarint(u32);
                    return self.getObjectWithID(id);
                },
                .begin_js_object => {
                    return self.readJSObject();
                },
                .begin_sparse_js_array => {
                    return self.readSparseJSArray();
                },
                .begin_dense_js_array => {
                    return self.readDenseJSArray();
                },
                .date => {
                    return self.readJSDate();
                },
                .true_object, .false_object, .number_object, .big_int_object, .string_object => |t| {
                    return self.readJSPrimitiveWrapper(t);
                },
                .reg_exp => {
                    return self.readJSRegExp();
                },
                .begin_js_map => {
                    return self.readJSMap(.Map);
                },
                .begin_js_set => {
                    return self.readJSMap(.Set);
                },
                .array_buffer => {
                    const is_shared = false;
                    const is_resizable = false;
                    return self.readJSArrayBuffer(is_shared, is_resizable);
                },
                // .shared_array_buffer => {
                //     const is_shared = false;
                //     const is_resizable = true;
                //     return self.readJSArrayBuffer(is_shared, is_resizable);
                // },
                .@"error" => {
                    return self.readJSError();
                },
                .host_object => {
                    return self.readHostObject();
                },
                else => {
                    if (self.version) |v| if (v < 13) {
                        self.position -= 1;
                        return self.readObject();
                    };
                    try self.throwDataCloneDeserializationError();
                },
            } else {
                try self.throwDataCloneDeserializationError();
            }
        }

        fn readString(self: *Self) !c.JSValue {
            if (self.version.? < 12) return self.readUtf8String();
            const object = try self.readObject();
            if (!c.JS_IsString(object)) try self.throwDataCloneDeserializationError();
            return object;
        }

        fn bigIntFromSerializedDigits(self: *Self, sign_bit: u1, digits_store: []const u8) !c.JSValue {
            if (digits_store.len == 0) {
                if (_js_bigint_from_string(self.ctx, "0", 16)) |r| {
                    const ret = _js_compact_bigint(self.ctx, r);
                    try exceptionCheck(ret);
                    return ret;
                } else {
                    try self.throwDataCloneDeserializationError();
                }
            }

            var hex = try std.ArrayListUnmanaged(u8).initCapacity(self.ac, 2 + digits_store.len * 2);
            defer hex.deinit(self.ac);

            if (sign_bit == 1) try hex.append(self.ac, @as(u8, '-'));

            var i = digits_store.len;
            while (i > 0) {
                i -= 1;
                const byte = digits_store[i];
                try hex.append(self.ac, @as(u8, "0123456789abcdef"[byte >> 4]));
                try hex.append(self.ac, @as(u8, "0123456789abcdef"[byte & 0xf]));
            }
            try hex.append(self.ac, 0);

            const slice = try hex.toOwnedSlice(self.ac);
            defer self.ac.free(slice);
            // std.debug.print("\nstr: {s}\n", .{slice});

            if (_js_bigint_from_string(self.ctx, slice.ptr, 16)) |r| {
                const bigint = _js_compact_bigint(self.ctx, r);
                try exceptionCheck(bigint);
                return bigint;
            } else {
                try self.throwDataCloneDeserializationError();
            }
        }

        fn readBigInt(self: *Self) !c.JSValue {
            const bitfield = try self.readVarint(u32);
            const sign_bit: u1 = @intCast(bitfield & 1);
            const byte_length: u31 = @intCast(bitfield >> 1);
            const digits_store = try self.readRawBytes(@intCast(byte_length));
            return self.bigIntFromSerializedDigits(sign_bit, digits_store);
        }

        fn readUtf8String(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(length);
            const val = c.JS_NewStringLen(self.ctx, bytes.ptr, length);
            try exceptionCheck(val);
            return val;
        }

        fn readOneByteString(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(length);
            const val = _js_new_string8_len(self.ctx, bytes.ptr, @intCast(length));
            try exceptionCheck(val);
            return val;
        }

        fn readTwoByteString(self: *Self) !c.JSValue {
            const byte_length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(byte_length);
            const c_length: c_int = @intCast(byte_length / @sizeOf(u16));
            const ret = if (!std.mem.isAligned(@intFromPtr(bytes.ptr), 2)) ret: {
                const aligned_bytes = try self.ac.alignedAlloc(u8, std.mem.Alignment.@"2", byte_length);
                defer self.ac.free(aligned_bytes);
                @memcpy(aligned_bytes, bytes);
                const bytes_u16: []const u16 = @ptrCast(aligned_bytes);
                break :ret _js_new_string16_len(self.ctx, bytes_u16.ptr, c_length);
            } else ret: {
                const bytes_u16: []const u16 = @alignCast(@ptrCast(bytes));
                break :ret _js_new_string16_len(self.ctx, bytes_u16.ptr, c_length);
            };
            try exceptionCheck(ret);
            return ret;
        }

        fn readJSObject(self: *Self) !c.JSValue {
            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const id = self.next_id;
            self.next_id += 1;

            const object = c.JS_NewObject(self.ctx);
            try exceptionCheck(object);
            errdefer c.JS_FreeValue(self.ctx, object);

            try self.addObjectWithID(id, object);

            const num_properties = try self.readJSObjectProperties(object, .end_js_object);
            const expected_num_properties = try self.readVarint(u32);
            if (num_properties != expected_num_properties) try self.throwDataCloneDeserializationError();

            std.debug.assert(self.hasObjectWithID(id));
            return object;
        }

        fn readJSObjectProperties(self: *Self, object: c.JSValue, end_tag: SerializationTag) !u32 {
            var num_properties: u32 = 0;
            while (true) : (num_properties += 1) {
                const tag = try self.peekTag();
                if (tag == end_tag) {
                    try self.consumeTag(end_tag);
                    return num_properties;
                }

                const key = try self.readObject();
                defer c.JS_FreeValue(self.ctx, key);

                const property_key = c.JS_ToPropertyKey(self.ctx, key);
                try exceptionCheck(property_key);
                defer c.JS_FreeValue(self.ctx, key);

                const value = try self.readObject();
                errdefer c.JS_FreeValue(self.ctx, value); // XXX: not good enough

                const atom = c.JS_ValueToAtom(self.ctx, property_key);
                defer c.JS_FreeAtom(self.ctx, atom);

                // if the property already exists, something went wrong (probably getter/setter modified the object)
                const has_property = c.JS_HasProperty(self.ctx, object, atom);
                if (has_property < 0) return Error.JSException;
                if (has_property == cTRUE) try self.throwDataCloneDeserializationError();

                const code = c.JS_DefinePropertyValue(self.ctx, object, atom, value, c.JS_PROP_C_W_E);
                if (code < 0) return Error.JSException;
            }
        }

        fn readSparseJSArray(self: *Self) !c.JSValue {
            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const length = try self.readVarint(u32);

            const id = self.next_id;
            self.next_id += 1;

            const array = c.JS_NewArray(self.ctx);
            try exceptionCheck(array);
            errdefer c.JS_FreeValue(self.ctx, array);

            try self.addObjectWithID(id, array);

            const num_properties = try self.readJSObjectProperties(array, .end_sparse_js_array);
            const expected_num_properties = try self.readVarint(u32);
            const expected_length = try self.readVarint(u32);
            if (num_properties != expected_num_properties or length != expected_length) try self.throwDataCloneDeserializationError();

            std.debug.assert(self.hasObjectWithID(id));
            return array;
        }

        fn readDenseJSArray(self: *Self) !c.JSValue {
            try stackCheck(self.ctx);

            const length = try self.readVarint(u32);
            if (length > self.data.len - self.position) try self.throwDataCloneDeserializationError();

            const id = self.next_id;
            self.next_id += 1;

            const array = c.JS_NewArray(self.ctx);
            try exceptionCheck(array);
            errdefer c.JS_FreeValue(self.ctx, array);

            try self.addObjectWithID(id, array);

            var idx: u32 = 0;
            while (idx < length) : (idx += 1) {
                const tag = try self.peekTag();
                if (tag == .the_hole) {
                    try self.consumeTag(.the_hole);
                    continue;
                }

                const element = try self.readObject();
                errdefer c.JS_FreeValue(self.ctx, element);

                // Serialization versions less than 11 encode the hole the same as
                // undefined. For consistency with previous behavior, store these as the
                // hole. Past version 11, undefined means undefined.
                if (self.version.? < 11 and c.JS_IsUndefined(element)) continue;

                const code = c.JS_DefinePropertyValueUint32(self.ctx, array, idx, element, c.JS_PROP_C_W_E);
                if (code < 0) return Error.JSException;
            }

            const num_properties = try self.readJSObjectProperties(array, .end_dense_js_array);
            const expected_num_properties = try self.readVarint(u32);
            const expected_length = try self.readVarint(u32);
            if (num_properties != expected_num_properties or length != expected_length) try self.throwDataCloneDeserializationError();
            std.debug.assert(self.hasObjectWithID(id));
            return array;
        }

        fn readJSDate(self: *Self) !c.JSValue {
            const value = try self.readDouble();
            const id: u32 = self.next_id;
            self.next_id += 1;
            const date = c.JS_NewDate(self.ctx, value);
            try exceptionCheck(date);
            try self.addObjectWithID(id, date);
            return date;
        }

        fn readJSPrimitiveWrapper(self: *Self, tag: SerializationTag) !c.JSValue {
            const id: u32 = self.next_id;
            self.next_id += 1;
            const value: c.JSValue = switch (tag) {
                .true_object => c.JS_ToObject(self.ctx, z.JS_TRUE),
                .false_object => c.JS_ToObject(self.ctx, z.JS_FALSE),
                .number_object => blk: {
                    const double = try self.readDouble();
                    const js_num = c.JS_NewFloat64(self.ctx, double);
                    defer c.JS_FreeValue(self.ctx, js_num);
                    break :blk c.JS_ToObject(self.ctx, js_num);
                },
                .big_int_object => blk: {
                    const bigint = try self.readBigInt();
                    defer c.JS_FreeValue(self.ctx, bigint);
                    break :blk c.JS_ToObject(self.ctx, bigint);
                },
                .string_object => blk: {
                    const js_str = try self.readString();
                    defer c.JS_FreeValue(self.ctx, js_str);
                    break :blk c.JS_ToObject(self.ctx, js_str);
                },
                else => unreachable,
            };
            try exceptionCheck(value);
            try self.addObjectWithID(id, value);
            return value;
        }

        inline fn appendChar(arr: []u8, len: *usize, ch: u8) void {
            arr[len.*] = ch;
            len.* += 1;
        }

        fn readJSRegExp(self: *Self) !c.JSValue {
            const id: u32 = self.next_id;
            self.next_id += 1;
            const pattern = try self.readString();
            defer c.JS_FreeValue(self.ctx, pattern);
            const v8_flags = try self.readVarint(u32);

            var flags: [6]u8 = undefined;
            var flags_len: usize = 0;
            if ((v8_flags & (1 << 0)) != 0) appendChar(&flags, &flags_len, 'g'); // global
            if ((v8_flags & (1 << 1)) != 0) appendChar(&flags, &flags_len, 'i'); // ignoreCase
            if ((v8_flags & (1 << 2)) != 0) appendChar(&flags, &flags_len, 'm'); // multiline
            if ((v8_flags & (1 << 3)) != 0) appendChar(&flags, &flags_len, 'y'); // sticky
            if ((v8_flags & (1 << 4)) != 0) appendChar(&flags, &flags_len, 'u'); // unicode
            if ((v8_flags & (1 << 5)) != 0) appendChar(&flags, &flags_len, 's'); // dotAll

            const global = c.JS_GetGlobalObject(self.ctx);
            defer c.JS_FreeValue(self.ctx, global);

            const regexp_constructor = c.JS_GetPropertyStr(self.ctx, global, "RegExp");
            try exceptionCheck(regexp_constructor);
            defer c.JS_FreeValue(self.ctx, regexp_constructor);

            const flag_str = c.JS_NewStringLen(self.ctx, &flags, flags_len);
            try exceptionCheck(flag_str);
            defer c.JS_FreeValue(self.ctx, flag_str);

            var argv = [_]c.JSValue{ pattern, flag_str };
            const regexp = c.JS_CallConstructor(self.ctx, regexp_constructor, 2, &argv);
            try exceptionCheck(regexp);
            errdefer c.JS_FreeValue(self.ctx, regexp);

            try self.addObjectWithID(id, regexp);
            return regexp;
        }

        fn readJSMap(self: *Self, comptime kind: SetOrMap) !c.JSValue {
            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const id = self.next_id;
            self.next_id += 1;

            const global = c.JS_GetGlobalObject(self.ctx);
            defer c.JS_FreeValue(self.ctx, global);
            const map_constructor = c.JS_GetPropertyStr(self.ctx, global, if (kind == .Map) "Map" else "Set");
            try exceptionCheck(map_constructor);
            defer c.JS_FreeValue(self.ctx, map_constructor);

            const map = c.JS_CallConstructor(self.ctx, map_constructor, 0, null);
            try exceptionCheck(map);
            errdefer c.JS_FreeValue(self.ctx, map);

            try self.addObjectWithID(id, map);

            const set_func = c.JS_GetPropertyStr(self.ctx, map, if (kind == .Map) "set" else "add");
            try exceptionCheck(set_func);
            defer c.JS_FreeValue(self.ctx, set_func);

            var length: u32 = 0;
            while (true) {
                const tag = try self.peekTag();
                if (tag == if (kind == .Map) .end_js_map else .end_js_set) {
                    try self.consumeTag(tag);
                    break;
                }

                var argv: [2]c.JSValue = undefined;
                argv[0] = try self.readObject();
                defer c.JS_FreeValue(self.ctx, argv[0]);
                if (kind == .Map) argv[1] = try self.readObject();
                defer if (kind == .Map) c.JS_FreeValue(self.ctx, argv[1]);

                const result = c.JS_Call(self.ctx, set_func, map, if (kind == .Map) 2 else 1, &argv);
                try exceptionCheck(result);
                defer c.JS_FreeValue(self.ctx, result);

                length += if (kind == .Map) 2 else 1;
            }

            const expected_length = try self.readVarint(u32);
            if (length != expected_length) try self.throwDataCloneDeserializationError();
            std.debug.assert(self.hasObjectWithID(id));
            return map;
        }

        fn readJSArrayBuffer(self: *Self, is_shared: bool, is_resizable: bool) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            if (is_shared) {
                // TODO:
                // uint32_t clone_id;
                // Local<SharedArrayBuffer> sab_value;
                // if (!ReadVarint<uint32_t>().To(&clone_id) || delegate_ == nullptr ||
                //     !delegate_
                //             ->GetSharedArrayBufferFromId(
                //                 reinterpret_cast<v8::Isolate*>(isolate_), clone_id)
                //             .ToLocal(&sab_value)) {
                //     RETURN_EXCEPTION_IF_EXCEPTION(isolate_);
                //     return MaybeHandle<JSArrayBuffer>();
                // }
                // Handle<JSArrayBuffer> array_buffer = Utils::OpenHandle(*sab_value);
                // DCHECK_EQ(is_shared, array_buffer->is_shared());
                // AddObjectWithID(id, array_buffer);
                // return array_buffer;
            }

            const byte_length = try self.readVarint(u32);
            if (is_resizable) {
                const max_byte_length = try self.readVarint(u32);
                if (byte_length > max_byte_length) try self.throwDataCloneDeserializationError();
            }

            const bytes = try self.readRawBytes(byte_length);
            const result = c.JS_NewArrayBufferCopy(self.ctx, bytes.ptr, byte_length);
            try exceptionCheck(result);
            errdefer c.JS_FreeValue(self.ctx, result);

            try self.addObjectWithID(id, result);
            return result;
        }

        fn readJSArrayBufferView(self: *Self, ab_val: c.JSValue) !c.JSValue {
            var buffer_byte_length: usize = undefined;
            _ = c.JS_GetArrayBuffer(self.ctx, &buffer_byte_length, ab_val);

            const tag = try self.readVarint(u8);
            const byte_offset = try self.readVarint(u32);
            const byte_length = try self.readVarint(u32);
            if (byte_offset > buffer_byte_length or byte_length > buffer_byte_length - byte_offset) {
                try self.throwDataCloneDeserializationError();
            }

            const should_read_flags = self.version.? >= 14 or self.version_13_broken_data_mode;
            const flags = if (should_read_flags) try self.readVarint(u32) else 0;
            _ = flags; // TODO: can we even use this in qjs?

            const id = self.next_id;
            self.next_id += 1;

            const tag_enum: ArrayBufferViewTag = @enumFromInt(tag);
            const class_id: z.JSClassId, const element_size: u32 = switch (tag_enum) {
                .uint8_clamped_array => .{ .uint8c_array, 1 },
                .int8_array => .{ .int8_array, 1 },
                .uint8_array => .{ .uint8_array, 1 },
                .int16_array => .{ .int16_array, 2 },
                .uint16_array => .{ .uint16_array, 2 },
                .int32_array => .{ .int32_array, 4 },
                .uint32_array => .{ .uint32_array, 4 },
                .big_int64_array => .{ .big_int64_array, 8 },
                .big_uint64_array => .{ .big_uint64_array, 8 },
                .float16_array => .{ .float16_array, 2 },
                .float32_array => .{ .float32_array, 4 },
                .float64_array => .{ .float64_array, 8 },
                .data_view => .{ .dataview, 1 },
                else => try self.throwDataCloneDeserializationError(),
            };

            if (byte_offset % element_size != 0 or byte_length % element_size != 0) try self.throwDataCloneDeserializationError();

            //   bool is_length_tracking = false;
            //   bool is_backed_by_rab = false;
            //   if (!ValidateJSArrayBufferViewFlags(*buffer, flags, is_length_tracking, is_backed_by_rab)) {
            //     return MaybeHandle<JSArrayBufferView>();
            //   }

            var argv: [3]c.JSValue = undefined;
            argv[0] = ab_val;
            argv[1] = c.JS_NewUint32(self.ctx, byte_offset);
            argv[2] = c.JS_NewUint32(self.ctx, byte_length / element_size);
            defer c.JS_FreeValue(self.ctx, argv[1]);
            defer c.JS_FreeValue(self.ctx, argv[2]);
            const obj = if (tag_enum == .data_view)
                _js_dataview_constructor(self.ctx, z.JS_UNDEFINED, 3, &argv)
            else
                c.JS_NewTypedArray(self.ctx, 3, &argv, @intFromEnum(class_id) - @intFromEnum(z.JSClassId.uint8c_array));
            try exceptionCheck(obj);
            errdefer c.JS_FreeValue(self.ctx, obj);

            try self.addObjectWithID(id, obj);
            return obj;
        }

        fn readJSError(self: *Self) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            var tag: ErrorTag = @enumFromInt(try self.readVarint(u8));

            var error_num: z.JSErrorEnum = undefined;
            switch (tag) {
                .eval_error_prototype => {
                    error_num = .eval_error;
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .range_error_prototype => {
                    error_num = .range_error;
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .reference_error_prototype => {
                    error_num = .reference_error;
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .syntax_error_prototype => {
                    error_num = .syntax_error;
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .type_error_prototype => {
                    error_num = .type_error;
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .uri_error_prototype => {
                    error_num = .uri_error;
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                else => {
                    error_num = .plain_error;
                },
            }

            var message: ?c.JSValue = null;
            if (tag == .message) {
                message = try self.readString();
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (message) |x| c.JS_FreeValue(self.ctx, x);

            var stack: ?c.JSValue = null;
            if (tag == .stack) {
                stack = try self.readString();
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (stack) |x| c.JS_FreeValue(self.ctx, x);

            const err_obj = JS_MakeError2(self.ctx, error_num, false, "");
            try exceptionCheck(err_obj);
            errdefer c.JS_FreeValue(self.ctx, err_obj);

            try self.addObjectWithID(id, err_obj);

            const no_enum = c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE;

            if (stack) |x| if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "stack", x, no_enum) < 0) {
                try self.throwDataCloneDeserializationError();
            };
            if (message) |x| if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "message", x, no_enum) < 0) {
                try self.throwDataCloneDeserializationError();
            };

            var cause: ?c.JSValue = null;
            if (tag == .cause) {
                cause = try self.readObject();
                if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "cause", cause.?, no_enum) < 0) {
                    try self.throwDataCloneDeserializationError();
                }
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (cause) |x| c.JS_FreeValue(self.ctx, x);

            if (tag != .end) try self.throwDataCloneDeserializationError();
            return err_obj;
        }

        fn readHostObject(self: *Self) !c.JSValue {
            try stackCheck(self.ctx);
            const id = self.next_id;
            self.next_id += 1;
            const obj: c.JSValue = if (self.delegate) |del| try del.readHostObject(self.ctx) else return Error.NotImplemented;
            errdefer c.JS_FreeValue(self.ctx, obj);
            try self.addObjectWithID(id, obj);
            return obj;
        }

        fn hasObjectWithID(self: *Self, id: u32) bool {
            return self.id_map.contains(id);
        }

        fn getObjectWithID(self: *Self, id: u32) !c.JSValue {
            if (id >= self.id_map.count()) try self.throwDataCloneDeserializationError();
            const value = self.id_map.get(id);
            if (value == null or !c.JS_IsObject(value.?)) try self.throwDataCloneDeserializationError();
            return value.?;
        }

        fn addObjectWithID(self: *Self, id: u32, value: c.JSValue) !void {
            std.debug.assert(!self.hasObjectWithID(id));
            try self.id_map.put(self.ac, id, value);
        }

        fn throwDataCloneDeserializationError(self: *Self) !noreturn {
            if (self.delegate) |del| {
                try del.throwDataCloneError(self.ctx, "Data clone deserialization error");
            } else {
                _ = c.JS_ThrowTypeError(self.ctx, "Data clone deserialization error");
            }
            return Error.DataCloneDeserializationError;
        }

        fn throwDataCloneDeserializationVersionError(self: *Self) !noreturn {
            if (self.delegate) |del| {
                try del.throwDataCloneError(self.ctx, "Data clone deserialization version error");
            } else {
                _ = c.JS_ThrowTypeError(self.ctx, "Data clone deserialization version error");
            }
            return Error.DataCloneDeserializationVersionError;
        }
    };
}

pub const DefaultSerializer = Serializer(DefaultDelegate);
pub const DefaultDeserializer = Deserializer(DefaultDelegate);
