import assert from 'tjs:assert';
import path from 'tjs:path';
import { Database, AsyncDatabase } from 'tjs:sqlite';


function testTypes(dbName) {
    const db = new Database(dbName);

    db.exec('PRAGMA journal_mode = WAL;');

    db.prepare('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)').run();
    
    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    
    ins.run('foo', 42, 4.2, new Uint8Array(16).fill(42));
    ins.run('foo', 43, 4.3, new Uint8Array(16).fill(43));
    ins.run('bar', 69, 6.9, new Uint8Array(16).fill(69));
    ins.run('baz', 666, 6.6, null);
    
    ins.finalize();

    assert.throws(() => ins.run('baz', 666, 6.6, null), InternalError);

    const data1 = db.prepare('SELECT * FROM test').all();
    const data2 = db.prepare('SELECT * FROM test WHERE txt = $txt').all({ $txt: 'foo' });

    assert.throws(() => db.prepare('SELECT * FROM test WHERE txt = $txt').all({ txt: 'foo' }), ReferenceError);
    assert.eq(data1.length, 4);
    assert.eq(data2.length, 2);

    assert.eq(data1[0].txt, 'foo');
    assert.eq(data1[0].int, 42);
    assert.eq(data1[0].double, 4.2);
    assert.eq(data1[0].data[0], 42);

    assert.eq(data1[3].txt, 'baz');
    assert.eq(data1[3].data, null);

    assert.throws(() => db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)').run(null, 42, 4.2, null), Error);

    db.close();
}

function testExistingDB() {
    const db = new Database(path.join(import.meta.dirname, 'fixtures', 'test.sqlite'), { readOnly: true });

    const data1 = db.prepare('SELECT * FROM test').all();
    const data2 = db.prepare('SELECT * FROM test WHERE txt = $txt').all({ $txt: 'foo' });

    assert.eq(data1.length, 4);
    assert.eq(data2.length, 2);

    assert.eq(data1[0].txt, 'foo');
    assert.eq(data1[0].int, 42);
    assert.eq(data1[0].double, 4.2);
    assert.eq(data1[0].data[0], 42);

    assert.eq(data1[3].txt, 'baz');
    assert.eq(data1[3].data, null);

    assert.throws(() => db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)').run('foo', 42, 4.2, null), Error);

    db.close();
}

function testNewDbNoCreate() {
    assert.throws(() => new Database(path.join(import.meta.dirname, 'fixtures', 'nope.sqlite'), { create: false }), Error);

}

testTypes();
testExistingDB();

const newDb = path.join(import.meta.dirname, `db-${tjs.pid}.sqlite`);

testTypes(newDb);

const result = await tjs.stat(newDb);

assert.ok(result.isFile, 'file was created ok');

await tjs.remove(newDb);

testNewDbNoCreate();

function testTransactions() {
    const db = new Database();

    assert.falsy(db.inTransaction);

    db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    const insMany = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }
    });

    insMany([
        [ 'foo', 42, 4.2, new Uint8Array(16).fill(42) ],
        [ 'foo', 43, 4.3, new Uint8Array(16).fill(43) ],
        [ 'bar', 69, 6.9, new Uint8Array(16).fill(69) ],
        [ 'baz', 666, 6.6, null ],
    ]);

    const data1 = db.prepare('SELECT * FROM test').all();

    assert.eq(data1.length, 4);
}

function testTransactionsError() {
    const db = new Database();

    assert.falsy(db.inTransaction);

    db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    const insMany = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }

        throw new Error('oops!');
    });

    assert.throws(() => insMany([
        [ 'foo', 42, 4.2, new Uint8Array(16).fill(42) ],
        [ 'foo', 43, 4.3, new Uint8Array(16).fill(43) ],
        [ 'bar', 69, 6.9, new Uint8Array(16).fill(69) ],
        [ 'baz', 666, 6.6, null ],
    ]), Error, 'an error is thrown');

    const data1 = db.prepare('SELECT * FROM test').all();

    assert.falsy(db.inTransaction);
    assert.eq(data1.length, 0);
}

function testTransactionsNested() {
    const db = new Database();

    assert.falsy(db.inTransaction);

    db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    const ins2 = db.prepare('INSERT INTO test (txt, int) VALUES(?, ?)');

    const insMany = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }

        throw new Error('oops!');
    });

    const insMany2 = db.transaction(datas => {
        assert.ok(db.inTransaction);

        for (const data of datas) {
            ins.run(data);
        }

        try {
            insMany([
                [ 'foo', 42, 4.2, new Uint8Array(16).fill(42) ],
                [ 'foo', 43, 4.3, new Uint8Array(16).fill(43) ],
                [ 'bar', 69, 6.9, new Uint8Array(16).fill(69) ],
                [ 'baz', 666, 6.6, null ]
            ]);
        } catch(_) {
            // Ignore, so the outer transaction succeeds.
        }
    });

    insMany2([
        [ '1234', 1234 ],
        [ '4321', 4321 ],
    ]);

    const data1 = db.prepare('SELECT * FROM test').all();

    assert.falsy(db.inTransaction);
    assert.eq(data1.length, 2);
}

function testExtensions(){
	let sopath = './build/libsqlite-test.so';
	switch(tjs.system.platform){
		case 'linux':
			sopath = './build/libsqlite-test.so';
			break;
		case 'darwin':
			sopath = './build/libsqlite-test.dylib';
			break;
		case 'windows':
			sopath = './build/libsqlite-test.dll';
		break;
	}

    const db = new Database();
    db.loadExtension(sopath, 'sqlite_test_ext_init')
    assert.eq(db.prepare("SELECT testfn();").all()[0]["testfn()"], 43)
}

testTransactions();
testTransactionsError();
testTransactionsNested();
testExtensions();

async function testExistingDBAll() {
    const dbPath = path.join(import.meta.dirname, 'fixtures', 'test.sqlite');
    const db = new AsyncDatabase(dbPath, { readOnly: true });

    const data1 = await db.all('SELECT * FROM test');
    const data2 = await db.all('SELECT * FROM test WHERE txt = ?', ['foo']);

    assert.eq(data1.length, 4);
    assert.eq(data2.length, 2);

    assert.eq(data1[0].txt, 'foo');
    assert.eq(data1[0].int, 42);
    assert.eq(data1[0].double, 4.2);
    assert.eq(data1[0].data[0], 42);

    assert.eq(data1[3].txt, 'baz');
    assert.eq(data1[3].data, null);

    db.close();
}

async function testAllOnNewDb() {
    const dbPath = path.join(import.meta.dirname, 'fixtures', `db-async-${tjs.pid}.sqlite`);
    try {
        const db = new AsyncDatabase(dbPath, { create: true });

        await db.run('PRAGMA journal_mode = WAL;');
        await db.run('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

        await db.run('INSERT INTO test (txt, int, double, data) VALUES (?, ?, ?, ?)', ['foo', 42, 4.2, new Uint8Array(16).fill(42)]);
        await db.run('INSERT INTO test (txt, int, double, data) VALUES (?, ?, ?, ?)', ['foo', 43, 4.3, new Uint8Array(16).fill(43)]);
        await db.run('INSERT INTO test (txt, int, double, data) VALUES (?, ?, ?, ?)', ['bar', 69, 6.9, new Uint8Array(16).fill(69)]);
        await db.run('INSERT INTO test (txt, int, double, data) VALUES (?, ?, ?, ?)', ['baz', 666, 6.6, null]);

        const data1 = await db.all('SELECT * FROM test');
        const data2 = await db.all('SELECT * FROM test WHERE txt = ?', ['foo']);

        assert.eq(data1.length, 4);
        assert.eq(data2.length, 2);

        assert.eq(data1[0].txt, 'foo');
        assert.eq(data1[0].int, 42);
        assert.eq(data1[0].double, 4.2);
        assert.eq(data1[0].data[0], 42);

        assert.eq(data1[3].txt, 'baz');
        assert.eq(data1[3].data, null);

        db.close();

        const result = await tjs.stat(dbPath);
        assert.ok(result.isFile, 'file was created ok');
    } finally {
        await tjs.remove(dbPath);
    }
}

function testNewDbNoCreateAsync() {
    assert.throws(() => new AsyncDatabase(path.join(import.meta.dirname, 'fixtures', 'nope.sqlite'), { create: false }), Error);

}

// A recursive CTE that does a lot of work
const SlowSql = `WITH RECURSIVE t(x) AS (
    VALUES(0)
    UNION ALL
    SELECT x+1 FROM t
    LIMIT 100000000
) SELECT count(*) as c FROM t`;

async function testPreAbortAll() {
    const db = new AsyncDatabase();

    const ac = new AbortController();
    ac.abort();

    let threw = false;
    try {
        await db.all(SlowSql, [], { signal: ac.signal });
    } catch (e) {
        threw = true;
        assert.ok(
            e instanceof DOMException && e.name === 'AbortError', 
            'aborted query rejects with an AbortError'
        );
    }
    assert.ok(threw, 'all() rejects when passed an already-aborted signal');

    db.close();
}

async function testAbortAll(n) {
    const db = new AsyncDatabase();

    const ac = new AbortController();
    const p = db.all(SlowSql, [], { signal: ac.signal });
    p.catch(() => {});

    // Abort shortly after starting; give the worker time to enter sqlite3_step
    setTimeout(() => ac.abort(), n);

    let aborted = false;
    try {
        await p;
    } catch (e) {
        aborted = true;
        assert.ok(
            e instanceof DOMException && e.name === 'AbortError', 
            'aborted query rejects with an AbortError'
        );
    }
    console.log(`all() rejects when aborting after ${n}ms`);
    assert.ok(aborted, `all() rejects when aborting after ${n}ms`);
}

async function testConcurrentExec() {
    const db = new AsyncDatabase();

    const p1 = db.all('SELECT 1');
    const p2 = db.all('SELECT 2');

    const [r1, r2] = await Promise.all([p1, p2]);

    assert.eq(r1[0]?.['1'], 1);
    assert.eq(r2[0]?.['2'], 2);

    db.close();
}

async function testConcurrentExec2() {
    const db = new AsyncDatabase();
    const [r1, r2] = await Promise.all([p1, p2]);
    assert.eq(r1.length, 1);
    assert.eq(r2.length, 1);
    db.close();
}

// Async tests disabled temporarily to isolate GC assertion in JS_FreeRuntime
const runAsyncSqliteTests = true;
if (runAsyncSqliteTests) {
    // await testExistingDBAll();
    // await testAllOnNewDb();
    // testNewDbNoCreateAsync();
    // await testPreAbortAll();
    // await testAbortAll(1);
    await testAbortAll(10);
    await testAbortAll(10);
    // await testConcurrentExec();
}

