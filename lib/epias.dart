import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'registry.dart';

/// EPİAŞ Şeffaflık Platformu: tüm dağıtım şirketlerinin planlı ve plansız
/// elektrik kesintileri (ilçe ve mahalle adlarıyla). Ücretsiz hesap ister;
/// kullanıcı adı ve şifre yalnızca GitHub Actions secret'larında durur
/// (EPIAS_USER, EPIAS_PASS), depoda ve çıktıda yoktur.
///
/// Planlı kesintiler gün gün yayımlanır (bugün ve sonraki günler); plansız
/// kesintiler olaydan sonra yayımlandığı için anlık uyarıda kullanılmaz.
/// Feed, kendi okuyucusu olmayan dağıtım şirketleri için EPİAŞ'ı kullanır
/// ([epiasKurumlar]); kendi okuyucusu olanlarda (BEDAŞ, CK, Aksa, UEDAŞ, MEDAŞ,
/// KCETAŞ) daha ayrıntılı olan kendi kaynağı kalır.
const epiasLogin = 'https://giris.epias.com.tr/cas/v1/tickets';
const epiasBase = 'https://seffaflik.epias.com.tr/electricity-service/v1/consumption/data';

/// Gün başı, Türkiye saati: "2026-11-03T00:00:00+03:00". (Kayıtların "date"
/// alanı istenen güne eşit geliyor: dönem bir gündür.)
String epiasPeriod(DateTime trDay) =>
    '${trDay.year}-${trDay.month.toString().padLeft(2, '0')}-${trDay.day.toString().padLeft(2, '0')}T00:00:00+03:00';

Future<String> epiasTgt(http.Client c, String user, String pass) async {
  final res = await c
      .post(Uri.parse(epiasLogin),
          headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'text/plain'},
          body: 'username=${Uri.encodeQueryComponent(user)}&password=${Uri.encodeQueryComponent(pass)}')
      .timeout(const Duration(seconds: 30));
  final body = res.body.trim();
  // Hata iletisine yanıt gövdesi konmaz (giriş bilgisi yankılanabilir).
  if ((res.statusCode != 200 && res.statusCode != 201) || !body.startsWith('TGT-')) {
    throw Exception('EPİAŞ girişi başarısız: HTTP ${res.statusCode}');
  }
  return body;
}

Future<Map<String, dynamic>> epiasPost(http.Client c, String tgt, String path, Map<String, dynamic> body) async {
  final res = await c
      .post(Uri.parse('$epiasBase/$path'),
          headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'TGT': tgt},
          body: jsonEncode(body))
      .timeout(const Duration(seconds: 60));
  final j = jsonDecode(utf8.decode(res.bodyBytes));
  if (res.statusCode != 200) {
    throw Exception('EPİAŞ $path: HTTP ${res.statusCode} ${j is Map ? j['errors'] : ''}');
  }
  return j as Map<String, dynamic>;
}

/// EPİAŞ'tan okunan dağıtım şirketleri (providers.json kimlikleri).
const epiasKurumlar = [
  'baskent', 'ayedas', 'toroslar', 'gdz', 'tredas', 'sedas', 'oedas',
  'akedas', 'adm', 'yedas', 'dicle', 'vedas', 'aras',
];

/// EPİAŞ şirket adı ("BASKENT_EDAS", "CK_CAMLIBEL_EDAS", "AKEDAS") -> kurum.
/// Sıra önemli: "ayedas" içinde "yedas", "yesilirmakedas" içinde "akedas" geçer.
String? epiasKurum(String name) {
  final n = normTr(name).replaceAll(RegExp(r'[^a-z]'), '');
  const keys = [
    ('baskent', 'baskent'), ('yesilirmak', 'yedas'), ('ayedas', 'ayedas'), ('anadoluyakasi', 'ayedas'),
    ('bogazici', 'bedas'), ('bedas', 'bedas'), ('toroslar', 'toroslar'),
    ('gediz', 'gdz'), ('gdz', 'gdz'), ('trakya', 'tredas'), ('tredas', 'tredas'),
    ('akedas', 'akedas'), ('sakarya', 'sedas'), ('sedas', 'sedas'),
    ('osmangazi', 'oedas'), ('oedas', 'oedas'), ('menderes', 'adm'), ('adm', 'adm'),
    ('yedas', 'yedas'), ('dicle', 'dicle'),
    ('vangolu', 'vedas'), ('vedas', 'vedas'), ('aras', 'aras'),
    ('akdeniz', 'akdeniz'), ('camlibel', 'cedas'), ('coruh', 'coruh'),
    ('firat', 'firat'), ('uludag', 'uedas'), ('meram', 'meram'), ('kayseri', 'kcetas'),
  ];
  for (final (k, id) in keys) {
    if (n.contains(k)) return id;
  }
  return null;
}

/// "HASANOĞLAN BAHÇELİEVLER Mah.", "Igde Mh.", "TAVŞANLI KÖYÜ" -> adlar.
/// Mahalle işareti yoksa (yalnızca ilçe adı) boş: kesinti ilçe genelidir.
List<String> epiasMahalleler(String text) {
  final out = <String, String>{};
  for (final m in RegExp(r'([^,;]+?)\s+(?:MAHALLESİ|MAHALLESI|Mahallesi|MAH\.?|Mah\.?|Mh\.?|KÖYÜ|Köyü|KOYU)(?=[\s,;.]|$)')
      .allMatches(text)) {
    final name = m.group(1)!.trim();
    if (name.isNotEmpty) out.putIfAbsent(placeKey(name), () => name);
  }
  return out.values.toList();
}

/// Bir şirketin planlı kesinti kayıtları -> feed kayıtları. İlçesi tanınmayan
/// kayıt atlanır (il geneline yayılmasın).
List<Notice> epiasNotices(List<Map<String, dynamic>> rows, String kurum, Registry reg, DateTime now) {
  final groups = <String, (Map<String, dynamic>, int, Ilce, Map<String, String>, List<String>)>{};
  for (final r in rows) {
    if (epiasKurum('${r['distributionCompanyName']}') != kurum) continue;
    final prov = '${r['province'] ?? ''}';
    final il = placeKey(prov).startsWith('istanbul') ? reg.byPlaka(34) : reg.byName(prov);
    if (il == null) continue;
    final ilce = il.ilce('${r['district'] ?? ''}'.split('/').first.trim());
    if (ilce == null) continue;
    final key = '${il.plaka}|${ilce.key}|${r['startTime']}|${r['endTime']}|${r['reason']}';
    final g = groups[key] ??= (r, il.plaka, ilce, <String, String>{}, <String>[]);
    final text = '${r['effectedNeighbourhoods'] ?? ''}'.trim();
    for (final m in epiasMahalleler(text)) {
      g.$4.putIfAbsent(placeKey(m), () => m);
    }
    if (text.isNotEmpty && g.$5.length < 6) g.$5.add(text);
  }
  final out = <Notice>[];
  for (final e in groups.entries) {
    final (r, plaka, ilce, mah, texts) = e.value;
    final start = DateTime.tryParse('${r['startTime']}')?.toUtc().add(const Duration(hours: 3));
    var end = DateTime.tryParse('${r['endTime']}')?.toUtc().add(const Duration(hours: 3));
    // Türkiye saati, saat dilimi eksiz (feed'in diğer kaynakları gibi)
    DateTime? local(DateTime? d) => d == null ? null : DateTime(d.year, d.month, d.day, d.hour, d.minute);
    final s0 = local(start), e0 = local(end);
    if (s0 == null || !inWindow(s0, e0, now)) continue;
    final mahalleler = mah.values.toList()..sort();
    final reason = '${r['reason'] ?? ''}'.trim();
    out.add(Notice(
      kind: NoticeKind.power,
      source: reg.kurumlar[kurum]?.kisa ?? kurum,
      title: 'Planlı elektrik kesintisi',
      detail: [
        mahalleler.isNotEmpty ? neighborhoodsLine(mahalleler) : texts.join(', '),
        if (reason.isNotEmpty) '(${titleTr(reason.split(' - ').first)})',
      ].join(' '),
      district: ilce.ad,
      plaka: plaka,
      start: s0,
      end: e0 != null && e0.isAfter(s0) ? e0 : null,
      neighborhoods: mahalleler,
      url: 'https://seffaflik.epias.com.tr/electricity/electricity-consumption/failure-information/planned-failure-information',
      planned: true,
      id: 'epias:${stableId(e.key)}',
    ));
  }
  return out;
}

/// Bu turun EPİAŞ planlı kesintileri (bugün ve sonraki 3 gün), turda bir kez
/// okunur; şirket kaynakları aynı listeyi paylaşır.
final _planned = Expando<Future<List<Map<String, dynamic>>>>();

Future<List<Map<String, dynamic>>> epiasPlanned(Object turn, DateTime trNow,
    {String? user, String? pass}) {
  return _planned[turn] ??= () async {
    final u = user ?? Platform.environment['EPIAS_USER'];
    final p = pass ?? Platform.environment['EPIAS_PASS'];
    if (u == null || u.isEmpty || p == null || p.isEmpty) {
      throw Exception('EPİAŞ hesabı tanımlı değil');
    }
    final c = http.Client();
    try {
      final tgt = await epiasTgt(c, u, p);
      final today = DateTime(trNow.year, trNow.month, trNow.day);
      final rows = <Map<String, dynamic>>[];
      for (var d = 0; d <= 3; d++) {
        for (var n = 1; n <= 10; n++) {
          final j = await epiasPost(c, tgt, 'planned-power-outage-info', {
            'period': epiasPeriod(today.add(Duration(days: d))),
            'page': {'number': n, 'size': 500},
          });
          final got = (j['items'] as List?) ?? const [];
          rows.addAll(got.whereType<Map<String, dynamic>>());
          if (got.length < 500) break;
        }
      }
      return rows;
    } finally {
      c.close();
    }
  }();
}

bool get epiasConfigured =>
    (Platform.environment['EPIAS_USER'] ?? '').isNotEmpty &&
    (Platform.environment['EPIAS_PASS'] ?? '').isNotEmpty;
