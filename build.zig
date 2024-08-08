const std = @import("std");
const builtin = @import("builtin");

const tjs_version: std.SemanticVersion = .{ .major = 24, .minor = 6, .patch = 1, .pre = "" };

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};

fn build2(
    b: *std.Build,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    with_mimalloc: bool,
) ![2]?*std.Build.Step.Compile {
    const target = b.resolveTargetQuery(query);

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

    const lib = b.addStaticLibrary(.{
        .name = "tjs",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibrary(dep_quickjs.artifact("qjs"));
    lib.linkLibrary(dep_libuv.artifact("uv_a"));
    lib.linkLibrary(dep_sqlite3.artifact("sqlite3"));
    lib.linkLibrary(dep_wasm3.artifact("m3"));
    if (with_mimalloc) {
        lib.linkLibrary(dep_mimalloc.artifact("mimalloc-static"));
    }

    lib.installLibraryHeaders(dep_quickjs.artifact("qjs"));
    lib.installLibraryHeaders(dep_libuv.artifact("uv_a"));
    lib.installLibraryHeaders(dep_sqlite3.artifact("sqlite3"));
    lib.installLibraryHeaders(dep_wasm3.artifact("m3"));
    if (with_mimalloc) {
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

    if (with_mimalloc) {
        lib.defineCMacro("TJS__HAS_MIMALLOC", "1");
    }

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

    // XXX: Workaround for outdated libc in Zig for macOS Sonoma. Hopefully this will get fixed sometime. Can only be used on macOS.
    // Need to create new `zig libc > macos-libc.ini` and then replace `include_dir` and `sys_include_dir`
    // with output from `xcrun --show-sdk-path --sdk macosx` ++ `/usr/include`.
    if (target.result.isDarwin()) {
        if (builtin.os.tag == .macos) {
            tjs.setLibCFile(b.path("macos-libc.ini"));
            tjsc.setLibCFile(b.path("macos-libc.ini"));
        } else {
            return .{ null, null };
        }
    } else {
        lib.linkLibC();
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
    const opt_with_mimalloc = b.option(bool, "with-mimalloc", "If true (default), build with mimalloc") orelse true;
    // const opt_external_ffi = b.option(bool, "external-ffi", "Specify to use external ffi dependency") orelse false;

    {
        const ac = b.allocator;
        var buf0 = try std.fs.cwd().readFileAlloc(ac, b.path("src/version.h.in").getPath(b), 4096 * 4);
        var buf1 = try std.mem.replaceOwned(u8, ac, buf0, "@TJS__VERSION_MAJOR@", try usizeToStr(ac, tjs_version.major));
        buf0 = try std.mem.replaceOwned(u8, ac, buf1, "@TJS__VERSION_MINOR@", try usizeToStr(ac, tjs_version.minor));
        buf1 = try std.mem.replaceOwned(u8, ac, buf0, "@TJS__VERSION_PATCH@", try usizeToStr(ac, tjs_version.patch));
        buf0 = try std.mem.replaceOwned(u8, ac, buf1, "@TJS__VERSION_SUFFIX@", tjs_version.pre orelse "");
        const f = try std.fs.cwd().createFile(b.path("src/version.h").getPath(b), .{ .truncate = true });
        defer f.close();
        try f.writeAll(buf0);
    }

    if (opt_matrix) {
        for (targets) |q| {
            const tjs, const tjsc = try build2(b, q, std_optimize, opt_with_mimalloc);

            if (tjs == null or tjsc == null) {
                continue;
            }

            const tjs_output = b.addInstallArtifact(tjs.?, .{
                .dest_dir = .{
                    .override = .{
                        .custom = try q.zigTriple(b.allocator),
                    },
                },
            });
            const tjsc_output = b.addInstallArtifact(tjsc.?, .{
                .dest_dir = .{
                    .override = .{
                        .custom = try q.zigTriple(b.allocator),
                    },
                },
            });

            b.getInstallStep().dependOn(&tjs_output.step);
            b.getInstallStep().dependOn(&tjsc_output.step);
        }

        return;
    }

    const tjs, const tjsc = try build2(b, std_query, std_optimize, opt_with_mimalloc);

    b.installArtifact(tjs.?);
    b.installArtifact(tjsc.?);

    const opt_test = b.option(bool, "test", "Combine with run to run tests after compilation") orelse false;
    const art_run = b.addRunArtifact(tjs.?);
    if (opt_test) {
        art_run.addArg("test");
        art_run.addDirectoryArg(b.path("tests"));
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&art_run.step);
}
