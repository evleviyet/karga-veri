// registry/geo.json'u yeniden üretir:
//   dart run tool/build_registry.dart
//
// Kaynaklar:
//  - İl/ilçe adları, NVİ (UAVT) ilçe kodları, nüfus, büyükşehir bilgisi:
//    TürkiyeAPI (https://api.turkiyeapi.dev, açık kaynak; NVİ/TÜİK verisi)
//  - İlçe merkez koordinatları ve MGM merkez kimlikleri (MeteoUyarı eşleşmesi):
//    servis.mgm.gov.tr/web/merkezler
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:karga_feed/registry.dart';

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';
const _mgmHeaders = {
  'User-Agent': _ua,
  'Origin': 'https://www.mgm.gov.tr',
  'Referer': 'https://www.mgm.gov.tr/',
};

/// MGM'de ilçe adıyla bulunmayan ilçeler: (plaka, ilçe) -> MGM'deki adı.
const _mgmNames = {
  (16, 'yenisehir'): 'Bursa/Yenişehir',
  (55, '19mayis'): 'Ondokuzmayıs',
  (65, 'tusba'): 'Tuşba Yüzüncü Yıl Üniversitesi',
};

/// MGM'de hiç merkezi olmayan yeni ilçeler: uyarılarını ayrıldıkları ilçeden alır.
const _mgmBorrow = {
  (30, 'derecik'): 'Şemdinli',
};

/// Büyükşehirlerde MGM'nin "Merkez" kaydı şehir merkezindeki ilçelerdir.
/// (Koordinata güvenilmez: Manisa "Merkez" boylamı hatalı yazılmış.)
const _mgmMerkez = {
  9: ['Efeler'],
  10: ['Altıeylül', 'Karesi'],
  44: ['Battalgazi', 'Yeşilyurt'],
  45: ['Şehzadeler', 'Yunusemre'],
  46: ['Onikişubat', 'Dulkadiroğlu'],
  47: ['Artuklu'],
};

Future<dynamic> _json(String url, [Map<String, String>? headers]) async {
  for (var attempt = 0;; attempt++) {
    try {
      final r = await http
          .get(Uri.parse(url), headers: headers ?? {'User-Agent': _ua})
          .timeout(const Duration(seconds: 40));
      if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode} $url');
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (e) {
      if (attempt >= 3) rethrow;
      await Future<void>.delayed(Duration(seconds: 2 + attempt * 3));
    }
  }
}

Future<void> main() async {
  final tapi = await _json(
      'https://api.turkiyeapi.dev/v1/provinces?fields=id,name,districts,coordinates,isMetropolitan');
  final provinces = (tapi['data'] as List).cast<Map<String, dynamic>>()
    ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
  if (provinces.length != 81) throw StateError('81 il bekleniyordu');

  final mgmIller = (await _json(
          'https://servis.mgm.gov.tr/web/merkezler/iller', _mgmHeaders) as List)
      .cast<Map<String, dynamic>>();

  final out = <Map<String, dynamic>>[];
  var ilceCount = 0;
  for (final p in provinces) {
    final plaka = p['id'] as int;
    final name = p['name'] as String;
    final mgmIl = mgmIller.firstWhere((m) => m['ilPlaka'] == plaka);
    final mgm = (await _json(
            'https://servis.mgm.gov.tr/web/merkezler/ililcesi?il=${Uri.encodeComponent(mgmIl['il'] as String)}',
            _mgmHeaders) as List)
        .cast<Map<String, dynamic>>();
    final byKey = {for (final m in mgm) placeKey(m['ilce'] as String): m};

    final ilceler = <Ilce>[];
    for (final d in (p['districts'] as List).cast<Map<String, dynamic>>()) {
      final dname = d['name'] as String;
      final k = placeKey(dname);
      var m = byKey[k];
      final alias = _mgmNames[(plaka, k)];
      if (m == null && alias != null) m = byKey[placeKey(alias)];
      final borrow = _mgmBorrow[(plaka, k)];
      final ids = <int>[
        if (m != null) m['merkezId'] as int,
        if (m == null && borrow != null)
          byKey[placeKey(borrow)]!['merkezId'] as int,
      ];
      if (m == null && borrow == null) {
        stderr.writeln('UYARI: MGM merkezi yok: $name/$dname');
      }
      ilceler.add(Ilce(dname,
          kod: d['id'] as int?,
          nufus: d['population'] as int?,
          mgm: ids,
          lat: (m?['enlem'] as num?)?.toDouble(),
          lon: (m?['boylam'] as num?)?.toDouble()));
    }
    ilceler.sort((a, b) => a.key.compareTo(b.key));

    // Büyükşehirlerde MGM'nin "Merkez" kaydı: merkez ilçelere bağlanır.
    final used = {for (final d in ilceler) ...d.mgm};
    for (final m in mgm) {
      final id = m['merkezId'] as int;
      if (used.contains(id) || placeKey(m['ilce'] as String) != 'merkez') continue;
      final targets = _mgmMerkez[plaka];
      if (targets == null) {
        throw StateError('$name: MGM "Merkez" kaydı için _mgmMerkez eşlemesi gerekli');
      }
      for (final t in targets) {
        final i = ilceler.indexWhere((d) => d.key == placeKey(t));
        final d = ilceler[i];
        ilceler[i] = Ilce(d.ad,
            kod: d.kod, nufus: d.nufus, mgm: [...d.mgm, id], lat: d.lat, lon: d.lon);
      }
    }

    final coords = p['coordinates'] as Map<String, dynamic>;
    out.add(Il(plaka, name,
            buyuksehir: p['isMetropolitan'] as bool? ?? false,
            lat: (coords['latitude'] as num).toDouble(),
            lon: (coords['longitude'] as num).toDouble(),
            mgm: mgmIl['merkezId'] as int?,
            ilceler: ilceler)
        .toGeoJson());
    ilceCount += ilceler.length;
    stdout.writeln('$plaka $name: ${ilceler.length} ilçe');
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  final file = File('registry/geo.json');
  file.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert({
        'kaynak': {
          'iller': 'TürkiyeAPI (NVİ/TÜİK verisi), api.turkiyeapi.dev',
          'koordinat': 'MGM merkezler servisi',
          'uretim': DateTime.now().toUtc().toIso8601String().substring(0, 10),
        },
        'iller': out,
      })}\n');
  stdout.writeln('81 il, $ilceCount ilçe -> ${file.path}');
}
