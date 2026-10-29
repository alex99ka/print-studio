import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config.dart';
import 'errors.dart';
import 'server.dart';
import 'update.dart';

/// Pushes come from the home server (Spark has no Cloud Functions): it reads
/// the tokens in users/{uid}.fcmTokens and the per-type switches in
/// users/{uid}.notify. Android and the web get pushes; Windows has no FCM,
/// so it shows only the app's own local notifications.
///
/// The types every app starts with. A new app adds its own.
const notificationTypes = <String, String>{
  'client': 'כשלקוח מעיר, מאשר או שולח רשימת אורחים',
  'production': 'כש-Gift Factory מסיים פלטה או כשיחידות נכשלות',
  'deadlines': 'כשתאריך יעד מתקרב (כשצריך להתחיל להדפיס, יום לפני, ביום עצמו)',
  'updates': 'כשיש גרסה חדשה',
};

final _local = FlutterLocalNotificationsPlugin();
bool _started = false;
const _updateId = 9001;
DateTime _lastTouch = DateTime(2000);
String? _token;

/// Each push is seen once: when the app is opened or used on any device, the
/// Pi takes that push off the user's other devices (an Android phone gets a
/// silent "dismiss" message with the pushes' tags; see server jobs.seen).
Future<void> markSeen() async {
  if (!hasServer || FirebaseAuth.instance.currentUser == null) return;
  try {
    await server('POST', '/pushes/seen', {
      'token': _token ?? '',
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    });
  } catch (_) {
    // Offline: the next open clears them.
  }
}

/// Removes the pushes a "dismiss" message names (FCM shows each as id 0 with its tag).
Future<void> _dismiss(RemoteMessage m) async {
  for (final tag in '${m.data['dismiss'] ?? ''}'.split(',').where((t) => t.isNotEmpty)) {
    await _local.cancel(id: 0, tag: tag);
  }
}

/// Android, app in the background or closed: a "dismiss" message from the Pi.
/// Registered in main() before runApp.
@pragma('vm:entry-point')
Future<void> pushInBackground(RemoteMessage m) async {
  if (m.data['dismiss'] == null) return;
  // A fresh isolate: the plugin isn't set up here yet.
  await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  await _dismiss(m);
}

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
  // Opening the app (or coming back to it) on any device, the PC included, is seeing its pushes.
  AppLifecycleListener(onResume: () => markSeen().ignore());
  GestureBinding.instance.pointerRouter.addGlobalRoute((_) => _lastTouch = DateTime.now());
  HardwareKeyboard.instance.addHandler((_) {
    _lastTouch = DateTime.now();
    return false;
  });
  if (!_hasFcm) {
    markSeen().ignore();
    return;
  }

  final fcm = FirebaseMessaging.instance;
  fcm.onTokenRefresh.listen((t) {
    _token = t;
    _register(t).ignore();
  });
  // In the app already: the system shows nothing, so the app does.
  FirebaseMessaging.onMessage.listen((m) {
    if (m.data['dismiss'] != null) {
      _dismiss(m).ignore();
      return;
    }
    final n = m.notification;
    if (n == null) return;
    // Someone is using the app here right now, so it's seen: off the other devices.
    if (DateTime.now().difference(_lastTouch) < const Duration(minutes: 1)) markSeen().ignore();
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
        _token = await fcm.getToken();
        if (_token != null) await _register(_token!);
      }
    } catch (_) {}
    markSeen().ignore();
    return;
  }
  if (onOpen != null) {
    FirebaseMessaging.onMessageOpenedApp.listen((m) => onOpen(m.data));
    final first = await fcm.getInitialMessage();
    if (first != null) onOpen(first.data);
  }
  try {
    await fcm.requestPermission(); // Android 13+ asks once
    _token = await fcm.getToken();
    if (_token != null) await _register(_token!);
  } catch (_) {
    // Offline: registered next launch or on token refresh.
  }
  markSeen().ignore(); // opened, maybe from a notification: seen
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
