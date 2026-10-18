import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'app_shortcuts.dart';
import 'command_palette.dart';
import 'desktop_actions.dart';
import 'workspace.dart';

/// Standard menus with standard shortcuts across the top of the window on
/// Windows and Linux. The shortcuts shown beside the items are registered
/// with the app, so they work wherever the focus is; the terminal leaves
/// them alone. A Mac uses [SystemMenuBar] instead.
class AppMenuBar extends ConsumerStatefulWidget {
  const AppMenuBar({super.key});

  @override
  ConsumerState<AppMenuBar> createState() => _AppMenuBarState();
}

/// The bar's height, its bottom border included. It sits at the top of the
/// window, so menus have the window's height less this to open into.
const double _barHeight = 33;
const double _itemHeight = 36;

/// Registers the shortcuts shown beside the menu items with the app, so they
/// work wherever the focus is; the terminal leaves them alone. Both menu
/// bars, the one in the window and the Mac's own, use it.
mixin _MenuShortcuts<T extends ConsumerStatefulWidget> on ConsumerState<T> {
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
}

class _AppMenuBarState extends ConsumerState<AppMenuBar> with _MenuShortcuts {
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
    final barItemStyle = SubmenuButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      minimumSize: const Size(0, _barHeight - 1),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
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

/// The Mac's own menu bar, at the top of the screen, with the same menus as
/// the one drawn in the window elsewhere, plus the application menu every
/// Mac app has (About, Settings, Hide, Quit) and a Window menu.
class SystemMenuBar extends ConsumerStatefulWidget {
  const SystemMenuBar({super.key, required this.child});

  final Widget child;

  /// On a Mac the system menu bar takes the place of the one in the window.
  static bool get supported => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  ConsumerState<SystemMenuBar> createState() => _SystemMenuBarState();
}

class _SystemMenuBarState extends ConsumerState<SystemMenuBar> with _MenuShortcuts {
  /// The standard items the Mac provides, those it has.
  static List<PlatformMenuItem> _provided(List<PlatformProvidedMenuItemType> types) => [
    for (final type in types)
      if (PlatformProvidedMenuItem.hasMenu(type)) PlatformProvidedMenuItem(type: type),
  ];

  static PlatformMenuItem _item(String label, VoidCallback? onSelected, [MenuSerializableShortcut? shortcut]) =>
      PlatformMenuItem(label: label, onSelected: onSelected, shortcut: shortcut);

  /// A group with a separator around it; none when it would be empty.
  static List<PlatformMenuItem> _group(List<PlatformMenuItem> members) =>
      members.isEmpty ? const [] : [PlatformMenuItemGroup(members: members)];

  @override
  Widget build(BuildContext context) {
    final actions = DesktopActions(context, ref);
    final hasSession = ref.watch(focusedSessionProvider) != null;
    final hostsPanel = ref.watch(workspaceProvider.select((s) => s.hostsPanel));
    void go(String location) => context.go(location);
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'Promptly',
          menus: [
            _item('About Promptly', () => go('/settings/about')),
            ..._group([
              _item('Settings…', () => go('/settings'), const SingleActivator(LogicalKeyboardKey.comma, meta: true)),
            ]),
            ..._group(_provided(const [PlatformProvidedMenuItemType.servicesSubmenu])),
            ..._group(
              _provided(const [
                PlatformProvidedMenuItemType.hide,
                PlatformProvidedMenuItemType.hideOtherApplications,
                PlatformProvidedMenuItemType.showAllApplications,
              ]),
            ),
            ..._group([
              // Promptly's own quit, so open sessions are closed properly.
              _item('Quit Promptly', actions.quit, const SingleActivator(LogicalKeyboardKey.keyQ, meta: true)),
            ]),
          ],
        ),
        PlatformMenu(
          label: 'File',
          menus: [
            _item('New tab', actions.newTab, AppShortcuts.newTab),
            _item('New local shell', actions.newLocalShell),
            _item('Add host…', () => go('/hosts/new')),
            ..._group([_item('Close pane', actions.closePane, AppShortcuts.closePane)]),
          ],
        ),
        PlatformMenu(
          label: 'Edit',
          menus: [
            _item('Copy', hasSession ? actions.copy : null, AppShortcuts.copy),
            _item('Paste', hasSession ? actions.paste : null, AppShortcuts.paste),
            ..._group([
              _item('Find in session…', hasSession ? actions.find : null, AppShortcuts.find),
              _item('Command palette…', () => showCommandPalette(context, ref), AppShortcuts.palette),
            ]),
          ],
        ),
        PlatformMenu(
          label: 'View',
          menus: [
            ..._group([
              _item('Split right', actions.splitRight, AppShortcuts.splitRight),
              _item('Split down', actions.splitDown, AppShortcuts.splitDown),
              _item('Focus pane left', () => actions.focus(PaneDirection.left), AppShortcuts.focusLeft),
              _item('Focus pane right', () => actions.focus(PaneDirection.right), AppShortcuts.focusRight),
              _item('Focus pane up', () => actions.focus(PaneDirection.up), AppShortcuts.focusUp),
              _item('Focus pane down', () => actions.focus(PaneDirection.down), AppShortcuts.focusDown),
            ]),
            ..._group([
              _item('Next tab', actions.nextTab, AppShortcuts.nextTab),
              _item('Previous tab', actions.previousTab, AppShortcuts.previousTab),
              PlatformMenu(
                label: 'Go to tab',
                menus: [
                  for (var i = 0; i < 9; i++) _item('Tab ${i + 1}', () => actions.selectTab(i), AppShortcuts.tab(i)),
                ],
              ),
            ]),
            ..._group([
              _item(
                hostsPanel ? 'Hide hosts panel' : 'Show hosts panel',
                actions.toggleHostsPanel,
                AppShortcuts.hostsPanel,
              ),
            ]),
            ..._group([
              _item('Bigger text', hasSession ? actions.zoomIn : null, AppShortcuts.zoomIn),
              _item('Smaller text', hasSession ? actions.zoomOut : null, AppShortcuts.zoomOut),
              _item('Reset text size', hasSession ? actions.zoomReset : null, AppShortcuts.zoomReset),
              _item('Terminal themes…', () => go('/settings/themes')),
            ]),
            ..._group(_provided(const [PlatformProvidedMenuItemType.toggleFullScreen])),
          ],
        ),
        PlatformMenu(
          label: 'Session',
          menus: [
            _item('Reconnect', hasSession ? actions.reconnect : null),
            _item('Port forwards…', hasSession ? actions.forwards : null),
            _item('Snippets…', hasSession ? actions.snippets : null),
            _item('Files…', hasSession ? actions.files : null),
            ..._group([_item('Close session', hasSession ? actions.closeSession : null)]),
          ],
        ),
        if (_provided(const [PlatformProvidedMenuItemType.minimizeWindow]).isNotEmpty)
          PlatformMenu(
            label: 'Window',
            menus: _provided(const [
              PlatformProvidedMenuItemType.minimizeWindow,
              PlatformProvidedMenuItemType.zoomWindow,
              PlatformProvidedMenuItemType.arrangeWindowsInFront,
            ]),
          ),
        PlatformMenu(label: 'Help', menus: [_item('Promptly Help', () => go('/settings/help'))]),
      ],
      child: widget.child,
    );
  }
}
