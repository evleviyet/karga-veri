# karga-veri

Karga uygulamasının veri katmanı. GitHub Actions kamu kaynaklarını 30 dakikada bir okur,
normalize JSON üretir ve GitHub Pages'te statik API olarak yayımlar. Uygulama yalnızca bu
JSON'u okur; kullanıcının konumu hiçbir yere gönderilmez (il dosyası cihazda seçilir).

## Kapsam

Kullanıcı Türkiye'nin neresinde olursa olsun konumu il/ilçeye çevrilir ve o yere hizmet veren
kurumların "kara haber"leri (kesinti, uyarı, tatil, afet...) iletilir.

| Tür | Kaynak | Kapsam |
|---|---|---|
| Hava uyarısı | MGM MeteoUyarı (sarı/turuncu/kırmızı) | 81 il, ilçe düzeyinde |
| Resmi duyuru | 81 valilik duyuru sayfası (tatil, afet, yasak, karantina, yol...) | 81 il |
| Deprem | AFAD (uygulama doğrudan okur) | Türkiye |
| Elektrik | BEDAŞ, AEDAŞ, ÇEDAŞ (CK Enerji), Çoruh, Fırat, KCETAŞ, UEDAŞ | 26 il + İstanbul Avrupa yakası |
| Elektrik (cihazdan) | MEDAŞ — uygulama Türkiye'den kendisi okur | 6 il |
| Su | ASKİ (Ankara), İZSU, SASKİ (Samsun), TİSKİ | 4 büyükşehir |
| Su (cihazdan) | DESKİ — uygulama Türkiye'den kendisi okur | Denizli |
| Belediye | Ankara Büyükşehir duyuruları | Ankara |

MEDAŞ (`cc.meramedas.com.tr`), DESKİ (`sukesinti.deski.gov.tr`) ve YEDAŞ (`www.yedas.com`)
GitHub runner'larının (yurt dışı IP) bağlantısını TCP düzeyinde düşürür. MEDAŞ (ilçe sorgusu
~50 KB) ve DESKİ (~12 KB) uygulamada cihazdan okunur; YEDAŞ'ın tek uç noktası filtresiz ve
sıkıştırmasız ~1,9 MB olduğu için okunmaz. UEDAŞ'ın API'si de kapalıdır, ama ana sitenin resmi
planlı kesinti uç noktası (`www.uedas.com.tr/planli-kesintiler/sec.asp`) açıktır ve kullanılır.

Otomatik okunamayan kurumlar (reCAPTCHA/bot koruması: Başkent EDAŞ, AYEDAŞ, Toroslar, TREDAŞ,
GDZ, ADM, OEDAŞ, SEDAŞ, Akedaş; erişilemeyen: Dicle, VEDAŞ, Aras, YEDAŞ) için uygulama kurumu,
resmi kesinti sayfasını ve 185/186 hatlarını gösterir. Güncel durum: sitenin `index.html` sayfası.

## Kayıt defteri (`registry/`)

- `geo.json`: 81 il, 973 ilçe; NVİ ilçe kodu, nüfus, MGM merkez kimlikleri ve koordinatlar.
  `dart run tool/build_registry.dart` ile yeniden üretilir.
- `providers.json`: elle bakılan kurum tablosu — 21 elektrik dağıtım bölgesi (İstanbul'da
  ilçeye göre BEDAŞ/AYEDAŞ), 30 büyükşehir su idaresi, valilik/belediye adresleri.

## Çıktı (Pages)

- `data/v2/il/<il>.json` — uygulamanın tek istekte okuduğu dosya: kurumlar, kaynak durumları,
  kayıtlar. Kayıt alanları: `id, kind (water|power|gas|weather|general), source, title,
  detail, district, start, end, neighborhoods, area [güney, batı, kuzey, doğu], level, url,
  planned`. Saatler Türkiye yerel saatidir (saat dilimi eki yok).
- `data/v2/meta.json` — tüm kaynakların durumu; `data/v2/registry.json` — birleşik kayıt defteri.
- `data/meta.json`, `data/ankara/*.json` — sürüm 1 (eski uygulama sürümleri).

Bir kaynak okunamazsa son başarılı okuması (6 saate kadar) yayımlanmaya devam eder ve durumu
`degraded` + `stale` olarak işaretlenir.

## Kurulum (bir kez)

1. Settings → Pages → Build and deployment → Source: **GitHub Actions**. Kaynak "branch" iken
   her push ve botun `data/` commit'i siteyi eski içeriğe (yalnızca sürüm 1) döndürür.
2. **Zamanlayıcı:** GitHub'ın `schedule` tetikleyicisi günde yalnızca 3–6 kez çalışıyor. 15
   dakikalık yenileme için [`scheduler/`](scheduler/README.md) altındaki Cloudflare Worker
   kurulur (ücretsiz; token yalnızca Cloudflare'de şifreli durur).

## Geliştirme

```
dart pub get
dart test
dart run bin/build_feed.dart site            # tüm kaynaklar
ONLY=ck- dart run bin/build_feed.dart site   # yalnızca bir grup
```

Yeni kaynak: ayrıştırıcıyı `lib/parsers/` altına saf fonksiyon olarak yaz, örnek yanıtı
`test/fixtures/` altına koy, `lib/sources.dart` listesine ekle. `probe` iş akışı tüm
kaynakları GitHub runner'ından dener (elle ya da kaynak kodu/kayıt defteri değişince push ile);
sonuç iş özetinde tablo, kısa özet ve okunamayan kaynaklar çalıştırma sayfasında uyarı notu
olarak görünür. `feed` iş akışı da her turda aynı özeti bırakır.
