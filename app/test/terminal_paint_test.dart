import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/features/terminal/link_kind.dart';
import 'package:promptly/features/terminal/terminal_fonts.dart';
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

/// A frame of these lines of text, every cell in the default colours
/// except the backgrounds given per line.
TerminalFrame textFrame(List<String> lines, {bool full = true, List<int>? only, Map<int, int> bg = const {}}) {
  final n = lines.map((l) => l.length).fold(0, (a, b) => a > b ? a : b);
  return TerminalFrame(
    cols: n,
    rows: lines.length,
    full: full,
    rowsChanged: [
      for (final (i, line) in lines.indexed)
        if (only == null || only.contains(i))
          TerminalRow(
            line: i,
            glyphs: [for (var x = 0; x < n; x++) x < line.length && line[x] != ' ' ? line[x] : ''],
            fg: Uint32List(n)..fillRange(0, n, 0xE6EDF3),
            bg: Uint32List(n)..fillRange(0, n, bg[i] ?? 0x0E1116),
            flags: Uint16List(n),
            underline: Uint32List(n)..fillRange(0, n, 0xE6EDF3),
          ),
    ],
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
}

/// Keeps the rectangles, paths and text painted, with their colours.
class _Recorder implements Canvas {
  final List<(Rect, Color)> rects = [];
  final List<(Color, PaintingStyle)> paths = [];
  final List<double> paragraphWidths = [];

  @override
  void drawRect(Rect rect, Paint paint) => rects.add((rect, paint.color));

  @override
  void drawPath(Path path, Paint paint) => paths.add((paint.color, paint.style));

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) => paragraphWidths.add(paragraph.maxIntrinsicWidth);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// What the painter draws, as pixels.
Future<Uint8List> pixels(WidgetTester tester, TerminalPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final image = recorder.endRecording().toImageSync(size.width.ceil(), size.height.ceil());
  final data = await tester.runAsync(() => image.toByteData());
  image.dispose();
  return data!.buffer.asUint8List();
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

  testWidgets('only rows that changed are drawn again, and moved rows are reused', (tester) async {
    final grid = TerminalGrid()..apply(textFrame(['one', 'two', 'six']));
    final metrics = CellMetrics.measure(14);
    final rows = RowPictures();
    addTearDown(rows.dispose);
    var glyphs = GlyphCache(metrics);
    void paint() => TerminalPainter(
      grid: grid,
      metrics: glyphs.metrics,
      glyphs: glyphs,
      cursorVisible: true,
      focused: true,
      generation: grid.generation,
      rows: rows,
    ).paint(Canvas(ui.PictureRecorder()), const Size(100, 60));

    paint();
    expect(rows.drawn, 3);
    paint();
    expect(rows.drawn, 3, reason: 'a repaint with nothing new, such as the cursor blinking');

    grid.apply(textFrame(['one', 'ten', 'six'], full: false, only: [1]));
    paint();
    expect(rows.drawn, 4, reason: 'the one changed row');

    // Scrolling sends every row, but only the new bottom one is new.
    grid.apply(textFrame(['ten', 'six', 'new']));
    paint();
    expect(rows.drawn, 5);

    // Two blank rows share one drawing.
    grid.apply(textFrame(['ten', '', '']));
    paint();
    expect(rows.drawn, 6);

    // A new font or size draws every row again (the blank one once).
    glyphs = GlyphCache(CellMetrics.measure(16));
    paint();
    expect(rows.drawn, 8);
  });

  testWidgets('drawing rows from saved pictures looks the same as drawing them afresh', (tester) async {
    final grid = TerminalGrid()..apply(textFrame(['ls -la', 'total 8', '\$ vim'], bg: {1: 0x334455}));
    final metrics = CellMetrics.measure(14);
    final glyphs = GlyphCache(metrics);
    final rows = RowPictures();
    addTearDown(rows.dispose);
    TerminalPainter painter({RowPictures? rows}) => TerminalPainter(
      grid: grid,
      metrics: metrics,
      glyphs: glyphs,
      cursorVisible: true,
      focused: true,
      generation: grid.generation,
      inset: 8,
      rows: rows,
    );
    const size = Size(120, 60);

    final fresh = await pixels(tester, painter(), size);
    expect(await pixels(tester, painter(rows: rows), size), fresh);
    // Again from the saved pictures, after one row changed.
    grid.apply(textFrame(['ls -la', 'tot   8', '\$ vim'], full: false, only: [1], bg: {1: 0x334455}));
    final changed = await pixels(tester, painter(), size);
    expect(changed, isNot(fresh));
    expect(await pixels(tester, painter(rows: rows), size), changed);
    expect(rows.drawn, 4);
  });

  testWidgets('with ligatures on, plain text in one style is laid out as a run', (tester) async {
    final grid = TerminalGrid()..apply(textFrame(['a->b != c']));
    TerminalPainter painter(bool ligatures) {
      final metrics = CellMetrics.measure(14, TerminalFont(ligatures: ligatures));
      return TerminalPainter(
        grid: grid,
        metrics: metrics,
        glyphs: GlyphCache(metrics),
        cursorVisible: false,
        focused: false,
        generation: grid.generation,
      );
    }

    final off = _Recorder();
    painter(false).paint(off, const Size(200, 20));
    expect(off.paragraphWidths, hasLength(7), reason: 'one per character');

    final on = _Recorder();
    final p = painter(true);
    p.paint(on, const Size(200, 20));
    expect(on.paragraphWidths, hasLength(3), reason: '"a->b", "!=" and "c"');
    expect(on.paragraphWidths.first, closeTo(4 * p.metrics.width, 0.01), reason: 'still four cells wide');
  });

  test('web links are opened, and paths, addresses and other links copied', () {
    expect(linkKind('https://example.com'), LinkKind.web);
    expect(linkKind('mailto:me@example.com'), LinkKind.web);
    expect(linkKind('file:///etc/hosts'), LinkKind.other);
    expect(linkKind('ssh://server'), LinkKind.other);
    expect(linkKind('ms-msdt:/id'), LinkKind.other);
    expect(linkKind('HTTPS://example.com'), LinkKind.web);
    expect(linkKind('/etc/hosts'), LinkKind.path);
    expect(linkKind('~/src'), LinkKind.path);
    expect(linkKind('10.0.0.1'), LinkKind.address);
    expect(linkKind('192.168.1.20:2222'), LinkKind.address);
    expect(copyLabel(LinkKind.path), 'Copy path');
    expect(copyLabel(LinkKind.address), 'Copy address');
    expect(copyLabel(LinkKind.other), 'Copy link');
  });
}
