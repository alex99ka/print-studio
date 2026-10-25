import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'errors.dart';

/// Google sign-in on every platform, ending in a Firebase session that stays
/// signed in: nothing here signs out except the user's own "יציאה".
///
/// - Android: Credential Manager's account sheet (google_sign_in), then the
///   ID token goes to Firebase.
/// - Web: Firebase's popup.
/// - Windows: google_sign_in has no desktop support, so the browser opens
///   Google's page and redirects back to a one-shot localhost listener
///   (OAuth for installed apps, with PKCE).
abstract final class Auth {
  static FirebaseAuth get _fb => FirebaseAuth.instance;
  static bool _googleReady = false;

  static User? get user => _fb.currentUser;

  static Future<void> signInWithGoogle({bool chooseAccount = false}) async {
    if (kIsWeb) {
      final provider = GoogleAuthProvider()
        ..setCustomParameters({'prompt': 'select_account'});
      await _fb.signInWithPopup(provider);
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      await _fb.signInWithCredential(await _desktopCredential());
    } else {
      if (AppConfig.googleWebClientId.isEmpty) throw Errors.googleNotSetUp;
      final g = GoogleSignIn.instance;
      if (!_googleReady) {
        await g.initialize(serverClientId: AppConfig.googleWebClientId);
        _googleReady = true;
      }
      if (chooseAccount) await g.signOut();
      final GoogleSignInAccount account;
      try {
        account = await g.authenticate();
      } on GoogleSignInException catch (e) {
        throw e.code == GoogleSignInExceptionCode.canceled
            ? Errors.googleCancelled
            : Errors.googleFailed;
      }
      final idToken = account.authentication.idToken;
      if (idToken == null) throw Errors.googleFailed;
      await _fb.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
    }
    await _recordSignIn();
  }

  /// "החלפת חשבון": sign out here, then straight to the account chooser.
  static Future<void> switchAccount() async {
    await signOut();
    await signInWithGoogle(chooseAccount: true);
  }

  static Future<void> signOut() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && _googleReady) {
      await GoogleSignIn.instance.signOut();
    }
    await _fb.signOut();
  }

  /// users/{uid}: name, email, and the time of this and the previous sign-in
  /// (Settings shows "כניסה קודמת", which is how a stranger's sign-in shows up).
  static Future<void> _recordSignIn() async {
    final u = user;
    if (u == null) return;
    final ref = FirebaseFirestore.instance.doc('users/${u.uid}');
    try {
      final before = await ref.get();
      await ref.set({
        'name': u.displayName,
        'email': u.email,
        'lastSignIn': FieldValue.serverTimestamp(),
        'previousSignIn': before.data()?['lastSignIn'],
        'previousPlatform': before.data()?['lastPlatform'],
        'lastPlatform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      }, SetOptions(merge: true));
    } on FirebaseException {
      // Not allowed (the gate says so next) or offline: nothing to record.
    }
  }

  // ---- Windows: OAuth for installed apps, loopback redirect + PKCE ----

  static Future<AuthCredential> _desktopCredential() async {
    if (AppConfig.googleDesktopClientId.isEmpty) throw Errors.googleNotSetUp;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _random(64);
    final state = _random(24);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': AppConfig.googleDesktopClientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': 'openid email profile',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'prompt': 'select_account',
    });
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      final request = await server.first.timeout(const Duration(minutes: 5),
          onTimeout: () => throw Errors.googleCancelled);
      final q = request.uri.queryParameters;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html dir="rtl"><body style="font-family:sans-serif;'
            'text-align:center;margin-top:20vh"><h2>אפשר לחזור לאפליקציה</h2>'
            '</body></html>');
      await request.response.close();
      if (q['state'] != state || q['code'] == null) throw Errors.googleCancelled;
      final res = await http.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        body: {
          'code': q['code']!,
          'client_id': AppConfig.googleDesktopClientId,
          'client_secret': AppConfig.googleDesktopSecret,
          'redirect_uri': redirect,
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      ).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Errors.googleFailed;
      final tokens = jsonDecode(res.body) as Map<String, dynamic>;
      return GoogleAuthProvider.credential(
        idToken: tokens['id_token'] as String?,
        accessToken: tokens['access_token'] as String?,
      );
    } finally {
      await server.close(force: true);
    }
  }

  static String _random(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

const _allowedKey = 'access_ok';

/// Remembers the last access answer, so an offline start doesn't lock out
/// someone who was let in before.
Future<bool?> lastKnownAccess() async =>
    (await SharedPreferences.getInstance()).getBool(_allowedKey);

Future<void> rememberAccess(bool ok) async =>
    (await SharedPreferences.getInstance()).setBool(_allowedKey, ok);
