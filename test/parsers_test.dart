import 'dart:io';

import 'package:karga_feed/models.dart';
import 'package:karga_feed/parsers/aski.dart';
import 'package:karga_feed/parsers/announcements.dart';
import 'package:test/test.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  test('ASKİ: kayıtlar ayrıştırılıyor, yapı bozulursa hata veriyor', () {
    final n = parseAski(fx('aski.html'));
    expect(n, isNotEmpty);
    expect(n.first.district, 'ELMADAĞ');
    expect(n.first.start, DateTime(2026, 9, 30, 8));
    expect(n.first.end, DateTime(2026, 9, 30, 15));
    expect(() => parseAski('<html>boş</html>'), throwsFormatException);
    expect(() => parseAski(fx('aski.html').replaceAll('<strong>', '<b>')),
        throwsFormatException);
  });

  test('Belediye ve Valilik sayfaları ayrıştırılıyor', () {
    expect(parseAbb(fx('abb.html')), isNotEmpty);
    final v = parseValilik(fx('valilik.html'));
    expect(v, isNotEmpty);
    expect(v.first.url, startsWith('https://www.ankara.gov.tr/'));
    expect(() => parseValilik('<html></html>'), throwsFormatException);
  });

  test('Okul tatili ve önemli duyuru filtreleri', () {
    final now = DateTime(2026, 1, 12, 9);
    final items = [
      Announcement(DateTime(2026, 1, 12), 'Kar Yağışı Nedeniyle Okulların Tatil Edildiğine İlişkin Duyuru', 'u1'),
      Announcement(DateTime(2026, 1, 12), 'KPSS Sınav Duyurusu', 'u2'),
      Announcement(DateTime(2025, 12, 1), 'Okullar Tatil Edildi', 'u3'),
    ];
    expect(valilikNotices(items, now).map((n) => n.detail), ['u1']);
    expect(abbNotices(items, now).map((n) => n.detail), ['u1']); // "tatil edil"
    expect(valilikNotices(items, now).single.kind, NoticeKind.general);
  });
}
