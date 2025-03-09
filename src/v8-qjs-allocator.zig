const std = @import("std");

pub const c = @import("v8-qjs-structs.zig").c;

/// A Zig allocator that uses QuickJS's memory management functions.
/// Allows freeing memory returned by our compat functions using QuickJS's `JS_Free*` functions.
pub const QJSAllocator = struct {
    pub fn allocator(ctx: ?*c.JSContext) std.mem.Allocator {
        std.debug.assert(ctx != null);
        return .{
            .ptr = ctx.?,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const js_ctx: *c.JSContext = @ptrCast(@alignCast(ctx));
        const ptr = c.js_malloc(js_ctx, n);
        std.debug.assert(@intFromEnum(log2_ptr_align) < 64);
        std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @as(usize, 1) << @intFromEnum(log2_ptr_align)));
        _ = ret_addr;
        return @ptrCast(ptr);
    }

    fn resize(ctx: *anyopaque, old_mem: []u8, log2_buf_align: std.mem.Alignment, n: usize, ret_addr: usize) bool {
        const js_ctx: *c.JSContext = @ptrCast(@alignCast(ctx));
        if (n <= old_mem.len) {
            return true;
        }
        const full_len = c.js_malloc_usable_size(js_ctx, old_mem.ptr);
        if (n <= full_len) {
            return true;
        }
        _ = log2_buf_align;
        _ = ret_addr;
        return false;
    }

    fn free(ctx: *anyopaque, mem: []u8, log2_buf_align: std.mem.Alignment, ret_addr: usize) void {
        const js_ctx: *c.JSContext = @ptrCast(@alignCast(ctx));
        _ = log2_buf_align;
        _ = ret_addr;
        c.js_free(js_ctx, mem.ptr);
    }

    fn remap(ctx: *anyopaque, old_mem: []u8, log2_buf_align: std.mem.Alignment, n: usize, ret_addr: usize) ?[*]u8 {
        const js_ctx: *c.JSContext = @ptrCast(@alignCast(ctx));
        _ = ret_addr;
        const new_ptr_opt = c.js_realloc(js_ctx, old_mem.ptr, n);
        if (new_ptr_opt) |new_ptr| {
            std.debug.assert(std.mem.isAligned(@intFromPtr(new_ptr), @as(usize, 1) << @intFromEnum(log2_buf_align)));
            return @ptrCast(new_ptr);
        }
        return null;
    }
};
