enum NoticeKind { water, power, general }

/// Resmi kaynaktan gelen kesinti/duyuru kaydı. Saatler Türkiye yerel saatidir
/// (saat dilimi eki olmayan ISO metni).
class Notice {
  final NoticeKind kind;
  final String source;
  final String title;
  final String detail;
  final String? district; // null = tüm şehir
  final DateTime? start;
  final DateTime? end;

  Notice({
    required this.kind,
    required this.source,
    required this.title,
    required this.detail,
    this.district,
    this.start,
    this.end,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'source': source,
        'title': title,
        'detail': detail,
        'district': district,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
      };
}

/// Türkçe karakterleri sadeleştirip küçük harfe çevirir.
String normTr(String s) {
  const map = {
    'İ': 'i', 'I': 'i', 'ı': 'i', 'Ş': 's', 'ş': 's', 'Ğ': 'g', 'ğ': 'g',
    'Ü': 'u', 'ü': 'u', 'Ö': 'o', 'ö': 'o', 'Ç': 'c', 'ç': 'c',
    'â': 'a', 'Â': 'a', 'î': 'i', 'û': 'u',
  };
  final sb = StringBuffer();
  for (final ch in s.split('')) {
    sb.write(map[ch] ?? ch.toLowerCase());
  }
  return sb.toString().replaceAll('̇', '').trim();
}

String cleanHtml(String s) => s
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&#39;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Duyuru başlıklarının en fazla kaç günlükse dikkate alınacağı.
const announcementMaxAgeDays = 2;

/// Belediye duyurusunun "önemli" sayılması için başlıkta aranacak kelimeler.
const importantKeywords = [
  'acil', 'uyari', 'kesinti', 'firtina', 'sel', 'su baskini', 'kar yagisi',
  'buzlanma', 'deprem', 'afet', 'trafige kapa', 'yol kapa', 'tatil edil',
  'iptal edil',
];
