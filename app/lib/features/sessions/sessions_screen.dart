import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/host_colors.dart';
import '../settings/settings_providers.dart';
import '../shell/empty_state.dart';
import 'session_manager.dart';
import 'session_thumbnail.dart';

/// True where a local shell makes sense: the desktops.
bool get supportsLocalShell => !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

/// Open a local shell and show it. Shared by the Sessions and Hosts screens.
void openLocalShell(BuildContext context, WidgetRef ref) {
  final theme = terminalThemeFor(ref, context);
  final entry = ref.read(sessionManagerProvider.notifier).openLocalShell(theme: theme);
  context.go('/sessions/${entry.id}');
}

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionManagerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Sessions',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sessions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 6),
                  child: _Summary(sessions: sessions),
                ),
              if (supportsLocalShell)
                FilledButton.icon(
                  onPressed: () => openLocalShell(context, ref),
                  icon: const Icon(Icons.terminal, size: 18),
                  label: const Text('Local shell'),
                ),
            ],
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? EmptyState(
                  icon: Icons.terminal_outlined,
                  title: 'No live sessions',
                  message: supportsLocalShell
                      ? 'Open a local shell to try the terminal, or connect to a host. Sessions stay open while you move around the app.'
                      : 'Open a host and it shows up here with a live thumbnail, so you can watch a build finish from the list.',
                  action: supportsLocalShell
                      ? OutlinedButton.icon(
                          onPressed: () => openLocalShell(context, ref),
                          icon: const Icon(Icons.terminal),
                          label: const Text('Open a local shell'),
                        )
                      : null,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  itemCount: sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => SessionCard(
                    entry: sessions[i],
                    onOpen: () => context.go('/sessions/${sessions[i].id}'),
                    onClose: () => ref.read(sessionManagerProvider.notifier).close(sessions[i].id),
                  ),
                ),
        ),
      ],
    );
  }
}

/// "2 live · 1 connecting", or whatever applies.
class _Summary extends StatelessWidget {
  const _Summary({required this.sessions});

  final List<SessionEntry> sessions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(sessions),
      builder: (context, _) {
        var live = 0, connecting = 0, ended = 0;
        for (final s in sessions) {
          final c = s.controller;
          if (c != null && !c.exited) {
            live++;
          } else if (s.isConnecting || s.reconnecting) {
            connecting++;
          } else {
            ended++;
          }
        }
        final parts = [
          if (live > 0) '$live live',
          if (connecting > 0) '$connecting connecting',
          if (ended > 0) '$ended ended',
        ];
        return Text(parts.join(' · '), style: TextStyle(fontSize: 12, color: context.tokens.muted));
      },
    );
  }
}

/// One session in the list: its colour, name and state, with a live
/// thumbnail of the screen underneath.
class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.entry, required this.onOpen, required this.onClose});

  final SessionEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) {
        final c = entry.controller;
        final live = c != null && !c.exited;
        final String status;
        final Color dot;
        if (entry.reconnecting) {
          status = entry.reconnectStatus;
          dot = t.warning;
        } else if (c == null) {
          status = entry.error != null ? 'Failed: ${entry.error}' : 'Connecting…';
          dot = entry.error != null ? t.danger : t.warning;
        } else if (c.exited) {
          status = 'Ended${c.exitCode == null ? '' : ' with code ${c.exitCode}'}';
          dot = t.muted;
        } else {
          status = '${entry.isLocal ? 'Local shell' : 'SSH'} · ${c.grid.cols}×${c.grid.rows}';
          dot = t.accent;
        }
        final accent = entry.color == null ? null : hostColor(entry.color, Theme.of(context).brightness);

        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: accent ?? Colors.transparent, width: 3)),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          entry.title,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(context, size: 14, weight: FontWeight.w600, color: t.text),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: t.muted),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close session',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: onClose,
                      ),
                    ],
                  ),
                ),
                if (c != null)
                  Opacity(
                    opacity: live ? 1 : 0.55,
                    child: SessionThumbnail(controller: c),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
