import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/engine/engine.dart';
import 'terminal_fonts.dart';
import 'terminal_grid.dart';

/// Size of one cell for a font and size, measured once per change.
class CellMetrics {
  CellMetrics._(this.width, this.height, this.fontSize, this.font);

  final double width;
  final double height;
  final double fontSize;
  final TerminalFont font;

  factory CellMetrics.measure(double fontSize, [TerminalFont font = TerminalFont.standard]) {
    final tp = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(fontFamily: font.family, fontFamilyFallback: font.fallback, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return CellMetrics._(tp.width, tp.height, fontSize, font);
  }

  int colsFor(double width) => (width / this.width).floor().clamp(2, 1000);
  int rowsFor(double height) => (height / this.height).floor().clamp(1, 1000);
}

/// Rasterised glyphs, shared by every terminal on screen.
class GlyphCache {
  GlyphCache(this.metrics);

  final CellMetrics metrics;
  final Map<String, ui.Paragraph> _cache = {};

  static const _maxEntries = 6000;

  TerminalFont get font => metrics.font;

  /// One cell's text.
  ui.Paragraph paragraph(String text, int fg, int flags) => _cached(text, fg, flags, run: false);

  /// Several cells' text laid out together, so the font can join pairs
  /// such as `->` into ligatures. Each character still takes one cell.
  ui.Paragraph run(String text, int fg, int flags) => _cached(text, fg, flags, run: true);

  ui.Paragraph _cached(String text, int fg, int flags, {required bool run}) {
    final style = flags & (CellFlags.bold | CellFlags.italic);
    final key = '$text\u0000$fg\u0000$style${run ? '\u0000run' : ''}';
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length > _maxEntries) _cache.clear();

    final p = _build(text, fg, flags, ligatures: run)
      ..layout(ui.ParagraphConstraints(width: metrics.width * (run ? text.length + 1 : 2) + 2));
    _cache[key] = p;
    return p;
  }

  /// Text the input method is composing, laid out on one line however long
  /// it is. Not kept: it changes with every key.
  ui.Paragraph composing(String text, int fg) =>
      _build(text, fg, 0, ligatures: false)..layout(const ui.ParagraphConstraints(width: double.infinity));

  ui.Paragraph _build(String text, int fg, int flags, {required bool ligatures}) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: font.family,
      fontSize: metrics.fontSize,
      maxLines: 1,
      textDirection: TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: Color(0xFF000000 | fg),
        fontFamily: font.family,
        fontFamilyFallback: font.fallback,
        fontSize: metrics.fontSize,
        fontWeight: (flags & CellFlags.bold) != 0 ? FontWeight.w700 : FontWeight.w400,
        fontStyle: (flags & CellFlags.italic) != 0 ? FontStyle.italic : FontStyle.normal,
        fontFeatures: ligatures ? const [ui.FontFeature.enable('liga'), ui.FontFeature.enable('calt')] : null,
      ))
      ..addText(text);
    return builder.build();
  }
}

/// Each row drawn once into a picture and kept while it stays the same, so
/// a frame draws again only the rows that changed. A row that moved, as
/// when the screen scrolls, is found by what it holds and drawn where it
/// lands without being laid out again.
class RowPictures {
  List<_DrawnRow?> _lines = const [];
  Map<int, List<_DrawnRow>> _pool = {};
  Object? _style;
  int _frame = 0;

  /// How many rows have been drawn into pictures, for tests.
  @visibleForTesting
  int drawn = 0;

  /// The picture for each line. `style` is what every picture depends on
  /// besides its row (the font, the size, the default background); when it
  /// changes, every row is drawn again.
  List<ui.Picture> update(List<GridRow> lines, Object style, ui.Picture Function(GridRow row) draw) {
    if (style != _style) {
      dispose();
      _style = style;
    }
    _frame++;
    final pool = <int, List<_DrawnRow>>{};
    final next = List<_DrawnRow?>.filled(lines.length, null);
    for (var y = 0; y < lines.length; y++) {
      final row = lines[y];
      final before = y < _lines.length ? _lines[y] : null;
      _DrawnRow? found;
      if (before != null && identical(before.row, row)) {
        found = before;
      } else {
        final hash = _hash(row);
        found = pool[hash]?.where((d) => _same(d.row, row)).firstOrNull ??
            _pool[hash]?.where((d) => _same(d.row, row)).firstOrNull;
        if (found == null) {
          drawn++;
          found = _DrawnRow(row, hash, draw(row));
        }
      }
      if (found.frame != _frame) {
        found.frame = _frame;
        pool.putIfAbsent(found.hash, () => []).add(found);
      }
      next[y] = found;
    }
    // Rows no longer on screen let their pictures go.
    for (final bucket in _pool.values) {
      for (final d in bucket) {
        if (d.frame != _frame) d.picture.dispose();
      }
    }
    _pool = pool;
    _lines = next;
    return [for (final d in next) d!.picture];
  }

  void dispose() {
    for (final bucket in _pool.values) {
      for (final d in bucket) {
        d.picture.dispose();
      }
    }
    _pool = {};
    _lines = const [];
  }

  static int _hash(GridRow r) => Object.hash(
    Object.hashAll(r.glyphs),
    Object.hashAll(r.fg),
    Object.hashAll(r.bg),
    Object.hashAll(r.flags),
    Object.hashAll(r.underline),
  );

  static bool _same(GridRow a, GridRow b) =>
      identical(a, b) ||
      (listEquals(a.glyphs, b.glyphs) &&
          listEquals(a.fg, b.fg) &&
          listEquals(a.bg, b.bg) &&
          listEquals(a.flags, b.flags) &&
          listEquals(a.underline, b.underline));
}

class _DrawnRow {
  _DrawnRow(this.row, this.hash, this.picture);

  final GridRow row;
  final int hash;
  final ui.Picture picture;

  /// The last frame that used it.
  int frame = 0;
}

/// Paints the grid. Each row is backgrounds first as merged runs, then
/// glyphs from the cache with their decorations; with [rows], rows come
/// from pictures drawn earlier where they have not changed. The cursor goes
/// on top, and the input method's text over that.
class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.metrics,
    required this.glyphs,
    required this.cursorVisible,
    required this.focused,
    required this.generation,
    this.inset = 0,
    this.rows,
    this.composing = '',
  });

  final TerminalGrid grid;
  final CellMetrics metrics;
  final GlyphCache glyphs;
  final bool cursorVisible;
  final bool focused;
  final int generation;

  /// Space between the left edge and the first column, filled with the
  /// terminal's background.
  final double inset;

  /// Pictures of rows from earlier frames. Without it every row is drawn
  /// each time.
  final RowPictures? rows;

  /// Text an input method is composing, shown at the cursor until it is
  /// committed and typed.
  final String composing;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = Color(0xFF000000 | grid.defaultBg);
    canvas.drawRect(Offset.zero & size, bgPaint);
    canvas.translate(inset, 0);

    final cw = metrics.width;
    final ch = metrics.height;
    final paint = Paint();

    final pictures = rows?.update(grid.lines, (metrics, glyphs, grid.defaultBg), (row) {
      final recorder = ui.PictureRecorder();
      _paintRow(Canvas(recorder), row, Paint());
      return recorder.endRecording();
    });
    for (var y = 0; y < grid.lines.length; y++) {
      canvas.save();
      canvas.translate(0, y * ch);
      if (pictures != null) {
        canvas.drawPicture(pictures[y]);
      } else {
        _paintRow(canvas, grid.lines[y], paint);
      }
      canvas.restore();
    }

    if (composing.isNotEmpty) {
      _paintComposing(canvas, cw, ch, paint);
    } else {
      _paintCursor(canvas, cw, ch, paint);
    }
  }

  /// One row, its top at zero.
  void _paintRow(Canvas canvas, GridRow row, Paint paint) {
    final cw = metrics.width;
    final ch = metrics.height;
    const top = 0.0;
    final n = row.glyphs.length;

    // Background runs.
    var x = 0;
    while (x < n) {
      final bg = row.bg[x];
      var end = x + 1;
      while (end < n && row.bg[end] == bg) {
        end++;
      }
      if (bg != grid.defaultBg) {
        paint.color = Color(0xFF000000 | bg);
        canvas.drawRect(Rect.fromLTWH(x * cw, top, (end - x) * cw, ch), paint);
      }
      x = end;
    }

    // Glyphs and decorations. With ligatures on, a run of plain characters
    // in one colour and style is laid out as one, from its first cell.
    final ligatures = glyphs.font.ligatures;
    var textDone = 0;
    for (var x = 0; x < n; x++) {
      final g = row.glyphs[x];
      final f = row.flags[x];
      if ((f & CellFlags.wideSpacer) != 0) continue;
      final left = x * cw;
      if (g.isNotEmpty && x >= textDone) {
        var end = x + 1;
        if (ligatures && _joinable(g)) {
          final style = f & (CellFlags.bold | CellFlags.italic);
          while (end < n &&
              _joinable(row.glyphs[end]) &&
              row.fg[end] == row.fg[x] &&
              (row.flags[end] & (CellFlags.bold | CellFlags.italic)) == style) {
            end++;
          }
        }
        final p = end - x > 1
            ? glyphs.run(row.glyphs.sublist(x, end).join(), row.fg[x], f)
            : glyphs.paragraph(g, row.fg[x], f);
        canvas.drawParagraph(p, Offset(left, top + (ch - p.height) / 2));
        textDone = end;
      }
      if ((f & CellFlags.link) != 0 && (f & CellFlags.anyUnderline) == 0) {
        // Links get a faint underline of their own colour, so they read
        // as links without shouting.
        final width = (f & CellFlags.wide) != 0 ? cw * 2 : cw;
        paint.color = Color(0x99000000 | row.fg[x]);
        canvas.drawRect(Rect.fromLTWH(left, top + ch - 2, width, 1), paint);
      }
      if ((f & (CellFlags.anyUnderline | CellFlags.strikeout)) != 0) {
        final width = (f & CellFlags.wide) != 0 ? cw * 2 : cw;
        if ((f & CellFlags.anyUnderline) != 0) {
          paint.color = Color(0xFF000000 | row.underline[x]);
          _paintUnderline(canvas, f, left, top + ch, width, paint);
        }
        if ((f & CellFlags.strikeout) != 0) {
          paint.color = Color(0xFF000000 | row.fg[x]);
          canvas.drawRect(Rect.fromLTWH(left, top + ch / 2, width, _thickness), paint);
        }
      }
    }
  }

  /// A printable ASCII character: one cell wide in a monospaced font, so a
  /// run of them laid out together still lines up with the grid.
  static bool _joinable(String g) => g.length == 1 && g.codeUnitAt(0) > 0x20 && g.codeUnitAt(0) < 0x7f;

  /// Line thickness: one pixel at the usual sizes, more on large text.
  double get _thickness => (metrics.fontSize / 14).roundToDouble().clamp(1, 4);

  /// One cell's underline in the style its flags ask for, `bottom` being
  /// the bottom of the cell. Dots, dashes and waves are laid out from the
  /// left edge of the screen, not the cell, so a run of cells joins up.
  void _paintUnderline(Canvas canvas, int f, double left, double bottom, double width, Paint paint) {
    final t = _thickness;
    final y = bottom - 1 - t;
    final right = left + width;
    if ((f & CellFlags.undercurl) != 0) {
      // A wave, a whole one per cell so neighbours meet at the same height.
      final amp = 1.5 * t;
      final mid = y - amp / 2;
      final halves = (width / metrics.width * 2).round().clamp(2, 8);
      final half = width / halves;
      final path = Path()..moveTo(left, mid);
      for (var i = 0; i < halves; i++) {
        final x0 = left + i * half;
        path.quadraticBezierTo(x0 + half / 2, i.isEven ? mid - amp * 2 : mid + amp * 2, x0 + half, mid);
      }
      final stroke = Paint()
        ..color = paint.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = t;
      canvas.drawPath(path, stroke);
    } else if ((f & CellFlags.dottedUnderline) != 0) {
      final step = 2 * t;
      for (var x = (left / step).ceilToDouble() * step; x < right; x += step) {
        canvas.drawRect(Rect.fromLTWH(x, y, t, t), paint);
      }
    } else if ((f & CellFlags.dashedUnderline) != 0) {
      final dash = 3 * t;
      final step = 5 * t;
      for (var x = (left / step).floorToDouble() * step; x < right; x += step) {
        final from = x < left ? left : x;
        final to = x + dash > right ? right : x + dash;
        if (to > from) canvas.drawRect(Rect.fromLTRB(from, y, to, y + t), paint);
      }
    } else {
      canvas.drawRect(Rect.fromLTWH(left, y, width, t), paint);
      if ((f & CellFlags.doubleUnderline) != 0) {
        canvas.drawRect(Rect.fromLTWH(left, y - 2 * t, width, t), paint);
      }
    }
  }

  void _paintCursor(Canvas canvas, double cw, double ch, Paint paint) {
    final c = grid.cursor;
    if (c.shape == TerminalCursorShape.hidden) return;
    if (c.line < 0 || c.line >= grid.lines.length || c.col >= grid.cols) return;
    if (!cursorVisible && focused) return;

    final row = grid.lines[c.line];
    final wide = c.col < row.flags.length && (row.flags[c.col] & CellFlags.wide) != 0;
    final rect = Rect.fromLTWH(c.col * cw, c.line * ch, wide ? cw * 2 : cw, ch);
    paint.color = Color(0xFF000000 | grid.cursorColor);

    if (!focused) {
      canvas.drawRect(rect.deflate(0.5), paint..style = PaintingStyle.stroke..strokeWidth = 1);
      paint.style = PaintingStyle.fill;
      return;
    }
    switch (c.shape) {
      case TerminalCursorShape.block:
        canvas.drawRect(rect, paint);
        final g = c.col < row.glyphs.length ? row.glyphs[c.col] : '';
        if (g.isNotEmpty) {
          final p = glyphs.paragraph(g, grid.defaultBg, row.flags[c.col]);
          canvas.drawParagraph(p, Offset(rect.left, rect.top + (ch - p.height) / 2));
        }
      case TerminalCursorShape.hollowBlock:
        canvas.drawRect(rect.deflate(0.5), paint..style = PaintingStyle.stroke..strokeWidth = 1);
        paint.style = PaintingStyle.fill;
      case TerminalCursorShape.beam:
        canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, 2, ch), paint);
      case TerminalCursorShape.underline:
        canvas.drawRect(Rect.fromLTWH(rect.left, rect.bottom - 2, rect.width, 2), paint);
      case TerminalCursorShape.hidden:
        break;
    }
  }

  /// The input method's text at the cursor, underlined over the terminal's
  /// background, with a bar where the next character goes.
  void _paintComposing(Canvas canvas, double cw, double ch, Paint paint) {
    final c = grid.cursor;
    if (c.line < 0 || c.line >= grid.lines.length) return;
    final p = glyphs.composing(composing, grid.defaultFg);
    final left = c.col * cw;
    final top = c.line * ch;
    final width = math.max(p.maxIntrinsicWidth, cw);
    paint.color = Color(0xFF000000 | grid.defaultBg);
    canvas.drawRect(Rect.fromLTWH(left, top, width, ch), paint);
    canvas.drawParagraph(p, Offset(left, top + (ch - p.height) / 2));
    paint.color = Color(0xFF000000 | grid.defaultFg);
    canvas.drawRect(Rect.fromLTWH(left, top + ch - 1 - _thickness, width, _thickness), paint);
    paint.color = Color(0xFF000000 | grid.cursorColor);
    canvas.drawRect(Rect.fromLTWH(left + p.maxIntrinsicWidth, top, 2, ch), paint);
  }

  @override
  bool shouldRepaint(TerminalPainter old) =>
      old.generation != generation ||
      old.cursorVisible != cursorVisible ||
      old.focused != focused ||
      old.metrics != metrics ||
      old.glyphs != glyphs ||
      old.grid != grid ||
      old.inset != inset ||
      old.rows != rows ||
      old.composing != composing;
}
