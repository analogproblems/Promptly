import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/engine/engine.dart';
import 'terminal_grid.dart';

/// Owns one session on the Dart side: the grid mirror, the event stream, and
/// the calls into the engine. One per open session; the view is disposable.
class TerminalController extends ChangeNotifier {
  TerminalController({required this.engine, required this.id, required this.label});

  final Engine engine;
  final int id;

  /// What to call the session before the program sets a title.
  final String label;

  final TerminalGrid grid = TerminalGrid();
  StreamSubscription<TerminalEvent>? _sub;

  bool exited = false;
  int? exitCode;
  bool bell = false;
  double fontSize = 14;

  /// Called when the program asks to put text on the clipboard (OSC 52).
  /// Unset means the request is ignored.
  void Function(String text)? onClipboard;

  int _cols = 0;
  int _rows = 0;

  String get title => grid.title?.trim().isNotEmpty == true ? grid.title!.trim() : label;

  void start() {
    _sub ??= engine.terminalEvents(id).listen(_onEvent, onError: (_) {});
  }

  void _onEvent(TerminalEvent e) {
    switch (e.kind) {
      case TerminalEventKind.frame:
        final f = e.frame;
        if (f != null) {
          grid.apply(f);
          if (f.bell) bell = true;
        }
      case TerminalEventKind.clipboard:
        final text = e.clipboard;
        if (text != null && text.isNotEmpty) onClipboard?.call(text);
      case TerminalEventKind.exited:
        exited = true;
        exitCode = e.exitCode;
    }
    notifyListeners();
  }

  void write(List<int> bytes) {
    if (exited) return;
    _guard(() => engine.terminalWrite(id, bytes));
  }

  /// Modifiers the keyboard bar holds down for the next key, since a phone
  /// keyboard has no Ctrl or Alt of its own. One-shot: typing clears them,
  /// unless they are locked, which keeps them down until turned off.
  bool stickyCtrl = false;
  bool stickyAlt = false;
  bool lockedCtrl = false;
  bool lockedAlt = false;

  /// Hold or let go of a modifier. Locking holds it too; letting go of it
  /// unlocks it.
  void setSticky({bool? ctrl, bool? alt, bool? lockCtrl, bool? lockAlt}) {
    if (ctrl != null) stickyCtrl = ctrl;
    if (alt != null) stickyAlt = alt;
    if (lockCtrl != null) lockedCtrl = lockCtrl;
    if (lockAlt != null) lockedAlt = lockAlt;
    if (lockedCtrl) stickyCtrl = true;
    if (lockedAlt) stickyAlt = true;
    if (!stickyCtrl) lockedCtrl = false;
    if (!stickyAlt) lockedAlt = false;
    notifyListeners();
  }

  /// After a key: one-shot modifiers let go, locked ones stay down.
  void releaseSticky() {
    if (stickyCtrl == lockedCtrl && stickyAlt == lockedAlt) return;
    stickyCtrl = lockedCtrl;
    stickyAlt = lockedAlt;
    notifyListeners();
  }

  /// Typed text as bytes for the program, through the sticky modifiers:
  /// Ctrl turns a letter into its control byte, Alt prefixes Escape. Both
  /// are released afterwards unless locked.
  List<int> encodeTyped(String text) {
    if (!stickyCtrl && !stickyAlt) return utf8.encode(text);
    final out = <int>[];
    for (final rune in text.runes) {
      if (stickyAlt) out.add(0x1b);
      if (stickyCtrl) {
        final u = String.fromCharCode(rune).toUpperCase().codeUnitAt(0);
        if (u >= 0x40 && u <= 0x5f) {
          out.add(u & 0x1f);
          continue;
        }
        if (rune == 0x20 || rune == 0x32) {
          out.add(0);
          continue;
        }
        if (rune == 0x3f) {
          out.add(0x7f);
          continue;
        }
      }
      out.addAll(utf8.encode(String.fromCharCode(rune)));
    }
    releaseSticky();
    return out;
  }

  void paste(String text) {
    if (exited || text.isEmpty) return;
    _guard(() => engine.terminalPaste(id, text));
  }

  /// Hand a mouse event to the program when it asked for mouse events
  /// (vim, tmux). False means it did not, and the view handles it locally.
  bool mouse(
    TerminalMouseAction action,
    TerminalMouseButton? button,
    int col,
    int row, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    if (exited || !grid.mouseReporting) return false;
    try {
      return engine.terminalMouse(id, action, button, col, row, shift: shift, alt: alt, ctrl: ctrl);
    } catch (e) {
      debugPrint('[promptly] engine call failed for session $id: $e');
      return false;
    }
  }

  void resize(int cols, int rows) {
    if (cols <= 0 || rows <= 0 || (cols == _cols && rows == _rows)) return;
    _cols = cols;
    _rows = rows;
    _guard(() => engine.terminalResize(id, cols, rows));
  }

  void scroll(int delta) => _guard(() => engine.terminalScroll(id, delta));

  void scrollToBottom() => _guard(() => engine.terminalScrollToBottom(id));

  void setTheme(String theme) => _guard(() => engine.terminalSetTheme(id, theme));

  void refresh() => _guard(() => engine.terminalRefresh(id));

  /// Show a message from Promptly in the terminal; nothing goes to the program.
  void notice(String text) => _guard(() => engine.terminalNotice(id, text));

  /// The session got a new connection after it dropped: it is live again.
  void revive() {
    exited = false;
    exitCode = null;
    notifyListeners();
  }

  bool _selecting = false;

  /// Start a selection at a viewport cell. A plain click starts an empty
  /// one, which also drops whatever was selected before.
  void selectBegin(int col, int line, bool sideRight, TerminalSelectKind kind) {
    _selecting = true;
    _guard(() => engine.terminalSelectBegin(id, col, line, sideRight, kind));
  }

  void selectUpdate(int col, int line, bool sideRight) {
    if (!_selecting) return;
    _guard(() => engine.terminalSelectUpdate(id, col, line, sideRight));
  }

  void selectClear() {
    if (!_selecting) return;
    _selecting = false;
    _guard(() => engine.terminalSelectClear(id));
  }

  /// The selected text, or null when nothing is selected.
  String? selectionText() {
    if (!_selecting) return null;
    try {
      return engine.terminalSelectionText(id);
    } catch (_) {
      return null;
    }
  }

  // ---- Search and links ---------------------------------------------------

  /// Search the screen and scrollback; null or empty stops searching and
  /// drops the highlighted match.
  void searchSet(String? query) {
    final q = query?.trim();
    if (q == null || q.isEmpty) {
      _selecting = false;
      _guard(() => engine.terminalSearchSet(id, null));
    } else {
      _guard(() => engine.terminalSearchSet(id, q));
    }
  }

  /// Move to the next match: up into history when `backward`. The match
  /// becomes the selection, so Copy works on it.
  TerminalSearchHit? searchStep({required bool backward}) {
    try {
      final hit = engine.terminalSearchStep(id, backward);
      if (hit != null) _selecting = true;
      return hit;
    } catch (_) {
      return null;
    }
  }

  /// The link under a viewport cell, if any.
  String? linkAt(int col, int line) {
    try {
      return engine.terminalLinkAt(id, col, line);
    } catch (_) {
      return null;
    }
  }

  /// Called after the text size changes, so it can be remembered.
  void Function(double size)? onFontSize;

  void setFontSize(double size) {
    final next = size.clamp(8, 40).toDouble();
    if (next == fontSize) return;
    fontSize = next;
    onFontSize?.call(next);
    notifyListeners();
  }

  /// Acknowledge a bell after the view has flashed it.
  void clearBell() => bell = false;

  void _guard(void Function() call) {
    try {
      call();
    } catch (e) {
      // The session is gone; the Exited event (or close) handles the rest.
      debugPrint('[promptly] engine call failed for session $id: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
