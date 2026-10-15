import 'dart:convert';

import 'package:flutter/services.dart';

/// Turns a key press into the bytes a terminal program expects.
///
/// Returns null for keys the terminal does not consume (so the app can use
/// them as shortcuts) and for key-up events.
abstract final class KeyMapper {
  static const _esc = 0x1b;

  static List<int>? bytesFor(
    KeyEvent event, {
    required bool appCursor,
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    if (event is KeyUpEvent) return null;
    final key = event.logicalKey;

    // Keys that are the app's, never the terminal's.
    if (ctrl && shift && (key == LogicalKeyboardKey.keyC || key == LogicalKeyboardKey.keyV)) {
      return null;
    }
    if (shift && (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.pageDown)) {
      return null;
    }

    final mod = _modifierParam(ctrl: ctrl, alt: alt, shift: shift);

    List<int>? bytes = switch (key) {
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => [0x0d],
      LogicalKeyboardKey.backspace => ctrl ? [0x08] : [0x7f],
      LogicalKeyboardKey.tab => shift ? _csi('Z') : [0x09],
      LogicalKeyboardKey.escape => [_esc],
      LogicalKeyboardKey.arrowUp => _cursorKey('A', appCursor, mod),
      LogicalKeyboardKey.arrowDown => _cursorKey('B', appCursor, mod),
      LogicalKeyboardKey.arrowRight => _cursorKey('C', appCursor, mod),
      LogicalKeyboardKey.arrowLeft => _cursorKey('D', appCursor, mod),
      LogicalKeyboardKey.home => _cursorKey('H', appCursor, mod),
      LogicalKeyboardKey.end => _cursorKey('F', appCursor, mod),
      LogicalKeyboardKey.insert => _tilde(2, mod),
      LogicalKeyboardKey.delete => _tilde(3, mod),
      LogicalKeyboardKey.pageUp => _tilde(5, mod),
      LogicalKeyboardKey.pageDown => _tilde(6, mod),
      LogicalKeyboardKey.f1 => _ss3('P', mod),
      LogicalKeyboardKey.f2 => _ss3('Q', mod),
      LogicalKeyboardKey.f3 => _ss3('R', mod),
      LogicalKeyboardKey.f4 => _ss3('S', mod),
      LogicalKeyboardKey.f5 => _tilde(15, mod),
      LogicalKeyboardKey.f6 => _tilde(17, mod),
      LogicalKeyboardKey.f7 => _tilde(18, mod),
      LogicalKeyboardKey.f8 => _tilde(19, mod),
      LogicalKeyboardKey.f9 => _tilde(20, mod),
      LogicalKeyboardKey.f10 => _tilde(21, mod),
      LogicalKeyboardKey.f11 => _tilde(23, mod),
      LogicalKeyboardKey.f12 => _tilde(24, mod),
      _ => null,
    };
    if (bytes != null) return bytes;

    if (ctrl) {
      final c = _controlByte(key);
      if (c != null) return alt ? [_esc, c] : [c];
      return null;
    }

    final ch = event.character;
    if (ch == null || ch.isEmpty) return null;
    final code = ch.codeUnitAt(0);
    if (ch.length == 1 && (code < 0x20 || code == 0x7f)) return null;
    final encoded = utf8.encode(ch);
    return alt ? [_esc, ...encoded] : encoded;
  }

  /// xterm's modifier parameter: 1 plus shift=1, alt=2, ctrl=4.
  static int _modifierParam({required bool ctrl, required bool alt, required bool shift}) {
    var m = 1;
    if (shift) m += 1;
    if (alt) m += 2;
    if (ctrl) m += 4;
    return m;
  }

  static List<int> _csi(String tail) => [_esc, 0x5b, ...tail.codeUnits];

  static List<int> _cursorKey(String letter, bool appCursor, int mod) {
    if (mod > 1) return _csi('1;$mod$letter');
    return appCursor ? [_esc, 0x4f, letter.codeUnitAt(0)] : _csi(letter);
  }

  static List<int> _ss3(String letter, int mod) {
    if (mod > 1) return _csi('1;$mod$letter');
    return [_esc, 0x4f, letter.codeUnitAt(0)];
  }

  static List<int> _tilde(int n, int mod) => mod > 1 ? _csi('$n;$mod~') : _csi('$n~');

  static int? _controlByte(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1) {
      final c = label.toLowerCase().codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) return c - 0x60; // a..z -> 1..26
      switch (label) {
        case '[':
          return 0x1b;
        case '\\':
          return 0x1c;
        case ']':
          return 0x1d;
        case '^':
        case '6':
          return 0x1e;
        case '_':
        case '-':
        case '/':
          return 0x1f;
        case '@':
        case '2':
          return 0x00;
        case ' ':
          return 0x00;
      }
    }
    if (key == LogicalKeyboardKey.space) return 0x00;
    return null;
  }
}
