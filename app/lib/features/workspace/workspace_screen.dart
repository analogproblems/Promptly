import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/host_colors.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../sessions/session_body.dart';
import '../sessions/session_manager.dart';
import '../sessions/sessions_screen.dart' show supportsLocalShell;
import 'desktop_actions.dart';
import 'workspace.dart';

/// The desktop sessions area: tabs across the top, panes below, and a
/// hosts panel at the side to drag hosts in from.
class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({super.key, this.showSessionId});

  /// A session the route asked for; it is brought on screen.
  final int? showSessionId;

  @override
  ConsumerState<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  @override
  void initState() {
    super.initState();
    _show();
  }

  @override
  void didUpdateWidget(WorkspaceScreen old) {
    super.didUpdateWidget(old);
    if (old.showSessionId != widget.showSessionId) _show();
  }

  void _show() {
    final id = widget.showSessionId;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(workspaceProvider.notifier).showSession(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(workspaceProvider);
    final t = context.tokens;
    final tab = ws.currentTab;
    return Column(
      children: [
        _TabStrip(state: ws),
        Expanded(
          child: Row(
            children: [
              if (ws.hostsPanel) ...[const _HostsPanel(), VerticalDivider(width: 1, thickness: 1, color: t.border)],
              Expanded(
                child: tab == null
                    ? const SizedBox.shrink()
                    : _PaneTreeView(key: ValueKey('tab-${tab.id}'), node: tab.root, tab: tab),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabStrip extends ConsumerWidget {
  const _TabStrip({required this.state});

  final WorkspaceState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final sessions = ref.watch(sessionManagerProvider);
    final actions = DesktopActions(context, ref);
    SessionEntry? sessionOf(WorkspaceTab tab) {
      final id = tab.focused.sessionId ?? tab.leaves.map((l) => l.sessionId).whereType<int>().firstOrNull;
      for (final e in sessions) {
        if (e.id == id) return e;
      }
      return null;
    }

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('hosts-panel-toggle'),
            tooltip: 'Hosts panel (Ctrl+Shift+B)',
            visualDensity: VisualDensity.compact,
            isSelected: state.hostsPanel,
            onPressed: actions.toggleHostsPanel,
            icon: const Icon(Icons.view_sidebar_outlined, size: 18),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < state.tabs.length; i++)
                  _Tab(
                    key: Key('tab-${state.tabs[i].id}'),
                    tab: state.tabs[i],
                    session: sessionOf(state.tabs[i]),
                    selected: i == state.current,
                    paneCount: state.tabs[i].leaves.length,
                    onSelect: () => actions.selectTab(i),
                    onClose: () => ref.read(workspaceProvider.notifier).closeTab(state.tabs[i].id),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('tab-new'),
            tooltip: 'New tab (Ctrl+Shift+T)',
            visualDensity: VisualDensity.compact,
            onPressed: actions.newTab,
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    super.key,
    required this.tab,
    required this.session,
    required this.selected,
    required this.paneCount,
    required this.onSelect,
    required this.onClose,
  });

  final WorkspaceTab tab;
  final SessionEntry? session;
  final bool selected;
  final int paneCount;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final brightness = Theme.of(context).brightness;
    return ListenableBuilder(
      listenable: session ?? Listenable.merge(const []),
      builder: (context, _) {
        final s = session;
        final title = s == null ? 'New tab' : s.title;
        final accent = s?.color == null ? null : hostColor(s!.color, brightness);
        final live = s?.controller != null && !(s!.controller!.exited);
        return InkWell(
          onTap: onSelect,
          child: Container(
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
            padding: const EdgeInsets.only(left: 12, right: 2),
            decoration: BoxDecoration(
              color: selected ? t.background : null,
              border: Border(
                bottom: BorderSide(color: selected ? (accent ?? t.accent) : Colors.transparent, width: 2),
                right: BorderSide(color: t.border),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: s == null
                        ? t.muted
                        : live
                        ? (accent ?? t.accent)
                        : t.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    paneCount > 1 ? '$title +${paneCount - 1}' : title,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      context,
                      size: 12,
                      weight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? t.text : t.muted,
                    ),
                  ),
                ),
                IconButton(
                  key: Key('tab-close-${tab.id}'),
                  tooltip: 'Close tab',
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  onPressed: onClose,
                  icon: Icon(Icons.close, color: t.muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Saved hosts beside the panes. Click one to connect in the focused pane
/// (or a new tab), or drag it onto any pane.
class _HostsPanel extends ConsumerStatefulWidget {
  const _HostsPanel();

  @override
  ConsumerState<_HostsPanel> createState() => _HostsPanelState();
}

class _HostsPanelState extends ConsumerState<_HostsPanel> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hosts = ref.watch(hostsProvider).where((h) {
      if (_query.isEmpty) return true;
      return h.label.toLowerCase().contains(_query) || h.hostname.toLowerCase().contains(_query);
    }).toList();
    final actions = DesktopActions(context, ref);
    final brightness = Theme.of(context).brightness;
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: TextField(
              key: const Key('panel-search'),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              style: monoStyle(context, size: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Hosts',
                prefixIcon: Icon(Icons.search, size: 16, color: t.muted),
              ),
            ),
          ),
          Expanded(
            child: hosts.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No hosts yet. Add one on the Hosts tab.',
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: [
                      for (final h in hosts)
                        Draggable<Host>(
                          data: h,
                          feedback: Material(
                            color: Colors.transparent,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: t.surface,
                                border: Border.all(color: t.accent),
                                borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                              ),
                              child: Text(h.label, style: monoStyle(context, size: 12, color: t.text)),
                            ),
                          ),
                          child: InkWell(
                            key: Key('panel-host-${h.id}'),
                            onTap: () {
                              final focused = ref.read(workspaceProvider).currentTab?.focused;
                              if (focused != null && focused.sessionId == null) {
                                actions.connectInto(focused.id, h);
                              } else {
                                actions.connect(h);
                              }
                            },
                            borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: hostColor(h.color ?? defaultColorFor(h.label), brightness),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          h.label,
                                          overflow: TextOverflow.ellipsis,
                                          style: monoStyle(context, size: 12, weight: FontWeight.w600, color: t.text),
                                        ),
                                        Text(
                                          h.endpoint,
                                          overflow: TextOverflow.ellipsis,
                                          style: monoStyle(context, size: 10, color: t.muted),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A pane tree: splits become rows or columns with a draggable divider;
/// leaves become sessions or the empty pane.
class _PaneTreeView extends ConsumerWidget {
  const _PaneTreeView({super.key, required this.node, required this.tab});

  final PaneNode node;
  final WorkspaceTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (node) {
      case PaneLeaf():
        return _PaneLeafView(leaf: node as PaneLeaf, tab: tab);
      case PaneSplit():
        final split = node as PaneSplit;
        return LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = split.axis == Axis.horizontal;
            final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
            final firstSize = (total * split.ratio).clamp(0.0, total);
            final first = _PaneTreeView(key: ValueKey('node-${split.first.id}'), node: split.first, tab: tab);
            final second = _PaneTreeView(key: ValueKey('node-${split.second.id}'), node: split.second, tab: tab);
            final divider = _Divider(
              axis: split.axis,
              onDrag: (delta) => ref.read(workspaceProvider.notifier).setRatio(split.id, (firstSize + delta) / total),
            );
            return Flex(
              direction: split.axis,
              children: [
                SizedBox(width: horizontal ? firstSize : null, height: horizontal ? null : firstSize, child: first),
                divider,
                Expanded(child: second),
              ],
            );
          },
        );
    }
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.axis, required this.onDrag});

  final Axis axis;
  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onDrag(horizontal ? d.delta.dx : d.delta.dy),
        child: Container(width: horizontal ? 5 : null, height: horizontal ? null : 5, color: t.border),
      ),
    );
  }
}

class _PaneLeafView extends ConsumerWidget {
  const _PaneLeafView({required this.leaf, required this.tab});

  final PaneLeaf leaf;
  final WorkspaceTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final focused = tab.focusedLeaf == leaf.id;
    final several = tab.leaves.length > 1;
    SessionEntry? entry;
    if (leaf.sessionId != null) {
      entry = ref.watch(
        sessionManagerProvider.select((s) {
          for (final e in s) {
            if (e.id == leaf.sessionId) return e;
          }
          return null;
        }),
      );
    }
    final actions = DesktopActions(context, ref);
    final ws = ref.read(workspaceProvider.notifier);

    return DragTarget<Host>(
      onAcceptWithDetails: (d) {
        if (entry == null) {
          actions.connectInto(leaf.id, d.data);
        } else {
          // A pane that is taken: open the host beside it.
          ws.focusLeaf(leaf.id);
          final fresh = ws.split(Axis.horizontal);
          if (fresh != null) actions.connectInto(fresh, d.data);
        }
      },
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return Container(
          key: Key('pane-${leaf.id}'),
          decoration: BoxDecoration(
            border: Border.all(
              color: hovering
                  ? t.accent
                  : several && focused
                  ? t.accent.withValues(alpha: 0.6)
                  : Colors.transparent,
              width: hovering ? 2 : 1,
            ),
          ),
          child: entry == null
              ? _EmptyPane(leafId: leaf.id, onFocus: () => ws.focusLeaf(leaf.id))
              : SessionBody(
                  key: ValueKey('session-body-${entry.id}'),
                  entry: entry,
                  compact: true,
                  focused: focused,
                  onFocus: () => ws.focusLeaf(leaf.id),
                  onClose: () {
                    ws.focusLeaf(leaf.id);
                    ws.closeFocusedPane();
                  },
                  onReplaced: (id) => ws.attachSession(leaf.id, id),
                ),
        );
      },
    );
  }
}

/// A pane with nothing in it yet: pick a host, drop one in, or open a
/// shell.
class _EmptyPane extends ConsumerStatefulWidget {
  const _EmptyPane({required this.leafId, required this.onFocus});

  final int leafId;
  final VoidCallback onFocus;

  @override
  ConsumerState<_EmptyPane> createState() => _EmptyPaneState();
}

class _EmptyPaneState extends ConsumerState<_EmptyPane> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hosts = ref.watch(hostsProvider).where((h) {
      if (_query.isEmpty) return true;
      return h.label.toLowerCase().contains(_query) || h.hostname.toLowerCase().contains(_query);
    }).toList();
    final actions = DesktopActions(context, ref);
    final brightness = Theme.of(context).brightness;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.onFocus(),
      child: Material(
        color: t.background,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.dns_outlined, size: 28, color: t.muted),
                const SizedBox(height: 10),
                Text(
                  'Drop a host here',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text),
                ),
                const SizedBox(height: 4),
                Text(
                  'Or pick one below. Split with Ctrl+Shift+D or Ctrl+Shift+E; Ctrl+Shift+P for everything else.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: t.muted),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: Key('pane-search-${widget.leafId}'),
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                  style: monoStyle(context, size: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search hosts',
                    prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
                  ),
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final h in hosts.take(8))
                        ListTile(
                          key: Key('pane-host-${h.id}'),
                          dense: true,
                          leading: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: hostColor(h.color ?? defaultColorFor(h.label), brightness),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          title: Text(
                            h.label,
                            style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text),
                          ),
                          subtitle: Text(h.endpoint, style: monoStyle(context, size: 11, color: t.muted)),
                          onTap: () => actions.connectInto(widget.leafId, h),
                        ),
                    ],
                  ),
                ),
                if (supportsLocalShell) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: Key('pane-local-${widget.leafId}'),
                    onPressed: () => actions.localShellInto(widget.leafId),
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text('Local shell'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
