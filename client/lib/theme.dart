import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette sampled from `assets/images/engkwentro-logo.svg` and the app icon.
abstract final class EngkwentroColors {
  /// Deep navy field behind the wordmark.
  static const navy = Color(0xFF1B2335);

  /// Slightly warmer navy used inside the app icon.
  static const navyDeep = Color(0xFF1F222D);

  /// Near-black outline and shadow ink.
  static const ink = Color(0xFF060A0E);

  /// Heraldic gold from the emblem.
  static const gold = Color(0xFFC3973E);

  /// Warm cream used for the wordmark.
  static const cream = Color(0xFFF8ECBD);

  /// Light sand highlights.
  static const sand = Color(0xFFD6B88F);

  /// Mid tan for the opposing army.
  static const tan = Color(0xFFBE9873);

  /// Darker tan used for outlines and secondary text.
  static const brown = Color(0xFFB68C6A);

  /// Dark board square.
  static const boardDark = navyDeep;

  /// Light board square.
  static const boardLight = Color(0xFF252C3E);
}

/// Sharp corners — pixel chrome does not use Material radii.
const BorderRadius engkwentroSharp = BorderRadius.zero;

/// Builds the dark arcade theme: Press Start 2P for chrome, VT323 for body.
ThemeData engkwentroTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: EngkwentroColors.gold,
        brightness: Brightness.dark,
      ).copyWith(
        primary: EngkwentroColors.gold,
        onPrimary: EngkwentroColors.ink,
        secondary: EngkwentroColors.tan,
        onSecondary: EngkwentroColors.ink,
        tertiary: EngkwentroColors.cream,
        onTertiary: EngkwentroColors.navy,
        surface: EngkwentroColors.navy,
        onSurface: EngkwentroColors.cream,
        onSurfaceVariant: EngkwentroColors.sand,
        outline: EngkwentroColors.brown,
        surfaceTint: Colors.transparent,
        surfaceContainerLowest: EngkwentroColors.ink,
        surfaceContainerLow: EngkwentroColors.navyDeep,
        surfaceContainer: const Color(0xFF252C3E),
        surfaceContainerHigh: const Color(0xFF2D3549),
        surfaceContainerHighest: const Color(0xFF374054),
        inverseSurface: EngkwentroColors.cream,
        onInverseSurface: EngkwentroColors.navy,
        inversePrimary: const Color(0xFF6B4D1B),
      );

  final text = _engkwentroTextTheme();

  final sharpBorder = OutlineInputBorder(
    borderRadius: engkwentroSharp,
    borderSide: const BorderSide(color: EngkwentroColors.cream, width: 2),
  );

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: EngkwentroColors.navy,
    textTheme: text,
    primaryTextTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: EngkwentroColors.navy,
      foregroundColor: EngkwentroColors.cream,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: text.titleMedium?.copyWith(
        color: EngkwentroColors.cream,
        letterSpacing: 0.5,
      ),
      iconTheme: const IconThemeData(color: EngkwentroColors.cream),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: EngkwentroColors.boardLight,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: engkwentroSharp,
        side: BorderSide(color: EngkwentroColors.cream, width: 3),
      ),
      titleTextStyle: text.titleMedium?.copyWith(
        color: EngkwentroColors.cream,
        height: 1.5,
      ),
      contentTextStyle: text.bodyMedium?.copyWith(color: EngkwentroColors.sand),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: EngkwentroColors.navyDeep,
      labelStyle: text.bodyMedium?.copyWith(color: EngkwentroColors.sand),
      hintStyle: text.bodyMedium?.copyWith(
        color: EngkwentroColors.sand.withValues(alpha: 0.55),
      ),
      border: sharpBorder,
      enabledBorder: sharpBorder,
      focusedBorder: sharpBorder.copyWith(
        borderSide: const BorderSide(color: EngkwentroColors.gold, width: 2),
      ),
      disabledBorder: sharpBorder.copyWith(
        borderSide: BorderSide(
          color: EngkwentroColors.cream.withValues(alpha: 0.35),
          width: 2,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: EngkwentroColors.cream,
        foregroundColor: EngkwentroColors.ink,
        disabledBackgroundColor: EngkwentroColors.boardLight,
        disabledForegroundColor: EngkwentroColors.sand,
        shape: const RoundedRectangleBorder(borderRadius: engkwentroSharp),
        side: const BorderSide(color: EngkwentroColors.ink, width: 3),
        elevation: 0,
        shadowColor: Colors.transparent,
        textStyle: GoogleFonts.pressStart2p(
          fontSize: 9,
          height: 1.4,
          letterSpacing: 0.4,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: EngkwentroColors.cream,
        shape: const RoundedRectangleBorder(borderRadius: engkwentroSharp),
        side: const BorderSide(color: EngkwentroColors.cream, width: 2),
        textStyle: GoogleFonts.pressStart2p(
          fontSize: 8,
          height: 1.4,
          letterSpacing: 0.3,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: EngkwentroColors.gold,
        textStyle: GoogleFonts.pressStart2p(
          fontSize: 8,
          height: 1.4,
          letterSpacing: 0.3,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: EngkwentroColors.boardLight,
      contentTextStyle: text.bodyMedium?.copyWith(
        color: EngkwentroColors.cream,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: engkwentroSharp,
        side: BorderSide(color: EngkwentroColors.gold, width: 2),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: EngkwentroColors.brown,
      thickness: 2,
      space: 28,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: EngkwentroColors.gold,
      circularTrackColor: EngkwentroColors.boardLight,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: EngkwentroColors.cream),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: EngkwentroColors.navy,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: engkwentroSharp),
    ),
  );
}

/// Display / chrome = Press Start 2P; reading copy = VT323.
TextTheme _engkwentroTextTheme() {
  TextStyle arcadeAt(double size, {double height = 1.5, Color? color}) =>
      GoogleFonts.pressStart2p(
        fontSize: size,
        height: height,
        letterSpacing: 0.4,
        color: color ?? EngkwentroColors.cream,
      );

  TextStyle bodyAt(double size, {double height = 1.25, Color? color}) =>
      GoogleFonts.vt323(
        fontSize: size,
        height: height,
        letterSpacing: 0.2,
        color: color ?? EngkwentroColors.cream,
      );

  final base = ThemeData(brightness: Brightness.dark).textTheme;
  return base.copyWith(
    displayLarge: arcadeAt(22, height: 1.35),
    displayMedium: arcadeAt(18, height: 1.4),
    displaySmall: arcadeAt(16, height: 1.4, color: EngkwentroColors.gold),
    headlineLarge: arcadeAt(16, height: 1.4),
    headlineMedium: arcadeAt(14, height: 1.45),
    headlineSmall: arcadeAt(12, height: 1.45, color: EngkwentroColors.gold),
    titleLarge: arcadeAt(11, height: 1.5),
    titleMedium: arcadeAt(10, height: 1.5),
    titleSmall: arcadeAt(9, height: 1.5),
    labelLarge: arcadeAt(9, height: 1.4, color: EngkwentroColors.gold),
    labelMedium: bodyAt(16, color: EngkwentroColors.sand),
    labelSmall: bodyAt(14, color: EngkwentroColors.sand),
    bodyLarge: bodyAt(22),
    bodyMedium: bodyAt(18, color: EngkwentroColors.sand),
    bodySmall: bodyAt(16, color: EngkwentroColors.sand),
  );
}
