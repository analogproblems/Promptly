import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/platform.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../sessions/session_manager.dart';
import '../settings/settings_providers.dart';
import '../sessions/sessions_screen.dart';
import '../shell/empty_state.dart';
import '../sync/sync_providers.dart';
import 'csv_import.dart';
import 'group_editor.dart';
import 'host_colors.dart';
import 'inheritance.dart';
import 'models.dart';
import 'reachability.dart';
import 'repositories.dart';
import 'ssh_config_import.dart';

class HostsScreen extends ConsumerStatefulWidget {
  const HostsScreen({super.key});

  @override
  ConsumerState<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends ConsumerState<HostsScreen> {
  final _search = TextEditingController();
  String _query = '';
  EndpointParse? _quickConnect;

  /// Hosts picked with a long press, to move or delete together. While any
  /// are picked, a tap picks or drops a host instead of connecting.
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  /// The move dialog's answers besides a group id (group ids are UUIDs).
  static const _noGroup = '';
  static const _newGroup = '+new';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    // Anything with an @ is a quick-connect attempt; the engine decides if it is valid.
    final parsed = text.contains('@') ? ref.read(engineProvider).parseEndpoint(text) : null;
    setState(() {
      _query = text.trim().toLowerCase();
      _quickConnect = parsed;
    });
  }

  void _quickConnectTo(EndpointOk ok) {
    final entry = ref.read(sessionManagerProvider.notifier).connectSsh(SshConnectRequest(
      user: ok.user,
      host: ok.host,
      port: ok.port,
      auth: SshAuthKind.password,
      password: null,
      privateKey: null,
      passphrase: null,
      cols: 80,
      rows: 24,
      theme: terminalThemeFor(ref, context),
      label: null,
      keepaliveSeconds: 30,
      reattachSessionId: null,
      jumps: const [],
      persistent: false,
      startupCommand: null,
      env: const [],
      agentForward: false,
      forwards: const [],
    ));
    context.go('/sessions/${entry.id}');
  }

  void _connect(Host host) {
    final theme = terminalThemeFor(ref, context);
    final entry = ref.read(sessionManagerProvider.notifier).connectHost(host, theme: theme);
    context.go('/sessions/${entry.id}');
  }

  Future<void> _delete(Host host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${host.label}?'),
        content: const Text('The host and its saved password are removed. Keys are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.tokens.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(hostsProvider.notifier).delete(host.id);
  }

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  void _clearSelection() => setState(_selected.clear);

  Future<void> _deleteSelected() async {
    final notifier = ref.read(hostsProvider.notifier);
    final hosts = [for (final id in _selected) ?notifier.byId(id)];
    if (hosts.isEmpty) return;
    final one = hosts.length == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(one ? 'Delete ${hosts.single.label}?' : 'Delete ${hosts.length} hosts?'),
        content: Text(
          one
              ? 'The host and its saved password are removed. Keys are kept.'
              : 'The hosts and their saved passwords are removed. Keys are kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('hosts-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: ctx.tokens.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final h in hosts) {
      notifier.delete(h.id);
    }
    _clearSelection();
  }

  Future<void> _moveSelected() async {
    final groups = ref.read(groupsProvider);
    final count = _selected.length;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(count == 1 ? 'Move 1 host to' : 'Move $count hosts to'),
        children: [
          for (final g in groups)
            SimpleDialogOption(
              key: Key('move-to-${g.id}'),
              onPressed: () => Navigator.pop(ctx, g.id),
              child: Text(g.label, overflow: TextOverflow.ellipsis),
            ),
          SimpleDialogOption(
            key: const Key('move-to-none'),
            onPressed: () => Navigator.pop(ctx, _noGroup),
            child: const Text('No group'),
          ),
          SimpleDialogOption(
            key: const Key('move-to-new'),
            onPressed: () => Navigator.pop(ctx, _newGroup),
            child: const Text('New group…'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    Group? target;
    if (choice == _newGroup) {
      target = await showGroupEditor(context, ref, Group.create(''), isNew: true);
      if (target == null || !mounted) return;
    } else if (choice != _noGroup) {
      target = ref.read(groupsProvider.notifier).byId(choice);
    }
    final notifier = ref.read(hostsProvider.notifier);
    for (final id in _selected) {
      final h = notifier.byId(id);
      if (h != null) notifier.save(h.copyWith(groupId: target?.id));
    }
    final what = count == 1 ? '1 host' : '$count hosts';
    _clearSelection();
    notYet(context, target == null ? 'Took $what out of their group.' : 'Moved $what to ${target.label}.');
  }

  /// The add button's choices: a host, a group, or hosts from a file.
  Future<void> _showAddMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('add-host'),
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Host'),
                subtitle: const Text('A server to connect to.'),
                onTap: () => Navigator.pop(ctx, 'host'),
              ),
              ListTile(
                key: const Key('add-group'),
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Group'),
                subtitle: const Text('Hosts that share a user, key or jump host.'),
                onTap: () => Navigator.pop(ctx, 'group'),
              ),
              ListTile(
                key: const Key('add-import-csv'),
                leading: const Icon(Icons.table_chart_outlined),
                title: const Text('Import from a CSV file'),
                subtitle: const Text('From Termius, or any file with a Hostname column.'),
                onTap: () => Navigator.pop(ctx, 'csv'),
              ),
              if (supportsLocalShell)
                ListTile(
                  key: const Key('add-import-ssh-config'),
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Import from ~/.ssh/config'),
                  subtitle: const Text('Hosts, users, ports, jump hosts and keys.'),
                  onTap: () => Navigator.pop(ctx, 'ssh-config'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'host':
        context.go('/hosts/new');
      case 'group':
        await showGroupEditor(context, ref, Group.create(''), isNew: true);
      case 'csv':
        await showCsvImport(context, ref);
      case 'ssh-config':
        await showSshConfigImport(context, ref);
    }
  }

  bool _matches(Host h) => hostMatches(h, _query);

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncStatusProvider).value;
    final t = context.tokens;
    final hosts = ref.watch(hostsProvider);
    final groups = ref.watch(groupsProvider);
    final shown = hosts.where(_matches).toList();
    final reachOn = ref.watch(reachabilityProvider);
    final reach = ref.watch(hostReachabilityProvider);
    final collapsed = ref.watch(collapsedGroupsProvider);
    // A host deleted meanwhile (by sync, say) drops out of the selection.
    _selected.removeWhere((id) => !hosts.any((h) => h.id == id));
    final swipe = isTouchPlatform && !_selecting;

    Widget row(Host h, [String prefix = 'host']) => _HostRow(
          host: h,
          endpoint: Inherited(h, groups).endpoint,
          keyPrefix: prefix,
          reachOn: reachOn,
          reach: reach[h.id],
          selecting: _selecting,
          selected: _selected.contains(h.id),
          swipe: swipe,
          onConnect: () => _selecting ? _toggle(h.id) : _connect(h),
          onSelect: () => _toggle(h.id),
          onEdit: () => context.go('/hosts/${h.id}'),
          onDelete: () => _delete(h),
          onFavourite: () => ref.read(hostsProvider.notifier).toggleFavourite(h.id),
        );

    // Shortcuts above the full list, while nothing is being searched for.
    final favourites = _query.isEmpty ? hosts.where((h) => h.favourite).toList() : const <Host>[];
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final recent = _query.isEmpty && hosts.length >= 4
        ? (hosts.where((h) => h.lastConnectedAt != null && h.lastConnectedAt!.isAfter(cutoff)).toList()
          ..sort((a, b) => b.lastConnectedAt!.compareTo(a.lastConnectedAt!)))
        : const <Host>[];
    final shortcuts = <(String, String, List<Host>)>[
      if (favourites.isNotEmpty) ('Favourites', 'favourite', favourites),
      if (recent.isNotEmpty) ('Recent', 'recent', recent.take(5).toList()),
    ];

    // Sections: each group with matching hosts, then the ungrouped ones.
    final byGroup = <String?, List<Host>>{};
    for (final h in shown) {
      final gid = groups.any((g) => g.id == h.groupId) ? h.groupId : null;
      byGroup.putIfAbsent(gid, () => []).add(h);
    }
    final sections = <(String?, Group?, List<Host>)>[
      for (final g in groups)
        if (byGroup[g.id] case final list?) (g.label, g, list),
      if (byGroup[null] case final list?) (groups.isEmpty ? null : 'Other', null, list),
    ];

    // While searching every group is open, so a match is never hidden.
    bool folded(Group? g) => g != null && _query.isEmpty && collapsed.contains(g.id);

    return PopScope(
      // Back drops the selection before it leaves the screen.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton(
                key: const Key('hosts-add'),
                onPressed: _showAddMenu,
                tooltip: 'Add a host, group or import',
                child: const Icon(Icons.add),
              ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_selecting)
              _SelectionBar(
                count: _selected.length,
                onCancel: _clearSelection,
                onMove: _moveSelected,
                onDelete: _deleteSelected,
              )
            else
              PageHeader(
                title: 'Hosts',
                trailing: InkWell(
                  onTap: () => context.go('/settings/sync'),
                  borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: sync != null && sync.configured
                                ? (sync.lastError == null ? t.accent : t.warning)
                                : t.muted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            syncSummary(sync),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: t.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _search,
                onChanged: _onChanged,
                style: monoStyle(context, size: 14),
                decoration: InputDecoration(
                  hintText: 'Search, or user@host to connect',
                  prefixIcon: Icon(Icons.search, color: t.muted),
                ),
              ),
            ),
            if (_quickConnect case final EndpointOk ok)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Card(
                  child: ListTile(
                    leading: Icon(Icons.bolt_outlined, color: t.accent),
                    title: Text('Connect to ${ok.display}', style: monoStyle(context, size: 14)),
                    subtitle: Text('Port ${ok.port} · not saved'),
                    trailing: FilledButton(
                      onPressed: () => _quickConnectTo(ok),
                      child: const Text('Connect'),
                    ),
                  ),
                ),
              ),
            if (_quickConnect case final EndpointError err)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(err.message, style: TextStyle(color: t.danger, fontSize: 13)),
              ),
            Expanded(
              child: hosts.isEmpty
                  ? EmptyState(
                      icon: Icons.dns_outlined,
                      title: 'No hosts yet',
                      message:
                          'Add a host, or type user@host above to connect straight away. Hosts you add will sync to your other devices once the vault is set up.',
                      action: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => context.go('/hosts/new'),
                            icon: const Icon(Icons.add),
                            label: const Text('Add host'),
                          ),
                          if (supportsLocalShell)
                            FilledButton.icon(
                              onPressed: () => openLocalShell(context, ref),
                              icon: const Icon(Icons.terminal),
                              label: const Text('Local shell'),
                            ),
                          if (supportsLocalShell)
                            OutlinedButton.icon(
                              key: const Key('hosts-import'),
                              onPressed: () => showSshConfigImport(context, ref),
                              icon: const Icon(Icons.file_download_outlined),
                              label: const Text('Import ~/.ssh/config'),
                            ),
                        ],
                      ),
                    )
                  : shown.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off,
                          title: 'No hosts match',
                          message: 'Nothing matches "$_query". Type user@host to connect to somewhere new.',
                        )
                      : PullToSync(
                          enabled: sync?.configured ?? false,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                            children: [
                              for (final (title, prefix, list) in shortcuts) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                                  child: Text(
                                    title.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.8,
                                      color: t.muted,
                                    ),
                                  ),
                                ),
                                for (final h in list) row(h, prefix),
                              ],
                              if (shortcuts.isNotEmpty && sections.first.$1 == null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                                  child: Text(
                                    'ALL HOSTS',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.8,
                                      color: t.muted,
                                    ),
                                  ),
                                ),
                              for (final (title, group, list) in sections) ...[
                                if (title != null)
                                  _SectionHeader(
                                    title: title,
                                    count: list.length,
                                    group: group,
                                    collapsed: folded(group),
                                    onToggle: group == null || _query.isNotEmpty
                                        ? null
                                        : () => ref.read(collapsedGroupsProvider.notifier).toggle(group.id),
                                    onEdit: group == null ? null : () => showGroupEditor(context, ref, group),
                                  ),
                                if (!folded(group))
                                  for (final h in list) row(h),
                              ],
                              // After the hosts, so a small screen still shows them first.
                              if (sync != null && !sync.configured && _query.isEmpty && !ref.watch(backupNudgeDismissedProvider))
                                const _BackupNudge(),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Below the list while there is no vault: the hosts are only on this
/// device, so suggest backing them up, until "Not now".
class _BackupNudge extends ConsumerWidget {
  const _BackupNudge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Card(
        key: const Key('backup-nudge'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_upload_outlined, color: t.accent, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Back up your hosts', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'They are only on this device for now. Set up sync to keep an encrypted copy in a folder or on a server you own, and to use them on your other devices.',
                style: TextStyle(color: t.muted, fontSize: 13),
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('backup-nudge-dismiss'),
                    onPressed: () => ref.read(backupNudgeDismissedProvider.notifier).set(true),
                    child: const Text('Not now'),
                  ),
                  TextButton(
                    key: const Key('backup-nudge-setup'),
                    onPressed: () => context.go('/settings/sync'),
                    child: const Text('Set up sync'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Across the top while hosts are picked: how many, and what to do with them.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.onCancel, required this.onMove, required this.onDelete});

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Row(
        children: [
          IconButton(
            key: const Key('hosts-select-cancel'),
            tooltip: 'Stop selecting',
            onPressed: onCancel,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '$count selected',
              key: const Key('hosts-select-count'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.text),
            ),
          ),
          IconButton(
            key: const Key('hosts-move'),
            tooltip: 'Move to group',
            onPressed: onMove,
            icon: const Icon(Icons.drive_file_move_outline),
          ),
          IconButton(
            key: const Key('hosts-delete'),
            tooltip: 'Delete',
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, color: t.danger),
          ),
        ],
      ),
    );
  }
}

/// A group's name over its hosts, with how many there are. A tap folds the
/// group shut or open again, and that is remembered.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.group,
    required this.collapsed,
    this.onToggle,
    this.onEdit,
  });

  final String title;
  final int count;
  final Group? group;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = group;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: onToggle != null,
              expanded: onToggle == null ? null : !collapsed,
              label: '$title, $count ${count == 1 ? 'host' : 'hosts'}',
              excludeSemantics: true,
              child: InkWell(
                key: g == null ? null : Key('group-toggle-${g.id}'),
                onTap: onToggle,
                borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Row(
                    children: [
                      if (onToggle != null) ...[
                        Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: t.muted),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          title.toUpperCase(),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
                            color: t.muted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('$count', style: TextStyle(fontSize: 11, color: t.muted)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (g != null)
            IconButton(
              key: Key('group-edit-${g.id}'),
              tooltip: 'Edit group',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: Icon(Icons.tune, color: t.muted),
              onPressed: onEdit,
            ),
        ],
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({
    required this.host,
    required this.endpoint,
    required this.onConnect,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    required this.onFavourite,
    this.keyPrefix = 'host',
    this.reachOn = false,
    this.reach,
    this.selecting = false,
    this.selected = false,
    this.swipe = false,
  });

  final Host host;

  /// `user@host:port`, with what the group fills in.
  final String endpoint;
  final VoidCallback onConnect;

  /// A long press: pick this host, or drop it.
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onFavourite;

  /// Rows in the Favourites and Recent sections carry their own keys.
  final String keyPrefix;
  final bool reachOn;
  final HostReach? reach;

  /// Hosts are being picked: the row shows a tick in place of its initial,
  /// and no menus.
  final bool selecting;
  final bool selected;

  /// On a phone: swipe right to connect, left to edit.
  final bool swipe;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = hostColor(host.color ?? defaultColorFor(host.label), Theme.of(context).brightness);
    final initial = host.label.isNotEmpty ? host.label[0].toUpperCase() : '?';
    final auth = switch (host.auth.kind) {
      AuthKind.identity => 'key',
      AuthKind.password => host.auth.passwordSecretId != null ? 'password saved' : 'password',
      AuthKind.agent => 'agent',
      AuthKind.interactive => 'ask',
      AuthKind.none => 'no login',
    };
    final r = reach;
    final reachLabel = !reachOn
        ? null
        : r == null
            ? 'Checking…'
            : r.up
                ? 'Up · ${r.millis} ms'
                : 'Not reachable';
    final tile = Semantics(
      selected: selecting ? selected : null,
      child: InkWell(
        key: Key('$keyPrefix-row-${host.id}'),
        onTap: onConnect,
        onLongPress: onSelect,
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? t.accent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: selecting ? null : color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: selecting
                      ? Icon(
                          selected ? Icons.check_circle : Icons.radio_button_unchecked,
                          key: Key('$keyPrefix-check-${host.id}'),
                          color: selected ? t.accent : t.muted,
                        )
                      : Text(initial, style: monoStyle(context, size: 15, weight: FontWeight.w600, color: color)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The time sits beside the label, taking at most half the
                    // line, so large text never pushes the row past the edge.
                    LayoutBuilder(
                      builder: (context, box) => Row(
                        children: [
                          Expanded(
                            child: Text(
                              host.label,
                              overflow: TextOverflow.ellipsis,
                              style: monoStyle(context, size: 15, weight: FontWeight.w500, color: t.text),
                            ),
                          ),
                          if (host.lastConnectedAt != null) ...[
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                              child: Text(
                                relativeTime(host.lastConnectedAt),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: t.muted),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (reachLabel != null) ...[
                          Tooltip(
                            message: reachLabel,
                            child: Container(
                              key: Key('$keyPrefix-reach-${host.id}'),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: r == null
                                    ? Colors.transparent
                                    : r.up
                                        ? t.accent
                                        : t.danger,
                                border: Border.all(color: r == null ? t.muted : Colors.transparent),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            '$endpoint · $auth',
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(context, size: 12, color: t.muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (!selecting) ...[
                IconButton(
                  key: Key('$keyPrefix-fav-${host.id}'),
                  tooltip: host.favourite ? 'Unfavourite' : 'Favourite',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: onFavourite,
                  icon: Icon(
                    host.favourite ? Icons.star : Icons.star_border,
                    color: host.favourite ? t.warning : t.muted,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Host actions',
                  onSelected: (v) {
                    switch (v) {
                      case 'edit':
                        onEdit();
                      case 'select':
                        onSelect();
                      case 'favourite':
                        onFavourite();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(value: 'select', child: Text('Select')),
                    PopupMenuItem(value: 'favourite', child: Text(host.favourite ? 'Unfavourite' : 'Favourite')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!swipe) return tile;
    // Neither way removes the row: it springs back once the action starts.
    return Dismissible(
      key: ValueKey('$keyPrefix-swipe-${host.id}'),
      background: _SwipeAction(icon: Icons.bolt_outlined, label: 'Connect', color: t.accent, start: true),
      secondaryBackground: _SwipeAction(icon: Icons.edit_outlined, label: 'Edit', color: t.muted, start: false),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onConnect();
        } else {
          onEdit();
        }
        return false;
      },
      child: tile,
    );
  }
}

/// What a swipe on a host row will do, showing as the row moves aside.
class _SwipeAction extends StatelessWidget {
  const _SwipeAction({required this.icon, required this.label, required this.color, required this.start});

  final IconData icon;
  final String label;
  final Color color;
  final bool start;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: start ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}
