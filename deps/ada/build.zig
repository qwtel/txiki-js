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
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("."));
    lib.root_module.addCSourceFile(.{
        .file = b.path("ada.cpp"),
        .flags = &.{ "-std=c++20" },
    });
    lib.installHeadersDirectory(b.path("."), "", .{});

    b.installArtifact(lib);
}
