import 'dart:typed_data';

import '../../core/engine/engine.dart';

/// Style bits on a cell. Must match `promptly_term::frame::flags`.
abstract final class CellFlags {
  static const bold = 1 << 0;
  static const italic = 1 << 1;
  static const underline = 1 << 2;
  static const strikeout = 1 << 3;
  static const dim = 1 << 4;
  static const wide = 1 << 5;
  static const wideSpacer = 1 << 6;
  static const doubleUnderline = 1 << 7;
  static const undercurl = 1 << 8;
  static const dottedUnderline = 1 << 9;
  static const dashedUnderline = 1 << 10;
  static const selected = 1 << 11;
  static const match = 1 << 12;
  static const link = 1 << 13;

  static const anyUnderline =
      underline | doubleUnderline | undercurl | dottedUnderline | dashedUnderline;
}

/// One row of cells. The lists are shared with the frame that delivered them;
/// a row is replaced whole, never edited in place.
class GridRow {
  GridRow(this.glyphs, this.fg, this.bg, this.flags);

  factory GridRow.blank(int cols, int fg, int bg) => GridRow(
        List<String>.filled(cols, ''),
        Uint32List(cols)..fillRange(0, cols, fg),
        Uint32List(cols)..fillRange(0, cols, bg),
        Uint16List(cols),
      );

  final List<String> glyphs;
  final Uint32List fg;
  final Uint32List bg;
  final Uint16List flags;
}

/// The app's mirror of the engine's screen. Frames update it; the painter
/// reads it.
class TerminalGrid {
  int cols = 0;
  int rows = 0;
  List<GridRow> lines = const [];
  TerminalCursor cursor = const TerminalCursor(line: 0, col: 0, shape: TerminalCursorShape.block);
  int displayOffset = 0;
  int historyLen = 0;
  int defaultFg = 0xE6EDF3;
  int defaultBg = 0x0E1116;
  int cursorColor = 0x7CE38B;
  String? title;
  bool appCursor = false;
  bool altScreen = false;
  bool bracketedPaste = false;
  bool mouseReporting = false;

  /// Counts frames applied, so listeners can tell "same grid, new content".
  int generation = 0;

  void apply(TerminalFrame f) {
    final resized = f.cols != cols || f.rows != rows;
    cols = f.cols;
    rows = f.rows;
    defaultFg = f.defaultFg;
    defaultBg = f.defaultBg;
    cursorColor = f.cursorColor;
    if (f.full || resized || lines.length != rows) {
      lines = List<GridRow>.generate(rows, (_) => GridRow.blank(cols, defaultFg, defaultBg));
    }
    for (final r in f.rowsChanged) {
      if (r.line < rows) {
        lines[r.line] = GridRow(r.glyphs, r.fg, r.bg, r.flags);
      }
    }
    cursor = f.cursor;
    displayOffset = f.displayOffset;
    historyLen = f.historyLen;
    title = f.title;
    appCursor = f.appCursor;
    altScreen = f.altScreen;
    bracketedPaste = f.bracketedPaste;
    mouseReporting = f.mouseReporting;
    generation++;
  }

  /// Plain text of the screen, for tests.
  String get text => lines
      .map((r) => r.glyphs.map((g) => g.isEmpty ? ' ' : g).join().trimRight())
      .join('\n');
}
