import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/repositories.dart';
import '../settings/settings_providers.dart';
import '../snippets/repositories.dart';
import '../snippets/run_snippet.dart';
import 'desktop_actions.dart';
import 'workspace.dart';

/// One thing the palette can do.
class PaletteItem {
  const PaletteItem({required this.label, required this.icon, required this.run, this.hint, this.key});

  final String label;
  final String? hint;
  final IconData icon;
  final VoidCallback run;
  final String? key;
}

/// Everything the palette offers right now, hosts and snippets first.
List<PaletteItem> paletteItems(BuildContext context, WidgetRef ref) {
  final actions = DesktopActions(context, ref);
  final focused = ref.read(focusedSessionProvider);
  final items = <PaletteItem>[];
  for (final h in ref.read(hostsProvider)) {
    items.add(PaletteItem(
      key: 'host-${h.id}',
      label: 'Connect to ${h.label}',
      hint: h.endpoint,
      icon: Icons.dns_outlined,
      run: () => actions.connect(h),
    ));
  }
  for (final s in ref.read(snippetsProvider)) {
    items.add(PaletteItem(
      key: 'snippet-${s.id}',
      label: 'Run snippet ${s.label}',
      hint: s.firstLine,
      icon: Icons.code,
      run: () => runSnippetInSession(context, ref, s, session: focused),
    ));
  }
  items.addAll([
    PaletteItem(label: 'New local shell', icon: Icons.terminal, run: actions.newLocalShell),
    PaletteItem(label: 'New tab', hint: 'Ctrl+Shift+T', icon: Icons.tab, run: actions.newTab),
    PaletteItem(label: 'Split right', hint: 'Ctrl+Shift+D', icon: Icons.vertical_split, run: actions.splitRight),
    PaletteItem(label: 'Split down', hint: 'Ctrl+Shift+E', icon: Icons.horizontal_split, run: actions.splitDown),
    PaletteItem(label: 'Close pane', hint: 'Ctrl+Shift+W', icon: Icons.close, run: actions.closePane),
    PaletteItem(label: 'Hosts panel', hint: 'Ctrl+Shift+B', icon: Icons.view_sidebar_outlined, run: actions.toggleHostsPanel),
    PaletteItem(label: 'Find in session', hint: 'Ctrl+Shift+F', icon: Icons.search, run: actions.find),
    PaletteItem(label: 'Port forwards', icon: Icons.alt_route, run: actions.forwards),
    PaletteItem(label: 'Reconnect', icon: Icons.refresh, run: actions.reconnect),
    PaletteItem(label: 'Add host', icon: Icons.add, run: () => context.go('/hosts/new')),
    PaletteItem(label: 'New snippet', icon: Icons.add, run: () => context.go('/snippets/new')),
    PaletteItem(label: 'Hosts', icon: Icons.dns, run: () => context.go('/hosts')),
    PaletteItem(label: 'Sessions', icon: Icons.terminal, run: () => context.go('/sessions')),
    PaletteItem(label: 'Snippets', icon: Icons.code, run: () => context.go('/snippets')),
    PaletteItem(label: 'Keys', icon: Icons.key, run: () => context.go('/keys')),
    PaletteItem(label: 'Settings', icon: Icons.tune, run: () => context.go('/settings')),
    PaletteItem(label: 'Sync', hint: 'Where the vault lives', icon: Icons.cloud_outlined, run: () => context.go('/settings/sync')),
    PaletteItem(label: 'Terminal themes', icon: Icons.palette_outlined, run: () => context.go('/settings/themes')),
    PaletteItem(label: 'App look: Light', icon: Icons.light_mode_outlined, run: () => ref.read(themeModeProvider.notifier).set(ThemeMode.light)),
    PaletteItem(label: 'App look: Dark', icon: Icons.dark_mode_outlined, run: () => ref.read(themeModeProvider.notifier).set(ThemeMode.dark)),
    PaletteItem(label: 'App look: System', icon: Icons.brightness_auto_outlined, run: () => ref.read(themeModeProvider.notifier).set(ThemeMode.system)),
    PaletteItem(
      label: 'Terminal theme: match the app',
      icon: Icons.palette_outlined,
      run: () => ref.read(terminalThemeProvider.notifier).set(TerminalThemeNotifier.auto),
    ),
  ]);
  for (final theme in ref.read(themesProvider)) {
    items.add(PaletteItem(
      key: 'theme-${theme.id}',
      label: 'Terminal theme: ${theme.name}',
      icon: Icons.palette_outlined,
      run: () => ref.read(terminalThemeProvider.notifier).set(theme.id),
    ));
  }
  return items;
}

/// Ctrl+Shift+P: type a few letters, pick a host, a snippet, a theme or
/// an action, Enter.
Future<void> showCommandPalette(BuildContext context, WidgetRef ref) {
  final items = paletteItems(context, ref);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black38,
    builder: (_) => _Palette(items: items),
  );
}

class _Palette extends StatefulWidget {
  const _Palette({required this.items});

  final List<PaletteItem> items;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _field = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';
  int _selected = 0;

  List<PaletteItem> get _shown {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return widget.items;
    return [
      for (final i in widget.items)
        if (words.every((w) => i.label.toLowerCase().contains(w) || (i.hint?.toLowerCase().contains(w) ?? false))) i,
    ];
  }

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _run(PaletteItem item) {
    Navigator.of(context).pop();
    item.run();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final shown = _shown;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1).clamp(0, shown.isEmpty ? 0 : shown.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1).clamp(0, shown.isEmpty ? 0 : shown.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (shown.isNotEmpty) _run(shown[_selected.clamp(0, shown.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = _shown;
    final selected = shown.isEmpty ? -1 : _selected.clamp(0, shown.length - 1);
    return Align(
      alignment: const Alignment(0, -0.7),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 8))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    key: const Key('palette-field'),
                    controller: _field,
                    autofocus: true,
                    style: monoStyle(context, size: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Connect to a host, run a snippet, switch theme…',
                      prefixIcon: Icon(Icons.search, color: t.muted),
                    ),
                    onChanged: (v) => setState(() {
                      _query = v;
                      _selected = 0;
                    }),
                  ),
                ),
              ),
              Divider(height: 1, color: t.border),
              Flexible(
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Nothing matches.', style: TextStyle(color: t.muted, fontSize: 13)),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final item = shown[i];
                          final on = i == selected;
                          return InkWell(
                            key: item.key == null ? null : Key('palette-${item.key}'),
                            onTap: () => _run(item),
                            child: Container(
                              color: on ? t.accent.withValues(alpha: 0.12) : null,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              child: Row(
                                children: [
                                  Icon(item.icon, size: 18, color: on ? t.accent : t.muted),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(item.label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: t.text)),
                                  ),
                                  if (item.hint != null)
                                    Text(item.hint!, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: t.muted)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
