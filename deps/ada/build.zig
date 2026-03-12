const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "ada",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.addIncludePath(b.path("."));
    lib.addCSourceFile(.{
        .file = b.path("ada.cpp"),
        .flags = &.{ "-std=c++20" },
    });
    lib.linkLibC();
    lib.linkLibCpp();
    lib.installHeadersDirectory(b.path("."), "", .{});

    b.installArtifact(lib);
}
