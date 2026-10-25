import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// This build's version, read once at startup.
abstract final class AppInfo {
  static String version = '0.0.0';
  static String build = '0';

  static String get versionLabel => '$version ($build)';

  /// 'android', 'windows' or 'web': the release asset and update path.
  static String get platform => kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.android => 'android',
          TargetPlatform.windows => 'windows',
          _ => 'other',
        };

  /// The version just before this one's MINOR/PATCH ("1.4.0" → "1.3.999"),
  /// so whatsNew() returns exactly this version's steps.
  static String previousVersion() {
    final p = version.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    while (p.length < 3) {
      p.add(0);
    }
    if (p[2] > 0) return '${p[0]}.${p[1]}.${p[2] - 1}';
    if (p[1] > 0) return '${p[0]}.${p[1] - 1}.999';
    return p[0] > 0 ? '${p[0] - 1}.999.999' : '0.0.0';
  }

  static Future<void> load() async {
    try {
      final p = await PackageInfo.fromPlatform();
      version = p.version;
      build = p.buildNumber;
    } catch (_) {} // tests: keep the defaults
  }
}

/// True when [a] is a newer MAJOR.MINOR.PATCH than [b]. Tolerates a leading
/// "v" and a "+build" suffix.
bool isNewer(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^v'), '')
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
