import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'config.dart';
import 'core/app_info.dart';
import 'core/errors.dart';
import 'core/lock.dart';
import 'core/remote_config.dart';
import 'core/settings_store.dart';
import 'core/tour.dart';
import 'core/update.dart';
import 'core/web_update.dart';
import 'firebase_options.dart';
import 'ui/gates.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Errors nobody caught are kept for the problem report in Settings.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    recordError('X2', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    recordError('X2', error, stack);
    return true;
  };
  if (kReleaseMode) {
    // A broken widget says so in words, not a grey box.
    ErrorWidget.builder = (d) => Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(errorText(d.exception, 'המסך הזה לא נטען'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTokens.danger)),
            ),
          ),
        );
  }
  await AppInfo.load();
  await SettingsStore.instance.load();

  // A throw before runApp is an invisible process on Windows (no window at
  // all), so startup failures become a screen with a code instead.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
        .timeout(const Duration(seconds: 20));
    await FirebaseAuth.instance.setLanguageCode('he');
    if (kIsWeb) {
      // The web keeps Firestore in memory by default; persist it so offline
      // edits survive a reload, as on the phone.
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        webPersistentTabManager: WebPersistentMultipleTabManager(),
      );
    }
    RemoteConfig.instance.listen();
  } catch (e, stack) {
    recordError('X3', e, stack);
    runApp(App(home: _StartupError(e)));
    return;
  }

  // Before sign-in too: an update can be what fixes a broken sign-in.
  AppUpdater.instance?.checkIfDue();
  WebUpdate.instance.check();
  runApp(const App(home: Gates()));
}

class App extends StatefulWidget {
  const App({super.key, required this.home});
  final Widget home;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  // Windows: a downloaded update installs silently as the window closes.
  late final _lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await AppUpdater.instance?.installOnExit();
      return AppExitResponse.exit;
    },
  );

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _lifecycle; // start listening
    return ListenableBuilder(
      listenable: SettingsStore.instance,
      builder: (context, _) => MaterialApp(
        title: AppConfig.name,
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: SettingsStore.instance.themeMode,
        locale: const Locale('he'),
        supportedLocales: const [Locale('he')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: widget.home,
        // The walkthrough over every screen, the fingerprint lock over that.
        builder: (context, screens) => AppLock(
          signedIn: () {
            try {
              return FirebaseAuth.instance.currentUser != null;
            } catch (_) {
              return false; // Firebase never started
            }
          },
          child: TourLayer(child: screens!),
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError(this.error);
  final Object error;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              errorText(error, 'האפליקציה לא הצליחה להתחבר בהפעלה'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
