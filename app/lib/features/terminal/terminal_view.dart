import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/engine/engine.dart' show TerminalMouseAction, TerminalMouseButton, TerminalSelectKind;
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
    this.confirmPaste,
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

  /// Look at clipboard text before it is pasted. Returns the text to paste,
  /// or null to paste nothing. Without one, text is pasted as it is.
  final Future<String?> Function(String text)? confirmPaste;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

/// A viewport cell under the pointer. `line` may be outside the grid while
/// the pointer is dragged past an edge; the engine clamps it.
typedef _Cell = ({int col, int line, bool right});

/// A few pixels between the pane's left edge and the first column, so text
/// does not sit flush against it.
const double _inset = 8;

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

  /// A keyboard paste waiting on its check. Keyboard input that arrives
  /// meanwhile waits behind it, so nothing overtakes the paste.
  Future<void>? _imePending;

  /// An edit from the soft keyboard: erase [erase] characters, then type
  /// [text]. Enter on its own is Enter; anything else with a line break in
  /// it came from the keyboard's paste (or a dictated paragraph) and goes
  /// through the same check and clean-up as any paste, erasure included, so
  /// cancelling it changes nothing. Control characters a keyboard should
  /// never produce are dropped.
  void _imeText(String text, {int erase = 0}) {
    final pending = _imePending;
    final next = pending == null
        ? _imeEdit(text, erase)
        : pending.catchError((Object _) {}).then((_) => _imeEdit(text, erase));
    if (next == null) return;
    _imePending = next;
    next.whenComplete(() {
      if (identical(_imePending, next)) _imePending = null;
    });
  }

  Future<void>? _imeEdit(String text, int erase) {
    if (!mounted) return null;
    if (text.length > 1 && (text.contains('\n') || text.contains('\r'))) {
      return _pasteText(text, erase: erase, fromKeyboard: true);
    }
    _erase(erase);
    if (text == '\n' || text == '\r') {
      _writeText('\r');
    } else {
      final clean = text.replaceAll(_controlChars, '');
      if (clean.isNotEmpty) _writeText(clean);
    }
    return null;
  }

  static final _controlChars = RegExp('[\x00-\x08\x0b-\x1f\x7f-\x9f]');

  @override
  TextEditingValue? get currentTextEditingValue => _imeValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    for (final d in deltas) {
      switch (d) {
        case TextEditingDeltaInsertion(:final textInserted):
          _imeText(textInserted);
        case TextEditingDeltaDeletion(:final oldText, :final deletedRange):
          _imeText('', erase: _characters(oldText, deletedRange));
        case TextEditingDeltaReplacement(:final oldText, :final replacedRange, :final replacementText):
          _imeText(replacementText, erase: _characters(oldText, replacedRange));
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
    // Never split an emoji's two halves between kept and changed.
    if (common > 0 && (before.codeUnitAt(common - 1) & 0xFC00) == 0xD800) common--;
    _imeText(after.substring(common), erase: before.substring(common).runes.length);
    _imeValue = value;
    _trimImeBuffer();
  }

  /// How many characters a range of the buffer holds. Offsets count UTF-16
  /// units, so an emoji is two of them but one backspace in the shell.
  static int _characters(String text, TextRange range) {
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    return text.substring(start, end).runes.length;
  }

  void _erase(int count) {
    if (count > 0) widget.controller.write(List.filled(count, 0x7f));
  }

  /// Start the buffer afresh when it has grown, or when backspace has used
  /// up the leading space, and nothing is being composed. It never gets big,
  /// and the keyboard always has something left to delete, so backspace
  /// keeps reaching the shell (for a command recalled from history, say).
  void _trimImeBuffer() {
    final composing = _imeValue.composing.isValid && !_imeValue.composing.isCollapsed;
    if (composing) return;
    final text = _imeValue.text;
    if (text.length < _imeBufferLimit && text.startsWith(' ')) return;
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
    if (text == null || text.isEmpty || !mounted) return;
    await _pasteText(text);
  }

  /// Paste [text]: shown first when the hook says so, then sent as a paste
  /// (bracketed for programs that ask, control characters removed). [erase]
  /// characters the paste replaces are erased only once it goes ahead.
  Future<void> _pasteText(String original, {int erase = 0, bool fromKeyboard = false}) async {
    String? text = original;
    final confirm = widget.confirmPaste;
    if (confirm != null) {
      text = await confirm(text);
      if (!mounted) return;
      if (fromKeyboard) {
        // The keyboard's buffer holds the paste whatever the answer; start
        // it afresh so it matches what the program has.
        _imeValue = _imeBase;
        _ime?.setEditingState(_imeBase);
      }
      _focus.requestFocus();
    }
    if (text != null && text.isNotEmpty) {
      _erase(erase);
      widget.controller.paste(text);
    }
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
    final x = local.dx - _inset;
    final col = (x / cw).floor().clamp(0, 0xFFFF);
    final right = x - col * cw > cw / 2;
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
    final cell = _cellAt(e.localPosition);
    final over = _isLinkCell(cell);
    if (over != _overLink) setState(() => _overLink = over);
    // Only programs in any-motion mode take these; the engine drops the rest.
    if (cell.col != _hoverCell?.col || cell.line != _hoverCell?.line) {
      _hoverCell = cell;
      _report(TerminalMouseAction.move, null, cell);
    }
  }

  // ---- Mouse reporting -----------------------------------------------------
  //
  // A program that asks for the mouse (vim with mouse=a, tmux, htop) gets
  // clicks, drags and the wheel. Holding Shift selects and scrolls here
  // instead, as in other terminals.

  /// The button a reported press is holding, until its release.
  TerminalMouseButton? _reportedButton;
  _Cell? _reportedCell;

  /// Where the last buttonless move was, so each cell is reported once.
  _Cell? _hoverCell;

  static TerminalMouseButton? _buttonOf(int buttons) {
    if (buttons & kPrimaryButton != 0) return TerminalMouseButton.left;
    if (buttons & kMiddleMouseButton != 0) return TerminalMouseButton.middle;
    if (buttons & kSecondaryButton != 0) return TerminalMouseButton.right;
    return null;
  }

  /// `held`: the drag or release of a press the program already has, which
  /// it gets whatever Shift does meanwhile.
  bool _report(TerminalMouseAction action, TerminalMouseButton? button, _Cell cell, {bool held = false}) {
    final c = widget.controller;
    final hw = HardwareKeyboard.instance;
    if ((hw.isShiftPressed && !held) || !c.grid.mouseReporting) return false;
    return c.mouse(
      action,
      button,
      cell.col.clamp(0, math.max(0, c.grid.cols - 1)),
      cell.line.clamp(0, math.max(0, c.grid.rows - 1)),
      alt: hw.isAltPressed,
      ctrl: hw.isControlPressed,
    );
  }

  void _onPointerDown(PointerDownEvent e) {
    _focus.requestFocus();
    // Touch selection (long press, handles) comes with the mobile build.
    if (e.kind == PointerDeviceKind.touch) {
      if (_useIme) _openIme();
      return;
    }
    final button = _buttonOf(e.buttons);
    final at = _cellAt(e.localPosition);
    if (button != null && _report(TerminalMouseAction.press, button, at)) {
      _reportedButton = button;
      _reportedCell = at;
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
    if (_reportedButton != null) {
      final cell = _cellAt(e.localPosition);
      if (cell.col == _reportedCell?.col && cell.line == _reportedCell?.line) return;
      _reportedCell = cell;
      _report(TerminalMouseAction.move, _reportedButton, cell, held: true);
      return;
    }
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
    final button = _reportedButton;
    if (button != null) {
      _reportedButton = null;
      _report(TerminalMouseAction.release, button, _cellAt(e.localPosition), held: true);
    }
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
      final cell = _cellAt(event.localPosition);
      final wheel = lines > 0 ? TerminalMouseAction.wheelDown : TerminalMouseAction.wheelUp;
      if (_report(wheel, null, cell)) {
        for (var i = 1; i < lines.abs(); i++) {
          _report(wheel, null, cell);
        }
        return;
      }
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
        final cols = _metrics.colsFor(constraints.maxWidth - _inset);
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
                      inset: _inset,
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
