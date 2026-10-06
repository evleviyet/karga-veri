// Tüm kaynakları okur ve statik siteyi üretir:
//   dart run bin/build_feed.dart [çıktı-klasörü=site] [--legacy data]
// --legacy <klasör>: eski uygulama sürümlerinin okuduğu Ankara dosyalarını
//   depodaki klasöre eşitler (yalnızca değiştiğinde).
// ONLY=<önek> ortam değişkeni yalnızca o önekle başlayan kaynakları çalıştırır
// (ör. ONLY=ck- ya da ONLY=valilik-ankara).
import 'dart:io';

import 'package:karga_feed/build.dart';
import 'package:karga_feed/models.dart';
import 'package:karga_feed/net.dart';
import 'package:karga_feed/registry.dart';
import 'package:karga_feed/sources.dart';

Future<void> main(List<String> args) async {
  final legacyAt = args.indexOf('--legacy');
  final legacy = legacyAt >= 0 && legacyAt + 1 < args.length
      ? Directory(args[legacyAt + 1])
      : null;
  final positional = [
    for (var i = 0; i < args.length; i++)
      if (legacyAt < 0 || (i != legacyAt && i != legacyAt + 1)) args[i]
  ];
  final out = Directory(positional.isNotEmpty ? positional.first : 'site');
  final reg = Registry.load();
  final net = Net();
  final ctx = Ctx(net, reg, nowTr(), Directory('.cache'));

  var sources = allSources(reg);
  final only = Platform.environment['ONLY'];
  if (only != null && only.isNotEmpty) {
    sources = sources.where((s) => s.id.startsWith(only)).toList();
  }

  final result = await runSources(ctx, sources);
  writeSite(result, reg, out);
  net.client.close();
  if (legacy != null && syncLegacy(out, legacy, result.generatedUtc)) {
    stdout.writeln('Eski sürüm dosyaları güncellendi: ${legacy.path}');
  }

  final ok = result.runs.where((r) => r.status == 'ok').length;
  stdout.writeln('Bitti: $ok/${result.runs.length} kaynak okundu -> ${out.path}');
}
