// Order is important!

const core = globalThis[Symbol.for('tjs.internal.core')];

import './global.js';
import './timers.js';
import './event-target-polyfill.js';
import './structured-clone.js';

import './abba.js';
import './text-encoding.js';
import './text-encode-transform.js';
import './url.js';

import './navigator.js';

import './blob.js';
import './file.js';
import './file-reader.js';
import './form-data.js';
import './abort-controller.js';

import './console.js';
if ('webcrypto' in core) {
    await import('./crypto/crypto.js');
}
import './performance.js';
import './worker.js';

import 'web-streams-polyfill/polyfill';
import './compression-streams.js';

// XXX: Could remove it form the build entirely by using --define in esbuild.
// But since it's only a couples LoCs it's not really worth it.
if ('HttpClient' in core && 'WebSocket' in core && 'HttpServer' in core) {
    await import('./xhr.js');
    await import('./fetch/polyfill.js');
    await import('./ws.js');
    await import('./ws-stream.js');
}

if ('sqlite3' in core) {
    await import('./storage.js');
}

if ('wasm' in core) {
    await import('./wasm.js');
}
