import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../terminal/terminal_controller.dart';
import '../terminal/terminal_fonts.dart';
import '../terminal/terminal_painter.dart';

/// A small live render of a session's screen, for the Sessions list. It is
/// the same painter as the terminal at a tiny font size, kept in step with
/// the session but repainted at most a few times a second.
class SessionThumbnail extends ConsumerStatefulWidget {
  const SessionThumbnail({super.key, required this.controller, this.height = 96});

  final TerminalController controller;
  final double height;

  @override
  ConsumerState<SessionThumbnail> createState() => _SessionThumbnailState();
}

class _SessionThumbnailState extends ConsumerState<SessionThumbnail> {
  /// Metrics and glyphs per font and size, shared by every thumbnail on
  /// screen.
  static final Map<(double, TerminalFont), (CellMetrics, GlyphCache)> _shared = {};

  static (CellMetrics, GlyphCache) _for(double fontSize, TerminalFont font) {
    if (_shared.keys.any((k) => k.$2 != font)) _shared.clear();
    return _shared.putIfAbsent((fontSize, font), () {
      final m = CellMetrics.measure(fontSize, font);
      return (m, GlyphCache(m));
    });
  }

  /// This thumbnail's rows, drawn again only when they change.
  final RowPictures _rows = RowPictures();

  static const _minGap = Duration(milliseconds: 250);

  Timer? _throttle;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onFrame);
  }

  @override
  void didUpdateWidget(SessionThumbnail old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onFrame);
      widget.controller.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    _throttle?.cancel();
    _rows.dispose();
    widget.controller.removeListener(_onFrame);
    super.dispose();
  }

  void _onFrame() {
    if (!mounted) return;
    if (_throttle != null) {
      _dirty = true;
      return;
    }
    setState(() {});
    _throttle = Timer(_minGap, () {
      _throttle = null;
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.controller.grid;
    final bg = Color(0xFF000000 | grid.defaultBg);
    final font = ref.watch(terminalFontProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (grid.cols == 0 || grid.rows == 0 || !width.isFinite) {
          return Container(height: widget.height, color: bg);
        }
        // Pick the font size at which the whole width fits, in half-point
        // steps so the shared caches stay small.
        final (base, _) = _for(6, font);
        final perPoint = base.width / 6;
        final fit = width / (grid.cols * perPoint);
        final fontSize = ((fit * 2).floor() / 2).clamp(3.0, 9.0);
        final (metrics, glyphs) = _for(fontSize, font);
        // Keep the cursor's row in view: that is where things are happening.
        final full = grid.rows * metrics.height;
        final cursorBottom = (grid.cursor.line + 1) * metrics.height;
        final shift = (cursorBottom - widget.height).clamp(0.0, (full - widget.height).clamp(0.0, double.infinity));
        return Container(
          height: widget.height,
          color: bg,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Transform.translate(
                offset: Offset(0, -shift),
                child: CustomPaint(
                  size: Size(width, full),
                  painter: TerminalPainter(
                    grid: grid,
                    metrics: metrics,
                    glyphs: glyphs,
                    cursorVisible: true,
                    focused: true,
                    generation: grid.generation,
                    rows: _rows,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
