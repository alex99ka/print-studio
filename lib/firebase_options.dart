// Placeholder until the app has its Firebase project. Fill it from
// `firebase.cmd apps:sdkconfig <WEB|ANDROID> <appId> --project <id>` (the web
// config serves Windows too). These values are public by design: they name
// the project, the security rules protect it.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      TargetPlatform.windows => web,
      _ => throw UnsupportedError('No Firebase config for $defaultTargetPlatform'),
    };
  }

  static const web = FirebaseOptions(
    apiKey: 'REPLACE',
    appId: 'REPLACE',
    messagingSenderId: 'REPLACE',
    projectId: 'REPLACE',
    authDomain: 'REPLACE.firebaseapp.com',
    storageBucket: 'REPLACE.firebasestorage.app',
  );

  static const android = FirebaseOptions(
    apiKey: 'REPLACE',
    appId: 'REPLACE',
    messagingSenderId: 'REPLACE',
    projectId: 'REPLACE',
    storageBucket: 'REPLACE.firebasestorage.app',
  );
}
