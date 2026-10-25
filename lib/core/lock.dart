import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Fingerprint (Windows Hello on the PC) lock, opt-in. Google is needed once;
/// after that the app stays signed in and, when this is on, opening it (or
/// coming back after [relockAfter]) asks for the fingerprint, with the
/// device PIN as the fallback. A failed fingerprint never signs out.

const _onKey = 'fingerprint_lock';
const _offeredKey = 'fingerprint_offered';
const relockAfter = Duration(minutes: 5);
const _system = MethodChannel('app/system');

enum FingerprintResult { enabled, cancelled, unsupported }

/// null where the device can't do it (or on the web); otherwise on/off.
Future<bool?> fingerprintSetting() async {
  if (kIsWeb) return null;
  try {
    if (!await LocalAuthentication().isDeviceSupported()) return null;
    return (await SharedPreferences.getInstance()).getBool(_onKey) ?? false;
  } catch (_) {
    return null;
  }
}

Future<void> disableFingerprint() async =>
    (await SharedPreferences.getInstance()).setBool(_onKey, false);

/// Offered once, after the first sign-in on this device.
Future<bool> shouldOfferFingerprint() async {
  if (await fingerprintSetting() != false) return false;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_offeredKey) ?? false) return false;
  await prefs.setBool(_offeredKey, true);
  return true;
}

/// Turns the lock on the way the phone expects: if no fingerprint is enrolled
/// yet, the phone's own enrollment screen opens, and this continues when the
/// user comes back. Then the system prompt confirms it once.
Future<FingerprintResult> enableFingerprint() async {
  final auth = LocalAuthentication();
  if (!await auth.isDeviceSupported()) return FingerprintResult.unsupported;
  if ((await auth.getAvailableBiometrics()).isEmpty &&
      defaultTargetPlatform == TargetPlatform.android) {
    final back = Completer<void>();
    final listener = AppLifecycleListener(onResume: () {
      if (!back.isCompleted) back.complete();
    });
    try {
      await _system.invokeMethod('enrollBiometrics');
      await back.future.timeout(const Duration(minutes: 10));
    } on TimeoutException {
      return FingerprintResult.cancelled;
    } finally {
      listener.dispose();
    }
    if ((await auth.getAvailableBiometrics()).isEmpty) {
      return FingerprintResult.cancelled;
    }
  }
  try {
    final ok = await auth.authenticate(
      localizedReason: 'אישור כניסה בטביעת אצבע ל${AppConfig.name}',
      persistAcrossBackgrounding: true,
    );
    if (!ok) return FingerprintResult.cancelled;
  } on LocalAuthException {
    return FingerprintResult.cancelled;
  }
  await (await SharedPreferences.getInstance()).setBool(_onKey, true);
  return FingerprintResult.enabled;
}

class AppLock extends StatefulWidget {
  const AppLock({super.key, required this.signedIn, required this.child});

  /// Nothing to lock on the sign-in screen.
  final bool Function() signedIn;
  final Widget child;

  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> {
  bool _locked = false;
  bool _asking = false;
  DateTime? _leftAt;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _leftAt = DateTime.now(),
      onShow: () {
        final left = _leftAt;
        if (left != null && DateTime.now().difference(left) >= relockAfter) {
          _lock();
        }
      },
    );
    _lock();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _lock() async {
    if (!widget.signedIn() || await fingerprintSetting() != true) return;
    if (!mounted) return;
    setState(() => _locked = true);
    await _unlock();
  }

  Future<void> _unlock() async {
    if (_asking) return;
    _asking = true;
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'פתיחת ${AppConfig.name}',
        persistAcrossBackgrounding: true,
      );
      if (ok && mounted) setState(() => _locked = false);
    } on LocalAuthException catch (e) {
      // The fingerprint was removed from the phone: don't lock anyone out.
      if (e.code == LocalAuthExceptionCode.noCredentialsSet ||
          e.code == LocalAuthExceptionCode.noBiometricHardware) {
        await disableFingerprint();
        if (mounted) setState(() => _locked = false);
      }
      // Cancelled or too many tries: the button below retries.
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          widget.child, // keeps its state under the lock
          if (_locked)
            Positioned.fill(
              child: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(AppConfig.name,
                          style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 40),
                      FilledButton.icon(
                        onPressed: _unlock,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('פתיחה בטביעת אצבע'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
}
