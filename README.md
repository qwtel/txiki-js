A fork of [txiki.js](https://github.com/saghul/txiki.js) with support for cross-compilation via Zig build. 

Also includes a module that implements [Node's V8 serialization format](https://nodejs.org/api/v8.html#serialization-api) written in Zig, 
which is the fastest way to send data from node to tjs and vice-versa. Can be imported as `tjs:v8`.

Caveats
- Network (libcurl) and FFI are disabled because I don't need them for my use case
- Building for macOS currenlty only works on macOS. For more, see [here](https://github.com/ziglang/zig/issues/19217).
