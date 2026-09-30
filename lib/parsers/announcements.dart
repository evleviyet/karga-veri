import '../models.dart';

class Announcement {
  final DateTime date;
  final String title;
  final String url;
  Announcement(this.date, this.title, this.url);
}

const _trMonths = {
  'ocak': 1, 'subat': 2, 'mart': 3, 'nisan': 4, 'mayis': 5, 'haziran': 6,
  'temmuz': 7, 'agustos': 8, 'eylul': 9, 'ekim': 10, 'kasim': 11, 'aralik': 12,
  // Valilik kısaltmaları
  'oca': 1, 'sub': 2, 'mar': 3, 'nis': 4, 'haz': 6, 'tem': 7, 'agu': 8,
  'eyl': 9, 'eki': 10, 'kas': 11, 'ara': 12,
};

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
    final month = _trMonths[normTr(dm.group(2)!)];
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

/// Ankara Valiliği duyurular sayfası.
List<Announcement> parseValilik(String html) {
  final out = <Announcement>[];
  final r = RegExp(
    r'class="day">(\d{1,2})</div>\s*<div class="month">(\S+)\s+(\d{4})</div>'
    r'[\s\S]*?class="announce-text" href="([^"]+)">([\s\S]*?)<i class',
  );
  for (final m in r.allMatches(html)) {
    final month = _trMonths[normTr(m.group(2)!)];
    if (month == null) continue;
    var url = m.group(4)!;
    if (url.startsWith('//')) url = 'https:$url';
    out.add(Announcement(
      DateTime(int.parse(m.group(3)!), month, int.parse(m.group(1)!)),
      cleanHtml(m.group(5)!),
      url,
    ));
  }
  if (out.isEmpty) throw const FormatException('Valilik: hiç duyuru ayrıştırılamadı');
  return out;
}

bool _fresh(Announcement a, DateTime now) =>
    now.difference(a.date).inDays <= announcementMaxAgeDays;

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
          ),
    ];

/// Valilik: okul/eğitim tatili kararları.
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
