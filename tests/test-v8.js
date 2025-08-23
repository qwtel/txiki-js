import assert from 'tjs:assert';
import { serialize, deserialize } from 'tjs:v8';

const structuredClone = (x) => deserialize(serialize(x));

for (let i = -1000; i < 1000; i++) {
  assert.equal(structuredClone(i), i);
}

for (let i = -100n; i < 100n; i++) {
  assert.equal(structuredClone(i), i);
}

for (let i = -100n; i < 100n; i++) {
  const j = i << 64n;
  assert.equal(structuredClone(j), j);
}

for (const expected of crypto.getRandomValues(new Int32Array(100))) {
  assert.deepEqual(structuredClone(expected), expected);
}

for (const expected of crypto.getRandomValues(new Uint32Array(100))) {
  assert.deepEqual(structuredClone(expected), expected);
}

for (let i = 0; i < 100; i++) {
  const expected = generateRandomObject(3, 3)
  assert.deepEqual(structuredClone(expected), expected);
}

for (let i = 0; i < 100; i++) {
  const expected = crypto.getRandomValues(new Uint8Array(100));
  assert.deepEqual(structuredClone(expected), expected);
}

function generateRandomString(length) {
  const characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = characters.slice(0, -10)[randomInt(0, 52)];
  const charactersLength = characters.length;
  for (let i = 0; i < length; i++) {
      result += characters.charAt(Math.floor(Math.random() * charactersLength));
  }
  return result;
}

function generateRandomValue(primitive = true) {
  const types = ['string', 'wtf-16', 'integer', 'number', 'boolean', 'null', 'bytes'];
  if (!primitive) types.push('array');
  const type = types[Math.floor(Math.random() * types.length)];

  switch (type) {
      case 'string':
          return generateRandomString(randomInt(0, 100));
      case 'wtf-16':
          return String.fromCharCode.apply(undefined, crypto.getRandomValues(new Uint16Array(randomInt(0, 1000))));
      case 'integer':
          return randomInt(Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
      case 'number':
          return Math.random() * Number.MAX_VALUE
      case 'boolean':
          return Math.random() < 0.5;
      case 'array':
          return Array.from({ length: randomInt(0, 10) }, () => generateRandomValue(false));
      case 'bytes':
        return crypto.getRandomValues(new Uint8Array(randomInt(0, 100)));
      case 'undefined':
          return undefined;
      case 'null':
      default:
          return null;
  }
}

function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function generateRandomObject(breadth, depth) {
  if (depth === 0) {
      return generateRandomValue();
  }

  const obj = {};
  for (let i = 0, len = randomInt(1, breadth); i < len; i++) {
      const key = generateRandomString(randomInt(1, 16)); // Generate random key
      obj[key] = generateRandomValue();
  }
  for (let i = 0, len = randomInt(1, breadth); i < len; i++) {
      const key = generateRandomString(randomInt(1, 16)); // Generate random key
      obj[key] = generateRandomObject(breadth, depth - 1);
  }

  return obj;
}

// Dense array with extra enumerable properties should round-trip
{
  const a = [1, 2, 3];
  a.foo = 42;
  a.bar = 'baz';

  const b = structuredClone(a);
  assert.equal(Array.isArray(b), true);
  assert.equal(b.length, 3);
  assert.equal(b[0], 1);
  assert.equal(b[1], 2);
  assert.equal(b[2], 3);

  // Extra properties preserved and enumerable
  assert.equal(Object.prototype.hasOwnProperty.call(b, 'foo'), true);
  assert.equal(Object.prototype.hasOwnProperty.call(b, 'bar'), true);
  assert.equal(b.foo, 42);
  assert.equal(b.bar, 'baz');

  const keys = Object.keys(b);
  assert.equal(keys.includes('foo'), true);
  assert.equal(keys.includes('bar'), true);
}

// Throw for callable and exotic objects
{
  assert.throws(() => structuredClone(() => {}));
  assert.throws(() => structuredClone(new Proxy({ x: 1 }, {})));
  assert.throws(() => structuredClone(new Proxy([1, 2, 3], {})));
  assert.throws(() => (function () { structuredClone(arguments) })(1, 2, 3));
  assert.throws(() => (function () { structuredClone(arguments.map(x => x + 1)) })(1, 2, 3));
}

// Dense array large length + many named props
{
  const n = 1000;
  const a = Array.from({ length: n }, (_, i) => i);
  for (let i = 0; i < 50; i++) a['k' + i] = i * 2;
  const b = structuredClone(a);
  assert.equal(b.length, n);
  assert.equal(b[0], 0);
  assert.equal(b[n - 1], n - 1);
  for (let i = 0; i < 50; i++) assert.equal(b['k' + i], i * 2);
}

// Object with enumerable numeric keys
{
  const o = { 0: 'a', 1: 'b', 10: 'c', x: 1 };
  const c = structuredClone(o);
  assert.equal(c[0], 'a');
  assert.equal(c[1], 'b');
  assert.equal(c[10], 'c');
  assert.equal(c.x, 1);
}

// RegExp flags
{
  const r = /a.b/giuy;
  const rr = structuredClone(r);
  assert.equal(rr.source, r.source);
  assert.equal(rr.flags, r.flags);
}

// Error with message/stack/cause
{
  const cause = new Error('root');
  const e = new TypeError('msg', { cause });
  const ee = structuredClone(e);
  assert.equal(ee.name, 'TypeError');
  assert.equal(ee.message, 'msg');
  // stack may differ, but must be a string if present
  if (typeof ee.stack !== 'undefined') assert.equal(typeof ee.stack, 'string');
  assert.equal(ee.cause.message, 'root');
}

// TypedArray/DataView with offsets
{
  const buf = new ArrayBuffer(32);
  const u32 = new Uint32Array(buf, 4, 4);
  u32.set([1,2,3,4]);
  const dv = new DataView(buf, 8, 8);
  const u32c = structuredClone(u32);
  const dvc = structuredClone(dv);
  assert.equal(u32c.byteLength, 16);
  assert.deepEqual(Array.from(u32c), [1,2,3,4]);
  assert.equal(dvc.byteLength, 8);
}

// ArrayBuffer empty and non-empty
{
  const a0 = new ArrayBuffer(0);
  const a1 = new ArrayBuffer(8);
  new Uint8Array(a1).set([1,2,3,4,5,6,7,8]);
  const b0 = structuredClone(a0);
  const b1 = structuredClone(a1);
  assert.equal(b0.byteLength, 0);
  assert.equal(b1.byteLength, 8);
  assert.deepEqual(Array.from(new Uint8Array(b1)), [1,2,3,4,5,6,7,8]);
}

// Nested Maps/Sets
{
  const inner = new Map([[{k:1}, new Set([1,2])]]);
  const outer = new Map([[1, inner]]);
  const cloned = structuredClone(outer);
  assert.equal(cloned.get(1) instanceof Map, true);
  const pair = [...cloned.get(1).entries()][0];
  assert.equal(pair[1] instanceof Set, true);
  assert.deepEqual([...pair[1].values()], [1,2]);
}
