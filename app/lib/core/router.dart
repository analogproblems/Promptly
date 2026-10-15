import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/hosts/host_editor_screen.dart';
import '../features/hosts/hosts_screen.dart';
import '../features/keys/keys_screen.dart';
import '../features/sessions/session_screen.dart';
import '../features/sessions/sessions_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/themes_screen.dart';
import '../features/sync/sync_screen.dart';
import '../features/shell/shell_scaffold.dart';
import '../features/snippets/run_on_hosts_screen.dart';
import '../features/snippets/snippet_editor_screen.dart';
import '../features/snippets/snippets_screen.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/hosts',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => ShellScaffold(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/hosts',
              builder: (_, _) => const HostsScreen(),
              routes: [
                GoRoute(path: 'new', builder: (_, _) => const HostEditorScreen()),
                GoRoute(
                  path: ':id',
                  builder: (_, state) => HostEditorScreen(hostId: state.pathParameters['id']),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/sessions',
              builder: (_, _) => const SessionsScreen(),
              routes: [
                GoRoute(
                  path: ':id',
                  builder: (_, state) =>
                      SessionScreen(id: int.tryParse(state.pathParameters['id'] ?? '') ?? -1),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/snippets',
              builder: (_, _) => const SnippetsScreen(),
              routes: [
                GoRoute(path: 'new', builder: (_, _) => const SnippetEditorScreen()),
                GoRoute(
                  path: ':id',
                  builder: (_, state) => SnippetEditorScreen(snippetId: state.pathParameters['id']),
                  routes: [
                    GoRoute(
                      path: 'run',
                      builder: (_, state) => RunOnHostsScreen(snippetId: state.pathParameters['id']!),
                    ),
                  ],
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/keys', builder: (_, _) => const KeysScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
              routes: [
                GoRoute(path: 'themes', builder: (_, _) => const ThemesScreen()),
                GoRoute(path: 'sync', builder: (_, _) => const SyncScreen()),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});
