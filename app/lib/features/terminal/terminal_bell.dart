import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform.dart';
import '../settings/settings_providers.dart' show BellMode;
import 'terminal_controller.dart';

/// Shows the terminal bell over [child]: a quick flash of the screen, or a
/// vibration on a phone, as the setting says. With reduced motion the flash
/// is a thin outline that comes and goes without fading.
class TerminalBell extends StatefulWidget {
  const TerminalBell({
    super.key,
    required this.controller,
    required this.mode,
    required this.child,
    this.canVibrate,
  });

  final TerminalController controller;
  final BellMode mode;
  final Widget child;

  /// Whether this device can vibrate; phones and tablets by default.
  final bool? canVibrate;

  @override
  State<TerminalBell> createState() => _TerminalBellState();
}

class _TerminalBellState extends State<TerminalBell> with SingleTickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  /// The outline shown instead of the flash with reduced motion.
  bool _outline = false;
  Timer? _outlineOff;

  /// When the phone last vibrated, so a burst of bells is one buzz.
  DateTime? _lastBuzz;

  static const _outlineFor = Duration(milliseconds: 400);
  static const _buzzGap = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    // A bell rung while nothing showed this session is old news.
    widget.controller.clearBell();
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(TerminalBell old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.clearBell();
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _outlineOff?.cancel();
    _flash.dispose();
    super.dispose();
  }

  void _onController() {
    final c = widget.controller;
    if (!c.bell || !mounted) return;
    c.clearBell();
    _ring();
  }

  void _ring() {
    switch (widget.mode) {
      case BellMode.off:
        return;
      case BellMode.vibrate when widget.canVibrate ?? isTouchPlatform:
        final now = DateTime.now();
        if (_lastBuzz != null && now.difference(_lastBuzz!) < _buzzGap) return;
        _lastBuzz = now;
        HapticFeedback.vibrate();
      case BellMode.vibrate:
      case BellMode.flash:
        if (MediaQuery.disableAnimationsOf(context)) {
          setState(() => _outline = true);
          _outlineOff?.cancel();
          _outlineOff = Timer(_outlineFor, () {
            if (mounted) setState(() => _outline = false);
          });
        } else {
          _flash.reverse(from: 1);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = Color(0xFF000000 | widget.controller.grid.defaultFg);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _flash,
              builder: (context, _) {
                if (_outline) {
                  return DecoratedBox(
                    key: const Key('bell-outline'),
                    decoration: BoxDecoration(border: Border.all(color: fg.withValues(alpha: 0.6), width: 2)),
                  );
                }
                if (_flash.value == 0) return const SizedBox.shrink();
                return ColoredBox(
                  key: const Key('bell-flash'),
                  color: fg.withValues(alpha: 0.18 * _flash.value),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
