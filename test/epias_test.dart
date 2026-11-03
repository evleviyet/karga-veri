import 'package:karga_feed/epias.dart';
import 'package:karga_feed/registry.dart';
import 'package:test/test.dart';

/// Kayıtlar EPİAŞ'ın 3 Kasım 2026 yanıtlarından.
final rows = <Map<String, dynamic>>[
  {
    'province': 'ANKARA', 'district': 'Gölbaşı / Ankara', 'distributionCompanyName': 'BASKENT_EDAS',
    'startTime': '2026-11-04T09:30:00+03:00', 'endTime': '2026-11-04T17:30:00+03:00',
    'reason': 'Hizmet Alım Çalışması - YG-hizmet alım çalışmaları', 'effectedNeighbourhoods': 'ÖRENCİK Mah.',
  },
  {
    'province': 'ANKARA', 'district': 'Gölbaşı / Ankara', 'distributionCompanyName': 'BASKENT_EDAS',
    'startTime': '2026-11-04T09:30:00+03:00', 'endTime': '2026-11-04T17:30:00+03:00',
    'reason': 'Hizmet Alım Çalışması - YG-hizmet alım çalışmaları', 'effectedNeighbourhoods': 'EYMİR Mah.',
  },
  {
    'province': 'ANKARA', 'district': 'Elmadağ', 'distributionCompanyName': 'BASKENT_EDAS',
    'startTime': '2026-11-04T10:00:00+03:00', 'endTime': '2026-11-04T18:00:00+03:00',
    'reason': '3. Şahıs Planlı Kesinti - 3. Şahıs', 'effectedNeighbourhoods': 'HASANOĞLAN BAHÇELİEVLER Mah.',
  },
  {
    'province': 'KOCAELİ', 'district': 'Gebze', 'distributionCompanyName': 'SEDAS',
    'startTime': '2026-11-04T09:00:00+03:00', 'endTime': '2026-11-04T17:00:00+03:00',
    'reason': 'KESİNTİ ÖNLEME AMAÇLI GENEL BAKIM ONARIM ÇALIŞMASI',
    'effectedNeighbourhoods': ' DEMIRCILER KÖYÜ TAVSANLI MAH.',
  },
  {
    'province': 'BURSA', 'district': 'İnegöl', 'distributionCompanyName': 'ULUDAG',
    'startTime': '2026-11-04T17:00:00+03:00', 'endTime': '2026-11-04T18:00:00+03:00',
    'reason': 'TRAFO BAKIM', 'effectedNeighbourhoods': 'İNEGÖL',
  },
  {
    'province': 'NİĞDE', 'district': 'Bilinmeyen Yer', 'distributionCompanyName': 'BASKENT_EDAS',
    'startTime': '2026-11-04T09:00:00+03:00', 'endTime': '2026-11-04T10:00:00+03:00',
    'reason': 'x', 'effectedNeighbourhoods': 'A Mah.',
  },
];

void main() {
  final reg = Registry.load();
  final now = DateTime(2026, 11, 3, 18);

  test('şirket adları kuruma eşlenir', () {
    expect(epiasKurum('BASKENT_EDAS'), 'baskent');
    expect(epiasKurum('AYEDAS'), 'ayedas');
    expect(epiasKurum('YESILIRMAK_EDAS'), 'yedas');
    expect(epiasKurum('CK_CAMLIBEL_EDAS'), 'cedas');
    expect(epiasKurum('SEDAS'), 'sedas');
    expect(epiasKurum('TREDAS'), 'tredas');
    expect(epiasKurum('AKEDAS'), 'akedas');
    expect(epiasKurum('ULUDAG'), 'uedas');
  });

  test('mahalle adları serbest metinden', () {
    expect(epiasMahalleler('HASANOĞLAN BAHÇELİEVLER Mah.'), ['HASANOĞLAN BAHÇELİEVLER']);
    expect(epiasMahalleler(' DEMIRCILER KÖYÜ TAVSANLI MAH.'), ['DEMIRCILER', 'TAVSANLI']);
    expect(epiasMahalleler('Igde Mh.'), ['Igde']);
    expect(epiasMahalleler('İNEGÖL'), isEmpty);
  });

  test('Başkent EDAŞ: aynı çalışma tek kayıt, ilçe ve saatler doğru', () {
    final n = epiasNotices(rows, 'baskent', reg, now);
    expect(n.length, 2); // Gölbaşı (2 mahalle birleşir) + Elmadağ; tanınmayan ilçe atlanır
    final g = n.firstWhere((x) => x.district == 'Gölbaşı');
    expect(g.plaka, 6);
    expect(g.neighborhoods, ['EYMİR', 'ÖRENCİK']);
    expect(g.start, DateTime(2026, 11, 4, 9, 30));
    expect(g.end, DateTime(2026, 11, 4, 17, 30));
    expect(g.source, 'Başkent EDAŞ');
    expect(g.detail, contains('Hizmet Alım Çalışması'));
    expect(g.planned, isTrue);
  });

  test('kendi okuyucusu olan şirketin (UEDAŞ) kaydı EPİAŞ kaynağına girmez', () {
    expect(epiasNotices(rows, 'baskent', reg, now).where((x) => x.plaka == 16), isEmpty);
    expect(epiasKurumlar, isNot(contains('uedas')));
    final s = epiasNotices(rows, 'sedas', reg, now).single;
    expect(s.plaka, 41);
    expect(s.district, 'Gebze');
  });
}
