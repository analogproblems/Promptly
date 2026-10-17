import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/features/terminal/link_kind.dart';
import 'package:promptly/features/terminal/terminal_grid.dart';
import 'package:promptly/features/terminal/terminal_painter.dart';

/// A grid of one row whose cells carry these flags and underline colours.
TerminalGrid gridOf(List<int> flags, List<int> underline) {
  final n = flags.length;
  final grid = TerminalGrid()
    ..apply(
      TerminalFrame(
        cols: n,
        rows: 1,
        full: true,
        rowsChanged: [
          TerminalRow(
            line: 0,
            glyphs: List.filled(n, 'x'),
            fg: Uint32List(n)..fillRange(0, n, 0xE6EDF3),
            bg: Uint32List(n)..fillRange(0, n, 0x0E1116),
            flags: Uint16List.fromList(flags),
            underline: Uint32List.fromList(underline),
          ),
        ],
        cursor: const TerminalCursor(line: 0, col: 0, shape: TerminalCursorShape.hidden),
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
      ),
    );
  return grid;
}

/// Keeps the rectangles and paths painted, with their colours.
class _Recorder implements Canvas {
  final List<(Rect, Color)> rects = [];
  final List<(Color, PaintingStyle)> paths = [];

  @override
  void drawRect(Rect rect, Paint paint) => rects.add((rect, paint.color));

  @override
  void drawPath(Path path, Paint paint) => paths.add((paint.color, paint.style));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('each underline style is drawn its own way, in its own colour', (tester) async {
    const green = 0x00FF00, red = 0xFF0000, blue = 0x0000FF, grey = 0x123456, pink = 0xFF00FF;
    final grid = gridOf(
      [
        CellFlags.underline,
        CellFlags.undercurl,
        CellFlags.dottedUnderline,
        CellFlags.dashedUnderline,
        CellFlags.doubleUnderline,
      ],
      [green, red, blue, grey, pink],
    );
    final metrics = CellMetrics.measure(14);
    final painter = TerminalPainter(
      grid: grid,
      metrics: metrics,
      glyphs: GlyphCache(metrics),
      cursorVisible: false,
      focused: false,
      generation: grid.generation,
    );
    final canvas = _Recorder();
    painter.paint(canvas, const Size(200, 40));
    List<Rect> rects(int rgb) => [
          for (final (rect, color) in canvas.rects)
            if (color.toARGB32() == 0xFF000000 | rgb) rect,
        ];
    final cw = metrics.width;

    expect(rects(green).single.width, cw, reason: 'a plain line across the cell');
    expect(canvas.paths.single.$1, Color(0xFF000000 | red), reason: 'a wave');
    expect(canvas.paths.single.$2, PaintingStyle.stroke);
    expect(rects(red), isEmpty);
    final dots = rects(blue);
    expect(dots.length, greaterThan(2));
    expect(dots.every((r) => r.width == 1), isTrue, reason: 'dots');
    final dashes = rects(grey);
    expect(dashes.length, greaterThan(1));
    // Dashes run on from the cell before, so the ones at its edges are cut.
    expect(dashes.any((r) => r.width == 3) && dashes.every((r) => r.width < cw), isTrue, reason: 'dashes');
    final double = rects(pink);
    expect(double.length, 2);
    expect(double[0].top, isNot(double[1].top), reason: 'two lines');
    expect(dots.first.top, rects(green).single.top, reason: 'all at the same height');
  });

  test('links are opened, paths and addresses copied', () {
    expect(linkKind('https://example.com'), LinkKind.web);
    expect(linkKind('mailto:me@example.com'), LinkKind.web);
    expect(linkKind('file:///etc/hosts'), LinkKind.web);
    expect(linkKind('/etc/hosts'), LinkKind.path);
    expect(linkKind('~/src'), LinkKind.path);
    expect(linkKind('10.0.0.1'), LinkKind.address);
    expect(linkKind('192.168.1.20:2222'), LinkKind.address);
    expect(copyLabel(LinkKind.path), 'Copy path');
    expect(copyLabel(LinkKind.address), 'Copy address');
  });
}
