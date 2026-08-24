import assert from 'tjs:assert';

let caught;

try {
    await import('tjs:doesnotexist');
} catch (e) {
    caught = e;
}

assert.ok(caught instanceof ReferenceError, 'rejects with a ReferenceError');
assert.ok(String(caught.message).includes('tjs:doesnotexist'), 'the error names the specifier');
