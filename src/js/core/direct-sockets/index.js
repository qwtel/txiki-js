import { PipeSocket, PipeServerSocket } from './pipe.js';
import { TCPSocket, TCPServerSocket } from './tcp.js';
import { TLSSocket, TLSServerSocket } from './tls.js';
import { UDPSocket } from './udp.js';

const core = globalThis[Symbol.for('tjs.internal.core')];

export { TCPSocket, TCPServerSocket, TLSSocket, TLSServerSocket, UDPSocket, PipeSocket, PipeServerSocket };

const globals = {
    TCPSocket,
    TCPServerSocket,
    UDPSocket,
    PipeSocket,
    PipeServerSocket
};

if ('TLSTcp' in core) {
    globals.TLSSocket = TLSSocket;
    globals.TLSServerSocket = TLSServerSocket;
}

for (const [ name, value ] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, {
        enumerable: true,
        configurable: true,
        writable: true,
        value
    });
}
