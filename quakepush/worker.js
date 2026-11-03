// Karga anlık deprem bildirimi — Cloudflare Workers (ücretsiz plan, Cron Trigger).
//
// Dakikada bir AFAD'ın son depremlerine bakar. Yeni bir deprem varsa Firebase
// Cloud Messaging (FCM HTTP v1) ile ilgili illerin konusuna ("il-6") tek bir
// veri mesajı gönderir; büyük depremde (M5+) tüm Türkiye'ye ("tr"). Mesajda
// depremin kendisi vardır: uzaklığı ve kullanıcının hassasiyet ayarını telefon
// kendisi hesaplar. Kullanıcının konumu sunucuya hiç gelmez; telefon yalnızca
// bulunduğu ilin konusuna abonedir.
//
// Kullanıcı sayısı ne olursa olsun yük aynıdır: dakikada bir AFAD isteği,
// deprem başına birkaç FCM isteği. Görülen depremler KV'de tutulur ve KV'ye
// yalnızca yeni deprem çıkınca yazılır (ücretsiz plan: günde 1000 yazma).
//
// Güvenlik: Firebase servis hesabı anahtarı yalnızca Cloudflare'de şifreli
// secret (FCM_SA) olarak durur; depoda ve uygulamada yoktur. Worker'ın HTTP
// karşılığı yoktur, workers.dev adresi kapalıdır.
//
// Ücretli plana geçince yalnızca LIMITS değişir.
import { ILLER } from './iller.js';

export const LIMITS = {
  // Ücretsiz plan: çalışma başına 50 dış istek; AFAD + jeton + gönderimler.
  maxSends: 40,
};

export const AFAD = 'https://servisnet.afad.gov.tr/apigateway/deprem/apiv2/event/filter';
export const MIN_MAG = 3.0; // en hassas ayarın en küçüğü (uygulama: quakeTierLevels)
export const ALL_MAG = 5.0; // bu büyüklükten itibaren tüm Türkiye'ye gider
const FRESH_MIN = 30; // bundan eski deprem anlık haber sayılmaz (geç eklenen kayıtlar)
const KEEP_H = 48;

// Uygulamadaki üç hassasiyet ayarının (büyüklük, uzaklık km) basamakları.
const TIERS = [
  [3.0, 50], [4.0, 200], [5.0, 600],
  [3.5, 60], [4.5, 250], [5.5, 700],
  [4.5, 120], [5.5, 450], [6.5, 1200],
];

/** Bu büyüklükteki depremin herhangi bir ayarda haber olabileceği en uzak mesafe. */
export function reach(mag) {
  return Math.max(0, ...TIERS.filter(([m]) => mag >= m).map(([, km]) => km));
}

export function km(a, b, c, d) {
  const r = 6371, rad = (x) => (x * Math.PI) / 180;
  const h = Math.sin(rad(c - a) / 2) ** 2 + Math.cos(rad(a)) * Math.cos(rad(c)) * Math.sin(rad(d - b) / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(h));
}

/** Depremin gideceği konular: M5+ "tr", değilse etki alanına giren iller. */
export function topicsFor(q) {
  if (q.mag >= ALL_MAG) return ['tr'];
  const r = reach(q.mag);
  return ILLER.filter(([, lat, lon, rad]) => km(q.lat, q.lon, lat, lon) <= r + rad).map(([p]) => `il-${p}`);
}

/** FCM koşulu en çok 5 konu alır: konuları beşerli koşullara böler. */
export function conditions(topics) {
  const out = [];
  for (let i = 0; i < topics.length; i += 5) {
    out.push(topics.slice(i, i + 5).map((t) => `'${t}' in topics`).join(' || '));
  }
  return out;
}

export function parseAfad(list) {
  if (!Array.isArray(list)) throw new Error('AFAD: liste gelmedi');
  return list
    .map((e) => ({
      id: String(e.eventID),
      mag: Number(e.magnitude),
      lat: Number(e.latitude),
      lon: Number(e.longitude),
      depth: String(e.depth ?? ''),
      place: String(e.location ?? ''),
      time: `${e.date}Z`, // AFAD saati UTC, saat dilimi eksiz
    }))
    .filter((q) => q.id && Number.isFinite(q.mag) && Number.isFinite(q.lat) && Number.isFinite(q.lon));
}

const utc = (d) => d.toISOString().split('.')[0];

export default {
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(run(env, new Date(controller.scheduledTime ?? Date.now())));
  },
};

export async function run(env, now) {
  const start = new Date(now.getTime() - 2 * 3600e3);
  const res = await fetch(
    `${AFAD}?start=${utc(start)}&end=${utc(new Date(now.getTime() + 3600e3))}&minmag=${MIN_MAG}&orderby=timedesc&limit=100`,
    { headers: { 'User-Agent': 'karga-quakepush' } },
  );
  if (res.status !== 200) throw new Error(`AFAD HTTP ${res.status}`);
  const quakes = parseAfad(await res.json());
  // Anahtar girilmeden KV'ye dokunulmaz: yeni depremler "görüldü" sayılıp
  // kaybolmasın (AFAD yine okunur ki erişim günlükte görülsün).
  if (!env.FCM_SA) {
    console.log(`FCM_SA yok; AFAD ${quakes.length} kayıt`);
    return { sent: 0, noSecret: true };
  }

  const raw = await env.SEEN.get('seen');
  const seen = raw ? JSON.parse(raw) : null;
  // İlk çalışma: o anki listeyi görüldü say, eski depremleri bildirme. Anahtar
  // FCM'nin kuru çalıştırmasıyla (validate_only: kimseye gitmez) denenir.
  if (!seen) {
    await env.SEEN.put('seen', JSON.stringify(Object.fromEntries(quakes.map((q) => [q.id, now.getTime()]))));
    const check = await send(env, { topic: 'tr', data: { type: 'check' } }, true);
    console.log(`İlk çalışma; FCM denemesi HTTP ${check}`);
    return { sent: 0, first: true, check };
  }
  const fresh = quakes.filter(
    (q) => !(q.id in seen) && now.getTime() - Date.parse(q.time) <= FRESH_MIN * 60e3,
  );
  // Yeni deprem yoksa KV'ye yazılmaz.
  if (fresh.length === 0) return { sent: 0 };

  for (const q of quakes) seen[q.id] ??= now.getTime();
  for (const [id, t] of Object.entries(seen)) if (now.getTime() - t > KEEP_H * 3600e3) delete seen[id];
  await env.SEEN.put('seen', JSON.stringify(seen));

  let sent = 0;
  for (const q of fresh.sort((a, b) => b.mag - a.mag)) {
    const topics = topicsFor(q);
    const targets = topics.length === 1 ? [{ topic: topics[0] }] : conditions(topics).map((c) => ({ condition: c }));
    for (const t of targets) {
      if (sent >= LIMITS.maxSends) break;
      await send(env, {
        ...t,
        data: {
          type: 'quake',
          id: q.id,
          mag: String(q.mag),
          lat: String(q.lat),
          lon: String(q.lon),
          depth: q.depth,
          place: q.place,
          time: q.time,
        },
        android: { priority: 'HIGH', ttl: `${FRESH_MIN * 60}s` },
      });
      sent++;
    }
  }
  return { sent };
}

/** FCM HTTP v1 gönderimi; [validateOnly] kimseye göndermeden yalnızca dener. */
async function send(env, message, validateOnly = false) {
  const token = await accessToken(env);
  const sa = JSON.parse(env.FCM_SA);
  const r = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message, ...(validateOnly ? { validate_only: true } : {}) }),
  });
  if (r.status !== 200) console.error(`FCM HTTP ${r.status} ${await r.text()}`);
  return r.status;
}

// --- Google OAuth (servis hesabı JWT, RS256) ---
let cached = null; // aynı isolate'ta jeton yeniden kullanılır

async function accessToken(env) {
  const nowS = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > nowS) return cached.token;
  if (!env.FCM_SA) throw new Error('FCM_SA secret tanımlı değil');
  const sa = JSON.parse(env.FCM_SA);
  const b64 = (o) => btoa(typeof o === 'string' ? o : JSON.stringify(o)).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
  const head = b64({ alg: 'RS256', typ: 'JWT' });
  const claim = b64({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: nowS,
    exp: nowS + 3600,
  });
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${claim}`)));
  const jwt = `${head}.${claim}.${b64(String.fromCharCode(...sig))}`;
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  });
  if (res.status !== 200) throw new Error(`OAuth HTTP ${res.status}`);
  const j = await res.json();
  cached = { token: j.access_token, exp: nowS + (j.expires_in ?? 3600) };
  return cached.token;
}
