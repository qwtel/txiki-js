/// <reference path="../types/src/index.d.ts" />

// npx esbuild ./serialize.js --bundle --outfile=./bundle.js --target=es2023 --platform=neutral --format=esm --main-fields=main,module

const typicalObjet = generateRandomObject(5, 5)
console.log("# properties:", countProperties(typicalObjet))

import * as v8 from '@workers/v8-value-serializer'
import { Packr, Unpackr } from 'msgpackr';
const packr = new Packr({ structuredClone: true });

const N = 1000;

// performance.mark('start');
// for (let i = 0; i < n; i++) {
//   tjs.engine.serialize(typicalObjet)
// }
// performance.mark('end');
// console.log(performance.measure('full', 'start', 'end'));


performance.mark('start');
for (let i = 0; i < N; i++) {
  packr.pack(typicalObjet);
}
performance.mark('end');
console.log(performance.measure('full', 'start', 'end'));


performance.mark('start');
for (let i = 0; i < N; i++) {
  v8.serialize(typicalObjet, { forceUtf8: true, ignoreArrayProperties: true });
}
performance.mark('end');
console.log(performance.measure('full', 'start', 'end'));


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
  const types = ['string', 'integer', 'number', 'boolean', 'null'];
  if (!primitive) types.push('array');
  const type = types[Math.floor(Math.random() * types.length)];

  switch (type) {
      case 'string':
          return generateRandomString(randomInt(0, 100));
      // case 'wtf-16':
      //     return String.fromCharCode.apply(undefined, crypto.getRandomValues(new Uint16Array(randomInt(0, 1000))));
      case 'integer':
          return randomInt(Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
      case 'number':
          return Math.random() * Number.MAX_VALUE
      case 'boolean':
          return Math.random() < 0.5;
      case 'array':
          return Array.from({ length: randomInt(0, 10) }, () => generateRandomValue(false));
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

function countProperties(obj) {
  let count = 0;

  function countNestedProperties(obj) {
    if (Array.isArray(obj)) {
      count += obj.length;
      for (let i = 0; i < obj.length; i++) {
        countNestedProperties(obj[i]);
      }
    }
    else if (obj !== null && typeof obj === 'object') {
      for (const key in obj) {
        if (Object.hasOwn(obj, key)) {
          count++;
          countNestedProperties(obj[key]);
        }
      }
    }
  }

  countNestedProperties(obj);
  return count;
}
