# txiki WAMR maintenance

The upstream WAMR submodule is built by `deps/build/wamr/build.zig`, not by WAMR's CMake.
txiki owns that build logic so cross-compiles use one Zig build graph for WAMR
C, WAMR assembly, and `src/wasm.c`.

When updating WAMR to a newer checkout:

1. Compare these upstream files against the previous version:
   - `build-scripts/runtime_lib.cmake`
   - `build-scripts/config_common.cmake`
   - `core/iwasm/common/iwasm_common.cmake`
   - `core/iwasm/interpreter/iwasm_interp.cmake`
   - `core/iwasm/libraries/libc-builtin/libc_builtin.cmake`
   - `core/iwasm/libraries/libc-wasi/libc_wasi.cmake`
   - `core/shared/platform/*/shared_platform.cmake`
   - `core/shared/platform/common/*/*.cmake`
   - `core/shared/mem-alloc/mem_alloc.cmake`
   - `core/shared/utils/shared_utils.cmake`
2. Port source-list changes into `deps/build/wamr/build.zig`.
3. Port feature macro changes into `deps/build/wamr/config.zon`.
4. Keep `src/wasm.c` compiling with the same `.zon` macros that `vmlib` uses.
   Do not add a second `WASM_ENABLE_*` macro table in either build script.
5. Re-run native and matrix builds with WASM enabled. If a target fails on
   `invokeNative_*.s`, add the correct architecture source or temporarily route
   that target to `core/iwasm/common/arch/invokeNative_general.c` with a comment.

SIMD is currently disabled in `deps/build/wamr/config.zon` because WAMR's CMake fetches
SIMDe for fast-interpreter SIMD support, while this Zig build remains offline
and dependency-free. To enable SIMD, vendor SIMDe or add it as an explicit Zig
package dependency, then enable both `simd` and `simde` in one place.
