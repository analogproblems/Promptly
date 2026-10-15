import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'key_mapper.dart';
import 'terminal_controller.dart';
import 'terminal_painter.dart';

/// The terminal itself: paints the controller's grid, sizes the session to
/// fit, and turns keys, scrolls and pastes into engine calls.
class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.controller, this.autofocus = true});

  final TerminalController controller;
  final bool autofocus;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  late final FocusNode _focus = FocusNode(debugLabel: 'terminal');
  late CellMetrics _metrics = CellMetrics.measure(widget.controller.fontSize);
  late GlyphCache _glyphs = GlyphCache(_metrics);
  Timer? _blink;
  bool _cursorOn = true;
  double _scrollRemainder = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _focus.addListener(_onFocus);
    widget.controller.start();
  }

  @override
  void didUpdateWidget(TerminalView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      widget.controller.start();
    }
  }

  @override
  void dispose() {
    _blink?.cancel();
    widget.controller.removeListener(_onController);
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    if (widget.controller.fontSize != _metrics.fontSize) {
      _metrics = CellMetrics.measure(widget.controller.fontSize);
      _glyphs = GlyphCache(_metrics);
    }
    // Any output resets the blink so the cursor is solid while typing.
    _cursorOn = true;
    _restartBlink();
    setState(() {});
  }

  void _onFocus() {
    _restartBlink();
    setState(() {});
  }

  void _restartBlink() {
    _blink?.cancel();
    if (!_focus.hasFocus) return;
    _blink = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted) return;
      setState(() => _cursorOn = !_cursorOn);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final c = widget.controller;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed;
    final alt = hw.isAltPressed;
    final shift = hw.isShiftPressed;
    final meta = hw.isMetaPressed;
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    // App shortcuts first.
    final key = event.logicalKey;
    final copyPaste = ctrl && shift || meta;
    if (copyPaste && key == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }
    if (copyPaste && key == LogicalKeyboardKey.keyC) {
      // Selection lands next; until then Ctrl+Shift+C does nothing harmful.
      return KeyEventResult.handled;
    }
    if (shift && key == LogicalKeyboardKey.pageUp) {
      c.scroll(c.grid.rows - 1);
      return KeyEventResult.handled;
    }
    if (shift && key == LogicalKeyboardKey.pageDown) {
      c.scroll(-(c.grid.rows - 1));
      return KeyEventResult.handled;
    }
    if (ctrl && (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add)) {
      c.setFontSize(c.fontSize + 1);
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.minus) {
      c.setFontSize(c.fontSize - 1);
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.digit0) {
      c.setFontSize(14);
      return KeyEventResult.handled;
    }

    final bytes = KeyMapper.bytesFor(event, appCursor: c.grid.appCursor, ctrl: ctrl, alt: alt, shift: shift);
    if (bytes == null) return KeyEventResult.ignored;
    if (c.grid.displayOffset != 0) c.scrollToBottom();
    c.write(bytes);
    return KeyEventResult.handled;
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) widget.controller.paste(text);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _scrollRemainder += event.scrollDelta.dy / _metrics.height;
    final lines = _scrollRemainder.truncate();
    if (lines != 0) {
      _scrollRemainder -= lines;
      // Wheel down (positive dy) moves the view toward the newest output.
      widget.controller.scroll(-lines);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _metrics.colsFor(constraints.maxWidth);
        final rows = _metrics.rowsFor(constraints.maxHeight);
        c.resize(cols, rows);
        return Focus(
          focusNode: _focus,
          autofocus: widget.autofocus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _focus.requestFocus(),
              child: MouseRegion(
                cursor: SystemMouseCursors.text,
                child: ClipRect(
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: TerminalPainter(
                      grid: c.grid,
                      metrics: _metrics,
                      glyphs: _glyphs,
                      cursorVisible: _cursorOn,
                      focused: _focus.hasFocus,
                      generation: c.grid.generation,
                    ),
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
