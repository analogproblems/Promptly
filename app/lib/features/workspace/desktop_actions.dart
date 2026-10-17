import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../sessions/forwards_sheet.dart';
import '../sessions/session_manager.dart';
import '../sessions/snippets_drawer.dart';
import '../settings/settings_providers.dart';
import '../terminal/paste_guard.dart';
import 'workspace.dart';

/// What the menu bar, the command palette and the shortcuts can do. One
/// place, so the three agree.
class DesktopActions {
  DesktopActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  WorkspaceNotifier get _ws => ref.read(workspaceProvider.notifier);
  SessionManager get _sessions => ref.read(sessionManagerProvider.notifier);
  SessionEntry? get focused => ref.read(focusedSessionProvider);

  void newTab() {
    _ws.newTab();
    context.go('/sessions');
  }

  void newLocalShell() {
    final theme = terminalThemeFor(ref, context);
    final entry = _sessions.openLocalShell(theme: theme);
    context.go('/sessions/${entry.id}');
  }

  /// Connect to a saved host and show it.
  void connect(Host host) {
    final theme = terminalThemeFor(ref, context);
    final entry = _sessions.connectHost(host, theme: theme);
    context.go('/sessions/${entry.id}');
  }

  /// Connect into one particular pane.
  void connectInto(int leafId, Host host) {
    final theme = terminalThemeFor(ref, context);
    final entry = _sessions.connectHost(host, theme: theme);
    _ws.attachSession(leafId, entry.id);
    context.go('/sessions');
  }

  void localShellInto(int leafId) {
    final theme = terminalThemeFor(ref, context);
    final entry = _sessions.openLocalShell(theme: theme);
    _ws.attachSession(leafId, entry.id);
    context.go('/sessions');
  }

  void closePane() => _ws.closeFocusedPane();
  void splitRight() => _ws.split(Axis.horizontal);
  void splitDown() => _ws.split(Axis.vertical);
  void nextTab() => _ws.nextTab();
  void previousTab() => _ws.previousTab();
  void selectTab(int index) => _ws.selectTab(index);
  void toggleHostsPanel() => _ws.toggleHostsPanel();
  void focus(PaneDirection d) => _ws.focusNeighbour(d);

  void find() => ref.read(findRequestProvider.notifier).request();

  Future<void> copy() async {
    final text = focused?.controller?.selectionText();
    if (text != null && text.isNotEmpty) await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> paste() async {
    final c = focused?.controller;
    if (c == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    var text = data?.text;
    if (text == null || text.isEmpty || !context.mounted) return;
    text = await confirmPaste(context, text, warn: ref.read(pasteWarningProvider));
    if (text != null && text.isNotEmpty) c.paste(text);
  }

  void zoomIn() => focused?.controller?.setFontSize((focused?.controller?.fontSize ?? 14) + 1);
  void zoomOut() => focused?.controller?.setFontSize((focused?.controller?.fontSize ?? 14) - 1);
  void zoomReset() => focused?.controller?.setFontSize(14);

  void reconnect() {
    final e = focused;
    if (e != null && !e.isLocal) _sessions.reconnectNow(e.id);
  }

  void closeSession() {
    final e = focused;
    if (e != null) _sessions.close(e.id);
  }

  void forwards() {
    final e = focused;
    final c = e?.controller;
    if (c != null) showForwardsSheet(context, ref, c.id);
  }

  void snippets() {
    final e = focused;
    if (e != null) showSnippetsDrawer(context, ref, e);
  }

  void files() {
    final e = focused;
    if (e != null && !e.isLocal && e.controller != null) context.go('/sessions/${e.id}/files');
  }

  void quit() {
    for (final e in ref.read(sessionManagerProvider)) {
      _sessions.close(e.id);
    }
    exit(0);
  }

  /// Every saved host, for the palette and the panel.
  List<Host> get hosts => ref.read(hostsProvider);
}
