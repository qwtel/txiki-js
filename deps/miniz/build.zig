const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "miniz",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("."));

    const miniz_cflags: []const []const u8 = if (target.result.os.tag == .windows)
        &.{ "-std=c11" }
    else
        &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L" };

    lib.root_module.addCSourceFile(.{
        .file = b.path("miniz.c"),
        .flags = miniz_cflags,
    });
    lib.installHeadersDirectory(b.path("."), "", .{});

    b.installArtifact(lib);
}
