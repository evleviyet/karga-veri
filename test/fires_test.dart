import 'package:karga_feed/fires.dart';
import 'package:karga_feed/registry.dart';
import 'package:test/test.dart';

Map<String, dynamic> ev(double lat, double lon,
        {int count = 20, double frp = 120, String conf = 'probable', String? first, String last = '2026-08-01T10:00:00Z'}) =>
    {
      'id': 'x_${lat}_$lon',
      'centroid': [lon, lat],
      'count': count,
      'maxFrp': frp,
      'confidence': conf,
      'firstSeen': first ?? last,
      'lastSeen': last,
    };

void main() {
  final reg = Registry.load();
  final now = DateTime.utc(2026, 8, 1, 12);
  // Manavgat yakını (Antalya), orman
  const lat = 36.85, lon = 31.55;

  test('güçlü ve doğrulanmış küme yayımlanır, il/ilçe eklenir', () {
    final f = firesFile({'events': [ev(lat, lon)]}, reg, now);
    final e = (f['events'] as List).single as Map;
    expect(e['il'], 'Antalya');
    expect(e['ilce'], isNotEmpty);
    expect(f['source'], 'kanari.io');
  });

  test('zayıf, belirsiz, eski ve yurt dışı kümeler atlanır', () {
    final f = firesFile({
      'events': [
        ev(lat, lon, conf: 'possible'),
        ev(lat, lon, count: 2),
        ev(lat, lon, frp: 10),
        ev(lat, lon, last: '2026-07-31T20:00:00Z'), // 16 saat önce
        ev(35.98, 43.74), // Irak
        ev(34.0, 33.0), // deniz, Kıbrıs güneyi
      ]
    }, reg, now);
    expect(f['events'], isEmpty);
  });

  test('aynı hücrede 3 ayrı gün görülen nokta sanayi sayılır', () {
    final seen = <String, dynamic>{
      fireCell(lat, lon): ['2026-07-29', '2026-07-30'],
    };
    final f = firesFile({'events': [ev(lat, lon)]}, reg, now, seenDays: seen);
    expect(f['events'], isEmpty);
    expect(seen[fireCell(lat, lon)], ['2026-07-29', '2026-07-30', '2026-08-01']);
    // 30 günden eski günler unutulur
    final old = <String, dynamic>{fireCell(lat, lon): ['2026-06-01', '2026-06-02']};
    expect(firesFile({'events': [ev(lat, lon)]}, reg, now, seenDays: old)['events'], hasLength(1));
  });
}
