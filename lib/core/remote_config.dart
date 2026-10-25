import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'app_info.dart';

/// Two Firestore documents edited by hand in the console, no redeploy:
///
/// `config/app` (anyone may read):   {minVersion: "1.2.0", message: "..."}
/// `config/access` (only allowed):   {emails: [...], earlyUsers: [...]}
///
/// The rules read `config/access.emails` too, so it is the one allowlist.
class RemoteConfig extends ChangeNotifier {
  RemoteConfig._();
  static final instance = RemoteConfig._();

  String minVersion = '0.0.0';
  String message = '';

  /// Gets releases first (patient zero); everyone else waits for the
  /// prerelease to be promoted.
  bool earlyUser = false;

  /// Below [minVersion]: the app shows only the update screen and does not
  /// sync, so an old build never writes data in a shape it doesn't know.
  bool get tooOld => isNewer(minVersion, AppInfo.version);

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  /// Live, so raising minVersion reaches open apps at once.
  void listen() {
    _sub ??= FirebaseFirestore.instance.doc('config/app').snapshots().listen(
      (doc) {
        minVersion = '${doc.data()?['minVersion'] ?? '0.0.0'}';
        message = '${doc.data()?['message'] ?? ''}';
        notifyListeners();
      },
      onError: (_) {}, // offline or no doc: keep the last known values
    );
  }

  /// Whether [email] may use the app. Reading config/access succeeds only for
  /// allowed accounts, so the rules decide, not this code.
  Future<bool> checkAccess(String? email) async {
    try {
      final doc = await FirebaseFirestore.instance
          .doc('config/access')
          .get()
          .timeout(const Duration(seconds: 15));
      final early = (doc.data()?['earlyUsers'] as List?) ?? const [];
      earlyUser = early.contains(email);
      notifyListeners();
      return true;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return false;
      rethrow;
    }
  }
}
