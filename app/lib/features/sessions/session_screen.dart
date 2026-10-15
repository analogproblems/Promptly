import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../terminal/terminal_view.dart';
import 'connecting_view.dart';
import 'session_manager.dart';

/// A single session: slim top bar, then nothing but terminal. While an SSH
/// connection is being made, the terminal area shows the progress and any
/// question the server has.
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
    final t = context.tokens;

    if (entry == null) {
      return Center(
        child: Text('This session is closed.', style: TextStyle(color: t.muted)),
      );
    }

    void closeAndLeave() {
      ref.read(sessionManagerProvider.notifier).close(id);
      context.go('/sessions');
    }

    return ListenableBuilder(
      listenable: Listenable.merge([entry, ?entry.controller]),
      builder: (context, _) {
        final c = entry.controller;
        final live = c != null && !c.exited;
        return Column(
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(bottom: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back to sessions',
                    onPressed: () => context.go('/sessions'),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: live
                          ? t.accent
                          : entry.isConnecting
                              ? t.warning
                              : t.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.title,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  if (c != null)
                    Text(
                      '${c.grid.cols}×${c.grid.rows}',
                      style: monoStyle(context, size: 11, color: t.muted),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Close session',
                    onPressed: closeAndLeave,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: c == null
                  ? (entry.flow != null
                      ? ConnectingView(
                          flow: entry.flow!,
                          onCancel: closeAndLeave,
                          onRetry: () => ref.read(sessionManagerProvider.notifier).retry(id),
                        )
                      : Center(
                          child: Text(entry.error ?? 'Nothing here.', style: TextStyle(color: t.muted)),
                        ))
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        TerminalView(controller: c),
                        if (c.exited)
                          _ExitedOverlay(
                            code: c.exitCode,
                            isLocal: entry.isLocal,
                            onClose: closeAndLeave,
                            onAgain: () {
                              final manager = ref.read(sessionManagerProvider.notifier);
                              if (entry.isLocal) {
                                final dark = Theme.of(context).brightness == Brightness.dark;
                                manager.close(id);
                                final fresh = manager.openLocalShell(dark: dark);
                                context.go('/sessions/${fresh.id}');
                              } else {
                                final request = entry.flow?.request;
                                manager.close(id);
                                if (request != null) {
                                  final fresh = manager.connectSsh(request);
                                  context.go('/sessions/${fresh.id}');
                                } else {
                                  context.go('/sessions');
                                }
                              }
                            },
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ExitedOverlay extends StatelessWidget {
  const _ExitedOverlay({
    required this.code,
    required this.isLocal,
    required this.onClose,
    required this.onAgain,
  });

  final int? code;
  final bool isLocal;
  final VoidCallback onClose;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final what = isLocal ? 'The shell' : 'The connection';
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      alignment: Alignment.center,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code == null || code == 0 ? '$what ended.' : '$what ended with code $code.',
                style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(onPressed: onClose, child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: onAgain, child: Text(isLocal ? 'New shell' : 'Reconnect')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
