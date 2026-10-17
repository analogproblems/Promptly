import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../sessions/session_manager.dart';
import '../settings/settings_providers.dart';
import '../sessions/sessions_screen.dart';
import '../shell/empty_state.dart';
import '../sync/sync_providers.dart';
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

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.go('/hosts/new'),
        tooltip: 'Add host',
        child: const Icon(Icons.add),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                        children: [
                          for (final (title, prefix, list) in shortcuts) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                              child: Text(
                                title.toUpperCase(),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
                              ),
                            ),
                            for (final h in list)
                              _HostRow(
                                host: h,
                                endpoint: Inherited(h, groups).endpoint,
                                keyPrefix: prefix,
                                reachOn: reachOn,
                                reach: reach[h.id],
                                onConnect: () => _connect(h),
                                onEdit: () => context.go('/hosts/${h.id}'),
                                onDelete: () => _delete(h),
                                onFavourite: () => ref.read(hostsProvider.notifier).toggleFavourite(h.id),
                              ),
                          ],
                          if (shortcuts.isNotEmpty && sections.first.$1 == null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                              child: Text(
                                'ALL HOSTS',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
                              ),
                            ),
                          for (final (title, group, list) in sections) ...[
                            if (title != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                                child: Row(
                                  children: [
                                    Expanded(
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
                                    Text('${list.length}', style: TextStyle(fontSize: 11, color: t.muted)),
                                    if (group case final g?)
                                      IconButton(
                                        key: Key('group-edit-${g.id}'),
                                        tooltip: 'Edit group',
                                        visualDensity: VisualDensity.compact,
                                        iconSize: 16,
                                        icon: Icon(Icons.tune, color: t.muted),
                                        onPressed: () => showGroupEditor(context, ref, g),
                                      ),
                                  ],
                                ),
                              ),
                            for (final h in list)
                              _HostRow(
                                host: h,
                                endpoint: Inherited(h, groups).endpoint,
                                reachOn: reachOn,
                                reach: reach[h.id],
                                onConnect: () => _connect(h),
                                onEdit: () => context.go('/hosts/${h.id}'),
                                onDelete: () => _delete(h),
                                onFavourite: () => ref.read(hostsProvider.notifier).toggleFavourite(h.id),
                              ),
                          ],
                        ],
                      ),
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
    required this.onEdit,
    required this.onDelete,
    required this.onFavourite,
    this.keyPrefix = 'host',
    this.reachOn = false,
    this.reach,
  });

  final Host host;

  /// `user@host:port`, with what the group fills in.
  final String endpoint;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onFavourite;

  /// Rows in the Favourites and Recent sections carry their own keys.
  final String keyPrefix;
  final bool reachOn;
  final HostReach? reach;

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
    return InkWell(
      key: Key('$keyPrefix-row-${host.id}'),
      onTap: onConnect,
      borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(initial, style: monoStyle(context, size: 15, weight: FontWeight.w600, color: color)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host.label,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(context, size: 15, weight: FontWeight.w500, color: t.text),
                        ),
                      ),
                    ],
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
            const SizedBox(width: 8),
            Text(relativeTime(host.lastConnectedAt), style: TextStyle(fontSize: 11, color: t.muted)),
            IconButton(
              key: Key('$keyPrefix-fav-${host.id}'),
              tooltip: host.favourite ? 'Unfavourite' : 'Favourite',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onFavourite,
              icon: Icon(host.favourite ? Icons.star : Icons.star_border, color: host.favourite ? t.warning : t.muted),
            ),
            PopupMenuButton<String>(
              tooltip: 'Host actions',
              onSelected: (v) {
                switch (v) {
                  case 'edit':
                    onEdit();
                  case 'favourite':
                    onFavourite();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'favourite', child: Text(host.favourite ? 'Unfavourite' : 'Favourite')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
