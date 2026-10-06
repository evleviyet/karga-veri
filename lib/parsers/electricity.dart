import '../models.dart';
import '../registry.dart';

// Elektrik dağıtım şirketlerinin kesinti verileri. Her ayrıştırıcı saf bir
// fonksiyondur (metin/JSON -> kayıtlar); ağ işleri lib/sources.dart'tadır.

const _plannedTitle = 'Planlı elektrik kesintisi';
const _faultTitle = 'Elektrik arızası';

/// Kaynağın yazdığı il/ilçe adını kayıt defterindeki ilçeye çevirir.
/// Ad tutmazsa (ör. büyükşehirde "MERKEZ") koordinata en yakın ilçe seçilir.
(Il, Ilce)? resolveDistrict(Registry reg, Iterable<int> plakas,
    {String? ilAdi, String? ilceAdi, double? lat, double? lon}) {
  final pool = [for (final p in plakas) reg.byPlaka(p)!];
  var ils = pool;
  if (ilAdi != null) {
    final il = reg.byName(ilAdi);
    if (il != null) ils = [il];
  }
  if (ilceAdi != null) {
    final hits = [
      for (final il in ils)
        if (il.ilce(ilceAdi) != null) (il, il.ilce(ilceAdi)!)
    ];
    if (hits.length == 1) return hits.single;
  }
  if (lat != null && lon != null) {
    return reg.nearest(lat, lon, within: ils.map((i) => i.plaka));
  }
  return null;
}

List<double>? _bbox(Iterable<(double, double)> pts) {
  double? s, w, n, e;
  for (final (lat, lon) in pts) {
    if (lat.isNaN || lon.isNaN || lat == 0 || lon == 0) continue;
    s = s == null || lat < s ? lat : s;
    n = n == null || lat > n ? lat : n;
    w = w == null || lon < w ? lon : w;
    e = e == null || lon > e ? lon : e;
  }
  if (s == null) return null;
  double r(double v) => (v * 1e5).roundToDouble() / 1e5;
  return [r(s), r(w!), r(n!), r(e!)];
}

DateTime? _endAfter(DateTime? start, DateTime? end) =>
    start != null && end != null && !end.isAfter(start) ? null : end;

// ---------------------------------------------------------------------------
// CK Enerji (BEDAŞ, AEDAŞ, ÇEDAŞ): kesintiapi.ckenerji.com.tr
// ---------------------------------------------------------------------------

/// Trafo -> (ilçe, mahalle) eşlemesi ("GetLocation" yanıtlarından).
typedef TmLocation = ({String ilce, String mahalle});

/// RetrieveOutages yanıtındaki trafo numaraları (konumu sorulacaklar).
Set<String> ckTransformers(Map<String, dynamic> outages,
    Map<String, dynamic>? transformers) {
  final tms = <String>{
    for (final o in (outages['Outage'] as List? ?? const []))
      if ('${(o as Map)['CBS_TM_NO'] ?? ''}'.isNotEmpty) '${o['CBS_TM_NO']}',
  };
  final list = ((transformers?['OutageTransformersList'] as Map?)?[
          'OutageTransformers'] as List?) ??
      const [];
  for (final t in list) {
    final tm = '${(t as Map)['TM_NO'] ?? ''}';
    if (tm.isNotEmpty) tms.add(tm);
  }
  return tms;
}

/// "GetLocation?tmno=" yanıtı.
TmLocation? ckLocation(Map<String, dynamic> j) {
  final results = j['results'] as List? ?? const [];
  String? ilce, mahalle;
  for (final r in results.whereType<Map>()) {
    ilce ??= r['ilce'] as String?;
    mahalle ??= r['mahalle'] as String?;
  }
  if (ilce == null) return null;
  return (ilce: ilce, mahalle: mahalle ?? '');
}

List<Notice> ckNotices({
  required String company,
  required String source,
  required String url,
  required List<int> plakas,
  required Map<String, dynamic> outages,
  Map<String, dynamic>? transformers,
  required Map<String, TmLocation> locations,
  required Registry reg,
}) {
  final rows = (outages['Outage'] as List?);
  if (rows == null) throw const FormatException('CK: "Outage" listesi yok');

  final byNo = <String, List<Map>>{};
  for (final o in rows.whereType<Map>()) {
    (byNo['${o['OUTAGE_NO']}'] ??= []).add(o);
  }
  final tmsByNo = <String, Set<String>>{};
  final ptsByNo = <String, List<(double, double)>>{};
  final tlist = ((transformers?['OutageTransformersList'] as Map?)?[
          'OutageTransformers'] as List?) ??
      const [];
  for (final t in tlist.whereType<Map>()) {
    final no = '${t['OUTAGE_NO']}';
    (tmsByNo[no] ??= {}).add('${t['TM_NO']}');
    final lat = double.tryParse('${t['LAT']}'), lon = double.tryParse('${t['LON']}');
    if (lat != null && lon != null) (ptsByNo[no] ??= []).add((lat, lon));
  }

  final out = <Notice>[];
  for (final e in byNo.entries) {
    final first = e.value.first;
    final planned = '${first['BILDIRIM_TURU']}' == 'Bildirimli';
    final start = parseIsoTr('${first['RPTD_DATE'] ?? ''}');
    final end = _endAfter(start, parseIsoTr('${first['EST_REPAIR_TIME'] ?? ''}'));
    final tms = {
      for (final o in e.value)
        if ('${o['CBS_TM_NO'] ?? ''}'.isNotEmpty) '${o['CBS_TM_NO']}',
      ...?tmsByNo[e.key],
    };
    final area = _bbox(ptsByNo[e.key] ?? const []);
    final cLat = area == null ? null : (area[0] + area[2]) / 2;
    final cLon = area == null ? null : (area[1] + area[3]) / 2;

    // İlçe -> mahalleler
    final groups = <String, Set<String>>{};
    for (final tm in tms) {
      final loc = locations[tm];
      if (loc == null) continue;
      (groups[loc.ilce] ??= {}).addAll([if (loc.mahalle.isNotEmpty) loc.mahalle]);
    }
    if (groups.isEmpty && cLat != null) groups[''] = {};

    for (final g in groups.entries) {
      final hit = resolveDistrict(reg, plakas,
          ilceAdi: g.key.isEmpty ? null : g.key, lat: cLat, lon: cLon);
      if (hit == null) continue;
      final (il, ilce) = hit;
      final mahalleler = g.value.toList()..sort();
      out.add(Notice(
        kind: NoticeKind.power,
        source: source,
        title: planned ? _plannedTitle : _faultTitle,
        detail: mahalleler.isEmpty
            ? '${ilce.ad} ilçesinde'
            : neighborhoodsLine(mahalleler),
        district: ilce.ad,
        plaka: il.plaka,
        start: start,
        end: end,
        neighborhoods: mahalleler,
        area: area,
        url: url,
        planned: planned,
        id: '$company:${e.key}:${ilce.key}',
      ));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Aksa grubu (Çoruh EDAŞ, Fırat EDAŞ): /BilgiDanisma/GetKesintiler satırları
// ---------------------------------------------------------------------------

List<String> _cells(String row) => [
      for (final c in RegExp(r'<t[dh][^>]*>([\s\S]*?)</t[dh]>').allMatches(row))
        cleanHtml(c.group(1)!)
    ];

List<List<String>> _rows(String html) => [
      for (final r in RegExp(r'<tr[^>]*>([\s\S]*?)</tr>').allMatches(html))
        _cells(r.group(1)!)
    ];

DateTime? _at(DateTime? day, String hm) {
  final m = RegExp(r'(\d{1,2})[:.](\d{2})').firstMatch(hm);
  if (day == null || m == null) return null;
  return DateTime(day.year, day.month, day.day, int.parse(m.group(1)!),
      int.parse(m.group(2)!));
}

/// Satır: İl | İlçe | Tarih | Başlama | Bitiş | Neden | Etkilenen Bölgeler | Ekleme
List<Notice> aksaNotices(String html,
    {required String company,
    required String source,
    required String url,
    required int plaka,
    required Registry reg,
    required DateTime now}) {
  if (html.contains('<html') || html.contains('<body')) {
    throw const FormatException('Aksa: satır yerine tam sayfa döndü');
  }
  final groups = <String, (List<String>, Set<String>)>{};
  for (final c in _rows(html)) {
    if (c.length < 7 || parseDmy(c[2]) == null) continue;
    // İlçe bazen "Yeşilyurt / Malatya" biçiminde yazılır.
    c[1] = c[1].split('/').first.trim();
    final key = '${c[1]}|${c[2]}|${c[3]}|${c[4]}|${c[5]}';
    (groups[key] ??= (c, <String>{})).$2.add(c[6]);
  }
  final il = reg.byPlaka(plaka)!;
  final out = <Notice>[];
  for (final g in groups.entries) {
    final c = g.value.$1;
    final day = parseDmy(c[2]);
    final start = _at(day, c[3]);
    var end = _at(day, c[4]);
    if (start != null && end != null && !end.isAfter(start)) {
      end = end.add(const Duration(days: 1));
    }
    if (!inWindow(start, end, now)) continue;
    final ilce = il.ilce(c[1]);
    final mahalleler = g.value.$2.where((m) => m.isNotEmpty).toList()..sort();
    out.add(Notice(
      kind: NoticeKind.power,
      source: source,
      title: _plannedTitle,
      detail: [
        if (mahalleler.isNotEmpty) neighborhoodsLine(mahalleler),
        if (c[5].isNotEmpty) '(${c[5]})',
      ].join(' '),
      district: ilce?.ad ?? titleTr(c[1]),
      plaka: plaka,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: url,
      planned: true,
      id: '$company:${stableId(g.key)}',
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// KCETAŞ (Kayseri): planlı kesintiler tablosu
// ---------------------------------------------------------------------------

/// Satır: İlçe | Etkilenen Yerler | Kesinti Tarihi | Saat Aralığı | Süre | Durum
List<Notice> kcetasNotices(String html,
    {required Registry reg, required DateTime now}) {
  final t = RegExp(r'<table[^>]*ic-pk__tablo[\s\S]*?</table>').firstMatch(html);
  if (t == null) throw const FormatException('KCETAŞ: kesinti tablosu yok');
  final il = reg.byPlaka(38)!;
  final groups = <String, (List<String>, Set<String>)>{};
  for (final c in _rows(t.group(0)!)) {
    if (c.length < 4 || parseDmy(c[2]) == null) continue;
    if (c.length > 5 && normTr(c[5]).contains('tamamlan')) continue;
    final key = '${c[0]}|${c[2]}|${c[3]}';
    // "KAYABAŞI MAH. KOCASİNAN KAYSERİ" -> "KAYABAŞI MAH."
    final place = c[1]
        .replaceAll(RegExp(r'\s+KAYSER[İI]\s*$', caseSensitive: false), '')
        .replaceAll(RegExp('\\s+${RegExp.escape(c[0])}\\s*\$'), '')
        .trim();
    (groups[key] ??= (c, <String>{})).$2.add(place);
  }
  final out = <Notice>[];
  for (final g in groups.entries) {
    final c = g.value.$1;
    final day = parseDmy(c[2]);
    final parts = c[3].split('-');
    final start = _at(day, parts.first);
    var end = parts.length > 1 ? _at(day, parts[1]) : null;
    if (start != null && end != null && !end.isAfter(start)) {
      end = end.add(const Duration(days: 1));
    }
    if (!inWindow(start, end, now)) continue;
    final mahalleler = g.value.$2.where((m) => m.isNotEmpty).toList()..sort();
    out.add(Notice(
      kind: NoticeKind.power,
      source: 'KCETAŞ',
      title: _plannedTitle,
      detail: neighborhoodsLine(mahalleler),
      district: il.ilce(c[0])?.ad ?? titleTr(c[0]),
      plaka: 38,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: 'https://www.kcetas.com.tr/tr/planli-kesintiler-bakimlar',
      planned: true,
      id: 'kcetas:${stableId(g.key)}',
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// YEDAŞ: /api/planli-kesinti-harita
// ---------------------------------------------------------------------------

Iterable<(double, double)> _geoPoints(dynamic coords) sync* {
  if (coords is List && coords.length >= 2 && coords[0] is num && coords[1] is num) {
    yield ((coords[1] as num).toDouble(), (coords[0] as num).toDouble());
  } else if (coords is List) {
    for (final c in coords) {
      yield* _geoPoints(c);
    }
  }
}

List<Notice> yedasNotices(Map<String, dynamic> j,
    {required Registry reg, required DateTime now}) {
  final data = (j['result'] as Map?)?['data'] as List?;
  if (data == null) throw const FormatException('YEDAŞ: result.data yok');
  final plakas = const [55, 5, 19, 52, 57];
  final out = <Notice>[];
  for (final item in data.whereType<Map>()) {
    final details = '${item['details'] ?? ''}';
    final windows = [
      for (final m in RegExp(
              r'Başlangıç Zamanı\s*(\d{1,2}\.\d{1,2}\.\d{4}\s+\d{1,2}:\d{2})[\s\S]*?Bitiş Zamanı\s*(\d{1,2}\.\d{1,2}\.\d{4}\s+\d{1,2}:\d{2})')
          .allMatches(details))
        (parseDmyHm(m.group(1)!), parseDmyHm(m.group(2)!))
    ];
    final geo = (item['geoJson'] as Map?)?['geometry'] as Map?;
    final area = _bbox([
      ..._geoPoints(geo?['coordinates']),
      for (final c in (item['coords'] as List? ?? const []).whereType<Map>())
        if (c['latitude'] is num && c['longitude'] is num)
          ((c['latitude'] as num).toDouble(), (c['longitude'] as num).toDouble()),
    ]);
    final groups = <(String, String), Set<String>>{};
    for (final a in (item['address'] as List? ?? const []).whereType<Map>()) {
      (groups[('${a['city_name']}', '${a['district_name']}')] ??= {})
          .add('${a['mah_name'] ?? ''}');
    }
    var w = 0;
    for (final (start, rawEnd) in windows) {
      final end = _endAfter(start, rawEnd);
      final wi = w++;
      if (!inWindow(start, end, now)) continue;
      for (final g in groups.entries) {
        final hit = resolveDistrict(reg, plakas,
            ilAdi: g.key.$1,
            ilceAdi: g.key.$2,
            lat: area == null ? null : (area[0] + area[2]) / 2,
            lon: area == null ? null : (area[1] + area[3]) / 2);
        if (hit == null) continue;
        final (il, ilce) = hit;
        final mahalleler = g.value.where((m) => m.isNotEmpty).toList()..sort();
        final reason = '${item['title'] ?? ''}'.trim();
        out.add(Notice(
          kind: NoticeKind.power,
          source: 'YEDAŞ',
          title: _plannedTitle,
          detail: [
            if (mahalleler.isNotEmpty) neighborhoodsLine(mahalleler),
            if (reason.isNotEmpty) '($reason)',
          ].join(' '),
          district: ilce.ad,
          plaka: il.plaka,
          start: start,
          end: end,
          neighborhoods: mahalleler,
          area: area,
          url: 'https://www.yedas.com/planli-kesinti',
          planned: true,
          id: 'yedas:${item['id']}:$wi:${ilce.key}',
        ));
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// MEDAŞ (Meram): cc.meramedas.com.tr/services/publicdata.ashx?m=mrm_gb1&il=
// ---------------------------------------------------------------------------

List<Notice> meramNotices(List<dynamic> rows,
    {required int plaka, required Registry reg, required DateTime now}) {
  final il = reg.byPlaka(plaka)!;
  final groups = <String, (Map, Set<String>)>{};
  for (final r in rows.whereType<Map>()) {
    final key = '${r['GroupId']}|${r['IlceAdi']}';
    (groups[key] ??= (r, <String>{})).$2.add('${r['MahalleKoyAdi'] ?? ''}');
  }
  final out = <Notice>[];
  for (final g in groups.entries) {
    final r = g.value.$1;
    final start = parseIsoTr('${r['PlanlananBaslangic'] ?? ''}');
    final end = _endAfter(start, parseIsoTr('${r['PlanlananBitis'] ?? ''}'));
    if (!inWindow(start, end, now)) continue;
    final ilce = il.ilce('${r['IlceAdi']}');
    final mahalleler = g.value.$2.where((m) => m.isNotEmpty).toList()..sort();
    final reason = '${r['IlanTipi'] ?? ''}'.trim();
    out.add(Notice(
      kind: NoticeKind.power,
      source: 'MEDAŞ',
      title: _plannedTitle,
      detail: [
        if (mahalleler.isNotEmpty) neighborhoodsLine(mahalleler),
        if (reason.isNotEmpty) '($reason)',
      ].join(' '),
      district: ilce?.ad ?? titleTr('${r['IlceAdi']}'),
      plaka: plaka,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: 'https://www.meramedas.com.tr/tr/planli-kesintiler.html',
      planned: true,
      id: 'meram:${stableId(g.key)}',
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// UEDAŞ: edrimsapi.uedas.com.tr/api/DoimGeneral/KesintiGetirByKesintiTur
// ---------------------------------------------------------------------------

List<Notice> uedasNotices(Map<String, dynamic> j,
    {required bool planned, required Registry reg, required DateTime now}) {
  if (j['SonucDurum'] != 1) {
    throw FormatException('UEDAŞ: ${j['SonucMesaj']}');
  }
  final rows = j['SonucIcerik'] as List? ?? const []; // boş: kesinti yok
  final plakas = const [16, 10, 17, 77];
  final out = <Notice>[];
  for (final r in rows.whereType<Map>()) {
    final start = parseIsoTr('${r['olusmaZamani'] ?? ''}');
    final end = _endAfter(start, parseIsoTr('${r['tahminiGiderilmeZamani'] ?? ''}'));
    if (!inWindow(start, end, now)) continue;
    final hit = resolveDistrict(reg, plakas,
        ilAdi: '${r['il']}',
        ilceAdi: '${r['ilce']}',
        lat: (r['enlem'] as num?)?.toDouble(),
        lon: (r['boylam'] as num?)?.toDouble());
    if (hit == null) continue;
    final (il, ilce) = hit;
    final mahalleler = '${r['etkilenenMahaller'] ?? ''}'
        .split(',')
        .map((m) => m.trim())
        .where((m) => m.isNotEmpty)
        .toList()
      ..sort();
    final reason = '${r['kesintiNedeni'] ?? r['kesintiTipi'] ?? ''}'.trim();
    out.add(Notice(
      kind: NoticeKind.power,
      source: 'UEDAŞ',
      title: planned ? _plannedTitle : _faultTitle,
      detail: [
        if (mahalleler.isNotEmpty) neighborhoodsLine(mahalleler),
        if (reason.isNotEmpty) '($reason)',
      ].join(' '),
      district: ilce.ad,
      plaka: il.plaka,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: 'https://online.uedas.com.tr/#/AktifElektrikKesintileri',
      planned: planned,
      id: 'uedas:${stableId('${r['il']}|${r['ilce']}|${r['olusmaZamani']}|${r['etkilenenMahaller']}')}',
    ));
  }
  return out;
}
