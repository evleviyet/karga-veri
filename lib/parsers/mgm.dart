import '../models.dart';
import '../registry.dart';

/// MeteoUyarı tehlike türleri (mgm.gov.tr/meteouyari simge açıklamaları).
const mgmHazards = {
  'thunderstorm': 'Gök gürültülü sağanak',
  'rain': 'Yağmur',
  'snow': 'Kar',
  'wind': 'Rüzgâr',
  'fog': 'Sis',
  'ice': 'Buzlanma ve don',
  'cold': 'Soğuk',
  'hot': 'Sıcak',
  'dust': 'Toz taşınımı',
  'snowmelt': 'Kar erimesi',
  'avalanche': 'Çığ',
  'agricultural': 'Zirai don',
};

const mgmLevels = {'red': 'Kırmızı', 'orange': 'Turuncu', 'yellow': 'Sarı'};

/// MGM MeteoUyarı kayıtlarını ilçe başına hava uyarısına çevirir.
/// [gun]: 1 bugün, 2 yarın (kaynak sayfası bağlantısı için).
/// Aynı uyarıda bir ilçe birden çok seviyede geçerse en yükseği kalır.
List<Notice> mgmNotices(List<dynamic> alerts, Registry reg, {int gun = 1}) {
  final out = <String, Notice>{};
  for (final a in alerts.whereType<Map<String, dynamic>>()) {
    final no = a['alertNo'] ?? a['_id'];
    final begin = parseIsoTr(a['begin'] as String?);
    final end = parseIsoTr(a['end'] as String?);
    final towns = a['towns'] as Map? ?? const {};
    final weather = a['weather'] as Map? ?? const {};
    final text = a['text'] as Map? ?? const {};
    for (final level in mgmLevels.keys) {
      final ids = towns[level] as List? ?? const [];
      if (ids.isEmpty) continue;
      final hazards = [
        for (final w in (weather[level] as List? ?? const []))
          mgmHazards['$w'] ?? '$w'
      ];
      final title = '${mgmLevels[level]} uyarı: '
          '${hazards.isEmpty ? 'meteorolojik uyarı' : hazards.join(', ')}';
      for (final id in ids) {
        if (id is! num) continue;
        for (final (il, ilce) in reg.mgmTown(id.toInt())) {
          final key = 'mgm:$no:${il.plaka}:${ilce.key}';
          if (out.containsKey(key)) continue;
          out[key] = Notice(
            kind: NoticeKind.weather,
            source: 'MGM',
            title: title,
            detail: '${text[level] ?? ''}'.trim(),
            district: ilce.ad,
            plaka: il.plaka,
            start: begin,
            end: end,
            level: level,
            url: 'https://www.mgm.gov.tr/meteouyari/Il.aspx?id=${il.mgm}&Gun=$gun',
            id: key,
          );
        }
      }
    }
  }
  return out.values.toList();
}
