import 'package:flutter/material.dart';

/// The only place colours are written. Screens use Theme.of(context) or
/// [AppTokens]; test/theme_test.dart fails on any colour not listed here.
/// A new app replaces these values with its approved palette.
abstract final class AppTokens {
  static const seed = Color(0xFF047857);

  static const lightBg = Color(0xFFF6FAF8);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightInk = Color(0xFF1F2A26);
  static const lightMuted = Color(0xFF5B6B65);

  static const darkBg = Color(0xFF111614);
  static const darkCard = Color(0xFF1B2220);
  static const darkInk = Color(0xFFE7EFEC);
  static const darkMuted = Color(0xFF9AAAA4);

  static const danger = Color(0xFFB42318);
  static const dangerDark = Color(0xFFF97066);

  /// Skeleton placeholders.
  static const skeletonLight = Color(0xFFE4ECE8);
  static const skeletonDark = Color(0xFF26302D);

  static const all = <Color>[
    seed, lightBg, lightCard, lightInk, lightMuted, darkBg, darkCard, darkInk,
    darkMuted, danger, dangerDark, skeletonLight, skeletonDark,
  ];
}

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppTokens.seed,
    brightness: brightness,
  ).copyWith(
    surface: dark ? AppTokens.darkCard : AppTokens.lightCard,
    onSurface: dark ? AppTokens.darkInk : AppTokens.lightInk,
    onSurfaceVariant: dark ? AppTokens.darkMuted : AppTokens.lightMuted,
    error: dark ? AppTokens.dangerDark : AppTokens.danger,
  );
  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Rubik',
    scaffoldBackgroundColor: dark ? AppTokens.darkBg : AppTokens.lightBg,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? AppTokens.darkBg : AppTokens.lightBg,
      foregroundColor: dark ? AppTokens.darkInk : AppTokens.lightInk,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: dark ? AppTokens.darkCard : AppTokens.lightCard,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Color skeletonColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppTokens.skeletonDark
        : AppTokens.skeletonLight;
