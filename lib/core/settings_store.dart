import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device choices that change how the app looks.
class SettingsStore extends ChangeNotifier {
  SettingsStore._();
  static final instance = SettingsStore._();

  ThemeMode themeMode = ThemeMode.system;

  Future<void> load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString('theme');
      themeMode = ThemeMode.values.firstWhere((m) => m.name == v,
          orElse: () => ThemeMode.system);
    } catch (_) {}
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString('theme', m.name);
    } catch (_) {}
  }
}
