import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'net.dart';
import 'parsers/announcements.dart';
import 'parsers/aski.dart';
import 'parsers/electricity.dart';
import 'parsers/mgm.dart';
import 'parsers/water.dart';
import 'registry.dart';

/// Bir kaynağın çalıştığı bağlam.
class Ctx {
  final Net net;
  final Registry reg;

  /// Türkiye yerel saati.
  final DateTime now;

  /// Çalışmalar arasında saklanan önbellek (ör. trafo -> mahalle).
  final Directory cacheDir;
  Ctx(this.net, this.reg, this.now, this.cacheDir);
}

/// Feed kaynağı: hangi illeri kapsadığı ve nasıl okunduğu.
class Source {
  final String id;
  final String name;
  final NoticeKind kind;

  /// providers.json'daki kurum (varsa): uygulama "canlı takip" rozetini buna göre gösterir.
  final String? kurum;
  final List<int> plakas;
  final Future<List<Notice>> Function(Ctx ctx) run;

  Source(this.id, this.name, this.kind, this.plakas, this.run, {this.kurum});
}

const _mgmHeaders = {
  'Origin': 'https://www.mgm.gov.tr',
  'Referer': 'https://www.mgm.gov.tr/meteouyari/turkiye.aspx',
};

/// Tüm kaynaklar. Sıra önemsiz; aynı anda birkaçı çalışır.
List<Source> allSources(Registry reg) => [
      // --- Ülke geneli ---
      Source('mgm', 'MGM', NoticeKind.weather, [for (final il in reg.iller) il.plaka],
          (c) async {
        final today = await c.net.getJson(
            'https://servis.mgm.gov.tr/web/meteoalarm/today',
            headers: _mgmHeaders);
        final tomorrow = await c.net.getJson(
            'https://servis.mgm.gov.tr/web/meteoalarm/tomorrow',
            headers: _mgmHeaders);
        if (today is! List || tomorrow is! List) {
          throw const FormatException('MGM: liste beklenirken başka yanıt geldi');
        }
        final byId = {
          for (final n in mgmNotices(tomorrow, c.reg, gun: 2)) n.id: n,
          for (final n in mgmNotices(today, c.reg, gun: 1)) n.id: n,
        };
        return byId.values.toList();
      }),
      for (final il in reg.iller)
        Source('valilik-${il.key}', '${il.ad} Valiliği', NoticeKind.general,
            [il.plaka], (c) async {
          final html = await c.net.get('${il.valilikUrl}/duyurular');
          return valilikKaraHaber(
              parseValilik(html, now: c.now), c.now, il.ad, il.plaka);
        }),

      // --- Su ---
      Source('aski', 'ASKİ', NoticeKind.water, [6], kurum: 'aski', (c) async {
        return parseAski(await c.net.get('https://www.aski.gov.tr/tr/Kesinti.aspx'));
      }),
      Source('izsu', 'İZSU', NoticeKind.water, [35], kurum: 'izsu', (c) async {
        const url = 'https://izsu.gov.tr/bilgi-merkezi/ariza-ve-bakim-bilgisi-sorgulama';
        return arizaTableNotices(await c.net.get(url),
            source: 'İZSU', url: url, plaka: 35, reg: c.reg, now: c.now);
      }),
      Source('saski', 'SASKİ', NoticeKind.water, [55], kurum: 'saski', (c) async {
        return saskiNotices(
            await c.net.get('https://www.saski.gov.tr/sukesintileri/'),
            reg: c.reg,
            now: c.now);
      }),
      Source('tiski', 'TİSKİ', NoticeKind.water, [61], kurum: 'tiski', (c) async {
        return tiskiNotices(
            await c.net.get('https://www.tiski.gov.tr/Tiski/SuKesintileri'),
            reg: c.reg,
            now: c.now);
      }),

      // --- Belediye ---
      Source('abb', 'Ankara Büyükşehir Belediyesi', NoticeKind.general, [6],
          (c) async {
        return abbNotices(
            parseAbb(await c.net.get('https://www.ankara.bel.tr/duyurular')), c.now);
      }),

      // --- Elektrik ---
      _ck('BEDAS', 'bedas', 'BEDAŞ', 'https://kesinti.bedas.com.tr', [34]),
      _ck('AEDAS', 'akdeniz', 'AEDAŞ', 'https://kesinti.akdenizedas.com.tr', [7, 32, 15]),
      _ck('CEDAS', 'cedas', 'ÇEDAŞ', 'https://www.cedas.com.tr', [58, 60, 66]),
      _aksa('coruh', 'Çoruh EDAŞ', 'https://www.coruhedas.com.tr', [61, 8, 28, 29, 53]),
      _aksa('firat', 'Fırat EDAŞ', 'https://www.firatedas.com.tr', [23, 12, 44, 62]),
      Source('kcetas', 'KCETAŞ', NoticeKind.power, [38], kurum: 'kcetas', (c) async {
        return kcetasNotices(
            await c.net.get('https://www.kcetas.com.tr/tr/planli-kesintiler-bakimlar'),
            reg: c.reg,
            now: c.now);
      }),
      Source('uedas', 'UEDAŞ', NoticeKind.power, [16, 10, 17, 77], kurum: 'uedas',
          (c) async {
        const page = 'https://www.uedas.com.tr/tr/kesintiler';
        final ids = uedasDistrictIds(await c.net.get(page));
        // İlçe başına küçük bir istek (~20 KB); tek tük hata tüm kaynağı düşürmesin.
        final xmls = await pooled([
          for (final id in ids)
            () async {
              try {
                return await c.net.postForm(
                    'https://www.uedas.com.tr/planli-kesintiler/sec.asp', {'ilce': '$id'},
                    headers: {'Referer': page, 'X-Requested-With': 'XMLHttpRequest'});
              } catch (_) {
                return null;
              }
            }
        ], 4);
        final ok = xmls.whereType<String>().toList();
        if (ok.length < ids.length * 0.8) {
          throw Exception('UEDAŞ: ${ids.length - ok.length}/${ids.length} ilçe okunamadı');
        }
        return uedasNotices(ok, reg: c.reg, now: c.now);
      }),

      // GitHub runner'larından (yurt dışı IP) TCP düzeyinde erişilemeyen kaynaklar
      // feed'de çalıştırılmaz; ayrıştırıcıları ve testleri durur:
      //  - MEDAŞ (cc.meramedas.com.tr) ve DESKİ (sukesinti.deski.gov.tr): uygulama
      //    Türkiye'den kendisi okur (ilçe sorgusu ~50 KB, ~12 KB).
      //  - YEDAŞ (www.yedas.com): tek uç nokta, filtresiz ve sıkıştırmasız ~1,9 MB;
      //    cihazdan okumak mobil veri açısından ağır. Uygulama resmi sayfayı gösterir.
    ];

Source _ck(String company, String kurum, String name, String url, List<int> plakas) =>
    Source('ck-${company.toLowerCase()}', name, NoticeKind.power, plakas,
        kurum: kurum, (c) async {
      final base = 'https://kesintiapi.ckenerji.com.tr/$company';
      final outages =
          await c.net.getJson('$base/RetrieveOutages') as Map<String, dynamic>;
      Map<String, dynamic>? tms;
      if ((outages['Outage'] as List?)?.isNotEmpty ?? false) {
        tms = await c.net.getJson('$base/RetrieveOutageTransformersList')
            as Map<String, dynamic>;
      }
      // Trafo konumları değişmez: önbellekte tutulur, yalnızca yeniler sorulur.
      final cache = JsonCache(c.cacheDir, 'ck-$company');
      final need = ckTransformers(outages, tms)
          .where((tm) => !cache.data.containsKey(tm))
          .take(800)
          .toList();
      await pooled([
        for (final tm in need)
          () async {
            try {
              final loc = ckLocation(
                  await c.net.getJson('$base/GetLocation?tmno=$tm') as Map<String, dynamic>);
              if (loc != null) cache.data[tm] = [loc.ilce, loc.mahalle];
            } catch (_) {
              // Bu trafo bu tur atlanır; kesinti yine koordinatla bir ilçeye bağlanır.
            }
          }
      ], 8);
      cache.save();
      return ckNotices(
        company: company.toLowerCase(),
        source: name,
        url: url,
        plakas: plakas,
        outages: outages,
        transformers: tms,
        locations: {
          for (final e in cache.data.entries)
            e.key: (ilce: '${(e.value as List)[0]}', mahalle: '${(e.value as List)[1]}'),
        },
        reg: c.reg,
      );
    });

Source _aksa(String kurum, String name, String web, List<int> plakas) =>
    Source('aksa-$kurum', name, NoticeKind.power, plakas, kurum: kurum, (c) async {
      // Bu ayın (ay sonuna yakınsa gelecek ayın da) planlı kesintileri.
      final months = <DateTime>{
        DateTime(c.now.year, c.now.month),
        if (c.now.day >= 24) DateTime(c.now.year, c.now.month + 1),
      };
      final out = <Notice>[];
      for (final p in plakas) {
        for (final m in months) {
          final html = await c.net.get(
              '$web/BilgiDanisma/GetKesintiler?yil=${m.year}&ay=${m.month}&il=$p&ilce=');
          out.addAll(aksaNotices(html,
              company: kurum,
              source: name,
              url: '$web/BilgiDanisma/BakimProgramiveKesintiListesi',
              plaka: p,
              reg: c.reg,
              now: c.now));
        }
      }
      return out;
    });

/// Çalışmalar arasında saklanan küçük JSON önbelleği.
class JsonCache {
  final File file;
  final Map<String, dynamic> data;

  JsonCache._(this.file, this.data);

  factory JsonCache(Directory dir, String name) {
    final f = File('${dir.path}/$name.json');
    Map<String, dynamic> d = {};
    try {
      if (f.existsSync()) d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      d = {};
    }
    return JsonCache._(f, d);
  }

  void save() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(data));
  }
}
