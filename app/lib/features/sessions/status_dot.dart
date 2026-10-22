import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../hosts/session_labels.dart';
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

/// The coloured bar across a session to a labelled host, such as a
/// production one. It carries the label in words, so the warning never
/// rests on colour alone.
class SessionLabelBar extends StatelessWidget {
  const SessionLabelBar({super.key, required this.mark, this.compact = false});

  final SessionMark mark;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = labelColor(mark.color, Theme.of(context).brightness);
    final ink = inkOn(color);
    return Semantics(
      container: true,
      label: '${mark.name} host: ${mark.text}',
      excludeSemantics: true,
      child: Container(
        key: const Key('session-label-bar'),
        width: double.infinity,
        color: color,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 2 : 4),
        child: Row(
          children: [
            if (mark.warn) ...[
              Icon(Icons.warning_amber_rounded, size: compact ? 14 : 16, color: ink),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                mark.text.toUpperCase(),
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
