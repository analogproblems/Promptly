import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/host_colors.dart';
import '../settings/settings_providers.dart';
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
      listenable: entry,
      builder: (context, _) {
        final c = entry.controller;
        final live = c != null && !c.exited;
        final accent = entry.color == null ? null : hostColor(entry.color, Theme.of(context).brightness);
        return Column(
          children: [
            if (accent != null)
              Container(key: const Key('host-colour-bar'), height: 3, color: accent),
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
                        if (entry.reconnecting)
                          _ReconnectOverlay(
                            entry: entry,
                            onStop: () => ref.read(sessionManagerProvider.notifier).stopReconnect(id),
                          )
                        else if (c.exited)
                          _ExitedOverlay(
                            code: c.exitCode,
                            isLocal: entry.isLocal,
                            detail: entry.error,
                            onClose: closeAndLeave,
                            onAgain: () {
                              final manager = ref.read(sessionManagerProvider.notifier);
                              if (entry.isLocal) {
                                final theme = terminalThemeFor(ref, context);
                                manager.close(id);
                                final fresh = manager.openLocalShell(theme: theme);
                                context.go('/sessions/${fresh.id}');
                              } else if (entry.flow?.request != null) {
                                manager.reconnectNow(id);
                              } else {
                                manager.close(id);
                                context.go('/sessions');
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

/// Over a session whose connection dropped: what is happening, a way to
/// stop, and any question the new connection asks (a changed host key, a
/// password that is not saved).
class _ReconnectOverlay extends StatelessWidget {
  const _ReconnectOverlay({required this.entry, required this.onStop});

  final SessionEntry entry;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final flow = entry.flow;
    final inProgress = flow != null && entry.reconnectAt == null;
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.sync_problem, color: t.warning),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Connection dropped',
                        style: TextStyle(color: t.text, fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                    ),
                    TextButton(onPressed: onStop, child: const Text('Stop')),
                  ],
                ),
                const SizedBox(height: 4),
                Text(entry.reconnectStatus, style: TextStyle(color: t.muted, fontSize: 13)),
                if (inProgress) ...[
                  const SizedBox(height: 12),
                  Flexible(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                      child: ConnectingView(flow: flow, onCancel: onStop, onRetry: () {}),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExitedOverlay extends StatelessWidget {
  const _ExitedOverlay({
    required this.code,
    required this.isLocal,
    required this.onClose,
    required this.onAgain,
    this.detail,
  });

  final int? code;
  final bool isLocal;
  final VoidCallback onClose;
  final VoidCallback onAgain;

  /// Why, when there is more to say (for example a reconnect that gave up).
  final String? detail;

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
              if (detail != null) ...[
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(detail!, textAlign: TextAlign.center, style: TextStyle(color: t.muted, fontSize: 13)),
                ),
              ],
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
