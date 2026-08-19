const std = @import("std");
const wamr_config = @import("config.zig");

const SourceLists = struct {
    c: std.array_list.Managed([]const u8),
    cpp: std.array_list.Managed([]const u8),
    assembly: std.array_list.Managed([]const u8),
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const patcher = b.lazyImport(@This(), "common") orelse return;
    const source = b.path("../../wamr");

    try patcher.ensureApplied(b, source, b.path("../../../patches/wamr-zig.patch"));
    b.addNamedLazyPath("source", source);
    b.addNamedLazyPath("config", b.path("config.zon"));
    b.installArtifact(try add(b, source, target, optimize));
}

pub fn add(
    b: *std.Build,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const config = try wamr_config.load(b.allocator);
    defer wamr_config.free(b.allocator, config);

    var sources = SourceLists{
        .c = std.array_list.Managed([]const u8).init(b.allocator),
        .cpp = std.array_list.Managed([]const u8).init(b.allocator),
        .assembly = std.array_list.Managed([]const u8).init(b.allocator),
    };
    try collectRuntimeSources(b, source, config, target, &sources);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "vmlib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag == .windows,
        }),
    });

    wamr_config.addRuntimeCMacros(lib.root_module, config, target, optimize);
    wamr_config.addPackageIncludePaths(lib.root_module, b, source, target);

    var cflags = std.array_list.Managed([]const u8).init(b.allocator);
    try cflags.appendSlice(&.{
        "-std=gnu99",
        "-ffunction-sections",
        "-fdata-sections",
        "-Wall",
        "-Wno-unused-parameter",
        "-Wno-pedantic",
        "-Wno-unknown-pragmas",
        "-Wno-c23-extensions",
        "-Wno-logical-op-parentheses",
        "-Wno-unused-variable",
    });
    if (optimize == .Debug) {
        try cflags.appendSlice(&.{
            "-ggdb",
            "-fno-omit-frame-pointer",
            "-fno-sanitize=undefined",
        });
    }
    if (target.result.ptrBitWidth() == 64 and target.result.os.tag != .windows) {
        try cflags.append("-fPIC");
    }
    if (target.result.cpu.arch == .arm or target.result.cpu.arch == .armeb) {
        try cflags.append("-marm");
    }

    lib.root_module.addCSourceFiles(.{
        .root = source,
        .files = sources.c.items,
        .flags = cflags.items,
    });
    var cxxflags = std.array_list.Managed([]const u8).init(b.allocator);
    for (cflags.items) |flag| {
        if (!std.mem.eql(u8, flag, "-std=gnu99")) {
            try cxxflags.append(flag);
        }
    }
    lib.root_module.addCSourceFiles(.{
        .root = source,
        .files = sources.cpp.items,
        .flags = cxxflags.items,
    });
    lib.root_module.addCSourceFiles(.{
        .root = source,
        .files = sources.assembly.items,
        .flags = cflags.items,
    });

    if (target.result.os.tag == .windows) {
        lib.root_module.linkSystemLibrary("api-ms-win-core-path-l1-1-0", .{});
        lib.root_module.linkSystemLibrary("bcrypt", .{});
        lib.root_module.linkSystemLibrary("ws2_32", .{});
    }

    lib.installHeadersDirectory(source.path(b, "core/iwasm/include"), ".", .{});
    lib.installHeadersDirectory(source.path(b, "core/iwasm/common"), ".", .{});
    lib.installHeadersDirectory(source.path(b, "core/iwasm/interpreter"), ".", .{});
    lib.installHeadersDirectory(source.path(b, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/include"), ".", .{});
    lib.installHeadersDirectory(source.path(b, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src"), ".", .{});
    lib.installHeadersDirectory(source.path(b, "core/shared/utils"), ".", .{});
    lib.installHeadersDirectory(source.path(b, "core/shared/platform/include"), ".", .{});
    if (target.result.os.tag.isDarwin()) {
        lib.installHeadersDirectory(source.path(b, "core/shared/platform/darwin"), ".", .{});
    } else if (target.result.os.tag == .windows) {
        lib.installHeadersDirectory(source.path(b, "core/shared/platform/windows"), ".", .{});
    } else {
        lib.installHeadersDirectory(source.path(b, "core/shared/platform/linux"), ".", .{});
    }
    return lib;
}

fn collectRuntimeSources(
    b: *std.Build,
    source: std.Build.LazyPath,
    config: wamr_config.Config,
    target: std.Build.ResolvedTarget,
    sources: *SourceLists,
) !void {
    const os = target.result.os.tag;

    try collectPlatformSources(b, source, target, sources);
    try collectGlob(b, source, "core/shared/mem-alloc/ems", ".c", &sources.c);
    try collectGlob(b, source, "core/shared/mem-alloc/tlsf", ".c", &sources.c);
    try sources.c.append("core/shared/mem-alloc/mem_alloc.c");
    try collectGlob(b, source, "core/shared/utils", ".c", &sources.c);

    if (wamr_config.macroEnabled(config, "WASM_ENABLE_LIBC_BUILTIN")) {
        try collectGlob(b, source, "core/iwasm/libraries/libc-builtin", ".c", &sources.c);
    }
    if (wamr_config.macroEnabled(config, "WASM_ENABLE_LIBC_WASI")) {
        try collectGlobRecursive(b, source, "core/iwasm/libraries/libc-wasi", ".c", &sources.c);
    }

    try collectGlob(b, source, "core/iwasm/common", ".c", &sources.c);
    if (wamr_config.macroEnabled(config, "WASM_ENABLE_GC")) {
        try collectGlob(b, source, "core/iwasm/common/gc", ".c", &sources.c);
    }
    const invoke_native = invokeNativeSource(config, target);
    if (std.mem.endsWith(u8, invoke_native, ".c")) {
        try sources.c.append(invoke_native);
    } else {
        try sources.assembly.append(invoke_native);
    }

    if (wamr_config.macroEnabled(config, "WASM_ENABLE_INTERP")) {
        try sources.c.append(if (wamr_config.macroEnabled(config, "WASM_ENABLE_MINI_LOADER"))
            "core/iwasm/interpreter/wasm_mini_loader.c"
        else
            "core/iwasm/interpreter/wasm_loader.c");
        try sources.c.append("core/iwasm/interpreter/wasm_runtime.c");
        try sources.c.append(if (wamr_config.macroEnabled(config, "WASM_ENABLE_FAST_INTERP"))
            "core/iwasm/interpreter/wasm_interp_fast.c"
        else
            "core/iwasm/interpreter/wasm_interp_classic.c");
    }

    if (os == .windows) {
        try collectGlob(b, source, "core/shared/platform/windows", ".cpp", &sources.cpp);
    }
}

fn collectPlatformSources(
    b: *std.Build,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    sources: *SourceLists,
) !void {
    const os = target.result.os.tag;

    if (os.isDarwin()) {
        try collectGlobRecursive(b, source, "core/shared/platform/darwin", ".c", &sources.c);
        try collectPosixSources(b, source, target, sources);
    } else if (os == .windows) {
        try collectGlobRecursive(b, source, "core/shared/platform/windows", ".c", &sources.c);
        try collectGlobRecursive(b, source, "core/shared/platform/common/libc-util", ".c", &sources.c);
        try collectGlobRecursive(b, source, "core/shared/platform/common/memory", ".c", &sources.c);
    } else {
        try collectGlobRecursive(b, source, "core/shared/platform/linux", ".c", &sources.c);
        try collectPosixSources(b, source, target, sources);
    }
}

fn collectPosixSources(
    b: *std.Build,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    sources: *SourceLists,
) !void {
    try collectGlobRecursive(b, source, "core/shared/platform/common/posix", ".c", &sources.c);
    try collectGlobRecursive(b, source, "core/shared/platform/common/libc-util", ".c", &sources.c);
    if (!wamr_config.hasMremap(target)) {
        try collectGlobRecursive(b, source, "core/shared/platform/common/memory", ".c", &sources.c);
    }
}

fn invokeNativeSource(config: wamr_config.Config, target: std.Build.ResolvedTarget) []const u8 {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;
    const simd = wamr_config.macroEnabled(config, "WASM_ENABLE_SIMD");

    if (os == .windows and arch == .x86_64) {
        return if (simd)
            "core/iwasm/common/arch/invokeNative_mingw_x64_simd.s"
        else
            "core/iwasm/common/arch/invokeNative_mingw_x64.s";
    }
    if (os == .windows) {
        return "core/iwasm/common/arch/invokeNative_general.c";
    }

    return switch (arch) {
        .x86_64 => if (simd)
            "core/iwasm/common/arch/invokeNative_em64_simd.s"
        else
            "core/iwasm/common/arch/invokeNative_em64.s",
        .aarch64, .aarch64_be => if (simd)
            "core/iwasm/common/arch/invokeNative_aarch64_simd.s"
        else
            "core/iwasm/common/arch/invokeNative_aarch64.s",
        .arm, .armeb => "core/iwasm/common/arch/invokeNative_arm.s",
        .thumb, .thumbeb => "core/iwasm/common/arch/invokeNative_thumb.s",
        .riscv64, .riscv32 => "core/iwasm/common/arch/invokeNative_riscv.S",
        .mips, .mipsel, .mips64, .mips64el => "core/iwasm/common/arch/invokeNative_mips.s",
        .xtensa => "core/iwasm/common/arch/invokeNative_xtensa.s",
        else => "core/iwasm/common/arch/invokeNative_general.c",
    };
}

fn collectGlob(
    b: *std.Build,
    source: std.Build.LazyPath,
    dir_name: []const u8,
    extension: []const u8,
    out: *std.array_list.Managed([]const u8),
) !void {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, source.path(b, dir_name).getPath(b), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var entries = std.array_list.Managed([]const u8).init(b.allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, extension)) continue;
        try entries.append(try std.fs.path.join(b.allocator, &.{ dir_name, entry.name }));
    }
    std.mem.sort([]const u8, entries.items, {}, lessThan);
    try out.appendSlice(entries.items);
}

fn collectGlobRecursive(
    b: *std.Build,
    source: std.Build.LazyPath,
    dir_name: []const u8,
    extension: []const u8,
    out: *std.array_list.Managed([]const u8),
) !void {
    const io = b.graph.io;
    var root = std.Io.Dir.cwd().openDir(io, source.path(b, dir_name).getPath(b), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer root.close(io);

    var entries = std.array_list.Managed([]const u8).init(b.allocator);
    var walker = try root.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, extension)) continue;
        try entries.append(try std.fs.path.join(b.allocator, &.{ dir_name, entry.path }));
    }
    std.mem.sort([]const u8, entries.items, {}, lessThan);
    try out.appendSlice(entries.items);
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
