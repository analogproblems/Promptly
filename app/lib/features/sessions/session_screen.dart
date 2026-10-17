import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'session_body.dart';
import 'session_manager.dart';

/// A single session filling the screen, for phones and narrow windows: a
/// back arrow, then the session.
class SessionScreen extends ConsumerWidget {
  const SessionScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(sessionManagerProvider.select((s) {
      for (final e in s) {
        if (e.id == id) return e;
      }
      return null;
    }));
    if (entry == null) {
      return Center(
        child: Text('This session is closed.', style: TextStyle(color: context.tokens.muted)),
      );
    }
    return SessionBody(
      key: ValueKey('session-body-$id'),
      entry: entry,
      showBack: true,
      onClose: () {
        ref.read(sessionManagerProvider.notifier).close(id);
        context.go('/sessions');
      },
      onSwitchSession: (step) {
        // The sessions in the order the list shows them; no wrapping round.
        final sessions = ref.read(sessionManagerProvider);
        final here = sessions.indexWhere((e) => e.id == id);
        final at = here + step;
        if (here < 0 || at < 0 || at >= sessions.length) return;
        context.go('/sessions/${sessions[at].id}');
      },
    );
  }
}
