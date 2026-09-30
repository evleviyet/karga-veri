import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:karga_feed/models.dart';
import 'package:karga_feed/parsers/aski.dart';
import 'package:karga_feed/parsers/announcements.dart';

const _ua =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
const _schema = 1;
const _heartbeat = Duration(hours: 3);

Future<String> _get(String url) async {
  final res = await http
      .get(Uri.parse(url), headers: {'User-Agent': _ua})
      .timeout(const Duration(seconds: 40));
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return utf8.decode(res.bodyBytes, allowMalformed: true);
}

/// Kaynak tanımı: dosya yolu, adres ve (html, şimdi) -> kayıtlar.
class Source {
  final String id;
  final String path;
  final String url;
  final List<Notice> Function(String html, DateTime now) parse;
  Source(this.id, this.path, this.url, this.parse);
}

final sources = <Source>[
  Source('ankara-aski', 'data/ankara/aski.json',
      'https://www.aski.gov.tr/tr/Kesinti.aspx', (h, _) => parseAski(h)),
  Source('ankara-abb', 'data/ankara/abb.json',
      'https://www.ankara.bel.tr/duyurular', (h, now) => abbNotices(parseAbb(h), now)),
  Source('ankara-valilik', 'data/ankara/valilik.json',
      'https://www.ankara.gov.tr/duyurular',
      (h, now) => valilikNotices(parseValilik(h), now)),
];

String _pretty(Object o) => '${const JsonEncoder.withIndent('  ').convert(o)}\n';

/// Dosya içeriği değiştiyse yazar; değiştiyse true döner.
bool _write(String path, String content) {
  final f = File(path);
  if (f.existsSync() && f.readAsStringSync() == content) return false;
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
  return true;
}

Future<void> main() async {
  final nowUtc = DateTime.now().toUtc();
  // Duyuru yaşı Türkiye saatine göre hesaplanır.
  final nowTr = nowUtc.add(const Duration(hours: 3));
  final nowTrNaive = DateTime(nowTr.year, nowTr.month, nowTr.day, nowTr.hour, nowTr.minute);

  var dataChanged = false;
  final status = <String, Map<String, dynamic>>{};

  for (final s in sources) {
    try {
      final notices = s.parse(await _get(s.url), nowTrNaive);
      dataChanged |= _write(s.path, _pretty({
        'schema': _schema,
        'source': s.id,
        'notices': notices.map((n) => n.toJson()).toList(),
      }));
      status[s.id] = {'status': 'ok', 'count': notices.length};
      stdout.writeln('${s.id}: ok (${notices.length})');
    } catch (e) {
      // Önceki dosyayı bozmadan bırak; uygulama "degraded" görüp kullanıcıya söyler.
      status[s.id] = {'status': 'degraded', 'error': '$e'.split('\n').first};
      stdout.writeln('${s.id}: DEGRADED $e');
    }
  }

  // meta.json: içerik değişmediyse ve son kalp atışı yakınsa dosyaya dokunma
  // (gereksiz commit oluşmasın).
  final metaFile = File('data/meta.json');
  Map<String, dynamic>? prev;
  if (metaFile.existsSync()) {
    prev = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
  }
  final prevAt = DateTime.tryParse('${prev?['generatedAt']}');
  final sameStatus = prev != null &&
      jsonEncode(prev['sources']) == jsonEncode(status) &&
      prev['schema'] == _schema;
  final stale = prevAt == null || nowUtc.difference(prevAt) >= _heartbeat;
  if (dataChanged || !sameStatus || stale) {
    _write('data/meta.json', _pretty({
      'schema': _schema,
      'generatedAt': nowUtc.toIso8601String(),
      'sources': status,
    }));
  }
}
