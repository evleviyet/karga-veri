import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// EPİAŞ Şeffaflık Platformu: tüm dağıtım şirketlerinin planlı ve plansız
/// elektrik kesintileri (il bazında). Ücretsiz hesap ister; kullanıcı adı ve
/// şifre yalnızca GitHub Actions secret'larında durur (EPIAS_USER, EPIAS_PASS),
/// depoda ve çıktıda yoktur.
///
/// Şimdilik keşif: verinin ayrıntı düzeyi (ilçe/mahalle/saat) görülsün diye
/// her türden ilk birkaç kayıt data/v2/epias_probe.json'a yazılır. Kayıtlar
/// zaten herkese açık kesinti bilgisidir; giriş bilgisi yazılmaz.
const epiasLogin = 'https://giris.epias.com.tr/cas/v1/tickets';
const epiasBase = 'https://seffaflik.epias.com.tr/electricity-service/v1/consumption/data';

/// Ayın ilk günü, Türkiye saati: "2026-11-01T00:00:00+03:00".
String epiasPeriod(DateTime trNow) =>
    '${trNow.year}-${trNow.month.toString().padLeft(2, '0')}-01T00:00:00+03:00';

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

/// Keşif dosyası: her türün kayıt sayısı, alan adları ve ilk kayıtlar.
Future<void> epiasProbe(Directory out, DateTime trNow) async {
  final user = Platform.environment['EPIAS_USER'];
  final pass = Platform.environment['EPIAS_PASS'];
  if (user == null || user.isEmpty || pass == null || pass.isEmpty) return;
  final c = http.Client();
  final report = <String, dynamic>{
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'period': epiasPeriod(trNow),
  };
  try {
    final tgt = await epiasTgt(c, user, pass);
    report['login'] = 'ok';
    for (final (name, path) in [
      ('planned', 'planned-power-outage-info'),
      ('unplanned', 'unplanned-power-outage-info'),
    ]) {
      try {
        final j = await epiasPost(c, tgt, path, {'period': epiasPeriod(trNow), 'provinceId': 6});
        final items = (j['items'] as List?) ?? const [];
        report[name] = {
          'keys': j.keys.toList(),
          'count': items.length,
          if (items.isNotEmpty && items.first is Map) 'fields': (items.first as Map).keys.toList(),
          'sample': items.take(4).toList(),
          if (j['page'] != null) 'page': j['page'],
        };
      } catch (e) {
        report[name] = {'error': '$e'};
      }
    }
  } catch (e) {
    report['login'] = '$e';
  } finally {
    c.close();
  }
  File('${out.path}/data/v2/epias_probe.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
}
