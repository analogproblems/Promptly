import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform.dart';
import '../../core/theme/tokens.dart';
import '../sessions/session_manager.dart';
import '../sessions/sessions_in_background.dart';
import '../workspace/app_menu_bar.dart';

/// The five-tab shell. A rail on the side when there is room (desktop,
/// tablet), a bar along the bottom on a phone.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const double wideBreakpoint = 720;

  /// From here up the Sessions tab becomes a workspace of tabs and panes,
  /// and desktop platforms get a menu bar.
  static const double desktopBreakpoint = 900;

  static bool isDesktopLayout(BuildContext context) => MediaQuery.sizeOf(context).width >= desktopBreakpoint;

  static bool get isDesktopPlatform => !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  static const _tabs = [
    (label: 'Hosts', icon: Icons.dns_outlined, selected: Icons.dns),
    (label: 'Sessions', icon: Icons.terminal_outlined, selected: Icons.terminal),
    (label: 'Snippets', icon: Icons.code_outlined, selected: Icons.code),
    (label: 'Keys', icon: Icons.key_outlined, selected: Icons.key),
    (label: 'Settings', icon: Icons.tune_outlined, selected: Icons.tune),
  ];

  /// The Sessions tab carries a count of open sessions.
  static const _sessionsTab = 1;

  static Widget _icon(int index, IconData icon) =>
      index == _sessionsTab ? _SessionCount(child: Icon(icon)) : Icon(icon);

  void _go(int index) {
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    // A Mac has its menu bar at the top of the screen, whatever the window's
    // size; elsewhere the menus are drawn in a wide enough window.
    final systemMenus = isDesktopPlatform && SystemMenuBar.supported;
    final layout = LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideBreakpoint;
        final menuBar = constraints.maxWidth >= desktopBreakpoint && isDesktopPlatform && !systemMenus;
        if (wide) {
          return Scaffold(
            body: Column(
              children: [
                if (menuBar) const AppMenuBar(),
                Expanded(
                  child: Row(
              children: [
                NavigationRail(
                  selectedIndex: shell.currentIndex,
                  onDestinationSelected: _go,
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.only(top: 8, bottom: 16),
                    child: _Wordmark(),
                  ),
                  destinations: [
                    for (final (i, t) in _tabs.indexed)
                      NavigationRailDestination(
                        icon: _icon(i, t.icon),
                        selectedIcon: _icon(i, t.selected),
                        label: Text(t.label),
                      ),
                  ],
                ),
                VerticalDivider(width: 1, thickness: 1, color: context.tokens.border),
                Expanded(child: shell),
              ],
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: shell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: _go,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final (i, t) in _tabs.indexed)
                NavigationDestination(
                  icon: _icon(i, t.icon),
                  selectedIcon: _icon(i, t.selected),
                  label: t.label,
                ),
            ],
          ),
        );
      },
    );
    final shown = systemMenus ? SystemMenuBar(child: layout) : layout;
    if (!isAndroid) return shown;
    // Back with nothing left to go back to puts the app in the background,
    // as Android 12 and later do anyway. Before 12 it would close the app
    // and end every open session with it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        SessionsInBackground.channel.invokeMethod<void>('moveToBack').catchError((Object _) {});
      },
      child: shown,
    );
  }
}

/// A badge with how many sessions are open, on the Sessions tab's icon.
/// None when there are none.
class _SessionCount extends ConsumerWidget {
  const _SessionCount({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(sessionManagerProvider.select((s) => s.length));
    return Badge(
      key: const Key('sessions-count'),
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count', semanticsLabel: '$count open'),
      backgroundColor: context.tokens.accent,
      textColor: context.tokens.onAccent,
      child: child,
    );
  }
}

/// The app icon at the top of the rail.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/icon/promptly.png', width: 32, height: 32, semanticLabel: 'Promptly');
  }
}
