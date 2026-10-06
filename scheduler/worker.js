// Karga feed zamanlayıcısı — Cloudflare Workers (ücretsiz plan, Cron Trigger).
//
// GitHub'ın kendi zamanlayıcısı (schedule) yük altında çalıştırmaları saatlerce
// geciktirip atlıyor. Bu Worker her 15 dakikada bir "feed" iş akışını
// workflow_dispatch ile tetikler; dispatch çalıştırmaları beklemeden başlar.
//
// Güvenlik:
//  - GitHub token'ı yalnızca Cloudflare'de şifreli "secret" (GH_TOKEN) olarak
//    durur; bu dosyada, depoda ya da uygulamada yoktur.
//  - Token "fine-grained": yalnızca evleviyet/karga-veri, yalnızca
//    "Actions: Read and write" yetkisi (iş akışı tetikleyebilir; kodu, ayarları,
//    secret'ları değiştiremez).
//  - Worker'ın HTTP karşılığı (fetch) yoktur ve workers.dev adresi kapalıdır:
//    dışarıdan çağrılamaz, yalnızca zamanlayıcı çalıştırır.
const REPO = 'evleviyet/karga-veri';
const WORKFLOW = 'feed.yml';

export default {
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(dispatch(env));
  },
};

async function dispatch(env) {
  if (!env.GH_TOKEN) throw new Error('GH_TOKEN secret tanımlı değil');
  const res = await fetch(
    `https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GH_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'karga-feed-scheduler',
      },
      body: JSON.stringify({ ref: 'main' }),
    },
  );
  if (res.status !== 204) {
    // Yanıt gövdesi token içermez; Cloudflare'in Cron olayları ve günlüğünde görünür.
    throw new Error(`workflow_dispatch başarısız: HTTP ${res.status} ${await res.text()}`);
  }
}
