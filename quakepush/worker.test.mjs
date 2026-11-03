// node --test quakepush/worker.test.mjs   (Node 18+; ek paket gerekmez)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { run, topicsFor, conditions, reach } from './worker.js';

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const SA = JSON.stringify({
  project_id: 'test-proje',
  client_email: 'x@test-proje.iam.gserviceaccount.com',
  private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
});

function kv(initial) {
  const store = new Map(initial ? [['seen', JSON.stringify(initial)]] : []);
  let writes = 0;
  return {
    get: async (k) => store.get(k) ?? null,
    put: async (k, v) => { writes++; store.set(k, v); },
    delete: async (k) => { writes++; store.delete(k); },
    get writes() { return writes; },
    read: () => JSON.parse(store.get('seen')),
  };
}

const now = new Date('2026-11-03T12:00:00Z');
const afad = (id, mag, lat, lon, date) => ({ eventID: id, magnitude: String(mag), latitude: String(lat), longitude: String(lon), depth: '7', location: 'Yer', date });

function stub(quakes) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).startsWith('https://servisnet.afad.gov.tr')) return new Response(JSON.stringify(quakes), { status: 200 });
    if (String(url) === 'https://oauth2.googleapis.com/token') return new Response('{"access_token":"tok","expires_in":3600}', { status: 200 });
    return new Response('{}', { status: 200 });
  };
  return calls;
}

test('etki alanı: büyüklüğe göre en uzak ayar', () => {
  assert.equal(reach(2.9), 0);
  assert.equal(reach(3.2), 50);
  assert.equal(reach(4.6), 250);
  assert.equal(reach(6.6), 1200);
});

test('küçük deprem yalnız yakın illere, M5+ tüm Türkiye', () => {
  // Eskişehir merkezi yakınında M3.2: Eskişehir var, Van yok
  const t = topicsFor({ mag: 3.2, lat: 39.78, lon: 30.52 });
  assert.ok(t.includes('il-26'));
  assert.ok(!t.includes('il-65'));
  assert.deepEqual(topicsFor({ mag: 5.1, lat: 39.78, lon: 30.52 }), ['tr']);
  const c = conditions(['il-1', 'il-2', 'il-3', 'il-4', 'il-5', 'il-6']);
  assert.equal(c.length, 2);
  assert.equal(c[1], "'il-6' in topics");
});

test('ilk çalışma bildirim göndermez, listeyi görüldü sayar, anahtarı kuru dener', async () => {
  const calls = stub([afad('1', 4.2, 39.78, 30.52, '2026-11-03T11:55:00')]);
  const SEEN = kv(null);
  const r = await run({ SEEN, FCM_SA: SA }, now);
  assert.equal(r.first, true);
  assert.equal(r.check, 200);
  const tok = calls.find((c) => c.url === 'https://oauth2.googleapis.com/token');
  const jwt = decodeURIComponent(tok.init.body.split('assertion=')[1]);
  assert.equal(jwt.split('.').length, 3);
  const fcm = calls.filter((c) => c.url.includes('fcm.googleapis.com'));
  assert.equal(fcm.length, 1);
  assert.equal(JSON.parse(fcm[0].init.body).validate_only, true);
  assert.ok('1' in SEEN.read());
});

test('yeni deprem yoksa KV\'ye yazılmaz, FCM\'ye gidilmez', async () => {
  const calls = stub([afad('1', 4.2, 39.78, 30.52, '2026-11-03T11:55:00')]);
  const SEEN = kv({ 1: now.getTime() });
  const r = await run({ SEEN, FCM_SA: SA }, now);
  assert.equal(r.sent, 0);
  assert.equal(SEEN.writes, 0);
  assert.equal(calls.length, 1);
});

test('yeni deprem: ilgili konulara veri mesajı (jeton yeniden kullanılır)', async () => {
  const calls = stub([
    afad('2', 3.4, 39.78, 30.52, '2026-11-03T11:58:00'),
    afad('3', 4.0, 38.0, 30.0, '2026-11-03T09:00:00'), // 3 saat önce: anlık değil
  ]);
  const SEEN = kv({ 1: now.getTime() });
  const r = await run({ SEEN, FCM_SA: SA }, now);
  assert.ok(r.sent >= 1);
  const sends = calls.filter((c) => c.url.includes('fcm.googleapis.com/v1/projects/test-proje/messages:send'));
  assert.equal(sends.length, r.sent);
  const m = JSON.parse(sends[0].init.body).message;
  assert.equal(m.data.id, '2');
  assert.equal(m.data.time, '2026-11-03T11:58:00Z');
  assert.equal(m.android.priority, 'HIGH');
  assert.ok(sends.some((c) => /'il-26'/.test(JSON.parse(c.init.body).message.condition ?? '')));
  assert.equal(sends[0].init.headers.Authorization, 'Bearer tok');
  // eski deprem de görüldü sayılır ama gönderilmez
  assert.ok('3' in SEEN.read());
  assert.equal(SEEN.writes, 1);
});

test('anahtar yokken KV\'ye dokunulmaz', async () => {
  stub([afad('9', 4.2, 39.78, 30.52, '2026-11-03T11:58:00')]);
  const SEEN = kv({ 1: now.getTime() });
  const r = await run({ SEEN }, now);
  assert.equal(r.noSecret, true);
  assert.equal(SEEN.writes, 0);
});
