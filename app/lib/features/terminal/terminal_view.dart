import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/engine/engine.dart' show TerminalSelectKind;
import '../../core/platform.dart';
import '../workspace/app_shortcuts.dart';
import 'key_mapper.dart';
import 'terminal_controller.dart';
import 'terminal_grid.dart';
import 'terminal_painter.dart';

/// The terminal itself: paints the controller's grid, sizes the session to
/// fit, and turns keys, mouse, scrolls and pastes into engine calls.
class TerminalView extends StatefulWidget {
  const TerminalView({
    super.key,
    required this.controller,
    this.autofocus = true,
    this.onFind,
    this.onOpenLink,
    this.imeInput,
  });

  /// The view that last took focus, so the keyboard bar can show or hide
  /// its keyboard.
  static _TerminalViewState? _active;

  /// Ask the platform keyboard to appear for the focused terminal.
  static void showKeyboard() => _active?._openIme();

  /// Put the platform keyboard away; a tap on the terminal brings it back.
  static void hideKeyboard() => SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

  final TerminalController controller;
  final bool autofocus;

  /// Ctrl+Shift+F (or Cmd+F): the screen around the terminal shows its
  /// search bar.
  final VoidCallback? onFind;

  /// Ctrl+click (or Cmd+click) on a link, and "Open link" in the menu.
  final void Function(String uri)? onOpenLink;

  /// Take typed text from the platform's soft keyboard (the IME) as well
  /// as from hardware key events. On by default on phones and tablets.
  final bool? imeInput;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

/// A viewport cell under the pointer. `line` may be outside the grid while
/// the pointer is dragged past an edge; the engine clamps it.
typedef _Cell = ({int col, int line, bool right});

class _TerminalViewState extends State<TerminalView> with TextInputClient, DeltaTextInputClient {
  TextInputConnection? _ime;

  /// The IME's little buffer starts with one space, so that a backspace on
  /// an otherwise empty buffer still reaches us as a change. The platform
  /// reports edits as deltas (what was inserted or deleted), so a key that
  /// lands while the buffer is being reset is still read right.
  static const _imeBase = TextEditingValue(text: ' ', selection: TextSelection.collapsed(offset: 1));
  TextEditingValue _imeValue = _imeBase;

  /// Trim the buffer once it holds this much, between compositions.
  static const _imeBufferLimit = 64;

  bool get _useIme => widget.imeInput ?? isTouchPlatform;

  late final FocusNode _focus = FocusNode(debugLabel: 'terminal');
  late CellMetrics _metrics = CellMetrics.measure(widget.controller.fontSize);
  late GlyphCache _glyphs = GlyphCache(_metrics);
  Timer? _blink;
  bool _cursorOn = true;
  double _scrollRemainder = 0;

  // Mouse selection.
  bool _dragging = false;
  int _clicks = 0;
  DateTime? _lastDown;
  Offset? _lastDownAt;
  _Cell? _lastCell;

  /// Whether the pointer rests on a link, for the cursor.
  bool _overLink = false;

  static const _multiClickGap = Duration(milliseconds: 400);

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
    // A pane that just became the focused one takes the keyboard.
    if (widget.autofocus && !old.autofocus) _focus.requestFocus();
  }

  @override
  void dispose() {
    _closeIme();
    if (TerminalView._active == this) TerminalView._active = null;
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
    if (_focus.hasFocus) {
      TerminalView._active = this;
      if (_useIme) _openIme();
    } else {
      _closeIme();
    }
    setState(() {});
  }

  // ---- The soft keyboard --------------------------------------------------

  void _openIme() {
    if (!_useIme) return;
    _ime ??= TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        enableDeltaModel: true,
        keyboardAppearance: widget.controller.grid.defaultBg < 0x808080 ? Brightness.dark : Brightness.light,
      ),
    )..setEditingState(_imeValue);
    _ime!.show();
  }

  void _closeIme() {
    _ime?.close();
    _ime = null;
    _imeValue = _imeBase;
  }

  /// Send typed text to the program, through the sticky modifiers.
  void _writeText(String text) {
    final c = widget.controller;
    if (c.grid.displayOffset != 0) c.scrollToBottom();
    c.selectClear();
    c.write(c.encodeTyped(text));
  }

  @override
  TextEditingValue? get currentTextEditingValue => _imeValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    for (final d in deltas) {
      switch (d) {
        case TextEditingDeltaInsertion(:final textInserted):
          _writeText(textInserted.replaceAll('\n', '\r'));
        case TextEditingDeltaDeletion(:final deletedRange):
          _erase(deletedRange.end - deletedRange.start);
        case TextEditingDeltaReplacement(:final replacedRange, :final replacementText):
          _erase(replacedRange.end - replacedRange.start);
          _writeText(replacementText.replaceAll('\n', '\r'));
        case TextEditingDeltaNonTextUpdate():
          break;
      }
      // Follow the platform's view of the buffer. A delta that refers to an
      // older buffer than ours (one we had just reset) is applied to its
      // own old text instead, which is what the platform holds now.
      final base = d.oldText == _imeValue.text ? _imeValue : TextEditingValue(text: d.oldText);
      _imeValue = d.apply(base);
    }
    _trimImeBuffer();
  }

  /// Without the delta model (a platform or test that sends whole values),
  /// what changed since last time is what was typed or erased.
  @override
  void updateEditingValue(TextEditingValue value) {
    final before = _imeValue.text;
    final after = value.text;
    var common = 0;
    while (common < before.length && common < after.length && before[common] == after[common]) {
      common++;
    }
    _erase(before.length - common);
    final typed = after.substring(common);
    if (typed.isNotEmpty) _writeText(typed.replaceAll('\n', '\r'));
    _imeValue = value;
    _trimImeBuffer();
  }

  void _erase(int count) {
    if (count > 0) widget.controller.write(List.filled(count, 0x7f));
  }

  /// Start the buffer afresh when it has grown, and nothing is being
  /// composed, so it never gets big and a backspace keeps meaning "erase
  /// what I typed".
  void _trimImeBuffer() {
    final composing = _imeValue.composing.isValid && !_imeValue.composing.isCollapsed;
    if (composing || _imeValue.text.length < _imeBufferLimit) return;
    _imeValue = _imeBase;
    _ime?.setEditingState(_imeBase);
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.newline:
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
        _writeText('\r');
      default:
        break;
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _ime = null;
    _imeValue = _imeBase;
  }

  void _restartBlink() {
    _blink?.cancel();
    if (!_focus.hasFocus) return;
    _blink = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted) return;
      setState(() => _cursorOn = !_cursorOn);
    });
  }

  // ---- Keyboard --------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final c = widget.controller;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed;
    final alt = hw.isAltPressed;
    final shift = hw.isShiftPressed;
    final meta = hw.isMetaPressed;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // The window's own shortcuts (tabs, panes, the palette) pass through.
    if (AppShortcuts.isReserved(event)) return KeyEventResult.ignored;
    // With the soft keyboard attached, printable characters come through
    // it (a hardware keyboard on a phone feeds the IME too); only keys it
    // does not carry are taken from here.
    if (_ime != null && !ctrl && !alt && !meta && _isPrintable(event)) return KeyEventResult.ignored;

    // App shortcuts first.
    final key = event.logicalKey;
    final copyPaste = ctrl && shift || meta;
    if (copyPaste && key == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }
    if (copyPaste && key == LogicalKeyboardKey.keyC) {
      _copySelection();
      return KeyEventResult.handled;
    }
    if (copyPaste && key == LogicalKeyboardKey.keyF && widget.onFind != null) {
      widget.onFind!();
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
    // Typing drops the selection, the way every other terminal does it.
    c.selectClear();
    c.write(bytes);
    return KeyEventResult.handled;
  }

  static bool _isPrintable(KeyEvent event) {
    final ch = event.character;
    if (ch == null || ch.isEmpty) return false;
    final code = ch.codeUnitAt(0);
    return code >= 0x20 && code != 0x7f;
  }

  // ---- Clipboard -------------------------------------------------------

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) widget.controller.paste(text);
  }

  Future<void> _copySelection() async {
    final text = widget.controller.selectionText();
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  // ---- Mouse -----------------------------------------------------------

  _Cell _cellAt(Offset local) {
    final cw = _metrics.width;
    final ch = _metrics.height;
    final col = (local.dx / cw).floor().clamp(0, 0xFFFF);
    final right = local.dx - col * cw > cw / 2;
    final line = (local.dy / ch).floor();
    return (col: col, line: line, right: right);
  }

  /// True when the cell holds part of a link.
  bool _isLinkCell(_Cell cell) {
    final grid = widget.controller.grid;
    if (cell.line < 0 || cell.line >= grid.lines.length) return false;
    final row = grid.lines[cell.line];
    return cell.col < row.flags.length && (row.flags[cell.col] & CellFlags.link) != 0;
  }

  void _onHover(PointerHoverEvent e) {
    final over = _isLinkCell(_cellAt(e.localPosition));
    if (over != _overLink) setState(() => _overLink = over);
  }

  void _onPointerDown(PointerDownEvent e) {
    _focus.requestFocus();
    // Touch selection (long press, handles) comes with the mobile build.
    if (e.kind == PointerDeviceKind.touch) {
      if (_useIme) _openIme();
      return;
    }
    if (e.buttons & kSecondaryButton != 0) {
      _showContextMenu(e.position, _cellAt(e.localPosition));
      return;
    }
    final hw = HardwareKeyboard.instance;
    if (e.buttons & kPrimaryButton != 0 && (hw.isControlPressed || hw.isMetaPressed)) {
      final cell = _cellAt(e.localPosition);
      final link = widget.controller.linkAt(cell.col, cell.line);
      if (link != null) {
        widget.onOpenLink?.call(link);
        return;
      }
    }
    if (e.buttons & kMiddleMouseButton != 0) {
      _pasteFromClipboard();
      return;
    }
    if (e.buttons & kPrimaryButton == 0) return;

    final now = DateTime.now();
    final quick = _lastDown != null && now.difference(_lastDown!) < _multiClickGap;
    final near = _lastDownAt != null && (e.localPosition - _lastDownAt!).distance < _metrics.width;
    _clicks = quick && near ? _clicks + 1 : 1;
    _lastDown = now;
    _lastDownAt = e.localPosition;

    final cell = _cellAt(e.localPosition);
    final kind = switch (_clicks) {
      1 => TerminalSelectKind.simple,
      2 => TerminalSelectKind.word,
      _ => TerminalSelectKind.line,
    };
    widget.controller.selectBegin(cell.col, cell.line, cell.right, kind);
    _lastCell = cell;
    _dragging = true;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_dragging || e.buttons & kPrimaryButton == 0) return;
    final cell = _cellAt(e.localPosition);
    if (cell == _lastCell) return;
    _lastCell = cell;
    final c = widget.controller;
    // Dragging past the top or bottom edge brings more lines into view.
    if (cell.line < 0) {
      c.scroll(1);
    } else if (c.grid.rows > 0 && cell.line >= c.grid.rows) {
      c.scroll(-1);
    }
    c.selectUpdate(cell.col, cell.line, cell.right);
  }

  void _onPointerUp(PointerEvent e) {
    _dragging = false;
  }

  Future<void> _showContextMenu(Offset global, _Cell cell) async {
    final hasSelection = widget.controller.selectionText()?.isNotEmpty == true;
    final link = _isLinkCell(cell) ? widget.controller.linkAt(cell.col, cell.line) : null;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, global.dy),
      items: [
        if (link != null) ...[
          const PopupMenuItem(value: 'open-link', child: Text('Open link')),
          const PopupMenuItem(value: 'copy-link', child: Text('Copy link')),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(value: 'copy', enabled: hasSelection, child: const Text('Copy')),
        const PopupMenuItem(value: 'paste', child: Text('Paste')),
      ],
    );
    switch (choice) {
      case 'open-link':
        widget.onOpenLink?.call(link!);
      case 'copy-link':
        await Clipboard.setData(ClipboardData(text: link!));
      case 'copy':
        await _copySelection();
      case 'paste':
        await _pasteFromClipboard();
    }
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

  /// The screen as text, for screen readers; empty when none is running,
  /// so a frame costs nothing extra the rest of the time.
  String _spokenScreen() {
    if (!SemanticsBinding.instance.semanticsEnabled) return '';
    final lines = <String>[];
    for (final row in widget.controller.grid.lines) {
      lines.add(row.glyphs.map((g) => g.isEmpty ? ' ' : g).join().trimRight());
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _metrics.colsFor(constraints.maxWidth);
        final rows = _metrics.rowsFor(constraints.maxHeight);
        c.resize(cols, rows);
        return Semantics(
          container: true,
          label: 'Terminal',
          value: _spokenScreen(),
          multiline: true,
          child: Focus(
            focusNode: _focus,
            autofocus: widget.autofocus,
            onKeyEvent: _onKey,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: _onPointerSignal,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
              child: MouseRegion(
                cursor: _overLink ? SystemMouseCursors.click : SystemMouseCursors.text,
                onHover: _onHover,
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
