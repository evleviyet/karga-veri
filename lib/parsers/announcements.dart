import '../models.dart';

class Announcement {
  final DateTime date;
  final String title;
  final String url;
  Announcement(this.date, this.title, this.url);
}

/// Ankara Büyükşehir Belediyesi duyurular sayfası. Hiç duyuru okunamazsa
/// yapı değişmiş demektir ve [FormatException] atılır.
List<Announcement> parseAbb(String html) {
  final out = <Announcement>[];
  final seen = <String>{};
  final links =
      RegExp(r'<a[^>]+href="(/duyurular/[^"]+)"[^>]*>(.*?)</a>', dotAll: true);
  for (final m in links.allMatches(html)) {
    final href = m.group(1)!;
    if (!seen.add(href)) continue;
    final text = cleanHtml(m.group(2)!);
    final dm = RegExp(r'^(\d{1,2})\s+(\S+)\s+(\d{4})\s+(.*)$').firstMatch(text);
    if (dm == null) continue;
    final month = trMonths[normTr(dm.group(2)!)];
    if (month == null) continue;
    out.add(Announcement(
      DateTime(int.parse(dm.group(3)!), month, int.parse(dm.group(1)!)),
      dm.group(4)!.trim(),
      'https://www.ankara.bel.tr$href',
    ));
  }
  if (out.isEmpty) throw const FormatException('ABB: hiç duyuru ayrıştırılamadı');
  return out;
}

/// Valilik duyurular sayfası (81 valilik aynı altyapıyı kullanır). Bazı
/// valilikler bu yılın duyurularında yılı yazmaz; yıl [now]'a göre bulunur.
List<Announcement> parseValilik(String html, {DateTime? now}) {
  final out = <Announcement>[];
  final r = RegExp(
    r'class="day">\s*(\d{1,2})\s*</div>\s*<div class="month">\s*([^\s<]+)(?:\s+(\d{4}))?\s*</div>'
    r'[\s\S]*?class="announce-text" href="([^"]+)">([\s\S]*?)<i class',
  );
  final ref = now ?? DateTime.now();
  for (final m in r.allMatches(html)) {
    final month = trMonths[normTr(m.group(2)!)];
    if (month == null) continue;
    final day = int.parse(m.group(1)!);
    final year =
        m.group(3) != null ? int.parse(m.group(3)!) : inferYear(month, day, ref);
    var url = m.group(4)!;
    if (url.startsWith('//')) url = 'https:$url';
    out.add(Announcement(DateTime(year, month, day), cleanHtml(m.group(5)!), url));
  }
  if (out.isEmpty) throw const FormatException('Valilik: hiç duyuru ayrıştırılamadı');
  return out;
}

bool _fresh(Announcement a, DateTime now) =>
    now.difference(a.date).inDays <= announcementMaxAgeDays &&
    !a.date.isAfter(now.add(const Duration(days: 1)));

/// Belediye: yeni ve anahtar kelime içeren duyurular.
List<Notice> abbNotices(List<Announcement> items, DateTime now) => [
      for (final a in items)
        if (_fresh(a, now) &&
            importantKeywords.any(normTr(a.title).contains))
          Notice(
            kind: NoticeKind.general,
            source: 'Ankara Büyükşehir Belediyesi',
            title: a.title,
            detail: a.url,
            start: a.date,
            url: a.url,
            id: 'abb:${stableId(a.url)}',
          ),
    ];

/// Valilik (sürüm 1, yalnızca Ankara): okul/eğitim tatili kararları.
List<Notice> valilikNotices(List<Announcement> items, DateTime now) => [
      for (final a in items)
        if (_fresh(a, now) && _isSchoolBreak(normTr(a.title)))
          Notice(
            kind: NoticeKind.general,
            source: 'Ankara Valiliği',
            title: a.title,
            detail: a.url,
            start: a.date,
          ),
    ];

bool _isSchoolBreak(String t) =>
    t.contains('tatil') &&
    (t.contains('okul') || t.contains('egitim') || t.contains('ogretim'));

/// "Kara haber" sayılan valilik duyuruları: tatil, afet, hava uyarısı,
/// kesinti, yol kapanması, yasak, karantina... İhale, sınav, personel ilanı gibi
/// rutin duyurular elenir.
bool isKaraHaber(String title) {
  final t = normTr(title);
  const noise = [
    'ihale', 'sinav', 'personel', 'alim ilani', 'alimi', 'ced ', 'cevresel etki',
    'bilirkisi', 'kiralama', 'satis ilani', 'satis duyurusu', 'tebligat',
    'yarisma', 'burs', 'gorevde yukselme', 'kura ', 'muracaat', 'tahsis',
    'kalkinma ajansi', 'nufus mudurlugu', 'proje teklif', 'hibe', 'egitim programi',
  ];
  if (noise.any(t.contains)) return false;
  if (_isSchoolBreak(t) || t.contains('egitime ara') || t.contains('ogretime ara')) {
    return true;
  }
  const strong = [
    'meteorolojik uyari', 'kuvvetli yagis', 'kuvvetli ruzgar', 'firtina',
    'sel ', 'sel,', 'selin', 'su baskini', 'kar yagisi', 'yogun kar', 'buzlanma',
    'zirai don', 'cig tehlike', 'cig riski', 'cig dusme', 'cig uyari', 'heyelan',
    'sicak hava dalgasi', 'asiri sicak', 'toz tasinimi', 'dolu yagis', 'deprem', 'afet', 'acil durum', 'tahliye',
    'orman yangin', 'yangin riski', 'yangin tehlike', 'yangin uyari', 'yangin nedeniyle',
    'ormanlik alan', 'ormana giris', 'ormanlara giris', 'yol kapa', 'trafige kapa',
    'ulasima kapa', 'trafik kisitlama', 'gecis yasag', 'yasak', 'su kesinti',
    'elektrik kesinti', 'dogalgaz kesinti', 'dogal gaz kesinti', 'kesinti',
    'karantina', 'kuduz', 'salgin', 'zehirlen', 'siren', 'uyari',
  ];
  return strong.any(t.contains) || t.endsWith(' sel');
}

/// Valilik (sürüm 2, 81 il): yeni ve "kara haber" niteliğindeki duyurular.
List<Notice> valilikKaraHaber(
        List<Announcement> items, DateTime now, String ilAd, int plaka) =>
    [
      for (final a in items)
        if (_fresh(a, now) && isKaraHaber(a.title))
          Notice(
            kind: NoticeKind.general,
            source: '$ilAd Valiliği',
            title: a.title,
            detail: '',
            start: a.date,
            url: a.url,
            plaka: plaka,
            id: 'valilik$plaka:${stableId(a.url)}',
          ),
    ];
