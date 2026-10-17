import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'session_manager.dart';

/// Where a session's connection stands, in words: what the dot means, for
/// its tooltip and for screen readers.
String sessionStatusLabel(SessionEntry? entry) {
  if (entry == null) return 'Empty';
  if (entry.reconnecting) return 'Reconnecting…';
  final c = entry.controller;
  if (c != null && !c.exited) return 'Connected';
  if (entry.isConnecting) return 'Connecting';
  return 'Not connected';
}

/// The connection pulse: green and steady when connected, amber while
/// connecting, amber and pulsing while reconnecting (steady when the system
/// asks for less motion), grey otherwise.
class SessionStatusDot extends StatefulWidget {
  const SessionStatusDot({super.key, required this.entry, this.size = 8, this.liveColor});

  /// Null for an empty pane.
  final SessionEntry? entry;
  final double size;

  /// The colour when connected; the theme's accent by default.
  final Color? liveColor;

  @override
  State<SessionStatusDot> createState() => _SessionStatusDotState();
}

class _SessionStatusDotState extends State<SessionStatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.3,
    value: 1,
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final entry = widget.entry;
    final label = sessionStatusLabel(entry);
    final reconnecting = entry?.reconnecting ?? false;
    final color = switch (label) {
      'Connected' => widget.liveColor ?? t.accent,
      'Connecting' || 'Reconnecting…' => t.warning,
      _ => t.muted,
    };
    final pulsing = reconnecting && !MediaQuery.disableAnimationsOf(context);
    if (pulsing && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!pulsing && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 1;
    }
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        key: const Key('session-status'),
        label: label,
        child: FadeTransition(
          opacity: _pulse,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

/// The red bar across a session to a production host. It carries the
/// host's label in words, so the warning never rests on colour alone.
class ProductionBar extends StatelessWidget {
  const ProductionBar({super.key, required this.label, this.compact = false});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Whichever of black and white reads better on this theme's red.
    final ink = t.danger.computeLuminance() > 0.179 ? const Color(0xFF0E1116) : Colors.white;
    return Semantics(
      container: true,
      label: 'Production host: $label',
      excludeSemantics: true,
      child: Container(
        key: const Key('production-bar'),
        width: double.infinity,
        color: t.danger,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 2 : 4),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: compact ? 14 : 16, color: ink),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink,
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
