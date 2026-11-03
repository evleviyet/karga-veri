import 'dart:convert';
import 'dart:io';

import 'net.dart';
import 'registry.dart';
import 'sources.dart' show JsonCache;

/// Uydunun gördüğü büyük yangınlar (kanari.io, CC BY 4.0): data/v2/fires.json.
///
/// Uydu her ısı noktasını görür: tarla yakma, baca, rafineri alevi. Bu yüzden
/// yalnızca güçlü ve doğrulanmış kümeler yayımlanır:
///  - Türkiye'de (en yakın ilçe merkezi [maxIlceKm] içinde),
///  - güven "possible" değil, en az [minCount] tespit ve [minFrp] MW ışınım,
///  - son [maxAge] içinde görülmüş,
///  - aynı hücrede son 30 günde [industrialDays] ayrı gün görülmemiş
///    (sürekli yanan sanayi noktası değil; çok günlük bir orman yangını da
///    ilk iki gününden sonra tekrar bildirilmez).
/// Uygulama bunları resmi duyuru gibi değil "uydu tespiti" diye gösterir.
const firesUrl = 'https://kanari.io/api/events?hours=24&full=1';

/// İlk çalışmada (gün geçmişi boşken) sanayi noktalarını tanımak için 3 gün.
const firesSeedUrl = 'https://kanari.io/api/events?hours=72&full=1';
const maxIlceKm = 30.0;
const minCount = 5;
const minFrp = 50.0;
const maxAge = Duration(hours: 12);
const industrialDays = 3;

/// ~5 km'lik hücre: aynı tesisin noktaları aynı hücreye düşer.
String fireCell(double lat, double lon) =>
    '${(lat * 20).floor()}_${(lon * 20).floor()}';

Map<String, dynamic> firesFile(dynamic json, Registry reg, DateTime nowUtc,
    {Map<String, dynamic>? seenDays}) {
  final events = json is Map ? json['events'] : null;
  if (events is! List) throw const FormatException('kanari: liste gelmedi');
  final today = nowUtc.toIso8601String().substring(0, 10);
  final cutoff = nowUtc.subtract(const Duration(days: 30)).toIso8601String().substring(0, 10);
  final out = <Map<String, dynamic>>[];
  for (final e in events) {
    if (e is! Map) continue;
    final c = e['centroid'];
    if (c is! List || c.length < 2) continue;
    final lon = (c[0] as num).toDouble(), lat = (c[1] as num).toDouble();
    if (lat < 35.5 || lat > 42.5 || lon < 25.5 || lon > 45.0) continue;
    final near = reg.nearest(lat, lon);
    if (near == null) continue;
    final (il, ilce) = near;
    if (ilce.lat == null || distanceKm(lat, lon, ilce.lat!, ilce.lon!) > maxIlceKm) continue;

    // Hücrenin görüldüğü günler (her güvende): sürekli sıcak nokta ayıklaması.
    final cell = fireCell(lat, lon);
    final days = <String>{
      for (final d in (seenDays?[cell] as List? ?? const [])) '$d',
      for (final t in [e['firstSeen'], e['lastSeen']])
        if (t is String && t.length >= 10) t.substring(0, 10),
    }..removeWhere((d) => d.compareTo(cutoff) < 0);
    if (days.isEmpty) days.add(today);
    seenDays?[cell] = days.toList()..sort();

    final last = DateTime.tryParse('${e['lastSeen']}');
    final count = (e['count'] as num?)?.toInt() ?? 0;
    final frp = (e['maxFrp'] as num?)?.toDouble() ?? 0;
    if (e['confidence'] == 'possible' || count < minCount || frp < minFrp) continue;
    if (last == null || nowUtc.difference(last) > maxAge) continue;
    if (days.length >= industrialDays) continue;
    out.add({
      'id': '${e['id']}',
      'lat': lat,
      'lon': lon,
      'il': il.ad,
      'ilce': ilce.ad,
      'count': count,
      'frp': frp,
      'confidence': e['confidence'],
      'firstSeen': e['firstSeen'],
      'lastSeen': e['lastSeen'],
    });
  }
  return {
    'schema': 1,
    'generatedAt': nowUtc.toIso8601String(),
    'source': 'kanari.io',
    'license': 'CC BY 4.0',
    'events': out,
  };
}

/// Okur, süzer ve yazar. Okunamazsa dosya yazılmaz (uygulama yangın yok sayar).
Future<void> buildFires(Net net, Registry reg, Directory out, Directory cacheDir) async {
  final cache = JsonCache(cacheDir, 'fire-cells');
  try {
    final url = cache.data.isEmpty ? firesSeedUrl : firesUrl;
    final f = firesFile(await net.getJson(url), reg, DateTime.now().toUtc(),
        seenDays: cache.data);
    cache.save();
    File('${out.path}/data/v2/fires.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(f));
  } catch (e) {
    stderr.writeln('Yangınlar okunamadı: $e');
  } finally {
    net.close();
  }
}
