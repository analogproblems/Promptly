import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'app_shortcuts.dart';
import 'command_palette.dart';
import 'desktop_actions.dart';
import 'workspace.dart';

/// Standard menus with standard shortcuts across the top of the window on
/// desktop. The shortcuts shown beside the items are registered with the
/// app, so they work wherever the focus is; the terminal leaves them alone.
class AppMenuBar extends ConsumerStatefulWidget {
  const AppMenuBar({super.key});

  @override
  ConsumerState<AppMenuBar> createState() => _AppMenuBarState();
}

/// The bar's height, its bottom border included. It sits at the top of the
/// window, so menus have the window's height less this to open into.
const double _barHeight = 41;
const double _itemHeight = 36;

class _AppMenuBarState extends ConsumerState<AppMenuBar> {
  ShortcutRegistryEntry? _shortcuts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final actions = DesktopActions(context, ref);
    _shortcuts?.dispose();
    _shortcuts = ShortcutRegistry.of(context).addAll(<ShortcutActivator, Intent>{
      AppShortcuts.newTab: VoidCallbackIntent(actions.newTab),
      AppShortcuts.closePane: VoidCallbackIntent(actions.closePane),
      AppShortcuts.nextTab: VoidCallbackIntent(actions.nextTab),
      AppShortcuts.previousTab: VoidCallbackIntent(actions.previousTab),
      AppShortcuts.splitRight: VoidCallbackIntent(actions.splitRight),
      AppShortcuts.splitDown: VoidCallbackIntent(actions.splitDown),
      AppShortcuts.hostsPanel: VoidCallbackIntent(actions.toggleHostsPanel),
      AppShortcuts.palette: VoidCallbackIntent(() => showCommandPalette(context, ref)),
      AppShortcuts.find: VoidCallbackIntent(actions.find),
      AppShortcuts.copy: VoidCallbackIntent(actions.copy),
      AppShortcuts.paste: VoidCallbackIntent(actions.paste),
      AppShortcuts.quit: VoidCallbackIntent(actions.quit),
      AppShortcuts.focusLeft: VoidCallbackIntent(() => actions.focus(PaneDirection.left)),
      AppShortcuts.focusRight: VoidCallbackIntent(() => actions.focus(PaneDirection.right)),
      AppShortcuts.focusUp: VoidCallbackIntent(() => actions.focus(PaneDirection.up)),
      AppShortcuts.focusDown: VoidCallbackIntent(() => actions.focus(PaneDirection.down)),
      AppShortcuts.zoomIn: VoidCallbackIntent(actions.zoomIn),
      AppShortcuts.zoomOut: VoidCallbackIntent(actions.zoomOut),
      AppShortcuts.zoomReset: VoidCallbackIntent(actions.zoomReset),
      for (var i = 0; i < 9; i++) AppShortcuts.tab(i): VoidCallbackIntent(() => actions.selectTab(i)),
    });
  }

  @override
  void dispose() {
    _shortcuts?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final actions = DesktopActions(context, ref);
    final hasSession = ref.watch(focusedSessionProvider) != null;
    final hostsPanel = ref.watch(workspaceProvider.select((s) => s.hostsPanel));
    final style = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(t.surface),
      elevation: const WidgetStatePropertyAll(0),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    );
    // A menu too tall for the space under the bar is pushed up over the bar
    // by Flutter, so cap each one at that space; it scrolls past that.
    final menuStyle = MenuStyle(
      minimumSize: const WidgetStatePropertyAll(Size(220, 0)),
      maximumSize: WidgetStatePropertyAll(
        Size(double.infinity, math.max(_itemHeight * 3, MediaQuery.sizeOf(context).height - _barHeight - 8)),
      ),
    );
    // The bar's own labels keep even spacing on both sides.
    final barItemStyle = SubmenuButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16));
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: MenuButtonTheme(
        // Compact rows, with room after the shortcuts even when a scrollbar
        // sits over the menu's right edge.
        data: MenuButtonThemeData(
          style: MenuItemButton.styleFrom(
            minimumSize: const Size(0, _itemHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsetsDirectional.only(start: 16, end: 24),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              height: _barHeight - 1,
              child: MenuBar(
                style: style,
                children: [
                  SubmenuButton(
                    style: barItemStyle,
                    menuStyle: menuStyle,
                    key: const Key('menu-file'),
                    menuChildren: [
                      MenuItemButton(
                        onPressed: actions.newTab,
                        shortcut: AppShortcuts.newTab,
                        child: const Text('New tab'),
                      ),
                      MenuItemButton(onPressed: actions.newLocalShell, child: const Text('New local shell')),
                      MenuItemButton(onPressed: () => context.go('/hosts/new'), child: const Text('Add host…')),
                      const Divider(height: 1),
                      MenuItemButton(
                        onPressed: actions.closePane,
                        shortcut: AppShortcuts.closePane,
                        child: const Text('Close pane'),
                      ),
                      MenuItemButton(onPressed: actions.quit, shortcut: AppShortcuts.quit, child: const Text('Quit')),
                    ],
                    child: const Text('File'),
                  ),
                  SubmenuButton(
                    style: barItemStyle,
                    menuStyle: menuStyle,
                    menuChildren: [
                      MenuItemButton(
                        onPressed: hasSession ? actions.copy : null,
                        shortcut: AppShortcuts.copy,
                        child: const Text('Copy'),
                      ),
                      MenuItemButton(
                        onPressed: hasSession ? actions.paste : null,
                        shortcut: AppShortcuts.paste,
                        child: const Text('Paste'),
                      ),
                      const Divider(height: 1),
                      MenuItemButton(
                        onPressed: hasSession ? actions.find : null,
                        shortcut: AppShortcuts.find,
                        child: const Text('Find in session…'),
                      ),
                      MenuItemButton(
                        onPressed: () => showCommandPalette(context, ref),
                        shortcut: AppShortcuts.palette,
                        child: const Text('Command palette…'),
                      ),
                    ],
                    child: const Text('Edit'),
                  ),
                  SubmenuButton(
                    style: barItemStyle,
                    menuStyle: menuStyle,
                    menuChildren: [
                      MenuItemButton(
                        onPressed: actions.splitRight,
                        shortcut: AppShortcuts.splitRight,
                        child: const Text('Split right'),
                      ),
                      MenuItemButton(
                        onPressed: actions.splitDown,
                        shortcut: AppShortcuts.splitDown,
                        child: const Text('Split down'),
                      ),
                      MenuItemButton(
                        onPressed: () => actions.focus(PaneDirection.left),
                        shortcut: AppShortcuts.focusLeft,
                        child: const Text('Focus pane left'),
                      ),
                      MenuItemButton(
                        onPressed: () => actions.focus(PaneDirection.right),
                        shortcut: AppShortcuts.focusRight,
                        child: const Text('Focus pane right'),
                      ),
                      MenuItemButton(
                        onPressed: () => actions.focus(PaneDirection.up),
                        shortcut: AppShortcuts.focusUp,
                        child: const Text('Focus pane up'),
                      ),
                      MenuItemButton(
                        onPressed: () => actions.focus(PaneDirection.down),
                        shortcut: AppShortcuts.focusDown,
                        child: const Text('Focus pane down'),
                      ),
                      const Divider(height: 1),
                      MenuItemButton(
                        onPressed: actions.nextTab,
                        shortcut: AppShortcuts.nextTab,
                        child: const Text('Next tab'),
                      ),
                      MenuItemButton(
                        onPressed: actions.previousTab,
                        shortcut: AppShortcuts.previousTab,
                        child: const Text('Previous tab'),
                      ),
                      SubmenuButton(
                        menuStyle: menuStyle,
                        menuChildren: [
                          for (var i = 0; i < 9; i++)
                            MenuItemButton(
                              style: MenuItemButton.styleFrom(minimumSize: const Size(160, _itemHeight)),
                              onPressed: () => actions.selectTab(i),
                              shortcut: AppShortcuts.tab(i),
                              child: Text('Tab ${i + 1}'),
                            ),
                        ],
                        child: const Text('Go to tab'),
                      ),
                      const Divider(height: 1),
                      MenuItemButton(
                        onPressed: actions.toggleHostsPanel,
                        shortcut: AppShortcuts.hostsPanel,
                        leadingIcon: Icon(
                          hostsPanel ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                          size: 18,
                        ),
                        child: const Text('Hosts panel'),
                      ),
                      const Divider(height: 1),
                      MenuItemButton(
                        onPressed: hasSession ? actions.zoomIn : null,
                        shortcut: AppShortcuts.zoomIn,
                        child: const Text('Bigger text'),
                      ),
                      MenuItemButton(
                        onPressed: hasSession ? actions.zoomOut : null,
                        shortcut: AppShortcuts.zoomOut,
                        child: const Text('Smaller text'),
                      ),
                      MenuItemButton(
                        onPressed: hasSession ? actions.zoomReset : null,
                        shortcut: AppShortcuts.zoomReset,
                        child: const Text('Reset text size'),
                      ),
                      MenuItemButton(
                        onPressed: () => context.go('/settings/themes'),
                        child: const Text('Terminal themes…'),
                      ),
                    ],
                    child: const Text('View'),
                  ),
                  SubmenuButton(
                    style: barItemStyle,
                    menuStyle: menuStyle,
                    menuChildren: [
                      MenuItemButton(onPressed: hasSession ? actions.reconnect : null, child: const Text('Reconnect')),
                      MenuItemButton(
                        onPressed: hasSession ? actions.forwards : null,
                        child: const Text('Port forwards…'),
                      ),
                      MenuItemButton(onPressed: hasSession ? actions.snippets : null, child: const Text('Snippets…')),
                      MenuItemButton(onPressed: hasSession ? actions.files : null, child: const Text('Files…')),
                      const Divider(height: 1),
                      MenuItemButton(
                        onPressed: hasSession ? actions.closeSession : null,
                        child: const Text('Close session'),
                      ),
                    ],
                    child: const Text('Session'),
                  ),
                  SubmenuButton(
                    style: barItemStyle,
                    menuStyle: menuStyle,
                    menuChildren: [
                      MenuItemButton(onPressed: () => context.go('/settings/help'), child: const Text('Help')),
                      MenuItemButton(onPressed: () => context.go('/settings'), child: const Text('Settings')),
                      MenuItemButton(
                        onPressed: () => context.go('/settings/about'),
                        child: const Text('About Promptly'),
                      ),
                    ],
                    child: const Text('Help'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
