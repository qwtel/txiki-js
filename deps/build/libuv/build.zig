const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.installArtifact(try add(b, b.path("../../libuv"), target, optimize));
}

pub fn add(
    b: *std.Build,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "uv_a",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Include dirs
    lib.root_module.addIncludePath(source.path(b, "include"));
    lib.root_module.addIncludePath(source.path(b, "src"));

    const result = target.result;
    const os = result.os;

    var uv_defines = std.array_list.Managed([]const []const u8).init(b.allocator);
    var uv_sources = std.array_list.Managed([]const u8).init(b.allocator);
    var uv_cflags = std.array_list.Managed([]const u8).init(b.allocator);

    // TODO: add lint flags from cmakelist.txt?
    try uv_cflags.appendSlice(&.{
        "-std=gnu90", // Should be equivalent to C90 + USE EXTENSIONS
        "-fvisibility=hidden",
        "-Wall",
        "-fno-strict-aliasing",
    });

    try uv_sources.appendSlice(&.{
        "src/fs-poll.c",
        "src/idna.c",
        "src/inet.c",
        "src/random.c",
        "src/strscpy.c",
        "src/strtok.c",
        "src/thread-common.c",
        "src/threadpool.c",
        "src/timer.c",
        "src/uv-common.c",
        "src/uv-data-getter-setters.c",
        "src/version.c",
    });

    // Links
    if (result.os.tag == .windows) {
        try uv_defines.append(&.{ "WIN32_LEAN_AND_MEAN", "1" });
        try uv_defines.append(&.{ "_WIN32_WINNT", "0x0602" });
        try uv_defines.append(&.{ "_CRT_DECLARE_NONSTDC_NAMES", "0" });

        lib.root_module.linkSystemLibrary("psapi", .{});
        lib.root_module.linkSystemLibrary("user32", .{});
        lib.root_module.linkSystemLibrary("advapi32", .{});
        lib.root_module.linkSystemLibrary("iphlpapi", .{});
        lib.root_module.linkSystemLibrary("userenv", .{});
        lib.root_module.linkSystemLibrary("ws2_32", .{});
        lib.root_module.linkSystemLibrary("dbghelp", .{});
        lib.root_module.linkSystemLibrary("ole32", .{});
        lib.root_module.linkSystemLibrary("shell32", .{});

        try uv_sources.appendSlice(&.{
            "src/win/async.c",
            "src/win/core.c",
            "src/win/detect-wakeup.c",
            "src/win/dl.c",
            "src/win/error.c",
            "src/win/fs.c",
            "src/win/fs-event.c",
            "src/win/getaddrinfo.c",
            "src/win/getnameinfo.c",
            "src/win/handle.c",
            "src/win/loop-watcher.c",
            "src/win/pipe.c",
            "src/win/thread.c",
            "src/win/poll.c",
            "src/win/process.c",
            "src/win/process-stdio.c",
            "src/win/signal.c",
            "src/win/snprintf.c",
            "src/win/stream.c",
            "src/win/tcp.c",
            "src/win/tty.c",
            "src/win/udp.c",
            "src/win/util.c",
            "src/win/winapi.c",
            "src/win/winsock.c",
        });
    } else {
        try uv_defines.append(&.{ "_FILE_OFFSET_BITS", "64" });
        try uv_defines.append(&.{ "_LARGEFILE_SOURCE", "1" });
        if (!result.abi.isAndroid()) {
            lib.root_module.linkSystemLibrary("pthread", .{});
        }

        try uv_sources.appendSlice(&.{
            "src/unix/async.c",
            "src/unix/core.c",
            "src/unix/dl.c",
            "src/unix/fs.c",
            "src/unix/getaddrinfo.c",
            "src/unix/getnameinfo.c",
            "src/unix/loop-watcher.c",
            "src/unix/loop.c",
            "src/unix/pipe.c",
            "src/unix/poll.c",
            "src/unix/process.c",
            "src/unix/random-devurandom.c",
            "src/unix/signal.c",
            "src/unix/stream.c",
            "src/unix/tcp.c",
            "src/unix/thread.c",
            "src/unix/tty.c",
            "src/unix/udp.c",
        });
    }

    if (result.abi.isAndroid()) {
        try uv_defines.append(&.{ "_GNU_SOURCE", "1" });
        lib.root_module.linkSystemLibrary("dl", .{});
        try uv_sources.appendSlice(&.{
            "src/unix/linux.c",
            "src/unix/procfs-exepath.c",
            "src/unix/random-getentropy.c",
            "src/unix/random-getrandom.c",
            "src/unix/random-sysctl-linux.c",
        });
    }

    if (result.os.tag.isDarwin() or result.abi.isAndroid() or os.tag == .linux) {
        try uv_sources.appendSlice(&.{
            "src/unix/proctitle.c",
        });
    }

    if (os.tag == .dragonfly or os.tag == .freebsd) {
        try uv_sources.appendSlice(&.{
            "src/unix/freebsd.c",
        });
    }

    if (os.tag == .dragonfly or os.tag == .freebsd or os.tag == .netbsd or os.tag == .openbsd) {
        try uv_sources.appendSlice(&.{
            "src/unix/posix-hrtime.c",
            "src/unix/bsd-proctitle.c",
        });
    }

    if (result.os.tag.isBSD()) { // incl Drawin
        try uv_sources.appendSlice(&.{
            "src/unix/bsd-ifaddrs.c",
            "src/unix/kqueue.c",
        });
    }

    if (os.tag == .freebsd) {
        try uv_sources.appendSlice(&.{
            "src/unix/random-getrandom.c",
        });
    }

    if (result.os.tag.isDarwin() or os.tag == .openbsd) {
        try uv_sources.appendSlice(&.{
            "src/unix/random-getentropy.c",
        });
    }

    if (result.os.tag.isDarwin()) {
        try uv_defines.append(&.{ "_DARWIN_UNLIMITED_SELECT", "1" });
        try uv_defines.append(&.{ "_DARWIN_USE_64_BIT_INODE", "1" });
        try uv_sources.appendSlice(&.{
            "src/unix/darwin-proctitle.c",
            "src/unix/darwin.c",
            "src/unix/fsevents.c",
        });
    }

    if (os.tag == .hurd and result.abi.isGnu()) {
        lib.root_module.linkSystemLibrary("dl", .{});
        try uv_sources.appendSlice(&.{
            "src/unix/bsd-ifaddrs.c",
            "src/unix/no-fsevents.c",
            "src/unix/no-proctitle.c",
            "src/unix/posix-hrtime.c",
            "src/unix/posix-poll.c",
            "src/unix/hurd.c",
        });
    }

    if (os.tag == .linux) {
        try uv_defines.append(&.{ "_GNU_SOURCE", "1" });
        try uv_defines.append(&.{ "_POSIX_C_SOURCE", "200112" });
        lib.root_module.linkSystemLibrary("dl", .{});
        lib.root_module.linkSystemLibrary("rt", .{});
        try uv_sources.appendSlice(&.{
            "src/unix/linux.c",
            "src/unix/procfs-exepath.c",
            "src/unix/random-getrandom.c",
            "src/unix/random-sysctl-linux.c",
        });
    }

    if (os.tag == .netbsd) {
        try uv_sources.appendSlice(&.{
            "src/unix/netbsd.c",
        });
        lib.root_module.linkSystemLibrary("kvm", .{});
    }

    if (os.tag == .openbsd) {
        try uv_sources.appendSlice(&.{
            "src/unix/openbsd.c",
        });
    }

    if (os.tag == .haiku) {
        try uv_defines.append(&.{ "_BSD_SOURCE", "1" });
        lib.root_module.linkSystemLibrary("bsd", .{});
        lib.root_module.linkSystemLibrary("network", .{});
        try uv_sources.appendSlice(&.{
            "src/unix/haiku.c",
            "src/unix/bsd-ifaddrs.c",
            "src/unix/no-fsevents.c",
            "src/unix/no-proctitle.c",
            "src/unix/posix-hrtime.c",
            "src/unix/posix-poll.c",
        });
    }

    lib.root_module.addCSourceFiles(.{
        .root = source,
        .files = uv_sources.items,
        .flags = uv_cflags.items,
    });

    for (uv_defines.items) |define| {
        lib.root_module.addCMacro(define[0], define[1]);
    }

    lib.installHeadersDirectory(source.path(b, "include"), "", .{});
    return lib;
}
