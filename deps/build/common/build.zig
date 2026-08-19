const std = @import("std");

pub fn build(_: *std.Build) void {}

pub fn ensureApplied(
    b: *std.Build,
    source: std.Build.LazyPath,
    patch: std.Build.LazyPath,
) !void {
    const source_path = source.getPath(b);
    const patch_path = try std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, patch.getPath(b), b.allocator);
    defer b.allocator.free(patch_path);

    if (try check(b, source_path, patch_path, false)) {
        const result = try runGit(b, source_path, &.{ "apply", patch_path });
        defer freeResult(b, result);
        if (!termSucceeded(result.term)) {
            std.log.err("failed to apply {s}:\n{s}", .{ patch_path, result.stderr });
            return error.PatchApplyFailed;
        }
        return;
    }

    if (try check(b, source_path, patch_path, true)) return;

    std.log.err("{s} neither applies nor is already applied in {s}", .{ patch_path, source_path });
    return error.PatchDoesNotApply;
}

fn check(b: *std.Build, source: []const u8, patch: []const u8, reverse: bool) !bool {
    const argv: []const []const u8 = if (reverse)
        &.{ "apply", "--reverse", "--check", patch }
    else
        &.{ "apply", "--check", patch };
    const result = try runGit(b, source, argv);
    defer freeResult(b, result);
    return termSucceeded(result.term);
}

fn runGit(
    b: *std.Build,
    source: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    var argv = std.array_list.Managed([]const u8).init(b.allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "git", "-C", source });
    try argv.appendSlice(args);
    return std.process.run(b.allocator, b.graph.io, .{ .argv = argv.items });
}

fn freeResult(b: *std.Build, result: std.process.RunResult) void {
    b.allocator.free(result.stdout);
    b.allocator.free(result.stderr);
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
