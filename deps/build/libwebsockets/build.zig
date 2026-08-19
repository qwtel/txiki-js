const std = @import("std");
const lws_configure = @import("configure.zig");

const common_sources = &.{
    "lib/tls/tls.c",
    "lib/tls/tls-network.c",
    "lib/tls/mbedtls/mbedtls-tls.c",
    "lib/tls/mbedtls/mbedtls-extensions.c",
    "lib/tls/mbedtls/mbedtls-x509.c",
    "lib/tls/mbedtls/mbedtls-ssl.c",
    "lib/tls/mbedtls/mbedtls-quic.c",
    "lib/tls/mbedtls/lws-genhash.c",
    "lib/tls/mbedtls/lws-genrsa.c",
    "lib/tls/mbedtls/lws-genaes.c",
    "lib/tls/lws-genec-common.c",
    "lib/tls/mbedtls/lws-genec.c",
    "lib/tls/mbedtls/lws-gencrypto.c",
    "lib/tls/lws-genchacha.c",
    "lib/tls/chacha.c",
    "lib/tls/poly1305.c",
    "lib/tls/tls-server.c",
    "lib/tls/mbedtls/mbedtls-server.c",
    "lib/tls/tls-client.c",
    "lib/tls/mbedtls/mbedtls-client.c",
    "lib/tls/lws-gencrypto-common.c",
    "lib/core/lws_dll2.c",
    "lib/core/alloc.c",
    "lib/core/adapt.c",
    "lib/core/buflist.c",
    "lib/core/context.c",
    "lib/core/lws_map.c",
    "lib/core/libwebsockets.c",
    "lib/core/logs.c",
    "lib/core/vfs.c",
    "lib/misc/base64-decode.c",
    "lib/misc/prng.c",
    "lib/misc/lws-ring.c",
    "lib/misc/cache-ttl/lws-cache-ttl.c",
    "lib/misc/cache-ttl/heap.c",
    "lib/misc/cache-ttl/file.c",
    "lib/misc/lws-crc32.c",
    "lib/misc/dir.c",
    "lib/misc/dir-notify/dir-notify.c",
    "lib/misc/sha-1.c",
    "lib/system/stdin.c",
    "lib/system/system.c",
    "lib/system/policy.c",
    "lib/system/async-dns/async-dns.c",
    "lib/system/async-dns/async-dns-parse.c",
    "lib/core-net/dummy-callback.c",
    "lib/core-net/output.c",
    "lib/core-net/close.c",
    "lib/core-net/network.c",
    "lib/core-net/vhost.c",
    "lib/core-net/pollfd.c",
    "lib/core-net/service.c",
    "lib/core-net/sorted-usec-list.c",
    "lib/core-net/wsi.c",
    "lib/core-net/wsi-timeout.c",
    "lib/core-net/adopt.c",
    "lib/core-net/txpacer.c",
    "lib/core-net/async-ipc.c",
    "lib/core-net/socks5-client.c",
    "lib/roles/pipe/ops-pipe.c",
    "lib/core-net/client/client.c",
    "lib/core-net/client/connect.c",
    "lib/core-net/client/connect2.c",
    "lib/core-net/client/connect3.c",
    "lib/core-net/client/connect4.c",
    "lib/core-net/client/sort-dns.c",
    "lib/roles/http/header.c",
    "lib/roles/http/date.c",
    "lib/roles/http/parsers.c",
    "lib/roles/http/server/server.c",
    "lib/roles/http/server/lws-spa.c",
    "lib/roles/http/server/lejp-conf.c",
    "lib/roles/http/cookie.c",
    "lib/roles/h1/ops-h1.c",
    "lib/roles/h2/hpack.c",
    "lib/roles/h2/http2.c",
    "lib/roles/h2/ops-h2.c",
    "lib/roles/h3/ops-h3.c",
    "lib/roles/h3/qpack.c",
    "lib/roles/quic/crypto-quic.c",
    "lib/roles/quic/ops-quic-cc-cubic.c",
    "lib/roles/quic/ops-quic-cc-newreno.c",
    "lib/roles/quic/ops-quic.c",
    "lib/roles/quic/parse-quic.c",
    "lib/roles/wt/ops-wt.c",
    "lib/roles/ws/ops-ws.c",
    "lib/roles/ws/client-ws.c",
    "lib/roles/ws/client-parser-ws.c",
    "lib/roles/ws/server-ws.c",
    "lib/roles/raw-skt/ops-raw-skt.c",
    "lib/roles/listen/ops-listen.c",
    "lib/roles/http/client/client-http.c",
    "lib/event-libs/poll/poll.c",
};

const unix_sources = &.{
    "lib/plat/unix/unix-caps.c",
    "lib/plat/unix/unix-misc.c",
    "lib/plat/unix/unix-init.c",
    "lib/plat/unix/unix-file.c",
    "lib/plat/unix/unix-pipe.c",
    "lib/plat/unix/unix-service.c",
    "lib/plat/unix/unix-sockets.c",
    "lib/plat/unix/unix-fds.c",
    "lib/plat/unix/unix-resolv.c",
};

const windows_sources = &.{
    "lib/plat/windows/windows-fds.c",
    "lib/plat/windows/windows-file.c",
    "lib/plat/windows/windows-init.c",
    "lib/plat/windows/windows-misc.c",
    "lib/plat/windows/windows-pipe.c",
    "lib/plat/windows/windows-plugins.c",
    "lib/plat/windows/windows-service.c",
    "lib/plat/windows/windows-sockets.c",
    "lib/plat/windows/windows-resolv.c",
    "win32port/win32helpers/gettimeofday.c",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mbedtls = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(try add(
        b,
        b.path("../../libwebsockets"),
        mbedtls.namedLazyPath("source"),
        mbedtls.artifact("mbedtls"),
        mbedtls.artifact("mbedx509"),
        mbedtls.artifact("mbedcrypto"),
        target,
        optimize,
    ));
}

pub fn add(
    b: *std.Build,
    source: std.Build.LazyPath,
    mbedtls_source: std.Build.LazyPath,
    mbedtls_tls: *std.Build.Step.Compile,
    mbedtls_x509: *std.Build.Step.Compile,
    mbedtls_crypto: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const windows = target.result.os.tag == .windows;

    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const pub_in = try cwd.readFileAlloc(io, source.path(b, "cmake/lws_config.h.in").getPath(b), b.allocator, .unlimited);
    defer b.allocator.free(pub_in);
    const priv_in = try cwd.readFileAlloc(io, source.path(b, "cmake/lws_config_private.h.in").getPath(b), b.allocator, .unlimited);
    defer b.allocator.free(priv_in);
    const lws_config_zon = @embedFile("config.zon");
    const pub_out = try lws_configure.generatePublic(b.allocator, pub_in, target.result, optimize, lws_config_zon);
    defer b.allocator.free(pub_out);
    const priv_out = try lws_configure.generatePrivate(b.allocator, priv_in, target.result, lws_config_zon);
    defer b.allocator.free(priv_out);

    const write_files = b.addWriteFiles();
    const lws_config = write_files.add("lws_config.h", pub_out);
    const lws_config_private = write_files.add("lws_config_private.h", priv_out);

    const lib = b.addLibrary(.{
        .name = "websockets",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addCMacro("LWS_BUILDING_STATIC", "1");
    if (windows) {
        lib.root_module.addCMacro("WIN32", "1");
        lib.root_module.addCMacro("WINVER", "0x0601");
        lib.root_module.addCMacro("_WIN32_WINNT", "0x0601");
        lib.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "1");
    }

    lib.step.dependOn(&write_files.step);
    lib.root_module.addIncludePath(write_files.getDirectory());
    lib.root_module.addIncludePath(source.path(b, "include"));
    lib.root_module.addIncludePath(source.path(b, "lib"));
    lib.root_module.addIncludePath(source.path(b, if (windows) "lib/plat/windows" else "lib/plat/unix"));
    if (windows) {
        lib.root_module.addIncludePath(source.path(b, "win32port/win32helpers"));
    }
    lib.root_module.addIncludePath(source.path(b, "lib/tls"));
    lib.root_module.addIncludePath(mbedtls_source.path(b, "include"));
    lib.root_module.addIncludePath(source.path(b, "lib/system/async-dns"));
    lib.root_module.addIncludePath(source.path(b, "lib/system/metrics"));
    lib.root_module.addIncludePath(source.path(b, "lib/event-libs"));
    lib.root_module.addIncludePath(source.path(b, "lib/core"));
    lib.root_module.addIncludePath(source.path(b, "lib/misc"));
    lib.root_module.addIncludePath(source.path(b, "lib/system"));
    lib.root_module.addIncludePath(source.path(b, "lib/core-net"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/http"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/http/compression"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/h1"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/h2"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/h3"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/ws"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/raw-skt"));
    lib.root_module.addIncludePath(source.path(b, "lib/roles/listen"));
    lib.root_module.addIncludePath(source.path(b, "core"));
    lib.root_module.addIncludePath(source.path(b, "lib/secure-streams/serialized/client"));

    var cflags = std.array_list.Managed([]const u8).init(b.allocator);
    try cflags.appendSlice(&.{
        "-std=gnu11",
        "-Wno-deprecated-declarations",
        "-Wno-deprecated",
        "-Wno-unused-parameter",
        "-Wno-undef",
        "-fvisibility=hidden",
    });
    if (target.result.os.tag != .windows and !target.result.abi.isAndroid()) {
        try cflags.append("-pthread");
    }
    if (target.result.abi.isGnu()) {
        try cflags.append("-Wno-discarded-qualifiers");
    }

    var source_files = std.array_list.Managed([]const u8).init(b.allocator);
    try source_files.appendSlice(if (windows) windows_sources else unix_sources);
    try source_files.appendSlice(common_sources);

    lib.root_module.addCSourceFiles(.{ .root = source, .files = source_files.items, .flags = cflags.items });

    lib.root_module.linkLibrary(mbedtls_tls);
    lib.root_module.linkLibrary(mbedtls_x509);
    lib.root_module.linkLibrary(mbedtls_crypto);
    if (target.result.os.tag != .windows and !target.result.abi.isAndroid()) {
        lib.root_module.linkSystemLibrary("pthread", .{});
    }
    if (!windows) {
        lib.root_module.linkSystemLibrary("m", .{});
    }
    if (windows) {
        lib.root_module.linkSystemLibrary("iphlpapi", .{});
        lib.root_module.linkSystemLibrary("userenv", .{});
        lib.root_module.linkSystemLibrary("psapi", .{});
        lib.root_module.linkSystemLibrary("crypt32", .{});
        lib.root_module.linkSystemLibrary("ws2_32", .{});
    }

    lib.installHeadersDirectory(source.path(b, "include"), "", .{});
    lib.installHeader(lws_config, "lws_config.h");
    lib.installHeader(lws_config_private, "lws_config_private.h");

    return lib;
}
