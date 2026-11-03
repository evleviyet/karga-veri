import 'dart:convert';
import 'dart:io';

import 'net.dart';

/// Son 24 saatin depremleri: uygulama bunları her telefondan AFAD'a gitmek
/// yerine tek dosyadan (data/v2/quakes.json) okuyabilir. Kayıtlar AFAD'ın
/// kendi biçimindedir; böylece uygulama aynı ayrıştırıcıyı kullanır.
///
/// AFAD okunamazsa (ör. yurt dışı IP'si engellenirse) EMSC'nin Türkiye ve
/// çevresi listesi aynı biçime çevrilir.
const quakeLookback = Duration(hours: 24);

/// En hassas ayarın en küçük büyüklüğü (uygulama: quakeTierLevels[0]).
const quakeMinMag = 3.0;

const afadFilterUrl =
    'https://servisnet.afad.gov.tr/apigateway/deprem/apiv2/event/filter';
const emscUrl = 'https://www.seismicportal.eu/fdsnws/event/1/query';

String _utc(DateTime d) => d.toUtc().toIso8601String().split('.').first;

/// AFAD kaydından uygulamanın kullandığı alanlar.
Map<String, dynamic> _afadSlim(Map<String, dynamic> e) => {
      'eventID': '${e['eventID']}',
      'magnitude': '${e['magnitude']}',
      'location': '${e['location']}',
      'latitude': '${e['latitude']}',
      'longitude': '${e['longitude']}',
      'depth': '${e['depth']}',
      'date': '${e['date']}',
    };

List<Map<String, dynamic>> parseAfad(dynamic json) {
  if (json is! List) throw const FormatException('AFAD: liste gelmedi');
  return [
    for (final e in json)
      if (e is Map<String, dynamic> && e['eventID'] != null) _afadSlim(e),
  ];
}

/// EMSC (FDSN GeoJSON) -> AFAD biçimi. Yer adı Türkçe olmadığından bölge adı
/// kullanılır; kimlik "E" önekiyle AFAD kimliklerinden ayrılır.
List<Map<String, dynamic>> parseEmsc(dynamic json) {
  final features = json is Map ? json['features'] : null;
  if (features is! List) throw const FormatException('EMSC: liste gelmedi');
  final out = <Map<String, dynamic>>[];
  for (final f in features) {
    final p = f is Map ? f['properties'] : null;
    if (p is! Map) continue;
    final t = DateTime.tryParse('${p['time']}');
    if (t == null || p['mag'] == null) continue;
    out.add({
      'eventID': 'E${p['unid'] ?? f['id']}',
      'magnitude': '${p['mag']}',
      'location': _title('${p['flynn_region'] ?? ''}'),
      'latitude': '${p['lat']}',
      'longitude': '${p['lon']}',
      'depth': '${p['depth']}',
      'date': _utc(t),
    });
  }
  return out;
}

String _title(String s) => s.toLowerCase().replaceAllMapped(
    RegExp(r'(^|[\s(\-])([a-z])'), (m) => '${m[1]}${m[2]!.toUpperCase()}');

/// Deprem dosyası: önce AFAD, okunamazsa EMSC. İkisi de okunamazsa hata
/// bilgisiyle boş liste (uygulama "kaynak okunamadı" sayıp AFAD'a kendisi gider).
Future<Map<String, dynamic>> buildQuakes(Net net, DateTime nowUtc) async {
  final start = _utc(nowUtc.subtract(quakeLookback));
  final end = _utc(nowUtc.add(const Duration(hours: 1)));
  final errors = <String>[];
  for (final (name, read) in [
    (
      'AFAD',
      () async => parseAfad(await net.getJson(
          '$afadFilterUrl?start=$start&end=$end&minmag=$quakeMinMag'
          '&orderby=timedesc&limit=300'))
    ),
    (
      'EMSC',
      () async => parseEmsc(await net.getJson(
          '$emscUrl?format=json&minlat=34&maxlat=43&minlon=24&maxlon=46'
          '&minmag=$quakeMinMag&start=$start&orderby=time&limit=300'))
    ),
  ]) {
    try {
      final events = await read();
      return {
        'schema': 1,
        'generatedAt': nowUtc.toIso8601String(),
        'source': name,
        'events': events,
        if (errors.isNotEmpty) 'errors': errors,
      };
    } catch (e) {
      errors.add('$name: $e');
    }
  }
  return {
    'schema': 1,
    'generatedAt': nowUtc.toIso8601String(),
    'source': null,
    'events': const [],
    'errors': errors,
  };
}

void writeQuakes(Directory out, Map<String, dynamic> q) {
  File('${out.path}/data/v2/quakes.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(q));
}
