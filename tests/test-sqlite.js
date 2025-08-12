import assert from 'tjs:assert';
import path from 'tjs:path';
import { Database } from 'tjs:sqlite';


async function testTypes(dbName) {
    const db = new Database(dbName);

    await db.exec('PRAGMA journal_mode = WAL;');

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

await testTypes();
testExistingDB();

const newDb = path.join(import.meta.dirname, `db-${tjs.pid}.sqlite`);

await testTypes(newDb);

const result = await tjs.stat(newDb);

assert.ok(result.isFile, 'file was created ok');

await tjs.remove(newDb);

testNewDbNoCreate();

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

testExtensions();

// New tests for async Database.all

async function testAllBasic() {
    const db = new Database();

    await db.exec('CREATE TABLE test (txt TEXT NOT NULL, int INTEGER, double FLOAT, data BLOB)');

    // Insert a few rows synchronously via deprecated Statement API (still supported)
    const ins = db.prepare('INSERT INTO test (txt, int, double, data) VALUES(?, ?, ?, ?)');
    ins.run('foo', 42, 4.2, new Uint8Array(4).fill(1));
    ins.run('bar', 69, 6.9, new Uint8Array(4).fill(2));
    ins.run('baz', 666, 6.6, null);

    const allRows = await db.all('SELECT * FROM test');
    assert.eq(allRows.length, 3);
    assert.eq(allRows[0].txt, 'foo');
    assert.eq(allRows[0].int, 42);
    assert.eq(allRows[0].double, 4.2);
    assert.eq(allRows[0].data[0], 1);
    assert.eq(allRows[0].data[1], 1);
    assert.eq(allRows[0].data[2], 1);
    assert.eq(allRows[0].data[3], 1);
    assert.eq(allRows[1].data[0], 2);

    const onlyFoo = await db.all('SELECT * FROM test WHERE txt = $txt', { $txt: 'foo' });
    assert.eq(onlyFoo.length, 1);
    assert.eq(onlyFoo[0].txt, 'foo');

    // Wrong param name should reject
    let threw = false;
    try {
        await db.all('SELECT * FROM test WHERE txt = $txt', { txt: 'foo' });
    } catch (e) {
        threw = true;
        assert.ok(e instanceof ReferenceError || e instanceof Error);
    }
    assert.ok(threw, 'binding error thrown');
}

async function testAllAbort() {
    const db = new Database();

    // A recursive CTE that does a lot of work
    const sql = `WITH RECURSIVE t(x) AS (
        VALUES(0)
        UNION ALL
        SELECT x+1 FROM t
        LIMIT 100000000
    ) SELECT count(*) as c FROM t`;

    const ac = new AbortController();
    const p = db.all(sql, undefined, { signal: ac.signal });

    // Abort shortly after starting; give the worker time to enter sqlite3_step
    setTimeout(() => ac.abort(), 1);

    let aborted = false;
    try {
        await p;
    } catch (e) {
        aborted = true;
        assert.ok(e instanceof Error);
    }
    assert.ok(aborted, 'query was aborted');
}

await testAllBasic();
await testAllAbort();
