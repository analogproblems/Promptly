import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'keyboard_bar_keys.dart';
import 'terminal_controller.dart';
import 'terminal_view.dart';

/// The row of keys a phone keyboard lacks, above the system keyboard: Esc,
/// Tab, sticky Ctrl and Alt, arrows, and the characters shells live on,
/// in the order chosen in Settings. Ctrl and Alt hold for the next key;
/// tapped twice quickly (or long pressed) they lock until tapped again.
/// Holding an arrow key a moment and sliding sends arrows the way the
/// finger goes, like a trackpad. Every key has a label for screen readers.
class KeyboardBar extends ConsumerStatefulWidget {
  const KeyboardBar({super.key, required this.controller, this.onSnippets});

  final TerminalController controller;
  final VoidCallback? onSnippets;

  /// How long after tapping Ctrl or Alt a second tap locks it.
  static const lockWindow = Duration(milliseconds: 350);

  /// How long to hold an arrow key before sliding sends arrows.
  static const slideHold = Duration(milliseconds: 250);

  /// How far a finger slides on an arrow key for each arrow sent.
  static const slideStep = 16.0;

  @override
  ConsumerState<KeyboardBar> createState() => _KeyboardBarState();
}

class _KeyboardBarState extends ConsumerState<KeyboardBar> {
  /// Running while a second tap on this modifier would lock it.
  Timer? _lockWindow;
  String? _lastModifier;

  /// Slide distance not yet turned into arrows, across and down.
  double _slideX = 0;
  double _slideY = 0;

  TerminalController get _c => widget.controller;

  @override
  void dispose() {
    _lockWindow?.cancel();
    super.dispose();
  }

  bool _isOn(String id) => id == 'ctrl' ? _c.stickyCtrl : _c.stickyAlt;
  bool _isLocked(String id) => id == 'ctrl' ? _c.lockedCtrl : _c.lockedAlt;

  void _setModifier(String id, {required bool on, bool lock = false}) {
    if (id == 'ctrl') {
      _c.setSticky(ctrl: on, lockCtrl: lock);
    } else {
      _c.setSticky(alt: on, lockAlt: lock);
    }
  }

  /// Off, then on for the next key, then (a quick second tap) locked; a tap
  /// on a held or locked key lets it go.
  void _tapModifier(String id) {
    final second = _lastModifier == id && (_lockWindow?.isActive ?? false);
    _lockWindow?.cancel();
    _lastModifier = id;
    if (_isLocked(id)) {
      _setModifier(id, on: false);
    } else if (_isOn(id) && second) {
      _lock(id);
    } else if (_isOn(id)) {
      _setModifier(id, on: false);
    } else {
      _setModifier(id, on: true);
      HapticFeedback.selectionClick();
      _lockWindow = Timer(KeyboardBar.lockWindow, () {});
    }
  }

  void _lock(String id) {
    _lockWindow?.cancel();
    _setModifier(id, on: true, lock: true);
    HapticFeedback.mediumImpact();
  }

  void _press(BarKey k) {
    if (k.isModifier) return _tapModifier(k.id);
    final char = k.char;
    if (char != null) {
      // A character goes through the sticky modifiers (Ctrl+- and so on).
      _c.write(_c.encodeTyped(char));
      return;
    }
    _send(k.id);
    _c.releaseSticky();
  }

  void _send(String id) {
    _c.write(barKeySequence(id, ctrl: _c.stickyCtrl, alt: _c.stickyAlt, appCursor: _c.grid.appCursor));
  }

  /// Turn finger travel into arrows: one per [KeyboardBar.slideStep], with
  /// a tick for each.
  void _slide({double dx = 0, double dy = 0}) {
    _slideX += dx;
    _slideY += dy;
    const step = KeyboardBar.slideStep;
    while (_slideX.abs() >= step || _slideY.abs() >= step) {
      final String id;
      if (_slideX.abs() >= step) {
        id = _slideX > 0 ? 'right' : 'left';
        _slideX -= _slideX.sign * step;
      } else {
        id = _slideY > 0 ? 'down' : 'up';
        _slideY -= _slideY.sign * step;
      }
      _send(id);
      _slid = true;
      HapticFeedback.selectionClick();
    }
  }

  /// Whether this slide has sent anything yet. A touch that turns out to
  /// be a tap also ends a slide, and must leave the modifiers for the tap.
  bool _slid = false;

  void _endSlide() {
    _slideX = 0;
    _slideY = 0;
    if (_slid) _c.releaseSticky();
    _slid = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final layout = ref.watch(barLayoutProvider);
    // Large text makes the bar taller rather than cutting labels off, up to
    // a point: past one and a half times, the bar would crowd the terminal.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Builder(
        builder: (context) {
          final height = 30 + MediaQuery.textScalerOf(context).scale(14);
          return ListenableBuilder(
            listenable: _c,
            builder: (context, _) => Container(
              height: height,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(top: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      children: [
                        for (final id in layout)
                          if (barKeyById(id) case final k?)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _key(k),
                            ),
                      ],
                    ),
                  ),
                  if (widget.onSnippets != null)
                    IconButton(
                      key: const Key('kb-snippets'),
                      tooltip: 'Snippets',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onSnippets,
                      icon: const Icon(Icons.code, size: 20),
                    ),
                  IconButton(
                    key: const Key('kb-keyboard'),
                    tooltip: 'Hide the keyboard',
                    visualDensity: VisualDensity.compact,
                    onPressed: TerminalView.hideKeyboard,
                    icon: const Icon(Icons.keyboard_hide_outlined, size: 20),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _key(BarKey k) {
    if (k.isModifier) {
      final locked = _isLocked(k.id);
      final on = _isOn(k.id);
      return _KeyButton(
        k,
        on: on,
        locked: locked,
        value: locked ? 'locked' : (on ? 'on for the next key' : 'off'),
        hint: locked ? 'Tap to let go' : 'Tap twice quickly, or long press, to lock',
        onTap: () => _press(k),
        onLongPress: locked ? null : () => _lock(k.id),
      );
    }
    final button = _KeyButton(
      k,
      hint: k.isArrow ? 'Hold and slide to move repeatedly' : null,
      onTap: () => _press(k),
    );
    if (!k.isArrow) return button;
    // Hold an arrow key a moment, then slide: arrows follow the finger in
    // any direction, like a trackpad. The hold keeps a quick swipe across
    // the bar scrolling it, wherever it starts.
    return RawGestureDetector(
      key: Key('kb-slide-${k.id}'),
      gestures: {
        LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: KeyboardBar.slideHold, debugOwner: this),
          (r) {
            r.onLongPressStart = (_) {
              _slideAt = Offset.zero;
              HapticFeedback.selectionClick();
            };
            r.onLongPressMoveUpdate = (d) {
              final delta = d.offsetFromOrigin - _slideAt;
              _slideAt = d.offsetFromOrigin;
              _slide(dx: delta.dx, dy: delta.dy);
            };
            r.onLongPressEnd = (_) => _endSlide();
            r.onLongPressCancel = _endSlide;
          },
        ),
      },
      child: button,
    );
  }

  /// Where the finger was at the last slide update, from where it held.
  Offset _slideAt = Offset.zero;
}

class _KeyButton extends StatelessWidget {
  const _KeyButton(
    this.k, {
    required this.onTap,
    this.onLongPress,
    this.on = false,
    this.locked = false,
    this.value,
    this.hint,
  });

  final BarKey k;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool on;
  final bool locked;
  final String? value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fg = on ? t.onAccent : t.text;
    return Semantics(
      button: true,
      label: k.spoken,
      value: value,
      hint: hint,
      selected: on,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Material(
        key: Key('kb-${k.id}'),
        color: on ? t.accent : t.background,
        // Locked: a solid outline and a padlock, so it does not rely on colour.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: locked ? BorderSide(color: t.text, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (locked) ...[
                  Icon(Icons.lock, key: Key('kb-${k.id}-locked'), size: 12, color: fg),
                  const SizedBox(width: 3),
                ],
                Text(k.label, style: monoStyle(context, size: 13, weight: FontWeight.w600, color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
