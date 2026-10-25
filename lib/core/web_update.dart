import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_info.dart';
import 'reload_stub.dart' if (dart.library.js_interop) 'reload_web.dart';

/// The web (and the iPad Home Screen app) updates by reloading: Hosting
/// serves index.html and the bootstrap with no-cache (firebase.json), and
/// every build writes version.json. A newer one there means a reload brings
/// the new build.
class WebUpdate extends ChangeNotifier {
  WebUpdate._();
  static final instance = WebUpdate._();

  String? available;
  DateTime? lastChecked;

  Future<void> check() async {
    if (!kIsWeb) return;
    try {
      final res = await http
          .get(Uri.parse('version.json?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 15));
      final v = (jsonDecode(res.body) as Map)['version'] as String?;
      available = v != null && isNewer(v, AppInfo.version) ? v : null;
    } catch (_) {
      // Offline: the next check tries again.
    } finally {
      lastChecked = DateTime.now();
      notifyListeners();
    }
  }

  void apply() => reloadPage();
}
