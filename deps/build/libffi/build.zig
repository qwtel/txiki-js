const std = @import("std");

const version = std.SemanticVersion.parse("3.5.2") catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const patcher = b.lazyImport(@This(), "common") orelse return;
    const source = b.path("../../libffi");

    try patcher.ensureApplied(b, source, b.path("../../../patches/libffi-aarch64-windows.patch"));
    b.installArtifact(try add(b, source, b.path("fficonfig.h"), target, optimize));
}

pub fn add(
    b: *std.Build,
    source: std.Build.LazyPath,
    config_template: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = false,
    });
    const cflags = &.{"-fexceptions"};

    mod.addCSourceFiles(.{
        .root = source.path(b, "src"),
        .files = &.{
            "closures.c",
            "java_raw_api.c",
            "prep_cif.c",
            "raw_api.c",
            "tramp.c",
            "types.c",
        },
        .flags = cflags,
    });

    const t = target.result;
    const arch_name, const arch_target, const arch_sources: []const []const u8 = switch (t.cpu.arch) {
        .aarch64, .aarch64_be => .{
            "aarch64",
            "AARCH64",
            &.{ "ffi.c", "sysv.S" },
        },
        .arc => .{
            "arc",
            "ARC",
            &.{ "ffi.c", "arcompact.S" },
        },
        .arm, .armeb => blk: {
            if (t.os.tag == .windows and t.abi == .msvc) {
                @panic("libffi does not provide GNU-compatible assembly for arm-windows-msvc");
            }
            break :blk .{
                "arm",
                if (t.os.tag == .windows) "ARM_WIN32" else "ARM",
                &.{ "ffi.c", "sysv.S" },
            };
        },
        .csky => .{
            "csky",
            "CSKY",
            &.{ "ffi.c", "sysv.S" },
        },
        .loongarch64 => .{
            "loongarch64",
            "LOONGARCH64",
            &.{ "ffi.c", "sysv.S" },
        },
        .m68k => .{
            "m68k",
            "M68K",
            &.{ "ffi.c", "sysv.S" },
        },
        .mips, .mipsel, .mips64, .mips64el => .{
            "mips",
            "MIPS",
            &.{ "ffi.c", "n32.S", "o32.S" },
        },
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => .{
            "powerpc",
            switch (t.os.tag) {
                .freebsd, .netbsd, .openbsd => "POWERPC_FREEBSD",
                else => if (t.os.tag.isDarwin()) "POWERPC_DARWIN" else "POWERPC",
            },
            &switch (t.os.tag) {
                .freebsd, .netbsd, .openbsd => .{
                    "ffi.c",
                    "ffi_sysv.c",
                    "ppc_closure.S",
                    "sysv.S",
                },
                else => if (t.os.tag.isDarwin()) .{
                    "darwin.S",
                    "darwin_closure.S",
                    "ffi_darwin.c",
                } else .{
                    "ffi.c",
                    "ffi_linux64.c",
                    "ffi_sysv.c",
                    "linux64.S",
                    "linux64_closure.S",
                    "ppc_closure.S",
                    "sysv.S",
                },
            },
        },
        .riscv32, .riscv64 => .{
            "riscv",
            "RISCV",
            &.{ "ffi.c", "sysv.S" },
        },
        .s390x => .{
            "s390",
            "S390",
            &.{ "ffi.c", "sysv.S" },
        },
        .sparc, .sparc64 => .{
            "sparc",
            "SPARC",
            &.{ "ffi.c", "ffi64.c", "v8.S", "v9.S" },
        },
        .x86 => .{
            "x86",
            switch (t.os.tag) {
                .freebsd, .openbsd => "X86_FREEBSD",
                .windows => "X86_WIN32",
                else => if (t.os.tag.isDarwin()) "X86_DARWIN" else "X86",
            },
            &.{ "ffi.c", "sysv.S" },
        },
        .x86_64 => .{
            "x86",
            if (t.os.tag == .windows) "X86_WIN64" else "X86_64",
            &if (t.os.tag == .windows) .{
                "ffiw64.c",
                "win64.S",
            } else if (t.abi == .gnux32 or t.abi == .muslx32) .{
                "ffi64.c",
                "unix64.S",
            } else .{
                "ffi64.c",
                "ffiw64.c",
                "unix64.S",
                "win64.S",
            },
        },
        .xtensa => .{
            "xtensa",
            "XTENSA",
            &.{ "ffi.c", "sysv.S" },
        },
        else => @panic("This target is not supported by libffi"),
    };

    mod.addCSourceFiles(.{
        .root = source.path(b, b.pathJoin(&.{ "src", arch_name })),
        .files = arch_sources,
        .flags = cflags,
    });
    mod.addIncludePath(source.path(b, "include"));
    mod.addIncludePath(source.path(b, "src"));
    mod.addIncludePath(source.path(b, b.pathJoin(&.{ "src", arch_name })));

    const double_size = t.cTypeByteSize(.double);
    const long_double_size = t.cTypeByteSize(.longdouble);
    const long_double_variant = switch (t.os.tag) {
        .freebsd, .netbsd, .openbsd => t.cpu.arch == .powerpc,
        .linux => t.cpu.arch.isPowerPC(),
        else => false,
    };
    const long_double: enum { false, true, mips64 } =
        if (t.cpu.arch.isMIPS() and (t.os.tag == .freebsd or t.os.tag == .linux or t.os.tag == .openbsd))
            .mips64
        else if (long_double_variant or long_double_size > double_size)
            .true
        else
            .false;

    const ffi_h = b.addConfigHeader(.{
        .style = .{ .cmake = source.path(b, "include/ffi.h.in") },
        .include_path = "ffi.h",
    }, .{
        .FFI_EXEC_TRAMPOLINE_TABLE = t.cpu.arch == .aarch64 and t.os.tag.isDarwin(),
        .FFI_VERSION_NUMBER = b.fmt("{d}{d:0>2}{d:0>2}\n", .{ version.major, version.minor, version.patch }),
        .FFI_VERSION_STRING = "3.5.2",
        .HAVE_LONG_DOUBLE = switch (long_double) {
            .false => "0",
            .true => "1",
            .mips64 => "defined(__mips64)",
        },
        .TARGET = arch_target,
        .VERSION = "3.5.2",
    });

    const fficonfig_h = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = config_template },
        .include_path = "fficonfig.h",
    }, .{
        .AC_APPLE_UNIVERSAL_BUILD = null,
        .EH_FRAME_FLAGS = "a",
        .FFI_DEBUG = null,
        .FFI_EXEC_STATIC_TRAMP = switch (t.os.tag) {
            .linux => if (t.cpu.arch.isArm() or t.cpu.arch.isAARCH64() or t.cpu.arch.isLoongArch() or t.cpu.arch.isPowerPC() or t.cpu.arch == .s390x or t.cpu.arch.isX86()) true else null,
            else => null,
        },
        .FFI_EXEC_TRAMPOLINE_TABLE = if (t.cpu.arch == .aarch64 and t.os.tag.isDarwin()) true else null,
        .FFI_MMAP_EXEC_EMUTRAMP_PAX = null,
        .FFI_MMAP_EXEC_WRIT = switch (t.os.tag) {
            .dragonfly, .freebsd, .openbsd, .illumos => true,
            else => if (t.os.tag.isDarwin() or t.abi.isAndroid()) true else null,
        },
        .FFI_NO_RAW_API = null,
        .FFI_NO_STRUCTS = null,
        .HAVE_ALLOCA_H = if (t.os.tag != .windows and (!t.os.tag.isBSD() or t.os.tag.isDarwin())) true else null,
        .HAVE_ARM64E_PTRAUTH = null,
        .HAVE_AS_CFI_PSEUDO_OP = true,
        .HAVE_AS_REGISTER_PSEUDO_OP = if (t.cpu.arch.isSPARC()) true else null,
        .HAVE_AS_S390_ZARCH = if (t.cpu.arch == .s390x) true else null,
        .HAVE_AS_SPARC_UA_PCREL = true,
        .HAVE_AS_X86_64_UNWIND_SECTION_TYPE = if (t.cpu.arch == .x86_64) true else null,
        .HAVE_AS_X86_PCREL = true,
        .HAVE_DLFCN_H = if (t.os.tag != .windows) true else null,
        .HAVE_HIDDEN_VISIBILITY_ATTRIBUTE = if (t.os.tag != .windows) true else null,
        .HAVE_INTTYPES_H = true,
        .HAVE_LONG_DOUBLE_VARIANT = if (long_double_variant) true else null,
        .HAVE_MEMCPY = true,
        .HAVE_MEMFD_CREATE = switch (t.os.tag) {
            .linux, .freebsd => true,
            .netbsd => if (t.os.version_range.semver.isAtLeast(.{ .major = 11, .minor = 0, .patch = 0 }) orelse false) true else null,
            else => null,
        },
        .HAVE_RO_EH_FRAME = true,
        .HAVE_STDINT_H = true,
        .HAVE_STDIO_H = true,
        .HAVE_STDLIB_H = true,
        .HAVE_STRINGS_H = if (t.abi != .msvc and t.abi != .itanium) true else null,
        .HAVE_STRING_H = true,
        .HAVE_SYS_MEMFD_H = null,
        .HAVE_SYS_STAT_H = if (t.abi != .msvc and t.abi != .itanium) true else null,
        .HAVE_SYS_TYPES_H = if (t.abi != .msvc and t.abi != .itanium) true else null,
        .HAVE_UNISTD_H = true,
        .LIBFFI_GNU_SYMBOL_VERSIONING = null,
        .LT_OBJDIR = null,
        .PACKAGE = "libffi",
        .PACKAGE_BUGREPORT = "https://github.com/libffi/libffi/issues",
        .PACKAGE_NAME = "libffi",
        .PACKAGE_STRING = "libffi 3.5.2",
        .PACKAGE_TARNAME = "libffi",
        .PACKAGE_URL = "https://github.com/libffi/libffi",
        .PACKAGE_VERSION = "3.5.2",
        .SIZEOF_DOUBLE = double_size,
        .SIZEOF_LONG_DOUBLE = long_double_size,
        .SIZEOF_SIZE_T = t.ptrBitWidth() / 8,
        .STDC_HEADERS = true,
        .SYMBOL_UNDERSCORE = if ((t.cpu.arch == .x86 and t.os.tag == .windows) or t.os.tag.isDarwin()) true else null,
        .USING_PURIFY = null,
        .VERSION = "3.5.2",
        .WORDS_BIGENDIAN = if (t.cpu.arch.endian() == .big) true else null,
    });

    switch (long_double) {
        .false => fficonfig_h.addValues(.{ .HAVE_LONG_DOUBLE = null }),
        .true => fficonfig_h.addValues(.{ .HAVE_LONG_DOUBLE = 1 }),
        .mips64 => fficonfig_h.addValues(.{ .HAVE_LONG_DOUBLE = .@"defined(__mips64)" }),
    }
    mod.addConfigHeader(fficonfig_h);
    mod.addConfigHeader(ffi_h);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ffi",
        .root_module = mod,
        .version = version,
    });
    lib.installConfigHeader(ffi_h);
    lib.installHeader(source.path(b, b.pathJoin(&.{ "src", arch_name, "ffitarget.h" })), "ffitarget.h");
    return lib;
}
