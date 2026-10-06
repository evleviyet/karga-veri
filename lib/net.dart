import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const browserUa =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';

/// Kaynaklara saygılı HTTP: tarayıcı kimliği, zaman aşımı, bir kez yeniden deneme.
class Net {
  final http.Client client;
  final Duration timeout;
  Net([http.Client? client, this.timeout = const Duration(seconds: 40)])
      : client = client ?? http.Client();

  Future<String> get(String url, {Map<String, String>? headers}) =>
      _send(() => client.get(Uri.parse(url),
          headers: {'User-Agent': browserUa, ...?headers}));

  Future<dynamic> getJson(String url, {Map<String, String>? headers}) async =>
      jsonDecode(await get(url, headers: headers));

  Future<dynamic> postJson(String url, Object body,
          {Map<String, String>? headers}) async =>
      jsonDecode(await _send(() => client.post(Uri.parse(url),
          headers: {
            'User-Agent': browserUa,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            ...?headers,
          },
          body: jsonEncode(body))));

  Future<String> _send(Future<http.Response> Function() req) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await req().timeout(timeout);
        if (res.statusCode == 200) {
          return utf8.decode(res.bodyBytes, allowMalformed: true);
        }
        last = Exception('HTTP ${res.statusCode}');
        // 4xx yeniden denemeye değmez.
        if (res.statusCode >= 400 && res.statusCode < 500) break;
      } catch (e) {
        last = e;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw last ?? Exception('istek başarısız');
  }
}

/// Aynı anda en fazla [limit] iş çalıştırır.
Future<List<T>> pooled<T>(
    Iterable<Future<T> Function()> jobs, int limit) async {
  final list = jobs.toList();
  final out = List<T?>.filled(list.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < list.length) {
      final i = next++;
      out[i] = await list[i]();
    }
  }

  await Future.wait([for (var i = 0; i < limit && i < list.length; i++) worker()]);
  return out.cast<T>();
}
