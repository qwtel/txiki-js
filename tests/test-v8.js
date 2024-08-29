import assert from 'tjs:assert';
import { serialize, deserialize } from 'tjs:v8';

for (let i = -1000; i < 1000; i++) {
  assert.equal(deserialize(serialize(i)), i);
}

for (let i = -100n; i < 100n; i++) {
  assert.equal(deserialize(serialize(i)), i);
}

for (let i = -100n; i < 100n; i++) {
  const j = i << 64n;
  assert.equal(deserialize(serialize(j)), j);
}

for (const expected of crypto.getRandomValues(new Int32Array(100))) {
  assert.deepEqual(deserialize(serialize(expected)), expected);
}

for (const expected of crypto.getRandomValues(new Uint32Array(100))) {
  assert.deepEqual(deserialize(serialize(expected)), expected);
}

for (let i = 0; i < 100; i++) {
  const expected = generateRandomObject(3, 3)
  assert.deepEqual(deserialize(serialize(expected)), expected);
}

for (let i = 0; i < 100; i++) {
  const expected = crypto.getRandomValues(new Uint8Array(100));
  assert.deepEqual(deserialize(serialize(expected)), expected);
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
