import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/tokens.dart';
import 'terminal_grid.dart';

/// Size of one cell for a font and size, measured once per change.
class CellMetrics {
  CellMetrics._(this.width, this.height, this.fontSize);

  final double width;
  final double height;
  final double fontSize;

  factory CellMetrics.measure(double fontSize) {
    final tp = TextPainter(
      text: TextSpan(text: 'M', style: TextStyle(fontFamily: PromptlyTokens.monoFamily, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    return CellMetrics._(tp.width, tp.height, fontSize);
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

  ui.Paragraph paragraph(String text, int fg, int flags) {
    final style = flags & (CellFlags.bold | CellFlags.italic);
    final key = '$text\u0000$fg\u0000$style';
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length > _maxEntries) _cache.clear();

    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: PromptlyTokens.monoFamily,
      fontSize: metrics.fontSize,
      maxLines: 1,
      textDirection: TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: Color(0xFF000000 | fg),
        fontFamily: PromptlyTokens.monoFamily,
        fontFamilyFallback: const ['Noto Color Emoji', 'DejaVu Sans Mono', 'Noto Sans Mono', 'monospace'],
        fontSize: metrics.fontSize,
        fontWeight: (flags & CellFlags.bold) != 0 ? FontWeight.w700 : FontWeight.w400,
        fontStyle: (flags & CellFlags.italic) != 0 ? FontStyle.italic : FontStyle.normal,
      ))
      ..addText(text);
    final p = builder.build()..layout(ui.ParagraphConstraints(width: metrics.width * 2 + 2));
    _cache[key] = p;
    return p;
  }
}

/// Paints the grid. Backgrounds first as merged runs, then glyphs from the
/// cache, then decorations and the cursor.
class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.metrics,
    required this.glyphs,
    required this.cursorVisible,
    required this.focused,
    required this.generation,
    this.inset = 0,
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

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = Color(0xFF000000 | grid.defaultBg);
    canvas.drawRect(Offset.zero & size, bgPaint);
    canvas.translate(inset, 0);

    final cw = metrics.width;
    final ch = metrics.height;
    final paint = Paint();

    for (var y = 0; y < grid.lines.length; y++) {
      final row = grid.lines[y];
      final top = y * ch;
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

      // Glyphs and decorations.
      for (var x = 0; x < n; x++) {
        final g = row.glyphs[x];
        final f = row.flags[x];
        if ((f & CellFlags.wideSpacer) != 0) continue;
        final left = x * cw;
        if (g.isNotEmpty) {
          final p = glyphs.paragraph(g, row.fg[x], f);
          canvas.drawParagraph(p, Offset(left, top + (ch - p.height) / 2));
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

    _paintCursor(canvas, cw, ch, paint);
  }

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

  @override
  bool shouldRepaint(TerminalPainter old) =>
      old.generation != generation ||
      old.cursorVisible != cursorVisible ||
      old.focused != focused ||
      old.metrics != metrics ||
      old.grid != grid ||
      old.inset != inset;
}
