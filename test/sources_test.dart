import 'dart:convert';
import 'dart:io';

import 'package:karga_feed/models.dart';
import 'package:karga_feed/parsers/announcements.dart';
import 'package:karga_feed/parsers/aski.dart';
import 'package:karga_feed/parsers/electricity.dart';
import 'package:karga_feed/parsers/mgm.dart';
import 'package:karga_feed/parsers/water.dart';
import 'package:karga_feed/registry.dart';
import 'package:test/test.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();
dynamic fxJson(String n) => jsonDecode(fx(n));

void main() {
  final reg = Registry.load();
  // Örnek veriler 6 Ekim 2026 öğlen alındı.
  final now = DateTime(2026, 10, 6, 12);

  group('ülke geneli', () {
    test('MGM: uyarılar ilçe ilçe, Türkiye saatine çevrilmiş', () {
      final n = mgmNotices(fxJson('mgm_today.json') as List, reg);
      expect(n, isNotEmpty);
      final agri = n.where((x) => x.plaka == 4 && x.district == 'Merkez').single;
      expect(agri.kind, NoticeKind.weather);
      expect(agri.level, 'yellow');
      expect(agri.title, 'Sarı uyarı: Gök gürültülü sağanak');
      expect(agri.start, DateTime(2026, 10, 6, 16, 0, 15));
      expect(agri.end, DateTime(2026, 10, 6, 22, 0, 15));
      expect(agri.detail, contains('ani sel'));
      // Her kayıt bir ile ve o ilin gerçek bir ilçesine bağlı.
      for (final x in n) {
        expect(reg.byPlaka(x.plaka)!.ilce(x.district), isNotNull);
      }
      expect(n.map((x) => x.id).toSet().length, n.length);
    });

    test('MGM: aynı ilçe iki seviyede geçerse en yükseği kalır', () {
      final alerts = [
        {
          'alertNo': 1,
          'begin': '2026-10-06T06:00:00.000Z',
          'end': '2026-10-06T18:00:00.000Z',
          'text': {'yellow': 'sarı', 'orange': 'turuncu'},
          'weather': {
            'yellow': ['rain'],
            'orange': ['snow', 'wind'],
          },
          // 90601: Keçiören (Ankara)
          'towns': {
            'yellow': [90601],
            'orange': [90601],
          },
        }
      ];
      final n = mgmNotices(alerts, reg);
      expect(n, hasLength(1));
      expect(n.single.level, 'orange');
      expect(n.single.title, 'Turuncu uyarı: Kar, Rüzgâr');
      expect(n.single.district, 'Keçiören');
    });

    test('Valilik: yılı yazılmamış duyurular da okunuyor', () {
      final v = parseValilik(fx('valilik_yilsiz.html'), now: now);
      expect(v, isNotEmpty);
      expect(v.first.date, DateTime(2026, 10, 2));
      expect(v.first.url, startsWith('https://www.amasya.gov.tr/'));
      // Ocak'ta görülen "Ara" (Aralık) duyurusu geçen yıla aittir.
      expect(inferYear(12, 30, DateTime(2027, 1, 3)), 2026);
    });

    test('Kara haber süzgeci', () {
      for (final t in [
        'Kar Yağışı Nedeniyle Okulların Tatil Edildiğine İlişkin Duyuru',
        'Kuvvetli Yağış ve Fırtına Uyarısı',
        'Ormanlık Alanlara Giriş Yasağı Hakkında',
        'İkaz, Alarm ve Siren Sistemleri Test Ediliyor',
        'Orman Yangını Hakkında Basın Açıklaması',
        'Kuduz Karantinası İlan Edildi',
        'Yol Trafiğe Kapatılacaktır',
      ]) {
        expect(isKaraHaber(t), isTrue, reason: t);
      }
      for (final t in [
        'KPSS Sınav Duyurusu',
        'İhale İlanı',
        'Maya Üretim Tesisi ÇED Olumlu Karar İlanı',
        'İçişleri Bakanlığı Görevde Yükselme Sınav Duyurusu',
        'Tedbirinizi alın, yangını önleyin!',
        'Çiğ Köfte Satış Noktaları Denetlendi',
      ]) {
        expect(isKaraHaber(t), isFalse, reason: t);
      }
    });
  });

  group('elektrik', () {
    test('CK Enerji: trafolar mahalleye, alan sınırları kesintiye bağlanıyor', () {
      final outages = {
        'Outage': [
          {
            'OUTAGE_NO': '1',
            'BILDIRIM_TURU': 'Bildirimli',
            'RPTD_DATE': '2026-10-06T10:12:05.000+03:00',
            'EST_REPAIR_TIME': '2026-10-06T17:00:00.000+03:00',
            'CBS_TM_NO': '100',
          },
          {
            'OUTAGE_NO': '1',
            'BILDIRIM_TURU': 'Bildirimli',
            'RPTD_DATE': '2026-10-06T10:12:05.000+03:00',
            'EST_REPAIR_TIME': '2026-10-06T17:00:00.000+03:00',
            'CBS_TM_NO': '101',
          },
          // Tahmini bitişi başlangıcından önce: bitiş bilinmiyor sayılır.
          {
            'OUTAGE_NO': '2',
            'BILDIRIM_TURU': 'Bildirimsiz',
            'RPTD_DATE': '2026-10-06T13:36:21.000+03:00',
            'EST_REPAIR_TIME': '2026-10-06T13:00:00.000+03:00',
            'CBS_TM_NO': '200',
          },
        ],
      };
      final tms = {
        'OutageTransformersList': {
          'OutageTransformers': [
            // Tokat merkezine yakın
            {'OUTAGE_NO': '2', 'TM_NO': '200', 'LAT': '40.31', 'LON': '36.55'},
            {'OUTAGE_NO': '2', 'TM_NO': '200', 'LAT': '40.32', 'LON': '36.56'},
          ],
        },
      };
      expect(ckTransformers(outages, tms), {'100', '101', '200'});
      final n = ckNotices(
        company: 'cedas',
        source: 'ÇEDAŞ',
        url: 'https://www.cedas.com.tr',
        plakas: const [58, 60, 66],
        outages: outages,
        transformers: tms,
        locations: {
          '100': (ilce: 'ŞARKIŞLA', mahalle: 'HÜYÜKKÖY'),
          '101': (ilce: 'ŞARKIŞLA', mahalle: 'ALACA'),
          // "MERKEZ" üç ilde de var: koordinat Tokat'ı gösteriyor.
          '200': (ilce: 'MERKEZ', mahalle: 'TUZLUGÖL'),
        },
        reg: reg,
      );
      expect(n, hasLength(2));
      final sarkisla = n.firstWhere((x) => x.district == 'Şarkışla');
      expect(sarkisla.plaka, 58);
      expect(sarkisla.neighborhoods, ['ALACA', 'HÜYÜKKÖY']);
      expect(sarkisla.detail, 'Alaca, Hüyükköy');
      expect(sarkisla.planned, isTrue);
      expect(sarkisla.start, DateTime(2026, 10, 6, 10, 12, 5));
      expect(sarkisla.end, DateTime(2026, 10, 6, 17));
      final merkez = n.firstWhere((x) => x.district == 'Merkez');
      expect(merkez.plaka, 60);
      expect(merkez.title, 'Elektrik arızası');
      expect(merkez.end, isNull);
      expect(merkez.area, [40.31, 36.55, 40.32, 36.56]);
    });

    test('Aksa (Çoruh/Fırat): satırlar mahalle listesine toplanıyor', () {
      final n = aksaNotices(fx('aksa_trabzon.html'),
          company: 'coruh',
          source: 'Çoruh EDAŞ',
          url: 'u',
          plaka: 61,
          reg: reg,
          now: now);
      expect(n, isNotEmpty);
      final akcaabat = n.firstWhere((x) =>
          x.district == 'Akçaabat' && x.start == DateTime(2026, 10, 9, 2));
      expect(akcaabat.neighborhoods, containsAll(['AKDAMAR MAH.', 'ALSANCAK MAH.']));
      expect(akcaabat.end, DateTime(2026, 10, 9, 3));
      // "Köprübası / Trabzon" yazımı ilçeye çözülüyor.
      expect(n.any((x) => x.district == 'Köprübaşı'), isTrue);
      for (final x in n) {
        expect(reg.byPlaka(61)!.ilce(x.district), isNotNull, reason: x.district);
      }
      expect(
          () => aksaNotices('<html><body>hata</body></html>',
              company: 'c', source: 's', url: 'u', plaka: 61, reg: reg, now: now),
          throwsFormatException);
    });

    test('KCETAŞ: tamamlanan kesintiler atlanıyor', () {
      final n = kcetasNotices(fx('kcetas.html'), reg: reg, now: now);
      expect(n, isNotEmpty);
      final k = n.firstWhere((x) => x.neighborhoods.contains('KAYABAŞI MAH.'));
      expect(k.district, 'Kocasinan');
      expect(k.start, DateTime(2026, 10, 6, 8, 45));
      expect(k.end, DateTime(2026, 10, 6, 17));
      expect(n.any((x) => x.neighborhoods.contains('ERENKÖY MAH.')), isFalse);
      expect(() => kcetasNotices('<html></html>', reg: reg, now: now),
          throwsFormatException);
    });

    test('YEDAŞ: zaman pencereleri ve alan sınırları', () {
      final n = yedasNotices(fxJson('yedas.json') as Map<String, dynamic>,
          reg: reg, now: now);
      expect(n, isNotEmpty);
      for (final x in n) {
        expect([55, 5, 19, 52, 57], contains(x.plaka));
        expect(x.area, hasLength(4));
        expect(x.start!.isBefore(DateTime(2026, 10, 9, 12)), isTrue);
        expect(x.end!.isAfter(DateTime(2026, 10, 6)), isTrue);
        expect(reg.byPlaka(x.plaka)!.ilce(x.district), isNotNull);
      }
      expect(() => yedasNotices({'result': {}}, reg: reg, now: now),
          throwsFormatException);
    });

    test('MEDAŞ: sokak satırları kesinti başına toplanıyor', () {
      final rows = fxJson('meram_konya.json') as List;
      final n = meramNotices(rows, plaka: 42, reg: reg, now: now);
      expect(n, isNotEmpty);
      expect(n.length, lessThan(rows.length));
      for (final x in n) {
        expect(x.plaka, 42);
        expect(x.neighborhoods, isNotEmpty);
        expect(reg.byPlaka(42)!.ilce(x.district), isNotNull);
      }
    });

    test('UEDAŞ: mahalle listesi ve il çözümü', () {
      final n = uedasNotices(fxJson('uedas.json') as Map<String, dynamic>,
          planned: true, reg: reg, now: now);
      expect(n, isNotEmpty);
      final b = n.firstWhere((x) => x.neighborhoods.contains('KARAKAYA'));
      expect(b.plaka, 10);
      expect(b.district, 'Altıeylül');
      expect(b.start, DateTime(2026, 10, 7, 9, 30));
      expect(
          () => uedasNotices({'SonucDurum': 0, 'SonucMesaj': 'Hata'},
              planned: true, reg: reg, now: now),
          throwsFormatException);
      // Kesinti yokken boş liste döner.
      expect(
          uedasNotices({'SonucDurum': 1, 'SonucIcerik': null},
              planned: false, reg: reg, now: now),
          isEmpty);
    });
  });

  group('su', () {
    test('ASKİ: detay metnindeki "Arıza Tarihi" yazısı kayıt sayılmıyor', () {
      final n = parseAski(fx('aski_detayli.html'));
      expect(n, hasLength(6));
      expect(n.first.plaka, 6);
    });

    test('İZSU: tablo satırları ve saat aralığı', () {
      final n = arizaTableNotices(fx('izsu.html'),
          source: 'İZSU', url: 'u', plaka: 35, reg: reg, now: now);
      expect(n, isNotEmpty);
      final b = n.firstWhere((x) => x.district == 'Bayraklı');
      expect(b.start, DateTime(2026, 10, 6, 10, 15));
      expect(b.end, DateTime(2026, 10, 6, 16, 15));
      expect(b.neighborhoods, contains('ÇAY'));
      expect(
          () => arizaTableNotices('<table><tr><th>x</th></tr></table>',
              source: 'İZSU', url: 'u', plaka: 35, reg: reg, now: now),
          throwsFormatException);
    });

    test('SASKİ: yılsız tarih ve ilçe/mahalle ayrımı', () {
      final n = saskiNotices(fx('saski.html'), reg: reg, now: now);
      expect(n, isNotEmpty);
      final a = n.firstWhere((x) => x.district == 'Atakum' &&
          x.neighborhoods.contains('ÇAKIRLAR MAH.'));
      expect(a.start, DateTime(2026, 10, 6, 14));
      expect(a.end, DateTime(2026, 10, 6, 18));
      expect(a.neighborhoods, contains('İNCESU YALI MAH.'));
    });

    test('TİSKİ: kart başlığındaki ilçe/mahalle üçlüleri', () {
      final n = tiskiNotices(fx('tiski.html'), reg: reg, now: now);
      expect(n, isNotEmpty);
      final of = n.firstWhere((x) => x.district == 'Of');
      expect(of.neighborhoods, ['İRFANLI MAH.']);
      expect(of.start, DateTime(2026, 10, 6, 12));
      expect(of.end, DateTime(2026, 10, 6, 17));
    });

    test('DESKİ: JSON kayıtları', () {
      final n = deskiNotices(fxJson('deski.json') as List, reg: reg, now: now);
      expect(n, isNotEmpty);
      for (final x in n) {
        expect(x.plaka, 20);
        expect(reg.byPlaka(20)!.ilce(x.district), isNotNull, reason: x.district);
      }
    });
  });

  test('yardımcılar', () {
    expect(titleTr('İNCESU YALI MAH.'), 'İncesu Yalı Mah.');
    expect(titleTr('ISPARTA'), 'Isparta');
    expect(mahalleKey('Çaytepe Mh.'), 'caytepe');
    expect(mahalleKey('GÜNEŞTEPE MAHALLESİ'), 'gunestepe');
    expect(parseIsoTr('2026-10-06T13:32:02.000+03:00'), DateTime(2026, 10, 6, 13, 32, 2));
    expect(parseIsoTr('2026-10-06 12:00:00.0'), DateTime(2026, 10, 6, 12));
    expect(parseDayMonthHm('06 Ekim 14:00', now), DateTime(2026, 10, 6, 14));
    expect(inWindow(DateTime(2026, 10, 5, 8), DateTime(2026, 10, 5, 10), now), isFalse);
    expect(inWindow(DateTime(2026, 10, 12, 8), null, now), isFalse);
    expect(inWindow(DateTime(2026, 10, 7, 8), DateTime(2026, 10, 7, 10), now), isTrue);
    expect(neighborhoodsLine(['A', 'B', 'C'], max: 2), 'A, B ve 1 yer daha');
  });
}
