A fork of [txiki.js](https://github.com/saghul/txiki.js) with support for cross-compilation via Zig build.

This version also includes a module that implements [Node's V8 serialization format](https://nodejs.org/api/v8.html#serialization-api), written in Zig, which is the fastest way to exchange data with Node.js. It can be imported as `tjs:v8`.

## Building with Zig

Native build (host target, default options):

```sh
zig build
```

The Zig build logic for dependencies lives in this repository under `deps/build/`,
while the dependency directories themselves remain upstream submodules. A
dependency can also be built on its own, for example:

```sh
zig build --build-file deps/build/libffi/build.zig -Dtarget=aarch64-windows-gnu
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
| `-Dno-sqlite-extensions` | Disable loading dynamic SQLite extensions |
| `-Dno-network` | Build without HTTP/WebSocket (libwebsockets stack) |
| `-Dno-ipc` | Disable path-based IPC connections/listeners while retaining stdio pipes |
| `-Dno-crypto` | Build without Web Crypto and global `crypto` |
| `-Dno-ffi` | Build without native FFI (the official `libffi` submodule) |
| `-Dno-subprocess` | Disable `tjs.spawn`, `tjs.exec`, and `tjs.kill` |

Build with several features disabled:

```sh
zig build -Dno-ffi -Dno-network -Doptimize=ReleaseSmall
```

## Caveats

- Building for macOS with mimalloc expects header files for `CommonCrypto` under `deps/mimalloc/include`. Those headers are not redistributable and are omitted from this repository; supply them locally where required.
