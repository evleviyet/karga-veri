import '../models.dart';
import '../registry.dart';

// Büyükşehir su idarelerinin kesinti sayfaları (saf ayrıştırıcılar).

List<String> _cells(String row) => [
      for (final c in RegExp(r'<t[dh][^>]*>([\s\S]*?)</t[dh]>').allMatches(row))
        cleanHtml(c.group(1)!)
    ];

List<List<String>> _rows(String html) => [
      for (final r in RegExp(r'<tr[^>]*>([\s\S]*?)</tr>').allMatches(html))
        _cells(r.group(1)!)
    ];

List<String> _split(String s, Pattern by) =>
    s.split(by).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

/// "06.10.2026 saat 10:15 ile 16:15 arasında ..." -> (başlangıç, bitiş)
(DateTime?, DateTime?) _saatAraligi(String s) {
  final m = RegExp(
          r'(\d{1,2}\.\d{1,2}\.\d{4})\s*(?:saat)?\s*(\d{1,2}[:.]\d{2})\s*(?:ile|-)\s*(?:(\d{1,2}\.\d{1,2}\.\d{4})\s*(?:saat)?\s*)?(\d{1,2}[:.]\d{2})')
      .firstMatch(s);
  if (m == null) return (parseDmyHm(s), null);
  final start = parseDmyHm('${m.group(1)} ${m.group(2)!.replaceAll('.', ':')}');
  var end = parseDmyHm('${m.group(3) ?? m.group(1)} ${m.group(4)!.replaceAll('.', ':')}');
  if (start != null && end != null && !end.isAfter(start)) {
    end = end.add(const Duration(days: 1));
  }
  return (start, end);
}

/// İZSU ve DESKİ'nin kullandığı tablo:
/// İlçe | Mahalleler | Kesinti Süresi | Arıza Tipi | Açıklama
List<Notice> arizaTableNotices(String html,
    {required String source,
    required String url,
    required int plaka,
    required Registry reg,
    required DateTime now}) {
  final il = reg.byPlaka(plaka)!;
  final out = <Notice>[];
  var tables = 0;
  for (final t in RegExp(r'<table[\s\S]*?</table>').allMatches(html)) {
    final rows = _rows(t.group(0)!);
    if (rows.isEmpty) continue;
    final head = rows.first.map(normTr).toList();
    final iIlce = head.indexWhere((h) => h == 'ilce');
    final iMah = head.indexWhere((h) => h.startsWith('mahalle'));
    final iSure = head.indexWhere((h) => h.contains('kesinti'));
    if (iIlce < 0 || iMah < 0 || iSure < 0) continue;
    tables++;
    final iTip = head.indexWhere((h) => h.contains('tip'));
    final iAck = head.indexWhere((h) => h.contains('aciklama'));
    for (final c in rows.skip(1)) {
      if (c.length <= iSure) continue;
      final (start, end) = _saatAraligi(c[iSure]);
      if (start == null || !inWindow(start, end, now)) continue;
      final mahalleler = _split(c[iMah], ',');
      final tip = iTip >= 0 && iTip < c.length ? c[iTip] : '';
      final ack = iAck >= 0 && iAck < c.length ? c[iAck] : '';
      out.add(Notice(
        kind: NoticeKind.water,
        source: source,
        title: 'Su kesintisi',
        detail: [
          neighborhoodsLine(mahalleler),
          if (tip.isNotEmpty) '($tip)',
          if (ack.isNotEmpty && ack.length < 120) '— $ack',
        ].join(' '),
        district: il.ilce(c[iIlce])?.ad ?? titleTr(c[iIlce]),
        plaka: plaka,
        start: start,
        end: end,
        neighborhoods: mahalleler,
        url: url,
        id: '${normTr(source)}:${stableId(c.join('|'))}',
      ));
    }
  }
  if (tables == 0) {
    throw FormatException('$source: kesinti tablosu bulunamadı');
  }
  return out;
}

/// Samsun SASKİ: Başlangıç | Bitiş | Nedeni | Etkilenen Yerler
/// ("06 Ekim 14:00", yer: "ATAKUM / ÇAKIRLAR MAH. / ,ATAKUM / ...")
List<Notice> saskiNotices(String html,
        {required Registry reg, required DateTime now}) =>
    etkilenenYerlerNotices(html,
        source: 'SASKİ',
        plaka: 55,
        url: 'https://www.saski.gov.tr/sukesintileri/',
        reg: reg,
        now: now);

/// SASKİ (Samsun) ve OSKİ'nin (Ordu) ortak tablosu.
List<Notice> etkilenenYerlerNotices(String html,
    {required String source,
    required int plaka,
    required String url,
    required Registry reg,
    required DateTime now}) {
  final il = reg.byPlaka(plaka)!;
  final rows = _rows(html);
  final headIdx = rows.indexWhere((r) =>
      r.length >= 4 && normTr(r[0]).startsWith('baslangic') && normTr(r[3]).contains('etkilenen'));
  if (headIdx < 0) throw FormatException('$source: kesinti tablosu yok');
  final out = <Notice>[];
  for (final c in rows.skip(headIdx + 1)) {
    if (c.length < 4) continue;
    final start = parseDayMonthHm(c[0], now);
    var end = parseDayMonthHm(c[1], now);
    if (start != null && end != null && !end.isAfter(start)) end = null;
    if (start == null || !inWindow(start, end, now)) continue;
    final byIlce = <String, List<String>>{};
    for (final place in _split(c[3], ',')) {
      final parts = _split(place, '/');
      if (parts.isEmpty) continue;
      (byIlce[parts.first] ??= []).addAll(parts.skip(1));
    }
    for (final e in byIlce.entries) {
      final mahalleler = e.value.toSet().toList()..sort();
      out.add(Notice(
        kind: NoticeKind.water,
        source: source,
        title: 'Su kesintisi',
        detail: [
          neighborhoodsLine(mahalleler),
          if (c[2].isNotEmpty) '(${titleTr(c[2])})',
        ].join(' '),
        district: il.ilce(e.key)?.ad ?? titleTr(e.key),
        plaka: plaka,
        start: start,
        end: end,
        neighborhoods: mahalleler,
        url: url,
        id: '${normTr(source)}:${stableId('${c.join('|')}|${e.key}')}',
      ));
    }
  }
  return out;
}

/// Trabzon TİSKİ: "warning-card" blokları.
List<Notice> tiskiNotices(String html,
    {required Registry reg, required DateTime now}) {
  if (!html.contains('warning-card') && !normTr(html).contains('su kesintileri')) {
    throw const FormatException('TİSKİ: kesinti sayfası tanınmadı');
  }
  final il = reg.byPlaka(61)!;
  String? after(String block, String label) {
    final m = RegExp('$label\\s*</small>\\s*<span[^>]*>([\\s\\S]*?)</span>')
        .firstMatch(block);
    return m == null ? null : cleanHtml(m.group(1)!);
  }

  final out = <Notice>[];
  for (final b in html.split('class="warning-card"').skip(1)) {
    final title = RegExp(r'class="warning-title"[^>]*>([\s\S]*?)</h3>').firstMatch(b);
    if (title == null) continue;
    final start = parseIsoTr(after(b, 'Kesinti Başlangıç'));
    final end = parseIsoTr(after(b, 'Tahmini Bitiş'));
    if (start == null || !inWindow(start, end, now)) continue;
    final reason = after(b, 'Kesinti Sebebi') ?? '';
    final text = RegExp(r'class="warning-text"[^>]*>([\s\S]*?)</div>').firstMatch(b);
    // "TRABZON / OF / İRFANLI MAH. / TRABZON / ORTAHİSAR / KAVALA MAH. / ..."
    final parts = _split(cleanHtml(title.group(1)!), '/');
    final byIlce = <String, Set<String>>{};
    for (var i = 0; i + 1 < parts.length; i += 3) {
      (byIlce[parts[i + 1]] ??= {})
          .addAll([if (i + 2 < parts.length) parts[i + 2]]);
    }
    for (final e in byIlce.entries) {
      final mahalleler = e.value.toList()..sort();
      out.add(Notice(
        kind: NoticeKind.water,
        source: 'TİSKİ',
        title: 'Su kesintisi',
        detail: [
          neighborhoodsLine(mahalleler),
          if (reason.isNotEmpty) '(${titleTr(reason)})',
          if (text != null && cleanHtml(text.group(1)!).length < 160)
            '— ${cleanHtml(text.group(1)!)}',
        ].join(' '),
        district: il.ilce(e.key)?.ad ?? titleTr(e.key),
        plaka: 61,
        start: start,
        end: end,
        neighborhoods: mahalleler,
        url: 'https://www.tiski.gov.tr/Tiski/SuKesintileri',
        id: 'tiski:${stableId('${title.group(1)}|$start|${e.key}')}',
      ));
    }
  }
  return out;
}

/// Denizli DESKİ: sukesinti.deski.gov.tr/kesintiler.json
List<Notice> deskiNotices(List<dynamic> rows,
    {required Registry reg, required DateTime now}) {
  final il = reg.byPlaka(20)!;
  final out = <Notice>[];
  for (final r in rows.whereType<Map>()) {
    final start = parseIsoTr('${r['BASLANGIC_TARIHI'] ?? ''}');
    final end = parseIsoTr('${r['BITIS_TARIHI'] ?? ''}');
    if (start == null || !inWindow(start, end, now)) continue;
    final mahalleler = _split('${r['MAHALLE_ADI'] ?? ''}', ',');
    final reason = '${r['NEDENI'] ?? ''}'.trim();
    final ilce = '${r['ILCE_ADI'] ?? ''}';
    out.add(Notice(
      kind: NoticeKind.water,
      source: 'DESKİ',
      title: 'Su kesintisi',
      detail: [
        neighborhoodsLine(mahalleler),
        if (reason.isNotEmpty) '(${titleTr(reason)})',
      ].join(' '),
      district: il.ilce(ilce)?.ad ?? titleTr(ilce),
      plaka: 20,
      start: start,
      end: end != null && end.isAfter(start) ? end : null,
      neighborhoods: mahalleler,
      url: 'https://sukesinti.deski.gov.tr/',
      planned: r['KESINTI_TURU'] == 1
          ? true
          : r['KESINTI_TURU'] == 2
              ? false
              : null,
      id: 'deski:${r['KESINTI_ID'] ?? stableId('$ilce|$start|${r['MAHALLE_ADI']}')}',
    ));
  }
  return out;
}

/// Antalya ASAT: kayıt alanları `id="edit<n>_<Alan>"` hücrelerinde. "Sokak"
/// sütunu etkilenen mahalleleri, "EtkilenenMahalleler" açıklamayı taşır.
List<Notice> asatNotices(String html, {required Registry reg, required DateTime now}) {
  if (!html.contains('BaslangicTarihSaat')) {
    throw const FormatException('ASAT: kesinti listesi tanınmadı');
  }
  const url = 'https://kesinti.asat.gov.tr/dbo_kesintiListe/list';
  final il = reg.byPlaka(7)!;
  final rec = <String, Map<String, String>>{};
  for (final m in RegExp(r'<span id="edit(\d+)_(\w+)"\s*>([\s\S]*?)</span>').allMatches(html)) {
    (rec[m.group(1)!] ??= {})[m.group(2)!] =
        cleanHtml(m.group(3)!.replaceAll(RegExp(r'<a[\s\S]*?</a>'), ''));
  }
  final out = <Notice>[];
  for (final e in rec.entries) {
    final r = e.value;
    final start = parseDmyHm(r['BaslangicTarihSaat'] ?? '');
    final end = parseDmyHm(r['BitisTarihiSaat'] ?? '') ?? parseDmyHm(r['TahminiBitisTarihSaat'] ?? '');
    if (start == null || !inWindow(start, end, now)) continue;
    final ilce = r['IlceId'] ?? '';
    final mahalleler = {
      if ((r['MahalleId'] ?? '').isNotEmpty) r['MahalleId']!,
      ..._split(r['Sokak'] ?? '', ','),
    }.toList();
    final neden = r['KesintiNedeniId'] ?? '';
    out.add(Notice(
      kind: NoticeKind.water,
      source: 'ASAT',
      title: 'Su kesintisi',
      detail: [
        neighborhoodsLine(mahalleler),
        if (neden.isNotEmpty) '(${titleTr(neden)})',
      ].join(' '),
      district: il.ilce(ilce)?.ad ?? titleTr(ilce),
      plaka: 7,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: url,
      planned: normTr(neden).contains('ariza') ? false : null,
      id: 'asat:${stableId('$ilce|${r['MahalleId']}|$start')}',
    ));
  }
  return out;
}

/// Muğla MUSKİ: "outage-detail-card" kartları (ilçe, kesinti tarihi, tahmini
/// süre, etkilenen mahalleler, tür). Tamamlananlar atlanır.
List<Notice> muskiNotices(String html, {required Registry reg, required DateTime now}) {
  if (!html.contains('outagesGrid')) {
    throw const FormatException('MUSKİ: kesinti listesi tanınmadı');
  }
  const url = 'https://www.muski.gov.tr/su-kesintileri';
  final il = reg.byPlaka(48)!;
  final cards = html.split('<div class="outage-detail-card"').skip(1);
  final out = <Notice>[];
  for (final c in cards) {
    if (RegExp(r'data-status="(?:tamam|bitti)').hasMatch(c)) continue;
    String value(String label) {
      final i = c.indexOf(label);
      if (i < 0) return '';
      final m = RegExp(r'<div class="detail-value[^"]*">([\s\S]*?)</div>').firstMatch(c.substring(i));
      return m == null ? '' : cleanHtml(m.group(1)!);
    }

    final ilce = cleanHtml(RegExp(r'<h3>([\s\S]*?)</h3>').firstMatch(c)?.group(1) ?? '');
    final start = parseDmyHm(value('Kesinti Tarihi'));
    final hours = int.tryParse(RegExp(r'(\d+)\s*Saat').firstMatch(value('Tahmini'))?.group(1) ?? '');
    final end = start != null && hours != null ? start.add(Duration(hours: hours)) : null;
    if (start == null || !inWindow(start, end, now)) continue;
    final mahalleler = [
      for (final m in _split(value('Etkilenen Mahalleler'), ','))
        m.replaceAll(RegExp(r'\s+Mah\.?$', caseSensitive: false), ''),
    ];
    final tur = value('Kesinti Türü');
    out.add(Notice(
      kind: NoticeKind.water,
      source: 'MUSKİ',
      title: 'Su kesintisi',
      detail: [
        neighborhoodsLine(mahalleler),
        if (tur.isNotEmpty) '($tur)',
      ].join(' '),
      district: il.ilce(ilce)?.ad ?? titleTr(ilce),
      plaka: 48,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: url,
      planned: c.contains('data-type="planli"') ? true : c.contains('data-type="plansiz"') ? false : null,
      id: 'muski:${stableId('$ilce|$start|${mahalleler.join(',')}')}',
    ));
  }
  return out;
}

/// Eskişehir ESKİ: başlık "X İlçesi Y Mahallesi …", metinde kesinti ve suyun
/// verildiği an ("03.11.2026 tarihinde saat 15:45 … 16:05 itibariyle su verilmeye").
List<Notice> eskiEskisehirNotices(String html, {required Registry reg, required DateTime now}) {
  if (!html.contains('Su Kesintileri')) {
    throw const FormatException('ESKİ: kesinti sayfası tanınmadı');
  }
  const url = 'https://www.eskisehir-eski.gov.tr/basin/su-kesintileri';
  final il = reg.byPlaka(26)!;
  final out = <Notice>[];
  for (final m in RegExp(r'<h2 class="no-margin-top">([\s\S]*?)</h2>\s*<p>([\s\S]*?)</p>').allMatches(html)) {
    final title = cleanHtml(m.group(1)!);
    final text = cleanHtml(m.group(2)!);
    final times = [
      for (final t in RegExp(r'(\d{1,2}\.\d{1,2}\.\d{4})\D{1,25}?(\d{1,2}[:.]\d{2})').allMatches(text))
        parseDmyHm('${t.group(1)} ${t.group(2)!.replaceAll('.', ':')}'),
    ].whereType<DateTime>().toList();
    if (times.isEmpty) continue;
    final start = times.first;
    final end = times.length > 1 && times[1].isAfter(start) ? times[1] : null;
    if (!inWindow(start, end, now)) continue;
    final yer = RegExp(r'^(.+?)\s+İlçesi\s+(.+?)\s+Mahallesi').firstMatch(title);
    final ilce = yer?.group(1) ?? '';
    final mahalleler = [if (yer != null) yer.group(2)!];
    out.add(Notice(
      kind: NoticeKind.water,
      source: 'ESKİ',
      title: 'Su kesintisi',
      detail: title,
      district: il.ilce(ilce)?.ad,
      plaka: 26,
      start: start,
      end: end,
      neighborhoods: mahalleler,
      url: url,
      planned: normTr(text).contains('ariza') ? false : null,
      id: 'eski-eskisehir:${stableId('$title|$start')}',
    ));
  }
  return out;
}
