import 'dart:convert';
import 'dart:io';

import 'package:karga_feed/build.dart';
import 'package:karga_feed/models.dart';
import 'package:karga_feed/net.dart';
import 'package:karga_feed/registry.dart';
import 'package:karga_feed/sources.dart';
import 'package:test/test.dart';

void main() {
  final reg = Registry.load();

  group('kayıt defteri', () {
    test('81 il, 973 ilçe, her ilin elektrik dağıtım şirketi var', () {
      expect(reg.iller, hasLength(81));
      expect(reg.iller.map((i) => i.plaka).toSet(), hasLength(81));
      expect(reg.iller.fold<int>(0, (a, il) => a + il.ilceler.length), 973);
      for (final il in reg.iller) {
        expect(reg.kurumlar[il.elektrik]?.tur, 'elektrik', reason: il.ad);
        // Su idaresi yalnızca büyükşehirlerde; diğerlerinde belediye.
        expect(il.su != null, il.buyuksehir, reason: il.ad);
        for (final d in il.ilceler) {
          expect(d.mgm, isNotEmpty, reason: '${il.ad}/${d.ad}');
        }
      }
      expect(reg.iller.where((i) => i.buyuksehir), hasLength(30));
      expect(reg.kurumlar.values.where((k) => k.tur == 'elektrik'), hasLength(21));
    });

    test('il ve ilçe adlarının farklı yazımları', () {
      expect(reg.byName('Afyon')!.plaka, 3);
      expect(reg.byName('İçel')!.plaka, 33);
      expect(reg.byName('K.Maraş')!.plaka, 46);
      expect(reg.byName('Istanbul')!.plaka, 34);
      expect(reg.byName('Adana Province')!.plaka, 1);
      expect(reg.byName('Narnia'), isNull);
      final bayburt = reg.byName('Bayburt')!;
      expect(bayburt.ilce('Merkez')!.ad, 'Merkez');
      expect(bayburt.ilce('Bayburt Merkez')!.ad, 'Merkez');
      expect(reg.byPlaka(55)!.ilce('Ondokuzmayıs')!.ad, '19 Mayıs');
      expect(reg.byPlaka(34)!.ilce('Eyüp')!.ad, 'Eyüpsultan');
      expect(reg.byPlaka(6)!.ilce('Kazan')!.ad, 'Kahramankazan');
      expect(reg.byPlaka(6)!.ilce('ÇANKAYA')!.ad, 'Çankaya');
      // Büyükşehirde "Merkez" ilçesi yoktur.
      expect(reg.byPlaka(6)!.ilce('Merkez'), isNull);
    });

    test('MGM merkezleri ilçelere bağlı', () {
      final k = reg.mgmTown(90601).single;
      expect((k.$1.ad, k.$2.ad), ('Ankara', 'Keçiören'));
      expect(reg.mgmTown(90901).map((e) => e.$2.ad), ['Efeler']);
      expect(reg.mgmTown(94501).map((e) => e.$2.ad).toSet(),
          {'Şehzadeler', 'Yunusemre'});
    });

    test('koordinattan ilçe ve kurumlar', () {
      final (il, ilce) = reg.nearest(39.9208, 32.8541)!; // Kızılay
      expect(il.ad, 'Ankara');
      expect(['Çankaya', 'Altındağ', 'Keçiören'], contains(ilce.ad));
      final ist = reg.byPlaka(34)!;
      expect(reg.kurumFor(ist, ist.ilce('Kadıköy'), 'elektrik')!.id, 'ayedas');
      expect(reg.kurumFor(ist, ist.ilce('Şişli'), 'elektrik')!.id, 'bedas');
      expect(reg.kurumFor(ist, null, 'su')!.kisa, 'İSKİ');
      final bayburt = reg.byPlaka(69)!;
      expect(reg.kurumFor(bayburt, null, 'su'), isNull);
      expect(bayburt.valilikUrl, 'https://www.bayburt.gov.tr');
      expect(reg.byPlaka(3)!.belediye, 'https://www.afyon.bel.tr');
    });
  });

  group('feed üretimi', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('karga_feed_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('yönlendirme, tekrar ayıklama, son başarılı veri ve site dosyaları', () async {
      final now = DateTime(2026, 10, 6, 12);
      final nowUtc = DateTime.utc(2026, 10, 6, 9);
      final cache = Directory('${tmp.path}/cache');
      // "c" kaynağının bir saat önceki başarılı okuması
      File('${cache.path}/last/c.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'at': DateTime.utc(2026, 10, 6, 8).toIso8601String(),
          'notices': [
            {
              'id': 'c:1',
              'kind': 'water',
              'source': 'C',
              'title': 'Su kesintisi',
              'detail': 'x',
              'district': 'Mamak',
              'start': '2026-10-06T08:00:00.000',
              'end': '2026-10-06T20:00:00.000',
              'plaka': 6,
            },
            {
              'id': 'c:2',
              'kind': 'water',
              'source': 'C',
              'title': 'Bitti',
              'detail': 'x',
              'end': '2026-10-06T09:00:00.000',
              'plaka': 6,
            },
          ],
        }));
      Notice n(String id, {int? plaka, String? district}) => Notice(
          kind: NoticeKind.power,
          source: 'S',
          title: 'T',
          detail: 'D',
          id: id,
          plaka: plaka,
          district: district,
          start: DateTime(2026, 10, 6, 9),
          end: DateTime(2026, 10, 6, 17));
      final sources = [
        Source('a', 'A', NoticeKind.water, [6],
            (c) async => [n('a:1', district: 'YENİMAHALLE')]),
        Source('b', 'B', NoticeKind.power, [34, 6], kurum: 'bedas', (c) async => [
              n('b:1', plaka: 34, district: 'KADIKÖY'),
              n('b:1', plaka: 34, district: 'KADIKÖY'),
              n('b:2', district: 'X'), // çok illi kaynakta il yoksa atlanır
            ]),
        Source('c', 'C', NoticeKind.water, [6], (c) async => throw Exception('kapalı')),
        Source('d', 'D', NoticeKind.general, [6], (c) async => throw Exception('yok')),
      ];
      final net = Net();
      final r = await runSources(Ctx(net, reg, now, cache), sources, nowUtc: nowUtc);
      net.close();

      final ankara = r.byPlaka[6]!;
      expect(ankara.map((x) => x.id), containsAll(['a:1', 'c:1']));
      expect(ankara.firstWhere((x) => x.id == 'a:1').district, 'Yenimahalle');
      expect(ankara.any((x) => x.id == 'c:2'), isFalse); // bitmiş kayıt atıldı
      expect(r.byPlaka[34]!.single.district, 'Kadıköy');
      final c = r.runs.firstWhere((x) => x.source.id == 'c');
      expect((c.status, c.stale), ('degraded', true));
      final d = r.runs.firstWhere((x) => x.source.id == 'd');
      expect((d.status, d.stale), ('degraded', false));
      expect(d.notices, isEmpty);
      // Başarılı kaynağın son hali saklandı.
      expect(File('${cache.path}/last/a.json').existsSync(), isTrue);

      final out = Directory('${tmp.path}/site');
      writeSite(r, reg, out);
      final bundle = jsonDecode(
              File('${out.path}/data/v2/il/ankara.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(bundle['schema'], 2);
      expect(bundle['il'], {'plaka': 6, 'ad': 'Ankara'});
      expect((bundle['kurumlar'] as Map)['elektrik']['kisa'], 'Başkent EDAŞ');
      expect((bundle['kurumlar'] as Map)['su']['kisa'], 'ASKİ');
      final srcs = {
        for (final s in (bundle['sources'] as List).cast<Map>()) s['id']: s
      };
      expect(srcs.keys, containsAll(['a', 'b', 'c', 'd']));
      expect(srcs['c']!['stale'], isTrue);
      expect(srcs['a']!['count'], 1);
      final ist = jsonDecode(
              File('${out.path}/data/v2/il/istanbul.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(((ist['kurumlar'] as Map)['elektrikIlce'] as Map)['Kadıköy']['id'],
          'ayedas');
      expect(File('${out.path}/data/v2/il/bayburt.json').existsSync(), isTrue);
      expect(Directory('${out.path}/data/v2/il').listSync(), hasLength(81));
      final meta = jsonDecode(File('${out.path}/data/v2/meta.json').readAsStringSync());
      expect(meta['sources']['c']['status'], 'degraded');
      expect(File('${out.path}/data/v2/registry.json').existsSync(), isTrue);
      expect(File('${out.path}/index.html').readAsStringSync(), contains('Karga veri'));
    });

    test('sürüm 1 dosyaları (eski uygulamalar) hâlâ üretiliyor', () async {
      final now = DateTime(2026, 10, 6, 12);
      final sources = [
        Source('aski', 'ASKİ', NoticeKind.water, [6], (c) async => [
              Notice(
                  kind: NoticeKind.water,
                  source: 'ASKİ',
                  title: 'Su kesintisi',
                  detail: 'Özevler',
                  district: 'YENİMAHALLE',
                  start: DateTime(2026, 10, 6, 8),
                  end: DateTime(2026, 10, 6, 20),
                  plaka: 6)
            ]),
        Source('valilik-ankara', 'Ankara Valiliği', NoticeKind.general, [6],
            (c) async => [
                  Notice(
                      kind: NoticeKind.general,
                      source: 'Ankara Valiliği',
                      title: 'Kar Nedeniyle Okullar Tatil Edildi',
                      detail: '',
                      url: 'https://www.ankara.gov.tr/x',
                      start: DateTime(2026, 10, 6)),
                  Notice(
                      kind: NoticeKind.general,
                      source: 'Ankara Valiliği',
                      title: 'Fırtına Uyarısı',
                      detail: '',
                      start: DateTime(2026, 10, 6)),
                ]),
        Source('abb', 'ABB', NoticeKind.general, [6], (c) async => throw Exception('x')),
      ];
      final net = Net();
      final r = await runSources(
          Ctx(net, reg, now, Directory('${tmp.path}/cache')), sources);
      net.close();
      final out = Directory('${tmp.path}/site');
      writeSite(r, reg, out);
      final meta = jsonDecode(File('${out.path}/data/meta.json').readAsStringSync());
      expect(meta['schema'], 1);
      expect(meta['sources']['ankara-aski'], {'status': 'ok', 'count': 1});
      expect(meta['sources']['ankara-abb']['status'], 'degraded');
      final aski = jsonDecode(File('${out.path}/data/ankara/aski.json').readAsStringSync());
      expect((aski['notices'] as List).single.keys.toSet(),
          {'kind', 'source', 'title', 'detail', 'district', 'start', 'end'});
      final valilik =
          jsonDecode(File('${out.path}/data/ankara/valilik.json').readAsStringSync());
      // Sürüm 1 yalnızca okul tatillerini taşır; ayrıntı alanında bağlantı vardır.
      expect((valilik['notices'] as List).single['detail'], 'https://www.ankara.gov.tr/x');
    });
  });


  test('eski sürüm dosyaları yalnızca değişince ya da kalp atışında yazılır', () {
    final tmp = Directory.systemTemp.createTempSync('karga_legacy_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final site = Directory('${tmp.path}/site');
    final repo = Directory('${tmp.path}/data');
    void meta(String status, DateTime at) => File('${site.path}/data/meta.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'schema': 1,
        'generatedAt': at.toIso8601String(),
        'sources': {
          'ankara-aski': {'status': status, 'count': 1},
        },
      }));
    File('${site.path}/data/ankara/aski.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"notices":[1]}');
    final t0 = DateTime.utc(2026, 10, 6, 9);
    meta('ok', t0);
    expect(syncLegacy(site, repo, t0), isTrue); // ilk kez
    meta('ok', t0.add(const Duration(minutes: 30)));
    expect(syncLegacy(site, repo, t0.add(const Duration(minutes: 30))), isFalse);
    meta('degraded', t0.add(const Duration(hours: 1)));
    expect(syncLegacy(site, repo, t0.add(const Duration(hours: 1))), isTrue);
    meta('degraded', t0.add(const Duration(hours: 4, minutes: 1)));
    expect(syncLegacy(site, repo, t0.add(const Duration(hours: 4, minutes: 1))),
        isTrue); // kalp atışı
    File('${site.path}/data/ankara/aski.json').writeAsStringSync('{"notices":[2]}');
    expect(syncLegacy(site, repo, t0.add(const Duration(hours: 4, minutes: 2))), isTrue);
    expect(File('${repo.path}/ankara/aski.json').readAsStringSync(), '{"notices":[2]}');
  });
}
