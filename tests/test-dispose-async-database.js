import assert from 'tjs:assert';
import path from 'tjs:path';
import { Database, AsyncDatabase } from 'tjs:sqlite';


// `await using` closes the async database when the block exits.
{
    let dbRef;

    await (async () => {
        await using db = new AsyncDatabase(':memory:');

        await db.run('CREATE TABLE t (v INTEGER)');
        await db.run('INSERT INTO t (v) VALUES (?)', [42]);

        const rows = await db.all('SELECT * FROM t');

        assert.eq(rows[0].v, 42);
        dbRef = db;
    })();

    assert.throws(() => dbRef.all('SELECT 1'), Error, 'closed async db throws on all');
    assert.throws(() => dbRef.run('SELECT 1'), Error, 'closed async db throws on run');
}

// Disposal waits for queued work before closing the database.
{
    const tmpDir = await tjs.makeTempDir('test-dispose-async-db-XXXXXX');

    try {
        const dbPath = path.join(tmpDir, 'db.sqlite');

        await (async () => {
            await using db = new AsyncDatabase(dbPath, { create: true });

            await db.run('CREATE TABLE t (v INTEGER)');
            db.run('INSERT INTO t (v) VALUES (?)', [7]);
        })();

        using db = new Database(dbPath, { readOnly: true });
        const rows = db.prepare('SELECT * FROM t').all();

        assert.eq(rows[0].v, 7);
    } finally {
        await tjs.remove(tmpDir);
    }
}

// Manual close followed by async disposal is a no-op.
{
    const db = new AsyncDatabase(':memory:');

    db.close();
    await db[Symbol.asyncDispose]();
    await db[Symbol.asyncDispose]();
}

// asyncDispose returns a Promise.
{
    const db = new AsyncDatabase(':memory:');
    const ret = db[Symbol.asyncDispose]();

    assert.ok(ret instanceof Promise, '[Symbol.asyncDispose] returns a Promise');
    await ret;
}

// asyncDispose property is non-enumerable.
{
    const db = new AsyncDatabase(':memory:');
    const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(db), Symbol.asyncDispose);

    assert.ok(descriptor, 'descriptor exists on prototype');
    assert.eq(descriptor.enumerable, false, 'asyncDispose is non-enumerable');
    assert.eq(descriptor.configurable, true, 'asyncDispose is configurable');
    assert.eq(descriptor.writable, true, 'asyncDispose is writable');

    await db[Symbol.asyncDispose]();
}
