import 'dart:math';

import 'package:flutter/material.dart';

import '../config.dart';
import '../core/app_info.dart';
import '../core/auth.dart';
import '../core/errors.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen>
    with SingleTickerProviderStateMixin {
  bool _busy = false;
  String? _error;

  /// A failed sign-in shakes the card, then says what happened.
  late final _shake = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 450));

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Auth.signInWithGoogle();
    } catch (e) {
      final error = classify(e);
      recordError(error.code, e);
      if (!mounted) return;
      if (error != Errors.googleCancelled) _shake.forward(from: 0);
      setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: AnimatedBuilder(
            animation: _shake,
            builder: (_, child) => Transform.translate(
              offset: Offset(
                  sin(_shake.value * pi * 6) * 12 * (1 - _shake.value), 0),
              child: child,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(AppConfig.name,
                        style: t.textTheme.headlineMedium,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 40),
                    FilledButton.icon(
                      onPressed: _busy ? null : _signIn,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.login),
                      label: const Text('כניסה עם Google'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!,
                          style: TextStyle(color: t.colorScheme.error),
                          textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 40),
                    Text('גרסה ${AppInfo.versionLabel}',
                        style: t.textTheme.bodySmall
                            ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
