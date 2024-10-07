// Order is important!

import './global.js';
import './timers.js';
import './dom-exception.js';
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
import 'abortcontroller-polyfill/dist/abortcontroller-polyfill-only';
// import './xhr.js';
// import './fetch/polyfill.js';

import './console.js';
import './crypto.js';
import './performance.js';
import './worker.js';
// import './ws.js';

import 'web-streams-polyfill/polyfill';
import 'compression-streams-polyfill';

// XXX: Could remove it form the build entirely by using --define in esbuild.
// But since it's only a couples LoCs it's not really worth it.
const core = globalThis[Symbol.for('tjs.internal.core')];
if ('sqlite3' in core) {
    await import('./storage.js');
}

if ('wasm' in core) {
    await import('./wasm.js');
}
