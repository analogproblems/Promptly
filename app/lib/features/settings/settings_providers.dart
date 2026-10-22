import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../hosts/session_labels.dart';

/// Keys of the app's settings. These are wire names. The engine keeps the
/// ones that make sense on every device (the look, how the terminal behaves;
/// `SYNCED_SETTINGS` in the engine's vault model) in the vault, so they
/// sync; the rest, such as the text size, stay on this device.
abstract final class SettingKeys {
  static const themeMode = 'theme_mode';
  static const terminalTheme = 'terminal_theme';
  static const programClipboard = 'program_clipboard';
  static const reachability = 'reachability_check';
  static const onboardingDone = 'onboarding_done';
  static const updateCheck = 'update_check';
  static const pasteWarning = 'paste_warning';
  static const bell = 'terminal_bell';
  static const scrollback = 'terminal_scrollback';
  static const fontSize = 'terminal_font_size';
  static const capsLockEscape = 'caps_lock_escape';
  static const cmdAsCtrl = 'cmd_as_ctrl';
  static const optionAsMeta = 'option_as_meta';
  static const collapsedGroups = 'hosts_collapsed_groups';
  static const font = 'terminal_font';
  static const ligatures = 'terminal_ligatures';
  static const autocorrect = 'terminal_autocorrect';
  static const backupNudgeDismissed = 'backup_nudge_dismissed';
}

/// Read the settings that travel in the vault again, once other devices'
/// changes have landed.
void reloadSyncedSettings(WidgetRef ref) {
  ref.invalidate(themeModeProvider);
  ref.invalidate(terminalThemeProvider);
  ref.invalidate(programClipboardProvider);
  ref.invalidate(reachabilityProvider);
  ref.invalidate(pasteWarningProvider);
  ref.invalidate(bellProvider);
  ref.invalidate(scrollbackProvider);
  ref.invalidate(sessionLabelsProvider);
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

/// A yes-or-no setting kept in the store, with its value when never set.
abstract class BoolSettingNotifier extends Notifier<bool> {
  String get key;
  bool get fallback;

  @override
  bool build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(key);
      if (raw == null) return fallback;
      final value = jsonDecode(raw);
      return value is bool ? value : fallback;
    } catch (_) {
      return fallback;
    }
  }

  void set(bool on) {
    state = on;
    try {
      ref.read(engineProvider).settingSet(key, jsonEncode(on));
    } catch (_) {}
  }
}

/// Whether pasting text with a newline in it shows it first. On by
/// default: each newline runs a command.
class PasteWarningNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.pasteWarning;
  @override
  bool get fallback => true;
}

final pasteWarningProvider = NotifierProvider<PasteWarningNotifier, bool>(PasteWarningNotifier.new);

/// Whether "Not now" was tapped on the hosts list's card that suggests
/// setting up a vault to back the hosts up. Kept on this device: another
/// device may well want the reminder.
class BackupNudgeDismissedNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.backupNudgeDismissed;
  @override
  bool get fallback => false;
}

final backupNudgeDismissedProvider =
    NotifierProvider<BackupNudgeDismissedNotifier, bool>(BackupNudgeDismissedNotifier.new);

/// Whether Caps Lock on a hardware keyboard types Escape in the terminal.
class CapsLockEscapeNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.capsLockEscape;
  @override
  bool get fallback => false;
}

final capsLockEscapeProvider = NotifierProvider<CapsLockEscapeNotifier, bool>(CapsLockEscapeNotifier.new);

/// Whether Cmd works as Ctrl in the terminal, on iPad and Mac.
class CmdAsCtrlNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.cmdAsCtrl;
  @override
  bool get fallback => false;
}

final cmdAsCtrlProvider = NotifierProvider<CmdAsCtrlNotifier, bool>(CmdAsCtrlNotifier.new);

/// Whether Option works as Alt in the terminal, on iPad and Mac, rather
/// than typing the characters the keyboard layout puts on it.
class OptionAsMetaNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.optionAsMeta;
  @override
  bool get fallback => false;
}

final optionAsMetaProvider = NotifierProvider<OptionAsMetaNotifier, bool>(OptionAsMetaNotifier.new);

/// A setting kept in the store as one JSON value, with its value when never
/// set. [decode] returns null for anything it does not accept, which reads
/// as the fallback.
abstract class JsonSettingNotifier<T> extends Notifier<T> {
  String get key;
  T get fallback;
  T? decode(Object? json);
  Object? encode(T value);

  @override
  T build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(key);
      if (raw == null) return fallback;
      return decode(jsonDecode(raw)) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  void set(T value) {
    state = value;
    try {
      ref.read(engineProvider).settingSet(key, jsonEncode(encode(value)));
    } catch (_) {}
  }
}

/// What the terminal does when a program rings the bell.
enum BellMode {
  /// The terminal flashes briefly (or, with reduced motion, shows an outline).
  flash,

  /// The phone vibrates. Where nothing can vibrate, the terminal flashes.
  vibrate,
  off,
}

class BellNotifier extends JsonSettingNotifier<BellMode> {
  @override
  String get key => SettingKeys.bell;
  @override
  BellMode get fallback => BellMode.flash;
  @override
  BellMode? decode(Object? json) => BellMode.values.where((m) => m.name == json).firstOrNull;
  @override
  Object? encode(BellMode value) => value.name;
}

final bellProvider = NotifierProvider<BellNotifier, BellMode>(BellNotifier.new);

/// How many lines of history a new terminal keeps.
class ScrollbackNotifier extends JsonSettingNotifier<int> {
  static const choices = [1000, 10000, 50000, 100000];

  @override
  String get key => SettingKeys.scrollback;
  @override
  int get fallback => 10000;
  @override
  int? decode(Object? json) => json is int && choices.contains(json) ? json : null;
  @override
  Object? encode(int value) => value;
}

final scrollbackProvider = NotifierProvider<ScrollbackNotifier, int>(ScrollbackNotifier.new);

/// The terminal's text size, as last zoomed to or picked in Settings.
class FontSizeNotifier extends JsonSettingNotifier<double> {
  static const min = 8.0;
  static const max = 40.0;
  static const normal = 14.0;

  @override
  String get key => SettingKeys.fontSize;
  @override
  double get fallback => normal;
  @override
  double? decode(Object? json) => json is num ? json.toDouble().clamp(min, max) : null;
  @override
  Object? encode(double value) => value;
}

final fontSizeProvider = NotifierProvider<FontSizeNotifier, double>(FontSizeNotifier.new);

/// The groups folded shut in the hosts list, by id.
class CollapsedGroupsNotifier extends JsonSettingNotifier<Set<String>> {
  @override
  String get key => SettingKeys.collapsedGroups;
  @override
  Set<String> get fallback => const {};
  @override
  Set<String>? decode(Object? json) => json is List ? {for (final id in json) if (id is String) id} : null;
  @override
  Object? encode(Set<String> value) => value.toList()..sort();

  void toggle(String groupId) =>
      set(state.contains(groupId) ? ({...state}..remove(groupId)) : {...state, groupId});
}

final collapsedGroupsProvider =
    NotifierProvider<CollapsedGroupsNotifier, Set<String>>(CollapsedGroupsNotifier.new);

/// The terminal font's family name; empty for the one built in. A font
/// added from a file or installed on one device may be missing on another,
/// so this stays on the device.
class FontFamilyNotifier extends JsonSettingNotifier<String> {
  @override
  String get key => SettingKeys.font;
  @override
  String get fallback => '';
  @override
  String? decode(Object? json) => json is String ? json : null;
  @override
  Object? encode(String value) => value;
}

final fontFamilyProvider = NotifierProvider<FontFamilyNotifier, String>(FontFamilyNotifier.new);

/// Whether the terminal joins pairs such as `->` and `!=` into one symbol,
/// in fonts that have them. Off by default.
class LigaturesNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.ligatures;
  @override
  bool get fallback => false;
}

final ligaturesProvider = NotifierProvider<LigaturesNotifier, bool>(LigaturesNotifier.new);

/// Whether a phone or tablet keyboard may suggest and correct words in the
/// terminal. Off by default: commands are rarely dictionary words.
class AutocorrectNotifier extends BoolSettingNotifier {
  @override
  String get key => SettingKeys.autocorrect;
  @override
  bool get fallback => false;
}

final autocorrectProvider = NotifierProvider<AutocorrectNotifier, bool>(AutocorrectNotifier.new);
