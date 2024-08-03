const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "sqlite3",
        .target = target,
        .optimize = mode,
    });

    lib.addIncludePath(b.path("."));

    const common_flags: []const []const u8 = &.{
        "-DHAVE_INT16_T=1",
        "-DHAVE_INT32_T=1",
        "-DHAVE_INT8_T=1",
        "-DHAVE_STDINT_H=1",
        "-DHAVE_UINT16_T=1",
        "-DHAVE_UINT32_T=1",
        "-DHAVE_UINT8_T=1",
        "-DHAVE_USLEEP=1",
        "-DSQLITE_DEFAULT_CACHE_SIZE=-16384",
        "-DSQLITE_DEFAULT_PAGE_SIZE=8192",
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        //"-DSQLITE_DQS=0",
        "-DSQLITE_ENABLE_COLUMN_METADATA",
        "-DSQLITE_ENABLE_BYTECODE_VTAB",
        "-DSQLITE_ENABLE_OFFSET_SQL_FUNC",
        "-DSQLITE_ENABLE_DBPAGE_VTAB",
        "-DSQLITE_ENABLE_DBSTAT_VTAB",
        "-DSQLITE_ENABLE_EXPLAIN_COMMENTS",
        "-DSQLITE_ENABLE_UNKNOWN_SQL_FUNCTION",
        "-DSQLITE_ENABLE_STMTVTAB",
        "-DSQLITE_ENABLE_DESERIALIZE",
        "-DSQLITE_ENABLE_FTS3",
        "-DSQLITE_ENABLE_FTS3_PARENTHESIS",
        "-DSQLITE_ENABLE_FTS4",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_ENABLE_GEOPOLY",
        "-DSQLITE_ENABLE_JSON1",
        "-DSQLITE_ENABLE_MATH_FUNCTIONS",
        "-DSQLITE_ENABLE_RTREE",
        "-DSQLITE_ENABLE_STAT4",
        "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT",
        //"-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_OMIT_DEPRECATED",
        "-DSQLITE_OMIT_GET_TABLE",
        //"-DSQLITE_OMIT_PROGRESS_CALLBACK",
        "-DSQLITE_OMIT_UTF16",
        "-DSQLITE_OMIT_SHARED_CACHE",
        "-DSQLITE_OMIT_TCL_VARIABLE",
        //"-DSQLITE_SOUNDEX",
        "-DSQLITE_THREADSAFE=2",
        "-DSQLITE_TRACE_SIZE_LIMIT=32",
        "-DSQLITE_USE_URI=0",
        "-DSQLITE_STRICT_SUBTYPE=1",
    };

    var flags = common_flags;
    if (mode == .Debug) {
        const debug_flags: []const []const u8 = &.{
            "-DSQLITE_DEBUG",
            "-DSQLITE_MEMDEBUG",
            "-DSQLITE_ENABLE_API_ARMOR",
            "-DSQLITE_WIN32_MALLOC_VALIDATE",
        };

        flags = common_flags ++ debug_flags;
    }

    lib.addCSourceFile(.{
        .file = b.path("sqlite3.c"),
        .flags = flags,
    });

    lib.linkLibC();

    lib.installHeader(b.path("sqlite3.h"), "sqlite3.h");
    lib.installHeader(b.path("sqlite3ext.h"), "sqlite3ext.h");

    b.installArtifact(lib);
}
