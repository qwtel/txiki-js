const std = @import("std");
const builtin = @import("builtin");

const BuildZon = struct {
    version: []const u8,
};

const WamrMacro = struct {
    name: []const u8,
    value: []const u8,
};

const WamrConfig = struct {
    wasm_macros: []const WamrMacro,
};

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf },
};

const BuildOpts = struct {
    with_mimalloc: bool,
    with_wasm: bool,
    with_sqlite: bool,
    with_sqlite_load_extensions: bool,
    with_network: bool,
    with_ipc: bool,
    with_crypto: bool,
    with_ffi: bool,
    with_subprocess: bool,
    matrix: bool,
    test_filter: ?[]const u8 = null,
};

fn build2(
    b: *std.Build,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    opts: BuildOpts,
    sanitize_tjs_c_import_exe: *std.Build.Step.Compile,
) ![2]?*std.Build.Step.Compile {
    const target = b.resolveTargetQuery(query);

    if (opts.with_wasm and target.result.abi == .gnueabihf) {
        return .{ null, null };
    }

    const dep_sqlite3 = if (opts.with_sqlite) b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
        .omit_load_extension = !opts.with_sqlite_load_extensions,
    }) else null;
    const dep_quickjs = b.dependency("quickjs", .{
        .target = target,
        .optimize = optimize,
        .extras = true,
    });
    const dep_libuv = b.dependency("libuv", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_miniz = b.dependency("miniz", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_ada = b.dependency("ada", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_mimalloc = if (opts.with_mimalloc) b.dependency("mimalloc", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const dep_mbedtls = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_libwebsockets = if (opts.with_network) b.dependency("libwebsockets", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const dep_wamr = if (opts.with_wasm) b.dependency("wamr", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const dep_libffi = if (opts.with_ffi) b.dependency("libffi", .{
        .target = target,
        .optimize = optimize,
    }) else null;

    const libuv = dep_libuv.artifact("uv_a");
    const mimalloc = if (dep_mimalloc) |dep| dep.artifact("mimalloc-static") else null;
    const mbedcrypto = dep_mbedtls.artifact("mbedcrypto");
    const mbedx509 = dep_mbedtls.artifact("mbedx509");
    const mbedtls = dep_mbedtls.artifact("mbedtls");
    const libwebsockets = if (dep_libwebsockets) |dep| dep.artifact("websockets") else null;
    const wamr = if (dep_wamr) |dep| dep.artifact("vmlib") else null;
    const libffi = if (dep_libffi) |dep| dep.artifact("ffi") else null;
    const wamr_config = if (dep_wamr) |dep| try loadWamrConfig(b, dep.namedLazyPath("config")) else null;
    defer if (wamr_config) |config| freeWamrConfig(b, config);

    const tjs_platform = try std.fmt.allocPrint(
        b.allocator,
        "\"{s}\"",
        .{if (target.result.os.tag.isDarwin()) "darwin" else @tagName(target.result.os.tag)},
    );

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/tjs_c_import.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(b.path("src"));
    translate_c.addIncludePath(dep_quickjs.artifact("qjs").getEmittedIncludeTree());
    if (opts.with_sqlite) {
        translate_c.addIncludePath(dep_sqlite3.?.artifact("sqlite3").getEmittedIncludeTree());
    }
    translate_c.addIncludePath(libuv.getEmittedIncludeTree());
    translate_c.addIncludePath(mbedcrypto.getEmittedIncludeTree());
    translate_c.defineCMacro("TJS__PLATFORM", tjs_platform);
    if (opts.with_sqlite) {
        translate_c.defineCMacro("TJS_HAVE_SQLITE", "1");
    }
    if (!opts.with_sqlite_load_extensions) {
        translate_c.defineCMacro("TJS__OMIT_SQLITE_LOAD_EXTENSION", "1");
    }
    if (!opts.with_crypto) {
        translate_c.defineCMacro("TJS__OMIT_CRYPTO", "1");
    }
    if (opts.with_ffi) {
        translate_c.defineCMacro("TJS_HAVE_FFI", "1");
    }
    if (opts.with_wasm) {
        translate_c.defineCMacro("TJS_HAVE_WASM", "1");
        translate_c.addIncludePath(dep_wamr.?.namedLazyPath("source").path(b, "core/iwasm/include"));
        translate_c.addIncludePath(wamr.?.getEmittedIncludeTree());
    }
    if (opts.with_mimalloc) {
        translate_c.defineCMacro("TJS__HAS_MIMALLOC", "1");
    }
    if (opts.with_network) {
        translate_c.addIncludePath(libwebsockets.?.getEmittedIncludeTree());
    } else {
        translate_c.defineCMacro("TJS__OMIT_NETWORK", "1");
    }
    if (!opts.with_subprocess) {
        translate_c.defineCMacro("TJS__OMIT_SUBPROCESS", "1");
    }
    if (!opts.with_ipc) {
        translate_c.defineCMacro("TJS__OMIT_IPC", "1");
    }

    const run_sanitize_tjs_c_import = b.addRunArtifact(sanitize_tjs_c_import_exe);
    run_sanitize_tjs_c_import.addFileArg(translate_c.getOutput());
    const sanitized_tjs_c_import_zig = run_sanitize_tjs_c_import.addOutputFileArg("tjs_c_import.zig");

    const c_mod = b.createModule(.{
        .root_source_file = sanitized_tjs_c_import_zig,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tjs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zig_c_bindings.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = c_mod },
            },
        }),
    });

    lib.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
    lib.installLibraryHeaders(dep_quickjs.artifact("qjs"));

    lib.root_module.linkLibrary(libuv);
    lib.installLibraryHeaders(libuv);
    lib.root_module.linkLibrary(dep_miniz.artifact("miniz"));
    lib.installLibraryHeaders(dep_miniz.artifact("miniz"));
    lib.root_module.linkLibrary(dep_ada.artifact("ada"));
    lib.installLibraryHeaders(dep_ada.artifact("ada"));
    lib.root_module.linkLibrary(mbedtls);
    lib.root_module.linkLibrary(mbedx509);
    lib.root_module.linkLibrary(mbedcrypto);
    lib.installLibraryHeaders(mbedtls);

    if (opts.with_ffi) {
        lib.root_module.linkLibrary(libffi.?);
        lib.installLibraryHeaders(libffi.?);
    }

    if (opts.with_sqlite) {
        lib.root_module.linkLibrary(dep_sqlite3.?.artifact("sqlite3"));
        lib.installLibraryHeaders(dep_sqlite3.?.artifact("sqlite3"));
    }

    if (opts.with_wasm) {
        lib.root_module.linkLibrary(wamr.?);
        lib.installLibraryHeaders(wamr.?);
        lib.root_module.addIncludePath(wamr.?.getEmittedIncludeTree());
        addWamrSourceIncludePaths(b, lib.root_module, dep_wamr.?.namedLazyPath("source"), target);
        addWamrRuntimeCMacros(lib.root_module, wamr_config.?, target, optimize);
    }

    if (opts.with_mimalloc) {
        lib.root_module.linkLibrary(mimalloc.?);
        lib.installLibraryHeaders(mimalloc.?);
    }

    if (opts.with_network) {
        lib.root_module.linkLibrary(libwebsockets.?);
        lib.installLibraryHeaders(libwebsockets.?);
    }

    if (target.result.os.tag != .windows and !target.result.abi.isAndroid()) {
        lib.root_module.linkSystemLibrary("pthread", .{});
    }

    var cflags = std.array_list.Managed([]const u8).init(b.allocator);

    try cflags.appendSlice(&.{
        "-Wall",
    });
    if (optimize == .Debug) {
        try cflags.appendSlice(&.{
            "-ggdb",
            "-fno-omit-frame-pointer",
            // something somewhere relies on undefined behavior. Adding this fixes a couple of of tests
            "-fno-sanitize=undefined",
        });
    }
    if (target.result.os.tag == .windows) {
        // Zig may pass link-only flags (e.g. -fno-rtlib-defaultlib) to the C driver; accept them quietly.
        try cflags.append("-Qunused-arguments");
    }

    lib.root_module.addIncludePath(b.path("src"));

    lib.root_module.addCSourceFiles(.{
        .files = &.{
            "src/builtins.c",
            "src/cacert.c",
            "src/error.c",
            "src/lws-evlib.c",
            "src/lws-utils.c",
            "src/eval.c",
            "src/mem.c",
            "src/modules.c",
            "src/tbuf.c",
            "src/signals.c",
            "src/text-coding.c",
            "src/timers.c",
            "src/utils.c",
            "src/version.c",
            "src/vm.c",
            "src/worker.c",
            "src/ws.c",
            "src/httpclient.c",
            "src/httpserver.c",
            "src/mod_channel.c",
            "src/mod_dns.c",
            "src/mod_engine.c",
            "src/mod_fs.c",
            "src/mod_fswatch.c",
            "src/mod_hashing.c",
            "src/mod_os.c",
            "src/mod_process.c",
            "src/mod_miniz.c",
            "src/mod_streams.c",
            "src/mod_tls.c",
            "src/ed25519.c",
            "src/webcrypto.c",
            "src/mod_sys.c",
            "src/mod_udp.c",
            "src/url.c",
            "src/bundles/c/core/core.c",
            "src/bundles/c/core/polyfills.c",
            "src/bundles/c/core/run-main.c",
            "src/bundles/c/core/run-repl.c",
            "src/bundles/c/core/worker-bootstrap.c",
        },
        .flags = cflags.items,
    });
    if (opts.with_wasm) {
        lib.root_module.addCSourceFile(.{ .file = b.path("src/wasm.c"), .flags = cflags.items });
    }
    if (opts.with_sqlite) {
        lib.root_module.addCSourceFile(.{ .file = b.path("src/mod_sqlite3.c"), .flags = cflags.items });
    }
    if (opts.with_ffi) {
        lib.root_module.addCSourceFile(.{ .file = b.path("src/mod_ffi.c"), .flags = cflags.items });
    }
    if (opts.with_network and (target.result.os.tag == .linux or target.result.os.tag.isBSD())) {
        lib.root_module.addCSourceFiles(.{
            .files = &.{"src/mod_posix-socket.c"},
            .flags = cflags.items,
        });
    }

    lib.root_module.addCMacro("TJS__PLATFORM", tjs_platform);
    lib.root_module.addCMacro("TJS__HAS_ZIG_MODULES", "1");
    if (opts.with_sqlite) {
        lib.root_module.addCMacro("TJS_HAVE_SQLITE", "1");
    }
    if (!opts.with_sqlite_load_extensions) {
        lib.root_module.addCMacro("TJS__OMIT_SQLITE_LOAD_EXTENSION", "1");
    }
    if (!opts.with_crypto) {
        lib.root_module.addCMacro("TJS__OMIT_CRYPTO", "1");
    }
    if (opts.with_ffi) {
        lib.root_module.addCMacro("TJS_HAVE_FFI", "1");
    }
    if (opts.with_wasm) {
        lib.root_module.addCMacro("TJS_HAVE_WASM", "1");
    }
    if (opts.with_mimalloc) {
        lib.root_module.addCMacro("TJS__HAS_MIMALLOC", "1");
    }
    if (!opts.with_network) {
        lib.root_module.addCMacro("TJS__OMIT_NETWORK", "1");
    }
    if (!opts.with_subprocess) {
        lib.root_module.addCMacro("TJS__OMIT_SUBPROCESS", "1");
    }
    if (!opts.with_ipc) {
        lib.root_module.addCMacro("TJS__OMIT_IPC", "1");
    }

    const tjs = b.addExecutable(.{
        .name = "tjs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tjs.root_module.linkLibrary(lib);
    tjs.root_module.addCSourceFile(.{
        .file = b.path("src/cli.c"),
        .flags = cflags.items,
    });

    const tjsc = b.addExecutable(.{
        .name = "tjsc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tjsc.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
    tjsc.root_module.addCSourceFile(.{
        .file = b.path("src/qjsc.c"),
        .flags = cflags.items,
    });

    if (opts.with_sqlite and opts.with_sqlite_load_extensions and !opts.matrix) {
        const sqlite_ext_test = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "sqlite-test",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        sqlite_ext_test.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/sqlite-test-ext.c") });
        sqlite_ext_test.root_module.linkLibrary(dep_sqlite3.?.artifact("sqlite3"));
        const art = b.addInstallArtifact(sqlite_ext_test, .{
            .dest_dir = .{
                .override = .{ .custom = "../build/" },
            },
        });
        tjs.step.dependOn(&art.step);
    }

    if (opts.with_ffi and !opts.matrix) {
        const ffi_test = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "ffi-test",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        ffi_test.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/ffi-test-lib.c") });
        const art = b.addInstallArtifact(ffi_test, .{
            .dest_dir = .{
                .override = .{ .custom = "../build/" },
            },
        });
        tjs.step.dependOn(&art.step);
    }

    if (!opts.matrix) {
        const exe = b.addExecutable(.{
            .name = "playground",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/v8_serialize_test.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
                .imports = &.{
                    .{ .name = "c", .module = c_mod },
                },
            }),
        });
        exe.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
        exe.root_module.linkLibrary(libuv);
        exe.root_module.linkLibrary(dep_miniz.artifact("miniz"));
        exe.root_module.linkLibrary(dep_ada.artifact("ada"));
        exe.installLibraryHeaders(libuv);
        exe.installLibraryHeaders(dep_miniz.artifact("miniz"));
        exe.installLibraryHeaders(dep_ada.artifact("ada"));
        exe.root_module.addIncludePath(b.path("src"));
        if (opts.with_sqlite) {
            exe.root_module.linkLibrary(dep_sqlite3.?.artifact("sqlite3"));
            exe.installLibraryHeaders(dep_sqlite3.?.artifact("sqlite3"));
        }
        if (opts.with_wasm) {
            exe.root_module.linkLibrary(wamr.?);
            exe.installLibraryHeaders(wamr.?);
        }
        b.installArtifact(exe);

        const art_run = b.addRunArtifact(exe);
        const run_step = b.step("playground", "");
        run_step.dependOn(&art_run.step);

        const test_step = b.step("test", "Run unit tests for zig modules");
        const test_filters: []const []const u8 = if (opts.test_filter) |filter| &.{filter} else &.{};
        const unit_tests = b.addTest(.{
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/v8_serialize_test.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
                .imports = &.{
                    .{ .name = "c", .module = c_mod },
                },
            }),
        });
        // unit_tests.root_module.addCMacro("DUMP_LEAKS", "1");
        unit_tests.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
        unit_tests.root_module.linkLibrary(libuv);
        unit_tests.root_module.linkLibrary(dep_miniz.artifact("miniz"));
        unit_tests.root_module.linkLibrary(dep_ada.artifact("ada"));
        unit_tests.installLibraryHeaders(libuv);
        unit_tests.installLibraryHeaders(dep_miniz.artifact("miniz"));
        unit_tests.installLibraryHeaders(dep_ada.artifact("ada"));
        if (opts.with_sqlite) {
            unit_tests.root_module.linkLibrary(dep_sqlite3.?.artifact("sqlite3"));
            unit_tests.installLibraryHeaders(dep_sqlite3.?.artifact("sqlite3"));
        }
        if (opts.with_wasm) {
            unit_tests.root_module.linkLibrary(wamr.?);
            unit_tests.installLibraryHeaders(wamr.?);
        }
        unit_tests.root_module.addIncludePath(b.path("src"));

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    return .{ tjs, tjsc };
}

fn loadWamrConfig(b: *std.Build, path: std.Build.LazyPath) !WamrConfig {
    const ac = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const zon_buffer = try cwd.readFileAllocOptions(
        io,
        path.getPath(b),
        ac,
        std.Io.Limit.limited(1024 * 1024),
        std.mem.Alignment.@"1",
        0,
    );
    return std.zon.parse.fromSliceAlloc(WamrConfig, ac, zon_buffer, null, .{ .ignore_unknown_fields = true });
}

fn freeWamrConfig(b: *std.Build, config: WamrConfig) void {
    std.zon.parse.free(b.allocator, config);
}

fn addWamrRuntimeCMacros(
    mod: *std.Build.Module,
    config: WamrConfig,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    for (config.wasm_macros) |macro| {
        mod.addCMacro(macro.name, macro.value);
    }

    if (optimize == .Debug) {
        mod.addCMacro("BH_DEBUG", "1");
    }
    if (target.result.os.tag == .linux) {
        mod.addCMacro("WASM_HAVE_MREMAP", "1");
        mod.addCMacro("_GNU_SOURCE", "1");
    } else {
        mod.addCMacro("WASM_HAVE_MREMAP", "0");
    }
}

fn addWamrSourceIncludePaths(
    b: *std.Build,
    mod: *std.Build.Module,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
) void {
    mod.addIncludePath(source.path(b, "core/iwasm/include"));
    mod.addIncludePath(source.path(b, "core/iwasm/common"));
    mod.addIncludePath(source.path(b, "core/iwasm/interpreter"));
    mod.addIncludePath(source.path(b, "core/shared/utils"));
    mod.addIncludePath(source.path(b, "core/shared/platform/include"));
    mod.addIncludePath(source.path(b, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/include"));
    mod.addIncludePath(source.path(b, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src"));

    if (target.result.os.tag.isDarwin()) {
        mod.addIncludePath(source.path(b, "core/shared/platform/darwin"));
    } else if (target.result.os.tag == .windows) {
        mod.addIncludePath(source.path(b, "core/shared/platform/windows"));
    } else {
        mod.addIncludePath(source.path(b, "core/shared/platform/linux"));
    }
}

fn usizeToStr(allocator: std.mem.Allocator, value: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{}", .{value});
}

pub fn build(b: *std.Build) !void {
    const std_query = b.standardTargetOptionsQueryOnly(.{});
    const std_optimize = b.standardOptimizeOption(.{});

    const opt_matrix = b.option(bool, "matrix", "Cross-compile to all targets that are known to work") orelse false;
    const opt_no_mimalloc = b.option(bool, "no-mimalloc", "If set, build without mimalloc") orelse false;
    const opt_no_wasm = b.option(bool, "no-wasm", "If set, build without WAMR (WASM)") orelse false;
    const opt_no_sqlite = b.option(bool, "no-sqlite", "If set, build without sqlite3") orelse false;
    const opt_no_sqlite_extensions = b.option(bool, "no-sqlite-extensions", "If set, disable loading dynamic SQLite extensions") orelse false;
    const opt_no_network = b.option(bool, "no-network", "If set, build without network support (IPC pipes remain)") orelse false;
    const opt_no_ipc = b.option(bool, "no-ipc", "If set, disable path-based IPC connections and listeners (stdio pipes remain)") orelse false;
    const opt_no_crypto = b.option(bool, "no-crypto", "If set, build without WebCrypto algorithms (secure random APIs remain)") orelse false;
    const opt_no_ffi = b.option(bool, "no-ffi", "If set, build without native FFI support") orelse false;
    const opt_no_subprocess = b.option(bool, "no-subprocess", "If set, disable process creation and control (tjs.spawn, tjs.exec, tjs.kill)") orelse false;
    // const opt_external_ffi = b.option(bool, "external-ffi", "Specify to use external ffi dependency") orelse false;

    {
        const ac = b.allocator;
        const io = b.graph.io;
        const cwd = std.Io.Dir.cwd();

        const zon_buffer = try cwd.readFileAllocOptions(io, "build.zig.zon", ac, std.Io.Limit.limited(1024 * 1024), std.mem.Alignment.@"1", 0);
        const zon_parsed = try std.zon.parse.fromSliceAlloc(BuildZon, ac, zon_buffer, null, .{ .ignore_unknown_fields = true });
        defer std.zon.parse.free(ac, zon_parsed);
        const tjs_version = try std.SemanticVersion.parse(zon_parsed.version);

        var buf0 = try cwd.readFileAlloc(io, b.path("src/version.h.in").getPath(b), ac, std.Io.Limit.limited(1024 * 1024));
        var buf1 = try std.mem.replaceOwned(u8, ac, buf0, "@TJS__VERSION_MAJOR@", try usizeToStr(ac, tjs_version.major));
        buf0 = try std.mem.replaceOwned(u8, ac, buf1, "@TJS__VERSION_MINOR@", try usizeToStr(ac, tjs_version.minor));
        buf1 = try std.mem.replaceOwned(u8, ac, buf0, "@TJS__VERSION_PATCH@", try usizeToStr(ac, tjs_version.patch));
        buf0 = try std.mem.replaceOwned(u8, ac, buf1, "@TJS__VERSION_SUFFIX@", if (tjs_version.pre) |s| try std.fmt.allocPrint(ac, "-{s}", .{s}) else "");
        const f = try cwd.createFile(io, b.path("src/version.h").getPath(b), .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, buf0);
    }

    // Host-only helper; shared by every translate-c + sanitize pipeline (including matrix builds).
    const sanitize_tjs_c_import_exe = b.addExecutable(.{
        .name = "sanitize_tjs_c_import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_sanitize_tjs_c_import.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    if (opt_matrix) {
        for (targets) |q| {
            const tjs, const tjsc = try build2(b, q, std_optimize, .{
                .with_mimalloc = !opt_no_mimalloc,
                .with_wasm = !opt_no_wasm,
                .with_sqlite = !opt_no_sqlite,
                .with_sqlite_load_extensions = !opt_no_sqlite_extensions,
                .with_network = !opt_no_network,
                .with_ipc = !opt_no_ipc,
                .with_crypto = !opt_no_crypto,
                .with_ffi = !opt_no_ffi,
                .with_subprocess = !opt_no_subprocess,
                .matrix = true,
            }, sanitize_tjs_c_import_exe);

            if (tjs == null or tjsc == null) {
                continue;
            }

            const tjs_output = b.addInstallArtifact(tjs.?, .{ .dest_dir = .{
                .override = .{
                    .custom = try q.zigTriple(b.allocator),
                },
            } });
            const tjsc_output = b.addInstallArtifact(tjsc.?, .{ .dest_dir = .{
                .override = .{
                    .custom = try q.zigTriple(b.allocator),
                },
            } });

            b.getInstallStep().dependOn(&tjs_output.step);
            b.getInstallStep().dependOn(&tjsc_output.step);
        }

        return;
    }

    const test_filter = b.option([]const u8, "test-filter", "Filter unit tests by name substring");

    const tjs, const tjsc = try build2(b, std_query, std_optimize, .{
        .with_mimalloc = !opt_no_mimalloc,
        .with_wasm = !opt_no_wasm,
        .with_sqlite = !opt_no_sqlite,
        .with_sqlite_load_extensions = !opt_no_sqlite_extensions,
        .with_network = !opt_no_network,
        .with_ipc = !opt_no_ipc,
        .with_crypto = !opt_no_crypto,
        .with_ffi = !opt_no_ffi,
        .with_subprocess = !opt_no_subprocess,
        .matrix = false,
        .test_filter = test_filter,
    }, sanitize_tjs_c_import_exe);

    b.installArtifact(tjs.?);
    b.installArtifact(tjsc.?);

    const art_run = b.addRunArtifact(tjs.?);

    const opt_test = b.option(bool, "test", "Combine with run to run tests after compilation") orelse false;
    if (opt_test) {
        art_run.addArg("test");
        art_run.addDirectoryArg(b.path("tests"));
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&art_run.step);
}
