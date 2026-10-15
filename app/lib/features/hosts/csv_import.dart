import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/file_picker.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import 'repositories.dart';

/// Pick a CSV file (the one Termius exports, or any with a Hostname
/// column), show the hosts in it, and import the chosen ones.
Future<void> showCsvImport(BuildContext context, WidgetRef ref) async {
  final picked = await ref.read(filePickerProvider)(label: 'CSV files', extensions: const ['csv', 'txt']);
  if (picked == null || !context.mounted) return;
  final List<CsvHost> hosts;
  try {
    hosts = ref.read(engineProvider).csvHostsPreview(picked.text);
  } catch (e) {
    notYet(context, 'Could not read ${picked.name}: $e');
    return;
  }
  if (hosts.isEmpty) {
    notYet(context, 'No SSH hosts found in ${picked.name}.');
    return;
  }
  final chosen = await showDialog<List<int>>(
    context: context,
    builder: (ctx) => _CsvDialog(filename: picked.name, hosts: hosts),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;
  try {
    final report = ref.read(engineProvider).csvHostsImport(picked.text, chosen);
    ref.invalidate(hostsProvider);
    ref.invalidate(groupsProvider);
    final skipped = report.skipped.isEmpty ? '' : ' Skipped ${report.skipped.length}: ${report.skipped.join('; ')}';
    notYet(context, 'Imported ${report.hosts} host${report.hosts == 1 ? '' : 's'}.$skipped');
  } catch (e) {
    notYet(context, 'Import failed: $e');
  }
}

class _CsvDialog extends StatefulWidget {
  const _CsvDialog({required this.filename, required this.hosts});

  final String filename;
  final List<CsvHost> hosts;

  @override
  State<_CsvDialog> createState() => _CsvDialogState();
}

class _CsvDialogState extends State<_CsvDialog> {
  late final Set<int> _picked = {
    for (var i = 0; i < widget.hosts.length; i++)
      if (!widget.hosts[i].alreadyImported) i,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: Text('Import from ${widget.filename}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hosts come in with their user, port, group and tags. A password in the file is saved with the host; a host without one asks when it connects.',
              style: TextStyle(fontSize: 13, color: t.muted, height: 1.4),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < widget.hosts.length; i++)
                    CheckboxListTile(
                      key: Key('csv-import-$i'),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _picked.contains(i),
                      onChanged: widget.hosts[i].alreadyImported
                          ? null
                          : (on) => setState(() => on! ? _picked.add(i) : _picked.remove(i)),
                      title: Text(widget.hosts[i].label),
                      subtitle: Text(_describe(widget.hosts[i])),
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
          key: const Key('csv-import-go'),
          onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()..sort()),
          child: Text('Import ${_picked.length}'),
        ),
      ],
    );
  }

  static String _describe(CsvHost h) {
    final login = h.username.isEmpty ? h.hostname : '${h.username}@${h.hostname}';
    final parts = [
      h.port == 22 ? login : '$login:${h.port}',
      if (h.hasPassword) 'password',
      if (h.group != null) h.group!,
      if (h.tags.isNotEmpty) h.tags.join(', '),
      if (h.alreadyImported) 'already saved',
    ];
    return parts.join(' · ');
  }
}
