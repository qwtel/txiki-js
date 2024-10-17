const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const Serializer = @import("v8-serialize.zig").DefaultSerializer;
const Deserializer = @import("v8-serialize.zig").DefaultDeserializer;
const c = @import("v8-serialize.zig").c;
const z = @import("v8-serialize.zig").z;

fn evalJS(ctx: ?*c.JSContext, code: []const u8) c.JSValue {
    return c.JS_Eval(ctx, code.ptr, code.len, "<input>", c.JS_EVAL_TYPE_GLOBAL);
}

pub fn main() !void {
    const rt = c.JS_NewRuntime();
    const ctx = c.JS_NewContext(rt);
    defer {
        c.JS_FreeContext(ctx);
        c.JS_FreeRuntime(rt);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.debug.print("Leak detected", .{});
    }

    // const js_code = "4499451044928085923n";
    // const js_code = "151053533847813541534499451044928085923n";
    // const js_code = "BigInt(0xffff_ffff_ffff_ffff)";
    const js_code = "new DataView(new Uint8Array([1,2,3]).buffer)";
    const eval_result = evalJS(ctx, js_code);
    if (c.JS_IsException(eval_result) == c.TRUE) std.debug.print("Exception\n", .{});
    defer c.JS_FreeValue(ctx, eval_result);

    var ser = try Serializer.init(allocator, ctx);
    defer ser.deinit();
    try ser.writeHeader();
    try ser.writeObject(eval_result);
    std.debug.print("{x:0<2}\n", .{ser.buffer.items});

    // const x = c.JS_NewUint8ArrayCopy(ctx, &data, data.len);
    // defer c.JS_FreeValue(ctx, x);
    // var des = try Deserializer.init(allocator, ctx, x);
    // defer des.deinit();
    // _ = try des.readHeader();
    // const res = try des.readObject();
    // defer c.JS_FreeValue(ctx, res);
    // std.debug.print("actual {any}\n", .{res});
}

fn testSerializeEvalJS(js_code: []const u8, expected: []const u8) !void {
    const rt = c.JS_NewRuntime();
    defer c.JS_FreeRuntime(rt);

    const ctx = c.JS_NewContext(rt);
    defer c.JS_FreeContext(ctx);

    const eval_result = evalJS(ctx, js_code);
    defer c.JS_FreeValue(ctx, eval_result);

    var ser = try Serializer.init(testing.allocator, ctx);
    defer ser.deinit();

    try ser.writeHeader();
    try ser.writeObject(eval_result);

    const result = try ser.release();
    defer testing.allocator.free(result);

    try testing.expectEqualSlices(u8, expected, result);
}

fn testDeserialize(buf: []const u8, expected: []const u8) !void {
    const rt = c.JS_NewRuntime();
    defer c.JS_FreeRuntime(rt);

    const ctx = c.JS_NewContext(rt);
    defer c.JS_FreeContext(ctx);

    const js_expected = evalJS(ctx, expected);
    defer c.JS_FreeValue(ctx, js_expected);

    try testing.expect(c.JS_IsException(js_expected) == 0);

    const view = c.JS_NewUint8ArrayCopy(ctx, buf.ptr, buf.len);
    defer c.JS_FreeValue(ctx, view);

    var des = try Deserializer.init(testing.allocator, ctx, view);
    defer des.deinit();

    _ = try des.readHeader();
    const js_actual = try des.readObject();
    defer c.JS_FreeValue(ctx, js_actual);

    try testing.expect(c.JS_IsException(js_actual) == 0);

    const func_obj = evalJS(ctx,
        \\ (function deepEqual(a, b) {
        \\     if (a === b) {
        \\         return true;
        \\     }
        \\
        \\     if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') {
        \\         return false;
        \\     }
        \\
        \\     if (Array.isArray(a) !== Array.isArray(b)) {
        \\         return false;
        \\     }
        \\
        \\     const keysA = Object.keys(a);
        \\     const keysB = Object.keys(b);
        \\
        \\     if (keysA.length !== keysB.length) {
        \\         return false;
        \\     }
        \\
        \\     for (const key of keysA) {
        \\         if (!keysB.includes(key) || !deepEqual(a[key], b[key])) {
        \\             return false;
        \\         }
        \\     }
        \\
        \\     return true;
        \\ })
    );
    defer c.JS_FreeValue(ctx, func_obj);
    try testing.expect(c.JS_IsFunction(ctx, func_obj) == 1);

    var argv = [_]c.JSValue{ js_expected, js_actual };
    const res = c.JS_Call(ctx, func_obj, z.JS_NULL, argv.len, &argv);
    defer c.JS_FreeValue(ctx, res);

    try testing.expect(c.JS_VALUE_GET_BOOL(res) == 1);
}

test "serializer 1" {
    const expected = [3]u8{ 255, 15, 48 };
    try testSerializeEvalJS("null", &expected);
}
test "serializer 2" {
    const expected = [16]u8{ 255, 15, 34, 12, 72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 63 };
    try testSerializeEvalJS("'Hello World?'", &expected);
}
test "serializer 3" {
    const expected = [28]u8{ 255, 15, 65, 3, 65, 1, 73, 0, 36, 0, 1, 65, 1, 73, 2, 36, 0, 1, 65, 1, 73, 4, 36, 0, 1, 36, 0, 3 };
    try testSerializeEvalJS("new Array(3).fill(0).map((_, i) => [i])", &expected);
}
test "serializer 4" {
    const expected = [10]u8{ 255, 15, 111, 34, 1, 97, 73, 6, 123, 1 };
    try testSerializeEvalJS("({ a: 3 })", &expected);
}
test "serializer 5" {
    const expected = [18]u8{ 255, 15, 111, 34, 1, 97, 73, 6, 34, 1, 98, 34, 3, 77, 77, 77, 123, 2 };
    try testSerializeEvalJS("new Object({ a: 3, b: 'MMM' })", &expected);
}
test "serializer 6" {
    const expected = [9]u8{ 255, 15, 82, 34, 3, 97, 98, 99, 0 };
    try testSerializeEvalJS("new RegExp('abc')", &expected);
}
test "serializer 7" {
    const expected = [9]u8{ 255, 15, 82, 34, 3, 97, 98, 99, 1 };
    try testSerializeEvalJS("new RegExp('abc', 'g')", &expected);
}
test "serializer 7-2" {
    const expected = [9]u8{ 255, 15, 82, 34, 3, 97, 98, 99, 1 };
    try testSerializeEvalJS("/abc/g", &expected);
}
test "serializer 8" {
    const expected = [9]u8{ 255, 15, 82, 34, 3, 97, 98, 99, 56 };
    try testSerializeEvalJS("new RegExp('abc', 'suy')", &expected);
}
test "serializer 9" {
    const expected = [8]u8{ 255, 15, 115, 34, 3, 77, 77, 77 };
    try testSerializeEvalJS("new String('MMM')", &expected);
}
test "serializer 10" {
    const expected = [11]u8{ 255, 15, 110, 0, 0, 0, 0, 0, 0, 8, 64 };
    try testSerializeEvalJS("new Number(3)", &expected);
}
test "serializer 11" {
    const expected = [11]u8{ 255, 15, 39, 73, 2, 73, 4, 73, 6, 44, 3 };
    try testSerializeEvalJS("new Set([1, 2, 3])", &expected);
}
test "serializer 12" {
    const expected = [19]u8{ 255, 15, 65, 2, 66, 3, 1, 2, 3, 86, 66, 0, 3, 0, 94, 2, 36, 0, 2 };
    try testSerializeEvalJS("(() => { let x = new Uint8Array([1, 2, 3]); return [x, x]; })()", &expected);
}
test "serializer 13" {
    const expected = [12]u8{ 255, 15, 90, 16, 255, 255, 255, 255, 0, 0, 0, 0 };
    try testSerializeEvalJS("BigInt(0xffffffff)", &expected);
}
test "serializer 14" {
    const expected = [20]u8{ 255, 15, 90, 32, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testSerializeEvalJS("BigInt(0xffff_ffff_ffff_ffff)", &expected);
}
test "serializer 15" {
    const expected = [12]u8{ 255, 15, 90, 16, 255, 255, 255, 255, 255, 255, 255, 255 };
    try testSerializeEvalJS("2n ** 64n - 1n", &expected);
}
test "serializer 16" {
    const expected = [20]u8{ 255, 15, 90, 32, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    try testSerializeEvalJS("2n ** 128n - 1n", &expected);
}
test "serializer 17" {
    const expected = [12]u8{ 255, 15, 90, 16, 59, 161, 12, 119, 81, 112, 133, 0 };
    try testSerializeEvalJS("37559667094495547n", &expected);
}
test "serializer 18" {
    const expected = [20]u8{ 255, 15, 90, 32, 0, 0, 0, 0, 0, 0, 0, 0, 59, 161, 12, 119, 81, 112, 133, 0 };
    try testSerializeEvalJS("37559667094495547n << 64n", &expected);
}
test "serializer 19" {
    const expected = [12]u8{ 255, 15, 90, 17, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testSerializeEvalJS("-1n", &expected);
}
test "serializer 20" {
    const expected = [12]u8{ 255, 15, 90, 16, 255, 255, 255, 255, 255, 255, 255, 255 };
    try testSerializeEvalJS("2n ** 64n - 1n", &expected);
}
test "serializer 21" {
    const expected = [20]u8{ 255, 15, 90, 33, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    try testSerializeEvalJS("-(2n ** 128n - 1n)", &expected);
}
test "serializer 22" {
    const expected = [12]u8{ 255, 15, 66, 3, 1, 2, 3, 86, 63, 0, 3, 0 };
    try testSerializeEvalJS("new DataView(new Uint8Array([1,2,3]).buffer)", &expected);
}
test "serializer 22-1" {
    const expected = [13]u8{ 255, 15, 66,  4, 1, 2, 3,  4, 86, 87, 0, 4, 0};
    try testSerializeEvalJS("new Uint16Array(new Uint8Array([1,2,3,4]).buffer)", &expected);
}
test "serializer 23" {
    const expected = [10]u8{ 255, 15, 111, 34, 1, 120, 73, 6, 123, 1 };
    try testSerializeEvalJS("(() => { const o = {}; Object.defineProperty(o, 'x', { enumerable: true, get: () => 3, set: () => {} }); return o; })()", &expected);
}
test "serializer 24-1" {
    const expected = [12]u8{ 255, 15, 90, 16, 169, 20, 163, 50, 223, 254, 160, 209 };
    try testSerializeEvalJS("15105353384781354153n", &expected);
}
test "serializer 24-2" {
    const expected = [20]u8{ 255, 15, 90, 32, 163, 223, 90, 11, 96, 218, 142, 234, 157, 231, 21, 43, 55, 218, 163, 113 };
    try testSerializeEvalJS("151053533847813541534499451044928085923n", &expected);
}
test "serializer 24-3" {
    const expected = [12]u8{ 255, 15, 90, 16, 3, 0, 0, 0, 0, 0, 0, 0 };
    try testSerializeEvalJS("3n", &expected);
}
test "serializer 24-4" {
    const expected = [12]u8{ 255, 15, 90, 16, 8, 0, 0, 0, 0, 0, 0, 0 };
    try testSerializeEvalJS("8n", &expected);
}
test "serializer 24-5" {
    const expected = [12]u8{ 255, 15, 90, 16, 15, 0, 0, 0, 0, 0, 0, 0 };
    try testSerializeEvalJS("15n", &expected);
}
test "serializer 24-6" {
    const expected = [12]u8{ 255, 15, 90, 16, 16, 0, 0, 0, 0, 0, 0, 0 };
    try testSerializeEvalJS("16n", &expected);
}
test "serializer 25" {
    const expected = [11]u8{ 255, 15, 78, 102, 102, 102, 102, 102, 102, 10, 64 };
    try testSerializeEvalJS("3.3", &expected);
}
test "serializer 26" {
    const expected = [34]u8{ 255, 15, 99, 30, 72, 0, 101, 0, 108, 0, 108, 0, 111, 0, 32, 0, 87, 0, 111, 0, 114, 0, 108, 0, 100, 0, 33, 0, 32, 0, 61, 216, 14, 222 };
    try testSerializeEvalJS("'Hello World! 😎'", &expected);
}
test "serializer 27" {
    const expected = [13]u8{ 255, 15, 65, 3, 73, 2, 73, 4, 73, 6, 36, 0, 3 };
    try testSerializeEvalJS("[1, 2, 3]", &expected);
}
test "serializer 28-0" {
    const expected = [7]u8{ 255, 15, 66, 3, 1, 2, 3 };
    try testSerializeEvalJS("new Uint8Array([1,2,3]).buffer", &expected);
}
test "serializer 28-1" {
    const expected = [12]u8{ 255, 15, 66, 3, 1, 2, 3, 86, 66, 0, 3, 0 };
    try testSerializeEvalJS("new Uint8Array([1,2,3])", &expected);
}
test "serializer 29" {
    const expected = [4]u8{ 255, 15, 90, 0 };
    try testSerializeEvalJS("0n", &expected);
}
test "serializer 29-1" {
    const expected = [4]u8{ 255, 15, 90, 0 };
    try testSerializeEvalJS("-0n", &expected);
}
test "serializer 30" {
    const expected = [8]u8{ 255, 15, 73, 200, 129, 175, 183, 2 };
    try testSerializeEvalJS("326492260", &expected);
}
test "serializer 31" {
    const expected = [4]u8{ 255, 15, 73, 1 };
    try testSerializeEvalJS("-1", &expected);
}
test "serializer 31-2" {
    const expected = [4]u8{ 255, 15, 73, 3 };
    try testSerializeEvalJS("-2", &expected);
}
test "serializer 31-3" {
    const expected = [4]u8{ 255, 15, 73, 5 };
    try testSerializeEvalJS("-3", &expected);
}
test "serializer 31-4" {
    const expected = [5]u8{ 255, 15, 73, 255, 15 };
    try testSerializeEvalJS("-1024", &expected);
}
test "serializer 31-5" {
    const expected = [8]u8{ 255,  15,  73, 157, 156, 180, 241,  12 };
    try testSerializeEvalJS("-1729529615", &expected);
}
test "serializer 31-6" {
    const expected = [8]u8{ 255,  15,  73, 159, 156, 180, 241,  12 };
    try testSerializeEvalJS("-1729529616", &expected);
}
test "serializer 31-7" {
    const expected = [8]u8{ 255,  15,  73, 161, 156, 180, 241,  12 };
    try testSerializeEvalJS("-1729529617", &expected);
}

test "deserializer 1" {
    const data = [3]u8{ 255, 15, 48 };
    try testDeserialize(&data, "null");
}
test "deserializer 2" {
    const data = [11]u8{ 255, 15, 78, 102, 102, 102, 102, 102, 102, 10, 64 };
    try testDeserialize(&data, "3.3");
}
test "deserializer 3" {
    const data = [10]u8{ 255, 15, 111, 34, 1, 97, 73, 6, 123, 1 };
    try testDeserialize(&data, "({ a: 3 })");
}
test "deserializer 4" {
    const data = [34]u8{ 255, 15, 99, 30, 72, 0, 101, 0, 108, 0, 108, 0, 111, 0, 32, 0, 87, 0, 111, 0, 114, 0, 108, 0, 100, 0, 33, 0, 32, 0, 61, 216, 14, 222 };
    try testDeserialize(&data, "'Hello World! 😎'");
}
test "deserializer 5-0-1" {
    const data = [13]u8{ 255, 15, 111, 73, 0, 73, 2, 73, 4, 73, 6, 123, 2 };
    try testDeserialize(&data, "({ '0': 1, '2': 3 })");
}
test "deserializer 5-0" {
    const data = [15]u8{ 255, 15, 97, 3, 73, 0, 73, 2, 73, 4, 73, 6, 64, 2, 3 };
    try testDeserialize(&data, "[1, , 3]");
}
test "deserialzier 5-1" {
    const data = [13]u8{ 255, 15, 65, 3, 73, 2, 73, 4, 73, 6, 36, 0, 3 };
    try testDeserialize(&data, "[1, 2, 3]");
}
test "deserialzier 5-2" {
    const data = [31]u8{ 255, 15, 65, 3, 111, 34, 1, 97, 73, 2, 123, 1, 111, 34, 1, 97, 73, 4, 123, 1, 111, 34, 1, 97, 73, 6, 123, 1, 36, 0, 3 };
    try testDeserialize(&data, "[{ a: 1 }, { a: 2 }, { a: 3}]");
}
test "deserializer 5" {
    const data = [28]u8{ 255, 15, 65, 3, 65, 1, 73, 0, 36, 0, 1, 65, 1, 73, 2, 36, 0, 1, 65, 1, 73, 4, 36, 0, 1, 36, 0, 3 };
    try testDeserialize(&data, "new Array(3).fill(0).map((_, i) => [i])");
}
test "deserialzier 6" {
    const data = [12]u8{ 255, 15, 90, 16, 255, 255, 255, 255, 0, 0, 0, 0 };
    try testDeserialize(&data, "BigInt(0xffffffff)");
}
test "deserializer 6-1" {
    const data = [20]u8{ 255, 15, 90, 32, 163, 223, 90, 11, 96, 218, 142, 234, 157, 231, 21, 43, 55, 218, 163, 113 };
    try testDeserialize(&data, "0x71a3da372b15e79dea8eda600b5adfa3n");
}
test "deserializer 6-2" {
    const data = [20]u8{ 255, 15, 90, 33, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    try testDeserialize(&data, "-(2n ** 128n - 1n)");
}
test "deserialize 7" {
    const data = [11]u8{ 255, 15, 39, 73, 2, 73, 4, 73, 6, 44, 3 };
    try testDeserialize(&data, "new Set([1,2,3])");
}
test "deserialize 8-0" {
    const data = [7]u8{ 255, 15, 66, 3, 0, 0, 0 };
    try testDeserialize(&data, "new ArrayBuffer(3)");
}
test "deserialize 8-1" {
    const data = [12]u8{ 255, 15, 66, 3, 1, 2, 3, 86, 66, 0, 3, 0 };
    try testDeserialize(&data, "new Uint8Array([1,2,3])");
}
test "deserialize 8-2" {
    const data = [12]u8{ 255, 15, 66, 3, 1, 2, 3, 86, 63, 0, 3, 0 };
    try testDeserialize(&data, "new DataView(new Uint8Array([1,2,3]).buffer)");
}
test "deserialize 9" {
    const data = [4]u8{ 255, 15, 90, 0 };
    try testDeserialize(&data, "0n");
}
test "deserialize 10" {
    const data = [8]u8{ 255, 15, 73, 200, 129, 175, 183, 2 };
    try testDeserialize(&data, "326492260");
}

test "deserialize error 1" {
    const data = [_]u8{ 255, 15, 111, 83, 6, 114, 101, 97, 115, 111, 110, 114, 115, 83, 197, 14, 69, 114, 114, 111, 114, 58, 32, 115, 105, 103, 110, 97, 108, 32, 105, 115, 32, 97, 98, 111, 114, 116, 101, 100, 32, 119, 105, 116, 104, 111, 117, 116, 32, 114, 101, 97, 115, 111, 110, 10, 32, 32, 32, 32, 97, 116, 32, 97, 98, 111, 114, 116, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 51, 48, 54, 49, 55, 58, 49, 55, 41, 10, 32, 32, 32, 32, 97, 116, 32, 115, 105, 103, 110, 97, 108, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 51, 48, 54, 50, 49, 58, 55, 41, 10, 32, 32, 32, 32, 97, 116, 32, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 51, 53, 50, 50, 56, 58, 57, 54, 10, 32, 32, 32, 32, 97, 116, 32, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 52, 50, 51, 58, 49, 51, 10, 32, 32, 32, 32, 97, 116, 32, 117, 110, 116, 114, 97, 99, 107, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 53, 50, 55, 58, 49, 50, 41, 10, 32, 32, 32, 32, 97, 116, 32, 108, 111, 97, 100, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 52, 50, 50, 58, 52, 52, 41, 10, 32, 32, 32, 32, 97, 116, 32, 79, 98, 106, 101, 99, 116, 46, 102, 110, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 52, 55, 49, 58, 51, 55, 41, 10, 32, 32, 32, 32, 97, 116, 32, 114, 117, 110, 67, 111, 109, 112, 117, 116, 97, 116, 105, 111, 110, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 55, 52, 55, 58, 50, 50, 41, 10, 32, 32, 32, 32, 97, 116, 32, 117, 112, 100, 97, 116, 101, 67, 111, 109, 112, 117, 116, 97, 116, 105, 111, 110, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 55, 50, 54, 58, 51, 41, 10, 32, 32, 32, 32, 97, 116, 32, 114, 117, 110, 84, 111, 112, 32, 40, 104, 116, 116, 112, 115, 58, 47, 47, 102, 105, 108, 101, 43, 46, 118, 115, 99, 111, 100, 101, 45, 114, 101, 115, 111, 117, 114, 99, 101, 46, 118, 115, 99, 111, 100, 101, 45, 99, 100, 110, 46, 110, 101, 116, 47, 85, 115, 101, 114, 115, 47, 113, 119, 116, 101, 108, 47, 71, 105, 116, 72, 117, 98, 47, 118, 115, 99, 111, 100, 101, 45, 101, 120, 116, 101, 110, 115, 105, 111, 110, 45, 115, 97, 109, 112, 108, 101, 115, 47, 99, 117, 115, 116, 111, 109, 45, 101, 100, 105, 116, 111, 114, 45, 115, 97, 109, 112, 108, 101, 47, 115, 113, 108, 105, 116, 101, 45, 118, 105, 101, 119, 101, 114, 45, 99, 111, 114, 101, 47, 118, 115, 99, 111, 100, 101, 47, 98, 117, 105, 108, 100, 47, 97, 115, 115, 101, 116, 115, 47, 105, 110, 100, 101, 120, 46, 106, 115, 58, 50, 56, 51, 56, 58, 55, 41, 46, 123, 1 };
    try testDeserialize(&data,
        \\(() => {
        \\  const reason = Error("");
        \\  reason.stack = `Error: signal is aborted without reason
        \\    at abort (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:30617:17)
        \\    at signal (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:30621:7)
        \\    at https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:35228:96
        \\    at https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2423:13
        \\    at untrack (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2527:12)
        \\    at load (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2422:44)
        \\    at Object.fn (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2471:37)
        \\    at runComputation (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2747:22)
        \\    at updateComputation (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2726:3)
        \\    at runTop (https://file+.vscode-resource.vscode-cdn.net/Users/qwtel/GitHub/vscode-extension-samples/custom-editor-sample/sqlite-viewer-core/vscode/build/assets/index.js:2838:7)`;
        \\  return { reason };
        \\})()
    );
}
