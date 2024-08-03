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
    });

    // const build_with_mimalloc = b.option(bool, "build-with-mimalloc", "If true (default), build with mimalloc") orelse true;
    // const use_external_ffi = b.option(bool, "use-external-ffi", "Specify to use external ffi dependency") orelse false;

    const lib = b.addStaticLibrary(.{
        .name = "tjs",
        .target = target,
        .optimize = optimize,
    });

    const art_dep_quickjs = dep_quickjs.artifact("qjs");
    const art_dep_libuv = dep_libuv.artifact("uv_a");
    const art_dep_sqlite3 = dep_sqlite3.artifact("sqlite3");
    const art_dep_wasm3 = dep_wasm3.artifact("m3");

    // TODO: libffi, curl

    lib.linkLibrary(art_dep_quickjs);
    lib.linkLibrary(art_dep_libuv);
    lib.linkLibrary(art_dep_sqlite3);
    lib.linkLibrary(art_dep_wasm3);

    lib.installLibraryHeaders(art_dep_quickjs);
    lib.installLibraryHeaders(art_dep_libuv);
    lib.installLibraryHeaders(art_dep_sqlite3);
    lib.installLibraryHeaders(art_dep_wasm3);

    if (target.result.os.tag != .windows and !target.result.isAndroid()) {
        lib.linkSystemLibrary("pthread");
    }

    // XXX: Duplicate from deps/quickjs/build.zig
    if (target.result.os.tag == .linux) {
        lib.defineCMacro("_GNU_SOURCE", "1");
    }
    if (target.result.os.tag == .windows) {
        // XXX: These seem like they should be necessary, but apparently not 🤷‍♂️
        // lib.defineCMacro("WIN32_LEAN_AND_MEAN", "1");
        // lib.defineCMacro("_WIN32_WINNT", "0x0602");
        // XXX: when using this here, it breaks the windows build for some reason (but necessary in quickjs)
        // lib.defineCMacro("_MSC_VER", "1900");
    }

    var cflags = std.ArrayList([]const u8).init(b.allocator);
    defer cflags.deinit();

    try cflags.appendSlice(&.{
        "-std=c11",
        "-Wall",
        "-g",
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
            // "deps/quickjs/cutils.c",
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
        "\"Zig Cross-Compile (os: {s})\"",
        .{@tagName(target.result.os.tag)},
    );
    lib.defineCMacro("TJS__PLATFORM", tjs_platform);

    lib.linkLibC();

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "tjs",
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(lib);
    exe.addCSourceFile(.{ .file = b.path("src/cli.c") });

    exe.linkLibC();

    b.installArtifact(exe);
}
