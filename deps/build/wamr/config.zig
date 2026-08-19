const std = @import("std");

pub const Macro = struct {
    name: []const u8,
    value: []const u8,
};

pub const Config = struct {
    wasm_macros: []const Macro,
};

pub fn load(allocator: std.mem.Allocator) !Config {
    return std.zon.parse.fromSliceAlloc(
        Config,
        allocator,
        @embedFile("config.zon"),
        null,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn free(allocator: std.mem.Allocator, config: Config) void {
    std.zon.parse.free(allocator, config);
}

pub fn hasMremap(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .linux;
}

pub fn macroEnabled(config: Config, name: []const u8) bool {
    for (config.wasm_macros) |macro| {
        if (std.mem.eql(u8, macro.name, name)) {
            return std.mem.eql(u8, macro.value, "1");
        }
    }
    return false;
}

pub fn addRuntimeCMacros(
    mod: *std.Build.Module,
    config: Config,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    if (optimize == .Debug) {
        mod.addCMacro("BH_DEBUG", "1");
    }

    mod.addCMacro("BH_MALLOC", "wasm_runtime_malloc");
    mod.addCMacro("BH_FREE", "wasm_runtime_free");

    switch (arch) {
        .x86_64 => mod.addCMacro("BUILD_TARGET_X86_64", "1"),
        .aarch64, .aarch64_be => {
            mod.addCMacro("BUILD_TARGET_AARCH64", "1");
            mod.addCMacro("BUILD_TARGET", "\"AARCH64\"");
        },
        .arm, .armeb, .thumb, .thumbeb => {
            mod.addCMacro("BUILD_TARGET_ARM", "1");
            mod.addCMacro("BUILD_TARGET", "\"ARM\"");
        },
        .riscv64 => mod.addCMacro("BUILD_TARGET_RISCV64_LP64D", "1"),
        .riscv32 => mod.addCMacro("BUILD_TARGET_RISCV32_ILP32D", "1"),
        .mips, .mipsel, .mips64, .mips64el => mod.addCMacro("BUILD_TARGET_MIPS", "1"),
        .xtensa => mod.addCMacro("BUILD_TARGET_XTENSA", "1"),
        else => @panic("unsupported CPU for WAMR macros"),
    }

    if (os.isDarwin()) {
        mod.addCMacro("BH_PLATFORM_DARWIN", "1");
    } else if (os == .windows) {
        mod.addCMacro("BH_PLATFORM_WINDOWS", "1");
        mod.addCMacro("HAVE_STRUCT_TIMESPEC", "1");
        mod.addCMacro("_WINSOCK_DEPRECATED_NO_WARNINGS", "1");
    } else {
        mod.addCMacro("BH_PLATFORM_LINUX", "1");
    }

    for (config.wasm_macros) |macro| {
        mod.addCMacro(macro.name, macro.value);
    }
    mod.addCMacro("WASM_HAVE_MREMAP", if (hasMremap(target)) "1" else "0");

    if (hasMremap(target)) {
        mod.addCMacro("_GNU_SOURCE", "1");
    }
}

pub fn addPackageIncludePaths(
    mod: *std.Build.Module,
    b: *std.Build,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
) void {
    mod.addIncludePath(source.path(b, "core/iwasm/include"));
    mod.addIncludePath(source.path(b, "core/iwasm/common"));
    mod.addIncludePath(source.path(b, "core/iwasm/interpreter"));
    mod.addIncludePath(source.path(b, "core/iwasm/libraries/libc-builtin"));
    mod.addIncludePath(source.path(b, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/include"));
    mod.addIncludePath(source.path(b, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src"));
    mod.addIncludePath(source.path(b, "core/shared/mem-alloc"));
    mod.addIncludePath(source.path(b, "core/shared/utils"));
    mod.addIncludePath(source.path(b, "core/shared/platform/include"));
    mod.addIncludePath(source.path(b, "core/shared/platform/common/libc-util"));
    mod.addIncludePath(source.path(b, "core/shared/platform/common/memory"));
    mod.addIncludePath(source.path(b, "core/shared/platform/common/posix"));

    if (target.result.os.tag.isDarwin()) {
        mod.addIncludePath(source.path(b, "core/shared/platform/darwin"));
    } else if (target.result.os.tag == .windows) {
        mod.addIncludePath(source.path(b, "core/shared/platform/windows"));
    } else {
        mod.addIncludePath(source.path(b, "core/shared/platform/linux"));
    }
}
