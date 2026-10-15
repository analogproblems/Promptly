import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the app theme for one brightness from the design tokens.
/// Route changes cut straight to the new screen when the system asks for
/// reduced motion.
class NoMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoMotionPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}

ThemeData buildPromptlyTheme(Brightness brightness, {bool reducedMotion = false}) {
  final t = brightness == Brightness.dark
      ? PromptlyTokens.dark
      : PromptlyTokens.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.accent,
    onPrimary: t.onAccent,
    secondary: t.accent,
    onSecondary: t.onAccent,
    error: t.danger,
    onError: t.onAccent,
    surface: t.background,
    onSurface: t.text,
    surfaceContainerHighest: t.surface,
    surfaceContainerHigh: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerLow: t.surface,
    surfaceContainerLowest: t.background,
    onSurfaceVariant: t.muted,
    outline: t.border,
    outlineVariant: t.border,
  );

  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.background,
    canvasColor: t.background,
    dividerColor: t.border,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    extensions: [t],
    appBarTheme: AppBarTheme(
      backgroundColor: t.background,
      foregroundColor: t.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: t.text,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      color: t.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        side: BorderSide(color: t.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        borderSide: BorderSide(color: t.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        borderSide: BorderSide(color: t.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        borderSide: BorderSide(color: t.accent, width: 1.5),
      ),
      hintStyle: TextStyle(color: t.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        shape: controlShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.text,
        side: BorderSide(color: t.border),
        shape: controlShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: t.accent, shape: controlShape),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.surface,
      indicatorColor: t.accent.withValues(alpha: 0.16),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? t.accent : t.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? t.accent : t.muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: t.surface,
      indicatorColor: t.accent.withValues(alpha: 0.16),
      selectedIconTheme: IconThemeData(color: t.accent),
      unselectedIconTheme: IconThemeData(color: t.muted),
      selectedLabelTextStyle: TextStyle(
        color: t.accent,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: t.muted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.surface,
      contentTextStyle: TextStyle(color: t.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        side: BorderSide(color: t.border),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.muted,
      textColor: t.text,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      ),
    ),
    pageTransitionsTheme: reducedMotion
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.linux: NoMotionPageTransitionsBuilder(),
              TargetPlatform.windows: NoMotionPageTransitionsBuilder(),
              TargetPlatform.macOS: NoMotionPageTransitionsBuilder(),
              TargetPlatform.android: NoMotionPageTransitionsBuilder(),
              TargetPlatform.iOS: NoMotionPageTransitionsBuilder(),
            },
          )
        : const PageTransitionsTheme(
            builders: {
              TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
  );
}

/// Text style for anything that should read like the terminal: host labels,
/// hostnames, snippets, fingerprints.
TextStyle monoStyle(
  BuildContext context, {
  double? size,
  FontWeight? weight,
  Color? color,
}) {
  return TextStyle(
    fontFamily: PromptlyTokens.monoFamily,
    fontFamilyFallback: const ['DejaVu Sans Mono', 'Menlo', 'Consolas', 'monospace'],
    fontSize: size,
    fontWeight: weight,
    color: color,
  );
}
