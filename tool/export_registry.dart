// Uygulamanın gömülü kayıt defterini üretir:
//   dart run tool/export_registry.dart ../lib/geo/turkiye_data.dart
// Uzantı .json ise yalın JSON yazar.
import 'dart:convert';
import 'dart:io';

import 'package:karga_feed/registry.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('kullanım: dart run tool/export_registry.dart <çıktı>');
    exit(64);
  }
  final json = jsonEncode(Registry.load().toAppJson());
  if (json.contains("'''")) throw StateError('beklenmeyen üç tırnak');
  final out = File(args.first);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(args.first.endsWith('.json')
      ? json
      : '// ÜRETİLMİŞ DOSYA — elle değiştirme.\n'
          '// Kaynak: feed-repo/registry (dart run tool/export_registry.dart).\n'
          '// 81 il, 973 ilçe ve bu yerlere hizmet veren kurumlar.\n'
          "const String turkiyeJson = r'''$json''';\n");
  stdout.writeln('${out.path}: ${out.lengthSync()} bayt');
}
