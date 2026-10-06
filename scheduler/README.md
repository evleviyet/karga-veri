# Feed zamanlayıcısı (Cloudflare Workers)

GitHub Actions'ın `schedule` tetikleyicisi yük altında çalıştırmaları geciktirip atlıyor
(ölçüm: 30 dakikalık cron günde yalnızca 3–6 kez çalıştı). `workflow_dispatch` ile başlatılan
çalıştırmalar ise beklemeden başlar. Bu Worker her 15 dakikada bir `feed` iş akışını tetikler.
`schedule` yedek olarak yerinde kalır.

```
Cloudflare Cron (4,19,34,49 * * * *)
   └─ worker.js ── POST /repos/evleviyet/karga-veri/actions/workflows/feed.yml/dispatches
                     (Authorization: GH_TOKEN — Cloudflare'de şifreli secret)
                        └─ GitHub Actions "feed" → Pages (data/v2/il/<il>.json)
```

## Güvenlik

- Token yalnızca Cloudflare'de **secret** olarak durur (şifreli, yazıldıktan sonra okunamaz).
  Depoda, uygulamada ya da günlüklerde yoktur.
- Token **fine-grained**: yalnızca `evleviyet/karga-veri`, yalnızca **Actions: Read and write**.
  Sızsa bile iş akışı tetiklemek/iptal etmekten öteye gidemez; kodu, ayarları, secret'ları
  değiştiremez.
- Worker'ın HTTP karşılığı yoktur ve `workers.dev` adresi kapalıdır; dışarıdan çağrılamaz.
- Token'ın süresi 1 yıl; dolmadan GitHub e-posta ile hatırlatır. Yenisini oluşturup secret'ı
  güncellemek yeterlidir. Bu arada feed GitHub'ın kendi zamanlayıcısıyla (seyrek) sürer.

## Kurulum (bir kez, ~10 dakika)

1. **Token** — GitHub → Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token
   - Token name: `karga-feed-scheduler`, Expiration: 1 yıl
   - Repository access: *Only select repositories* → `evleviyet/karga-veri`
   - Permissions → Repository permissions → **Actions: Read and write** (başka hiçbir şey)
2. **Worker** — Cloudflare (ücretsiz hesap) → Workers & Pages → Create → Worker
   - Ad: `karga-feed-scheduler` → Deploy → Edit code → `worker.js` içeriğini yapıştır → Deploy
   - Settings → Variables and Secrets → Add → Type **Secret**, Name `GH_TOKEN`, Value: token
   - Settings → Trigger events → **Cron Triggers** → `4,19,34,49 * * * *`
   - Settings → Domains & Routes → `workers.dev` ve *Preview URLs* → **Disable**

   (Alternatif: bu klasörde `npx wrangler deploy` ve `npx wrangler secret put GH_TOKEN`;
   `wrangler.toml` aynı ayarları içerir.)
3. **Doğrulama** — 15 dakika içinde GitHub → Actions → feed altında olayı `workflow_dispatch`
   olan çalıştırmalar görünmeli. Cloudflare → Worker → Logs / Cron Events hataları gösterir
   (ör. `HTTP 401` = token yanlış ya da süresi dolmuş).

## Test

```
node --test scheduler/worker.test.mjs
```
