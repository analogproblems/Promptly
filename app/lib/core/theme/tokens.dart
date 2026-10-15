import 'package:flutter/material.dart';

/// Design tokens from docs/DESIGN.md section 7.2.
///
/// These are the UI chrome colours. The terminal's own colours always come
/// from the active terminal theme, never from here.
@immutable
class PromptlyTokens extends ThemeExtension<PromptlyTokens> {
  const PromptlyTokens({
    required this.background,
    required this.surface,
    required this.border,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.danger,
    required this.warning,
  });

  final Color background;
  final Color surface;
  final Color border;
  final Color text;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color danger;
  final Color warning;

  static const dark = PromptlyTokens(
    background: Color(0xFF0E1116),
    surface: Color(0xFF161B22),
    border: Color(0xFF262D37),
    text: Color(0xFFE6EDF3),
    muted: Color(0xFF8B949E),
    accent: Color(0xFF7CE38B),
    onAccent: Color(0xFF0E1116),
    danger: Color(0xFFFF7B72),
    warning: Color(0xFFE3B341),
  );

  static const light = PromptlyTokens(
    background: Color(0xFFFAFAF7),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFE6E4DD),
    text: Color(0xFF1F2328),
    muted: Color(0xFF656D76),
    accent: Color(0xFF1A7F37),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFCF222E),
    warning: Color(0xFF9A6700),
  );

  /// Corner radius for panels and cards.
  static const double panelRadius = 10;

  /// Corner radius for buttons and inputs.
  static const double controlRadius = 6;

  /// The bundled terminal font. Also used for host labels and snippets so
  /// the app reads as one thing.
  static const String monoFamily = 'JetBrains Mono';

  @override
  PromptlyTokens copyWith({
    Color? background,
    Color? surface,
    Color? border,
    Color? text,
    Color? muted,
    Color? accent,
    Color? onAccent,
    Color? danger,
    Color? warning,
  }) {
    return PromptlyTokens(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      danger: danger ?? this.danger,
      warning: warning ?? this.warning,
    );
  }

  @override
  PromptlyTokens lerp(PromptlyTokens? other, double t) {
    if (other == null) return this;
    return PromptlyTokens(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

extension PromptlyTokensContext on BuildContext {
  PromptlyTokens get tokens => Theme.of(this).extension<PromptlyTokens>()!;
}
