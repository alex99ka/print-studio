import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/auth.dart';
import '../core/remote_config.dart';
import '../core/update.dart';
import '../core/web_update.dart';
import 'home_screen.dart';
import 'sign_in_screen.dart';
import 'skeleton.dart';

/// What the user sees, in order: too old → update; signed out → sign in;
/// not on the allowlist → no access; otherwise the app.
class Gates extends StatefulWidget {
  const Gates({super.key});

  @override
  State<Gates> createState() => _GatesState();
}

class _GatesState extends State<Gates> {
  // Kept, not made per build: a new stream on every rebuild shows the skeleton,
  // rebuilds the access gate, calls /me, notifies, rebuilds… forever.
  final _authChanges = FirebaseAuth.instance.authStateChanges();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: RemoteConfig.instance,
        builder: (context, _) {
          if (RemoteConfig.instance.tooOld) return const UpdateRequiredScreen();
          return StreamBuilder<User?>(
            stream: _authChanges,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Scaffold(body: SkeletonList());
              }
              final user = snap.data;
              if (user == null) return const SignInScreen();
              return _AccessGate(key: ValueKey(user.uid), email: user.email);
            },
          );
        },
      );
}

class _AccessGate extends StatefulWidget {
  const _AccessGate({super.key, required this.email});
  final String? email;

  @override
  State<_AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<_AccessGate> {
  late final Future<bool> _allowed = _check();

  Future<bool> _check() async {
    try {
      final ok = await RemoteConfig.instance.checkAccess(widget.email);
      await rememberAccess(ok);
      AppUpdater.instance?.early = RemoteConfig.instance.earlyUser;
      return ok;
    } catch (_) {
      // Offline: whoever was let in before stays in.
      return await lastKnownAccess() ?? false;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _allowed,
        builder: (context, snap) {
          if (!snap.hasData) return const Scaffold(body: SkeletonList());
          return snap.data! ? const HomeScreen() : const _NoAccessScreen();
        },
      );
}

class _NoAccessScreen extends StatelessWidget {
  const _NoAccessScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 16),
              Text('לחשבון ${FirebaseAuth.instance.currentUser?.email ?? ''} '
                  'אין גישה לאפליקציה הזו (קוד A1).',
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('אם זו טעות, מבקשים מהמנהל להוסיף את החשבון.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: Auth.switchAccount,
                child: const Text('כניסה עם חשבון אחר'),
              ),
            ]),
          ),
        ),
      );
}

/// Below config/app.minVersion: nothing else works until the update is in.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final updater = AppUpdater.instance;
    final message = RemoteConfig.instance.message;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListenableBuilder(
            listenable: Listenable.merge([updater, WebUpdate.instance]),
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update, size: 48),
                const SizedBox(height: 16),
                Text('צריך לעדכן כדי להמשיך (קוד U4)',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message.isEmpty
                    ? 'הגרסה ${AppInfo.version} ישנה מדי. הנתונים נשמרים.'
                    : message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (updater?.progress != null)
                  LinearProgressIndicator(value: updater!.progress)
                else
                  FilledButton(
                    onPressed: () async {
                      if (updater == null) return WebUpdate.instance.apply();
                      if (updater.available == null) await updater.check();
                      await updater.install();
                    },
                    child: const Text('עדכון עכשיו'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
