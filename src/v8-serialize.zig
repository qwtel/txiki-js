const std = @import("std");
const builtin = @import("builtin");

pub const z = @import("v8-qjs-structs.zig");
pub const c = z.c;

const QJSAllocator = @import("v8-qjs-allocator.zig").QJSAllocator;

// A bunch of qjs iternal functions that we've stripped `static` from. They're not part of the header, so we have to declare them here.
extern fn JS_CheckStackOverflow(rt: *c.JSRuntime, alloca_size: usize) c_int;
extern fn JS_AtomIsString(ctx: ?*c.JSContext, v: c.JSAtom) c_int;
extern fn JS_ToObject(ctx: ?*c.JSContext, v: c.JSValue) c.JSValue;
extern fn js_alloc_string(ctx: ?*c.JSContext, max_len: c_int, is_wide_char: c_int) ?*z.JSString;
extern fn js_new_string8_len(ctx: ?*c.JSContext, buf: [*c]const u8, len: c_int) c.JSValue;
extern fn js_new_string16_len(ctx: ?*c.JSContext, buf: [*c]const u16, len: c_int) c.JSValue;
extern fn js_string_to_bigint(ctx: ?*c.JSContext, buf: [*c]const u8, radix: c_int) c.JSValue;
extern fn js_regexp_constructor_internal(ctx: ?*c.JSContext, ctor: c.JSValue, pattern: c.JSValue, bc: c.JSValue) c.JSValue;
extern fn js_typed_array_constructor(ctx: ?*c.JSContext, new_target: c.JSValue, argc: c_int, argv: [*c]c.JSValue, classid: c_int) c.JSValue;
extern fn js_dataview_constructor(ctx: ?*c.JSContext, new_target: c.JSValue, argc: c_int, argv: [*c]c.JSValue) c.JSValue;

const kLatestVersion = 15;

fn bytesNeededForVarint(comptime T: type, value: T) usize {
    comptime {
        const type_info = @typeInfo(T);
        if (type_info != .Int or type_info.Int.signedness != .unsigned) {
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

/// A rightshift for u64 slices that can shift by more than 64 bits.
fn shiftRightN(values: []u64, n: usize) void {
    const m = n / 64; // Number of full u64 shifts
    const n_bits: u6 = @intCast(n % 64); // Remaining bit shift within u64

    const len = values.len;

    // Shift full u64 values
    if (m > 0) {
        var i = len;
        while (i > m) : (i -= 1) {
            const idx = i - 1;
            values[idx] = values[idx - m];
        }
        for (0..m) |idx| {
            values[idx] = 0;
        }
    }

    // Shift remaining bits within u64s
    if (n_bits > 0) {
        var carry: u64 = 0;
        var i = len;
        while (i > m) : (i -= 1) {
            const idx = i - 1;
            const new_carry = values[idx] << (63 - n_bits + 1); // Save bits that will be shifted out
            values[idx] = (values[idx] >> n_bits) | carry;
            carry = new_carry;
        }
    }
}

fn ShiftTypeOf(comptime T: type) type {
    const info = @typeInfo(T);
    return switch (info.Int.bits) {
        0...8 => u3,
        9...16 => u4,
        17...32 => u5,
        33...64 => u6,
        else => @compileError("Unsupported integer type"),
    };
}

fn freeFunc(rt: ?*c.JSRuntime, _: ?*anyopaque, ptr: ?*anyopaque) callconv(.C) void {
    c.js_free_rt(rt, ptr);
}

fn stackCheck(ctx: ?*c.JSContext) !void {
    const z_ctx: ?*z.JSContext = @alignCast(@ptrCast(ctx));
    if (JS_CheckStackOverflow(z_ctx.?.rt, 0) == c.TRUE) {
        _ = c.JS_ThrowRangeError(ctx, "Maximum call stack size exceeded");
        return Error.StackOverflow;
    }
}

fn getTypedArrayBuffer(ctx: ?*c.JSContext, obj: c.JSValue) !struct { c.JSValue, usize, usize, usize } {
    var offset: usize = 0;
    var length: usize = 0;
    var bytes_per_element: usize = 0;
    const buffer = c.JS_GetTypedArrayBuffer(ctx, obj, &offset, &length, &bytes_per_element);
    return .{ buffer, offset, length, bytes_per_element };
}

pub fn arrayBufferViewToSlice(ctx: ?*c.JSContext, obj: c.JSValue) ![]u8 {
    const js_ab, const offset, const length, const bytes_per_element = try getTypedArrayBuffer(ctx, obj);
    defer c.JS_FreeValue(ctx, js_ab);
    if (c.JS_IsException(js_ab) == 1) return error.NotATypedArray;

    var len: usize = 0;
    const bytes = c.JS_GetArrayBuffer(ctx, &len, js_ab);
    if (bytes == null) return error.NotAnArrayBuffer;

    return bytes[offset .. offset + (length * bytes_per_element)];
}

pub const SerializationTag = enum(u8) {
    Version = 255,
    Padding = 0,
    VerifyObjectCount = '?',
    TheHole = '-',
    Undefined = '_',
    Null = '0',
    True = 'T',
    False = 'F',
    Int32 = 'I',
    Uint32 = 'U',
    Double = 'N',
    BigInt = 'Z',
    Utf8String = 'S',
    OneByteString = '"',
    TwoByteString = 'c',
    ObjectReference = '^',
    BeginJSObject = 'o',
    EndJSObject = '{',
    BeginSparseJSArray = 'a',
    EndSparseJSArray = '@',
    BeginDenseJSArray = 'A',
    EndDenseJSArray = '$',
    Date = 'D',
    TrueObject = 'y',
    FalseObject = 'x',
    NumberObject = 'n',
    BigIntObject = 'z',
    StringObject = 's',
    RegExp = 'R',
    BeginJSMap = ';',
    EndJSMap = ':',
    BeginJSSet = '\'',
    EndJSSet = ',',
    ArrayBuffer = 'B',
    ResizableArrayBuffer = '~',
    ArrayBufferTransfer = 't',
    ArrayBufferView = 'V',
    SharedArrayBuffer = 'u',
    SharedObject = 'p',
    WasmModuleTransfer = 'w',
    HostObject = '\\',
    WasmMemoryTransfer = 'm',
    Error = 'r',
    _,
};

pub const ArrayBufferViewTag = enum(u8) {
    Int8Array = 'b',
    Uint8Array = 'B',
    Uint8ClampedArray = 'C',
    Int16Array = 'w',
    Uint16Array = 'W',
    Int32Array = 'd',
    Uint32Array = 'D',
    Float16Array = 'h',
    Float32Array = 'f',
    Float64Array = 'F',
    BigInt64Array = 'q',
    BigUint64Array = 'Q',
    DataView = '?',
    _,
};

pub const ErrorTag = enum(u8) {
    EvalErrorPrototype = 'E',
    RangeErrorPrototype = 'R',
    ReferenceErrorPrototype = 'F',
    SyntaxErrorPrototype = 'S',
    TypeErrorPrototype = 'T',
    UriErrorPrototype = 'U',
    Message = 'm',
    Cause = 'c',
    Stack = 's',
    End = '.',
    _,
};

pub const Error = std.mem.Allocator.Error || error{
    DataCloneError,
    StackOverflow,
    ArrayBufferDetached,
    NotImplemented,
    JSError,
    EndOfData,
    OutOfMemory,
    UnknownTag,
    UndefinedTag,
    OutOfData,
    ValidationFailed,
    IdCheckFailed,
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
};

const JSObjectHashContext = struct {
    const Self = @This();
    pub fn hash(_: Self, s: *z.JSObject) u64 {
        return @intFromPtr(s) * 3163; // Taken from QuickJS's hash function
    }
    pub fn eql(_: Self, a: *z.JSObject, b: *z.JSObject) bool {
        return a == b;
    }
};

const SetOrMap = enum(u1) { Set, Map };
const ObjectOrArray = enum(u1) { Object, Array };

/// A V8 compatible serializer for QuickJS values.
pub fn Serializer(comptime Delegate: type) type {
    // XXX: comptime validate delegate type
    return struct {
        allocator: std.mem.Allocator,
        ctx: ?*c.JSContext,
        buffer: std.ArrayList(u8),
        id_map: std.HashMap(*z.JSObject, u32, JSObjectHashContext, std.hash_map.default_max_load_percentage),
        next_id: u32 = 0,

        treat_array_buffer_views_as_host_objects: bool = false,
        has_custom_objects: bool = false,
        delegate: ?Delegate,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: ?*c.JSContext) !Self {
            return Self{
                .allocator = allocator,
                .ctx = ctx,
                .buffer = try std.ArrayList(u8).initCapacity(allocator, 2),
                .id_map = std.HashMap(*z.JSObject, u32, JSObjectHashContext, std.hash_map.default_max_load_percentage).init(allocator),
                .has_custom_objects = false,
                .delegate = null,
            };
        }

        pub fn initDelegate(allocator: std.mem.Allocator, ctx: ?*c.JSContext, delegate: Delegate) !Self {
            return Self{
                .allocator = allocator,
                .ctx = ctx,
                .buffer = try std.ArrayList(u8).initCapacity(allocator, 2),
                .id_map = std.HashMap(*z.JSObject, u32, JSObjectHashContext, std.hash_map.default_max_load_percentage).init(allocator),
                .has_custom_objects = delegate.hasCustomHostObject(),
                .delegate = delegate,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
            self.id_map.deinit();
        }

        pub fn writeHeader(self: *Self) !void {
            try self.writeTag(.Version);
            try self.writeVarint(u32, kLatestVersion);
        }

        pub fn setTreatArrayBufferViewsAsHostObjects(self: *Self, mode: bool) void {
            self.treat_array_buffer_views_as_host_objects = mode;
        }

        fn writeTag(self: *Self, tag: SerializationTag) !void {
            try self.buffer.append(@intFromEnum(tag));
        }

        fn writeVarint(self: *Self, comptime T: type, value: T) !void {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .Int or type_info.Int.signedness != .unsigned) {
                    @compileError("Only unsigned integer types can be written as varints.");
                }
            }
            var temp_value = value;
            while (temp_value >= 0x80) : (temp_value >>= 7) {
                try self.buffer.append(@intCast((temp_value & 0x7F) | 0x80));
            }
            try self.buffer.append(@intCast(temp_value));
        }

        fn writeZigZag(self: *Self, comptime T: type, value: T) !void {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .Int or type_info.Int.signedness != .signed) {
                    @compileError("Only signed integer types can be written as zigzag.");
                }
            }
            const UnsignedT = @Type(.{ .Int = .{ .bits = @typeInfo(T).Int.bits, .signedness = .unsigned } });
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
            try self.writeRawBytes(std.mem.sliceAsBytes(value));
        }

        fn writeBigIntContents(self: *Self, bf: *z.JSBigInt, obj: c.JSValue) !void {
            if (bf.num.len == 0) return self.writeVarint(u32, 0);

            const to_string_func = c.JS_GetPropertyStr(self.ctx, obj, "toString");
            defer c.JS_FreeValue(self.ctx, to_string_func);

            var argv: [1]c.JSValue = .{c.JS_NewInt32(self.ctx, 16)};
            defer c.JS_FreeValue(self.ctx, argv[0]);

            const result = c.JS_Call(self.ctx, to_string_func, obj, 1, &argv);
            defer c.JS_FreeValue(self.ctx, result);
            if (c.JS_IsException(result) == c.TRUE) return Error.DataCloneError;

            const hex_str_ptr = c.JS_ToCString(self.ctx, result);
            defer c.JS_FreeCString(self.ctx, hex_str_ptr);

            var hex_str = std.mem.span(hex_str_ptr);
            if (hex_str[0] == '-') hex_str = hex_str[1..]; // abs

            const expn: usize = @intCast(bf.num.expn);
            const v8_limbs_num: usize = (expn + 63) >> 6; // divCeil
            const v8_limbs = try self.allocator.alloc(u64, v8_limbs_num);
            defer self.allocator.free(v8_limbs);

            var end: usize = hex_str.len;
            var v8_limbs_idx: usize = 0;
            while (end > 0) {
                const start = if (end > 16) end - 16 else 0;
                const hex_slice = hex_str[start..end];
                v8_limbs[v8_limbs_idx] = std.fmt.parseInt(u64, hex_slice, 16) catch unreachable;
                end = start;
                v8_limbs_idx += 1;
            }

            // XXX: The following code works without string parsing by directly reading form qjs' big decimal representation,
            // bit it only works on 64-bit platforms...
            // std.debug.assert(bf.num.expn > 0);

            // const expn: u32 = @intCast(bf.num.expn);
            // const v8_limbs_num: u32 = (expn + 63) >> 6; // divCeil

            // // FIXME: `c.limb_t` might not be `u64`, depending on the platform or flags, but the v8 format is always u64!
            // const bf_limbs: []c.limb_t = bf.num.tab[0..bf.num.len];

            // const v8_limbs = try self.allocator.alloc(u64, v8_limbs_num);
            // defer self.allocator.free(v8_limbs);

            // for (v8_limbs) |*l| l.* = 0;
            // for (bf_limbs, 0..) |limb, i| v8_limbs[i] = limb;

            // const max_expn = 64 * v8_limbs_num;
            // const omitted = (v8_limbs_num - bf_limbs.len) * 64;
            // const shift = max_expn - expn + omitted;
            // shiftRightN(v8_limbs, shift);

            const sign_bit: u1 = @intCast(bf.num.sign);
            const byte_length: u31 = @intCast(v8_limbs_num * @sizeOf(u64));
            const bitfield: u32 = (byte_length << 1) | sign_bit;

            try self.writeVarint(u32, bitfield);
            try self.writeRawBytes(std.mem.sliceAsBytes(v8_limbs));
        }

        fn reserveRawBytes(self: *Self, size: usize) ![]u8 {
            try self.buffer.ensureUnusedCapacity(size);
            const slice = self.buffer.unusedCapacitySlice();
            self.buffer.items.len += size;
            return slice[0..size];
        }

        pub fn writeRawBytes(self: *Self, bytes: []const u8) !void {
            try self.buffer.appendSlice(bytes);
        }

        fn writeByte(self: *Self, value: u8) !void {
            try self.buffer.append(value);
        }

        pub fn writeUint32(self: *Self, value: u32) !void {
            try self.writeVarint(u32, value);
        }

        pub fn writeUint64(self: *Self, value: u64) !void {
            try self.writeVarint(u64, value);
        }

        pub fn release(self: *Self) ![]u8 {
            return self.buffer.toOwnedSlice();
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
                c.JS_TAG_BIG_INT => {
                    try self.writeBigInt(object);
                },
                c.JS_TAG_STRING => {
                    try self.writeString(@alignCast(@ptrCast(c.JS_VALUE_GET_PTR(object))));
                },
                c.JS_TAG_OBJECT => {
                    const p: *z.JSObject = @alignCast(@ptrCast(c.JS_VALUE_GET_PTR(object)));
                    // std.debug.print("Class id? {}\n", .{p.a.b.class_id});
                    switch (p.a.b.class_id) {
                        // Despite being JSReceivers, these have their wrapped buffer serialized
                        // first. That makes this logic a little quirky, because it needs to
                        // happen before we assign object IDs.
                        @intFromEnum(z.JSClassId.UINT8C_ARRAY)...@intFromEnum(z.JSClassId.DATAVIEW) => {
                            if (!self.id_map.contains(p) and !self.treat_array_buffer_views_as_host_objects) {
                                const ta: *z.JSTypedArray = p.u.typed_array;
                                try self.writeJSReceiver(ta.buffer, object);
                            }
                            try self.writeJSReceiver(p, object);
                        },
                        else => {
                            try self.writeJSReceiver(p, object);
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
                c.JS_TAG_UNDEFINED => .Undefined,
                c.JS_TAG_NULL => .Null,
                c.JS_TAG_BOOL => if (c.JS_VALUE_GET_INT(oddball) == 0) .False else .True,
                else => unreachable,
            };
            try self.writeTag(v8_tag);
        }

        fn writeSmi(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.Int32);
            try self.writeZigZag(i32, c.JS_VALUE_GET_INT(value));
        }

        fn writeHeapNumber(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.Double);
            try self.writeDouble(c.JS_VALUE_GET_FLOAT64(value));
        }

        fn writeBigInt(self: *Self, value: c.JSValue) !void {
            try self.writeTag(.BigInt);
            try self.writeBigIntContents(@alignCast(@ptrCast(c.JS_VALUE_GET_PTR(value))), value);
        }

        fn writeString(self: *Self, p: *z.JSString) !void {
            const len = p.len();
            if (p.isWideChar()) {
                const chars: [*]const u16 = @ptrCast(&p.u.str16);
                const byte_length: u32 = len * @sizeOf(u16);
                // The existing reading code expects 16-byte strings to be aligned.
                if (((self.buffer.items.len + 1 + bytesNeededForVarint(u32, byte_length)) & 1) != 0) {
                    try self.writeTag(.Padding);
                }
                try self.writeTag(.TwoByteString);
                try self.writeTwoByteString(chars[0..len]);
            } else {
                const chars: [*]const u8 = @ptrCast(&p.u.str8);
                try self.writeTag(.OneByteString);
                try self.writeOneByteString(chars[0..len]);
            }
        }

        fn writeJSReceiver(self: *Self, p: *z.JSObject, obj: c.JSValue) !void {
            // If the object has already been serialized, just write its ID.
            const find_result = try self.id_map.getOrPut(p);
            if (find_result.found_existing) {
                try self.writeTag(.ObjectReference);
                try self.writeVarint(u32, find_result.value_ptr.* - 1);
                return;
            }

            // Otherwise, allocate an ID for it.
            const id = self.next_id;
            self.next_id += 1;
            find_result.value_ptr.* = id + 1;

            // XXX: eliminate callable or exotic objects early?

            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const class_id: z.JSClassId = @enumFromInt(p.a.b.class_id);
            switch (class_id) {
                .ARRAY => {
                    try self.writeJSArray(p, obj);
                },
                .OBJECT => {
                    const is_host_object = try self.isHostObject(obj);
                    if (is_host_object) {
                        try self.writeHostObject(obj);
                    } else {
                        try self.writeJSObject(p, obj);
                    }
                },
                .DATE => {
                    try self.writeJSDate(p.u.object_data);
                },
                .NUMBER, .STRING, .BOOLEAN, .BIG_INT => {
                    try self.writeJSPrimitiveWrapper(p.u.object_data);
                },
                .REGEXP => {
                    try self.writeJSRegExp(p.u.regexp);
                },
                .MAP => {
                    try self.writeJSMap(.Map, p.u.map_state);
                },
                .SET => {
                    try self.writeJSMap(.Set, p.u.map_state);
                },
                .ARRAY_BUFFER, .SHARED_ARRAY_BUFFER => {
                    try self.writeJSArrayBuffer(p.u.array_buffer);
                },
                .UINT8C_ARRAY, .INT8_ARRAY, .UINT8_ARRAY, .INT16_ARRAY, .UINT16_ARRAY, .INT32_ARRAY, .UINT32_ARRAY, .BIG_INT64_ARRAY, .BIG_UINT64_ARRAY, .FLOAT32_ARRAY, .FLOAT64_ARRAY, .DATAVIEW => {
                    try self.writeJSArrayBufferView(p.u.typed_array, obj);
                },
                .ERROR => {
                    try self.writeJSError(obj);
                },
                else => {
                    try self.throwDataCloneError();
                },
            }
        }

        fn writeJSObject(self: *Self, p: *z.JSObject, obj: c.JSValue) !void {
            const raw_props: [*]z.JSShapeProperty = @ptrCast(&p.shape.prop);
            const props = raw_props[0..@intCast(p.shape.prop_size)];

            var properties_written: u32 = 0;
            var is_pojo = true;

            inline for (0..2) |pass| {
                if (is_pojo) {
                    if (pass == 1) try self.writeTag(.BeginJSObject);
                    for (props, 0..) |*prop, i| {
                        const atom = prop.atom;
                        const flags = prop.flags();
                        if (atom != c.JS_ATOM_NULL and JS_AtomIsString(self.ctx, atom) == c.TRUE and (flags & c.JS_PROP_ENUMERABLE) != 0) {
                            if (pass == 0 and (flags & c.JS_PROP_TMASK) != 0) {
                                is_pojo = false;
                                break;
                            }
                            if (pass == 1) {
                                const key = c.JS_AtomToValue(self.ctx, atom);
                                defer c.JS_FreeValue(self.ctx, key);

                                const value = p.prop[i].u.value;

                                try self.writeObject(key);
                                try self.writeObject(value);
                                properties_written += 1;
                            }
                        }
                    }
                    if (pass == 1) try self.writeTag(.EndJSObject);
                    if (pass == 1) try self.writeVarint(u32, properties_written);
                } else {
                    try self.writeJSObjectSlow(.Object, obj);
                }
            }
        }

        fn getOwnPropertyNames(self: *Self, obj: c.JSValue) ![]c.JSPropertyEnum {
            var prop_enum: [*c]c.JSPropertyEnum = undefined;
            var len: u32 = 0;
            if (c.JS_GetOwnPropertyNames(self.ctx, &prop_enum, &len, obj, c.JS_GPN_STRING_MASK) != 0) {
                try self.throwDataCloneError();
            }
            return prop_enum[0..len];
        }

        fn writeJSObjectSlow(self: *Self, comptime kind: ObjectOrArray, obj: c.JSValue) !void {
            var length: i64 = undefined;
            if (kind == .Array) if (c.JS_GetLength(self.ctx, obj, &length) != 0) try self.throwDataCloneError();

            const prop_enum = try self.getOwnPropertyNames(obj);
            defer c.JS_FreePropertyEnum(self.ctx, prop_enum.ptr, @intCast(prop_enum.len));

            try self.writeTag(if (kind == .Array) .BeginSparseJSArray else .BeginJSObject);
            if (kind == .Array) try self.writeVarint(u32, @intCast(length));

            const properties_written = try self.writeJSObjectPropertiesSlow(obj, prop_enum);

            try self.writeTag(if (kind == .Array) .EndSparseJSArray else .EndJSObject);
            try self.writeVarint(u32, properties_written);
            if (kind == .Array) try self.writeVarint(u32, @intCast(length)); // XXX: get length again?
        }

        fn writeJSArray(self: *Self, p: *z.JSObject, obj: c.JSValue) !void {
            // try self.writeJSObjectSlow(.Array, obj);
            if (p.a.b.fastArray()) {
                const length = p.u.array.count;
                try self.writeTag(.BeginDenseJSArray);
                try self.writeVarint(u32, length);
                for (0..length) |i| {
                    const item = p.u.array.u.values[i];
                    switch (c.JS_VALUE_GET_NORM_TAG(item)) {
                        c.JS_TAG_INT => try self.writeSmi(item),
                        c.JS_TAG_FLOAT64 => try self.writeHeapNumber(item),
                        else => try self.writeObject(item),
                    }
                }

                // TODO: Write properties (i.e. non-numeric keys on an array)
                // _ = try self.getOwnPropertyNames2(obj);

                try self.writeTag(.EndDenseJSArray);
                try self.writeVarint(u32, 0); // TODO: properties_written?
                try self.writeVarint(u32, length);
            } else {
                try self.writeJSObjectSlow(.Array, obj);
            }
        }

        fn writeJSDate(self: *Self, date: c.JSValue) !void {
            try self.writeTag(.Date);
            try self.writeDouble(c.JS_VALUE_GET_FLOAT64(date));
        }

        fn writeJSPrimitiveWrapper(self: *Self, value: c.JSValue) !void {
            const tag = c.JS_VALUE_GET_NORM_TAG(value);
            switch (tag) {
                c.JS_TAG_BOOL => try self.writeTag(if (c.JS_VALUE_GET_INT(value) == 0) .FalseObject else .TrueObject),
                c.JS_TAG_FLOAT64, c.JS_TAG_INT => {
                    const dbl: f64 = if (tag == c.JS_TAG_INT) @floatFromInt(c.JS_VALUE_GET_INT(value)) else c.JS_VALUE_GET_FLOAT64(value);
                    try self.writeTag(.NumberObject);
                    try self.writeDouble(dbl);
                },
                c.JS_TAG_BIG_INT => {
                    try self.writeTag(.BigIntObject);
                    try self.writeBigIntContents(@alignCast(@ptrCast(c.JS_VALUE_GET_PTR(value))), value);
                },
                c.JS_TAG_STRING => {
                    try self.writeTag(.StringObject);
                    try self.writeString(@alignCast(@ptrCast(c.JS_VALUE_GET_PTR(value))));
                },
                else => {
                    try self.throwDataCloneError();
                },
            }
        }

        fn writeJSRegExp(self: *Self, regexp: z.JSRegExp) !void {
            const bc = regexp.bytecode;
            std.debug.assert(!bc.isWideChar());

            const raw_bc: [*]const u8 = @ptrCast(&bc.u.str8);
            const flags = c.lre_get_flags(raw_bc);

            var v8_flags = flags & 0b111; // first 3 falgs are identical (/gmi)
            if ((flags & c.LRE_FLAG_STICKY) != 0) v8_flags |= 1 << 3;
            if ((flags & c.LRE_FLAG_UNICODE) != 0) v8_flags |= 1 << 4;
            if ((flags & c.LRE_FLAG_DOTALL) != 0) v8_flags |= 1 << 5;

            try self.writeTag(.RegExp);
            try self.writeString(regexp.pattern);
            try self.writeVarint(u32, @intCast(v8_flags));
        }

        fn writeJSMap(self: *Self, comptime as: SetOrMap, s: *z.JSMapState) !void {
            const length = s.record_count * (if (as == .Map) 2 else 1);

            var entries = try std.ArrayList(c.JSValue).initCapacity(self.allocator, length);
            defer entries.deinit();

            var el = s.records.next;
            while (el != &s.records) : (el = el.*.next) {
                const mr: *allowzero z.JSMapRecord = @alignCast(@fieldParentPtr("link", el));
                if (mr.empty == c.FALSE) {
                    entries.appendAssumeCapacity(mr.key);
                    if (as == .Map) entries.appendAssumeCapacity(mr.value);
                }
            }

            try self.writeTag(if (as == .Map) .BeginJSMap else .BeginJSSet);
            for (entries.items) |entry| {
                try self.writeObject(entry);
            }
            try self.writeTag(if (as == .Map) .EndJSMap else .EndJSSet);
            try self.writeVarint(u32, length);
        }

        fn writeJSArrayBuffer(self: *Self, abuf: *z.JSArrayBuffer) !void {
            if (abuf.detached != 0) {
                try self.throwDataCloneErrorDetachedArrayBuffer();
            }
            try self.writeTag(.ArrayBuffer);
            try self.writeVarint(u32, @intCast(abuf.byte_length));
            try self.writeRawBytes(abuf.data[0..@intCast(abuf.byte_length)]);
        }

        fn writeJSArrayBufferView(self: *Self, ta: *z.JSTypedArray, val: c.JSValue) !void {
            if (self.treat_array_buffer_views_as_host_objects) {
                return self.writeHostObject(val);
            }

            try self.writeTag(.ArrayBufferView);

            // XXX: out of bounds check?

            const class_id: z.JSClassId = @enumFromInt(ta.obj.a.b.class_id);
            const tag: ArrayBufferViewTag = switch (class_id) {
                .UINT8C_ARRAY => .Uint8ClampedArray,
                .INT8_ARRAY => .Int8Array,
                .UINT8_ARRAY => .Uint8Array,
                .INT16_ARRAY => .Int16Array,
                .UINT16_ARRAY => .Uint16Array,
                .INT32_ARRAY => .Int32Array,
                .UINT32_ARRAY => .Uint32Array,
                .BIG_INT64_ARRAY => .BigInt64Array,
                .BIG_UINT64_ARRAY => .BigUint64Array,
                .FLOAT16_ARRAY => .Float16Array,
                .FLOAT32_ARRAY => .Float32Array,
                .FLOAT64_ARRAY => .Float64Array,
                .DATAVIEW => .DataView,
                else => unreachable,
            };

            try self.writeVarint(u32, @intFromEnum(tag));
            try self.writeVarint(u32, @intCast(ta.offset));
            try self.writeVarint(u32, @intCast(ta.length));
            // XXX: does qjs have these flags?
            // uint32_t flags =
            //      JSArrayBufferViewIsLengthTracking::encode(view->is_length_tracking()) |
            //      JSArrayBufferViewIsBackedByRab::encode(view->is_backed_by_rab());
            try self.writeVarint(u32, 0);
        }

        fn writeErrorTag(self: *Self, tag: ErrorTag) !void {
            try self.writeVarint(u32, @intFromEnum(tag));
        }

        fn writeJSError(self: *Self, obj: c.JSValue) !void {
            var message_desc: c.JSPropertyDescriptor = undefined;
            const message = c.JS_NewAtom(self.ctx, "message");
            defer c.JS_FreeAtom(self.ctx, message);
            const message_found = c.JS_GetOwnProperty(self.ctx, &message_desc, obj, message) == c.TRUE;
            defer if (message_found) c.JS_FreeValue(self.ctx, message_desc.value);

            var cause_desc: c.JSPropertyDescriptor = undefined;
            const cause = c.JS_NewAtom(self.ctx, "cause");
            defer c.JS_FreeAtom(self.ctx, cause);
            const cause_found = c.JS_GetOwnProperty(self.ctx, &cause_desc, obj, cause) == c.TRUE;
            defer if (cause_found) c.JS_FreeValue(self.ctx, cause_desc.value);

            try self.writeTag(.Error);

            const name_object = c.JS_GetPropertyStr(self.ctx, obj, "name");
            defer c.JS_FreeValue(self.ctx, name_object);

            const name_cstr = c.JS_ToCString(self.ctx, name_object);
            defer c.JS_FreeCString(self.ctx, name_cstr);

            const name = std.mem.span(name_cstr);
            if (std.mem.eql(u8, name, "EvalError")) {
                try self.writeErrorTag(.EvalErrorPrototype);
            } else if (std.mem.eql(u8, name, "RangeError")) {
                try self.writeErrorTag(.RangeErrorPrototype);
            } else if (std.mem.eql(u8, name, "ReferenceError")) {
                try self.writeErrorTag(.ReferenceErrorPrototype);
            } else if (std.mem.eql(u8, name, "SyntaxError")) {
                try self.writeErrorTag(.SyntaxErrorPrototype);
            } else if (std.mem.eql(u8, name, "TypeError")) {
                try self.writeErrorTag(.TypeErrorPrototype);
            } else if (std.mem.eql(u8, name, "URIError")) {
                try self.writeErrorTag(.UriErrorPrototype);
            } else {
                // The default prototype in the deserialization side is Error.prototype, so
                // we don't have to do anything here.
            }

            if (message_found) {
                try self.writeErrorTag(.Message);
                try self.writeString(@alignCast(@ptrCast(c.JS_VALUE_GET_PTR(message_desc.value))));
            }

            const stack = c.JS_NewAtom(self.ctx, "stack");
            defer c.JS_FreeAtom(self.ctx, stack);
            const stack_val = c.JS_GetProperty(self.ctx, obj, stack);
            defer c.JS_FreeValue(self.ctx, stack_val);
            if (c.JS_IsString(stack_val) == 1) {
                try self.writeErrorTag(.Stack);
                try self.writeString(@alignCast(@ptrCast(c.JS_VALUE_GET_PTR(stack_val))));
            }

            if (cause_found) {
                try self.writeErrorTag(.Cause);
                try self.writeObject(cause_desc.value);
            }

            try self.writeErrorTag(.End);
        }

        fn writeHostObject(self: *Self, val: c.JSValue) !void {
            try self.writeTag(.HostObject);
            return if (self.delegate) |del| try del.writeHostObject(self.ctx, val) else return Error.NotImplemented;
        }

        fn writeJSObjectPropertiesSlow(self: *Self, obj: c.JSValue, prop_enum: []c.JSPropertyEnum) !u32 {
            var properties_written: u32 = 0;

            for (prop_enum) |prop| {
                if (prop.is_enumerable == c.FALSE) continue;
                const key = c.JS_AtomToValue(self.ctx, prop.atom);
                defer c.JS_FreeValue(self.ctx, key);
                const value = c.JS_GetProperty(self.ctx, obj, prop.atom);
                defer c.JS_FreeValue(self.ctx, value);

                // If the property is no longer found, do not serialize it.
                // This could happen if a getter deleted the property.
                // XXX: How to handle this in qjs? Checking undefined is not correct,
                //      since a value might be legitimately set to undefined.
                // if (c.JS_IsUndefined(value) != 0) continue;

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

        fn throwDataCloneError(self: *Self) !void {
            _ = c.JS_ThrowTypeError(self.ctx, "Could not clone data");
            return Error.DataCloneError;
        }

        fn throwDataCloneErrorDetachedArrayBuffer(self: *Self) !void {
            _ = c.JS_ThrowTypeError(self.ctx, "ArrayBuffer is detached");
            return Error.ArrayBufferDetached;
        }
    };
}

/// A V8 compatible deserializer for QuickJS values.
pub fn Deserializer(comptime Delegate: type) type {
    // FIXME: comptime validate delegate type
    return struct {
        allocator: std.mem.Allocator,
        ctx: ?*c.JSContext,
        js_view: c.JSValue,
        data: []const u8,
        position: usize = 0,
        version: ?u32 = undefined,
        next_id: u32 = 0,
        version_13_broken_data_mode: bool = false,
        suppress_deserialization_errors: bool = false,
        id_map: std.AutoHashMap(u32, c.JSValue),
        // array_buffer_transfer_map: *anyopaque = null,
        // shared_object_conveyor: *anyopaque = null,
        delegate: ?Delegate,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: ?*c.JSContext, buffer_view: c.JSValue) !Self {
            const slice = try arrayBufferViewToSlice(ctx, buffer_view);
            return Self{
                .allocator = allocator,
                .ctx = ctx,
                .js_view = c.JS_DupValue(ctx, buffer_view), // XXX: should probably create our own view
                .data = slice,
                .id_map = std.AutoHashMap(u32, c.JSValue).init(allocator),
                .delegate = null,
            };
        }

        pub fn initDelegate(allocator: std.mem.Allocator, ctx: ?*c.JSContext, buffer_view: c.JSValue, delegate: Delegate) !Self {
            const slice = try arrayBufferViewToSlice(ctx, buffer_view);
            return Self{
                .allocator = allocator,
                .ctx = ctx,
                .js_view = c.JS_DupValue(ctx, buffer_view), // XXX: should probably create our own view
                .data = slice,
                .id_map = std.AutoHashMap(u32, c.JSValue).init(allocator),
                .delegate = delegate,
            };
        }

        pub fn deinit(self: *Self) void {
            self.id_map.deinit();
            c.JS_FreeValue(self.ctx, self.js_view);
        }

        pub fn readHeader(self: *Self) !bool {
            if (try self.peekTag() == .Version) {
                try self.consumeTag(.Version);
                const version = try self.readVarint(u8);
                if (version > kLatestVersion) {
                    return Error.DataCloneError;
                }
                self.version = version;
            }
            return true;
        }

        fn peekTag(self: *Self) !?SerializationTag {
            var peek_position = self.position;
            var tag: SerializationTag = .Padding;
            while (tag == .Padding) {
                if (peek_position >= self.data.len) return null;
                tag = @enumFromInt(self.data[peek_position]);
                peek_position += 1;
            }
            return tag;
        }

        fn consumeTag(self: *Self, tag: ?SerializationTag) !void {
            const actual_tag = try self.readTag();
            if (tag == null or actual_tag != tag) return Error.DataCloneError;
        }

        fn readTag(self: *Self) !?SerializationTag {
            var tag: SerializationTag = .Padding;
            while (tag == .Padding) {
                if (self.position >= self.data.len) return null;
                tag = @enumFromInt(self.data[self.position]);
                self.position += 1;
            }
            return tag;
        }

        fn readVarint(self: *Self, comptime T: type) !T {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .Int or type_info.Int.signedness != .unsigned) {
                    @compileError("Only unsigned integer types can be read from varints.");
                }
            }
            var value: T = 0;
            const ShiftT = ShiftTypeOf(T);
            var shift: ShiftT = 0;
            var has_another_byte: bool = true;
            while (has_another_byte) {
                if (self.position >= self.data.len) return Error.EndOfData;
                const byte = self.data[self.position];
                has_another_byte = (byte & 0x80) != 0;
                if (shift < @sizeOf(T) * 8) {
                    const x: T = @intCast(byte & 0x7F);
                    value |= x << shift;
                    shift +%= 7; // allow wraparound since result isn't used anyway
                } else {
                    if (has_another_byte) return Error.DataCloneError;
                    return value;
                }
                self.position += 1;
            }
            return value;
        }

        fn readZigZag(self: *Self, comptime T: type) !T {
            comptime {
                const type_info = @typeInfo(T);
                if (type_info != .Int or type_info.Int.signedness != .signed) {
                    @compileError("Only signed integer types can be read as zigzag.");
                }
            }
            const UnsignedT = @Type(.{ .Int = .{ .bits = @typeInfo(T).Int.bits, .signedness = .unsigned } });
            const unsigned_value: UnsignedT = try self.readVarint(UnsignedT);
            const a: T = @intCast(unsigned_value >> 1);
            const b: T = @intCast(unsigned_value & 1);
            return a ^ -b;
        }

        pub fn readDouble(self: *Self) !f64 {
            if (self.position + @sizeOf(f64) > self.data.len) return Error.EndOfData;
            const f64_bytes = self.data[self.position .. self.position + @sizeOf(f64)];
            const value = std.mem.bytesAsValue(f64, f64_bytes).*;
            self.position += @sizeOf(f64);
            return value;
        }

        pub fn readRawBytes(self: *Self, length: usize) ![]const u8 {
            if (self.position + length > self.data.len) return Error.EndOfData;
            const slice = self.data[self.position .. self.position + length];
            self.position += length;
            return slice;
        }

        pub fn readByte(self: *Self) !u8 {
            // std.debug.print("data: {any}, {}\n", .{ self.data, self.position });
            if (self.data.len - self.position < @sizeOf(u8)) return Error.EndOfData;
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
            if (c.JS_IsArrayBuffer(result) == c.TRUE) {
                const tag = try self.peekTag();
                if (tag == .ArrayBufferView) {
                    try self.consumeTag(.ArrayBufferView);
                    defer c.JS_FreeValue(self.ctx, result);
                    return try self.readJSArrayBufferView(result);
                }
            }

            return result;
        }

        fn readObjectInternal(self: *Self) !c.JSValue {
            if (try self.readTag()) |tag| switch (tag) {
                .Undefined => return z.JS_UNDEFINED,
                .Null => return z.JS_NULL,
                .True => return z.JS_TRUE,
                .False => return z.JS_FALSE,
                .Int32 => {
                    const value = try self.readZigZag(i32);
                    return c.JS_NewInt32(self.ctx, value);
                },
                .Uint32 => {
                    const value = try self.readVarint(u32);
                    return c.JS_NewUint32(self.ctx, value);
                },
                .Double => {
                    const value = try self.readDouble();
                    return c.JS_NewFloat64(self.ctx, value);
                },
                .BigInt => {
                    return self.readBigInt();
                },
                .Utf8String => {
                    return self.readUtf8String();
                },
                .OneByteString => {
                    return self.readOneByteString();
                },
                .TwoByteString => {
                    return self.readTwoByteString();
                },
                .ObjectReference => {
                    const id = try self.readVarint(u32);
                    return self.getObjectWithID(id);
                },
                .BeginJSObject => {
                    return self.readJSObject();
                },
                .BeginSparseJSArray => {
                    return self.readSparseJSArray();
                },
                .BeginDenseJSArray => {
                    return self.readDenseJSArray();
                },
                .Date => {
                    return self.readJSDate();
                },
                .TrueObject, .FalseObject, .NumberObject, .BigIntObject, .StringObject => |t| {
                    return self.readJSPrimitiveWrapper(t);
                },
                .RegExp => {
                    return self.readJSRegExp();
                },
                .BeginJSMap => {
                    return self.readJSMap(.Map);
                },
                .BeginJSSet => {
                    return self.readJSMap(.Set);
                },
                .ArrayBuffer => {
                    const is_shared = false;
                    const is_resizable = false;
                    return self.readJSArrayBuffer(is_shared, is_resizable);
                },
                // .SharedArrayBuffer => {
                //     const is_shared = false;
                //     const is_resizable = true;
                //     return self.readJSArrayBuffer(is_shared, is_resizable);
                // },
                .Error => {
                    return self.readJSError();
                },
                .HostObject => {
                    return self.readHostObject();
                },
                else => {
                    return Error.UnknownTag;
                },
            } else {
                return Error.UndefinedTag;
            }
        }

        fn readString(self: *Self) !c.JSValue {
            if (self.version.? < 12) return self.readUtf8String();
            const object = try self.readObject();
            if (c.JS_IsString(object) == c.FALSE) return Error.DataCloneError;
            return object;
        }

        fn bigIntFromSerializedDigits(self: *Self, sign_bit: u1, digits_store: []const u8) !c.JSValue {
            if (digits_store.len == 0) return js_string_to_bigint(self.ctx, "0", 16);

            var hex = try std.ArrayList(u8).initCapacity(self.allocator, 2 + digits_store.len * 2);
            defer hex.deinit();

            if (sign_bit == 1) try hex.append(@as(u8, '-'));

            var i = digits_store.len;
            while (i > 0) {
                i -= 1;
                const byte = digits_store[i];
                try hex.append(@as(u8, "0123456789abcdef"[byte >> 4]));
                try hex.append(@as(u8, "0123456789abcdef"[byte & 0xf]));
            }
            try hex.append(0);

            const slice = try hex.toOwnedSlice();
            defer self.allocator.free(slice);
            // std.debug.print("\nstr: {s}\n", .{slice});

            const bigint = js_string_to_bigint(self.ctx, slice.ptr, 16);
            if (c.JS_IsException(bigint) == 1) return Error.DataCloneError;
            return bigint;
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
            if (c.JS_IsException(val) == c.TRUE) return Error.DataCloneError;
            return val;
        }

        fn readOneByteString(self: *Self) !c.JSValue {
            const length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(length);
            return js_new_string8_len(self.ctx, bytes.ptr, @intCast(length));
        }

        fn readTwoByteString(self: *Self) !c.JSValue {
            const byte_length = try self.readVarint(u32);
            const bytes = try self.readRawBytes(byte_length);
            const c_length: c_int = @intCast(byte_length / @sizeOf(u16));
            if (!std.mem.isAligned(@intFromPtr(bytes.ptr), 2)) { // XXX: all the homies hate this
                const aligned_bytes = try self.allocator.alignedAlloc(u8, 2, byte_length);
                defer self.allocator.free(aligned_bytes);
                @memcpy(aligned_bytes, bytes);
                const bytes_u16 = std.mem.bytesAsSlice(u16, aligned_bytes);
                return js_new_string16_len(self.ctx, @alignCast(bytes_u16.ptr), c_length);
            } else {
                const bytes_u16 = std.mem.bytesAsSlice(u16, bytes);
                return js_new_string16_len(self.ctx, @alignCast(bytes_u16.ptr), c_length);
            }
        }

        fn readJSObject(self: *Self) !c.JSValue {
            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const id = self.next_id;
            self.next_id += 1;

            const object = c.JS_NewObject(self.ctx);
            if (c.JS_IsException(object) == c.TRUE) return Error.DataCloneError;
            errdefer c.JS_FreeValue(self.ctx, object);

            try self.addObjectWithID(id, object);

            const num_properties = try self.readJSObjectProperties(object, .EndJSObject);
            const expected_num_properties = try self.readVarint(u32);
            if (num_properties != expected_num_properties) return Error.DataCloneError;

            if (!self.hasObjectWithID(id)) return Error.IdCheckFailed;
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
                defer c.JS_FreeValue(self.ctx, key);
                if (c.JS_IsException(property_key) == c.TRUE) return Error.DataCloneError;

                const value = try self.readObject();
                errdefer c.JS_FreeValue(self.ctx, value); // XXX: not good enough

                const atom = c.JS_ValueToAtom(self.ctx, property_key);
                defer c.JS_FreeAtom(self.ctx, atom);

                if (c.JS_HasProperty(self.ctx, object, atom) == 1) return Error.DataCloneError;
                const code = c.JS_DefinePropertyValue(self.ctx, object, atom, value, c.JS_PROP_C_W_E);
                if (code < 0) return Error.DataCloneError;
            }
        }

        fn readSparseJSArray(self: *Self) !c.JSValue {
            // If we are at the end of the stack, abort. This function may recurse.
            try stackCheck(self.ctx);

            const length = try self.readVarint(u32);

            const id = self.next_id;
            self.next_id += 1;

            const array = c.JS_NewArray(self.ctx);
            if (c.JS_IsException(array) == c.TRUE) return Error.OutOfMemory;
            errdefer c.JS_FreeValue(self.ctx, array);

            try self.addObjectWithID(id, array);

            const num_properties = try self.readJSObjectProperties(array, .EndSparseJSArray);
            const expected_num_properties = try self.readVarint(u32);
            const expected_length = try self.readVarint(u32);
            if (num_properties != expected_num_properties or length != expected_length) return Error.DataCloneError;

            if (!self.hasObjectWithID(id)) return Error.IdCheckFailed;
            return array;
        }

        fn readDenseJSArray(self: *Self) !c.JSValue {
            try stackCheck(self.ctx);

            const length = try self.readVarint(u32);
            if (length > self.data.len - self.position) return Error.OutOfData;

            const id = self.next_id;
            self.next_id += 1;

            const array = c.JS_NewArray(self.ctx);
            if (c.JS_IsException(array) == c.TRUE) return Error.OutOfMemory;
            errdefer c.JS_FreeValue(self.ctx, array);

            try self.addObjectWithID(id, array);

            var idx: u32 = 0;
            while (idx < length) : (idx += 1) {
                const tag = try self.peekTag();
                if (tag == .TheHole) {
                    try self.consumeTag(.TheHole);
                    continue;
                }

                const element = try self.readObject();
                errdefer c.JS_FreeValue(self.ctx, element);

                // Serialization versions less than 11 encode the hole the same as
                // undefined. For consistency with previous behavior, store these as the
                // hole. Past version 11, undefined means undefined.
                if (self.version.? < 11 and c.JS_IsUndefined(element) == 1) continue;

                const code = c.JS_DefinePropertyValueUint32(self.ctx, array, idx, element, c.JS_PROP_C_W_E);
                if (code < 0) return Error.JSError;
            }

            const num_properties = try self.readJSObjectProperties(array, .EndDenseJSArray);
            const expected_num_properties = try self.readVarint(u32);
            const expected_length = try self.readVarint(u32);
            if (num_properties != expected_num_properties or length != expected_length) return Error.ValidationFailed;

            if (!self.hasObjectWithID(id)) return Error.IdCheckFailed;
            return array;
        }

        fn readJSDate(self: *Self) !c.JSValue {
            const value = try self.readDouble();
            const id: u32 = self.next_id;
            self.next_id += 1;
            const date = c.JS_NewDate(self.ctx, value);
            if (c.JS_IsException(date) == 1) return Error.OutOfMemory;
            try self.addObjectWithID(id, date);
            return date;
        }

        fn readJSPrimitiveWrapper(self: *Self, tag: SerializationTag) !c.JSValue {
            const id: u32 = self.next_id;
            self.next_id += 1;
            const value: c.JSValue = switch (tag) {
                .TrueObject => JS_ToObject(self.ctx, z.JS_TRUE),
                .FalseObject => JS_ToObject(self.ctx, z.JS_FALSE),
                .NumberObject => blk: {
                    const double = try self.readDouble();
                    const js_num = c.JS_NewFloat64(self.ctx, double);
                    defer c.JS_FreeValue(self.ctx, js_num);
                    break :blk JS_ToObject(self.ctx, js_num);
                },
                .BigIntObject => blk: {
                    const bigint = try self.readBigInt();
                    defer c.JS_FreeValue(self.ctx, bigint);
                    break :blk JS_ToObject(self.ctx, bigint);
                },
                .StringObject => blk: {
                    const js_str = try self.readString();
                    defer c.JS_FreeValue(self.ctx, js_str);
                    break :blk JS_ToObject(self.ctx, js_str);
                },
                else => unreachable,
            };
            if (c.JS_IsException(value) == 1) return Error.OutOfMemory;
            try self.addObjectWithID(id, value);
            return value;
        }

        fn readJSRegExp(self: *Self) !c.JSValue {
            const id: u32 = self.next_id;
            self.next_id += 1;
            const pattern = try self.readString();
            defer c.JS_FreeValue(self.ctx, pattern);
            const v8_flags = try self.readVarint(u32);

            // TODO: restore flags
            // var bc = v8_flags & 0b111;  // first 3 falgs are identical (/gmi)
            // if ((v8_flags & 1 << 3) != 0) bc |= c.LRE_FLAG_STICKY;
            // if ((v8_flags & 1 << 4) != 0) bc |= c.LRE_FLAG_UNICODE;
            // if ((v8_flags & 1 << 5) != 0) bc |= c.LRE_FLAG_DOTALL;
            _ = v8_flags;

            const regexp = js_regexp_constructor_internal(self.ctx, z.JS_UNDEFINED, pattern, c.JS_NewString(self.ctx, ""));
            if (c.JS_IsException(regexp) == 1) return Error.OutOfMemory;
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
            defer c.JS_FreeValue(self.ctx, map_constructor);

            const map = c.JS_CallConstructor(self.ctx, map_constructor, 0, null);
            if (c.JS_IsException(map) == c.TRUE) return Error.OutOfMemory;
            errdefer c.JS_FreeValue(self.ctx, map);

            try self.addObjectWithID(id, map);

            const set_func = c.JS_GetPropertyStr(self.ctx, map, if (kind == .Map) "set" else "add");
            defer c.JS_FreeValue(self.ctx, set_func);

            var length: u32 = 0;
            while (true) {
                const tag = try self.peekTag();
                if (tag == if (kind == .Map) .EndJSMap else .EndJSSet) {
                    try self.consumeTag(tag);
                    break;
                }

                var argv: [2]c.JSValue = undefined;
                argv[0] = try self.readObject();
                defer c.JS_FreeValue(self.ctx, argv[0]);
                if (kind == .Map) argv[1] = try self.readObject();
                defer if (kind == .Map) c.JS_FreeValue(self.ctx, argv[1]);

                const result = c.JS_Call(self.ctx, set_func, map, if (kind == .Map) 2 else 1, &argv);
                if (c.JS_IsException(result) == c.TRUE) return Error.OutOfMemory;
                defer c.JS_FreeValue(self.ctx, result);

                length += if (kind == .Map) 2 else 1;
            }

            const expected_length = try self.readVarint(u32);
            if (length != expected_length) return Error.DataCloneError;
            if (!self.hasObjectWithID(id)) return Error.IdCheckFailed;
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
                if (byte_length > max_byte_length) return Error.DataCloneError;
            }

            const bytes = try self.readRawBytes(byte_length);
            const result = c.JS_NewArrayBufferCopy(self.ctx, bytes.ptr, byte_length);
            if (c.JS_IsException(result) == c.TRUE) return Error.OutOfMemory;
            errdefer c.JS_FreeValue(self.ctx, result);

            try self.addObjectWithID(id, result);
            return result;
        }

        fn readJSArrayBufferView(self: *Self, js_ab: c.JSValue) !c.JSValue {
            const p: *z.JSObject = @alignCast(@ptrCast(c.JS_VALUE_GET_PTR(js_ab)));
            const buffer_byte_length: u32 = @intCast(p.u.array_buffer.byte_length);

            const tag = try self.readVarint(u8);
            const byte_offset = try self.readVarint(u32);
            const byte_length = try self.readVarint(u32);
            if (byte_offset > buffer_byte_length or byte_length > buffer_byte_length - byte_offset) {
                return Error.DataCloneError;
            }

            const should_read_flags = self.version.? >= 14 or self.version_13_broken_data_mode;
            const flags = if (should_read_flags) try self.readVarint(u32) else 0;
            _ = flags; // TODO: can we even use this in qjs?

            const id = self.next_id;
            self.next_id += 1;

            const tag_enum: ArrayBufferViewTag = @enumFromInt(tag);
            const class_id: z.JSClassId, const element_size: u32 = switch (tag_enum) {
                .Uint8ClampedArray => .{ .UINT8C_ARRAY, 1 },
                .Int8Array => .{ .INT8_ARRAY, 1 },
                .Uint8Array => .{ .UINT8_ARRAY, 1 },
                .Int16Array => .{ .INT16_ARRAY, 2 },
                .Uint16Array => .{ .UINT16_ARRAY, 2 },
                .Int32Array => .{ .INT32_ARRAY, 4 },
                .Uint32Array => .{ .UINT32_ARRAY, 4 },
                .BigInt64Array => .{ .BIG_INT64_ARRAY, 8 },
                .BigUint64Array => .{ .BIG_UINT64_ARRAY, 8 },
                .Float16Array => .{ .FLOAT16_ARRAY, 2 },
                .Float32Array => .{ .FLOAT32_ARRAY, 4 },
                .Float64Array => .{ .FLOAT64_ARRAY, 8 },
                .DataView => .{ .DATAVIEW, 1 },
                else => return Error.DataCloneError,
            };

            if (byte_offset % element_size != 0 or byte_length % element_size != 0) return Error.DataCloneError;

            //   bool is_length_tracking = false;
            //   bool is_backed_by_rab = false;
            //   if (!ValidateJSArrayBufferViewFlags(*buffer, flags, is_length_tracking, is_backed_by_rab)) {
            //     return MaybeHandle<JSArrayBufferView>();
            //   }

            var argv: [3]c.JSValue = undefined;
            argv[0] = js_ab;
            argv[1] = c.JS_NewUint32(self.ctx, byte_offset);
            argv[2] = c.JS_NewUint32(self.ctx, byte_length / element_size);
            defer c.JS_FreeValue(self.ctx, argv[1]);
            defer c.JS_FreeValue(self.ctx, argv[2]);
            const obj = if (tag_enum == .DataView)
                js_dataview_constructor(self.ctx, z.JS_UNDEFINED, 3, &argv)
            else
                js_typed_array_constructor(self.ctx, z.JS_UNDEFINED, 3, &argv, @intFromEnum(class_id));
            if (c.JS_IsException(obj) == c.TRUE) return Error.OutOfMemory;
            errdefer c.JS_FreeValue(self.ctx, obj);

            try self.addObjectWithID(id, obj);
            return obj;
        }

        fn readJSError(self: *Self) !c.JSValue {
            const id = self.next_id;
            self.next_id += 1;

            var tag: ErrorTag = @enumFromInt(try self.readVarint(u8));

            const z_ctx: *z.JSContext = @alignCast(@ptrCast(self.ctx));
            var error_proto: ?c.JSValue = undefined;
            switch (tag) {
                .EvalErrorPrototype => {
                    error_proto = z_ctx.native_error_proto[0];
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .RangeErrorPrototype => {
                    error_proto = z_ctx.native_error_proto[1];
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .ReferenceErrorPrototype => {
                    error_proto = z_ctx.native_error_proto[2];
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .SyntaxErrorPrototype => {
                    error_proto = z_ctx.native_error_proto[3];
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .TypeErrorPrototype => {
                    error_proto = z_ctx.native_error_proto[4];
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                .UriErrorPrototype => {
                    error_proto = z_ctx.native_error_proto[5];
                    tag = @enumFromInt(try self.readVarint(u8));
                },
                else => {
                    error_proto = null;
                },
            }

            var message: ?c.JSValue = null;
            if (tag == .Message) {
                message = try self.readString();
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (message) |x| c.JS_FreeValue(self.ctx, x);

            var stack: ?c.JSValue = null;
            if (tag == .Stack) {
                stack = try self.readString();
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (stack) |x| c.JS_FreeValue(self.ctx, x);

            const err_class_id = @intFromEnum(z.JSClassId.ERROR);
            const err_obj = if (error_proto) |proto| c.JS_NewObjectProtoClass(self.ctx, proto, err_class_id) else c.JS_NewError(self.ctx);
            errdefer c.JS_FreeValue(self.ctx, err_obj);

            try self.addObjectWithID(id, err_obj);

            const no_enum = c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE;

            if (stack) |x| if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "stack", x, no_enum) < 0) {
                return Error.DataCloneError;
            };
            if (message) |x| if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "message", x, no_enum) < 0) {
                return Error.DataCloneError;
            };

            var cause: ?c.JSValue = null;
            if (tag == .Cause) {
                cause = try self.readObject();
                if (c.JS_DefinePropertyValueStr(self.ctx, err_obj, "cause", cause.?, no_enum) < 0) {
                    return Error.DataCloneError;
                }
                tag = @enumFromInt(try self.readVarint(u8));
            }
            errdefer if (cause) |x| c.JS_FreeValue(self.ctx, x);

            if (tag != .End) return Error.DataCloneError;
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
            if (id >= self.id_map.count()) return Error.DataCloneError;
            const value = self.id_map.get(id);
            if (value == null or c.JS_IsObject(value.?) == 0) return Error.DataCloneError;
            return value.?;
        }

        fn addObjectWithID(self: *Self, id: u32, value: c.JSValue) !void {
            if (self.hasObjectWithID(id)) return Error.DataCloneError;
            try self.id_map.put(id, value);
        }
    };
}

pub const DefaultSerializer = Serializer(DefaultDelegate);
pub const DefaultDeserializer = Deserializer(DefaultDelegate);
