//! Strips translate-c `comptime { ... @sizeOf(mach_msg_*) ... }` blocks from generated Zig.
//! Apple SDK headers use bitfield structs Zig demotes to `opaque`, but translate-c still emits
//! size assertions — those must not be compiled when the type is opaque.

const std = @import("std");
const mem = std.mem;

fn trim(line: []const u8) []const u8 {
    return mem.trim(u8, line, " \t\r");
}

fn blockShouldDrop(block: []const u8) bool {
    if (mem.indexOf(u8, block, "mach_msg_") != null) return true;
    if (mem.indexOf(u8, block, "mach_msg_mac_trailer") != null) return true;
    if (mem.indexOf(u8, block, "mach_msg_context_trailer") != null) return true;
    return false;
}

fn emitLine(out: *std.array_list.Managed(u8), line: []const u8) !void {
    if (out.items.len != 0) try out.append('\n');
    try out.appendSlice(line);
}

fn sanitize(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(arena);
    var iter = mem.splitScalar(u8, input, '\n');
    while (iter.next()) |line| {
        if (mem.eql(u8, trim(line), "comptime {")) {
            var block_lines = std.array_list.Managed([]const u8).init(arena);
            try block_lines.append(line);
            while (iter.next()) |inner| {
                try block_lines.append(inner);
                if (mem.startsWith(u8, trim(inner), "}")) break;
            }
            const joined = try mem.join(arena, "\n", block_lines.items);
            if (blockShouldDrop(joined)) continue;
            for (block_lines.items) |l| try emitLine(&out, l);
        } else {
            try emitLine(&out, line);
        }
    }
    return out.items;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const ac = arena.allocator();

    var it = init.minimal.args.iterate();
    defer it.deinit();
    _ = it.skip();
    const in_z = it.next() orelse return error.MissingArgument;
    const out_z = it.next() orelse return error.MissingArgument;
    const input_path = in_z[0..in_z.len];
    const output_path = out_z[0..out_z.len];

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, input_path, ac, std.Io.Limit.limited(std.math.maxInt(usize)));
    const output = try sanitize(ac, input);

    var out_f = try cwd.createFile(init.io, output_path, .{});
    defer out_f.close(init.io);
    try out_f.writeStreamingAll(init.io, output);
}
