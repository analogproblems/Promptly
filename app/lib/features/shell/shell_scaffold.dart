import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';

/// The five-tab shell. A rail on the side when there is room (desktop,
/// tablet), a bar along the bottom on a phone.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const double wideBreakpoint = 720;

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
        if (wide) {
          return Scaffold(
            body: Row(
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

/// A block cursor in prompt green: the mark until there is a real icon.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      label: 'Promptly',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('p', style: monoStyle(context, size: 18, weight: FontWeight.w700, color: t.text)),
          const SizedBox(width: 2),
          Container(
            width: 10,
            height: 18,
            decoration: BoxDecoration(
              color: t.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
