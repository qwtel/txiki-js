import assert from 'tjs:assert';
import { serialize, deserialize, Serializer, Deserializer } from 'tjs:v8';

const structuredClone = (x) => deserialize(serialize(x));

let randomState = 0x9e3779b9;

function randomUint32() {
  randomState ^= randomState << 13;
  randomState ^= randomState >>> 17;
  randomState ^= randomState << 5;
  return randomState >>> 0;
}

function randomValues(view) {
  for (let i = 0; i < view.length; i++) view[i] = randomUint32();
  return view;
}

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

for (const expected of randomValues(new Int32Array(100))) {
  assert.deepEqual(structuredClone(expected), expected);
}

for (const expected of randomValues(new Uint32Array(100))) {
  assert.deepEqual(structuredClone(expected), expected);
}

for (let i = 0; i < 100; i++) {
  const expected = generateRandomObject(3, 3)
  assert.deepEqual(structuredClone(expected), expected);
}

for (let i = 0; i < 100; i++) {
  const expected = randomValues(new Uint8Array(100));
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
          return String.fromCharCode.apply(undefined, randomValues(new Uint16Array(randomInt(0, 1000))));
      case 'integer':
          return randomInt(Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
      case 'number':
          return Math.random() * Number.MAX_VALUE
      case 'boolean':
          return Math.random() < 0.5;
      case 'array':
          return Array.from({ length: randomInt(0, 10) }, () => generateRandomValue(false));
      case 'bytes':
        return randomValues(new Uint8Array(randomInt(0, 100)));
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
  assert.deepEqual(Object.keys(c), ['0', '1', '10', 'x']);
}

// Inherited names do not conflict with deserialized own properties
{
  const o = { toString: 1, constructor: 2, hasOwnProperty: 3 };
  const c = structuredClone(o);
  assert.deepEqual(Object.keys(c), ['toString', 'constructor', 'hasOwnProperty']);
  assert.equal(Object.hasOwn(c, 'toString'), true);
  assert.equal(Object.hasOwn(c, 'constructor'), true);
  assert.equal(Object.hasOwn(c, 'hasOwnProperty'), true);
  assert.equal(c.toString, 1);
  assert.equal(c.constructor, 2);
  assert.equal(c.hasOwnProperty, 3);
}

// Duplicate own properties in malformed input are rejected
{
  const data = serialize({ a: 1, b: 2 });
  const b = data.lastIndexOf('b'.charCodeAt(0));
  assert.equal(b >= 0, true);
  data[b] = 'a'.charCodeAt(0);
  assert.throws(() => deserialize(data));
}

// Symbol keys are not part of the enumerable string-key snapshot
{
  const symbol = Symbol('ignored');
  const o = { a: 1 };
  o[symbol] = 2;
  const c = structuredClone(o);
  assert.deepEqual(c, { a: 1 });
  assert.equal(Object.getOwnPropertySymbols(c).length, 0);

  const a = [1];
  a[symbol] = 2;
  const ac = structuredClone(a);
  assert.deepEqual(ac, [1]);
  assert.equal(Object.getOwnPropertySymbols(ac).length, 0);
}

// Recursive serialization may mutate the shape currently being traversed
{
  const parent = { child: {}, removed: 2, changed: 3 };
  Object.defineProperty(parent.child, 'value', {
    enumerable: true,
    get() {
      delete parent.removed;
      parent.changed = 4;
      parent.added = 5;
      return 1;
    },
  });

  const c = structuredClone(parent);
  assert.deepEqual(c, { child: { value: 1 }, changed: 4 });
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

// Serializer-owned buffers remain transferable when the transfer resizes them.
{
  const serializer = new Serializer();
  serializer.writeHeader();
  serializer.writeValue({ answer: 42 });

  const serialized = serializer.releaseBuffer();
  const expected = Array.from(serialized);
  const originalLength = serialized.byteLength;
  const grown = serialized.buffer.transfer(originalLength + 7);

  assert.equal(serialized.byteLength, 0);
  assert.equal(grown.byteLength, originalLength + 7);
  assert.deepEqual(Array.from(new Uint8Array(grown, 0, originalLength)), expected);
  assert.deepEqual(Array.from(new Uint8Array(grown, originalLength)), Array(7).fill(0));

  const shrunk = grown.transfer(originalLength - 1);
  assert.equal(grown.byteLength, 0);
  assert.equal(shrunk.byteLength, originalLength - 1);
  assert.deepEqual(Array.from(new Uint8Array(shrunk)), expected.slice(0, -1));
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

// Delegate-provided DataCloneError (DOMException)
{
  class DataCloneError extends DOMException {
    constructor(msg) {
      super(msg, 'DataCloneError');
    }
  }

  // Delegate-provided DataCloneError (DOMException) during serialization
  {
    const s = new Serializer();
    s._getDataCloneError = () => DataCloneError;
    s.writeHeader();
    let thrown = false;
    try {
      s.writeValue(() => {})
    } catch (err) {
      thrown = true;
      assert.equal(err instanceof DOMException, true);
      assert.equal(err.name, 'DataCloneError');
    }
    assert.equal(thrown, true);
  }

  // Delegate-provided DataCloneError (DOMException) during deserialization
  {
    const bad = new Uint8Array(0);
    const d = new Deserializer(bad);
    d._getDataCloneError = () => DataCloneError;
    let thrown = false;
    try {
      d.readValue();
    } catch (err) {
      thrown = true;
      assert.equal(err instanceof DOMException, true);
      assert.equal(err.name, 'DataCloneError');
    }
    assert.equal(thrown, true);
  }
}
