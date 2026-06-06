A fork of [txiki.js](https://github.com/saghul/txiki.js) with support for cross-compilation via Zig build.

This version also includes a module that implements [Node's V8 serialization format](https://nodejs.org/api/v8.html#serialization-api), written in Zig, which is the fastest way to exchange data with Node.js. It can be imported as `tjs:v8`.

## Building with Zig

Native build (host target, default options):

```sh
zig build
```

### Cross-compilation

Pick a target with Zig’s usual triple syntax (see `zig build -h` and `zig targets`). Examples:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
```

To build every combination that is expected to work in this fork (see `targets` in `build.zig`):

```sh
zig build -Dmatrix
```

Each successful triple is installed under `zig-out/bin/<triple>/`.

### Feature flags

All of these are **opt-in disables**: omit the flag to keep the feature; pass `-D<flag>` to turn it off.

| Flag | Effect |
|------|--------|
| `-Dno-mimalloc` | Build without mimalloc |
| `-Dno-wasm` | Build without WAMR (WebAssembly) |
| `-Dno-sqlite` | Build without SQLite |
| `-Dno-network` | Build without HTTP/WebSocket (libwebsockets stack) |
| `-Dno-crypto` | Build without Web Crypto and global `crypto` |
| `-Dno-ffi` | Build without native FFI (`libffi` via pkg-config). **Only applies to native builds** whose triple matches the host; ignored for cross-compiles and `-Dmatrix`. |
| `-Dno-subprocess` | Disable `tjs.spawn` / `tjs.exec`

Native build with several features disabled (FFI matters only when the build triple is the host’s):

```sh
zig build -Dno-ffi -Dno-network -Doptimize=ReleaseSmall
```

## Caveats

- Building for macOS with mimalloc expects header files for `CommonCrypto` under `deps/mimalloc/include`. Those headers are not redistributable and are omitted from this repository; supply them locally where required.
- Cross-compiled binaries never link `libffi`. The build compares the resolved Zig triple to the host triple; if they differ, FFI is off regardless of flags. The same applies to `**-Dmatrix**` (every matrix artifact is built without FFI). Only a **native** build whose triple matches the host can use FFI, and only when you do **not** pass `-Dno-ffi`.

