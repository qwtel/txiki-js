const std = @import("std");

pub const Artifacts = struct {
    crypto: *std.Build.Step.Compile,
    x509: *std.Build.Step.Compile,
    tls: *std.Build.Step.Compile,
};

fn classify(path: []const u8) enum { crypto, x509, tls, skip } {
    const base = std.Io.Dir.path.basename(path);

    if (!std.mem.endsWith(u8, base, ".c")) return .skip;
    if (std.mem.startsWith(u8, base, "ssl_") or
        std.mem.eql(u8, base, "debug.c") or
        std.mem.eql(u8, base, "net_sockets.c"))
    {
        return .tls;
    }

    if (std.mem.startsWith(u8, base, "x509") or
        std.mem.startsWith(u8, base, "pkcs") or
        std.mem.startsWith(u8, base, "pk"))
    {
        return .x509;
    }

    return .crypto;
}

fn addMbedtlsLib(
    b: *std.Build,
    source: std.Build.LazyPath,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    files: []const []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(source.path(b, "include"));
    lib.root_module.addIncludePath(source.path(b, "3rdparty/everest/include"));
    lib.root_module.addIncludePath(source);
    lib.root_module.addCSourceFiles(.{
        .root = source,
        .files = files,
        .flags = &.{"-std=c11"},
    });
    return lib;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const patcher = b.lazyImport(@This(), "common") orelse return;
    const source = b.path("../../mbedtls");

    try patcher.ensureApplied(b, source, b.path("../../../patches/mbedtls-quic.patch"));
    const artifacts = try add(b, source, target, optimize);
    b.addNamedLazyPath("source", source);
    b.installArtifact(artifacts.crypto);
    b.installArtifact(artifacts.x509);
    b.installArtifact(artifacts.tls);
}

pub fn add(
    b: *std.Build,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !Artifacts {
    var crypto_files = std.array_list.Managed([]const u8).init(b.allocator);
    var x509_files = std.array_list.Managed([]const u8).init(b.allocator);
    var tls_files = std.array_list.Managed([]const u8).init(b.allocator);

    const io = b.graph.io;
    var lib_dir = try std.Io.Dir.cwd().openDir(io, source.path(b, "library").getPath(b), .{ .iterate = true });
    defer lib_dir.close(io);

    var it = lib_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try std.fmt.allocPrint(b.allocator, "library/{s}", .{entry.name});

        switch (classify(rel)) {
            .crypto => try crypto_files.append(rel),
            .x509 => try x509_files.append(rel),
            .tls => try tls_files.append(rel),
            .skip => {},
        }
    }

    const mbedcrypto = addMbedtlsLib(b, source, "mbedcrypto", target, optimize, crypto_files.items);
    const mbedx509 = addMbedtlsLib(b, source, "mbedx509", target, optimize, x509_files.items);
    const mbedtls = addMbedtlsLib(b, source, "mbedtls", target, optimize, tls_files.items);

    mbedx509.root_module.linkLibrary(mbedcrypto);
    mbedtls.root_module.linkLibrary(mbedx509);
    mbedtls.root_module.linkLibrary(mbedcrypto);
    mbedx509.root_module.linkLibrary(mbedcrypto);

    mbedcrypto.installHeadersDirectory(source.path(b, "include"), "", .{});
    return .{ .crypto = mbedcrypto, .x509 = mbedx509, .tls = mbedtls };
}
