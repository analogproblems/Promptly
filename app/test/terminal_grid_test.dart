import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/features/terminal/terminal_grid.dart';

TerminalRow row(int line, String text, {int fg = 0xE6EDF3, int bg = 0x0E1116}) {
  final glyphs = text.split('').map((c) => c == ' ' ? '' : c).toList();
  final n = glyphs.length;
  return TerminalRow(
    line: line,
    glyphs: glyphs,
    fg: Uint32List(n)..fillRange(0, n, fg),
    bg: Uint32List(n)..fillRange(0, n, bg),
    flags: Uint16List(n),
    underline: Uint32List(n)..fillRange(0, n, fg),
  );
}

TerminalFrame frame({required bool full, required List<TerminalRow> rows, int cols = 5, int lines = 2}) =>
    TerminalFrame(
      cols: cols,
      rows: lines,
      full: full,
      rowsChanged: rows,
      cursor: const TerminalCursor(line: 0, col: 0, shape: TerminalCursorShape.block),
      displayOffset: 0,
      historyLen: 0,
      defaultFg: 0xE6EDF3,
      defaultBg: 0x0E1116,
      cursorColor: 0x7CE38B,
      title: null,
      bell: false,
      appCursor: false,
      altScreen: false,
      bracketedPaste: false,
      mouseReporting: false,
    );

void main() {
  test('a full frame replaces the grid and partial frames patch rows', () {
    final g = TerminalGrid();
    g.apply(frame(full: true, rows: [row(0, 'hello'), row(1, 'world')]));
    expect(g.text, 'hello\nworld');
    expect(g.generation, 1);

    g.apply(frame(full: false, rows: [row(1, 'there')]));
    expect(g.text, 'hello\nthere');

    // A resize without `full` still rebuilds, so stale rows never linger.
    g.apply(frame(full: false, rows: [row(0, 'abc')], cols: 3, lines: 3));
    expect(g.cols, 3);
    expect(g.lines.length, 3);
    expect(g.text, 'abc\n\n');
  });
}
