// Project print-studio-1786a. Refresh from
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
    apiKey: 'AIzaSyDLYcFtRQ7-leIsE0_jYnkdkPpDaEIS8fQ',
    appId: '1:256993487907:web:fd6bed594f6ebfe9e89596',
    messagingSenderId: '256993487907',
    projectId: 'print-studio-1786a',
    authDomain: 'print-studio-1786a.firebaseapp.com',
    storageBucket: 'print-studio-1786a.firebasestorage.app',
  );

  static const android = FirebaseOptions(
    apiKey: 'AIzaSyD75WT3e0vTC3bj7bt7O2wD1DdKY-qF9_k',
    appId: '1:256993487907:android:c02cbc154b403ae8e89596',
    messagingSenderId: '256993487907',
    projectId: 'print-studio-1786a',
    storageBucket: 'print-studio-1786a.firebasestorage.app',
  );
}
