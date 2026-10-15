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

  void paste(String text) {
    if (exited || text.isEmpty) return;
    _guard(() => engine.terminalPaste(id, text));
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

  void setFontSize(double size) {
    fontSize = size.clamp(8, 40);
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
