import 'package:flutter/material.dart';

import 'nlp/triage_parser.dart';

/// Colours for the watch screen. They match the hospital board
/// (`hub/public/index.html`): teal for actions and selection, and the same
/// tinted category colours. Light and dark follow the system setting.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.panel,
    required this.text,
    required this.dim,
    required this.accent,
    required this.onAccent,
    required this.listening,
    required this.onListening,
  });

  final Color background;
  final Color panel;
  final Color text;
  final Color dim;
  final Color accent;
  final Color onAccent;
  final Color listening;
  final Color onListening;

  static const light = AppColors(
    background: Color(0xFFEAF4F6),
    panel: Color(0xFFEFF8FA),
    text: Color(0xFF16323A),
    dim: Color(0xFF4A6670),
    accent: Color(0xFF087F90),
    onAccent: Color(0xFFFFFFFF),
    listening: Color(0xFFB91C1C),
    onListening: Color(0xFFFFFFFF),
  );

  static const dark = AppColors(
    background: Color(0xFF061419),
    panel: Color(0xFF143B47),
    text: Color(0xFFE3F4F7),
    dim: Color(0xFFA9C8D0),
    accent: Color(0xFF3CC8D9),
    onAccent: Color(0xFF00262C),
    listening: Color(0xFFFCA5A5),
    onListening: Color(0xFF00262C),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) =>
      t < 0.5 ? this : (other as AppColors? ?? this);
}

/// A category's tinted surface: [background] and [foreground] are used
/// together for text, [accent] is the marker or outline colour.
@immutable
class TriageStyle {
  const TriageStyle(this.background, this.foreground, this.accent);
  final Color background;
  final Color foreground;
  final Color accent;
}

/// Same tints as the board's category chips. Colour is never the only signal:
/// the category name is always written out next to it.
TriageStyle triageStyle(String triage, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (triage) {
    TriageParser.immediate =>
      dark
          ? const TriageStyle(
              Color(0xFF4A1D1D),
              Color(0xFFFCA5A5),
              Color(0xFFF87171),
            )
          : const TriageStyle(
              Color(0xFFFEE2E2),
              Color(0xFF991B1B),
              Color(0xFFDC2626),
            ),
    TriageParser.delayed =>
      dark
          ? const TriageStyle(
              Color(0xFF422006),
              Color(0xFFFCD34D),
              Color(0xFFFBBF24),
            )
          : const TriageStyle(
              Color(0xFFFEF3C7),
              Color(0xFF92400E),
              Color(0xFFD97706),
            ),
    TriageParser.minor =>
      dark
          ? const TriageStyle(
              Color(0xFF064E3B),
              Color(0xFF6EE7B7),
              Color(0xFF34D399),
            )
          : const TriageStyle(
              Color(0xFFD1FAE5),
              Color(0xFF065F46),
              Color(0xFF059669),
            ),
    TriageParser.deceased =>
      dark
          ? const TriageStyle(
              Color(0xFF1E293B),
              Color(0xFFCBD5E1),
              Color(0xFF94A3B8),
            )
          : const TriageStyle(
              Color(0xFFE2E8F0),
              Color(0xFF334155),
              Color(0xFF64748B),
            ),
    // Unassessed ("Not sure" on the board): plain surface with a dashed look.
    _ =>
      dark
          ? const TriageStyle(
              Color(0xFF0F2F39),
              Color(0xFFE3F4F7),
              Color(0xFFA9C8D0),
            )
          : const TriageStyle(
              Color(0xFFFFFFFF),
              Color(0xFF16323A),
              Color(0xFF64748B),
            ),
  };
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: c.background,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: brightness,
        ).copyWith(
          primary: c.accent,
          onPrimary: c.onAccent,
          surface: c.background,
          onSurface: c.text,
        ),
    textTheme: ThemeData(brightness: brightness).textTheme
        .apply(bodyColor: c.text, displayColor: c.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.panel,
        disabledForegroundColor: c.dim,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    extensions: [c],
  );
}
