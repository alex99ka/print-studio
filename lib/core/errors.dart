import 'dart:async';
import 'dart:io' show SocketException, HttpException;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_info.dart';

/// Every failure the app shows says what failed, why, and what to do, in
/// Hebrew, with a code that tells the builder which failure it was.
///
/// Letters: N connection · A account · G Google sign-in · D data (Firestore)
/// · U updates · S the home server · P the device · F design files and the
/// studio's tools · W the shop website · X unexpected.
/// Codes are `CRM-<letter><n>`, the operation's standard (root ERRORS.md,
/// whose CRM block lists each one; test/core_test.dart checks it). Never bare
/// numbers: they read as HTTP statuses.
class AppError implements Exception {
  const AppError(this.code, this.why, this.todo);

  final String code;
  final String why;
  final String todo;

  @override
  String toString() => 'AppError($code)';
}

abstract final class Errors {
  static const noConnection = AppError(
      'CRM-N1', 'אין חיבור לאינטרנט', 'בודקים את החיבור ומנסים שוב');
  static const tooSlow = AppError(
      'CRM-N2', 'השרת לא ענה בזמן', 'מנסים שוב בעוד רגע. אם זה חוזר, החיבור איטי');

  static const notAllowed = AppError('CRM-A1', 'החשבון הזה לא מורשה באפליקציה',
      'נכנסים עם חשבון מורשה, או מבקשים מהמנהל להוסיף אותו');
  static const signedOut = AppError('CRM-A2', 'הכניסה פגה',
      'נכנסים שוב. הנתונים במקומם');
  static const accountDisabled =
      AppError('CRM-A3', 'החשבון הושבת', 'צריך להפעיל אותו מחדש ב-Firebase');
  static const tooManyTries =
      AppError('CRM-A4', 'יותר מדי ניסיונות כניסה', 'מחכים כמה דקות ומנסים שוב');

  static const googleCancelled =
      AppError('CRM-G1', 'הכניסה עם Google בוטלה', 'לוחצים שוב על "כניסה עם Google"');
  static const googleNotSetUp = AppError('CRM-G2', 'הכניסה עם Google לא מוגדרת בגרסה הזו',
      'צריך לבנות את האפליקציה עם מזהה הלקוח של Google. שולחים את הקוד');
  static const googleFailed =
      AppError('CRM-G3', 'Google החזיר שגיאה', 'מנסים שוב. אם זה חוזר, שולחים את הקוד');

  static const noPermission = AppError('CRM-D1', 'אין הרשאה לנתונים',
      'יוצאים ונכנסים שוב. אם זה חוזר, כללי ההרשאה ב-Firebase דורשים בדיקה');
  static const dataUnavailable = AppError('CRM-D2', 'מסד הנתונים לא זמין כרגע',
      'מנסים שוב בעוד כמה דקות. השינויים נשמרים במכשיר עד אז');
  static const quotaExceeded = AppError('CRM-D3', 'נגמרה המכסה היומית החינמית',
      'זה מתאפס בחצות (שעון ארה"ב). עד אז אפשר רק לקרוא מהמכשיר');

  static const updateCheckFailed = AppError('CRM-U1', 'לא הצלחתי לבדוק עדכונים',
      'בודקים את החיבור ומנסים שוב מההגדרות');
  static const updateCorrupt = AppError('CRM-U2', 'קובץ העדכון שהורד לא תקין',
      'מנסים שוב. קובץ שלא תואם למה שפורסם לא מותקן');
  static const updateNotAllowed = AppError('CRM-U3', 'אנדרואיד לא מרשה להתקין עדכונים',
      'מאשרים "התקנה מהאפליקציה הזו" במסך שנפתח, וחוזרים');
  static const updateTooOld = AppError('CRM-U4', 'הגרסה הזו ישנה מדי',
      'מעדכנים כדי להמשיך. הנתונים נשמרים');

  static const serverDown = AppError('CRM-S1', 'השרת בבית לא עונה',
      'מנסים שוב בעוד כמה דקות. אם זה נמשך, צריך לבדוק שהשרת דלוק');
  static const serverBug =
      AppError('CRM-S2', 'תקלה בשרת', 'מנסים שוב. אם זה חוזר, שולחים את הקוד');

  static const noBiometrics = AppError('CRM-P1', 'אין טביעת אצבע מוגדרת בטלפון',
      'מגדירים טביעת אצבע בהגדרות הטלפון וחוזרים');
  static const notificationsBlocked = AppError('CRM-P2', 'ההתראות חסומות',
      'מאשרים התראות לאפליקציה בהגדרות המכשיר');
  static const notificationsNeedHomeScreen = AppError('CRM-P3',
      'באייפד התראות עובדות רק מהאפליקציה שבמסך הבית',
      'בספארי: שיתוף › הוספה למסך הבית, ופותחים משם');

  static const noServer = AppError('CRM-F1', 'בגרסה הזו אין כתובת לשרת הקבצים',
      'צריך לבנות את האפליקציה עם SERVER_URL. שולחים את הקוד');
  static const requestLocked = AppError('CRM-F2', 'הבקשה כבר אושרה ונעולה',
      'שינוי אחרי אישור הוא בקשה חדשה');
  static const badFile = AppError('CRM-F3', 'הקובץ לא תקין או גדול מ-60MB',
      'מייצאים שוב מה-Flag Maker ומעלים את הקבצים מהייצוא');
  static const slicerFailed = AppError('CRM-F4', 'Bambu Studio לא נפתח',
      'בודקים ש-Bambu Studio מותקן ושקבצי 3MF נפתחים בו בלחיצה כפולה');
  static const noPreview = AppError('CRM-F5', 'לא נבחרה תמונת PNG',
      'בוחרים את כל קבצי הייצוא, כולל ה-PNG');

  // The shop website (lib/studio/website.dart picks them from the server's answer).
  static const siteInvalid = AppError('CRM-W1', 'האתר לא קיבל את הנתונים', 'מתקנים את השדה ושומרים שוב');
  static const siteSlugTaken = AppError('CRM-W2', 'כבר יש באתר מוצר עם המזהה הזה',
      'בוחרים מזהה אחר, או עורכים את המוצר הקיים');
  static const sitePicture = AppError('CRM-W3', 'הקובץ אינו תמונה (JPG, PNG, WebP) או שהוא גדול מ-15MB',
      'בוחרים תמונה אחרת');
  static const siteNotSetUp = AppError('CRM-W4', 'השרת בבית עוד לא מחובר ל-Supabase של האתר',
      'מוסיפים SUPABASE_URL ו-SUPABASE_SERVICE_ROLE_KEY ל-.env של השרת ומפעילים אותו מחדש');
  static const siteRefused = AppError('CRM-W5', 'Supabase לא ביצע את הפעולה',
      'מנסים שוב. אם זה חוזר, שולחים את הקוד');
  static const siteGone = AppError('CRM-W6', 'הרשומה כבר לא קיימת באתר', 'מרעננים את הרשימה');

  /// Every code, for the test that keeps them unique.
  static const all = <AppError>[
    noConnection, tooSlow, notAllowed, signedOut, accountDisabled,
    tooManyTries, googleCancelled, googleNotSetUp, googleFailed, noPermission,
    dataUnavailable, quotaExceeded, updateCheckFailed, updateCorrupt,
    updateNotAllowed, updateTooOld, serverDown, serverBug, noBiometrics,
    notificationsBlocked, notificationsNeedHomeScreen, noServer, requestLocked,
    badFile, slicerFailed, noPreview,
    siteInvalid, siteSlugTaken, sitePicture, siteNotSetUp, siteRefused, siteGone,
  ];
}

/// Thrown by the server client; the status and message pick the code.
class ServerException implements Exception {
  const ServerException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'ServerException($status, $message)';
}

AppError classify(Object e) => switch (e) {
      AppError() => e,
      TimeoutException() => Errors.tooSlow,
      SocketException() || HttpException() => Errors.noConnection,
      FirebaseAuthException(code: 'network-request-failed') =>
        Errors.noConnection,
      FirebaseAuthException(code: 'user-disabled') => Errors.accountDisabled,
      FirebaseAuthException(code: 'too-many-requests') => Errors.tooManyTries,
      FirebaseAuthException(
        code: 'user-token-expired' || 'requires-recent-login' || 'user-not-found'
      ) =>
        Errors.signedOut,
      FirebaseException(code: 'permission-denied') => Errors.noPermission,
      FirebaseException(code: 'unavailable') => Errors.dataUnavailable,
      FirebaseException(code: 'resource-exhausted') => Errors.quotaExceeded,
      ServerException(status: 401 || 403) => Errors.notAllowed,
      ServerException(status: 502 || 503) => Errors.serverDown,
      ServerException(status: 504) => Errors.tooSlow,
      ServerException(status: 409) => Errors.requestLocked,
      ServerException(status: 413 || 422) => Errors.badFile,
      ServerException() => Errors.serverBug,
      _ => _unexpected(e),
    };

AppError _unexpected(Object e) {
  final detail = '$e';
  return AppError(
    'CRM-X1',
    'תקלה לא צפויה (${detail.length > 100 ? '${detail.substring(0, 100)}…' : detail})',
    'מנסים שוב. אם זה חוזר, שולחים דיווח מההגדרות',
  );
}

/// "[failed]: why. What to do. (קוד CRM-G1)", for a SnackBar or under a field.
String errorText(Object e, [String? failed]) {
  final error = classify(e);
  return '${failed == null ? '' : '$failed: '}${error.why}. ${error.todo}. '
      '(קוד ${error.code})';
}

/// A failure in a SnackBar that stays long enough to read. "העתקה" copies the
/// code, the technical cause and the version, for the builder.
void showError(ScaffoldMessengerState messenger, Object e, [String? failed]) {
  final error = classify(e);
  recordError(error.code, e);
  messenger.showSnackBar(
    SnackBar(
      persist: false,
      duration: const Duration(seconds: 10),
      content: Text(errorText(error, failed)),
      action: SnackBarAction(
        label: 'העתקה',
        onPressed: () => Clipboard.setData(ClipboardData(
          text: 'קוד ${error.code}: ${failed ?? error.why}\nפרטים: $e\n'
              'גרסה ${AppInfo.versionLabel} · ${DateTime.now().toString().substring(0, 16)}',
        )),
      ),
    ),
  );
}

const _errorsKey = 'recent_errors';

/// Keeps the last 20 errors (shown or uncaught), across restarts, so the
/// problem report carries them instead of them vanishing.
Future<void> recordError(String code, Object error, [StackTrace? stack]) async {
  final where = '$stack'
      .split('\n')
      .firstWhere((l) => l.contains('package:print_studio/'), orElse: () => '');
  var line = '${DateTime.now().toString().substring(0, 16)} $code $error ${where.trim()}';
  if (line.length > 300) line = line.substring(0, 300);
  try {
    final prefs = await SharedPreferences.getInstance();
    final kept = prefs.getStringList(_errorsKey) ?? [];
    await prefs.setStringList(_errorsKey, [line, ...kept.take(19)]);
  } catch (_) {} // nowhere to keep it
}

Future<List<String>> recentErrors() async {
  try {
    return (await SharedPreferences.getInstance()).getStringList(_errorsKey) ??
        [];
  } catch (_) {
    return [];
  }
}
