import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../hosts/repositories.dart';
import '../hosts/session_label_editor.dart';
import '../hosts/session_labels.dart';
import '../sessions/status_dot.dart';
import '../shell/empty_state.dart';

/// The labels a host can carry, each a coloured bar and tab border with
/// its name in words. Production comes with the app and can be changed
/// like any other.
class SessionLabelsScreen extends ConsumerWidget {
  const SessionLabelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final labels = ref.watch(sessionLabelsProvider);
    final hosts = ref.watch(hostsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Session labels',
          leading: IconButton(
            tooltip: 'Back to settings',
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.arrow_back),
          ),
          trailing: OutlinedButton.icon(
            key: const Key('label-add'),
            onPressed: () => showSessionLabelEditor(context, SessionLabel.create(), isNew: true),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New label'),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 12),
                child: Text(
                  'Give a host a label in its Organise section. Its sessions then get a bar across the top '
                  'in the label\'s colour, with its name in words, and on a computer its tabs carry it too.',
                  style: TextStyle(color: t.muted, fontSize: 13),
                ),
              ),
              if (labels.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text('No labels yet.', style: TextStyle(color: t.muted)),
                ),
              for (final l in labels)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: t.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: t.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: Key('label-${l.id}'),
                      onTap: () => showSessionLabelEditor(context, l),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SessionLabelBar(
                            mark: SessionMark(name: l.name, text: l.name, color: l.color, warn: l.warn),
                          ),
                          ListTile(
                            title: Text(l.name),
                            subtitle: Text(switch (hosts.where((h) => h.sessionLabelId == l.id).length) {
                              0 => 'No hosts',
                              1 => '1 host',
                              final n => '$n hosts',
                            }),
                            trailing: Icon(Icons.edit_outlined, color: t.muted),
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
    );
  }
}
