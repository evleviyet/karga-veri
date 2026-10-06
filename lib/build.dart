import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'net.dart';
import 'registry.dart';
import 'sources.dart';

/// Bir kaynağın bu turdaki sonucu.
class SourceRun {
  final Source source;
  final String status; // ok | degraded
  final List<Notice> notices;
  final String? error;

  /// Kaynak okunamadı; son başarılı okumanın kayıtları kullanıldı.
  final bool stale;
  final int ms;

  SourceRun(this.source, this.status, this.notices,
      {this.error, this.stale = false, this.ms = 0});
}

class FeedResult {
  final DateTime generatedUtc;
  final List<SourceRun> runs;

  /// İl -> kayıtlar (tekrarsız, ilçe adları kayıt defterine göre düzeltilmiş).
  final Map<int, List<Notice>> byPlaka;

  /// İl -> kaynak -> o ildeki kayıt sayısı.
  final Map<int, Map<String, int>> counts;

  FeedResult(this.generatedUtc, this.runs, this.byPlaka, this.counts);
}

/// Son başarılı okuma bu kadar eskiyse artık kullanılmaz.
const lastGoodMaxAge = Duration(hours: 6);

Future<FeedResult> runSources(Ctx ctx, List<Source> sources,
    {int concurrency = 6, DateTime? nowUtc}) async {
  final generated = nowUtc ?? DateTime.now().toUtc();
  final runs = await pooled(
      [for (final s in sources) () => _runOne(ctx, s, generated)], concurrency);

  final byPlaka = <int, Map<String, Notice>>{};
  final counts = <int, Map<String, int>>{};
  for (final r in runs) {
    for (final n in r.notices) {
      final plaka =
          n.plaka ?? (r.source.plakas.length == 1 ? r.source.plakas.single : null);
      final il = ctx.reg.byPlaka(plaka);
      if (il == null) continue;
      final d = il.ilce(n.district);
      final routed = n.copyWith(
        plaka: il.plaka,
        district: d?.ad,
        id: n.id ??
            '${r.source.id}:${stableId('${n.district}|${n.start}|${n.title}|${n.detail}')}',
      );
      final bucket = byPlaka[il.plaka] ??= {};
      if (bucket.containsKey(routed.id)) continue;
      bucket[routed.id!] = routed;
      final c = counts[il.plaka] ??= {};
      c[r.source.id] = (c[r.source.id] ?? 0) + 1;
    }
  }
  return FeedResult(
    generated,
    runs,
    {
      for (final e in byPlaka.entries)
        e.key: e.value.values.toList()..sort(_byTime),
    },
    counts,
  );
}

int _byTime(Notice a, Notice b) {
  final ta = a.start ?? a.end, tb = b.start ?? b.end;
  if (ta == null || tb == null) return (ta == null ? 1 : 0) - (tb == null ? 1 : 0);
  return ta.compareTo(tb);
}

Future<SourceRun> _runOne(Ctx ctx, Source s, DateTime nowUtc) async {
  final sw = Stopwatch()..start();
  final last = File('${ctx.cacheDir.path}/last/${s.id}.json');
  try {
    final notices = await s.run(ctx).timeout(const Duration(minutes: 4));
    last.parent.createSync(recursive: true);
    last.writeAsStringSync(jsonEncode({
      'at': nowUtc.toIso8601String(),
      'notices': [
        for (final n in notices) {...n.toJsonV2(), 'plaka': n.plaka}
      ],
    }));
    stdout.writeln('${s.id}: ok (${notices.length}) ${sw.elapsedMilliseconds}ms');
    return SourceRun(s, 'ok', notices, ms: sw.elapsedMilliseconds);
  } catch (e) {
    final error = '$e'.split('\n').first;
    stdout.writeln('${s.id}: DEGRADED $error');
    // Son başarılı okuma yakınsa onu yayımlamaya devam et (bitmişleri at).
    var kept = <Notice>[];
    try {
      if (last.existsSync()) {
        final j = jsonDecode(last.readAsStringSync()) as Map<String, dynamic>;
        final at = DateTime.tryParse('${j['at']}');
        if (at != null && nowUtc.difference(at) <= lastGoodMaxAge) {
          kept = [
            for (final n in (j['notices'] as List).cast<Map<String, dynamic>>())
              Notice.fromJsonV2(n, plaka: n['plaka'] as int?),
          ].where((n) => n.end == null || n.end!.isAfter(ctx.now)).toList();
        }
      }
    } catch (_) {
      kept = [];
    }
    return SourceRun(s, 'degraded', kept,
        error: error, stale: kept.isNotEmpty, ms: sw.elapsedMilliseconds);
  }
}

// ---------------------------------------------------------------------------
// Site çıktısı
// ---------------------------------------------------------------------------

void _write(Directory out, String path, Object json, {bool pretty = false}) {
  final f = File('${out.path}/$path');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(pretty
      ? '${const JsonEncoder.withIndent('  ').convert(json)}\n'
      : jsonEncode(json));
}

Map<String, dynamic> _kurumJson(Registry reg, String? id) {
  final k = id == null ? null : reg.kurumlar[id];
  return k == null ? {} : {'id': id, ...k.toJson()};
}

/// İl dosyası: uygulamanın tek istekte okuduğu her şey.
Map<String, dynamic> ilBundle(FeedResult r, Registry reg, Il il) {
  final runs = r.runs.where((x) => x.source.plakas.contains(il.plaka)).toList();
  final counts = r.counts[il.plaka] ?? const {};
  return {
    'schema': 2,
    'generatedAt': r.generatedUtc.toIso8601String(),
    'il': {'plaka': il.plaka, 'ad': il.ad},
    'kurumlar': {
      'elektrik': _kurumJson(reg, il.elektrik),
      if (il.elektrikIlce.isNotEmpty)
        'elektrikIlce': {
          for (final d in il.ilceler)
            if (il.elektrikIlce[d.key] != null)
              d.ad: _kurumJson(reg, il.elektrikIlce[d.key]),
        },
      if (il.su != null) 'su': _kurumJson(reg, il.su),
      'valilik': il.valilikUrl,
      'belediye': il.belediye,
    },
    'sources': [
      for (final x in runs)
        {
          'id': x.source.id,
          'name': x.source.name,
          'kind': x.source.kind.name,
          if (x.source.kurum != null) 'kurum': x.source.kurum,
          'status': x.status,
          'count': counts[x.source.id] ?? 0,
          if (x.stale) 'stale': true,
        },
    ],
    'notices': [for (final n in r.byPlaka[il.plaka] ?? const <Notice>[]) n.toJsonV2()],
  };
}

void writeSite(FeedResult r, Registry reg, Directory out) {
  final at = r.generatedUtc.toIso8601String();

  // --- Sürüm 2 ---
  for (final il in reg.iller) {
    _write(out, 'data/v2/il/${il.key}.json', ilBundle(r, reg, il));
  }
  _write(out, 'data/v2/registry.json', reg.toAppJson());
  final live = <String>{
    for (final x in r.runs)
      if (x.source.kurum != null && x.status == 'ok') x.source.kurum!,
  };
  _write(
      out,
      'data/v2/meta.json',
      {
        'schema': 2,
        'generatedAt': at,
        'kapsam': {
          'il': reg.iller.length,
          'ilce': reg.iller.fold<int>(0, (a, il) => a + il.ilceler.length),
          'canliKurumlar': live.toList()..sort(),
        },
        'sources': {
          for (final x in r.runs)
            x.source.id: {
              'name': x.source.name,
              'kind': x.source.kind.name,
              if (x.source.kurum != null) 'kurum': x.source.kurum,
              'iller': x.source.plakas,
              'status': x.status,
              'count': x.notices.length,
              'ms': x.ms,
              if (x.error != null) 'error': x.error,
              if (x.stale) 'stale': true,
            },
        },
      },
      pretty: true);

  // --- Sürüm 1 (eski uygulama sürümleri için Ankara dosyaları) ---
  SourceRun? run(String id) {
    for (final x in r.runs) {
      if (x.source.id == id) return x;
    }
    return null;
  }

  final v1 = {
    'ankara-aski': run('aski'),
    'ankara-abb': run('abb'),
    'ankara-valilik': run('valilik-ankara'),
  };
  for (final e in v1.entries) {
    final x = e.value;
    if (x == null) continue;
    final notices = e.key == 'ankara-valilik'
        ? [
            for (final n in x.notices)
              if (_isSchoolBreak(normTr(n.title)))
                Notice(
                    kind: NoticeKind.general,
                    source: 'Ankara Valiliği',
                    title: n.title,
                    detail: n.url ?? '',
                    start: n.start)
          ]
        : x.notices;
    _write(
        out,
        'data/ankara/${e.key.substring(7)}.json',
        {
          'schema': 1,
          'source': e.key,
          'notices': [for (final n in notices) n.toJson()],
        },
        pretty: true);
  }
  _write(
      out,
      'data/meta.json',
      {
        'schema': 1,
        'generatedAt': at,
        'sources': {
          for (final e in v1.entries)
            if (e.value != null)
              e.key: e.value!.status == 'ok'
                  ? {'status': 'ok', 'count': e.value!.notices.length}
                  : {'status': 'degraded', 'error': e.value!.error},
        },
      },
      pretty: true);

  File('${out.path}/index.html')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(statusPage(r, reg));
  File('${out.path}/.nojekyll').writeAsStringSync('');
}

bool _isSchoolBreak(String t) =>
    t.contains('tatil') &&
    (t.contains('okul') || t.contains('egitim') || t.contains('ogretim'));

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// İnsanların okuyacağı durum sayfası (index.html).
String statusPage(FeedResult r, Registry reg) {
  final tr = toTrNaive(r.generatedUtc);
  String two(int n) => n.toString().padLeft(2, '0');
  final when =
      '${two(tr.day)}.${two(tr.month)}.${tr.year} ${two(tr.hour)}:${two(tr.minute)}';
  final ok = r.runs.where((x) => x.status == 'ok').length;
  final total = r.runs.fold<int>(0, (a, x) => a + x.notices.length);
  final kinds = {
    'weather': 'Hava uyarısı',
    'general': 'Duyuru',
    'water': 'Su',
    'power': 'Elektrik',
    'gas': 'Doğalgaz',
  };
  final rows = [...r.runs]..sort((a, b) {
      final k = a.source.kind.index.compareTo(b.source.kind.index);
      return k != 0 ? k : a.source.name.compareTo(b.source.name);
    });
  final liveKurum = {
    for (final x in r.runs)
      if (x.source.kurum != null) x.source.kurum!,
  };
  final elektrik = reg.kurumlar.values.where((k) => k.tur == 'elektrik').toList();
  final su = reg.kurumlar.values.where((k) => k.tur == 'su').toList();
  final sb = StringBuffer()
    ..writeln('<!doctype html><html lang="tr"><head><meta charset="utf-8">')
    ..writeln('<meta name="viewport" content="width=device-width,initial-scale=1">')
    ..writeln('<title>Karga Veri Durumu</title><style>')
    ..writeln(':root{--bg:#f6f4ef;--fg:#1d1b18;--mut:#6b655c;--ok:#2f7d4f;--bad:#b3412e;--line:#e2ddd3;--card:#fff}')
    ..writeln('@media (prefers-color-scheme:dark){:root{--bg:#0b0d13;--fg:#ece8df;--mut:#9a9488;--ok:#5fbf86;--bad:#e2735f;--line:#262a33;--card:#141821}}')
    ..writeln('body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}')
    ..writeln('main{max-width:860px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 4px}')
    ..writeln('p{color:var(--mut);margin:0 0 16px}table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}')
    ..writeln('td,th{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;font-size:14px}th{color:var(--mut);font-weight:600}')
    ..writeln('.ok{color:var(--ok)}.bad{color:var(--bad)}.num{text-align:right;font-variant-numeric:tabular-nums}h2{font-size:16px;margin:24px 0 8px}')
    ..writeln('.chips span{display:inline-block;border:1px solid var(--line);border-radius:99px;padding:2px 10px;margin:0 6px 6px 0;font-size:13px;background:var(--card)}')
    ..writeln('.chips .on{border-color:var(--ok);color:var(--ok)}</style></head><body><main>')
    ..writeln('<h1>Karga veri servisi</h1>')
    ..writeln('<p>Son üretim: $when (TSİ) · $ok/${r.runs.length} kaynak okundu · $total kayıt · '
        '${reg.iller.length} il, ${reg.iller.fold<int>(0, (a, il) => a + il.ilceler.length)} ilçe</p>')
    ..writeln('<h2>Elektrik dağıtım şirketleri</h2><div class="chips">');
  for (final k in elektrik) {
    sb.writeln('<span class="${liveKurum.contains(k.id) ? 'on' : ''}">${_esc(k.kisa)}</span>');
  }
  sb.writeln('</div><h2>Büyükşehir su idareleri</h2><div class="chips">');
  for (final k in su) {
    sb.writeln('<span class="${liveKurum.contains(k.id) ? 'on' : ''}">${_esc(k.kisa)} · ${_esc(k.ad.split(' ').first)}</span>');
  }
  sb
    ..writeln('</div><p>Yeşil: kesintileri feed okuyor. MEDAŞ ve DESKİ\'yi uygulama Türkiye\'den kendisi okur; '
        'diğerlerinde uygulama kurumun resmi sayfasını ve arıza hattını gösterir.</p>')
    ..writeln('<h2>Kaynaklar</h2><table><tr><th>Kaynak</th><th>Tür</th><th>Durum</th><th class="num">Kayıt</th></tr>');
  for (final x in rows) {
    final cls = x.status == 'ok' ? 'ok' : 'bad';
    final label = x.status == 'ok'
        ? 'okundu'
        : x.stale
            ? 'okunamadı (son veri)'
            : 'okunamadı';
    sb.writeln('<tr><td>${_esc(x.source.name)}</td><td>${kinds[x.source.kind.name]}</td>'
        '<td class="$cls" title="${_esc(x.error ?? '')}">$label</td><td class="num">${x.notices.length}</td></tr>');
  }
  sb.writeln('</table><p style="margin-top:16px">JSON: <code>data/v2/il/&lt;il&gt;.json</code>, '
      '<code>data/v2/meta.json</code>, <code>data/v2/registry.json</code></p></main></body></html>');
  return sb.toString();
}

/// Eski uygulama sürümlerinin okuduğu dosyaları depodaki data/ klasörüne
/// eşitler (değişmeyen dosyaya dokunmaz). meta.json yalnızca durum değişince
/// ya da [heartbeat] dolunca yenilenir: gereksiz commit oluşmaz.
/// Değişiklik olduysa true döner.
bool syncLegacy(Directory site, Directory repoData, DateTime nowUtc,
    {Duration heartbeat = const Duration(hours: 3)}) {
  var changed = false;
  final src = Directory('${site.path}/data/ankara');
  if (src.existsSync()) {
    for (final f in src.listSync().whereType<File>()) {
      final dst = File('${repoData.path}/ankara/${f.uri.pathSegments.last}');
      final content = f.readAsStringSync();
      if (dst.existsSync() && dst.readAsStringSync() == content) continue;
      dst.parent.createSync(recursive: true);
      dst.writeAsStringSync(content);
      changed = true;
    }
  }
  final metaSrc = File('${site.path}/data/meta.json');
  if (!metaSrc.existsSync()) return changed;
  final next = jsonDecode(metaSrc.readAsStringSync()) as Map<String, dynamic>;
  final metaDst = File('${repoData.path}/meta.json');
  Map<String, dynamic>? prev;
  try {
    if (metaDst.existsSync()) {
      prev = jsonDecode(metaDst.readAsStringSync()) as Map<String, dynamic>;
    }
  } catch (_) {
    prev = null;
  }
  final prevAt = DateTime.tryParse('${prev?['generatedAt']}');
  final sameStatus = prev != null &&
      jsonEncode(prev['sources']) == jsonEncode(next['sources']) &&
      prev['schema'] == next['schema'];
  final stale = prevAt == null || nowUtc.difference(prevAt) >= heartbeat;
  if (changed || !sameStatus || stale) {
    metaDst.parent.createSync(recursive: true);
    metaDst.writeAsStringSync(metaSrc.readAsStringSync());
    changed = true;
  }
  return changed;
}
