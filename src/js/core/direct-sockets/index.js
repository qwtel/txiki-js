import { PipeSocket, PipeServerSocket } from './pipe.js';
import { TCPSocket, TCPServerSocket } from './tcp.js';
import { TLSSocket, TLSServerSocket } from './tls.js';
import { UDPSocket } from './udp.js';
import { core } from './utils.js';

export { TCPSocket, TCPServerSocket, TLSSocket, TLSServerSocket, UDPSocket, PipeSocket, PipeServerSocket };

const globals = {
    TCPSocket,
    TCPServerSocket,
    PipeSocket,
    PipeServerSocket
};

if ('TLSTcp' in core) {
    globals.TLSSocket = TLSSocket;
    globals.TLSServerSocket = TLSServerSocket;
}

if ('UDP' in core) {
    globals.UDPSocket = UDPSocket;
}

for (const [ name, value ] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, {
        enumerable: true,
        configurable: true,
        writable: true,
        value
    });
}
