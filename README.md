A fork of [txiki.js](https://github.com/saghul/txiki.js) with support for cross-compilation via Zig build. 

This version also includes a module that implements [Node's V8 serialization format](https://nodejs.org/api/v8.html#serialization-api), written in Zig, which is the fastest way to exchange data with Node.js. It can be imported as `tjs:v8`.

Caveats
- Network (libcurl) and FFI are disabled because I don't need them for my use case
- Building for macOS requires copyrighted header files for `CommonCrypto` in `deps/mimalloc/include`. They have been excluded form this repo
