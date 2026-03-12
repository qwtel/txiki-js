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
        }),
    });

    lib.addIncludePath(b.path("."));
    lib.addCSourceFile(.{
        .file = b.path("miniz.c"),
        .flags = &.{ "-std=c11" },
    });
    lib.linkLibC();
    lib.installHeadersDirectory(b.path("."), "", .{});

    b.installArtifact(lib);
}
