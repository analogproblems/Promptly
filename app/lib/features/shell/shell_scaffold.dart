import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
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

  void _go(int index) {
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideBreakpoint;
        final menuBar = constraints.maxWidth >= desktopBreakpoint && isDesktopPlatform;
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
                    for (final t in _tabs)
                      NavigationRailDestination(
                        icon: Icon(t.icon),
                        selectedIcon: Icon(t.selected),
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
              for (final t in _tabs)
                NavigationDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.selected),
                  label: t.label,
                ),
            ],
          ),
        );
      },
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
