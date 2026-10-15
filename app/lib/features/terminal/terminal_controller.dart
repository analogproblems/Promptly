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
        // OSC 52 writes are gated by a setting that lands with the vault; ignored for now.
        break;
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

  void setDark(bool dark) => _guard(() => engine.terminalSetDark(id, dark));

  void refresh() => _guard(() => engine.terminalRefresh(id));

  void setFontSize(double size) {
    fontSize = size.clamp(8, 40);
    notifyListeners();
  }

  /// Acknowledge a bell after the view has flashed it.
  void clearBell() => bell = false;

  void _guard(void Function() call) {
    try {
      call();
    } catch (_) {
      // The session is gone; the Exited event (or close) handles the rest.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
