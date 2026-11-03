import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karga_feed/net.dart';
import 'package:karga_feed/quakes.dart';
import 'package:test/test.dart';

const _afad = '[{"rms":"0.37","eventID":"598079","location":"Sumbas (Osmaniye)",'
    '"latitude":"37.71633","longitude":"36.11583","depth":"7","type":"MW",'
    '"magnitude":"4.2","country":"Türkiye","province":"Osmaniye",'
    '"date":"2026-11-02T17:58:06","isEventUpdate":false}]';

const _emsc = '{"type":"FeatureCollection","features":[{"type":"Feature",'
    '"id":"20261102_0000243","properties":{"time":"2026-11-02T17:58:06.31Z",'
    '"flynn_region":"CENTRAL TURKEY","lat":37.7163,"lon":36.1158,"depth":7.0,'
    '"mag":4.1,"unid":"20261102_0000243"}}]}';

void main() {
  final now = DateTime.utc(2026, 11, 3, 12);

  test('AFAD kaydı uygulamanın okuduğu alanlarla aynen geçer', () async {
    final net = Net(MockClient((r) async {
      expect(r.url.host, 'servisnet.afad.gov.tr');
      expect(r.url.queryParameters['minmag'], '3.0');
      return http.Response.bytes(utf8.encode(_afad), 200);
    }));
    final q = await buildQuakes(net, now);
    expect(q['source'], 'AFAD');
    final e = (q['events'] as List).single as Map;
    expect(e['eventID'], '598079');
    expect(e['location'], 'Sumbas (Osmaniye)');
    expect(e['date'], '2026-11-02T17:58:06');
    expect(e.containsKey('rms'), isFalse);
  });

  test('AFAD okunamazsa EMSC aynı biçime çevrilir', () async {
    final net = Net(MockClient((r) async => r.url.host.contains('afad')
        ? http.Response('', 503)
        : http.Response(_emsc, 200)));
    final q = await buildQuakes(net, now);
    expect(q['source'], 'EMSC');
    expect(q['errors'], hasLength(1));
    final e = (q['events'] as List).single as Map;
    expect(e['eventID'], 'E20261102_0000243');
    expect(e['location'], 'Central Turkey');
    expect(e['date'], '2026-11-02T17:58:06');
    expect(e['magnitude'], '4.1');
  });

  test('ikisi de okunamazsa boş liste ve hatalar', () async {
    final net = Net(MockClient((r) async => http.Response('', 500)));
    final q = await buildQuakes(net, now);
    expect(q['source'], isNull);
    expect(q['events'], isEmpty);
    expect(q['errors'], hasLength(2));
  });
}
