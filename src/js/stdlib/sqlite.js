const core = globalThis[Symbol.for('tjs.internal.core')];
const sqlite3 = core.sqlite3;

const kSqlite3Handle = Symbol('kSqlite3Handle');

function attachAbortSignal(handle, promise, signal) {
    if (signal) {
        const onAbort = () => sqlite3.set_abort(handle);
        if (signal.aborted) onAbort();
        else signal.addEventListener('abort', onAbort, { once: true });
        promise.finally(() => {
            if (!signal.aborted) signal.removeEventListener('abort', onAbort);
        }).catch(() => {});
    }
}

class Database {
    #queue;

    constructor(dbName = ':memory:', options = { create: true, readOnly: false }) {
        let flags = 0;

        if (options.create) {
            flags |= sqlite3.SQLITE_OPEN_CREATE;
        }

        if (options.readOnly) {
            flags |= sqlite3.SQLITE_OPEN_READONLY;
        } else {
            flags |= sqlite3.SQLITE_OPEN_READWRITE;
        }

        this[kSqlite3Handle] = sqlite3.open(dbName, flags);
    }

    close() {
        if (this[kSqlite3Handle]) {
            sqlite3.close(this[kSqlite3Handle]);
            this[kSqlite3Handle] = null;
        }
    }

    exec(sql, params, options = {}) {
        if (!this[kSqlite3Handle]) {
            throw new Error('Invalid DB');
        }

        // Lazily create a per-connection queue to serialize ops
        this.#queue ||= Promise.resolve();

        const handle = this[kSqlite3Handle];
        const p = this.#queue.then(() => {
            const promise = sqlite3.exec_async(handle, sql, params);
            attachAbortSignal(handle, promise, options.signal);
            return promise;
        });

        // Update queue to ensure sequential execution
        this.#queue = p.catch(() => {});
        return p;
    }

    /** @deprecated */
    prepare(sql) {
        if (!this[kSqlite3Handle]) {
            throw new Error('Invalid DB');
        }

        return new Statement(sqlite3.prepare(this[kSqlite3Handle], sql));
    }

    loadExtension(file, entrypoint=undefined) {
        return sqlite3.load_extension(this[kSqlite3Handle],file,entrypoint);
    }

    all(sql, params, options = {}) {
        if (!this[kSqlite3Handle]) {
            throw new Error('Invalid DB');
        }

        // Serialize per-connection
        this.#queue ||= Promise.resolve();

        const handle = this[kSqlite3Handle];
        const p = this.#queue.then(() => {
            const promise = sqlite3.all_async(handle, sql, params);
            attachAbortSignal(handle, promise, options.signal);
            return promise;
        });

        this.#queue = p.catch(() => {});
        return p;
    }
}


const kSqlite3Stmt = Symbol('kSqlite3Stmt');

/** @deprecated */
class Statement {
    constructor(stmt) {
        this[kSqlite3Stmt] = stmt;
    }

    finalize() {
        sqlite3.stmt_finalize(this[kSqlite3Stmt]);
    }

    toString() {
        return sqlite3.stmt_expand(this[kSqlite3Stmt]);
    }

    all(...args) {
        if (args && args.length === 1 && typeof args[0] === 'object') {
            args = args[0];
        }

        return sqlite3.stmt_all(this[kSqlite3Stmt], args);
    }

    run(...args) {
        if (args && args.length === 1 && typeof args[0] === 'object') {
            args = args[0];
        }

        return sqlite3.stmt_run(this[kSqlite3Stmt], args);
    }
}


export { Database };
