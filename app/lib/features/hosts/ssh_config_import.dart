import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import 'repositories.dart';

/// Offer the hosts in ~/.ssh/config, let the person pick, and import them.
Future<void> showSshConfigImport(BuildContext context, WidgetRef ref) async {
  final List<SshConfigHost> hosts;
  try {
    hosts = ref.read(engineProvider).sshConfigHosts();
  } catch (e) {
    notYet(context, 'Could not read ~/.ssh/config: $e');
    return;
  }
  if (!context.mounted) return;
  if (hosts.isEmpty) {
    notYet(context, 'No hosts found in ~/.ssh/config.');
    return;
  }
  final chosen = await showDialog<List<String>>(
    context: context,
    builder: (ctx) => _ImportDialog(hosts: hosts),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;
  try {
    final report = ref.read(engineProvider).sshConfigImport(chosen);
    ref.invalidate(hostsProvider);
    ref.invalidate(identitiesProvider);
    final keys = report.keys == 0 ? '' : ' and ${report.keys} key${report.keys == 1 ? '' : 's'}';
    final skipped = report.skipped.isEmpty ? '' : ' Skipped ${report.skipped.length}: ${report.skipped.join('; ')}';
    notYet(context, 'Imported ${report.hosts} host${report.hosts == 1 ? '' : 's'}$keys.$skipped');
  } catch (e) {
    notYet(context, 'Import failed: $e');
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.hosts});

  final List<SshConfigHost> hosts;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final Set<String> _picked = {
    for (final h in widget.hosts)
      if (!h.alreadyImported) h.alias,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: const Text('Import from ~/.ssh/config'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hosts come in with their user, port and jump host. A key named by IdentityFile is saved too. Hosts without a key use the SSH agent.',
              style: TextStyle(fontSize: 13, color: t.muted, height: 1.4),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final h in widget.hosts)
                    CheckboxListTile(
                      key: Key('import-${h.alias}'),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      value: _picked.contains(h.alias),
                      onChanged: h.alreadyImported
                          ? null
                          : (v) => setState(() => v == true ? _picked.add(h.alias) : _picked.remove(h.alias)),
                      title: Text(h.alias, style: monoStyle(context, size: 13, weight: FontWeight.w600)),
                      subtitle: Text(
                        h.alreadyImported
                            ? 'already saved'
                            : '${h.user.isEmpty ? '' : '${h.user}@'}${h.hostname}${h.port == 22 ? '' : ':${h.port}'}'
                                '${h.identityFile == null ? ' · agent' : h.keyReadable ? ' · key' : ' · key file missing'}'
                                '${h.proxyJump == null ? '' : ' · via ${h.proxyJump}'}',
                        style: monoStyle(context, size: 11, color: t.muted),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('import-go'),
          onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
          child: Text('Import ${_picked.length}'),
        ),
      ],
    );
  }
}
