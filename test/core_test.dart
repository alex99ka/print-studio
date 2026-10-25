import 'dart:io';

import 'package:print_studio/core/app_info.dart';
import 'package:print_studio/core/errors.dart';
import 'package:print_studio/core/export.dart';
import 'package:print_studio/core/tour.dart';
import 'package:print_studio/core/update.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> rel(String tag, {bool pre = false, bool draft = false}) =>
    {'tag_name': tag, 'prerelease': pre, 'draft': draft};

void main() {
  group('errors', () {
    test('every code is unique and letter-first', () {
      final codes = Errors.all.map((e) => e.code).toList();
      expect(codes.toSet().length, codes.length);
      for (final c in codes) {
        expect(c, matches(RegExp(r'^[A-Z][0-9]+$')), reason: c);
      }
    });

    test('text says what failed, why, what to do, and the code', () {
      expect(errorText(Errors.noConnection, 'השמירה נכשלה'),
          'השמירה נכשלה: אין חיבור לאינטרנט. בודקים את החיבור ומנסים שוב. (קוד N1)');
    });

    test('server statuses map to codes', () {
      expect(classify(const ServerException(503, '')).code, 'S1');
      expect(classify(const ServerException(403, '')).code, 'A1');
      expect(classify(Exception('boom')).code, 'X1');
    });
  });

  group('versions', () {
    test('isNewer', () {
      expect(isNewer('1.10.0', '1.9.9'), isTrue);
      expect(isNewer('v2.0.0', '1.99.99'), isTrue);
      expect(isNewer('1.2.3+7', '1.2.3'), isFalse);
      expect(isNewer('1.2.3', '1.2.3'), isFalse);
    });

    test('previousVersion isolates this version in whatsNew', () {
      AppInfo.version = '1.4.0';
      expect(AppInfo.previousVersion(), '1.3.999');
      AppInfo.version = '1.4.2';
      expect(AppInfo.previousVersion(), '1.4.1');
      AppInfo.version = '2.0.0';
      expect(AppInfo.previousVersion(), '1.999.999');
    });
  });

  group('updates', () {
    final releases = [
      rel('1.3.0', pre: true),
      rel('1.2.0'),
      rel('1.4.0', draft: true),
      rel('1.1.0'),
    ];

    test('everyone gets the newest full release', () {
      expect(pickRelease(releases, early: false)!['tag_name'], '1.2.0');
    });

    test('early users (patient zero) get the prerelease first', () {
      expect(pickRelease(releases, early: true)!['tag_name'], '1.3.0');
    });

    test('drafts are never offered', () {
      expect(pickRelease([rel('9.0.0', draft: true)], early: true), isNull);
    });

    test('SHA256SUMS lines are matched by exact asset name', () {
      const sums = 'abc123  app-1.2.0.apk\nDEF456 *app-setup-1.2.0.exe\n';
      expect(digestFromSums(sums, 'app-1.2.0.apk'), 'abc123');
      expect(digestFromSums(sums, 'app-setup-1.2.0.exe'), 'def456');
      expect(digestFromSums(sums, 'app-1.2.0.ap'), isNull);
    });

    test('the right asset per platform', () {
      expect(assetFor('android', 'app-1.0.0.apk'), isTrue);
      expect(assetFor('windows', 'app-setup-1.0.0.exe'), isTrue);
      expect(assetFor('windows', 'app-1.0.0.apk'), isFalse);
    });
  });

  test('CSV quotes what needs quoting and keeps every column', () {
    final csv = toCsv([
      {'id': '1', 'title': 'חלב, 3%'},
      {'id': '2', 'note': 'אמר "כן"'},
    ]);
    expect(csv.split('\r\n'), [
      'id,title,note',
      '1,"חלב, 3%",',
      '2,,"אמר ""כן"""',
    ]);
  });

  // Source checks: cheap guards for rules a reviewer would otherwise police.
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('colours are written only in the token file', () {
    for (final f in sources) {
      if (f.path.replaceAll('\\', '/').endsWith('ui/theme.dart')) continue;
      expect(f.readAsStringSync().contains(RegExp(r'Color\(0x|Colors\.')), isFalse,
          reason: '${f.path}: use AppTokens or Theme.of(context)');
    }
  });

  test('every walkthrough step points at a TourTarget that exists', () {
    final ids = <String>{
      for (final f in sources)
        ...RegExp(r"TourTarget\(\s*'([^']+)'")
            .allMatches(f.readAsStringSync())
            .map((m) => m.group(1)!),
    };
    for (final step in fullTour) {
      if (step.target != null) {
        expect(ids, contains(step.target), reason: step.title);
      }
    }
  });
}
