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
    lib.root_module.addCSourceFile(.{
        .file = b.path("miniz.c"),
        .flags = &.{ "-std=c11" },
    });
    lib.installHeadersDirectory(b.path("."), "", .{});

    b.installArtifact(lib);
}
