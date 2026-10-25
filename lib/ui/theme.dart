import 'package:flutter/material.dart';

/// The only place colours are written. Screens use Theme.of(context),
/// [StudioColors] (context.studio) or [AppTokens]; test/core_test.dart fails
/// on a colour written anywhere else. Palette A, approved 25.10.2026; the
/// portal (server/app/static/portal.html) uses the same values.
abstract final class AppTokens {
  static const accent = Color(0xFF2F5BEA);
  static const accentDark = Color(0xFF7C9BFF);

  static const lightBg = Color(0xFFF4F5F7);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightSunk = Color(0xFFEBEDF1);
  static const lightInk = Color(0xFF15171C);
  static const lightMuted = Color(0xFF555C69);
  static const lightLine = Color(0xFFDFE2E8);
  static const lightAccentSoft = Color(0xFFE6ECFD);
  static const lightWarnSoft = Color(0xFFFDF0DC);
  static const lightWarnInk = Color(0xFF7A4A05);
  static const lightOkSoft = Color(0xFFDDF3E8);
  static const lightOkInk = Color(0xFF0F5A37);
  static const lightOk = Color(0xFF047857);

  static const darkBg = Color(0xFF0F1115);
  static const darkCard = Color(0xFF181B21);
  static const darkSunk = Color(0xFF1F232A);
  static const darkInk = Color(0xFFECEEF2);
  static const darkMuted = Color(0xFFA0A7B3);
  static const darkLine = Color(0xFF2A2F38);
  static const darkAccentSoft = Color(0xFF1E2A4D);
  static const darkWarnSoft = Color(0xFF3A2A12);
  static const darkWarnInk = Color(0xFFF8C77E);
  static const darkOkSoft = Color(0xFF133526);
  static const darkOkInk = Color(0xFF7FDDB0);
  static const darkOk = Color(0xFF34D399);
  static const darkOnAccent = Color(0xFF0B1020);
  static const darkOnOk = Color(0xFF052E1F);

  /// The title bar: graphite in light, near black in dark.
  static const lightBar = Color(0xFF15171C);
  static const darkBar = Color(0xFF07080B);
  static const white = Color(0xFFFFFFFF);

  static const danger = Color(0xFFB42318);
  static const dangerDark = Color(0xFFF97066);

  static const all = <Color>[
    accent, accentDark, lightBg, lightCard, lightSunk, lightInk, lightMuted, lightLine, lightAccentSoft,
    lightWarnSoft, lightWarnInk, lightOkSoft, lightOkInk, lightOk, darkBg, darkCard, darkSunk, darkInk,
    darkMuted, darkLine, darkAccentSoft, darkWarnSoft, darkWarnInk, darkOkSoft, darkOkInk, darkOk,
    darkOnAccent, darkOnOk, lightBar, darkBar, white, danger, dangerDark,
  ];
}

/// The palette's colours that Material's scheme has no slot for.
@immutable
class StudioColors extends ThemeExtension<StudioColors> {
  const StudioColors({
    required this.sunk,
    required this.line,
    required this.muted,
    required this.accentSoft,
    required this.warnSoft,
    required this.warnInk,
    required this.okSoft,
    required this.okInk,
    required this.ok,
    required this.onOk,
    required this.bar,
    required this.barInk,
  });

  final Color sunk, line, muted, accentSoft, warnSoft, warnInk, okSoft, okInk, ok, onOk, bar, barInk;

  static const light = StudioColors(
    sunk: AppTokens.lightSunk, line: AppTokens.lightLine, muted: AppTokens.lightMuted,
    accentSoft: AppTokens.lightAccentSoft, warnSoft: AppTokens.lightWarnSoft, warnInk: AppTokens.lightWarnInk,
    okSoft: AppTokens.lightOkSoft, okInk: AppTokens.lightOkInk, ok: AppTokens.lightOk, onOk: AppTokens.white,
    bar: AppTokens.lightBar, barInk: AppTokens.white,
  );
  static const dark = StudioColors(
    sunk: AppTokens.darkSunk, line: AppTokens.darkLine, muted: AppTokens.darkMuted,
    accentSoft: AppTokens.darkAccentSoft, warnSoft: AppTokens.darkWarnSoft, warnInk: AppTokens.darkWarnInk,
    okSoft: AppTokens.darkOkSoft, okInk: AppTokens.darkOkInk, ok: AppTokens.darkOk, onOk: AppTokens.darkOnOk,
    bar: AppTokens.darkBar, barInk: AppTokens.darkInk,
  );

  @override
  StudioColors copyWith() => this;

  @override
  StudioColors lerp(StudioColors? other, double t) => t < 0.5 || other == null ? this : other;
}

extension StudioTheme on BuildContext {
  StudioColors get studio => Theme.of(this).extension<StudioColors>()!;
}

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final s = dark ? StudioColors.dark : StudioColors.light;
  final ink = dark ? AppTokens.darkInk : AppTokens.lightInk;
  final card = dark ? AppTokens.darkCard : AppTokens.lightCard;
  final scheme = ColorScheme.fromSeed(seedColor: AppTokens.accent, brightness: brightness).copyWith(
    primary: dark ? AppTokens.accentDark : AppTokens.accent,
    onPrimary: dark ? AppTokens.darkOnAccent : AppTokens.white,
    surface: card,
    onSurface: ink,
    onSurfaceVariant: s.muted,
    outline: s.line,
    outlineVariant: s.line,
    surfaceContainerHighest: s.sunk,
    secondaryContainer: s.accentSoft,
    onSecondaryContainer: ink,
    error: dark ? AppTokens.dangerDark : AppTokens.danger,
  );
  final radius = BorderRadius.circular(10);
  return ThemeData(
    colorScheme: scheme,
    extensions: [s],
    fontFamily: 'Heebo',
    scaffoldBackgroundColor: dark ? AppTokens.darkBg : AppTokens.lightBg,
    dividerColor: s.line,
    appBarTheme: AppBarTheme(
      backgroundColor: card,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: s.line)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(44, 44), shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44), side: BorderSide(color: s.line), shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: s.line)),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: s.line)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Color skeletonColor(BuildContext context) => context.studio.sunk;
