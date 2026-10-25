import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config.dart';
import 'errors.dart';
import 'update.dart';

/// Pushes come from the home server (Spark has no Cloud Functions): it reads
/// the tokens in users/{uid}.fcmTokens and the per-type switches in
/// users/{uid}.notify. Android and the web get pushes; Windows has no FCM,
/// so it shows only the app's own local notifications.
///
/// The types every app starts with. A new app adds its own.
const notificationTypes = <String, String>{
  'items': 'כשמישהו אחר מוסיף משהו',
  'updates': 'כשיש גרסה חדשה',
  'morning': 'סיכום בוקר',
};

final _local = FlutterLocalNotificationsPlugin();
bool _started = false;
const _updateId = 9001;

bool get _hasFcm =>
    kIsWeb || defaultTargetPlatform == TargetPlatform.android;

DocumentReference<Map<String, dynamic>> _me() => FirebaseFirestore.instance
    .doc('users/${FirebaseAuth.instance.currentUser!.uid}');

Future<void> _register(String token) =>
    _me().set({'fcmTokens': FieldValue.arrayUnion([token])},
        SetOptions(merge: true));

/// Called once the user is signed in and let in. [onOpen] gets the data of a
/// tapped notification (say {"route": "/item", "id": "..."}).
Future<void> setUpNotifications(
  ScaffoldMessengerState messenger, {
  void Function(Map<String, dynamic> data)? onOpen,
}) async {
  if (_started) return;
  _started = true;

  if (!kIsWeb) {
    await _local.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: AppConfig.name,
          appUserModelId: 'com.alex99ka.printstudio',
          guid: 'dcfe0f4f-27df-4ef4-8827-48bb2c446f86',
        ),
      ),
    );
    AppUpdater.instance?.addListener(_showUpdateProgress);
  }
  if (!_hasFcm) return;

  final fcm = FirebaseMessaging.instance;
  fcm.onTokenRefresh.listen((t) => _register(t).ignore());
  // In the app already: the system shows nothing, so the app does.
  FirebaseMessaging.onMessage.listen((m) {
    final n = m.notification;
    if (n == null) return;
    messenger.showSnackBar(SnackBar(
      persist: false,
      content: Text('${n.title}\n${n.body ?? ''}'),
      action: onOpen == null
          ? null
          : SnackBarAction(label: 'פתיחה', onPressed: () => onOpen(m.data)),
    ));
  });
  if (kIsWeb) {
    // Allowed earlier from Settings: keep this browser registered.
    try {
      final s = await fcm.getNotificationSettings();
      if (s.authorizationStatus == AuthorizationStatus.authorized) {
        final t = await fcm.getToken();
        if (t != null) await _register(t);
      }
    } catch (_) {}
    return;
  }
  if (onOpen != null) {
    FirebaseMessaging.onMessageOpenedApp.listen((m) => onOpen(m.data));
    final first = await fcm.getInitialMessage();
    if (first != null) onOpen(first.data);
  }
  try {
    await fcm.requestPermission(); // Android 13+ asks once
    final t = await fcm.getToken();
    if (t != null) await _register(t);
  } catch (_) {
    // Offline: registered next launch or on token refresh.
  }
}

/// Settings › "התראות במכשיר הזה" on the web. Safari asks only straight from
/// a tap; on an iPad only in the Home Screen app (iOS 16.4+).
Future<String> enableWebNotifications() async {
  try {
    final s = await FirebaseMessaging.instance.requestPermission();
    if (s.authorizationStatus != AuthorizationStatus.authorized) {
      return errorText(Errors.notificationsBlocked);
    }
    final t = await FirebaseMessaging.instance.getToken();
    if (t != null) await _register(t);
    return 'ההתראות פעילות במכשיר הזה.';
  } catch (_) {
    return errorText(Errors.notificationsNeedHomeScreen);
  }
}

/// The per-type switches, default on.
Stream<Map<String, bool>> notificationPrefs() => _me().snapshots().map((d) {
      final saved = (d.data()?['notify'] as Map?) ?? const {};
      return {
        for (final k in notificationTypes.keys) k: saved[k] as bool? ?? true,
      };
    });

Future<void> setNotificationPref(String type, bool on) =>
    _me().set({'notify': {type: on}}, SetOptions(merge: true));

/// The background update download, shown like any download on the phone.
double? _shownProgress;
void _showUpdateProgress() {
  final u = AppUpdater.instance!;
  final p = u.progress;
  if (p != null) {
    // Every 5% is enough; each call redraws the notification.
    if (_shownProgress != null && (p - _shownProgress!).abs() < 0.05 && p < 1) {
      return;
    }
    _shownProgress = p;
    _local
        .show(
          id: _updateId,
          title: 'מוריד עדכון ${u.available?.version ?? ''}',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'updates', 'עדכונים',
              importance: Importance.low,
              onlyAlertOnce: true,
              showProgress: true,
              maxProgress: 100,
              progress: (p * 100).round(),
              ongoing: true,
            ),
          ),
        )
        .ignore();
  } else if (_shownProgress != null) {
    _shownProgress = null;
    _local.cancel(id: _updateId).ignore();
    if (u.ready) {
      _local
          .show(
            id: _updateId,
            title: 'גרסה ${u.available!.version} מוכנה',
            body: u.installsByItself
                ? 'תותקן לבד כשתצאו מהאפליקציה'
                : 'פותחים את האפליקציה ולוחצים "עדכון"',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails('updates', 'עדכונים',
                  importance: Importance.low),
              windows: WindowsNotificationDetails(),
            ),
          )
          .ignore();
    }
  }
}
