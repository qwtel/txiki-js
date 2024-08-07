const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sqlite3 = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_quickjs = b.dependency("quickjs", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_libuv = b.dependency("libuv", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_wasm3 = b.dependency("wasm3", .{
        .target = target,
        .optimize = optimize,
        .libm3 = true,
    });
    const dep_mimalloc = b.dependency("mimalloc", .{
        .target = target,
        .optimize = optimize,
    });

    const build_with_mimalloc = b.option(bool, "build-with-mimalloc", "If true (default), build with mimalloc") orelse true;
    // const use_external_ffi = b.option(bool, "use-external-ffi", "Specify to use external ffi dependency") orelse false;

    const lib = b.addStaticLibrary(.{
        .name = "tjs",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibrary(dep_quickjs.artifact("qjs"));
    lib.linkLibrary(dep_libuv.artifact("uv_a"));
    lib.linkLibrary(dep_sqlite3.artifact("sqlite3"));
    lib.linkLibrary(dep_wasm3.artifact("m3"));
    if (build_with_mimalloc) {
        lib.linkLibrary(dep_mimalloc.artifact("mimalloc-static"));
    }

    lib.installLibraryHeaders(dep_quickjs.artifact("qjs"));
    lib.installLibraryHeaders(dep_libuv.artifact("uv_a"));
    lib.installLibraryHeaders(dep_sqlite3.artifact("sqlite3"));
    lib.installLibraryHeaders(dep_wasm3.artifact("m3"));
    if (build_with_mimalloc) {
        lib.installLibraryHeaders(dep_mimalloc.artifact("mimalloc-static"));
    }

    if (target.result.os.tag != .windows and !target.result.isAndroid()) {
        lib.linkSystemLibrary("pthread");
    }

    var cflags = std.ArrayList([]const u8).init(b.allocator);
    defer cflags.deinit();

    try cflags.appendSlice(&.{
        "-Wall",
        // something somewhere relies on undefined behavior. Adding this fixes a couple of of tests
        "-fno-sanitize=all",
    });
    if (optimize == .Debug) {
        try cflags.appendSlice(&.{
            "-ggdb",
            "-fno-omit-frame-pointer",
        });
    }

    lib.addIncludePath(b.path("src"));

    lib.addCSourceFiles(.{
        .files = &.{
            "src/builtins.c",
            // "src/curl-utils.c",
            // "src/curl-websocket.c",
            "src/error.c",
            "src/eval.c",
            "src/mem.c",
            "src/modules.c",
            "src/sha1.c",
            "src/signals.c",
            "src/timers.c",
            "src/utils.c",
            "src/version.c",
            "src/vm.c",
            "src/wasm.c",
            "src/worker.c",
            // "src/ws.c",
            // "src/xhr.c",
            "src/mod_dns.c",
            "src/mod_engine.c",
            // "src/mod_ffi.c",
            "src/mod_fs.c",
            "src/mod_fswatch.c",
            "src/mod_os.c",
            "src/mod_process.c",
            "src/mod_sqlite3.c",
            "src/mod_streams.c",
            "src/mod_sys.c",
            "src/mod_udp.c",
            "src/bundles/c/core/core.c",
            "src/bundles/c/core/polyfills.c",
            "src/bundles/c/core/run-main.c",
            "src/bundles/c/core/run-repl.c",
            "src/bundles/c/core/worker-bootstrap.c",
        },
        .flags = cflags.items,
    });
    if (target.result.os.tag == .linux or target.result.isBSD()) {
        lib.addCSourceFiles(.{
            .files = &.{"src/mod_posix-socket.c"},
            .flags = cflags.items,
        });
    }

    const tjs_platform = try std.fmt.allocPrint(
        b.allocator,
        "\"{s}\"",
        .{if (target.result.isDarwin()) "darwin" else @tagName(target.result.os.tag)},
    );
    lib.defineCMacro("TJS__PLATFORM", tjs_platform);

    if (build_with_mimalloc) {
        lib.defineCMacro("TJS__HAS_MIMALLOC", "1");
    }

    lib.linkLibC();

    b.installArtifact(lib);

    const tjs = b.addExecutable(.{
        .name = "tjs",
        .target = target,
        .optimize = optimize,
    });
    tjs.linkLibrary(lib);
    tjs.addCSourceFile(.{
        .file = b.path("src/cli.c"),
        .flags = cflags.items,
    });

    tjs.linkLibC();

    b.installArtifact(tjs);

    const tjsc = b.addExecutable(.{
        .name = "tjsc",
        .target = target,
        .optimize = optimize,
    });
    tjsc.linkLibrary(dep_quickjs.artifact("qjs"));
    tjsc.addCSourceFile(.{
        .file = b.path("src/qjsc.c"),
        .flags = cflags.items,
    });

    tjsc.linkLibC();

    b.installArtifact(tjsc);
}
