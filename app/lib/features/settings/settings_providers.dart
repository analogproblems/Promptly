import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';

/// Keys in the engine's settings table. These are wire names: a change here
/// is a change to what the vault syncs.
abstract final class SettingKeys {
  static const themeMode = 'theme_mode';
  static const terminalTheme = 'terminal_theme';
  static const programClipboard = 'program_clipboard';
  static const reachability = 'reachability_check';
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

/// Whether a program in the terminal may put text on the clipboard (OSC 52,
/// as tmux and vim use). Off by default: a remote program should not be
/// able to read or replace what you copied without you knowing.
class ProgramClipboardNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(SettingKeys.programClipboard);
      return raw != null && jsonDecode(raw) == true;
    } catch (_) {
      return false;
    }
  }

  void set(bool on) {
    state = on;
    try {
      ref.read(engineProvider).settingSet(SettingKeys.programClipboard, jsonEncode(on));
    } catch (_) {}
  }
}

final programClipboardProvider =
    NotifierProvider<ProgramClipboardNotifier, bool>(ProgramClipboardNotifier.new);

/// Whether the hosts list knocks on each host's port to show which are up.
class ReachabilityNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(SettingKeys.reachability);
      return raw != null && jsonDecode(raw) == true;
    } catch (_) {
      return false;
    }
  }

  void set(bool on) {
    state = on;
    try {
      ref.read(engineProvider).settingSet(SettingKeys.reachability, jsonEncode(on));
    } catch (_) {}
  }
}

final reachabilityProvider = NotifierProvider<ReachabilityNotifier, bool>(ReachabilityNotifier.new);
