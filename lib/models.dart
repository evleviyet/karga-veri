enum NoticeKind { water, power, gas, weather, general }

/// Resmi kaynaktan gelen kesinti/duyuru kaydı. Saatler Türkiye yerel saatidir
/// (saat dilimi eki olmayan ISO metni).
class Notice {
  final NoticeKind kind;

  /// Görünen kaynak adı ("BEDAŞ", "Ankara Valiliği").
  final String source;
  final String title;
  final String detail;
  final String? district; // null = tüm il
  final DateTime? start;
  final DateTime? end;

  /// Kaynağın kendi kimliğinden türetilen kararlı anahtar (tekrar ayıklama).
  final String? id;

  /// Kaydın ait olduğu il. Tek ilde çalışan kaynaklarda boş bırakılabilir.
  final int? plaka;

  /// Etkilenen mahalleler (kaynak yazımıyla).
  final List<String> neighborhoods;

  /// Etkilenen alanın sınırları: [güney, batı, kuzey, doğu].
  final List<double>? area;

  /// MGM uyarı seviyesi: yellow | orange | red.
  final String? level;

  /// Resmi kaynak sayfası.
  final String? url;

  /// Planlı çalışma mı (true), arıza mı (false), bilinmiyor mu (null).
  final bool? planned;

  Notice({
    required this.kind,
    required this.source,
    required this.title,
    required this.detail,
    this.district,
    this.start,
    this.end,
    this.id,
    this.plaka,
    this.neighborhoods = const [],
    this.area,
    this.level,
    this.url,
    this.planned,
  });

  Notice copyWith({int? plaka, String? district, String? id}) => Notice(
        kind: kind,
        source: source,
        title: title,
        detail: detail,
        district: district ?? this.district,
        start: start,
        end: end,
        id: id ?? this.id,
        plaka: plaka ?? this.plaka,
        neighborhoods: neighborhoods,
        area: area,
        level: level,
        url: url,
        planned: planned,
      );

  /// Sürüm 1 dosyalarının alanları (eski uygulama sürümleri bunları okur).
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'source': source,
        'title': title,
        'detail': detail,
        'district': district,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
      };

  /// Sürüm 2: boş alanlar yazılmaz.
  Map<String, dynamic> toJsonV2() => {
        if (id != null) 'id': id,
        'kind': kind.name,
        'source': source,
        'title': title,
        'detail': detail,
        if (district != null) 'district': district,
        if (start != null) 'start': start!.toIso8601String(),
        if (end != null) 'end': end!.toIso8601String(),
        if (neighborhoods.isNotEmpty) 'neighborhoods': neighborhoods,
        if (area != null) 'area': area,
        if (level != null) 'level': level,
        if (url != null) 'url': url,
        if (planned != null) 'planned': planned,
      };

  factory Notice.fromJsonV2(Map<String, dynamic> j, {int? plaka}) => Notice(
        kind: NoticeKind.values.firstWhere((k) => k.name == j['kind'],
            orElse: () => NoticeKind.general),
        source: j['source'] as String? ?? '',
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        district: j['district'] as String?,
        start: DateTime.tryParse(j['start'] as String? ?? ''),
        end: DateTime.tryParse(j['end'] as String? ?? ''),
        id: j['id'] as String?,
        plaka: plaka,
        neighborhoods: [
          for (final n in (j['neighborhoods'] as List? ?? const [])) '$n'
        ],
        area: (j['area'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        level: j['level'] as String?,
        url: j['url'] as String?,
        planned: j['planned'] as bool?,
      );
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
    .replaceAll('&#8217;', "'")
    .replaceAll('&#8220;', '"')
    .replaceAll('&#8221;', '"')
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&')
    .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
    .replaceAllMapped(RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)))
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// "ÇAYTEPE MH." -> "Çaytepe Mh.": büyük harfli kaynak metnini okunur yapar.
String titleTr(String s) {
  final words = s.trim().split(RegExp(r'\s+'));
  return words.map((w) {
    if (w.isEmpty) return w;
    final lower = w
        .replaceAll('I', 'ı')
        .replaceAll('İ', 'i')
        .toLowerCase();
    final first = lower[0];
    final up = first == 'i'
        ? 'İ'
        : first == 'ı'
            ? 'I'
            : first.toUpperCase();
    return up + lower.substring(1);
  }).join(' ');
}

/// Mahalle adını karşılaştırma için sadeleştirir: "Çaytepe Mh." -> "caytepe".
String mahalleKey(String s) {
  var k = normTr(s)
      .replaceAll(RegExp(r'[.,()/-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  k = k.replaceAll(
      RegExp(r'\s(mahallesi|mahalle|mah|mh|koyu|koy|beldesi)$'), '');
  return k.replaceAll(' ', '');
}

/// Duyuru başlıklarının en fazla kaç günlükse dikkate alınacağı.
const announcementMaxAgeDays = 2;

/// Belediye duyurusunun "önemli" sayılması için başlıkta aranacak kelimeler.
const importantKeywords = [
  'acil', 'uyari', 'kesinti', 'firtina', 'sel', 'su baskini', 'kar yagisi',
  'buzlanma', 'deprem', 'afet', 'trafige kapa', 'yol kapa', 'tatil edil',
  'iptal edil',
];

// ---------------- Saat yardımcıları ----------------

/// Şu anki Türkiye saati (saat dilimi eki olmadan).
DateTime nowTr([DateTime? utc]) => toTrNaive((utc ?? DateTime.now()).toUtc());

/// UTC anı Türkiye yerel saatine (UTC+3, yaz saati yok) çevirir.
DateTime toTrNaive(DateTime t) {
  if (!t.isUtc) return t;
  final d = t.add(const Duration(hours: 3));
  return DateTime(d.year, d.month, d.day, d.hour, d.minute, d.second);
}

/// "2026-10-06T13:32:02.000+03:00", "2026-10-06T09:00:00", "2026-10-06 12:00:00.0"
DateTime? parseIsoTr(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final t = DateTime.tryParse(s.trim().replaceFirst(' ', 'T'));
  if (t == null) return null;
  return toTrNaive(t);
}

/// "06.10.2026 08:45", "6.10.2026 08:45:00", "06/10/2026 8:45"
DateTime? parseDmyHm(String s) {
  final m = RegExp(r'(\d{1,2})[./](\d{1,2})[./](\d{4})\D{1,12}?(\d{1,2})[:.](\d{2})')
      .firstMatch(s);
  if (m == null) return null;
  return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
      int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!));
}

/// "06.10.2026" (yalnızca gün)
DateTime? parseDmy(String s) {
  final m = RegExp(r'(\d{1,2})[./](\d{1,2})[./](\d{4})').firstMatch(s);
  if (m == null) return null;
  return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
      int.parse(m.group(1)!));
}

const trMonths = {
  'ocak': 1, 'subat': 2, 'mart': 3, 'nisan': 4, 'mayis': 5, 'haziran': 6,
  'temmuz': 7, 'agustos': 8, 'eylul': 9, 'ekim': 10, 'kasim': 11, 'aralik': 12,
  // kısaltmalar
  'oca': 1, 'sub': 2, 'mar': 3, 'nis': 4, 'may': 5, 'haz': 6, 'tem': 7,
  'agu': 8, 'eyl': 9, 'eki': 10, 'kas': 11, 'ara': 12,
};

/// Yılı yazılmamış tarihte yıl: [now]'a en yakın olanı seçer.
int inferYear(int month, int day, DateTime now) {
  var best = now.year;
  var bestDiff = 1 << 30;
  for (final y in [now.year - 1, now.year, now.year + 1]) {
    final diff = DateTime(y, month, day).difference(now).inDays.abs();
    if (diff < bestDiff) {
      bestDiff = diff;
      best = y;
    }
  }
  return best;
}

/// "06 Ekim 14:00" (yılsız) -> tarih.
DateTime? parseDayMonthHm(String s, DateTime now) {
  final m = RegExp(r'(\d{1,2})\s+([A-Za-zÇĞİÖŞÜçğıöşü]+)\s+(?:(\d{4})\s+)?(\d{1,2}):(\d{2})')
      .firstMatch(s);
  if (m == null) return null;
  final month = trMonths[normTr(m.group(2)!)];
  if (month == null) return null;
  final day = int.parse(m.group(1)!);
  final year = m.group(3) != null
      ? int.parse(m.group(3)!)
      : inferYear(month, day, now);
  return DateTime(year, month, day, int.parse(m.group(4)!),
      int.parse(m.group(5)!));
}

/// Kesinti penceresi ilgi alanında mı: yarım günden önce bitmiş ya da üç
/// günden sonra başlayacak kayıtlar yayımlanmaz.
bool inWindow(DateTime? start, DateTime? end, DateTime now,
    {int aheadDays = 3}) {
  final s = start ?? end;
  if (s == null) return true;
  final e = end ?? start!;
  if (e.isBefore(now.subtract(const Duration(hours: 12)))) return false;
  if (s.isAfter(now.add(Duration(days: aheadDays)))) return false;
  return true;
}

/// Mahalle listesini kısa bir satıra çevirir.
String neighborhoodsLine(Iterable<String> names, {int max = 8}) {
  final list = names.map(titleTr).toList();
  if (list.length <= max) return list.join(', ');
  return '${list.take(max).join(', ')} ve ${list.length - max} yer daha';
}

/// Kararlı kısa özet (FNV-1a, 32 bit) — kimliksiz kaynaklar için.
String stableId(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}
