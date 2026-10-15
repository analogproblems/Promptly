import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';

/// Keys in the engine's settings table. These are wire names: a change here
/// is a change to what the vault syncs.
abstract final class SettingKeys {
  static const themeMode = 'theme_mode';
  static const terminalTheme = 'terminal_theme';
}

String? _readString(Engine engine, String key) {
  try {
    final raw = engine.settingGet(key);
    if (raw == null) return null;
    final value = jsonDecode(raw);
    return value is String ? value : null;
  } catch (_) {
    return null;
  }
}

void _writeString(Engine engine, String key, String value) {
  try {
    engine.settingSet(key, jsonEncode(value));
  } catch (_) {
    // A store that cannot be written still leaves the setting live for this run.
  }
}

/// Light, dark or follow the system, remembered in the store.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    return switch (_readString(ref.watch(engineProvider), SettingKeys.themeMode)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  void set(ThemeMode mode) {
    state = mode;
    _writeString(ref.read(engineProvider), SettingKeys.themeMode, mode.name);
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// Which terminal theme to use: a theme id from the gallery, or [auto] for
/// Promptly Dark or Light, whichever matches the app.
class TerminalThemeNotifier extends Notifier<String> {
  static const auto = 'auto';

  @override
  String build() =>
      _readString(ref.watch(engineProvider), SettingKeys.terminalTheme) ?? auto;

  void set(String idOrAuto) {
    state = idOrAuto;
    _writeString(ref.read(engineProvider), SettingKeys.terminalTheme, idOrAuto);
  }
}

final terminalThemeProvider =
    NotifierProvider<TerminalThemeNotifier, String>(TerminalThemeNotifier.new);

/// Turn the setting into a concrete theme id for the app's brightness.
String resolveTerminalTheme(String setting, Brightness brightness) {
  if (setting != TerminalThemeNotifier.auto) return setting;
  return brightness == Brightness.dark ? 'promptly-dark' : 'promptly-light';
}

/// The theme id a session opened from this screen should start with.
String terminalThemeFor(WidgetRef ref, BuildContext context) =>
    resolveTerminalTheme(ref.read(terminalThemeProvider), Theme.of(context).brightness);

/// The gallery, read from the engine once.
final themesProvider = Provider<List<ThemeInfo>>((ref) => ref.watch(engineProvider).themesList());
