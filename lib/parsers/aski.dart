import '../models.dart';

/// ASKİ (Ankara) su kesintisi sayfası.
/// Sayfada geçen "Arıza Tarihi" sayısı ile ayrıştırılan kayıt sayısı tutmazsa
/// sayfa yapısı değişmiş demektir ve [FormatException] atılır.
List<Notice> parseAski(String html) {
  if (!html.contains('class="history"')) {
    throw const FormatException('ASKİ: liste kapsayıcısı bulunamadı');
  }
  final out = <Notice>[];
  for (final b in html.split('class="box-content"').skip(1)) {
    final district = _first(RegExp(r'<strong>(.*?)</strong>', dotAll: true), b);
    final start = _first(RegExp(r'Arıza Tarihi:\s*</b>\s*([\d.]+\s+[\d:]+)'), b);
    final end = _first(RegExp(r'Tamir Tarihi:\s*</b>\s*([\d.]+\s+[\d:]+)'), b);
    final detail = _first(RegExp(r'Detay:\s*</b>(.*?)<br', dotAll: true), b) ?? '';
    final places =
        _first(RegExp(r'Etkilenen Yerler:\s*</b>(.*?)</p>', dotAll: true), b) ?? '';
    if (district == null || start == null) continue;
    final text = cleanHtml(places.isNotEmpty ? places : detail);
    out.add(Notice(
      kind: NoticeKind.water,
      source: 'ASKİ',
      title: 'Su kesintisi',
      detail: text,
      district: cleanHtml(district),
      start: _date(start),
      end: end == null ? null : _date(end),
      plaka: 6,
      url: 'https://www.aski.gov.tr/tr/Kesinti.aspx',
      id: 'aski:${stableId('${cleanHtml(district)}|$start|$text')}',
    ));
  }
  // Etiket sayısı (detay metninde geçen "Arıza Tarihi" yazıları sayılmaz).
  final expected = RegExp(r'<b>\s*Arıza Tarihi:\s*</b>').allMatches(html).length;
  if (out.length != expected) {
    throw FormatException(
        'ASKİ: sayfada $expected kayıt var, ${out.length} tanesi ayrıştırıldı');
  }
  return out;
}

String? _first(RegExp r, String s) => r.firstMatch(s)?.group(1);

/// "30.09.2026 08:00:00"
DateTime? _date(String s) {
  final m = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{4})\s+(\d{1,2}):(\d{2})').firstMatch(s);
  if (m == null) return null;
  return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
      int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!));
}
