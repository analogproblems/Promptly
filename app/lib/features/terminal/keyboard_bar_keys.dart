import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';

/// One key the keyboard bar can carry: what it shows, what a screen reader
/// says, and what it types. A key with [char] types that character through
/// the sticky modifiers; the rest send a sequence from [barKeySequence].
class BarKey {
  const BarKey(this.id, this.label, this.spoken, {this.char});

  /// The stored name, and the widget key `kb-<id>`. Never rename one: the
  /// setting holds these.
  final String id;
  final String label;
  final String spoken;
  final String? char;

  bool get isModifier => id == 'ctrl' || id == 'alt';
  bool get isArrow => id == 'left' || id == 'down' || id == 'up' || id == 'right';
}

/// Every key the bar can show, in the order the settings page lists them.
final barKeys = <BarKey>[
  const BarKey('esc', 'Esc', 'Escape'),
  const BarKey('tab', 'Tab', 'Tab'),
  const BarKey('ctrl', 'Ctrl', 'Control'),
  const BarKey('alt', 'Alt', 'Alt'),
  const BarKey('left', '←', 'Left arrow'),
  const BarKey('down', '↓', 'Down arrow'),
  const BarKey('up', '↑', 'Up arrow'),
  const BarKey('right', '→', 'Right arrow'),
  const BarKey('dash', '-', 'Dash', char: '-'),
  const BarKey('slash', '/', 'Slash', char: '/'),
  const BarKey('pipe', '|', 'Pipe', char: '|'),
  const BarKey('tilde', '~', 'Tilde', char: '~'),
  const BarKey('colon', ':', 'Colon', char: ':'),
  const BarKey('home', 'Home', 'Home'),
  const BarKey('end', 'End', 'End'),
  const BarKey('pgup', 'PgUp', 'Page up'),
  const BarKey('pgdn', 'PgDn', 'Page down'),
  const BarKey('del', 'Del', 'Delete'),
  // Not on the bar until chosen in Settings.
  const BarKey('underscore', '_', 'Underscore', char: '_'),
  const BarKey('backslash', r'\', 'Backslash', char: r'\'),
  const BarKey('star', '*', 'Star', char: '*'),
  const BarKey('amp', '&', 'Ampersand', char: '&'),
  const BarKey('semicolon', ';', 'Semicolon', char: ';'),
  const BarKey('quote', "'", 'Single quote', char: "'"),
  const BarKey('dquote', '"', 'Double quote', char: '"'),
  const BarKey('backtick', '`', 'Backtick', char: '`'),
  const BarKey('lt', '<', 'Less than', char: '<'),
  const BarKey('gt', '>', 'Greater than', char: '>'),
  const BarKey('lbracket', '[', 'Left bracket', char: '['),
  const BarKey('rbracket', ']', 'Right bracket', char: ']'),
  const BarKey('lbrace', '{', 'Left brace', char: '{'),
  const BarKey('rbrace', '}', 'Right brace', char: '}'),
  const BarKey('dollar', r'$', 'Dollar', char: r'$'),
  const BarKey('hash', '#', 'Hash', char: '#'),
  const BarKey('equals', '=', 'Equals', char: '='),
  const BarKey('bang', '!', 'Exclamation mark', char: '!'),
  const BarKey('at', '@', 'At sign', char: '@'),
  const BarKey('ins', 'Ins', 'Insert'),
  for (var n = 1; n <= 12; n++) BarKey('f$n', 'F$n', 'F$n'),
];

final _byId = {for (final k in barKeys) k.id: k};

BarKey? barKeyById(String id) => _byId[id];

/// The bar as it comes: the keys a phone keyboard lacks most.
const defaultBarLayout = <String>[
  'esc', 'tab', 'ctrl', 'alt', 'left', 'down', 'up', 'right', //
  'dash', 'slash', 'pipe', 'tilde', 'colon', 'home', 'end', 'pgup', 'pgdn', 'del',
];

/// What a non-character key sends, as xterm does. With Ctrl or Alt held,
/// the cursor and editing keys carry the modifier in the sequence (Ctrl+Left
/// is `ESC [ 1 ; 5 D`), which is what shells and editors read as "a word
/// left". Other keys get Escape in front for Alt. `appCursor` is the
/// program's cursor-key mode, which only changes unmodified arrows.
List<int> barKeySequence(String id, {bool ctrl = false, bool alt = false, bool appCursor = false}) {
  // xterm's modifier parameter: 1, plus 2 for Alt, plus 4 for Ctrl.
  final mod = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
  List<int> csi(String body) => [0x1b, 0x5b, ...body.codeUnits];

  // ESC [ 1 ; m X when modified, otherwise the short form.
  List<int> letter(String x, {bool ss3 = false}) {
    if (mod > 1) return csi('1;$mod$x');
    return ss3 ? [0x1b, 0x4f, x.codeUnitAt(0)] : csi(x);
  }

  // ESC [ n ; m ~ when modified, otherwise ESC [ n ~.
  List<int> tilde(int n) => csi(mod > 1 ? '$n;$mod~' : '$n~');

  switch (id) {
    case 'up':
      return letter('A', ss3: appCursor);
    case 'down':
      return letter('B', ss3: appCursor);
    case 'right':
      return letter('C', ss3: appCursor);
    case 'left':
      return letter('D', ss3: appCursor);
    case 'home':
      return letter('H');
    case 'end':
      return letter('F');
    case 'ins':
      return tilde(2);
    case 'del':
      return tilde(3);
    case 'pgup':
      return tilde(5);
    case 'pgdn':
      return tilde(6);
    case 'f1' || 'f2' || 'f3' || 'f4':
      final x = 'PQRS'[int.parse(id.substring(1)) - 1];
      return mod > 1 ? csi('1;$mod$x') : [0x1b, 0x4f, x.codeUnitAt(0)];
    case 'f5' || 'f6' || 'f7' || 'f8' || 'f9' || 'f10' || 'f11' || 'f12':
      const codes = {5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24};
      return tilde(codes[int.parse(id.substring(1))]!);
    case 'esc':
      return [if (alt) 0x1b, 0x1b];
    case 'tab':
      return [if (alt) 0x1b, 0x09];
  }
  return const [];
}

/// The keys on the bar, in order, as chosen in Settings. Stored in the
/// engine's settings table under its own key.
class BarLayoutNotifier extends Notifier<List<String>> {
  static const settingKey = 'keyboard_bar_keys';

  @override
  List<String> build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(settingKey);
      if (raw == null) return defaultBarLayout;
      final value = jsonDecode(raw);
      if (value is! List) return defaultBarLayout;
      // Known keys only, each once: a key from a newer version is skipped.
      final ids = <String>[];
      for (final id in value) {
        if (id is String && _byId.containsKey(id) && !ids.contains(id)) ids.add(id);
      }
      return ids;
    } catch (_) {
      return defaultBarLayout;
    }
  }

  void set(List<String> ids) {
    state = List.unmodifiable(ids);
    try {
      ref.read(engineProvider).settingSet(settingKey, jsonEncode(ids));
    } catch (_) {
      // A store that cannot be written still leaves the layout live for this run.
    }
  }

  void add(String id) {
    if (!state.contains(id)) set([...state, id]);
  }

  void remove(String id) => set([...state.where((k) => k != id)]);

  void move(int from, int to) {
    final ids = [...state];
    final id = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), id);
    set(ids);
  }

  void reset() => set(defaultBarLayout);
}

final barLayoutProvider = NotifierProvider<BarLayoutNotifier, List<String>>(BarLayoutNotifier.new);
