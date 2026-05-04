const std = @import("std");
const builtin = @import("builtin");

const BuildZon = struct {
    version: []const u8,
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
    .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf }, // XXX: only works when wasm is disabled
};

const BuildOpts = struct {
    with_mimalloc: bool,
    with_wasm: bool,
    with_sqlite: bool,
    with_network: bool,
    with_subprocess: bool,
    matrix: bool,
};

fn build2(
    b: *std.Build,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    opts: BuildOpts,
) ![2]?*std.Build.Step.Compile {
    const target = b.resolveTargetQuery(query);

    if (opts.with_wasm and target.result.abi == .gnueabihf) {
        return .{ null, null };
    }

    const dep_sqlite3 = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
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
    const dep_mimalloc = b.dependency("mimalloc", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_mbedtls = if (opts.with_network) b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const dep_libwebsockets = if (opts.with_network) b.dependency("libwebsockets", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const dep_wamr = if (opts.with_wasm) b.dependency("wamr", .{
        .target = target,
        .optimize = optimize,
    }) else null;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tjs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zig_c_bindings.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
    lib.installLibraryHeaders(dep_quickjs.artifact("qjs"));

    lib.root_module.linkLibrary(dep_libuv.artifact("uv_a"));
    lib.installLibraryHeaders(dep_libuv.artifact("uv_a"));
    lib.root_module.linkLibrary(dep_miniz.artifact("miniz"));
    lib.installLibraryHeaders(dep_miniz.artifact("miniz"));
    lib.root_module.linkLibrary(dep_ada.artifact("ada"));
    lib.installLibraryHeaders(dep_ada.artifact("ada"));

    if (opts.with_sqlite) {
        lib.root_module.linkLibrary(dep_sqlite3.artifact("sqlite3"));
        lib.installLibraryHeaders(dep_sqlite3.artifact("sqlite3"));
    }

    if (opts.with_wasm) {
        const wamr = dep_wamr.?;
        lib.root_module.linkLibrary(wamr.artifact("vmlib"));
        lib.installLibraryHeaders(wamr.artifact("vmlib"));
        lib.root_module.addIncludePath(b.path("deps/wamr/core/iwasm/include"));
    }

    if (opts.with_mimalloc) {
        lib.root_module.linkLibrary(dep_mimalloc.artifact("mimalloc-static"));
        lib.installLibraryHeaders(dep_mimalloc.artifact("mimalloc-static"));
    }

    if (opts.with_network) {
        const dep_lws = dep_libwebsockets.?;
        const dep_mtls = dep_mbedtls.?;
        lib.root_module.linkLibrary(dep_lws.artifact("websockets"));
        lib.installLibraryHeaders(dep_lws.artifact("websockets"));
        lib.root_module.linkLibrary(dep_mtls.artifact("mbedtls"));
        lib.root_module.linkLibrary(dep_mtls.artifact("mbedx509"));
        lib.root_module.linkLibrary(dep_mtls.artifact("mbedcrypto"));
        lib.installLibraryHeaders(dep_mtls.artifact("mbedtls"));
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

    lib.root_module.addIncludePath(b.path("src"));

    var c_sources = std.array_list.Managed([]const u8).init(b.allocator);
    try c_sources.appendSlice(&.{
        "src/builtins.c",
        "src/error.c",
        "src/eval.c",
        "src/mem.c",
        "src/modules.c",
        "src/tbuf.c",
        "src/signals.c",
        "src/text-coding.c",
        "src/timers.c",
        "src/url.c",
        "src/utils.c",
        "src/version.c",
        "src/vm.c",
        "src/worker.c",
        "src/mod_engine.c",
        "src/mod_fs.c",
        "src/mod_fswatch.c",
        "src/mod_miniz.c",
        "src/mod_os.c",
        "src/mod_process.c",
        "src/mod_streams.c",
        "src/mod_sys.c",
        "src/bundles/c/core/core.c",
        "src/bundles/c/core/polyfills.c",
        "src/bundles/c/core/run-main.c",
        "src/bundles/c/core/run-repl.c",
        "src/bundles/c/core/worker-bootstrap.c",
    });
    if (opts.with_sqlite) try c_sources.append("src/mod_sqlite3.c");
    if (opts.with_wasm) try c_sources.append("src/wasm.c");
    if (opts.with_network) {
        try c_sources.appendSlice(&.{
            "src/mod_dns.c",
            "src/mod_udp.c",
            "src/lws-utils.c",
            "src/httpclient.c",
            "src/httpserver.c",
            "src/ws.c",
        });
    }
    lib.root_module.addCSourceFiles(.{
        .files = c_sources.items,
        .flags = cflags.items,
    });
    if (target.result.os.tag == .linux or target.result.os.tag.isBSD()) {
        lib.root_module.addCSourceFiles(.{
            .files = &.{"src/mod_posix-socket.c"},
            .flags = cflags.items,
        });
    }

    const tjs_platform = try std.fmt.allocPrint(
        b.allocator,
        "\"{s}\"",
        .{if (target.result.os.tag.isDarwin()) "darwin" else @tagName(target.result.os.tag)},
    );

    lib.root_module.addCMacro("TJS__PLATFORM", tjs_platform);
    if (!opts.with_sqlite) {
        lib.root_module.addCMacro("TJS__OMIT_SQLITE", "1");
    }
    if (!opts.with_wasm) {
        lib.root_module.addCMacro("TJS__OMIT_WASM", "1");
    }
    if (opts.with_mimalloc) {
        lib.root_module.addCMacro("TJS__HAS_MIMALLOC", "1");
    }
    if (opts.with_network) {
        lib.root_module.addCMacro("TJS__HAS_NETWORK", "1");
    }
    if (!opts.with_subprocess) {
        lib.root_module.addCMacro("TJS__OMIT_SUBPROCESS", "1");
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

    if (opts.with_sqlite and !opts.matrix) {
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
        sqlite_ext_test.root_module.linkLibrary(dep_sqlite3.artifact("sqlite3"));
        const art = b.addInstallArtifact(sqlite_ext_test, .{
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
            }),
        });
        exe.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
        exe.root_module.linkLibrary(dep_sqlite3.artifact("sqlite3"));
        exe.root_module.linkLibrary(dep_libuv.artifact("uv_a"));
        exe.root_module.linkLibrary(dep_miniz.artifact("miniz"));
        exe.root_module.linkLibrary(dep_ada.artifact("ada"));
        exe.installLibraryHeaders(dep_libuv.artifact("uv_a"));
        exe.installLibraryHeaders(dep_sqlite3.artifact("sqlite3"));
        exe.installLibraryHeaders(dep_miniz.artifact("miniz"));
        exe.installLibraryHeaders(dep_ada.artifact("ada"));
        exe.root_module.addIncludePath(b.path("src"));
        if (opts.with_wasm) {
            const wamr = dep_wamr.?;
            exe.root_module.linkLibrary(wamr.artifact("vmlib"));
            exe.installLibraryHeaders(wamr.artifact("vmlib"));
        } else {
            exe.root_module.addCMacro("TJS__OMIT_WASM", "1");
        }
        b.installArtifact(exe);

        const art_run = b.addRunArtifact(exe);
        const run_step = b.step("playground", "");
        run_step.dependOn(&art_run.step);

        const test_step = b.step("test", "Run unit tests for zig modules");
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/v8_serialize_test.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });
        // unit_tests.root_module.addCMacro("DUMP_LEAKS", "1");
        unit_tests.root_module.linkLibrary(dep_quickjs.artifact("qjs"));
        unit_tests.root_module.linkLibrary(dep_libuv.artifact("uv_a"));
        unit_tests.root_module.linkLibrary(dep_miniz.artifact("miniz"));
        unit_tests.root_module.linkLibrary(dep_ada.artifact("ada"));
        unit_tests.installLibraryHeaders(dep_libuv.artifact("uv_a"));
        unit_tests.installLibraryHeaders(dep_miniz.artifact("miniz"));
        unit_tests.installLibraryHeaders(dep_ada.artifact("ada"));
        if (opts.with_sqlite) {
            unit_tests.root_module.linkLibrary(dep_sqlite3.artifact("sqlite3"));
            unit_tests.installLibraryHeaders(dep_sqlite3.artifact("sqlite3"));
        } else {
            unit_tests.root_module.addCMacro("TJS__OMIT_SQLITE", "1");
        }
        if (opts.with_wasm) {
            const wamr = dep_wamr.?;
            unit_tests.root_module.linkLibrary(wamr.artifact("vmlib"));
            unit_tests.installLibraryHeaders(wamr.artifact("vmlib"));
        } else {
            unit_tests.root_module.addCMacro("TJS__OMIT_WASM", "1");
        }
        unit_tests.root_module.addIncludePath(b.path("src"));

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    return .{ tjs, tjsc };
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
    const opt_no_sqlite = b.option(bool, "no-sqlite", "If set, build with sqlite3") orelse false;
    const opt_no_network = b.option(bool, "no-network", "If set, build without HTTP/WebSocket support") orelse false;
    const opt_no_subprocess = b.option(bool, "no-subprocess", "If set, disable tjs.spawn and tjs.exec (for sandbox/secure builds)") orelse false;
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

    if (opt_matrix) {
        for (targets) |q| {
            const tjs, const tjsc = try build2(b, q, std_optimize, .{
                .with_mimalloc = !opt_no_mimalloc,
                .with_wasm = !opt_no_wasm,
                .with_sqlite = !opt_no_sqlite,
                .with_network = !opt_no_network,
                .with_subprocess = !opt_no_subprocess,
                .matrix = true,
            });

            if (tjs == null or tjsc == null) {
                continue;
            }

            const tjs_output = b.addInstallArtifact(tjs.?, .{ .dest_dir = .{ .override = .{ .custom = try q.zigTriple(b.allocator) } } });
            const tjsc_output = b.addInstallArtifact(tjsc.?, .{ .dest_dir = .{ .override = .{ .custom = try q.zigTriple(b.allocator), }, } });

            b.getInstallStep().dependOn(&tjs_output.step);
            b.getInstallStep().dependOn(&tjsc_output.step);
        }

        return;
    }

    const tjs, const tjsc = try build2(b, std_query, std_optimize, .{
        .with_mimalloc = !opt_no_mimalloc,
        .with_wasm = !opt_no_wasm,
        .with_sqlite = !opt_no_sqlite,
        .with_network = !opt_no_network,
        .with_subprocess = !opt_no_subprocess,
        .matrix = false,
    });

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
