// node --test scheduler/worker.test.mjs   (Node 18+; ek paket gerekmez)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.js';

function run(env, response) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return response;
  };
  let pending;
  const ctx = { waitUntil: (p) => { pending = p; } };
  worker.scheduled({ cron: '4 * * * *' }, env, ctx);
  return { calls, pending };
}

test('feed iş akışını main dalında workflow_dispatch ile tetikler', async () => {
  const { calls, pending } = run({ GH_TOKEN: 'test-token' }, new Response(null, { status: 204 }));
  await pending;
  assert.equal(calls.length, 1);
  const { url, init } = calls[0];
  assert.equal(url, 'https://api.github.com/repos/evleviyet/karga-veri/actions/workflows/feed.yml/dispatches');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.Authorization, 'Bearer test-token');
  assert.deepEqual(JSON.parse(init.body), { ref: 'main' });
});

test('GitHub reddederse hata verir (token sızdırmadan)', async () => {
  const { pending } = run({ GH_TOKEN: 'gizli-deger' }, new Response('{"message":"Bad credentials"}', { status: 401 }));
  await assert.rejects(pending, (e) => {
    assert.match(e.message, /HTTP 401/);
    assert.doesNotMatch(e.message, /gizli-deger/);
    return true;
  });
});

test('secret tanımlı değilse istek atmaz', async () => {
  const { calls, pending } = run({}, new Response(null, { status: 204 }));
  await assert.rejects(pending, /GH_TOKEN/);
  assert.equal(calls.length, 0);
});

test('Worker HTTP isteklerine yanıt vermez (fetch işleyicisi yok)', () => {
  assert.equal(typeof worker.fetch, 'undefined');
});
