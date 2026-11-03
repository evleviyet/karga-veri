import 'dart:io';

import 'package:karga_feed/models.dart';
import 'package:karga_feed/parsers/water.dart';
import 'package:karga_feed/registry.dart';
import 'package:test/test.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  final reg = Registry.load();
  // Örnek sayfalar 3 Kasım 2026 öğleden sonra alındı.
  final now = DateTime(2026, 11, 3, 16, 30);

  void real(List<Notice> n, int plaka) {
    for (final x in n) {
      expect(x.kind, NoticeKind.water);
      expect(x.plaka, plaka);
      expect(reg.byPlaka(plaka)!.ilce(x.district), isNotNull, reason: '${x.district}');
    }
    expect(n.map((x) => x.id).toSet().length, n.length);
  }

  test('ASAT (Antalya): kayıt alanlarından ilçe, mahalleler ve saatler', () {
    final n = asatNotices(fx('asat.html'), reg: reg, now: now);
    final k = n.single;
    expect(k.source, 'ASAT');
    expect(k.district, 'Kemer');
    expect(k.neighborhoods, containsAll(['Arslanbucak', 'ÇAMYUVA', 'BELDİBİ']));
    expect(k.start, DateTime(2026, 11, 3, 8));
    expect(k.end, DateTime(2026, 12, 3, 17));
    real(n, 7);
  });

  test('OSKİ (Ordu): SASKİ ile aynı tablo, ilçe başına bir kayıt', () {
    final n = etkilenenYerlerNotices(fx('oski.html'),
        source: 'OSKİ', plaka: 52, url: 'u', reg: reg, now: now);
    expect(n, isNotEmpty);
    final unye = n.where((x) => x.district == 'Ünye').toList();
    expect(unye, isNotEmpty);
    expect(unye.expand((x) => x.neighborhoods), contains('BAYRAMCA MAH.'));
    expect(n.every((x) => x.source == 'OSKİ'), isTrue);
    real(n, 52);
  });

  test('MUSKİ (Muğla): devam eden kartlar, süre saatten bitişe çevrilir', () {
    final n = muskiNotices(fx('muski.html'), reg: reg, now: now);
    expect(n.length, greaterThanOrEqualTo(4));
    final y = n.firstWhere((x) => x.district == 'Yatağan');
    expect(y.start, DateTime(2026, 11, 3, 15, 46));
    expect(y.end, DateTime(2026, 11, 3, 18, 46));
    expect(y.neighborhoods, ['KONAK']);
    expect(y.planned, isFalse);
    real(n, 48);
  });

  test('ESKİ (Eskişehir): kesinti ve suyun verildiği an', () {
    final n = eskiEskisehirNotices(fx('eski_eskisehir.html'), reg: reg, now: now);
    final t = n.firstWhere((x) => x.detail.contains('Cumhuriyetçi'));
    expect(t.district, 'Tepebaşı');
    expect(t.neighborhoods, ['Işıklar']);
    expect(t.start, DateTime(2026, 11, 3, 15, 45));
    expect(t.end, DateTime(2026, 11, 3, 16, 5));
    // 12 saatten eski bitmiş kesintiler düşer
    final later = eskiEskisehirNotices(fx('eski_eskisehir.html'), reg: reg, now: DateTime(2026, 11, 5));
    expect(later.where((x) => x.detail.contains('Cumhuriyetçi')), isEmpty);
    real(n, 26);
  });

  test('tanınmayan sayfa hata verir (kaynak "okunamadı" görünür)', () {
    expect(() => asatNotices('<html/>', reg: reg, now: now), throwsFormatException);
    expect(() => muskiNotices('<html/>', reg: reg, now: now), throwsFormatException);
    expect(() => eskiEskisehirNotices('<html/>', reg: reg, now: now), throwsFormatException);
  });
}
