import assert from 'node:assert/strict';
import { onRequest } from '../functions/ipa/[[path]].js';

const sha = 'a'.repeat(64), body = new Uint8Array([1, 2, 3, 4]);
const store = new Map(), pending = [];
let reads = 0;
globalThis.caches = { default: {
  match: async key => store.get(key.url)?.clone(),
  put: async (key, response) => { store.set(key.url, response); },
} };
const object = () => ({ body, size: body.length, httpEtag: '"test"' });
const context = {
  params: { path: [sha, 'YunX-unsigned.ipa'] },
  env: { IPA_BUCKET: { get: async key => { assert.equal(key, `ipa/yunx/${sha}/YunX-unsigned.ipa`); reads++; return object(); }, head: async () => object() } },
  waitUntil: promise => pending.push(promise),
};
const url = `https://yunx-lcsign-cc1477.pages.dev/ipa/${sha}/YunX-unsigned.ipa`;
const call = request => onRequest({ ...context, request });
const first = await call(new Request(url + '?v=1'));
assert.equal(first.headers.get('X-YunX-Cache'), 'MISS');
assert.deepEqual(new Uint8Array(await first.arrayBuffer()), body);
await Promise.all(pending);
const second = await call(new Request(url + '?v=2'));
assert.equal(second.headers.get('X-YunX-Cache'), 'HIT');
assert.equal(reads, 1);
assert.equal((await call(new Request(url, { method: 'HEAD' }))).body, null);
assert.equal((await call(new Request(url, { method: 'POST' }))).status, 405);
assert.equal((await onRequest({ ...context, request: new Request(url), params: { path: ['..', 'YunX-unsigned.ipa'] } })).status, 404);
console.log('PASS: immutable download caching, HEAD, method and path checks');
