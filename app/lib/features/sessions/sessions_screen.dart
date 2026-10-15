import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import 'session_manager.dart';

/// True where a local shell makes sense: the desktops.
bool get supportsLocalShell => !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

/// Open a local shell and show it. Shared by the Sessions and Hosts screens.
void openLocalShell(BuildContext context, WidgetRef ref) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final entry = ref.read(sessionManagerProvider.notifier).openLocalShell(dark: dark);
  context.go('/sessions/${entry.id}');
}

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionManagerProvider);
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Sessions',
          trailing: supportsLocalShell
              ? FilledButton.icon(
                  onPressed: () => openLocalShell(context, ref),
                  icon: const Icon(Icons.terminal, size: 18),
                  label: const Text('Local shell'),
                )
              : null,
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
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    return ListenableBuilder(
                      listenable: s,
                      builder: (context, _) {
                        final c = s.controller;
                        final live = c != null && !c.exited;
                        final String status;
                        if (c == null) {
                          status = s.error != null ? 'Failed: ${s.error}' : 'Connecting…';
                        } else if (c.exited) {
                          status = 'Ended${c.exitCode == null ? '' : ' with code ${c.exitCode}'}';
                        } else {
                          status = '${s.isLocal ? 'Local shell' : 'SSH'} · ${c.grid.cols}×${c.grid.rows}';
                        }
                        return Card(
                          child: ListTile(
                            onTap: () => context.go('/sessions/${s.id}'),
                            leading: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: live
                                    ? t.accent
                                    : s.isConnecting
                                        ? t.warning
                                        : t.muted,
                                shape: BoxShape.circle,
                              ),
                            ),
                            title: Text(s.title, style: monoStyle(context, size: 14, weight: FontWeight.w600)),
                            subtitle: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                              tooltip: 'Close session',
                              icon: const Icon(Icons.close),
                              onPressed: () => ref.read(sessionManagerProvider.notifier).close(s.id),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
