import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'models.dart';

/// Yer adını eşleştirme anahtarına çevirir: "19 Mayıs" -> "19mayis".
String placeKey(String s) => normTr(s)
    .replaceAll(RegExp(r'\s+(ili|province|ilcesi|district)$'), '')
    .replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Geocoder ve kaynakların farklı yazdığı il adları.
const ilAliases = {
  'afyon': 'afyonkarahisar',
  'icel': 'mersin',
  'kmaras': 'kahramanmaras',
  'maras': 'kahramanmaras',
  'urfa': 'sanliurfa',
  'antep': 'gaziantep',
};

/// İlçe adının eski ya da kaynağa özgü yazımları (anahtar -> anahtar).
const ilceAliases = {
  'ondokuzmayis': '19mayis',
  'eyup': 'eyupsultan',
  'kazan': 'kahramankazan',
  'bursayenisehir': 'yenisehir',
  'tusbayuzuncuyiluniversitesi': 'tusba',
};

class Ilce {
  final String ad;

  /// Nüfus ve Vatandaşlık (UAVT) ilçe kodu.
  final int? kod;

  /// Bu ilçeyi kapsayan MGM merkez kimlikleri (uyarı eşleştirmesi).
  final List<int> mgm;
  final double? lat, lon;
  final int? nufus;

  Ilce(this.ad, {this.kod, this.mgm = const [], this.lat, this.lon, this.nufus});

  String get key => placeKey(ad);

  Map<String, dynamic> toJson() => {
        'ad': ad,
        if (kod != null) 'kod': kod,
        if (nufus != null) 'nufus': nufus,
        'mgm': mgm,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      };

  factory Ilce.fromJson(Map<String, dynamic> j) => Ilce(
        j['ad'] as String,
        kod: j['kod'] as int?,
        nufus: j['nufus'] as int?,
        mgm: [for (final m in (j['mgm'] as List? ?? const [])) m as int],
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
      );
}

class Il {
  final int plaka;
  final String ad;
  final bool buyuksehir;
  final double lat, lon;
  final int? mgm;
  final List<Ilce> ilceler;

  // Kurumlar (providers.json)
  String? elektrik;
  Map<String, String> elektrikIlce = {}; // ilçe anahtarı -> kurum
  String? su;
  String? belediyeUrl;

  Il(this.plaka, this.ad,
      {required this.buyuksehir,
      required this.lat,
      required this.lon,
      this.mgm,
      required this.ilceler});

  String get key => placeKey(ad);
  String get slug => key;
  String get valilikUrl => 'https://www.$slug.gov.tr';
  String get belediye => belediyeUrl ?? 'https://www.$slug.bel.tr';

  /// İlçe adını bu ildeki ilçeye çevirir; "Merkez" yazımlarını da tanır.
  Ilce? ilce(String? name) {
    if (name == null) return null;
    var k = placeKey(name);
    if (k.isEmpty) return null;
    k = ilceAliases[k] ?? k;
    for (final d in ilceler) {
      if (d.key == k) return d;
    }
    // "Merkez", "Bayburt Merkez", "Merkez Bayburt", "Bayburt"
    if (k == 'merkez' || k == '${key}merkez' || k == 'merkez$key' || k == key) {
      for (final d in ilceler) {
        if (d.key == 'merkez') return d;
      }
    }
    return null;
  }

  Map<String, dynamic> toGeoJson() => {
        'plaka': plaka,
        'ad': ad,
        'buyuksehir': buyuksehir,
        'lat': lat,
        'lon': lon,
        if (mgm != null) 'mgm': mgm,
        'ilceler': [for (final d in ilceler) d.toJson()],
      };

  factory Il.fromGeoJson(Map<String, dynamic> j) => Il(
        j['plaka'] as int,
        j['ad'] as String,
        buyuksehir: j['buyuksehir'] as bool? ?? false,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        mgm: j['mgm'] as int?,
        ilceler: [
          for (final d in (j['ilceler'] as List))
            Ilce.fromJson(d as Map<String, dynamic>)
        ],
      );
}

class Kurum {
  final String id;
  final String tur; // elektrik | su
  final String ad;
  final String kisa;
  final String? web;
  final String? kesinti;
  final String? tel;

  Kurum(this.id,
      {required this.tur,
      required this.ad,
      required this.kisa,
      this.web,
      this.kesinti,
      this.tel});

  factory Kurum.fromJson(String id, Map<String, dynamic> j) => Kurum(id,
      tur: j['tur'] as String,
      ad: j['ad'] as String,
      kisa: j['kisa'] as String,
      web: j['web'] as String?,
      kesinti: j['kesinti'] as String?,
      tel: j['tel'] as String?);

  Map<String, dynamic> toJson() => {
        'tur': tur,
        'ad': ad,
        'kisa': kisa,
        if (web != null) 'web': web,
        if (kesinti != null) 'kesinti': kesinti,
        if (tel != null) 'tel': tel,
      };
}

/// 81 il, 973 ilçe ve bu yerlere hizmet veren kurumlar.
class Registry {
  final List<Il> iller;
  final Map<String, Kurum> kurumlar;
  final Map<int, List<(Il, Ilce)>> _mgm = {};

  Registry(this.iller, this.kurumlar) {
    for (final il in iller) {
      for (final d in il.ilceler) {
        for (final id in d.mgm) {
          (_mgm[id] ??= []).add((il, d));
        }
      }
    }
  }

  static Registry load([String dir = 'registry']) => parse(
      File('$dir/geo.json').readAsStringSync(),
      File('$dir/providers.json').readAsStringSync());

  static Registry parse(String geoJson, String providersJson) {
    final geo = jsonDecode(geoJson) as Map<String, dynamic>;
    final prov = jsonDecode(providersJson) as Map<String, dynamic>;
    final iller = [
      for (final j in (geo['iller'] as List))
        Il.fromGeoJson(j as Map<String, dynamic>)
    ];
    final kurumlar = {
      for (final e in (prov['kurumlar'] as Map<String, dynamic>).entries)
        e.key: Kurum.fromJson(e.key, e.value as Map<String, dynamic>)
    };
    final byPlaka = {for (final il in iller) il.plaka: il};
    for (final e in (prov['iller'] as Map<String, dynamic>).entries) {
      final il = byPlaka[int.parse(e.key)];
      if (il == null) throw FormatException('providers: bilinmeyen il ${e.key}');
      final p = e.value as Map<String, dynamic>;
      il.elektrik = p['elektrik'] as String?;
      il.su = p['su'] as String?;
      il.belediyeUrl = p['belediye'] as String?;
      final over = p['elektrikIlce'] as Map<String, dynamic>?;
      if (over != null) {
        for (final o in over.entries) {
          for (final name in (o.value as List)) {
            final d = il.ilce('$name');
            if (d == null) {
              throw FormatException('providers: ${il.ad} ilçesi yok: $name');
            }
            il.elektrikIlce[d.key] = o.key;
          }
        }
      }
      for (final id in [il.elektrik, il.su, ...il.elektrikIlce.values]) {
        if (id != null && !kurumlar.containsKey(id)) {
          throw FormatException('providers: bilinmeyen kurum $id');
        }
      }
    }
    return Registry(iller, kurumlar);
  }

  Il? byPlaka(int? plaka) {
    for (final il in iller) {
      if (il.plaka == plaka) return il;
    }
    return null;
  }

  /// İl adından (geocoder, kaynak yazımı) ile.
  Il? byName(String? name) {
    if (name == null) return null;
    var k = placeKey(name);
    k = ilAliases[k] ?? k;
    for (final il in iller) {
      if (il.key == k) return il;
    }
    return null;
  }

  /// MGM merkez kimliğinden (il, ilçe) çiftleri.
  List<(Il, Ilce)> mgmTown(int id) => _mgm[id] ?? const [];

  /// Koordinata en yakın ilçe merkezi; [within] verilirse yalnızca o iller.
  (Il, Ilce)? nearest(double lat, double lon, {Iterable<int>? within}) {
    final only = within?.toSet();
    (Il, Ilce)? best;
    var bestD = double.infinity;
    for (final il in iller) {
      if (only != null && !only.contains(il.plaka)) continue;
      for (final d in il.ilceler) {
        if (d.lat == null || d.lon == null) continue;
        final dist = distanceKm(lat, lon, d.lat!, d.lon!);
        if (dist < bestD) {
          bestD = dist;
          best = (il, d);
        }
      }
    }
    return best;
  }

  /// İlçeye hizmet veren kurum (elektrik/su). Su için büyükşehir dışında null
  /// döner: orada su belediyenin işidir.
  Kurum? kurumFor(Il il, Ilce? ilce, String tur) {
    if (tur == 'elektrik') {
      final over = ilce == null ? null : il.elektrikIlce[ilce.key];
      return kurumlar[over ?? il.elektrik];
    }
    return il.su == null ? null : kurumlar[il.su];
  }

  /// Uygulamanın paketlediği ve sitede yayımlanan birleşik kayıt.
  Map<String, dynamic> toAppJson() => {
        'v': 1,
        'kurumlar': {
          for (final e in kurumlar.entries) e.key: e.value.toJson(),
        },
        'iller': [
          for (final il in iller)
            {
              'plaka': il.plaka,
              'ad': il.ad,
              'buyuksehir': il.buyuksehir,
              'lat': il.lat,
              'lon': il.lon,
              'elektrik': il.elektrik,
              if (il.elektrikIlce.isNotEmpty)
                'elektrikIlce': {
                  for (final d in il.ilceler)
                    if (il.elektrikIlce[d.key] != null)
                      d.ad: il.elektrikIlce[d.key],
                },
              if (il.su != null) 'su': il.su,
              'valilik': il.valilikUrl,
              'belediye': il.belediye,
              'ilceler': [
                for (final d in il.ilceler)
                  [d.ad, if (d.lat != null) d.lat, if (d.lon != null) d.lon],
              ],
            },
        ],
      };
}

/// İki nokta arası yaklaşık mesafe (km).
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}
