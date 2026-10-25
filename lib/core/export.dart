import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// The collections Settings › "ייצוא נתונים" writes out. A new app lists its own.
const exportedCollections = ['items'];

/// One JSON with everything, plus a CSV per collection for a spreadsheet.
/// Android and the web: the share sheet (the web downloads). Windows: a save
/// dialog per file.
Future<int> exportData() async {
  final db = FirebaseFirestore.instance;
  final all = <String, List<Map<String, dynamic>>>{};
  for (final name in exportedCollections) {
    final snap = await db.collection(name).get();
    all[name] = [for (final d in snap.docs) {'id': d.id, ...d.data()}];
  }
  final stamp = DateTime.now().toIso8601String().substring(0, 10);
  final files = <XFile>[
    _file('export-$stamp.json',
        JsonEncoder.withIndent('  ', _plain).convert(all), 'application/json'),
    for (final e in all.entries)
      _file('${e.key}-$stamp.csv', toCsv(e.value), 'text/csv'),
  ];
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    for (final f in files) {
      final where = await getSaveLocation(suggestedName: f.name);
      if (where == null) continue;
      await f.saveTo(where.path);
    }
  } else {
    await SharePlus.instance.share(ShareParams(files: files, title: 'ייצוא נתונים'));
  }
  return all.values.fold<int>(0, (n, rows) => n + rows.length);
}

Object? _plain(Object? v) => v is Timestamp ? v.toDate().toIso8601String() : '$v';

XFile _file(String name, String text, String mime) =>
    // BOM so Excel reads Hebrew CSV as UTF-8.
    XFile.fromData(Uint8List.fromList(utf8.encode('﻿$text')),
        name: name, mimeType: mime);

/// Rows → CSV with every key seen as a column. Timestamps become ISO dates.
String toCsv(List<Map<String, dynamic>> rows) {
  final keys = <String>{for (final r in rows) ...r.keys}.toList();
  String cell(Object? v) {
    final s = switch (v) {
      null => '',
      Timestamp() => v.toDate().toIso8601String(),
      _ => '$v',
    };
    return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  return [
    keys.map(cell).join(','),
    for (final r in rows) keys.map((k) => cell(r[k])).join(','),
  ].join('\r\n');
}
